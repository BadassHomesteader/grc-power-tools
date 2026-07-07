import Foundation
import AppKit
import CoreGraphics

/// Glue for the dictation state machine: idle -> recording -> processing -> idle.
///
/// Every async continuation is guarded by a generation counter (`cycle`): stale
/// completions from a previous dictation cycle must never mutate the current one.
@MainActor
final class AppController {
    enum State { case idle, recording, processing }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?
    var lastTranscript: String = ""
    /// Live-mutable: the menu updates polish mode without a relaunch.
    var config: Config {
        didSet {
            overlay.anchor = config.overlayPosition
            overlay.scheme = config.appearance
            chat?.updateConfig(config)
            clipboardWatcher.enabled = config.clipboardHistory
            hotkey?.lastWindowSwitch = config.lastWindowSwitch
        }
    }

    let store: Store
    private let audio: AudioCapture
    private let polisher: Polisher
    private let overlay = OverlayPanel()
    private let gridOverlay = GridOverlay()
    private let snapAssist = SnapAssist()
    private let advancedPaste = AdvancedPaste()
    private let quickCapture = QuickCapture()
    private let findMouse = FindMouse()
    private let windowPalette = WindowPalette()
    private let clipboardPalette = ClipboardPalette()
    private let windowSwitcher = WindowSwitcher()
    private lazy var clipboardWatcher = ClipboardHistory(store: store, enabled: config.clipboardHistory)
    private var hotkey: HotkeyMonitor?
    private var chat: ChatWindowController?

    private var cycle = 0
    /// File "cut" is Copy now + Move-on-next-paste (macOS has no real file cut).
    private var fileCutPending = false
    /// Window-organizer cycle state: repeated same-direction taps shrink the window.
    private var winLastMove: WindowManager.Move?
    private var winStep = 0
    private static let winFractions: [CGFloat] = [0.5, 1.0 / 3.0, 2.0 / 3.0]
    /// Chained-snap state within one leader hold: the horizontal and vertical
    /// constraints applied so far, so ← then ↑ lands the top-left corner
    /// (Moom-style chaining) instead of the second press replacing the first.
    private var chainH: (edge: WindowManager.Edge, f: CGFloat, label: String)?
    private var chainV: (edge: WindowManager.Edge, f: CGFloat, label: String)?
    /// After an edge snap, the empty region to offer Snap Assist for (on release).
    private var snapAssistRegion: CGRect?
    private var snapAssistExcludeWID: CGWindowID?
    private var utterance: AppleSpeechUtterance?
    private var startTask: Task<Void, Error>?
    private var context: ContextSnapshot?
    private var recordingStarted: Date?
    private var maxUtteranceTimer: Timer?
    /// True when this dictation cycle should fill the open Quick Capture panel
    /// instead of pasting into another app.
    private var dictatingIntoCapture = false

    init(config: Config, store: Store) {
        self.config = config
        self.store = store
        self.audio = AudioCapture(preRollSeconds: config.preRollSeconds)
        self.polisher = Polisher(store: store)
    }

