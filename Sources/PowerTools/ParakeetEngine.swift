import Foundation
import AVFoundation

/// Dictation utterance transcribed by FluidAudio's Parakeet TDT model
/// (vendored in `Sources/FluidAudioVendored/` — see its NOTICE.md).
///
/// FluidAudio's ASR API is batch-only, but the model runs at ~120x realtime —
/// fast enough to fake streaming: `feed()` accumulates 16kHz samples, and a
/// loop re-transcribes the whole utterance-so-far every ~0.7s during the
/// hold, pushing the running text through `onPartial`. Each pass is a fresh
/// full-context decode, so partials self-revise like Apple's volatile
/// results. (FluidAudio's SlidingWindowAsrManager was tried and rejected —
/// it's built for ≥10s long-form chunks and falls apart on dictation-length
/// utterances: fragmented partials, and its vocab-boosted finish() drops
/// everything that never reached its 10s confirmation gate.)
///
/// Custom-vocabulary boosting: terms from the app's existing dictionary
/// (Settings ▸ Dictionary / `dict add`) are CTC-tokenized, spotted in the
/// audio by a small CTC model, and used to rescore the TDT transcript — a
/// tier deeper than the dictionary's post-ASR text replacement (which still
/// applies later in the polish pipeline). Both partial passes and the final
/// pass go through the same rescoring path, so boosted terms (KYAW, NJAW…)
/// appear live. Requires a one-time CTC model download on first use; any
/// failure just disables boosting rather than failing dictation.
final class ParakeetEngine: TranscriptionEngine {
    /// Set once at startup (app + CLI) to the Store's dictionary. Static
    /// because engines are constructed through the protocol's `init(locale:)`.
    static var vocabTermsProvider: (() -> [DictEntry])?

    // Model loads are expensive (first use downloads from HuggingFace) and must
    // happen once, not per-utterance — shared across all ParakeetEngine instances.
    private static var managerTask: Task<AsrManager, Error>?
    private static var ctcTask: Task<CtcModels, Error>?

    /// Seconds between partial re-transcription passes.
    private static let partialInterval: UInt64 = 700_000_000

    /// Everything needed to vocab-rescore one transcription pass.
    private struct VocabBoost {
        let vocab: CustomVocabularyContext
        let spotter: CtcKeywordSpotter
        let rescorer: VocabularyRescorer
    }

    private let locale: Locale
    /// 16kHz mono samples accumulated so far. Guarded by `lock`: `feed()`
    /// appends on the audio-capture thread while the partial loop snapshots.
    private var samples: [Float] = []
    private let lock = NSLock()
    private let converter = AudioConverter()
    private var partialTask: Task<Void, Never>?
    /// Built once per utterance (start()) from the current dictionary, so
    /// Settings ▸ Dictionary edits apply to the very next dictation.
    private var boost: VocabBoost?

    var onPartial: ((String) -> Void)?

    init(locale: Locale) {
        self.locale = locale
    }

    private static func modelVersion(for locale: Locale) -> AsrModelVersion {
        locale.language.languageCode?.identifier == "en" ? .v2 : .v3
    }

    private static func sharedManager(locale: Locale) async throws -> AsrManager {
        if let managerTask { return try await managerTask.value }
        let version = modelVersion(for: locale)
        let task = Task<AsrManager, Error> {
            log("parakeet: downloading/loading model (version: \(version))…")
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager()
            try await manager.loadModels(models)
            log("parakeet: model ready")
            return manager
        }
        managerTask = task
        return try await task.value
    }

    private static func sharedCtcModels() async throws -> CtcModels {
        if let ctcTask { return try await ctcTask.value }
        let task = Task<CtcModels, Error> {
            log("parakeet: downloading/loading CTC vocab-boost model…")
            let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            log("parakeet: CTC model ready")
            return models
        }
        ctcTask = task
        return try await task.value
    }

