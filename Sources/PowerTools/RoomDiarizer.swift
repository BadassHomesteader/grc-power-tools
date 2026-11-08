import AVFoundation
import CoreML
import Foundation

/// Who is talking into THIS Mac's microphone. Everyone in the room shares the
/// one mic, so "which wire the audio came in on" (Me = mic, Them = call audio)
/// can't tell them apart. Sortformer — on-device, 4 voice slots, ~1 s behind
/// live — runs beside the mic transcriber; each finished mic phrase is labeled
/// with the slot that spoke most during it.
///
/// "Me" is the slot enrolled from your own dictation audio (`VoiceSample`);
/// the others are "Speaker 2", "3", "4" in the order they first speak. With no
/// sample yet, nobody is called "Me": Speaker 1, 2, 3.
///
/// A second instance (prefix "them") runs on the call audio: everyone on a
/// Teams/Zoom call arrives mixed in one stream, and it tells them apart as
/// Them 1, 2, 3, 4 — no enrollment, no "Me" (you aren't in the call audio).
final class RoomDiarizer: @unchecked Sendable {
    /// PT_SORTFORMER=fast|balanced|high|efficient overrides it (tests).
    /// Efficient v2.1 (~2 s behind live). Measured on two-voice and
    /// three-voice test meetings with your voice enrolled: 12/12 phrases right,
    /// vs 10/12 fast, 9/12 balanced; high-context failed to enroll.
    static let config: SortformerConfig = {
        switch ProcessInfo.processInfo.environment["PT_SORTFORMER"] {
        case "fast": return .fastV2_1
        case "high": return .highContextV2_1
        case "balanced": return .balancedV2_1
        default: return .efficientV2_1   // best in tests: 12/12, 60× realtime
        }
    }()
    /// How long a phrase waits before it is labeled: the model's output
    /// latency plus a margin, so the timeline covers the whole phrase.
    static let labelDelay: Double = {
        switch ProcessInfo.processInfo.environment["PT_SORTFORMER"] {
        case "fast": return 1.5
        case "high": return 4.0
        case "balanced": return 2.0
        default: return 2.5
        }
    }()
    static let enabledKey = "meetings.roomSpeakers"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private static let modelLock = NSLock()
    private static var cachedModels: [String: SortformerModels] = [:]

    /// One-time download (FluidInference/diar-streaming-sortformer-coreml →
    /// ~/Library/Application Support/FluidAudio/Models), then cached per launch.
    /// Each stream (mic "room", call "them") gets its own loaded copy, so two
    /// diarizers never run predictions on the same Core ML model at once.
    static func models(for prefix: String = "room") async throws -> SortformerModels {
        if let m = modelLock.withLock({ cachedModels[prefix] }) { return m }
        let m = try await SortformerModels.loadFromHuggingFace(config: config)
        modelLock.withLock { cachedModels[prefix] = m }
        return m
    }

    private let diarizer: SortformerDiarizer
    private let queue = DispatchQueue(label: "grc-whisper.meeting.diarizer")
    private let lock = NSLock()
    /// The enrolled "Me" slot, nil when there was no usable voice sample.
    let enrolledMe: Int?
    /// The slot labeled "Me" now — the enrolled one, or the one the user
    /// picked with "This is me" in the transcript.
    private var meSlot: Int?
    /// The last ~90 s of mic audio (device rate), so "This is me" can cut the
    /// user's own speech out as a voice sample for the next meetings.
    private var ring: [Float] = []
    private var ringRate: Double = 48_000
    private var fedSeconds: Double = 0   // diarizer clock at the end of `ring`
    private static let ringSeconds: Double = 90
    /// Recording seconds at which the diarizer's own clock reads 0 (it starts
    /// after the transcriber when the model is still loading).
    let clockStart: Double
    private var roomNumbers: [Int: Int] = [:]   // slot → 2, 3, 4 in order of first speech
    private var failed = false
    /// Label prefix: "room" (mic: room1…, can be "me") or "them" (call: them1…).
    let prefix: String
    private var isCall: Bool { prefix == "them" }

