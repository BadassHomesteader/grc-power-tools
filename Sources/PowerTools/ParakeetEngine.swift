import Foundation
import AVFoundation
import PowerToolsASRBridge

/// Dictation utterance transcribed by FluidAudio's Parakeet TDT model.
///
/// Unlike `AppleSpeechUtterance`, FluidAudio's ASR API is batch-only (transcribe
/// a complete file) — there's no push-based streaming with live partials. So
/// `feed()` just accumulates buffers, and the whole utterance is written to a
/// temp file and transcribed once in `finish()`. `onPartial` is never called;
/// the overlay simply shows nothing until release, which is an accepted gap
/// for this engine (see the plan — true streaming is a separate, bigger effort).
final class ParakeetEngine: TranscriptionEngine {
    // Model load is expensive (first use downloads from HuggingFace) and must
    // happen once, not per-utterance — shared across all ParakeetEngine instances.
    private static var loadTask: Task<ParakeetBridge, Error>?

    private let locale: Locale
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var format: AVAudioFormat?

    var onPartial: ((String) -> Void)?

    init(locale: Locale) {
        self.locale = locale
    }

    private static func modelVersion(for locale: Locale) -> ParakeetModelVersion {
        locale.language.languageCode?.identifier == "en" ? .english : .multilingual
    }

    private static func sharedBridge(locale: Locale) async throws -> ParakeetBridge {
        if let loadTask { return try await loadTask.value }
        let version = modelVersion(for: locale)
        let task = Task<ParakeetBridge, Error> {
            log("parakeet: downloading/loading model (version: \(version))…")
            let bridge = ParakeetBridge()
            try await bridge.loadModels(version: version)
            log("parakeet: model ready")
            return bridge
        }
        loadTask = task
        return try await task.value
    }

    /// Pre-warms the shared model so the first real dictation isn't the one
    /// that pays the (possibly multi-second, first-run network) load cost.
    static func ensureAssets(locale: Locale) async throws {
        _ = try await sharedBridge(locale: locale)
    }

    func start() async throws {
        // Nothing to start — buffers just accumulate via feed() below.
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        if format == nil { format = buffer.format }
        pendingBuffers.append(buffer)
    }

    func finish() async throws -> String {
        guard !pendingBuffers.isEmpty, let format else { return "" }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("caf")
        let file = try AVAudioFile(forWriting: tmpURL, settings: format.settings)
        for buffer in pendingBuffers {
            try file.write(from: buffer)
        }
        pendingBuffers.removeAll()
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let bridge = try await Self.sharedBridge(locale: locale)
        let result = try await bridge.transcribe(fileURL: tmpURL)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        pendingBuffers.removeAll()
    }
}
