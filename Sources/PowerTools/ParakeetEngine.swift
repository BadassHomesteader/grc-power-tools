import Foundation
import AVFoundation

/// Dictation utterance transcribed by FluidAudio's Parakeet TDT model
/// (vendored in `Sources/FluidAudioVendored/` — see its NOTICE.md for why:
/// swiftpm is broken on the dev machine, and a CI-built artifact turned out
/// to be blocked by a Swift-compiler version mismatch between this machine
/// and GitHub Actions' available toolchains).
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
    private static var loadTask: Task<AsrManager, Error>?

    private let locale: Locale
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var format: AVAudioFormat?

    var onPartial: ((String) -> Void)?

    init(locale: Locale) {
        self.locale = locale
    }

    private static func modelVersion(for locale: Locale) -> AsrModelVersion {
        locale.language.languageCode?.identifier == "en" ? .v2 : .v3
    }

    private static func sharedManager(locale: Locale) async throws -> AsrManager {
        if let loadTask { return try await loadTask.value }
        let version = modelVersion(for: locale)
        let task = Task<AsrManager, Error> {
            log("parakeet: downloading/loading model (version: \(version))…")
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager()
            try await manager.loadModels(models)
            log("parakeet: model ready")
            return manager
        }
        loadTask = task
        return try await task.value
    }

    /// Pre-warms the shared model so the first real dictation isn't the one
    /// that pays the (possibly multi-second, first-run network) load cost.
    static func ensureAssets(locale: Locale) async throws {
        _ = try await sharedManager(locale: locale)
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

        let manager = try await Self.sharedManager(locale: locale)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(tmpURL, decoderState: &decoderState, language: nil)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        pendingBuffers.removeAll()
    }
}
