import Foundation
import AppKit

/// Glue for the dictation state machine: idle -> recording -> processing -> idle.
@MainActor
final class AppController {
    enum State { case idle, recording, processing }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?
    var lastTranscript: String = ""

    let config: Config
    let store: Store
    private let audio: AudioCapture
    private let polisher: Polisher
    private let overlay = OverlayPanel()
    private var hotkey: HotkeyMonitor?

    private var utterance: AppleSpeechUtterance?
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
        audio.onLevel = { [weak self] level in
            Task { @MainActor in self?.overlay.setLevel(level) }
        }

        let monitor = HotkeyMonitor(hotkey: config.hotkey)
        monitor.handler = { [weak self] event in
            guard let self else { return }
            switch event {
            case .down: self.keyDown()
            case .up: self.keyUp()
            case .cancel: self.cancel()
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
        context = ctx
        state = .recording
        onStateChange?(.recording)
        recordingStarted = Date()
        overlay.showRecording()
        if config.polish == .llm { polisher.prewarm() }

        guard let format = audio.currentFormat else {
            fail("No audio input device")
            return
        }
        let utt = AppleSpeechUtterance(locale: Locale(identifier: config.localeIdentifier))
        utt.onPartial = { [weak self] text in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.overlay.showPartial(text)
            }
        }
        utterance = utt

        maxUtteranceTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.maxUtteranceSeconds),
                                                 repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                log("controller: max utterance reached, finishing")
                self.keyUp()
            }
        }

        Task {
            do {
                try await utt.start(sourceFormat: format)
                await MainActor.run {
                    guard self.state == .recording, self.utterance === utt else { return }
                    self.audio.beginRecording { buffer in utt.feed(buffer) }
                }
            } catch {
                await MainActor.run { self.fail("Speech engine failed: \(error.localizedDescription)") }
            }
        }
    }

    private func keyUp() {
        guard state == .recording, let utt = utterance else { return }
        maxUtteranceTimer?.invalidate()
        audio.endRecording()

        let heldMs = Int((Date().timeIntervalSince(recordingStarted ?? Date())) * 1000)
        if heldMs < config.minHoldMs {
            // Accidental tap.
            state = .idle
            onStateChange?(.idle)
            utterance = nil
            overlay.hide()
            Task { await utt.cancel() }
            return
        }

        state = .processing
        onStateChange?(.processing)
        overlay.showProcessing()
        let ctx = context
        let cfg = config

        Task {
            do {
                let raw = try await utt.finish()
                await MainActor.run { self.utterance = nil }
                guard !raw.isEmpty else {
                    await MainActor.run {
                        self.overlay.showError("Didn't catch that")
                        self.finishCycle()
                    }
                    return
                }
                let polished = await self.polisher.polish(
                    raw, mode: cfg.polish,
                    appName: ctx?.appName ?? "unknown",
                    deadlineMs: cfg.llmDeadlineMs
                )
                await MainActor.run {
                    self.deliver(raw: raw, polished: polished, durationMs: heldMs, ctx: ctx)
                }
            } catch {
                await MainActor.run {
                    self.utterance = nil
                    self.fail("Transcription failed: \(error.localizedDescription)")
                }
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

    private func cancel() {
        maxUtteranceTimer?.invalidate()
        audio.endRecording()
        if let utt = utterance {
            utterance = nil
            Task { await utt.cancel() }
        }
        overlay.hide()
        finishCycle()
    }

    private func fail(_ message: String) {
        log("controller: \(message)")
        maxUtteranceTimer?.invalidate()
        audio.endRecording()
        utterance = nil
        overlay.showError(message)
        finishCycle()
    }

    private func finishCycle() {
        state = .idle
        context = nil
        recordingStarted = nil
        onStateChange?(.idle)
    }
}