    /// Builds the boost pipeline from the app dictionary. Returns nil when the
    /// dictionary is empty (no CTC download forced on users without terms) or
    /// when anything fails (offline first run) — dictation proceeds unboosted.
    private static func buildBoost() async -> VocabBoost? {
        guard let entries = vocabTermsProvider?(), !entries.isEmpty else { return nil }
        do {
            let ctcModels = try await sharedCtcModels()
            let modelDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
            let tokenizer = try await CtcTokenizer.load(from: modelDir)
            let terms = entries.compactMap { entry -> CustomVocabularyTerm? in
                let ids = tokenizer.encode(entry.term)
                guard !ids.isEmpty else { return nil }
                let aliases = entry.misheard.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return CustomVocabularyTerm(
                    text: entry.term,
                    aliases: aliases.isEmpty ? nil : aliases,
                    ctcTokenIds: ids
                )
            }
            guard !terms.isEmpty else { return nil }
            let vocab = CustomVocabularyContext(terms: terms)
            let spotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
            // No acoustic rescue: it inserts spotted terms without transcript-
            // similarity backing, which over-fired badly here ("complete" →
            // "APS"). The library's own docs recommend disabling it for small
            // distinctive-name vocabularies exactly like a personal dictionary.
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: vocab,
                config: VocabularyRescorer.Config(spotterRescueEnabled: false),
                ctcModelDirectory: modelDir
            )
            return VocabBoost(vocab: vocab, spotter: spotter, rescorer: rescorer)
        } catch {
            log("parakeet: vocab boosting unavailable (\(error)) — dictating without it")
            return nil
        }
    }

    /// Pre-warms the shared models so the first real dictation isn't the one
    /// that pays the (possibly multi-minute, first-run network) load cost.
    /// CTC warm-up is best-effort: its failure must not block dictation.
    static func ensureAssets(locale: Locale) async throws {
        _ = try await sharedManager(locale: locale)
        if let provider = vocabTermsProvider, !provider().isEmpty {
            _ = try? await sharedCtcModels()
        }
    }

    private func snapshotSamples() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func clearSamples() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll()
    }

    /// One full transcription pass: TDT decode, then (when configured) CTC
    /// keyword-spot + rescore so dictionary terms come out spelled right.
    /// Shared by partial passes and the final pass so they can't disagree
    /// about boosting.
    private static func transcribe(_ samples: [Float], locale: Locale, boost: VocabBoost?) async throws -> String {
        let manager = try await sharedManager(locale: locale)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState, language: nil)
        var text = result.text
        if let boost, let timings = result.tokenTimings, !timings.isEmpty {
            do {
                let spot = try await boost.spotter.spotKeywordsWithLogProbs(
                    audioSamples: samples,
                    customVocabulary: boost.vocab,
                    minScore: nil
                )
                if !spot.logProbs.isEmpty {
                    let cfg = ContextBiasingConstants.rescorerConfig(forVocabSize: boost.vocab.terms.count)
                    let out = boost.rescorer.ctcTokenRescore(
                        transcript: text,
                        tokenTimings: timings,
                        logProbs: spot.logProbs,
                        frameDuration: spot.frameDuration,
                        cbw: cfg.cbw,
                        marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                        // Floor raised well above the library's 0.50: real hits
                        // here are close matches ("NJW"→"NJAW" ≈ 0.75, spelled
                        // aliases higher still) while every observed over-fire
                        // ("complete"→"APS") sits near zero — 0.65 separates
                        // them with margin on both sides.
                        minSimilarity: max(0.65, cfg.minSimilarity, boost.vocab.minSimilarity)
                    )
                    if out.wasModified { text = out.text }
                }
            } catch {
                log("parakeet: vocab rescore failed (\(error)) — using raw transcript")
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() async throws {
        boost = await Self.buildBoost()
        if let boost { log("parakeet: vocab boosting active (\(boost.vocab.terms.count) terms)") }
        let locale = self.locale
        let boost = self.boost
        partialTask = Task { [weak self] in
            let minSamples = ASRConstants.minimumRequiredSamples(forSampleRate: 16000)
            var lastCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.partialInterval)
                guard let self, !Task.isCancelled else { return }
                let snapshot = self.snapshotSamples()
                // Skip until there's enough audio, and don't burn a pass when
                // nothing new arrived.
                guard snapshot.count >= minSamples, snapshot.count > lastCount else { continue }
                lastCount = snapshot.count
                guard let text = try? await Self.transcribe(snapshot, locale: locale, boost: boost),
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
        return try await Self.transcribe(all, locale: locale, boost: boost)
    }

    func cancel() async {
        partialTask?.cancel()
        partialTask = nil
        clearSamples()
    }
}
