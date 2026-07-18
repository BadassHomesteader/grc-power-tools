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

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    grc-whisper — fully-local voice dictation (hold a key, speak, release)

    usage:
      grc-whisper                     run the menu-bar app
      grc-whisper transcribe <file>   transcribe an audio file (engine test)
      grc-whisper polish <text>       run the cleanup pipeline on text (LLM test)
      grc-whisper doctor              check permissions and on-device models
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
    do {
        let started = Date()
        let text = try runBlocking { try await transcribeFile(url: url, locale: locale) }
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
        let front = NSWorkspace.shared.frontmostApplication
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
        let overlayUp = app.windows.contains { $0.ignoresMouseEvents && $0.frame == vf }
        print("14 mid-drag: overlay \(overlayUp ? "VISIBLE" : "MISSING (expected VISIBLE)")")
        view.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: dragLoc,
                                              modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: panel.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1)!)
        pump()
        report("15 dropped near midLeft via real drag path (expect snap to x=12)")
        let overlayGone = !app.windows.contains { $0.ignoresMouseEvents && $0.frame == vf && $0.isVisible }
        print("16 after drop: overlay \(overlayGone ? "hidden" : "STILL UP (expected hidden)")")

        // 17: restart simulation — a FRESH MacroPad instance must restore the
        // left dock from pad-placement.json.
        pad.dismiss(); pump()
        let pad2 = MacroPad()
        pad2.present(profiles: [profile], dark: true, screen: screen, hotkeyName: "test",
                     frontApp: front, onAction: { _, _ in })
        pump()
        if let panel2 = app.windows.compactMap({ $0 as? NSPanel })
            .first(where: { $0.contentView is MacroPadView && $0.isVisible }) {
            let f = panel2.frame
            let side = f.midX < vf.midX ? "LEFT" : "RIGHT"
            print("17 fresh instance after restart: origin=(\(Int(f.minX)),\(Int(f.minY))) \(side) (expect LEFT dock x=12)")
        } else {
            print("17 fresh instance: NO PANEL")
        }
        pad2.dismiss()
        finish(0)
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

case "permissiontoast-preview":
    // Offscreen render of a permission toast card.
    let out = args.count >= 2 ? args[1] : "permissiontoast-preview.png"
    let dark = !args.contains("light")
    MainActor.assumeIsolated {
        var s = ClaudeSession(id: "prev")
        s.cwd = "/Users/dev/grc-power-tools"
        s.label = "Ship the Power Ring release"
        s.state = .needsPermission
        s.detail = "Bash: scripts/bundle.sh --install && git push origin main"
        let v = PermissionToastView(session: s, dark: dark)
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "dockoverlay-preview":
    // Offscreen render of the drag-time dock-target overlay (fake 1440x900
    // screen, pad held near the midLeft anchor → left-mid marker lit + ghost).
    let out = args.count >= 2 ? args[1] : "dockoverlay-preview.png"
    let dark = !args.contains("light")
    MainActor.assumeIsolated {
        let vf = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let v = PadDockOverlayView()
        v.frame = vf
        v.configure(vf: vf, padFrame: NSRect(x: 30, y: 320, width: 220, height: 202), dark: dark)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "agentpad-preview":
    // Offscreen render of the Agent Pad for design checks (fake sessions in
    // every state; second row hovered). Flags: "light", "mini" (traffic strip).
    let out = args.count >= 2 ? args[1] : "agentpad-preview.png"
    let dark = !args.contains("light")
    let mini = args.contains("mini")
    MainActor.assumeIsolated {
        func fake(_ id: String, _ cwd: String, _ label: String, _ state: ClaudeSession.State,
                  _ detail: String, ageSec: Double) -> ClaudeSession {
            var s = ClaudeSession(id: id)
            s.cwd = cwd; s.label = label; s.state = state; s.detail = detail
            s.stateChanged = Date().addingTimeInterval(-ageSec)
            return s
        }
        var codexRow = fake("codex-1", "/Users/dev/livevox", "Assess GridOps_Cal for refactors", .busy, "", ageSec: 30)
        codexRow.kind = "codex"
        let sessions = AgentPad.triageSorted([
            fake("1", "/Users/dev/gridops-ft-kyaw", "Fix the daypart call columns rebuild", .busy, "", ageSec: 45),
            fake("2", "/Users/dev/grc-power-tools", "Review macropad idea for Power Tools", .needsPermission, "Bash: scripts/bundle.sh", ageSec: 12),
            fake("3", "/Users/dev/libre-crm-cci", "I need to make a CRM for CCI", .idle, "", ageSec: 300),
            fake("4", "/Users/dev/grc-todo", "", .error, "rate_limit", ageSec: 660),
            fake("5", "/Users/dev/gridops-ft-njaw", "Reconcile the corr-index blanks", .idle, "", ageSec: 90_000),
            codexRow,
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
    MainActor.assumeIsolated {
        let content = OverlayPanel.buildContent(dark: dark, speaking: speaking)
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
