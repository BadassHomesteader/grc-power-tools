import Foundation
import AVFoundation

/// Dictation utterance transcribed by FluidAudio's Parakeet TDT model
/// (vendored in `Sources/FluidAudioVendored/` — see its NOTICE.md for why:
/// swiftpm is broken on the dev machine, and a CI-built artifact turned out
/// to be blocked by a Swift-compiler version mismatch between this machine
/// and GitHub Actions' available toolchains).
///
/// FluidAudio's ASR API is batch-only (no push-streaming with volatile
/// partials like Apple's SpeechAnalyzer), but the model runs at ~120x
/// realtime — fast enough to fake streaming: `feed()` accumulates 16kHz
/// samples, and a loop re-transcribes the whole utterance-so-far every
/// ~0.7s during the hold, pushing the running text through `onPartial`.
/// Each pass is a fresh decode of all audio, so partials can revise earlier
/// words (like Apple's volatile results do). `finish()` does one final
/// full-utterance pass.
final class ParakeetEngine: TranscriptionEngine {
    // Model load is expensive (first use downloads from HuggingFace) and must
    // happen once, not per-utterance — shared across all ParakeetEngine instances.
    private static var loadTask: Task<AsrManager, Error>?

    /// Seconds between partial re-transcription passes. Each pass costs
    /// ~0.1–0.5s (grows with utterance length), so 0.7s keeps the loop from
    /// saturating a core while still feeling live.
    private static let partialInterval: UInt64 = 700_000_000

    private let locale: Locale
    /// 16kHz mono samples accumulated so far. Guarded by `lock`: `feed()`
    /// appends on the audio-capture thread while the partial loop snapshots.
    private var samples: [Float] = []
    private let lock = NSLock()
    private let converter = AudioConverter()
    private var partialTask: Task<Void, Never>?

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

    private func snapshotSamples() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func clearSamples() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll()
    }

    private static func transcribe(_ samples: [Float], locale: Locale) async throws -> String {
        let manager = try await sharedManager(locale: locale)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState, language: nil)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() async throws {
        let locale = self.locale
        partialTask = Task { [weak self] in
            let minSamples = ASRConstants.minimumRequiredSamples(forSampleRate: 16000)
            var lastCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.partialInterval)
                guard let self, !Task.isCancelled else { return }
                let snapshot = self.snapshotSamples()
                // Skip until there's enough audio, and don't burn a pass when
                // nothing new arrived (e.g. mic silence gating upstream).
                guard snapshot.count >= minSamples, snapshot.count > lastCount else { continue }
                lastCount = snapshot.count
                guard let text = try? await Self.transcribe(snapshot, locale: locale),
                      !text.isEmpty, !Task.isCancelled else { continue }
                self.onPartial?(text)
            }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        // Convert on the capture thread (same pattern as AppleSpeechUtterance);
        // only the append needs the lock.
        guard let converted = try? converter.resampleBuffer(buffer) else { return }
        lock.lock()
        samples.append(contentsOf: converted)
        lock.unlock()
    }

    func finish() async throws -> String {
        partialTask?.cancel()
        // Let an in-flight partial pass drain before the final one queues
        // behind it on the (serialized) AsrManager actor.
        await partialTask?.value
        partialTask = nil
        let all = snapshotSamples()
        clearSamples()
        guard all.count >= ASRConstants.minimumRequiredSamples(forSampleRate: 16000) else { return "" }
        return try await Self.transcribe(all, locale: locale)
    }

    func cancel() async {
        partialTask?.cancel()
        partialTask = nil
        clearSamples()
    }
}