    init(models: SortformerModels, enrollment: [Float]?, clockStart: Double, prefix: String = "room") {
        diarizer = SortformerDiarizer(config: Self.config)
        diarizer.initialize(models: models)
        self.clockStart = clockStart
        self.prefix = prefix
        var me: Int?
        if prefix == "room", let enrollment, enrollment.count >= 16_000 * 3 {
            do {
                me = try diarizer.enrollSpeaker(withAudio: enrollment, sourceSampleRate: 16_000, named: "Me")?.index
            } catch {
                log("meetings: voice enrollment failed: \(error)")
            }
        }
        enrolledMe = me
        meSlot = me
        if prefix == "them" { log("meetings: call speakers on — Them 1, 2, 3 by voice"); return }
        log("meetings: room speakers on — " + (me.map { "your voice enrolled in slot \($0)" }
            ?? "no voice sample yet (dictate a few times) — labels are Speaker 1, 2, 3"))
    }

    /// Mono buffer at the device rate, from the mic capture thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        let rate = buffer.format.sampleRate
        queue.async { [self] in
            fedSeconds += Double(samples.count) / rate
            if !isCall {   // only the mic's voices can be claimed as "Me"
                ringRate = rate
                ring += samples
                let keep = Int(Self.ringSeconds * rate)
                if ring.count > keep + Int(rate * 10) { ring.removeFirst(ring.count - keep) }
            }
            guard !lock.withLock({ failed }) else { return }
            do { _ = try diarizer.process(samples: samples, sourceSampleRate: rate) } catch {
                lock.withLock { failed = true }
                log("meetings: room speakers stopped: \(error)")
            }
        }
    }

    /// Runs `body` after everything fed so far has been processed.
    func afterPending(_ body: @escaping @Sendable () -> Void) { queue.async(execute: body) }

    func finish() {
        queue.sync { _ = try? diarizer.finalizeSession() }
    }

    /// One mic phrase → one segment per speaker in it. Apple's transcriber
    /// often runs the end of one person's sentence and the next person's
    /// "Good." into one phrase; each word is labeled, a lone word that
    /// disagrees with both neighbors is smoothed away, and the phrase splits
    /// where the speaker changes. No word times → the phrase is labeled whole.
    func split(_ seg: MeetingSegment, words: [MeetingWord], offset: Double) -> [MeetingSegment] {
        guard !words.isEmpty else {
            var s = seg
            if let l = label(from: seg.start - offset, to: (seg.end ?? seg.start + 2) - offset) { s.speaker = l }
            return [s]
        }
        // Each word by its LAST 0.3 s: Apple stretches the first word after a
        // pause back over the silence ("Two" got 13.56–14.76 s; it was said at
        // ~14.6), so its whole range sat mostly in the previous speaker's turn.
        var labels = words.map { w in label(from: max(w.start, w.end - 0.3) - offset, to: w.end - offset, minSpan: 0.2) }
        // Unknown words take the label before them (or after, at the start).
        for i in labels.indices where labels[i] == nil { labels[i] = i > 0 ? labels[i - 1] : nil }
        for i in labels.indices.reversed() where labels[i] == nil { labels[i] = i + 1 < labels.count ? labels[i + 1] : nil }
        if labels.count >= 3 {
            for i in 1..<(labels.count - 1) where labels[i] != labels[i - 1] && labels[i - 1] == labels[i + 1] {
                labels[i] = labels[i - 1]
            }
        }
        var out: [MeetingSegment] = []
        for (w, l) in zip(words, labels) {
            let who = l ?? seg.speaker
            if var last = out.last, last.speaker == who {
                last.text += w.text
                last.end = w.end
                out[out.count - 1] = last
            } else {
                out.append(MeetingSegment(speaker: who, start: w.start, text: w.text, end: w.end))
            }
        }
        return out.compactMap { s in
            var t = s
            t.text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.text.isEmpty ? nil : t
        }
    }

    /// "This is me" on a transcript label ("room1"…): that voice slot becomes
    /// "Me" from now on (a previous "Me" slot takes the label's number), and
    /// the user's speech in the last 90 s comes back as a 16 kHz voice sample.
    func claimMe(label: String) -> [Float]? {
        guard !isCall, label.hasPrefix("room"), let n = Int(label.dropFirst(4)) else { return nil }
        return queue.sync { () -> [Float]? in
            let slot: Int? = lock.withLock {
                guard let slot = roomNumbers.first(where: { $0.value == n })?.key else { return nil }
                roomNumbers[slot] = nil
                if let old = meSlot { roomNumbers[old] = n }
                meSlot = slot
                return slot
            }
            guard let slot, let sp = diarizer.timeline.speakers[slot] else { return nil }
            let ringStart = fedSeconds - Double(ring.count) / ringRate
            var out: [Float] = []
            for seg in sp.finalizedSegments + sp.tentativeSegments {
                let a = max(Double(seg.startTime), ringStart), b = min(Double(seg.endTime), fedSeconds)
                guard b - a > 0.3 else { continue }
                let i = Int((a - ringStart) * ringRate), j = min(Int((b - ringStart) * ringRate), ring.count)
                if i < j { out += ring[i..<j] }
            }
            let cap = Int(VoiceSample.keepSeconds * ringRate)
            if out.count > cap { out = Array(out.suffix(cap)) }
            return VoiceSample.to16k(out, rate: ringRate)
        }
    }

    /// (slot, start, end) of every segment so far, time-sorted — for tests.
    func debugSegments() -> [(Int, Double, Double)] {
        diarizer.timeline.speakers.flatMap { slot, sp in
            (sp.finalizedSegments + sp.tentativeSegments).map { (slot, Double($0.startTime) + clockStart, Double($0.endTime) + clockStart) }
        }.sorted { $0.1 < $1.1 }
    }

    /// Speaker for a phrase spanning [from, to] seconds of this recording:
    /// "me", "room2"…"room4" (mic) or "them1"…"them4" (call), or nil when the
    /// diarizer heard no speech there.
    func label(from: Double, to: Double, minSpan: Double = 0.5) -> String? {
        let a = Float(from - clockStart), b = Float(max(to, from + minSpan) - clockStart)
        guard b > 0 else { return nil }
        let speakers = diarizer.timeline.speakers
        var overlap: [Int: Float] = [:]
        for (slot, sp) in speakers {
            for seg in sp.finalizedSegments + sp.tentativeSegments {
                let o = min(b, seg.endTime) - max(a, seg.startTime)
                if o > 0 { overlap[slot, default: 0] += o }
            }
        }
        guard let best = overlap.max(by: { $0.value < $1.value })?.key else { return nil }
        if best == lock.withLock({ meSlot }) { return "me" }
        // With your voice enrolled the others are Speaker 2, 3, 4. Without it,
        // nobody is claimed as "Me" — Speaker 1, 2, 3 in order of first speech
        // (guessing "the one who talks most" was wrong 8 times out of 8 in tests).
        let first = enrolledMe == nil ? 1 : 2
        return lock.withLock {
            if let n = roomNumbers[best] { return "\(prefix)\(n)" }
            let n = max(roomNumbers.values.max().map { $0 + 1 } ?? first, first)
            roomNumbers[best] = n
            return "\(prefix)\(n)"
        }
    }
}

