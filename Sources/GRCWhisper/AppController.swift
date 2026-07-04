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
    var config: Config

    let store: Store
    private let audio: AudioCapture
    private let polisher: Polisher
    private let overlay = OverlayPanel()
    private var hotkey: HotkeyMonitor?

    private var cycle = 0
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
                if self.state == .recording { self.cancel() }
                self.captureScreenText()
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
                let final: String
                if ai {
                    self.overlay.showProcessing()
                    // Command mode when text is selected; otherwise smart cloud cleanup.
                    let selection = await Inserter.copySelection()?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let sel = selection, !sel.isEmpty {
                        final = await self.polisher.rewrite(instruction: raw, selection: sel, config: cfg) ?? raw
                    } else {
                        final = await self.polisher.polish(raw, config: cfg, appName: appName,
                                                           engineOverride: Polisher.preferredCloud(cfg))
                    }
                } else {
                    final = await self.polisher.polish(raw, config: cfg, appName: appName)
                }
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
    func captureScreenText() {
        guard state == .idle else { return }
        // OCR needs THIS app to hold Screen Recording (even though the system
        // screencapture tool does the grab). If it's missing, prompt + open the
        // exact settings pane; the grant needs a quit & reopen to take effect.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            overlay.showError("Turn on Screen Recording for GRC Whisper, then quit & reopen the app")
            return
        }
        state = .processing
        onStateChange?(.processing)
        let cfg = config
        Task {
            let text = await ScreenTextCapture.capture()
            await MainActor.run {
                defer { self.finishCycle() }
                guard let text else { return } // user cancelled the selection
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self.overlay.showError("No text found in the selection")
                    return
                }
                do {
                    try Inserter.insert(trimmed, restoreDelayMs: cfg.clipboardRestoreDelayMs)
                    self.overlay.showResult(trimmed.count > 80 ? String(trimmed.prefix(77)) + "…" : trimmed)
                } catch {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(trimmed, forType: .string)
                    self.overlay.showError("Copied \(trimmed.count) characters to clipboard")
                }
                self.store.addHistory(app: "screen-ocr", raw: trimmed, polished: trimmed, durationMs: 0)
            }
        }
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