    func start() async throws {
        overlay.anchor = config.overlayPosition
        overlay.scheme = config.appearance
        guard await AudioCapture.requestMicPermission() else {
            throw NSError(domain: "GRCWhisper", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        }
        try await AppleSpeechUtterance.ensureAssets(locale: Locale(identifier: config.localeIdentifier))
        try audio.start()
        audio.onLevels = { [weak self] levels in
            Task { @MainActor in self?.overlay.setLevels(levels) }
        }

        let monitor = HotkeyMonitor(hotkey: config.hotkey)
        monitor.lastWindowSwitch = config.lastWindowSwitch
        monitor.handler = { [weak self] event in
            guard let self else { return }
            switch event {
            case .down: self.keyDown()
            case .up(let cmd): self.keyUp(ai: cmd == .ai)
            case .cancel: self.cancel()
            case .ocr:
                self.interruptDictation()
                self.captureScreenText()
            case .screenshot:
                self.interruptDictation()
                self.captureScreenshot(search: false)
            case .search:
                self.interruptDictation()
                self.captureScreenshot(search: true)
            case .fileCopy:
                self.interruptDictation()
                self.fileClipboard(.copy)
            case .fileCut:
                self.interruptDictation()
                self.fileClipboard(.cut)
            case .filePaste:
                self.interruptDictation()
                self.fileClipboard(.paste)
            case .window(let move):
                // While the leader is held the tap swallows arrows/Return, so the
                // palette (if open) gets them forwarded here instead of snapping.
                if self.windowPalette.isVisible { self.windowPalette.leaderKey(move) }
                else { self.handleWindow(move) }
            case .windowEnd:
                self.overlay.hide()
                self.maybeSnapAssist()
            case .grid:
                // "3" is the grid chord — but with the palette open it's the
                // palette's Right ½ digit, not a second overlay.
                if self.windowPalette.isVisible { self.windowPalette.applyDigit("3") }
                else { self.openGrid() }
            case .windowPalette:
                self.openWindowPalette()
            case .advancedPaste:
                self.openAdvancedPaste()
            case .quickCapture:
                self.openQuickCapture()
            case .clipboardHistory:
                self.openClipboardHistory()
            case .cycleWindow(let back):
                self.windowSwitcher.cycle(back: back)
            case .cycleEnd:
                self.windowSwitcher.endCycle()
            case .findMouse:
                self.interruptDictation()
                self.findMouse.flash()
            }
        }
        guard monitor.start() else {
            throw NSError(domain: "GRCWhisper", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't install the global hotkey — grant Accessibility permission and relaunch"])
        }
        hotkey = monitor
        clipboardWatcher.start()
        windowSwitcher.start()
        log("controller: ready (hotkey \(config.hotkey.displayName), polish \(config.polish.rawValue))")
    }

    // MARK: Key events

    private func keyDown() {
        guard state == .idle else { return }
        winLastMove = nil; winStep = 0   // fresh window-cycle each hold
        chainH = nil; chainV = nil       // fresh chain each hold
        snapAssistRegion = nil; snapAssistExcludeWID = nil
        let ctx = ContextSnapshot.capture()
        if ctx.isSecureField {
            overlay.showError("Secure input field — can't dictate here")
            return
        }
        if ctx.bundleID == "com.grc.whisper" {
            // Exception: dictate INTO the Quick Capture panel when it's open,
            // rather than refusing (normal dictation pastes into another app).
            guard quickCapture.isVisible else {
                overlay.showError("Click into another app first, then hold to dictate")
                return
            }
            dictatingIntoCapture = true
        } else {
            dictatingIntoCapture = false
        }
        cycle += 1
        let gen = cycle
        context = ctx
        state = .recording
        onStateChange?(.recording)
        recordingStarted = Date()
        overlay.showRecording()
        if config.polish == .apple { polisher.prewarm() }

        guard let format = audio.currentFormat, format.sampleRate > 0 else {
            fail("No audio input device")
            return
        }

        // From this instant, nothing captured may be dropped — the analyzer may
        // still be starting when the user finishes a short utterance.
        audio.beginHold()

        let utt = AppleSpeechUtterance(locale: Locale(identifier: config.localeIdentifier))
        utt.onPartial = { [weak self] text in
            Task { @MainActor in
                guard let self, self.cycle == gen, self.state == .recording else { return }
                self.overlay.showPartial(text)
            }
        }
        utterance = utt

        let st = Task.detached { try await utt.start() }
        startTask = st

        maxUtteranceTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.maxUtteranceSeconds),
                                                 repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.cycle == gen, self.state == .recording else { return }
                log("controller: max utterance reached, finishing")
                self.keyUp(ai: false)
            }
        }

