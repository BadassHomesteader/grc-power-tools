import Foundation
import AVFoundation
import Speech

/// One dictation utterance transcribed by Apple's on-device SpeechAnalyzer (macOS 26).
///
/// Streams audio *during* the key hold with volatile partial results, so the
/// finalize step at key-release is near-instant. One instance per utterance.
final class AppleSpeechUtterance {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let inputStream: AsyncStream<AnalyzerInput>
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<String, Error>?
    private var started = false

    /// Called with the running transcript (finalized + current volatile tail).
    var onPartial: ((String) -> Void)?

    init(locale: Locale) {
        // NOTE: .offlineTranscription preset does NOT exist in the macOS 26.x SDK
        // despite some docs — use the explicit options initializer.
        transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        analyzer = SpeechAnalyzer(modules: [transcriber])
        (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
    }

    /// Ensure the on-device model assets for `locale` are installed (one-time, system-managed).
    static func ensureAssets(locale: Locale) async throws {
        let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                      reportingOptions: [], attributeOptions: [])
        let installed = await Set(SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        if installed.contains(locale.identifier(.bcp47)) { return }
        let supported = await Set(SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) })
        guard supported.contains(locale.identifier(.bcp47)) else {
            throw NSError(domain: "GRCWhisper", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Locale \(locale.identifier) not supported by SpeechTranscriber"])
        }
        log("speech: downloading model assets for \(locale.identifier)…")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
        log("speech: assets installed")
    }

    func start(sourceFormat: AVAudioFormat) async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "GRCWhisper", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No compatible analyzer audio format"])
        }
        analyzerFormat = format
        if format != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: format)
        }

        // Reader must be running before audio flows.
        resultsTask = Task { [transcriber, onPartial] in
            var finals = ""
            var volatileTail = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finals += text
                    volatileTail = ""
                } else {
                    volatileTail = text
                }
                let running = finals + volatileTail
                if !running.isEmpty { onPartial?(running) }
            }
            return finals.isEmpty ? volatileTail : finals
        }

        try await analyzer.start(inputSequence: inputStream)
        started = true
    }

    /// Feed a captured buffer (any format); converted to the analyzer format here.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard started, let analyzerFormat else { return }
        if let converter {
            let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if let error {
                log("speech: convert error \(error)")
                return
            }
            guard out.frameLength > 0 else { return }
            inputContinuation.yield(AnalyzerInput(buffer: out))
        } else {
            inputContinuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    /// Stop input and return the final transcript.
    func finish() async throws -> String {
        inputContinuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await resultsTask?.value ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        inputContinuation.finish()
        resultsTask?.cancel()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
    }
}

/// Batch transcription of an audio file — used by the `transcribe` CLI subcommand
/// to verify the engine without microphone/TCC involvement.
func transcribeFile(url: URL, locale: Locale) async throws -> String {
    try await AppleSpeechUtterance.ensureAssets(locale: locale)
    let file = try AVAudioFile(forReading: url)
    log("transcribe: file format \(file.processingFormat)")
    let utterance = AppleSpeechUtterance(locale: locale)
    try await utterance.start(sourceFormat: file.processingFormat)
    log("transcribe: analyzer started")

    let chunk: AVAudioFrameCount = 4096
    var fedFrames: AVAudioFramePosition = 0
    // Bound by framePosition: reading at EOF throws (nilError) rather than returning 0 frames.
    while file.framePosition < file.length {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
        try file.read(into: buffer, frameCount: chunk)
        if buffer.frameLength == 0 { break }
        fedFrames += AVAudioFramePosition(buffer.frameLength)
        utterance.feed(buffer)
    }
    log("transcribe: fed \(fedFrames) frames, finishing")
    return try await utterance.finish()
}
