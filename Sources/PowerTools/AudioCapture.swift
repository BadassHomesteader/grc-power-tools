import Foundation
import AVFoundation

/// Always-warm microphone capture with a pre-roll ring buffer.
///
/// The engine runs continuously so the ~500ms macOS mic spin-up never eats the
/// first syllable (the classic "missing first words" problem in this app class). While idle,
/// buffers land in a short ring; at key-down `beginHold()` stops trimming the ring
/// (so nothing is lost while the speech analyzer spins up), and `beginRecording`
/// flushes the ring to the consumer then streams live buffers.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "grc-whisper.audio")
    private var ring: [AVAudioPCMBuffer] = []
    private var ringDuration: Double = 0
    private let preRollSeconds: Double
    /// While false (between beginHold and beginRecording/endRecording) the ring grows unbounded.
    private var trimRing = true
    private var streaming = false
    private var consumer: ((AVAudioPCMBuffer) -> Void)?
    private var observerInstalled = false
    private(set) var currentFormat: AVAudioFormat?

    /// Smoothed input level 0...1 for the overlay meter.
    /// Per-slice peak amplitudes (0.06...1), several per buffer, for the live waveform.
    var onLevels: (([Float]) -> Void)?

    init(preRollSeconds: Double = 1.0) {
        self.preRollSeconds = preRollSeconds
    }

    static func requestMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "GRCWhisper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No usable audio input device"])
        }
        currentFormat = format
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        engine.prepare()
        try engine.start()

        // Register exactly once: restartAfterConfigChange() re-enters start(), and a
        // per-start observer would double the observer count on every device change.
        if !observerInstalled {
            observerInstalled = true
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.restartAfterConfigChange() }
            }
        }
        log("audio: engine running, input \(Int(format.sampleRate))Hz x\(format.channelCount)ch")
    }

    private func restartAfterConfigChange() {
        log("audio: configuration change, restarting engine")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        ring.removeAll()
        ringDuration = 0
        do { try start() } catch {
            log("audio: restart failed: \(error)")
        }
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        // Copy: the tap's buffer may be reused by Core Audio after we return.
        guard let copy = buffer.deepCopy() else { return }
        let seconds = Double(copy.frameLength) / copy.format.sampleRate

        // Waveform: loudness (RMS) per ~12ms slice, several per buffer. RMS per
        // short slice tracks each syllable so the scrolling bars vary like a real
        // voice waveform. Gain 20 is tuned for real mic input, which runs far
        // quieter than a full-scale file — a lower gain flatlines live speech.
        if streaming, let data = copy.floatChannelData?[0], copy.frameLength > 0 {
            let n = Int(copy.frameLength)
            let sliceFrames = max(256, Int(copy.format.sampleRate * 0.012))
            var levels: [Float] = []
            var i = 0
            while i < n {
                let end = min(i + sliceFrames, n)
                var sumSq: Float = 0
                for j in i..<end { sumSq += data[j] * data[j] }
                let rms = sqrtf(sumSq / Float(max(end - i, 1)))
                levels.append(min(1, max(0.05, rms * 20)))
                i = end
            }
            if !levels.isEmpty { onLevels?(levels) }
        }

        queue.async { [self] in
            if streaming {
                consumer?(copy)
            } else {
                ring.append(copy)
                ringDuration += seconds
                if trimRing { trim(to: preRollSeconds) }
            }
        }
    }

    private func trim(to seconds: Double) {
        while ringDuration > seconds, !ring.isEmpty {
            let dropped = ring.removeFirst()
            ringDuration -= Double(dropped.frameLength) / dropped.format.sampleRate
        }
    }

    /// Key-down: keep everything captured from here on, even if the analyzer
    /// takes a while to start — the whole utterance must survive in the ring.
    func beginHold() {
        queue.async { self.trimRing = false }
    }

    /// Begin streaming to `consumer`, starting with the ring contents. Idempotent.
    func beginRecording(consumer: @escaping (AVAudioPCMBuffer) -> Void) {
        queue.async { [self] in
            guard !streaming else { return }
            self.consumer = consumer
            for buffered in ring { consumer(buffered) }
            ring.removeAll()
            ringDuration = 0
            streaming = true
        }
    }

    var isStreaming: Bool {
        queue.sync { streaming }
    }

    func endRecording() {
        queue.async { [self] in
            streaming = false
            consumer = nil
            trimRing = true
            trim(to: preRollSeconds)
        }
    }
}

extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let srcBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dstBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(srcBuffers, dstBuffers) {
            guard let sd = s.mData, let dd = d.mData else { continue }
            memcpy(dd, sd, Int(s.mDataByteSize))
        }
        return copy
    }
}
