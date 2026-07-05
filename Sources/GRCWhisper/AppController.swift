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
        }
    }

    let store: Store
    private let audio: AudioCapture
    private let polisher: Polisher
    private let overlay = OverlayPanel()
    private var hotkey: HotkeyMonitor?
    private var chat: ChatWindowController?

    private var cycle = 0
    /// File "cut" is Copy now + Move-on-next-paste (macOS has no real file cut).
    private var fileCutPending = false
    /// Window-organizer cycle state: repeated same-direction taps shrink the window.
    private var winLastMove: WindowManager.Move?
    private var winStep = 0
    private static let winFractions: [CGFloat] = [0.5, 1.0 / 3.0, 2.0 / 3.0]
    private var utterance: AppleSpeechUtterance?
    private var startTask: Task<Void, Error>?
    private var context: ContextSnapshot?
    private var recordingStarted: Date?
    private var maxUtteranceTimer: Timer?

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
                self.handleWindow(move)
            case .windowEnd:
                self.overlay.hide()
            }
        }
        guard monitor.start() else {
            throw NSError(domain: "GRCWhisper", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't install the global hotkey — grant Accessibility permission and relaunch"])
        }
        hotkey = monitor
        log("controller: ready (hotkey \(config.hotkey.displayName), polish \(config.polish.rawValue))")
    }

    // MARK: Key events

    private func keyDown() {
        guard state == .idle else { return }
        winLastMove = nil; winStep = 0   // fresh window-cycle each hold
        let ctx = ContextSnapshot.capture()
        if ctx.isSecureField {
            overlay.showError("Secure input field — can't dictate here")
            return
        }
        if ctx.bundleID == "com.grc.whisper" {
            overlay.showError("Click into another app first, then hold to dictate")
            return
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

    enum FileOp { case copy, cut, paste }

    /// hold + C / X / V: copy, cut (copy + mark for move), or paste files. Paste is a
    /// Finder "Move Item Here" (⌥⌘V) if the last action was a cut, else a plain ⌘V.
    /// A short delay lets the physical hotkey modifiers lift before we synthesize.
    /// Arrow/Return in window mode. Fires on each keydown; repeating the same
    /// direction cycles the size (½ → ⅓ → ⅔) so "tap ← ←" shrinks the left snap.
    private func handleWindow(_ move: WindowManager.Move) {
        interruptDictation()
        if move == .maximize {
            winLastMove = nil; winStep = 0
            if WindowManager.maximize() {
                overlay.showWindow(region: CGRect(x: 0, y: 0, width: 1, height: 1), label: "Maximize")
            } else { overlay.showError("No window to move") }
            return
        }
        let steps = config.snapSizes.steps
        if move == winLastMove { winStep = (winStep + 1) % steps.count }
        else { winStep = 0; winLastMove = move }
        let (f, fracLabel) = steps[winStep]
        let edge: WindowManager.Edge
        let region: CGRect
        let name: String
        switch move {
        case .left:  edge = .left;   region = CGRect(x: 0, y: 0, width: f, height: 1);     name = "Left"
        case .right: edge = .right;  region = CGRect(x: 1 - f, y: 0, width: f, height: 1); name = "Right"
        case .up:    edge = .top;    region = CGRect(x: 0, y: 0, width: 1, height: f);     name = "Top"
        case .down:  edge = .bottom; region = CGRect(x: 0, y: 1 - f, width: 1, height: f); name = "Bottom"
        case .maximize: return
        }
        guard WindowManager.snap(edge: edge, fraction: f) else {
            overlay.showError("No window to move"); return
        }
        overlay.showWindow(region: region, label: "\(name) \(fracLabel)")
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
        onStateChange?(.idle)
    }
}