/// The last ~30 seconds of YOUR voice, taken from real dictations (held over
/// 1.5 s and loud enough to be speech) — clean, close-mic audio of only you.
/// Meetings enroll it as "Me". Kept on this Mac only, 16 kHz mono Float32.
final class VoiceSample: @unchecked Sendable {
    static let shared = VoiceSample()
    static let url = Config.appSupportDir.appendingPathComponent("voice-sample.f32")
    static let rate: Double = 16_000
    static let keepSeconds: Double = 30

    private let lock = NSLock()
    private var current: [Float] = []
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!

    func begin() { lock.withLock { current = [] } }

    /// A dictation buffer (any rate, any channel count) — AudioCapture's queue.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let mono = buffer.monoFloat(loudest: true), let out = resample(mono),
              let d = out.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: d[0], count: Int(out.frameLength)))
        lock.withLock { if current.count < Int(Self.rate * 60) { current += chunk } }
    }

    /// Keep this dictation: append it, trim to the newest 30 s, save.
    func commit() {
        let take = lock.withLock { () -> [Float] in defer { current = [] }; return current }
        guard take.count >= Int(Self.rate * 1.5) else { return }
        var all = (Self.load() ?? []) + take
        let keep = Int(Self.rate * Self.keepSeconds)
        if all.count > keep { all.removeFirst(all.count - keep) }
        Self.save(all)
    }

    func discard() { lock.withLock { current = [] } }

    static func load() -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count >= 4 else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func save(_ samples: [Float]) {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: url, options: .atomic)
    }

    static var seconds: Double { Double(load()?.count ?? 0) / rate }

    /// Mono samples at any rate → 16 kHz.
    static func to16k(_ samples: [Float], rate: Double) -> [Float] {
        guard !samples.isEmpty, rate != Self.rate,
              let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(samples.count)) else { return samples }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let v = VoiceSample()
        guard let out = v.resample(buf), let d = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: d[0], count: Int(out.frameLength)))
    }

    fileprivate func resample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.sampleRate == Self.rate { return buffer }
        if converterSource != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterSource = buffer.format
        }
        guard let converter else { return nil }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * Self.rate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return err == nil ? out : nil
    }
}
