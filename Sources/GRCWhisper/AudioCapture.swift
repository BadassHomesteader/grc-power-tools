import Foundation
import AVFoundation

/// Always-warm microphone capture with a pre-roll ring buffer.
///
/// The engine runs continuously so the ~500ms macOS mic spin-up never eats the
/// first syllable (Handy #1283 / Wispr's "missing first words" class). While idle,
/// buffers land in a short ring; when recording starts the ring is flushed to the
/// consumer first, then live buffers stream through.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "grc-whisper.audio")
    private var ring: [AVAudioPCMBuffer] = []
    private var ringDuration: Double = 0
    private let preRollSeconds: Double
    private var recording = false
    private var consumer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var currentFormat: AVAudioFormat?

    /// Smoothed input level 0...1 for the overlay meter.
    var onLevel: ((Float) -> Void)?
    private var smoothedLevel: Float = 0

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

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.restartAfterConfigChange() }
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

        if let data = copy.floatChannelData?[0], copy.frameLength > 0 {
            var sum: Float = 0
            let n = Int(copy.frameLength)
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = sqrtf(sum / Float(n))
            smoothedLevel = smoothedLevel * 0.7 + min(rms * 8, 1.0) * 0.3
            let level = smoothedLevel
            if recording { onLevel?(level) }
        }

        queue.async { [self] in
            if recording {
                consumer?(copy)
            } else {
                ring.append(copy)
                ringDuration += seconds
                while ringDuration > preRollSeconds, !ring.isEmpty {
                    let dropped = ring.removeFirst()
                    ringDuration -= Double(dropped.frameLength) / dropped.format.sampleRate
                }
            }
        }
    }

    /// Begin streaming to `consumer`, starting with the pre-roll ring.
    func beginRecording(consumer: @escaping (AVAudioPCMBuffer) -> Void) {
        queue.async { [self] in
            self.consumer = consumer
            for buffered in ring { consumer(buffered) }
            ring.removeAll()
            ringDuration = 0
            recording = true
        }
    }

    func endRecording() {
        queue.async { [self] in
            recording = false
            consumer = nil
        }
    }
}

extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let src = audioBufferList.pointee
        let dst = copy.mutableAudioBufferList.pointee
        let srcBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dstBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        _ = src; _ = dst
        for (s, d) in zip(srcBuffers, dstBuffers) {
            guard let sd = s.mData, let dd = d.mData else { continue }
            memcpy(dd, sd, Int(s.mDataByteSize))
        }
        return copy
    }
}
