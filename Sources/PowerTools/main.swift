import Foundation
import AppKit

// Power Tools — fully-local voice dictation for macOS 26+.
// No arguments: run the menu-bar app. Subcommands below are for testing/administration.

/// Run async work to completion from the synchronous CLI entry point.
/// Detached so nothing accidentally hops onto the (blocked) main actor.
func runBlocking<T: Sendable>(_ op: @Sendable @escaping () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await op()) }
        catch { box.result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try box.result!.get()
}

final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Helpers for `trackpad-tap-test` — a C event-tap callback can't capture, so
/// the timestamp base and the formatter live here at file scope.
enum TapProbe {
    nonisolated(unsafe) static var t0: CFAbsoluteTime = 0
    static func stamp() -> String { String(format: "%7.3f", CFAbsoluteTimeGetCurrent() - t0) }
    static func line(type: CGEventType, event: CGEvent) -> String {
        let name: String
        switch type {
        case .leftMouseDown: name = "L-down"
        case .leftMouseUp: name = "L-up"
        case .rightMouseDown: name = "R-down"
        case .rightMouseUp: name = "R-up"
        case .otherMouseDown: name = "M-down"
        case .otherMouseUp: name = "M-up"
        default: name = "type\(type.rawValue)"
        }
        var mods = ""
        if event.flags.contains(.maskAlternate) { mods += "⌥" }
        if event.flags.contains(.maskShift) { mods += "⇧" }
        if event.flags.contains(.maskCommand) { mods += "⌘" }
        if event.flags.contains(.maskControl) { mods += "⌃" }
        let clicks = event.getIntegerValueField(.mouseEventClickState)
        let p = event.location
        return "\(stamp())  mouse \(name)\(mods.isEmpty ? "" : " " + mods)  clicks=\(clicks)  at=(\(Int(p.x)),\(Int(p.y)))"
    }
}

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    grc-whisper — fully-local voice dictation (hold a key, speak, release)

    usage:
      grc-whisper                     run the menu-bar app
      grc-whisper transcribe <file> [--engine apple|parakeet]   transcribe an audio file (engine test)
      grc-whisper polish <text>       run the cleanup pipeline on text (LLM test)
      grc-whisper doctor              check permissions and on-device models
      grc-whisper trackpad-tap-test [seconds]   probe the three-finger-tap detector + mouse events
      grc-whisper dict add <term> [misheard,variants]
      grc-whisper dict rm <term>
      grc-whisper dict list
      grc-whisper history [n]         show recent transcriptions
    """)
    exit(1)
}

switch args.first {
case nil, "run":
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

case "transcribe":
    guard args.count >= 2 else { usage() }
    let url = URL(fileURLWithPath: args[1])
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("no such file: \(url.path)"); exit(1)
    }
    let locale = Locale(identifier: Config.load().localeIdentifier)
    let requestedEngine: Config.ASREngine
    if let flagIndex = args.firstIndex(of: "--engine"), args.count > flagIndex + 1 {
        guard let parsed = Config.ASREngine(rawValue: args[flagIndex + 1]) else {
            print("unknown engine \(args[flagIndex + 1]) — expected apple or parakeet"); exit(1)
        }
        requestedEngine = parsed
    } else {
        requestedEngine = .apple
    }
    let paced = args.contains("--paced")
    // Same dictionary-driven vocab boosting as the app, so CLI tests exercise it.
    ParakeetEngine.vocabTermsProvider = { Store().dictionary() }
    do {
        let started = Date()
        // resolveEngineType() is called INSIDE the closure so only the Sendable
        // enum crosses the @Sendable boundary, not the (non-Sendable) metatype.
        let text = try runBlocking { try await transcribeFile(url: url, locale: locale, engine: resolveEngineType(requestedEngine), paced: paced) }
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        FileHandle.standardError.write("(transcribed in \(elapsed)s)\n".data(using: .utf8)!)
        print(text)
    } catch {
        print("transcription failed: \(error)"); exit(1)
    }

case "polish":
    guard args.count >= 2 else { usage() }
    let input = args.dropFirst().joined(separator: " ")
    let store = Store()
    let cfg = Config.load()
    let text = try! runBlocking {
        let polisher = Polisher(store: store)
        return await polisher.polish(input, config: cfg, appName: "Terminal")
    }
    print(text)

case "rewrite":
    // grc-whisper rewrite "<instruction>" "<text to transform>"  (AI command mode)
    guard args.count >= 3 else { usage() }
    let store = Store()
    let cfg = Config.load()
    let out = try! runBlocking {
        let p = Polisher(store: store)
        return await p.rewrite(instruction: args[1], selection: args[2], config: cfg) ?? "(rewrite failed)"
    }
    print(out)

case "chat":
    // grc-whisper chat "<message>"  — smoke-test the streaming AI chat backend.
    guard args.count >= 2 else { usage() }
    let msg = args.dropFirst().joined(separator: " ")
    guard let key = Keychain.get("claude"), !key.isEmpty else {
        print("no Claude key saved (add one in Settings ▸ AI)"); exit(1)
    }
    let cfg = Config.load()
    do {
        let reply = try runBlocking {
            try await CloudPolish.claudeChatStream(
                messages: [["role": "user", "content": msg]],
                system: "You are a helpful assistant.",
                model: cfg.claudeModel, apiKey: key, onUpdate: { _ in })
        }
        print(reply)
    } catch {
        print("chat failed: \(error)"); exit(1)
    }

case "ocr":
    // grc-whisper ocr <image>  — OCR an image file (tests table reconstruction)
    guard args.count >= 2, let png = try? Data(contentsOf: URL(fileURLWithPath: args[1])) else { usage() }
    print(ScreenCapture.ocr(png))

case "lens":
    // grc-whisper lens <image>  — print the Google Lens results URL (test)
    guard args.count >= 2, let png = try? Data(contentsOf: URL(fileURLWithPath: args[1])) else { usage() }
    let url = try! runBlocking { await ScreenCapture.googleLensURL(png) }
    print(url?.absoluteString ?? "(lens upload failed)")

case "settings-preview":
    // settings-preview [out.png] [light|dark] [tabIndex] [height]
    MainActor.assumeIsolated {
        var cfg = Config.load()
        if args.count >= 3, args[2] == "light" { cfg.appearance = .light }
        if args.count >= 3, args[2] == "dark" { cfg.appearance = .dark }
        let sc = SettingsWindowController(store: Store(), config: cfg, onConfigChange: { _ in })
        if args.count >= 4, let tab = Int(args[3]) { sc.selectTab(tab) }
        guard let window = sc.window else { exit(1) }
        let previewH = args.count >= 5 ? Int(args[4]) ?? 640 : 640
        window.setContentSize(NSSize(width: 660, height: CGFloat(previewH)))
        window.layoutIfNeeded()
        guard let content = window.contentView else { exit(1) }
        content.layoutSubtreeIfNeeded()
        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: args.count >= 2 ? args[1] : "settings.png"))
                print("wrote")
            }
        }
    }

case "render-window":
    // Offscreen preview of the window-organizer overlay state.
    let out = args.count >= 2 ? args[1] : "window-preview.png"
    let dark = args.count >= 3 && args[2] == "dark"
    MainActor.assumeIsolated {
        let content = OverlayPanel.buildWindowContent(
            dark: dark, region: CGRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1), label: "Left ⅓")
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(1) }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "findmouse-preview":
    let out = args.count >= 2 ? args[1] : "findmouse-preview.png"
    MainActor.assumeIsolated {
        let W: CGFloat = 1200, H: CGFloat = 760
        let img = NSImage(size: NSSize(width: W, height: H))
        img.lockFocus()
        NSColor(white: 0.82, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
        NSColor.white.setFill(); NSRect(x: 120, y: 160, width: 420, height: 320).fill()
        NSColor(white: 0.95, alpha: 1).setFill(); NSRect(x: 680, y: 260, width: 440, height: 360).fill()
        let fm = FindMouseView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        fm.point = NSPoint(x: W * 0.62, y: H * 0.5); fm.alpha = 1; fm.converge = 0.45
        fm.draw(fm.bounds)
        img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("wrote \(out)")
    }

case "advpaste-preview", "advancedpaste-preview":
    let out = args.count >= 2 ? args[1] : "advpaste-preview.png"
    let dark = !(args.count >= 3 && args[2] == "light")
    MainActor.assumeIsolated {
        let v = AdvancedPasteView(clipboard: "The quarterly report shows revenue up 12% with strong enterprise growth and a healthy pipeline for Q3.", dark: dark)
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)") }
    }

case "quickcapture-preview":
    let out = args.count >= 2 ? args[1] : "quickcapture-preview.png"
    let dark = !(args.count >= 3 && args[2] == "light")
    MainActor.assumeIsolated {
        let v = QuickCaptureView(dark: dark, title: "Todo", prefill: "Email the Q3 vendor list to Dana")
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        v.layoutSubtreeIfNeeded()  // the input field is Auto Layout; realize it before caching
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "snapassist-preview":
    let out = args.count >= 2 ? args[1] : "snapassist-preview.png"
    let dark = args.count >= 3 && args[2] == "dark"
    MainActor.assumeIsolated {
        func fake(_ t: String, _ sym: String) -> SnapAssist.Candidate {
            SnapAssist.Candidate(pid: 0, windowID: 0, title: t,
                                 icon: NSImage(systemSymbolName: sym, accessibilityDescription: nil))
        }
        let cands = [fake("GitHub — Chrome", "globe"), fake("Notes", "note.text"),
                     fake("Mail — Inbox (23)", "envelope.fill"), fake("Terminal — zsh", "terminal.fill"),
                     fake("Slack — general", "message.fill")]
        let view = SnapAssistView(candidates: cands, dark: dark)
        view.frame = NSRect(x: 0, y: 0, width: 940, height: 760)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "cliphistory-preview":
    // Offscreen render of the clipboard-history palette for design checks.
    let out = args.count >= 2 ? args[1] : "cliphistory-preview.png"
    let dark = !(args.count >= 3 && args[2] == "light")
    MainActor.assumeIsolated {
        let now = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-180))
        let older = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200))
        // A small generated image so the thumbnail row renders in the preview.
        let img = NSImage(size: NSSize(width: 320, height: 180))
        img.lockFocus()
        NSColor(srgbRed: 0.3, green: 0.6, blue: 0.9, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 320, height: 180).fill()
        NSColor.white.setFill()
        NSRect(x: 40, y: 40, width: 240, height: 100).fill()
        img.unlockFocus()
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let clips = [
            ClipEntry(id: 5, timestamp: now, content: "az staticwebapp secrets list -n kaw-survey-swa -g rg-gridops", image: nil),
            ClipEntry(id: 4, timestamp: now, content: "Image · 320×180", image: png),
            ClipEntry(id: 3, timestamp: older, content: "The crew completed 14 surveys today; 3 premises had no access.\nSecond visits are scheduled for Thursday.", image: nil),
            ClipEntry(id: 2, timestamp: older, content: "https://github.com/BadassHomesteader/grc-power-tools", image: nil),
            ClipEntry(id: 1, timestamp: older, content: "#4a73ff", image: nil),
        ]
        let v = ClipboardPaletteView(clips: clips, dark: dark)
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "palette-preview":
    // Offscreen render of the snap palette for design checks.
    let out = args.count >= 2 ? args[1] : "palette-preview.png"
    let dark = !(args.count >= 3 && args[2] == "light")
    MainActor.assumeIsolated {
        guard let screen = NSScreen.main else { exit(1) }
        let cfg = Config.load()
        let v = WindowPaletteView(dark: dark, gridCols: cfg.gridSize.cols, gridRows: cfg.gridSize.rows,
                                  screens: NSScreen.screens, initialScreen: screen)
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        v.previewState(highlight: 2, gridSel: ((2, 1), (7, 6)), quarters: args.contains("quarters"))
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "grid-preview":
    let out = args.count >= 2 ? args[1] : "grid-preview.png"
    let dark = args.count >= 3 && args[2] == "dark"
    MainActor.assumeIsolated {
        let gv = GridView(cols: 12, rows: 8, dark: dark)
        gv.frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
        gv.previewSelect((0, 2), (5, 7))  // sample selection
        guard let rep = gv.bitmapImageRepForCachingDisplay(in: gv.bounds) else { exit(1) }
        gv.cacheDisplay(in: gv.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "whiteboard-preview":
    // Offscreen render of the annotation whiteboard: a synthetic "screenshot"
    // with one seeded stroke per tool, for design checks. `light` = light dim.
    let out = args.count >= 2 ? args[1] : "whiteboard-preview.png"
    let dark = !args.contains("light")
    MainActor.assumeIsolated {
        guard let png = WhiteboardView.syntheticShot(),
              let v = WhiteboardView(png: png, dark: dark) else { exit(1) }
        v.frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
        v.previewSeed(strokes: WhiteboardView.sampleStrokes(in: v.previewCanvasSize()),
                      tool: .arrow, colorIndex: 0)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "whiteboard-export-test":
    // whiteboard-export-test [in.png] [out.png] — seeds one stroke per tool and
    // writes renderAnnotatedPNG(). Verifies the export math no screen preview
    // exercises: output pixel dims must equal input (exit 1 otherwise).
    MainActor.assumeIsolated {
        let inPath = args.count >= 2 ? args[1] : ""
        let out = args.count >= 3 ? args[2] : "whiteboard-export-test.png"
        let png: Data
        if inPath.isEmpty {
            guard let d = WhiteboardView.syntheticShot() else { exit(1) }
            png = d
        } else {
            guard let d = FileManager.default.contents(atPath: inPath) else {
                print("cannot read \(inPath)"); exit(1)
            }
            png = d
        }
        guard let inRep = NSBitmapImageRep(data: png),
              let v = WhiteboardView(png: png, dark: true) else { exit(1) }
        v.frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
        v.previewSeed(strokes: WhiteboardView.sampleStrokes(in: v.previewCanvasSize()),
                      tool: .pen, colorIndex: 0)
        guard let outData = v.renderAnnotatedPNG(),
              let outRep = NSBitmapImageRep(data: outData) else { print("export failed"); exit(1) }
        try? outData.write(to: URL(fileURLWithPath: out))
        print("in \(inRep.pixelsWide)x\(inRep.pixelsHigh) → out \(outRep.pixelsWide)x\(outRep.pixelsHigh)")
        if inRep.pixelsWide != outRep.pixelsWide || inRep.pixelsHigh != outRep.pixelsHigh { exit(1) }
    }

case "whiteboard-live-test":
    // Presents a REAL whiteboard window and drives it with synthesized mouse
    // events — proves what the offscreen preview can't: the borderless window
    // becomes key, the view takes first responder, the text tool's field editor
    // works, the Esc funnel cancels entry-then-window, and save() composites.
    // `hold` keeps the last window up so it can be screenshotted.
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let hold = args.contains("hold")
        func pump(_ s: Double = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("\(ok ? "ok  " : "FAIL") \(what)")
            if !ok { failures += 1 }
        }
        guard let png = WhiteboardView.syntheticShot(), let screen = NSScreen.main else { exit(1) }

        var saved: Data?
        var cancelled = false
        let wb = Whiteboard()
        var visibility: [Bool] = []
        wb.onVisibility = { visibility.append($0) }
        wb.present(png: png, dark: true, screen: screen,
                   onSave: { saved = $0 }, onCancel: { cancelled = true })
        pump(0.4)
        guard let win = app.windows.first(where: { $0.contentView is WhiteboardView }),
              let view = win.contentView as? WhiteboardView else { print("FAIL no window"); exit(1) }
        // isKeyWindow is NOT assertable from this harness: a bare CLI binary
        // can't take activation from the terminal (NSApp.isActive stays false),
        // and GridOverlay — the shipped window this pattern copies — reports
        // key=false here too. What IS assertable is the structural guarantee a
        // borderless window normally lacks, plus first-responder wiring.
        check(win.canBecomeKey, "borderless window can become key (KeyableWindow)")
        check(win.isVisible, "window is on screen")
        check(win.firstResponder === view, "view is first responder")
        check(visibility == [true], "onVisibility(true) mirrored to the tap")

        // Synthesized pen drag across the image (window coords == view coords:
        // the view is the contentView at the origin).
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                               windowNumber: win.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let box = view.imageRect
        view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: box.minX + 40, y: box.minY + 40)))
        for i in 1...6 {
            view.mouseDragged(with: mouse(.leftMouseDragged,
                NSPoint(x: box.minX + 40 + CGFloat(i) * 20, y: box.minY + 40 + CGFloat(i) * 8)))
        }
        view.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: box.minX + 160, y: box.minY + 88)))
        check(view.strokeCount == 1, "pen drag committed one stroke")

        // Text tool: click places a field editor, typing commits as a stroke.
        view.selectTool(.text)
        view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: box.midX, y: box.midY)))
        pump()
        check(view.isEditingText, "text click opened an entry field")
        check(win.firstResponder !== view, "field editor took first responder")
        view.activeTextField?.stringValue = "annotated"
        view.commitActiveText()
        pump()
        check(!view.isEditingText && view.strokeCount == 2, "text committed as a stroke")

        // Esc funnel: first Esc cancels a live entry, the window stays up.
        view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: box.midX, y: box.minY + 30)))
        pump()
        view.activeTextField?.stringValue = "discard me"
        wb.handleEscape()
        pump()
        check(!view.isEditingText && view.strokeCount == 2, "esc cancelled the text entry only")
        check(wb.isVisible && !cancelled, "whiteboard still up after entry-cancel")

        // Undo drops the last committed stroke.
        view.undo()
        check(view.strokeCount == 1, "undo popped the text stroke")

        // Save composites at the source's pixel size and dismisses.
        view.save()
        pump()
        check(saved != nil, "save produced a PNG")
        if let saved, let rep = NSBitmapImageRep(data: saved) {
            check(rep.pixelsWide == 900 && rep.pixelsHigh == 560,
                  "export kept source resolution (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        }
        check(!wb.isVisible, "save dismissed the window")
        check(visibility == [true, false], "onVisibility(false) mirrored on dismiss")

        // Second Esc path: no live entry → the whole board cancels.
        wb.present(png: png, dark: true, screen: screen, onSave: { _ in }, onCancel: { cancelled = true })
        pump(0.3)
        if hold {
            print("holding the window for 6s — screenshot it now")
            pump(6)
        }
        wb.handleEscape()
        pump()
        check(cancelled && !wb.isVisible, "esc with no entry closed the board")

        print(failures == 0 ? "PASS" : "FAILED \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

case "chat-live-test":
    // Opens a real chat window and pumps the run loop so the deferred
    // scrollToBottom() actually executes — exercises the live crash path.
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let cc = ChatWindowController(config: Config.load())
        cc.present()
        cc.send("Say hello in exactly three words.")   // exercises streaming + scroll
        RunLoop.main.run(until: Date().addingTimeInterval(8))
        print("survived")
    }

case "chat-preview":
    // Offscreen render of the AI chat window for design checks.
    let out = args.count >= 2 ? args[1] : "chat-preview.png"
    MainActor.assumeIsolated {
        var cfg = Config.load()
        if args.count >= 3, args[2] == "light" { cfg.appearance = .light }
        if args.count >= 3, args[2] == "dark" { cfg.appearance = .dark }
        let cc = ChatWindowController(config: cfg)
        guard let window = cc.window else { exit(1) }
        window.setContentSize(NSSize(width: 520, height: 620))
        cc.previewSeed()
        window.layoutIfNeeded()
        guard let content = window.contentView else { exit(1) }
        content.layoutSubtreeIfNeeded()
        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: out))
                print("wrote \(out)")
            }
        }
    }

case "macropad-preview":
    // Offscreen render of the macro pad for design checks (sample profile,
    // second button shown as a keyword-suggested match). Flags: "light",
    // "mini" (traffic strip).
    let out = args.count >= 2 ? args[1] : "macropad-preview.png"
    let dark = !args.contains("light")
    let mini = args.contains("mini")
    MainActor.assumeIsolated {
        let buttons = ["Invoices", "Projects", "Receipts", "Travel", "Newsletters", "Archive"]
            .map { Config.MacroButton(title: $0, chord: "cmd+shift+m", text: $0, pressReturn: true) }
        let v = MacroPadView(dark: dark)
        v.configure(appName: "Microsoft Outlook", buttons: buttons, dark: dark,
                    hotkeyName: "Option + Shift", mini: mini)
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        v.previewState(hover: mini ? nil : 4, suggested: [1])
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "macropad-live-test":
    // Dock + mini geometry diagnostic: presents a REAL pad, walks it through
    // drop points (left-edge dead zone, exact left anchor, right spawn), snaps,
    // and toggles mini via a synthesized click on the header "–" — printing the
    // panel frame after every step. No real mouse needed.
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // The harness snaps/persists for real — shield the user's live
        // placement file and put it back on the way out.
        let placementURL = Config.appSupportDir.appendingPathComponent("pad-placement.json")
        let placementBackup = try? Data(contentsOf: placementURL)
        func finish(_ code: Int32) -> Never {
            if let placementBackup { try? placementBackup.write(to: placementURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: placementURL) }
            exit(code)
        }
        // Never the frontmost app as-is: when that is Power Tools itself (or
        // nil) present() leaves currentBundleID unset, the test profile matches
        // nothing, and every size assertion below silently measures an EMPTY
        // pad instead of a four-button one.
        let front = [NSWorkspace.shared.frontmostApplication]
            .compactMap { $0 }
            .first { $0.bundleIdentifier != "com.grc.whisper" }
            ?? NSWorkspace.shared.runningApplications.first {
                $0.activationPolicy == .regular && $0.bundleIdentifier != "com.grc.whisper"
            }
        let buttons = ["Invoices", "Projects", "Receipts", "Travel"]
            .map { Config.MacroButton(title: $0, chord: "cmd+shift+m", text: $0, pressReturn: true) }
        let profile = Config.MacroProfile(bundleID: front?.bundleIdentifier ?? "com.apple.finder",
                                          name: front?.localizedName ?? "Finder", buttons: buttons)
        guard let screen = NSScreen.main else { finish(1) }
        let vf = screen.visibleFrame
        let pad = MacroPad()
        pad.present(profiles: [profile], dark: true, screen: screen, hotkeyName: "test",
                    frontApp: front, onAction: { _, _ in })
        func pump(_ s: Double = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        pump()
        guard let panel = app.windows.compactMap({ $0 as? NSPanel })
                .first(where: { $0.contentView is MacroPadView }),
              let view = panel.contentView as? MacroPadView else { print("NO PANEL"); finish(1) }
        func report(_ tag: String) {
            let f = panel.frame
            let side = f.midX < vf.midX ? "LEFT" : "RIGHT"
            print("\(tag): origin=(\(Int(f.minX)),\(Int(f.minY))) size=\(Int(f.width))x\(Int(f.height)) \(side)  [vf x \(Int(vf.minX))…\(Int(vf.maxX))]")
        }
        func synth(_ type: NSEvent.EventType, at pView: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(pView, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: panel.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Header "–" center in flipped view coords (width 220: x = 220-10-62+9).
        func clickMinimize() { view.mouseDown(with: synth(.leftMouseDown, at: NSPoint(x: 157, y: 21))); pump() }
        func hoverStrip() { view.mouseMoved(with: synth(.mouseMoved, at: NSPoint(x: 14, y: 14))); pump() }
        func leave() { view.mouseExited(with: synth(.mouseMoved, at: NSPoint(x: -30, y: -30))); pump() }
        report("1 present (expect RIGHT spawn)")

        // 2: drop in the LEFT-EDGE DEAD ZONE (midway between topLeft and midLeft
        // anchors) — is there a snap, and where does mini go?
        var size = panel.frame.size
        let deadY = ((vf.midY - size.height / 2) + (vf.maxY - 12 - size.height)) / 2
        panel.setFrame(NSRect(origin: NSPoint(x: vf.minX + 14, y: deadY), size: size), display: true)
        pad.snapAfterDrag(); pump()
        report("2 drop left dead-zone + snap")
        clickMinimize()
        report("3 minimize after dead-zone drop (expect LEFT)")
        hoverStrip()
        report("4 hover-peek (expect LEFT)")
        clickMinimize()   // □ while peeking → pin full
        report("5 pin full")

        // 6: drop EXACTLY on the midLeft anchor, snap, minimize.
        size = panel.frame.size
        panel.setFrame(NSRect(origin: NSPoint(x: vf.minX + 12, y: vf.midY - size.height / 2),
                              size: size), display: true)
        pad.snapAfterDrag(); pump()
        report("6 drop at midLeft anchor + snap")
        clickMinimize()
        report("7 minimize while docked LEFT (expect LEFT)")
        hoverStrip()
        report("8 hover-peek while docked (expect LEFT)")
        leave()
        report("9 mouse-exit re-collapse (expect LEFT)")
        hoverStrip(); clickMinimize()
        report("10 pin full again")

        // 11: small adjust-drag near the RIGHT spawn (12px from midRight) —
        // does an accidental micro-drag silently dock midRight?
        size = panel.frame.size
        panel.setFrame(NSRect(origin: NSPoint(x: vf.maxX - size.width - 24, y: vf.midY - size.height / 2),
                              size: size), display: true)
        pad.snapAfterDrag(); pump()
        report("11 micro-drag near right spawn + snap")
        // 12: now drag LEFT into the dead zone (user 'moves it to the left').
        panel.setFrame(NSRect(origin: NSPoint(x: vf.minX + 14, y: deadY), size: size), display: true)
        pad.snapAfterDrag(); pump()
        report("12 drag to left dead-zone + snap")
        clickMinimize()
        report("13 minimize (expect LEFT)")

        // 14: REAL synthetic drag through the manual-drag path (mouseDown →
        // mouseDragged → mouseUp on the view) onto the midLeft anchor —
        // exercises overlay show/update/hide + snap + persistence.
        hoverStrip(); clickMinimize()   // back to pinned full
        size = panel.frame.size
        let grabView = NSPoint(x: 110, y: size.height - 12)   // footer empty spot
        view.mouseDown(with: synth(.leftMouseDown, at: grabView))
        let grabWin = view.convert(grabView, to: nil)
        let target = NSPoint(x: vf.minX + 20, y: vf.midY - size.height / 2 + 30)  // near midLeft, within 96
        let o = panel.frame.origin
        let dragLoc = NSPoint(x: grabWin.x + target.x - o.x, y: grabWin.y + target.y - o.y)
        view.mouseDragged(with: NSEvent.mouseEvent(with: .leftMouseDragged, location: dragLoc,
                                                   modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: panel.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1)!)
        pump(0.1)
        let canvas = PadDock.Field(screen: screen).canvas
        let overlayUp = app.windows.contains { $0.ignoresMouseEvents && $0.frame == canvas }
        print("14 mid-drag: overlay \(overlayUp ? "VISIBLE" : "MISSING (expected VISIBLE)")")
        view.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: dragLoc,
                                              modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: panel.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1)!)
        pump()
        report("15 dropped near midLeft via real drag path (expect snap to x=12)")
        let overlayGone = !app.windows.contains { $0.ignoresMouseEvents && $0.frame == canvas && $0.isVisible }
        print("16 after drop: overlay \(overlayGone ? "hidden" : "STILL UP (expected hidden)")")

        // 17-19: the notch is NOT a pad berth any more — NotchStrip owns the
        // housing. A pad aimed at each retired berth must land on an ordinary
        // anchor instead of on top of the strip.
        let field = PadDock.Field(screen: screen)
        let offered = PadDock.anchors(in: field)
        print("   screen frame=\(screen.frame) visible=\(vf) notch=\(field.notch) hasNotch=\(field.hasNotch)")
        print("   anchors offered: \(offered.map(\.rawValue).joined(separator: ", "))")
        print("17 no notch anchor is offered: \(offered.contains(where: \.isNotch) ? "FAIL" : "PASS") · " +
              "topMid restored on a notched display: \(offered.contains(.topMid) ? "PASS" : "FAIL")")

        for (tag, retired) in [("18 aim at the old left shoulder", PadDock.notchLeft),
                               ("19 aim at the old shelf", PadDock.notchBelow)] {
            size = panel.frame.size   // still pinned full from step 14
            let aim = retired.origin(for: size, in: field)
            panel.setFrame(NSRect(origin: aim, size: size), display: true)
            pad.snapAfterDrag(); pump(0.3)
            report(tag)
            let landed = offered.first { anchor in
                let o = anchor.origin(for: panel.frame.size, in: field)
                return abs(panel.frame.minX - o.x) < 1 && abs(panel.frame.minY - o.y) < 1
            }
            // Free-floating is a fine outcome too — what must NEVER happen is
            // the pad coming to rest inside the housing band, where it would
            // sit on top of the strip.
            let inBand = panel.frame.maxY > field.notch.minY
            print("   landed on \(landed?.rawValue ?? "free-float") · clear of the housing band: " +
                  "\(inBand ? "FAIL" : "PASS")")
        }

        // 20: collapsed, the pad is a plain vertical column again — the notch
        // strip took the horizontal flanking layout with it.
        clickMinimize(); pump(0.3)
        report("20 minimized")
        let strip = panel.frame
        let lights = view.buttonCount
        print("   \(lights) light(s) · vertical column: " +
              "\(lights < 2 ? "n/a (a single light is square)" : (strip.height > strip.width ? "PASS" : "FAIL"))")

        // 21: restart simulation — a FRESH MacroPad instance restores the dock
        // from pad-placement.json.
        pad.dismiss(); pump()
        let pad2 = MacroPad()
        pad2.present(profiles: [profile], dark: true, screen: screen, hotkeyName: "test",
                     frontApp: front, onAction: { _, _ in })
        pump()
        if let panel2 = app.windows.compactMap({ $0 as? NSPanel })
            .first(where: { $0.contentView is MacroPadView && $0.isVisible }) {
            let f = panel2.frame
            print("21 fresh instance after restart: origin=(\(Int(f.minX)),\(Int(f.minY))) " +
                  "clear of the housing band: \(f.maxY > field.notch.minY ? "FAIL" : "PASS")")
        } else {
            print("21 fresh instance: NO PANEL")
        }
        pad2.dismiss()
        finish(0)
    }

case "macropad-summon-test":
    // Summon (hold + three-finger tap) geometry + persistence harness: presents
    // a REAL pad summoned at a fake cursor point, then walks summon-from-dock,
    // send-home via the header "–", drag-ends-summon, edge flipping, and the
    // no-collapse-on-mouse-exit guard — asserting after every step that the
    // saved berth in pad-placement.json never changes except its open flag.
    // No trackpad needed. Backs up / restores the user's live placement file.
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let placementURL = Config.appSupportDir.appendingPathComponent("pad-placement.json")
        let placementBackup = try? Data(contentsOf: placementURL)
        var failures = 0
        func finish() -> Never {
            if let placementBackup { try? placementBackup.write(to: placementURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: placementURL) }
            print(failures == 0 ? "ALL GREEN" : "\(failures) FAILURE(S)")
            exit(failures == 0 ? 0 : 1)
        }
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("  [\(ok ? "ok" : "FAIL")] \(what)")
        }
        let front = [NSWorkspace.shared.frontmostApplication]
            .compactMap { $0 }
            .first { $0.bundleIdentifier != "com.grc.whisper" }
            ?? NSWorkspace.shared.runningApplications.first {
                $0.activationPolicy == .regular && $0.bundleIdentifier != "com.grc.whisper"
            }
        let buttons = ["Invoices", "Projects", "Receipts", "Travel", "Archive"]
            .map { Config.MacroButton(title: $0, chord: "cmd+shift+m", text: $0, pressReturn: true) }
        let profile = Config.MacroProfile(bundleID: front?.bundleIdentifier ?? "com.apple.finder",
                                          name: front?.localizedName ?? "Finder", buttons: buttons)
        guard let screen = NSScreen.main else { print("no screen"); finish() }
        let vf = screen.visibleFrame
        func pump(_ s: Double = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func saved() -> PadPlacement? { PadPlacement.load("macro") }
        func describe(_ p: PadPlacement?) -> String {
            guard let p else { return "(none)" }
            return "anchor=\(p.anchor?.rawValue ?? "nil") x=\(p.x.map { Int($0) }.map(String.init) ?? "nil") y=\(p.y.map { Int($0) }.map(String.init) ?? "nil") mini=\(p.mini ?? false) open=\(p.open ?? false)"
        }
        // The home record may legitimately carry the strip's x/y beside its
        // anchor (a normal open persists the frame) — the invariant is that a
        // summon changes NOTHING but the open flag.
        func homeUnchanged(_ tag: String, since before: PadPlacement?, expectOpen: Bool) {
            let p = saved()
            let same = p?.anchor == before?.anchor && p?.x == before?.x && p?.y == before?.y
                && (p?.mini ?? false) == (before?.mini ?? false)
            check(same && p?.open == expectOpen,
                  "\(tag): saved berth intact (\(describe(p))) vs before (\(describe(before)))")
        }
        func panelFor(_ pad: MacroPad) -> (NSPanel, MacroPadView)? {
            guard let panel = app.windows.compactMap({ $0 as? NSPanel })
                    .first(where: { $0.contentView is MacroPadView && $0.isVisible }),
                  let view = panel.contentView as? MacroPadView else { return nil }
            return (panel, view)
        }
        func frameStr(_ f: NSRect) -> String { "origin=(\(Int(f.minX)),\(Int(f.minY))) size=\(Int(f.width))x\(Int(f.height))" }
        func besideCursor(_ f: NSRect, _ c: NSPoint) -> Bool {
            let outside = !f.contains(c)
            let near = abs(f.minX - (c.x + 10)) < 1 && abs(f.maxY - (c.y - 10)) < 1
            return outside && near
        }

        // Seed the user's real-world state: docked mid-left, mini strip, closed.
        PadPlacement.save("macro", anchor: .midLeft, topLeft: nil, mini: true, open: false)
        let seeded = saved()
        var summonEvents: [Bool] = []

        // 1: summon from CLOSED at a mid-screen cursor.
        let cursor = NSPoint(x: vf.midX, y: vf.midY)
        let pad = MacroPad()
        pad.onSummonChanged = { summonEvents.append($0) }
        pad.present(profiles: [profile], dark: true, screen: screen, hotkeyName: "test",
                    frontApp: front, at: cursor, onAction: { _, _ in })
        pump()
        guard let (panel, view) = panelFor(pad) else { print("NO PANEL"); finish() }
        print("1 summon from closed: \(frameStr(panel.frame)) cursor=(\(Int(cursor.x)),\(Int(cursor.y)))")
        check(pad.isSummoned, "1: isSummoned")
        check(summonEvents == [true], "1: onSummonChanged fired true once (\(summonEvents))")
        check(besideCursor(panel.frame, cursor), "1: pad beside the cursor, cursor outside it")
        check(panel.frame.width >= 200 && panel.frame.height > 100, "1: full pad, not a strip")
        check(view.buttonCount == 5, "1: five buttons rendered (\(view.buttonCount))")
        homeUnchanged("1", since: seeded, expectOpen: true)

        // 2: mouse-exit must NOT collapse a summoned pad (mini is preferred).
        let sizeBefore = panel.frame.size
        view.mouseExited(with: NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: -30, y: -30),
                                                  modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: panel.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1)!)
        pump()
        check(panel.frame.size == sizeBefore, "2: no collapse on mouse-exit while summoned")

        // 3: an app switch re-renders (an app with no profile = the short empty
        // pad) — the summoned TOP-LEFT must hold while the height changes.
        let f3 = panel.frame
        pad.frontmostChanged(bundleID: "com.example.other", name: "Other")
        pump()
        check(abs(panel.frame.minX - f3.minX) < 1 && abs(panel.frame.maxY - f3.maxY) < 1,
              "3: summoned top-left holds across an app switch (\(frameStr(panel.frame)))")
        pad.frontmostChanged(bundleID: profile.bundleID, name: profile.name)
        pump()

        // 4: dismiss — home untouched, open=false, summon cleared.
        pad.dismiss(); pump()
        check(!pad.isSummoned, "4: summon cleared on dismiss")
        check(summonEvents == [true, false], "4: onSummonChanged fired false (\(summonEvents))")
        homeUnchanged("4", since: seeded, expectOpen: false)

        // 5: normal open → must land on the mid-left berth as the strip.
        pad.present(profiles: [profile], dark: true, screen: screen, hotkeyName: "test",
                    frontApp: front, onAction: { _, _ in })
        pump()
        guard let (panel5, view5) = panelFor(pad) else { print("NO PANEL (5)"); finish() }
        print("5 normal open: \(frameStr(panel5.frame))")
        check(abs(panel5.frame.minX - (vf.minX + 12)) < 1 && panel5.frame.width < 60, "5: docked mid-left as a strip")
        check(!pad.isSummoned, "5: not summoned")
        let docked = saved()

        // 6: summon the DOCKED pad to a cursor → full pad beside it, berth intact.
        let cursor6 = NSPoint(x: vf.midX + 100, y: vf.midY - 80)
        pad.summon(to: cursor6, on: screen); pump()
        print("6 summon from dock: \(frameStr(panel5.frame))")
        check(pad.isSummoned && besideCursor(panel5.frame, cursor6), "6: full pad beside the cursor")
        check(panel5.frame.width >= 200, "6: full pad, not a strip")
        homeUnchanged("6", since: docked, expectOpen: true)

        // 7: header "–" while summoned = send it home (strip on the berth).
        func synth(_ type: NSEvent.EventType, at pView: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view5.convert(pView, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: panel5.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view5.mouseDown(with: synth(.leftMouseDown, at: NSPoint(x: 157, y: 21))); pump()
        print("7 after header –: \(frameStr(panel5.frame))")
        check(!pad.isSummoned, "7: summon ended by –")
        check(abs(panel5.frame.minX - (vf.minX + 12)) < 1 && panel5.frame.width < 60, "7: back on the mid-left berth as the strip")
        homeUnchanged("7", since: docked, expectOpen: true)

        // 8: summon again, then a REAL drag (mouseDown → dragged → up) to the
        // right half — the drag ends the summon and becomes the new placement;
        // a following app switch must not teleport it anywhere.
        pad.summon(to: cursor6, on: screen); pump()
        let grabView = NSPoint(x: 110, y: panel5.frame.height - 12)
        view5.mouseDown(with: synth(.leftMouseDown, at: grabView))
        let grabWin = view5.convert(grabView, to: nil)
        let target = NSPoint(x: vf.midX + 300, y: vf.midY - 200)
        let o = panel5.frame.origin
        let dragLoc = NSPoint(x: grabWin.x + target.x - o.x, y: grabWin.y + target.y - o.y)
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: dragLoc, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: panel5.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        view5.mouseDragged(with: drag); pump(0.1)
        view5.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: dragLoc, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel5.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: 1, pressure: 1)!)
        pump()
        print("8 after drag: \(frameStr(panel5.frame)) saved: \(describe(saved()))")
        check(!pad.isSummoned, "8: drag ended the summon")
        let f8 = panel5.frame
        let p8 = saved()
        check(p8?.anchor != .midLeft, "8: placement is no longer the mid-left berth (explicit drag wins)")
        pad.frontmostChanged(bundleID: "com.example.other", name: "Other"); pump()
        pad.frontmostChanged(bundleID: profile.bundleID, name: profile.name); pump()
        check(abs(panel5.frame.minX - f8.minX) < 1 && abs(panel5.frame.maxY - f8.maxY) < 1,
              "8: no teleport after an app switch (\(frameStr(panel5.frame)))")

        // 9: cursor in the bottom-right corner → pad flips left/up and stays on-screen.
        let corner = NSPoint(x: vf.maxX - 4, y: vf.minY + 4)
        pad.summon(to: corner, on: screen); pump()
        print("9 corner summon: \(frameStr(panel5.frame))")
        check(vf.contains(panel5.frame), "9: pad fully on-screen")
        check(!panel5.frame.contains(corner), "9: cursor outside the pad")
        pad.dismiss(); pump()

        // 10: FIRE-ONCE from a CLOSED pad — click button 1 → the macro fires
        // and the pad is gone again (it was closed before the summon).
        var fired: [String] = []
        pad.present(profiles: [profile], dark: true, screen: screen, hotkeyName: "test",
                    frontApp: front, at: cursor, onAction: { b, _ in fired.append(b.title) })
        pump()
        guard let (panel10, view10) = panelFor(pad) else { print("NO PANEL (10)"); finish() }
        func click(_ v: MacroPadView, _ p: NSPanel, at pView: NSPoint) {
            v.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: v.convert(pView, to: nil),
                                                 modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: p.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        click(view10, panel10, at: NSPoint(x: 110, y: 55))   // button 1 center (flipped view coords)
        pump(0.5)
        check(fired == ["Invoices"], "10: button fired (\(fired))")
        check(!pad.isVisible && !pad.isSummoned, "10: pad gone after the fire (it was closed before the summon)")
        check(saved()?.open == false, "10: saved open=false (\(describe(saved())))")

        // 11: FIRE-ONCE from a DOCKED pad — open normally (strip on the berth),
        // summon, click button 2 → the pad returns to the berth as the strip.
        pad.present(profiles: [profile], dark: true, screen: screen, hotkeyName: "test",
                    frontApp: front, onAction: { b, _ in fired.append(b.title) })
        pump()
        let dockedAgain = saved()
        pad.summon(to: cursor6, on: screen); pump()
        guard let (panel11, view11) = panelFor(pad) else { print("NO PANEL (11)"); finish() }
        check(pad.isSummoned && panel11.frame.width >= 200, "11: summoned full pad from the dock")
        click(view11, panel11, at: NSPoint(x: 110, y: 90))   // button 2 center
        pump(0.5)
        check(fired == ["Invoices", "Projects"], "11: second button fired (\(fired))")
        check(pad.isVisible && !pad.isSummoned, "11: pad still open, summon ended")
        // Home is whatever the record says — after step 8 that is the dragged
        // free-float spot, not the mid-left berth.
        let homeX = dockedAgain?.x ?? (vf.minX + 12)
        check(abs(panel11.frame.minX - homeX) < 1 && panel11.frame.width < 60,
              "11: back home as the strip (\(frameStr(panel11.frame)) vs home x=\(Int(homeX)))")
        homeUnchanged("11", since: dockedAgain, expectOpen: true)

        // 12: endSummon() (what plain Esc / click-away / a second tap call)
        // on a docked-then-summoned pad also returns it home, not away.
        pad.summon(to: cursor6, on: screen); pump()
        pad.endSummon(); pump()
        check(pad.isVisible && !pad.isSummoned && panel11.frame.width < 60, "12: endSummon on a borrowed pad sends it home")
        pad.dismiss(); pump()
        finish()
    }

case "cheatsheet-preview":
    // Offscreen render of the hold+Q hotkey cheat sheet.
    let out = args.count >= 2 ? args[1] : "cheatsheet-preview.png"
    let dark = !args.contains("light")
    MainActor.assumeIsolated {
        let v = HotkeyCheatSheetView(dark: dark, hotkeyName: "Option + Shift",
                                     connections: [(key: "N", name: "Todo")])
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "powerring-preview":
    // Offscreen render of the Power Ring (default slots, third slot hovered).
    let out = args.count >= 2 ? args[1] : "powerring-preview.png"
    let dark = !args.contains("light")
    MainActor.assumeIsolated {
        let actions: [PowerRing.Action] = PowerRingCatalog.defaultSlots.compactMap { id in
            PowerRingCatalog.entry(id).map { .init(glyph: $0.glyph, title: $0.title) {} }
        }
        let v = PowerRingView(actions: actions, dark: dark)
        v.frame = NSRect(origin: .zero, size: PowerRingView.canvas)
        v.previewState(hover: 2)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "trackpad-tap-test":
    // Probe for the three-finger-tap summon: runs the detector standalone (no
    // hotkey gating) and prints contact-count transitions + TAP lines, plus
    // every mouse-button event the system emits meanwhile through a pass-
    // through CGEventTap (Accessibility, which a trusted terminal passes
    // down) — so we can see whether Three-Finger Drag turns a quick tap into
    // a synthetic click, and whether that click lands before or after TAP.
    let seconds = args.count >= 2 ? Double(args[1]) ?? 20 : 20
    TapProbe.t0 = CFAbsoluteTimeGetCurrent()
    let probe = TrackpadTapDetector.probe()
    print("AXIsProcessTrusted: \(AXIsProcessTrusted())  MultitouchSupport: \(probe.available ? "loaded" : "MISSING")  devices: \(probe.devices)")
    let detector = TrackpadTapDetector()
    detector.onContactChange = { n in print("\(TapProbe.stamp())  contacts=\(n)") }
    detector.onTap = { print("\(TapProbe.stamp())  TAP (three-finger)") }
    detector.update(enabled: true)
    let probeMask: CGEventMask =
        (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
        | (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
    if let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: probeMask,
        callback: { _, type, event, _ in
            print(TapProbe.line(type: type, event: event))
            return Unmanaged.passUnretained(event)
        },
        userInfo: nil
    ) {
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    } else {
        print("mouse tap unavailable (this process isn't Accessibility-trusted) — contact log only")
    }
    print("listening \(Int(seconds))s — do: 3× three-finger tap · 3× with the hotkey held · a three-finger window drag")
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    detector.update(enabled: false)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    print("done")

case "dockoverlay-preview":
    // Offscreen render of the drag-time dock-target overlay (fake 1440x900
    // screen, pad held near the midLeft anchor → left-mid marker lit + ghost).
    let out = args.count >= 2 ? args[1] : "dockoverlay-preview.png"
    let dark = !args.contains("light")
    MainActor.assumeIsolated {
        let field = PadDock.Field(visible: NSRect(x: 0, y: 0, width: 1440, height: 862),
                                  notch: NSRect(x: 610, y: 862, width: 220, height: 38))
        let v = PadDockOverlayView()
        v.frame = field.canvas
        v.configure(field: field, padFrame: NSRect(x: 30, y: 320, width: 220, height: 202), dark: dark)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "notchstrip-live-test":
    // The notch strip, driven headlessly. The assertion that matters is the
    // CUTOUT one, and it is deliberately geometric rather than a screenshot:
    // `screencapture` reads the framebuffer, which faithfully contains the
    // pixels behind the camera housing that no human can ever see. A
    // screenshot-based check would pass on precisely the bug it exists to
    // catch — five marks were once drawn dead centre of the housing and looked
    // perfect in a capture.
    MainActor.assumeIsolated {
        // Shield BOTH state files: this test writes placement and config.
        let placementURL = Config.appSupportDir.appendingPathComponent("pad-placement.json")
        let placementBackup = try? Data(contentsOf: placementURL)
        func finish(_ code: Int32) -> Never {
            if let placementBackup { try? placementBackup.write(to: placementURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: placementURL) }
            exit(code)
        }
        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            print("\(ok ? "PASS" : "FAIL") — \(label)")
            if !ok { failures += 1 }
        }
        func pump(_ s: Double = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        guard let screen = NSScreen.screens.first(where: { PadDock.Field(screen: $0).hasNotch }) else {
            print("no notched display — the strip is only ever built on one, nothing to test")
            finish(0)
        }
        let field = PadDock.Field(screen: screen)
        print("housing \(Int(field.notch.minX))…\(Int(field.notch.maxX)) x \(Int(field.notch.minY))…\(Int(field.notch.maxY))")

        // Fake sources: counts are driven from here so the sweep can push the
        // layout well past its caps.
        var agentCount = 3
        var quotaOn = false
        var clicked: [(String, Int)] = []
        let strip = NotchStrip()
        strip.register(NotchStrip.Source(
            id: "agents", priority: 0, maxMarks: 5,
            marks: { (0..<agentCount).map { i in
                NotchStrip.Mark(color: .systemBlue, ring: i == 0, tooltip: "s\(i)") } },
            card: { i in NotchStrip.Card(title: "session \(i)", subtitle: "needs permission",
                                         accent: .systemOrange,
                                         actions: [("✓", .systemGreen, {}), ("✕", .systemRed, {})]) },
            activate: { clicked.append(("agents", $0)) }))
        strip.register(NotchStrip.Source(
            id: "quota", priority: 10, maxMarks: 1,
            marks: { quotaOn ? [NotchStrip.Mark(color: .systemOrange, tooltip: "82%")] : [] },
            card: { _ in NotchStrip.Card(title: "82% used", subtitle: "resets in 2h", accent: .systemOrange) },
            activate: { clicked.append(("quota", $0)) }))

        // 1: nothing to say ⇒ no pixels at all.
        agentCount = 0
        strip.apply(master: true, enabled: ["agents", "quota"])
        pump()
        check(!strip.isVisible, "1: zero marks ⇒ no window (no placeholder dot)")

        // 2: Min geometry.
        agentCount = 3
        strip.refresh(); pump(0.4)
        let minFrame = strip.frame
        check(strip.isVisible, "2a: marks ⇒ window")
        check(abs(minFrame.maxY - screen.frame.maxY) < 1, "2b: flush with the top of the screen")
        // Min is NOT centred: each shoulder is sized for its own cluster, so a
        // lopsided set of sources does not pay for empty plate on the quiet
        // side. What must hold is that the pill straddles the housing.
        check(minFrame.minX <= field.notch.minX + 1 && minFrame.maxX >= field.notch.maxX - 1,
              "2c: straddles the housing (\(Int(minFrame.minX))…\(Int(minFrame.maxX)))")
        check(minFrame.width < field.notch.width + 200,
              "2c2: no empty plate on a shoulder with nothing on it")
        check(minFrame.height <= field.notch.height + 1, "2d: Min fits inside the menu-bar band")

        // 3: THE cutout sweep — no drawn content may land behind the housing,
        // at any count, in any combination of sources, in either state.
        var worstOverlap = 0
        for on in [Set(["agents"]), Set(["quota"]), Set(["agents", "quota"])] {
            for n in 0...12 {
                agentCount = n
                quotaOn = on.contains("quota")
                strip.apply(master: true, enabled: on)
                // Outlast the 0.22s Min↔Mid morph: mid-animation `panel.frame`
                // is an in-flight value, so mapping view rects through it
                // reports positions the settled layout never occupies.
                pump(0.3)
                let bad = strip.contentRectsInScreen.filter { $0.intersects(field.notch) }
                worstOverlap += bad.count
                if !bad.isEmpty {
                    print("   overlap: sources=\(on.sorted()) agents=\(n) rects=\(bad.map { "\(Int($0.minX))…\(Int($0.maxX))" })")
                }
            }
        }
        check(worstOverlap == 0, "3: nothing drawn behind the housing across 39 layouts (Min)")

        // 4: Mid is CAPPED — the notch must never reach full-panel size.
        agentCount = 3
        quotaOn = true
        strip.apply(master: true, enabled: ["agents", "quota"])
        pump(0.1)
        strip.open(source: 0, mark: 0, hold: nil)
        pump(0.4)
        let mid = strip.frame
        let midCap = field.notch.width * NotchStrip.midWidthFactor
        let heightCap = field.notch.height + NotchStrip.midCardHeightWithActions
        check(mid.width <= midCap + 1, "4a: Mid width \(Int(mid.width)) within the \(Int(midCap))pt cap")
        check(mid.height <= heightCap + 1, "4b: Mid height \(Int(mid.height)) within the \(Int(heightCap))pt cap")
        check(abs(mid.maxY - screen.frame.maxY) < 1, "4c: Mid still hangs from the screen edge")
        check(abs(mid.midX - field.notch.midX) < 1, "4c2: Mid IS centred on the housing")
        let midBad = strip.contentRectsInScreen.filter { $0.intersects(field.notch) }
        check(midBad.isEmpty, "4d: Mid card content sits clear of the housing")
        check(strip.contentRectsInScreen.allSatisfy { $0.maxY <= field.notch.minY + 1 },
              "4e: Mid card content is entirely BELOW the housing")

        // 5: collapse returns to Min.
        strip.collapse(); pump(0.4)
        check(abs(strip.frame.height - minFrame.height) < 1, "5: collapse returns to Min height")

        // 6: click routing — synthesised against the real view, so hit-testing
        // and drawing are proven to read the same layout array.
        if let (panel, view) = strip.testSurface, let target = strip.placedMarks.last {
            let p = view.convert(NSPoint(x: target.rect.midX, y: target.rect.midY), to: nil)
            let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: panel.windowNumber, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 1)!
            view.mouseDown(with: ev)
            pump(0.1)
            let expected = target.source == 0 ? "agents" : "quota"
            check(clicked.last?.0 == expected && clicked.last?.1 == target.mark,
                  "6: click on the last mark routed to \(expected)[\(target.mark)] — got \(clicked.last.map { "\($0.0)[\($0.1)]" } ?? "nothing")")
        } else {
            check(false, "6: no surface to click")
        }

        // 7: master off ⇒ gone.
        strip.apply(master: false, enabled: ["agents", "quota"]); pump(0.2)
        check(!strip.isVisible, "7: master switch off ⇒ no window")

        // 8: berth migration, including idempotence.
        let fake: [String: [String: Any]] = [
            "agent": ["anchor": "notchLeft", "mini": true, "open": true, "x": 12, "y": 616],
            "macro": ["anchor": "midLeft", "mini": false, "open": false],
        ]
        try? JSONSerialization.data(withJSONObject: fake).write(to: placementURL, options: .atomic)
        let moved = PadPlacement.migrateNotchAnchors()
        let agent = PadPlacement.load("agent")
        let macro = PadPlacement.load("macro")
        check(moved == ["agent"], "8a: only the berthed pad moved")
        check(agent?.anchor == .topLeft, "8b: notchLeft → topLeft")
        check(agent?.mini == true && agent?.open == true, "8c: mini/open rode along")
        check(macro?.anchor == .midLeft, "8d: the other pad is untouched")
        let again = PadPlacement.migrateNotchAnchors()
        check(again.isEmpty, "8e: migration is idempotent")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        finish(failures == 0 ? 0 : 1)
    }

case "agentpad-preview":
    // Offscreen render of the Agent Pad for design checks (fake sessions in
    // every state; second row hovered). Flags: "light", "mini" (traffic strip).
    let out = args.count >= 2 ? args[1] : "agentpad-preview.png"
    let dark = !args.contains("light")
    let mini = args.contains("mini")
    MainActor.assumeIsolated {
        func fake(_ id: String, _ cwd: String, _ label: String, _ state: ClaudeSession.State,
                  _ detail: String, ageSec: Double,
                  branch: String = "", model: String = "", msgs: Int = 0, tokens: Int = 0) -> ClaudeSession {
            var s = ClaudeSession(id: id)
            s.cwd = cwd; s.label = label; s.state = state; s.detail = detail
            s.branch = branch; s.model = model; s.msgs = msgs; s.tokens = tokens
            s.stateChanged = Date().addingTimeInterval(-ageSec)
            return s
        }
        var codexRow = fake("codex-1", "/Users/dev/livevox", "Assess GridOps_Cal for refactors", .busy,
                            "Reading livevox/client.js", ageSec: 30, branch: "main", model: "GPT", msgs: 9, tokens: 14_100)
        codexRow.kind = "codex"
        var cursorRow = fake("cursor-1", "/dev/bees-bots-balance", "Chapter 2 improvements", .unseen, "cloud · ch02b-migrations", ageSec: 210)
        cursorRow.kind = "cursor"
        let sessions = AgentPad.triageSorted([
            fake("1", "/Users/dev/gridops-ft-kyaw", "Fix the daypart call columns rebuild", .busy,
                 "Editing css-report.js", ageSec: 45, branch: "fix/daypart-columns", model: "Sonnet", msgs: 41, tokens: 88_300),
            fake("2", "/Users/dev/grc-power-tools", "Snap points for macro and agent pads", .needsPermission,
                 "Bash: scripts/bundle.sh", ageSec: 12, branch: "main", model: "Opus", msgs: 28, tokens: 50_400),
            fake("3", "/Users/dev/libre-crm-cci", "I need to make a CRM for CCI", .idle,
                 "", ageSec: 300, branch: "feature/pipeline-sheet", model: "Opus", msgs: 12, tokens: 21_300),
            fake("4", "/Users/dev/grc-todo", "", .error, "rate_limit", ageSec: 660, branch: "main", model: "Haiku", msgs: 4, tokens: 900),
            fake("5", "/Users/dev/gridops-ft-njaw", "Reconcile the corr-index blanks", .idle,
                 "", ageSec: 90_000, branch: "main", model: "Sonnet", msgs: 133, tokens: 1_240_000),
            codexRow,
            cursorRow,
        ])
        let v = AgentPadView(dark: dark)
        v.configure(sessions: sessions, dark: dark, hotkeyName: "Option + Shift", hooksInstalled: true,
                    mini: mini)
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        if !mini { v.previewState(hoverRow: 2, hoverButton: nil) }
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "codex-scan-test":
    // Live verification: print the rows CodexWatcher derives from the REAL
    // ~/.codex store right now (title · state · age · cwd).
    let snaps = CodexWatcher.scan()
    for s in snaps {
        print("\(s.id)  state=\(s.state.label)  changed=\(Int(-s.changed.timeIntervalSinceNow))s ago  cwd=\(s.cwd)  title=\(s.title.isEmpty ? "(untitled)" : s.title)")
    }
    print("\(snaps.count) codex row(s)")

case "cursor-scan-test":
    // Live verification: print the rows CursorWatcher derives from the REAL
    // Cursor store right now.
    if let snaps = CursorWatcher.scan() {
        for s in snaps {
            print("\(s.id.prefix(40))  state=\(s.state.label)  changed=\(Int(-s.changed.timeIntervalSinceNow))s ago  cwd=\(s.cwd)  title=\(s.title)  detail=\(s.detail)")
        }
        print("\(snaps.count) cursor row(s)")
    } else {
        print("store unreadable (locked?)")
    }

case "usage-test":
    // Live verification: print the provider quota the Agent Pad header would
    // show right now, straight from the real CodexBar CLI. A read spawns a
    // Claude session to scrape /usage, so this takes ~45s.
    MainActor.assumeIsolated {
        guard let bin = UsageReader.binaryPath else {
            print("no codexbar binary found — the ◔ header button stays hidden")
            exit(1)
        }
        print("reader: \(bin)")
        let reader = UsageReader.shared
        let done = DispatchSemaphore(value: 0)
        reader.onUpdate = { done.signal() }
        reader.refreshIfStale()
        // The fetch is deliberately off the main actor; pump the runloop rather
        // than blocking it, or the completion never lands.
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if reader.providers.isEmpty {
            print("no providers reporting")
        }
        for p in reader.providers {
            print("\(p.name)\(p.plan.isEmpty ? "" : " · \(p.plan)")")
            for w in p.windows {
                print("    \(w.label)  \(w.usedPercent)%  \(w.resetDescription)")
            }
            if p.windows.isEmpty, !p.error.isEmpty { print("    error: \(p.error)") }
        }
        print("fetched \(reader.ageDescription)")
    }

case "agentpad-server-test":
    // Smoke-test the hook pipeline without the UI: start the loopback server +
    // registry, print session states as events arrive, exit after N seconds.
    // Feed it with: sh claude-hook.sh SessionStart <port> <<< '<payload json>'
    // or a direct curl to http://127.0.0.1:<port>/hook.
    let port = args.count >= 2 ? Int(args[1]) ?? 8377 : 8377
    let seconds = args.count >= 3 ? Double(args[2]) ?? 10 : 10
    MainActor.assumeIsolated {
        let registry = ClaudeSessionRegistry()
        let server = ClaudeHookServer()
        registry.onChange = { sessions in
            for s in sessions {
                print("SESSION \(s.id) project=\(s.projectName) tty=\(s.tty) state=\(s.state.label) detail=\(s.detail)")
            }
            print("---")
        }
        server.onEvent = { obj in MainActor.assumeIsolated { registry.ingest(obj) } }
        guard server.start(port: port) else { print("BIND FAILED on \(port)"); exit(1) }
        print("listening on 127.0.0.1:\(port) for \(Int(seconds))s")
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        print("done")
    }

case "claude-hooks":
    // claude-hooks install|remove|status [--settings <path>] [--port <n>]
    // Test/admin for the Agent Pad hook entries in ~/.claude/settings.json.
    var settingsURL = ClaudeHooksInstaller.defaultSettingsURL
    var port = Config.load().agentPadPort
    var rest = Array(args.dropFirst(2))
    while let flag = rest.first {
        if flag == "--settings", rest.count >= 2 { settingsURL = URL(fileURLWithPath: rest[1]); rest.removeFirst(2) }
        else if flag == "--port", rest.count >= 2, let p = Int(rest[1]) { port = p; rest.removeFirst(2) }
        else { rest.removeFirst() }
    }
    switch args.count > 1 ? args[1] : "" {
    case "install":
        do { print(try ClaudeHooksInstaller.install(port: port, settings: settingsURL)) }
        catch { print("install failed: \(error.localizedDescription)"); exit(1) }
    case "remove":
        do { print(try ClaudeHooksInstaller.remove(settings: settingsURL)) }
        catch { print("remove failed: \(error.localizedDescription)"); exit(1) }
    case "status":
        print(ClaudeHooksInstaller.isInstalled(settings: settingsURL)
            ? "installed (\(settingsURL.path))" : "not installed (\(settingsURL.path))")
    default:
        print("usage: claude-hooks install|remove|status [--settings path] [--port n]"); exit(1)
    }

case "doctor":
    let report = try! runBlocking { await Doctor.report() }
    print(report)

case "render-overlay":
    // Offscreen preview of the dictation pill for design checks.
    let out = args.count >= 2 ? args[1] : "overlay-preview.png"
    let dark = !(args.count >= 3 && args[2] == "light")
    let speaking = args.contains("speaking")
    let partial = args.contains("partial")
        ? "the field crew finished the meter exchange on Elm Street and headed"
        : nil
    MainActor.assumeIsolated {
        let content = OverlayPanel.buildContent(dark: dark, speaking: speaking, partial: partial)
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(1) }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out))
            print("wrote \(out)")
        }
    }

case "render-overlay-success":
    // Offscreen preview of the green Quick Capture confirmation.
    let out = args.count >= 2 ? args[1] : "overlay-success.png"
    let dark = !(args.count >= 3 && args[2] == "light")
    MainActor.assumeIsolated {
        let content = OverlayPanel.buildSuccessContent(dark: dark, text: "Captured  Buy potting soil")
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(1) }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "dict":
    let store = Store()
    switch args.count > 1 ? args[1] : "" {
    case "add":
        guard args.count >= 3 else { usage() }
        store.addDictTerm(args[2], misheard: args.count >= 4 ? args[3] : "")
        print("added: \(args[2])")
    case "rm":
        guard args.count >= 3 else { usage() }
        store.removeDictTerm(args[2])
        print("removed: \(args[2])")
    case "list":
        let entries = store.dictionary()
        if entries.isEmpty { print("(dictionary is empty — add terms with: grc-whisper dict add KYAW)") }
        for e in entries {
            print(e.misheard.isEmpty ? e.term : "\(e.term)  (misheard: \(e.misheard))")
        }
    default: usage()
    }

case "history":
    let n = args.count >= 2 ? Int(args[1]) ?? 10 : 10
    let store = Store()
    for entry in store.recentHistory(n) {
        print("[\(entry.timestamp)] \(entry.app)")
        print("  \(entry.polished)")
        if entry.polished != entry.raw { print("  (raw: \(entry.raw))") }
    }

case "strip-preview":
    // Live-render the ⌘Tab strip with REAL windows (exercises the SCK
    // thumbnail path), then save an offscreen PNG of the view.
    let out = args.count >= 2 ? args[1] : "strip-preview.png"
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var tiles: [SwitcherStrip.Tile] = []
        for w in list {
            guard tiles.count < 24,
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) >= 120, (b["Height"] ?? 0) >= 90,
                  let wid = w[kCGWindowNumber as String] as? Int,
                  let running = NSRunningApplication(processIdentifier: pid),
                  running.bundleIdentifier != "com.grc.whisper" else { continue }
            let title = (w[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? running.localizedName ?? ""
            tiles.append(SwitcherStrip.Tile(pid: pid, windowID: CGWindowID(wid), title: title, icon: running.icon))
        }
        guard tiles.count >= 2 else { print("NOT ENOUGH WINDOWS (\(tiles.count))"); exit(1) }
        if args.contains("repeat") {  // exercise multi-row wrapping in the preview
            while tiles.count < 18 { tiles += tiles }
            tiles = Array(tiles.prefix(18))
        }
        let strip = SwitcherStrip()
        strip.present(tiles: tiles, highlight: 1, dark: false)
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))  // let SCK captures land
        // Render the strip's content view offscreen.
        guard let panel = NSApp.windows.first(where: { $0.contentView is SwitcherStripView }),
              let v = panel.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { print("NO STRIP VIEW"); exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        strip.dismiss()
        print("wrote \(out) (\(tiles.count) tiles)")
    }

case "capture-parse":
    // grc-whisper capture-parse "<text>" — test the inline field parser.
    guard args.count >= 2 else { print("usage: capture-parse \"text\""); exit(1) }
    let p = CaptureParse.parse(args.dropFirst().joined(separator: " "))
    print("title:    \(p.title)")
    print("priority: \(p.priority.isEmpty ? "(none)" : p.priority)")
    print("due:      \(p.due.isEmpty ? "(none)" : p.due)")
    print("context:  \(p.context.isEmpty ? "(none)" : p.context)")

case "newdoc":
    // grc-whisper newdoc <word|excel|text|rtf|markdown> <folder> — test doc creation.
    guard args.count >= 3, let type = NewDocTemplates.DocType.allCases.first(where: { $0.ext == args[1] || $0.rawValue.lowercased().hasPrefix(args[1].lowercased()) }) else {
        print("usage: newdoc <word|excel|text|rtf|markdown> <folder>"); exit(1)
    }
    do {
        let url = try NewDocTemplates.create(type, in: URL(fileURLWithPath: args[2], isDirectory: true))
        print("created \(url.path)")
    } catch {
        print("failed: \(error)"); exit(1)
    }

case "layout":
    // grc-whisper layout save|list|restore [id]  — test/admin for saved layouts.
    let store = Store()
    switch args.count > 1 ? args[1] : "" {
    case "save":
        let items = WindowLayouts.snapshot()
        let f = DateFormatter()
        f.dateFormat = "MMM d · h:mm a"
        store.addLayout(name: args.count > 2 ? args[2] : f.string(from: Date()), json: WindowLayouts.encode(items))
        print("saved \(items.count) windows")
    case "list":
        for l in store.layouts() {
            print("\(l.id)  \(l.name)  \(WindowLayouts.decode(l.json).count) windows  [\(l.timestamp)]")
        }
    case "restore":
        let all = store.layouts()
        let target = args.count > 2 ? all.first(where: { String($0.id) == args[2] }) : all.first
        guard let target else { print("no such layout"); exit(1) }
        let r = WindowLayouts.restore(WindowLayouts.decode(target.json))
        print("restored \(r.restored) of \(r.total)")
    default:
        print("usage: layout save [name] | list | restore [id]"); exit(1)
    }

default:
    usage()
}
