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
    // settings-preview [out.png] [light|dark] [tabIndex]
    MainActor.assumeIsolated {
        var cfg = Config.load()
        if args.count >= 3, args[2] == "light" { cfg.appearance = .light }
        if args.count >= 3, args[2] == "dark" { cfg.appearance = .dark }
        let sc = SettingsWindowController(store: Store(), config: cfg, onConfigChange: { _ in })
        if args.count >= 4, let tab = Int(args[3]) { sc.selectTab(tab) }
        guard let window = sc.window else { exit(1) }
        window.setContentSize(NSSize(width: 660, height: 640))
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

case "advpaste-preview":
    let out = args.count >= 2 ? args[1] : "advpaste-preview.png"
    let dark = !(args.count >= 3 && args[2] == "light")
    MainActor.assumeIsolated {
        let v = AdvancedPasteView(clipboard: "The quarterly report shows revenue up 12% with strong enterprise growth and a healthy pipeline for Q3.", dark: dark)
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)") }
    }

case "advancedpaste-preview":
    let out = args.count >= 2 ? args[1] : "ap.png"
    let dark = !(args.count >= 3 && args[2] == "light")
    MainActor.assumeIsolated {
        let v = AdvancedPasteView(clipboard: "The quarterly numbers came in and honestly they look rough compared to last year, we should regroup.", dark: dark)
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
    }

case "quickcapture-preview":
    let out = args.count >= 2 ? args[1] : "quickcapture-preview.png"
    let dark = !(args.count >= 3 && args[2] == "light")
    MainActor.assumeIsolated {
        let v = QuickCaptureView(dark: dark, prefill: "Email the Q3 vendor list to Dana")
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        v.layoutSubtreeIfNeeded()  // the input field is Auto Layout; realize it before caching
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
        }
    }

case "findmouse-preview":
    let out = args.count >= 2 ? args[1] : "fm.png"
    MainActor.assumeIsolated {
        let v = FindMouseView()
        v.frame = NSRect(x: 0, y: 0, width: 1000, height: 680)
        v.point = NSPoint(x: 600, y: 400); v.alpha = 1; v.converge = 0.55
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)); print("wrote \(out)")
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

default:
    usage()
}