        Task { @MainActor in
            do {
                try await st.value
                guard self.cycle == gen, self.state == .recording else { return } // keyUp path takes over
                self.audio.beginRecording { buffer in utt.feed(buffer) }
            } catch {
                guard self.cycle == gen else { return }
                self.fail("Speech engine failed: \(error.localizedDescription)")
            }
        }
    }

    private func keyUp(ai: Bool = false) {
        guard state == .recording, let utt = utterance else { return }
        maxUtteranceTimer?.invalidate()
        let gen = cycle
        let heldMs = Int((Date().timeIntervalSince(recordingStarted ?? Date())) * 1000)
        let st = startTask

        if heldMs < config.minHoldMs {
            // Accidental tap.
            audio.endRecording()
            utterance = nil
            overlay.hide()
            finishCycle()
            Task.detached { try? await st?.value; await utt.cancel() }
            return
        }

        // Stop live feed only if streaming already began; in the raced case the
        // whole utterance still sits in the held ring and is flushed below.
        if audio.isStreaming { audio.endRecording() }

        state = .processing
        onStateChange?(.processing)
        overlay.showProcessing()
        let ctx = context
        let cfg = config

        Task { @MainActor in
            do {
                if let st { try await st.value }
            } catch {
                guard self.cycle == gen else { return }
                self.audio.endRecording()
                self.utterance = nil
                self.fail("Speech engine failed: \(error.localizedDescription)")
                return
            }
            guard self.cycle == gen else { return }

            // Race window: the key was released before the analyzer finished
            // starting, so beginRecording never ran. Flush the ring now and give
            // the audio queue a beat to drain into the analyzer.
            if !self.audio.isStreaming {
                self.audio.beginRecording { buffer in utt.feed(buffer) }
                try? await Task.sleep(nanoseconds: 200_000_000)
                self.audio.endRecording()
            }
            guard self.cycle == gen else { return }

            do {
                let raw = try await utt.finish()
                guard self.cycle == gen else { return }
                self.utterance = nil
                guard !raw.isEmpty else {
                    self.overlay.showError("Didn't catch that")
                    self.finishCycle()
                    return
                }
                let appName = ctx?.appName ?? "unknown"
                if ai {
                    // AI leader opens Claude with what you said (never pastes a cleanup).
                    guard self.cycle == gen else { return }
                    self.overlay.hide()
                    if self.config.aiChatMode == .browser {
                        ClaudeWeb.open(raw)
                    } else {
                        self.openChat(with: raw)
                    }
                    self.finishCycle()
                    return
                }
                let final = await self.polisher.polish(raw, config: cfg, appName: appName)
                guard self.cycle == gen else { return }
                self.deliver(raw: raw, polished: final, durationMs: heldMs, ctx: ctx)
            } catch {
                guard self.cycle == gen else { return }
                self.utterance = nil
                self.fail("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func deliver(raw: String, polished: String, durationMs: Int, ctx: ContextSnapshot?) {
        lastTranscript = polished
        store.addHistory(app: ctx?.bundleID ?? "", raw: raw, polished: polished, durationMs: durationMs)
        if dictatingIntoCapture {
            if quickCapture.isVisible {
                quickCapture.insertTranscript(polished)
                overlay.hide()   // the text is now visible in the panel; no paste toast
            } else {
                // Panel closed mid-dictation — don't paste into a random app; keep the text.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(polished, forType: .string)
                overlay.showError("Quick Capture closed — dictation copied to clipboard")
            }
            finishCycle()
            return
        }
        do {
            try Inserter.insert(polished, restoreDelayMs: config.clipboardRestoreDelayMs)
            overlay.showResult(polished)
        } catch {
            // Leave the text on the clipboard as a consolation so nothing is lost.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(polished, forType: .string)
            overlay.showError("\(error.localizedDescription) — copied to clipboard instead")
        }
        finishCycle()
    }

    /// Drop any in-flight dictation before a non-dictation leader action, so its
    /// transcript never lands: cancel a live recording, OR invalidate a cycle that's
    /// already .processing (finishCycle bumps `cycle`, so the pending deliver's
    /// `guard cycle == gen` fails and nothing is pasted).
    private func interruptDictation() {
        if state == .recording { cancel() }
        else if state == .processing { finishCycle() }
    }

    /// Cancel only interrupts an active recording (Esc / foreign keypress / stale
    /// hold). A cycle already in .processing is protected by the finish watchdog.
    private func cancel() {
        guard state == .recording else { return }
        maxUtteranceTimer?.invalidate()
        audio.endRecording()
        let utt = utterance
        let st = startTask
        utterance = nil
        overlay.hide()
        finishCycle()
        if let utt {
            Task.detached { try? await st?.value; await utt.cancel() }
        }
    }

    private func fail(_ message: String) {
        log("controller: \(message)")
        maxUtteranceTimer?.invalidate()
        audio.endRecording()
        utterance = nil
        overlay.showError(message)
        finishCycle()
    }

    /// OCR flow: let the user select a screen region, recognize text on-device,
    /// and paste it at the cursor (reuses the dictation paste + overlay).
    /// Screen recording is required for all screen grabs (the app is the
    /// responsible process even though the system tool captures). Prompt + open
    /// the pane if missing; the grant needs a quit & reopen to take effect.
    private func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        overlay.showError("Turn on Screen Recording for Power Tools, then quit & reopen the app")
        return false
    }

    private static func putImageOnClipboard(_ png: Data) {
        let pb = NSPasteboard.general
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.clearContents()
        pb.writeObjects([item])
    }

    /// hold + T: OCR a screen region to the clipboard (tab-separated if it's a table).
    func captureScreenText() {
        guard state == .idle, ensureScreenRecording() else { return }
        state = .processing
        onStateChange?(.processing)
        Task {
            let png = await ScreenCapture.grabRegionPNG()
            await MainActor.run {
                defer { self.finishCycle() }
                guard let png else { return } // cancelled
                let text = ScreenCapture.ocr(png).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { self.overlay.showError("No text found in the selection"); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                let preview = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
                let short = preview.count > 60 ? String(preview.prefix(57)) + "…" : preview
                self.overlay.showResult("Copied to clipboard · \(short)")
                self.store.addHistory(app: "screen-ocr", raw: text, polished: text, durationMs: 0)
            }
        }
    }

    /// hold + S: copy a screen region as an image. hold + G: same, then open
    /// Google Lens for you to paste (⌘V) — we don't upload the image ourselves,
    /// so it only leaves your Mac when you choose to paste it into Google.
    func captureScreenshot(search: Bool) {
        guard state == .idle, ensureScreenRecording() else { return }
        state = .processing
        onStateChange?(.processing)
        overlay.showProcessing()
        Task {
            guard let png = await ScreenCapture.grabRegionPNG() else {
                await MainActor.run { self.finishCycle() }
                return
            }
            await MainActor.run {
                defer { self.finishCycle() }
                AppController.putImageOnClipboard(png)
                if search {
                    if let url = URL(string: "https://lens.google.com/") {
                        NSWorkspace.shared.open(url)
                    }
                    self.overlay.showResult("Image copied — press ⌘V in Google Lens to search")
                } else {
                    self.overlay.showResult("Screenshot copied to clipboard")
                }
            }
        }
    }

    /// hold + P: transform the clipboard text before pasting. Capture the clipboard
    /// + target app NOW (before the palette steals focus), then paste into the app.
    private func openAdvancedPaste() {
        interruptDictation()
        overlay.hide()
        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clip.isEmpty else { overlay.showError("Copy some text first, then hold + P"); return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != "com.grc.whisper" else {
            overlay.showError("Click into a text field first, then hold + P"); return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        advancedPaste.present(
            clipboard: clip, dark: config.appearance.isDark, screen: screen,
            onPick: { t in self.applyAdvancedPaste(t, clip: clip, app: app) },
            onCancel: { app.activate() }
        )
    }

    private func applyAdvancedPaste(_ t: AdvancedPaste.Transform, clip: String, app: NSRunningApplication) {
        func paste(_ text: String) {
            app.activate()
            // let focus land in the target field before the synthetic ⌘V
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(220)) {
                try? Inserter.insert(text, restoreDelayMs: self.config.clipboardRestoreDelayMs)
            }
        }
        guard t.ai, let instruction = t.instruction else { paste(clip); return }  // plain text
        guard let key = Keychain.get("claude"), !key.isEmpty else {
            overlay.showError("Add a Claude key in Settings ▸ AI to use AI paste"); app.activate(); return
        }
        overlay.showProcessing()
        let model = config.claudeModel
        Task {
            do {
                let out = try await CloudPolish.claude(instructions: instruction, prompt: clip, model: model, apiKey: key)
                await MainActor.run { self.overlay.hide(); paste(out) }
            } catch {
                await MainActor.run { self.overlay.showError("Paste transform failed"); app.activate() }
            }
        }
    }

    /// hold + N: Quick Capture. Open a small input panel; the typed/dictated line
    /// is POSTed to the user's configured connection (Config.capture*). No endpoint
    /// set → a hint toast. The frontmost app is remembered so focus returns to it.
    private func openQuickCapture() {
        interruptDictation()
        overlay.hide()
        let endpoint = config.captureEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else {
            overlay.showError("Set up Quick Capture in Settings ▸ Connections")
            return
        }
        let priorApp = NSWorkspace.shared.frontmostApplication
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        quickCapture.present(
            dark: config.appearance.isDark, screen: screen,
            onSubmit: { text in self.sendCapture(text, endpoint: endpoint, restore: priorApp) },
            onCancel: { priorApp?.activate() }
        )
    }

    /// POST the captured text. On success, a brief toast and focus returns to the
    /// app you were in. On failure, re-open the panel pre-filled so the text isn't
    /// lost — no automatic retry (the endpoint has no idempotency key).
    private func sendCapture(_ text: String, endpoint: String, restore: NSRunningApplication?) {
        let header = config.captureAuthHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = Keychain.get("capture") ?? ""
        let template = config.captureBodyTemplate
        overlay.showProcessing()
        Task {
            do {
                try await CloudPolish.postCapture(text: text, endpoint: endpoint, header: header,
                                                  token: token, bodyTemplate: template)
                await MainActor.run { self.overlay.showSuccess("Captured  \(text)"); restore?.activate() }
            } catch {
                await MainActor.run {
                    self.overlay.showError("Quick Capture failed — check Settings ▸ Connections")
                    let mouse = NSEvent.mouseLocation
                    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
                    if let screen {
                        self.quickCapture.present(
                            dark: self.config.appearance.isDark, screen: screen, prefill: text,
                            onSubmit: { t in self.sendCapture(t, endpoint: endpoint, restore: restore) },
                            onCancel: { restore?.activate() }
                        )
                    }
                }
            }
        }
    }

    /// hold + H: clipboard history palette. Capture the target app NOW (before the
    /// palette steals focus); the picked clip pastes there and stays on the
    /// clipboard (Win+V semantics).
    private func openClipboardHistory() {
        interruptDictation()
        overlay.hide()
        guard config.clipboardHistory else {
            overlay.showError("Clipboard history is off — enable it in Settings ▸ General")
            return
        }
        let clips = store.recentClips(9)
        guard !clips.isEmpty else {
            overlay.showError("No clipboard history yet — copy something first")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != "com.grc.whisper" else {
            overlay.showError("Click into a text field first, then hold + H")
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        clipboardPalette.present(
            clips: clips, dark: config.appearance.isDark, screen: screen,
            onPick: { clip in
                app.activate()
                // let focus land back in the target field before the synthetic ⌘V
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(220)) {
                    if let png = clip.image {
                        Inserter.pasteImageLeavingOnClipboard(png)
                        self.store.addImageClip(png, label: clip.content)  // moves to the top
                    } else {
                        Inserter.pasteLeavingOnClipboard(clip.content)
                        self.store.addClip(clip.content)
                    }
                }
            },
            onCancel: { app.activate() }
        )
    }

    enum FileOp { case copy, cut, paste }

    /// hold + C / X / V: copy, cut (copy + mark for move), or paste files. Paste is a
    /// Finder "Move Item Here" (⌥⌘V) if the last action was a cut, else a plain ⌘V.
    /// A short delay lets the physical hotkey modifiers lift before we synthesize.
    /// hotkey + 3: capture the front window NOW (before the grid steals focus),
    /// then show a full-screen grid to draw where it goes.
    private func openGrid() {
        interruptDictation()
        overlay.hide()
        snapAssistRegion = nil; snapAssistExcludeWID = nil  // the grid replaces snap-assist for this hold
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != "com.grc.whisper",
              let window = WindowManager.frontmostWindow() else {
            overlay.showError("Click into a window first, then hold + 3")
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        gridOverlay.present(
            screen: screen, cols: config.gridSize.cols, rows: config.gridSize.rows,
            dark: config.appearance.isDark,
            snap: { rect in WindowManager.setWindow(window, cocoaFrame: rect) },
            done: { app.activate() }
        )
    }

    /// hold + W: Moom-style snap palette — Fill/halves (⌥ quarters), thirds, and a
    /// mini-grid. Capture the front window NOW, before the palette steals focus.
    private func openWindowPalette() {
        interruptDictation()
        overlay.hide()
        snapAssistRegion = nil; snapAssistExcludeWID = nil  // the palette replaces snap-assist for this hold
        guard config.windowPalette else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != "com.grc.whisper",
              let target = WindowManager.frontmostWindow() else {
            overlay.showError("Click into a window first, then hold + W")
            return
        }
        guard let screen = WindowManager.screen(of: target) ?? NSScreen.main else { return }
        windowPalette.present(
            dark: config.appearance.isDark,
            gridCols: config.gridSize.cols, gridRows: config.gridSize.rows,
            target: target, screen: screen,
            done: { app.activate() }
        )
    }

    /// Arrow/Return in window mode. Fires on each keydown; repeating the same
    /// direction cycles the size (½ → ⅓ → ⅔) so "tap ← ←" shrinks the left snap.
    private func handleWindow(_ move: WindowManager.Move) {
        interruptDictation()
        if move == .maximize {
            winLastMove = nil; winStep = 0; snapAssistRegion = nil  // no empty space to fill
            chainH = nil; chainV = nil
            if WindowManager.maximize() {
                overlay.showWindow(region: CGRect(x: 0, y: 0, width: 1, height: 1), label: "Maximize")
            } else { overlay.showError("No window to move") }
            return
        }
        let steps = config.snapSizes.steps
        if move == winLastMove {
            let next = (winStep + 1) % steps.count
            // Chained-corner unwind: cycling the same arrow past its last size
            // clears that axis and returns to the other axis's plain snap
            // (← ↑↑↑… goes ¼ → ⅓ → ⅔ → … → full-height Left ½ → ¼ …), so a
            // chain always cycles back out instead of trapping the window.
            let isVertical = (move == .up || move == .down)
            if next == 0, isVertical, chainV != nil, let h = chainH {
                chainV = nil
                winLastMove = nil
                applyEdgeSnap(edge: h.edge, f: h.f, fracLabel: h.label)
                return
            }
            if next == 0, !isVertical, chainH != nil, let v = chainV {
                chainH = nil
                winLastMove = nil
                applyEdgeSnap(edge: v.edge, f: v.f, fracLabel: v.label)
                return
            }
            winStep = next
        } else { winStep = 0; winLastMove = move }
        let (f, fracLabel) = steps[winStep]

        // Chain bookkeeping: remember this axis's constraint. If the OTHER axis
        // was already snapped this hold, the two combine into a corner (Moom's
        // "← then ↑ = top-left"). Same-axis repeats keep cycling sizes as before.
        switch move {
        case .left:     chainH = (.left, f, fracLabel)
        case .right:    chainH = (.right, f, fracLabel)
        case .up:       chainV = (.top, f, fracLabel)
        case .down:     chainV = (.bottom, f, fracLabel)
        case .maximize: return
        }
        if let h = chainH, let v = chainV {
            guard WindowManager.snapCorner(hEdge: h.edge, hFraction: h.f,
                                           vEdge: v.edge, vFraction: v.f) != nil else {
                overlay.showError("No window to move"); return
            }
            // The empty complement of a corner is L-shaped — Snap Assist sits out.
            snapAssistRegion = nil; snapAssistExcludeWID = nil
            let region = CGRect(x: h.edge == .left ? 0 : 1 - h.f,
                                y: v.edge == .top ? 0 : 1 - v.f,
                                width: h.f, height: v.f)
            let corner = "\(v.edge == .top ? "Top" : "Bottom") \(h.edge == .left ? "Left" : "Right")"
            let label = (h.f == 0.5 && v.f == 0.5) ? "\(corner) ¼" : "\(corner) \(h.label) × \(v.label)"
            overlay.showWindow(region: region, label: label)
            return
        }

        let edge: WindowManager.Edge
        switch move {
        case .left:  edge = .left
        case .right: edge = .right
        case .up:    edge = .top
        case .down:  edge = .bottom
        case .maximize: return
        }
        applyEdgeSnap(edge: edge, f: f, fracLabel: fracLabel)
    }

    /// Plain single-edge snap + Snap Assist bookkeeping + HUD (shared by the
    /// normal arrow path and the chained-corner unwind).
    private func applyEdgeSnap(edge: WindowManager.Edge, f: CGFloat, fracLabel: String) {
        let region: CGRect
        let name: String
        switch edge {
        case .left:   region = CGRect(x: 0, y: 0, width: f, height: 1);     name = "Left"
        case .right:  region = CGRect(x: 1 - f, y: 0, width: f, height: 1); name = "Right"
        case .top:    region = CGRect(x: 0, y: 0, width: 1, height: f);     name = "Top"
        case .bottom: region = CGRect(x: 0, y: 1 - f, width: 1, height: f); name = "Bottom"
        }
        guard let result = WindowManager.snap(edge: edge, fraction: f) else {
            overlay.showError("No window to move"); return
        }
        // Stash the empty (complement) region so Snap Assist can offer it on release.
        let vf = result.screen.visibleFrame
        let comp: CGRect
        switch edge {
        case .left:   comp = CGRect(x: vf.minX + vf.width * f, y: vf.minY, width: vf.width * (1 - f), height: vf.height)
        case .right:  comp = CGRect(x: vf.minX, y: vf.minY, width: vf.width * (1 - f), height: vf.height)
        case .top:    comp = CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: vf.height * (1 - f))
        case .bottom: comp = CGRect(x: vf.minX, y: vf.maxY - vf.height * (1 - f), width: vf.width, height: vf.height * (1 - f))
        }
        // Only offer Snap Assist if we reliably know the snapped window's ID (else
        // we couldn't exclude it and it'd appear in — and get re-snapped by — its
        // own picker).
        if let wid = result.windowID {
            snapAssistRegion = comp
            snapAssistExcludeWID = wid
        } else {
            snapAssistRegion = nil
            snapAssistExcludeWID = nil
        }
        overlay.showWindow(region: region, label: "\(name) \(fracLabel)")
    }

    /// After the hotkey is released post-snap: offer the other on-screen windows to
    /// fill the empty side (Windows-style). Off if disabled or the gap is tiny.
    private func maybeSnapAssist() {
        guard config.snapAssist, let region = snapAssistRegion, let exclude = snapAssistExcludeWID else {
            snapAssistRegion = nil; snapAssistExcludeWID = nil; return
        }
        snapAssistRegion = nil; snapAssistExcludeWID = nil
        guard region.width > 120, region.height > 100 else { return }
        // The app whose window we just snapped — restore focus to it on cancel so
        // Power Tools (a .regular Dock app) isn't left wedged frontmost.
        let prevApp = NSWorkspace.shared.frontmostApplication
        snapAssist.present(
            in: region, excluding: exclude, dark: config.appearance.isDark,
            onPick: { cand in
                guard let ax = WindowManager.axWindow(pid: cand.pid, windowID: cand.windowID) else {
                    self.overlay.showError("Couldn't move that window")
                    prevApp?.activate()
                    return
                }
                NSRunningApplication(processIdentifier: cand.pid)?.activate()
                WindowManager.setWindow(ax, cocoaFrame: region)
                WindowManager.raise(ax)
            },
            onCancel: { prevApp?.activate() }
        )
    }

    private func fileClipboard(_ op: FileOp) {
        // File ops don't touch the dictation state machine; the caller already
        // cancels an active recording, so don't drop the op while .processing.
        let move = (op == .paste) && fileCutPending
        let label: String
        switch op {
        case .copy:  fileCutPending = false; label = "Copied"
        case .cut:   fileCutPending = true;  label = "Cut — hold + V to move it"
        case .paste: fileCutPending = false; label = move ? "Moved" : "Pasted"
        }
        overlay.showResult(label)
        // Wait until the physical hotkey modifiers are released before synthesizing,
        // or a still-held Shift/Ctrl leaks in (Shift+⌘C = Finder "Go to Computer", etc.).
        afterModifiersClear {
            switch op {
            case .copy, .cut: Inserter.fileCopy()
            case .paste: Inserter.filePaste(move: move)
            }
        }
    }

    /// Run `action` once no physical Shift/Command/Control/Option remains held (or
    /// after a timeout), so a synthesized keystroke isn't polluted by the hotkey.
    private func afterModifiersClear(timeout: TimeInterval = 0.8, _ action: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            let f = CGEventSource.flagsState(.combinedSessionState)
            let held = f.contains(.maskShift) || f.contains(.maskCommand)
                    || f.contains(.maskControl) || f.contains(.maskAlternate)
            if !held || Date() >= deadline {
                action()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25), execute: poll)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20), execute: poll)
    }

    /// Open (or focus) the AI chat window. Optionally seed it with a message and send.
    func openChat(with text: String = "") {
        if chat == nil { chat = ChatWindowController(config: config) }
        chat?.updateConfig(config)
        chat?.present()
        if !text.isEmpty { chat?.send(text) }
    }

    private func finishCycle() {
        cycle += 1 // invalidate any straggler continuations from this cycle
        state = .idle
        context = nil
        recordingStarted = nil
        startTask = nil
        dictatingIntoCapture = false
        onStateChange?(.idle)
    }
}
