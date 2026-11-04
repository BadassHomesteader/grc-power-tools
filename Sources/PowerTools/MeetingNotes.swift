import AppKit
import AVFoundation
import CoreMedia
import FoundationModels
import ScreenCaptureKit
import Speech

// Meeting Notes — a Granola-style note-taker (hold + O, menu bar, notch tile).
//
// While a meeting records, two on-device SpeechTranscriber streams run side by
// side: the MICROPHONE is "Me", and everything the Mac PLAYS (Zoom, Teams, Meet
// in a browser — captured through ScreenCaptureKit's audio tap) is "Them". No
// diarization model and no bot joining the call: the speaker split falls out of
// which wire the audio came in on. You type rough notes in the window while it
// listens; Stop (or hold + O again) finalizes the transcript and Enhance merges
// your notes with it into structured notes (Claude → OpenAI → on-device).
//
// Storage is one JSON file per meeting under
// ~/Library/Application Support/GRC Whisper/Meetings/ — deliberately NOT a
// SQLite table, so the Mac/Windows schema-parity contract is untouched. Audio is
// never written to disk; only text is kept.

// MARK: - Model

struct MeetingSegment: Codable, Equatable {
    /// "me" (microphone) or "them" (system audio).
    var speaker: String
    /// Seconds from the start of the meeting's first recording.
    var start: Double
    var text: String
}

struct Meeting: Codable {
    var id: String
    var title: String
    var created: Date
    /// Total seconds recorded across every Record/Stop run on this meeting —
    /// a resumed recording continues the timeline from here.
    var recordedSeconds: Double
    var notes: String
    var enhanced: String
    var segments: [MeetingSegment]
    /// "Home", "Work", or any user-made label; nil = no context. Optional so
    /// meeting files written before contexts existed still decode.
    var context: String?

    static func blank(context: String? = nil) -> Meeting {
        Meeting(id: UUID().uuidString, title: "", created: Date(), recordedSeconds: 0,
                notes: "", enhanced: "", segments: [], context: context)
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled meeting" : t
    }
}

enum MeetingStore {
    static var dir: URL {
        Config.appSupportDir.appendingPathComponent("Meetings", isDirectory: true)
    }

    private static func url(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Newest first. A file that fails to decode is skipped (and logged), never deleted.
    static func all() -> [Meeting] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [Meeting] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f) else { continue }
            do { out.append(try decoder.decode(Meeting.self, from: data)) } catch {
                log("meetings: skipping unreadable \(f.lastPathComponent): \(error)")
            }
        }
        return out.sorted { $0.created > $1.created }
    }

    static func save(_ m: Meeting) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try encoder.encode(m).write(to: url(m.id), options: .atomic)
        } catch {
            log("meetings: save failed for \(m.id): \(error)")
        }
    }

    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: url(id))
    }
}

// MARK: - Sidebar filtering & grouping

enum MeetingDateFilter: Int, CaseIterable {
    case any, today, week, month, year
    var title: String { ["Any date", "Today", "Last 7 days", "Last 30 days", "This year"][rawValue] }
    func includes(_ d: Date, now: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .any: return true
        case .today: return calendar.isDate(d, inSameDayAs: now)
        case .week: return d >= calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now))!
        case .month: return d >= calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now))!
        case .year: return calendar.isDate(d, equalTo: now, toGranularity: .year)
        }
    }
}

enum MeetingLengthFilter: Int, CaseIterable {
    case any, short, medium, long
    var title: String { ["Any length", "Under 15 min", "15–45 min", "Over 45 min"][rawValue] }
    func includes(_ seconds: Double) -> Bool {
        switch self {
        case .any: return true
        case .short: return seconds < 15 * 60
        case .medium: return seconds >= 15 * 60 && seconds <= 45 * 60
        case .long: return seconds > 45 * 60
        }
    }
}

enum MeetingGrouping: Int, CaseIterable {
    case date, context, none
    var title: String { ["Group: Date", "Group: Context", "Group: None"][rawValue] }
}

enum MeetingSidebarRow: Equatable {
    case header(String)
    case meeting(String)  // meeting id
}

enum MeetingSidebar {
    /// Context filter values that aren't a context name.
    static let allContexts = ""
    static let noContext = "\u{0}none"
    static let defaultContexts = ["Home", "Work"]

    /// Home and Work first, then every other label in use, A→Z.
    static func contexts(_ meetings: [Meeting]) -> [String] {
        var out = defaultContexts
        let extra = Set(meetings.compactMap { $0.context?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !out.contains($0) })
        out += extra.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return out
    }

    static func matches(_ m: Meeting, context: String, date: MeetingDateFilter,
                        length: MeetingLengthFilter, now: Date) -> Bool {
        switch context {
        case allContexts: break
        case noContext: if !(m.context ?? "").isEmpty { return false }
        default: if m.context != context { return false }
        }
        return date.includes(m.created, now: now) && length.includes(m.recordedSeconds)
    }

    /// Date buckets, newest first: Today · Yesterday · Previous 7 Days ·
    /// Previous 30 Days · then one per month.
    static func dateBucket(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: d), today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days <= 7 { return "Previous 7 Days" }
        if days <= 30 { return "Previous 30 Days" }
        let f = DateFormatter()
        f.dateFormat = calendar.isDate(d, equalTo: now, toGranularity: .year) ? "MMMM" : "MMMM yyyy"
        return f.string(from: d)
    }

    /// Filtered rows with group headers. Within every group meetings stay
    /// newest first; context groups run Home, Work, others A→Z, No context last.
    static func rows(_ meetings: [Meeting], context: String, date: MeetingDateFilter,
                     length: MeetingLengthFilter, grouping: MeetingGrouping, now: Date = Date()) -> [MeetingSidebarRow] {
        let shown = meetings.filter { matches($0, context: context, date: date, length: length, now: now) }
            .sorted { $0.created > $1.created }
        switch grouping {
        case .none:
            return shown.map { .meeting($0.id) }
        case .date:
            var out: [MeetingSidebarRow] = []
            var last: String?
            for m in shown {
                let b = dateBucket(m.created, now: now)
                if b != last { out.append(.header(b)); last = b }
                out.append(.meeting(m.id))
            }
            return out
        case .context:
            var out: [MeetingSidebarRow] = []
            let names = contexts(shown)
            for name in names {
                let group = shown.filter { $0.context == name }
                guard !group.isEmpty else { continue }
                out.append(.header(name))
                out += group.map { .meeting($0.id) }
            }
            let loose = shown.filter { !names.contains($0.context ?? "") }
            if !loose.isEmpty {
                out.append(.header("No context"))
                out += loose.map { .meeting($0.id) }
            }
            return out
        }
    }
}

// MARK: - Transcript shaping

enum MeetingText {
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Time-sorted, with mic ECHO removed: on laptop speakers the microphone
    /// also hears the other side, so the same sentence lands under "Me" a beat
    /// after (or before) it lands under "Them". A "me" segment whose words
    /// mostly appear in a "them" segment within a few seconds is that echo.
    static func cleaned(_ segments: [MeetingSegment]) -> [MeetingSegment] {
        let sorted = segments.sorted { $0.start < $1.start }
        let thems = sorted.filter { $0.speaker == "them" }.map { (start: $0.start, words: Set(words($0.text))) }
        guard !thems.isEmpty else { return sorted }
        return sorted.filter { seg in
            guard seg.speaker == "me" else { return true }
            let w = words(seg.text)
            guard w.count >= 3 else {
                // Short "me" bits ("yeah", "okay") only count as echo on an exact match.
                return !thems.contains { abs($0.start - seg.start) < 6 && !w.isEmpty && w.allSatisfy($0.words.contains) }
            }
            for t in thems where abs(t.start - seg.start) < 8 {
                let hit = w.filter { t.words.contains($0) }.count
                if Double(hit) / Double(w.count) >= 0.6 { return false }
            }
            return true
        }
    }

    /// Consecutive segments from the same speaker fold into one turn.
    static func turns(_ segments: [MeetingSegment]) -> [MeetingSegment] {
        var out: [MeetingSegment] = []
        var lastStart = -Double.infinity
        for seg in cleaned(segments) {
            let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            defer { lastStart = seg.start }
            // A pause of more than a few seconds starts a new turn even for the
            // same speaker, so a reply from the other side isn't buried mid-paragraph.
            if var last = out.last, last.speaker == seg.speaker, seg.start - lastStart < 8 {
                last.text += " " + t
                out[out.count - 1] = last
            } else {
                out.append(MeetingSegment(speaker: seg.speaker, start: seg.start, text: t))
            }
        }
        return out
    }

    static func label(_ speaker: String) -> String { speaker == "me" ? "Me" : "Them" }

    /// Plain transcript, one turn per paragraph — what Copy and the enhancer see.
    static func plain(_ m: Meeting) -> String {
        turns(m.segments).map { "[\(clock($0.start))] \(label($0.speaker)): \($0.text)" }
            .joined(separator: "\n\n")
    }

    /// Whole meeting as Markdown (sidebar ▸ Copy as Markdown).
    static func markdown(_ m: Meeting) -> String {
        var parts = ["# \(m.displayTitle)",
                     DateFormatter.localizedString(from: m.created, dateStyle: .long, timeStyle: .short)]
        if !m.enhanced.isEmpty { parts.append(m.enhanced) }
        if !m.notes.isEmpty { parts.append("## My notes\n\n" + m.notes) }
        if !m.segments.isEmpty { parts.append("## Transcript\n\n" + plain(m)) }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Audio helpers

extension AVAudioPCMBuffer {
    /// Mono Float32 copy at the same sample rate. `loudest` picks the channel
    /// with the most energy in this buffer (multi-channel docks and interfaces
    /// don't always put the mic on channel 0); otherwise channels are averaged.
    func monoFloat(loudest: Bool) -> AVAudioPCMBuffer? {
        let n = Int(frameLength)
        guard n > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                       channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frameLength),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = frameLength
        let channels = Int(format.channelCount)
        if let src = floatChannelData, !format.isInterleaved {
            if channels == 1 {
                memcpy(dst, src[0], n * MemoryLayout<Float>.size)
            } else if loudest {
                var best = 0
                var bestEnergy: Float = -1
                for c in 0..<channels {
                    var e: Float = 0
                    let p = src[c]
                    for i in Swift.stride(from: 0, to: n, by: 4) { e += p[i] * p[i] }
                    if e > bestEnergy { bestEnergy = e; best = c }
                }
                memcpy(dst, src[best], n * MemoryLayout<Float>.size)
            } else {
                let scale = 1 / Float(channels)
                for i in 0..<n {
                    var s: Float = 0
                    for c in 0..<channels { s += src[c][i] }
                    dst[i] = s * scale
                }
            }
            return out
        }
        // Anything else (interleaved / integer): let AVAudioConverter downmix.
        guard let conv = AVAudioConverter(from: format, to: mono) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return self
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }
}

extension CMSampleBuffer {
    /// ScreenCaptureKit audio sample → PCM buffer.
    func makePCMBuffer() -> AVAudioPCMBuffer? {
        guard let desc = formatDescription, var asbd = desc.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        return status == noErr ? buf : nil
    }
}

// MARK: - Live transcriber (one per speaker)

/// One long-running SpeechTranscriber stream. Unlike the dictation engine
/// (one utterance per hold), this runs for the whole meeting and reports each
/// FINALIZED phrase with its start time, plus the volatile tail for live display.
///
/// Timeline: the analyzer's clock is "seconds of audio fed". ScreenCaptureKit
/// can stop delivering audio while nothing plays, which would make "Them"
/// timestamps drift behind "Me" — so `feed` pads any wall-clock gap with
/// silence, keeping both speakers on the meeting's real clock.
final class LiveTranscriber {
    let speaker: String
    var onFinal: ((MeetingSegment) -> Void)?
    var onVolatile: ((String) -> Void)?

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let inputStream: AsyncStream<AnalyzerInput>
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let offset: Double
    private let wallClock: Bool
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private var started = false
    private var wallStart = Date()
    /// Seconds of audio yielded to the analyzer so far.
    private var fedSeconds: Double = 0

    /// `wallClock: false` is for file tests, where audio arrives faster than realtime.
    init(speaker: String, locale: Locale, offset: Double, wallClock: Bool = true) {
        self.speaker = speaker
        self.offset = offset
        self.wallClock = wallClock
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                        reportingOptions: [.volatileResults], attributeOptions: [])
        analyzer = SpeechAnalyzer(modules: [transcriber])
        (inputStream, input) = AsyncStream<AnalyzerInput>.makeStream()
    }

    func start() async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "GRCWhisper", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No compatible analyzer audio format"])
        }
        analyzerFormat = format
        let speaker = self.speaker, offset = self.offset
        resultsTask = Task { [transcriber, weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        self?.onVolatile?("")
                        guard !text.isEmpty else { continue }
                        let start = result.range.start.seconds
                        self?.onFinal?(MeetingSegment(speaker: speaker,
                                                      start: offset + (start.isFinite ? start : 0),
                                                      text: text))
                    } else {
                        self?.onVolatile?(text)
                    }
                }
            } catch {
                log("meetings: \(speaker) results ended: \(error)")
            }
        }
        try await analyzer.start(inputSequence: inputStream)
        wallStart = Date()
        started = true
    }

    /// Called from ONE capture thread per instance.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard started, let analyzerFormat, let out = convert(buffer, to: analyzerFormat) else { return }
        let duration = Double(out.frameLength) / analyzerFormat.sampleRate
        if wallClock {
            // This buffer arrived now and covers [now - duration, now].
            let bufferStart = Date().timeIntervalSince(wallStart) - duration
            let gap = bufferStart - fedSeconds
            if gap > 1.0 { padSilence(seconds: gap, format: analyzerFormat) }
        }
        input.yield(AnalyzerInput(buffer: out))
        fedSeconds += duration
    }

    private func padSilence(seconds: Double, format: AVAudioFormat) {
        var remaining = seconds
        while remaining > 0.01 {
            let chunk = min(remaining, 1.0)
            let frames = AVAudioFrameCount(chunk * format.sampleRate)
            guard frames > 0, let silent = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            silent.frameLength = frames  // freshly allocated buffers are zeroed
            input.yield(AnalyzerInput(buffer: silent))
            fedSeconds += Double(frames) / format.sampleRate
            remaining -= chunk
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converterSource != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converterSource = buffer.format
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { log("meetings: convert error \(error)"); return nil }
        return out.frameLength > 0 ? out : nil
    }

    /// Finalize: every phrase still volatile is flushed through `onFinal`.
    func finish() async {
        input.finish()
        guard started else { resultsTask?.cancel(); return }
        // Zero audio fed: the results stream never terminates after finalize
        // (same macOS 26 behavior AppleSpeechUtterance guards against).
        guard fedSeconds > 0 else {
            resultsTask?.cancel()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            return
        }
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        let reader = resultsTask
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await reader?.value }
            group.addTask { try? await Task.sleep(nanoseconds: 20_000_000_000) }
            await group.next()
            group.cancelAll()
        }
        reader?.cancel()
    }
}

// MARK: - Capture sources

/// The meeting's own microphone engine — separate from the dictation engine
/// (AudioCapture), so dictating mid-meeting and recording never fight over a tap.
final class MeetingMic {
    private let engine = AVAudioEngine()
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var observer: NSObjectProtocol?

    func start() throws {
        try installAndStart()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            log("meetings: mic configuration change, restarting")
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            try? self.installAndStart()
        }
    }

    private func installAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "GRCWhisper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No usable audio input device"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let mono = buffer.monoFloat(loudest: true) else { return }
            self?.onBuffer?(mono)
        }
        engine.prepare()
        try engine.start()
        log("meetings: mic running \(Int(format.sampleRate))Hz x\(format.channelCount)ch")
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Everything the Mac plays, minus Power Tools' own sounds — via a
/// ScreenCaptureKit stream that asks for audio and a token 2×2 video frame.
/// Needs the Screen Recording permission (the ⌘Tab strip already uses it).
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "grc-whisper.meeting.system-audio")
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onStop: ((Error) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "GRCWhisper", code: 20, userInfo: [NSLocalizedDescriptionKey: "No display to attach audio capture to"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 1
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // A screen output too, or SCK logs "stream output NOT found" per frame.
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        log("meetings: system audio capture running")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let pcm = sampleBuffer.makePCMBuffer(), let mono = pcm.monoFloat(loudest: false) else { return }
        onBuffer?(mono)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("meetings: system audio stopped: \(error)")
        onStop?(error)
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }
}

// MARK: - Recorder

/// Orchestrates mic + system audio → two LiveTranscribers. Callbacks arrive
/// on arbitrary threads; the window controller hops them to main.
final class MeetingRecorder {
    var onFinal: ((MeetingSegment) -> Void)?
    var onVolatile: ((_ speaker: String, _ text: String) -> Void)?
    var onWarning: ((String) -> Void)?

    private var mic: MeetingMic?
    private var system: SystemAudioCapture?
    private var transcribers: [LiveTranscriber] = []

    /// Returns a warning to show when only part of the meeting can be heard.
    func start(locale: Locale, offset: Double) async throws -> String? {
        try await AppleSpeechUtterance.ensureAssets(locale: locale)

        let micAllowed = await AudioCapture.requestMicPermission()
        let screenAllowed = CGPreflightScreenCaptureAccess()
        guard micAllowed || screenAllowed else {
            throw NSError(domain: "GRCWhisper", code: 21, userInfo: [NSLocalizedDescriptionKey:
                "Power Tools needs Microphone and/or Screen Recording permission to hear the meeting."])
        }
        var warnings: [String] = []

        if micAllowed {
            let t = makeTranscriber("me", locale: locale, offset: offset)
            try await t.start()
            let m = MeetingMic()
            m.onBuffer = { [weak t] in t?.feed($0) }
            do { try m.start(); mic = m } catch { warnings.append("Mic unavailable (\(error.localizedDescription))") }
        } else {
            warnings.append("Microphone permission is off — only the other side is transcribed")
        }

        if screenAllowed {
            let t = makeTranscriber("them", locale: locale, offset: offset)
            try await t.start()
            let s = SystemAudioCapture()
            s.onBuffer = { [weak t] in t?.feed($0) }
            s.onStop = { [weak self] _ in self?.onWarning?("System audio capture stopped — only your mic is being transcribed now") }
            do { try await s.start(); system = s } catch {
                warnings.append("System audio unavailable (\(error.localizedDescription))")
            }
        } else {
            CGRequestScreenCaptureAccess()
            warnings.append("Grant Screen Recording (System Settings ▸ Privacy) to transcribe the other side — mic only for now")
        }
        guard mic != nil || system != nil else {
            await stop()
            throw NSError(domain: "GRCWhisper", code: 22, userInfo: [NSLocalizedDescriptionKey:
                warnings.joined(separator: " · ")])
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: " · ")
    }

    private func makeTranscriber(_ speaker: String, locale: Locale, offset: Double) -> LiveTranscriber {
        let t = LiveTranscriber(speaker: speaker, locale: locale, offset: offset)
        t.onFinal = { [weak self] in self?.onFinal?($0) }
        t.onVolatile = { [weak self] in self?.onVolatile?(speaker, $0) }
        transcribers.append(t)
        return t
    }

    func stop() async {
        mic?.stop()
        mic = nil
        await system?.stop()
        system = nil
        let ts = transcribers
        transcribers = []
        await withTaskGroup(of: Void.self) { group in
            for t in ts { group.addTask { await t.finish() } }
        }
    }
}

// MARK: - Enhancer

enum MeetingEnhancer {
    static let instructions = """
    You turn a meeting transcript plus the user's own rough notes into clean meeting notes.

    The transcript has two speakers: "Me" is the user (their microphone) and "Them" is \
    everyone else on the call, lumped together — infer distinct people from context when \
    names are used, otherwise say "they". Transcription errors are common; read charitably \
    (e.g. "cruise" next to "crews" is probably "crews").

    Output EXACTLY this Markdown structure, in this order:

    # <specific title naming what the meeting was about — never "Meeting Notes">

    <BODY: if the user wrote notes, keep every point they wrote, in their order and \
    wording, as "-" bullets (keep their headings as "##"), each expanded with the \
    relevant specifics from the transcript — numbers, names, dates, reasons. If they \
    wrote nothing, group the discussion under 2-5 "##" topic headings of your own.>

    ## Summary
    <2-3 sentences>

    ## Decisions
    - <only things actually agreed; omit this section if none>

    ## Action items
    - [ ] <Owner> — <task> — <due date if stated>

    ## Open questions
    - <unresolved items; omit this section if none>

    Rules: concise, "-" bullets, no preamble or closing remarks, and never invent \
    facts that aren't in the notes or transcript.
    """

    static func prompt(_ m: Meeting, transcript: String) -> String {
        let notes = m.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        <MY_NOTES>
        \(notes.isEmpty ? "(none)" : notes)
        </MY_NOTES>
        <TRANSCRIPT>
        \(transcript.isEmpty ? "(no transcript)" : transcript)
        </TRANSCRIPT>
        """
    }

    /// Returns the notes and the engine that wrote them. Claude, then OpenAI,
    /// then Apple's on-device model (map-reduce over the transcript, since its
    /// context window is a few thousand tokens).
    static func enhance(_ m: Meeting, config: Config) async throws -> (text: String, engine: String) {
        let transcript = MeetingText.plain(m)
        if let key = Keychain.get("claude"), !key.isEmpty {
            let text = try await CloudPolish.claude(instructions: instructions, prompt: prompt(m, transcript: transcript),
                                                    model: config.claudeModel, apiKey: key,
                                                    maxTokens: 4096, timeout: 180)
            return (text, "Claude")
        }
        if let key = Keychain.get("openai"), !key.isEmpty {
            let text = try await CloudPolish.openai(instructions: instructions, prompt: prompt(m, transcript: transcript),
                                                    model: config.openaiModel, apiKey: key,
                                                    maxTokens: 4096, timeout: 180)
            return (text, "OpenAI")
        }
        guard Polisher.llmAvailable else {
            throw NSError(domain: "GRCWhisper", code: 23, userInfo: [NSLocalizedDescriptionKey:
                "No AI available — add a Claude or OpenAI key in Settings ▸ AI, or turn on Apple Intelligence"])
        }
        return (try await appleEnhance(m, transcript: transcript), "on-device model")
    }

    private static func appleEnhance(_ m: Meeting, transcript: String) async throws -> String {
        let words = transcript.split(whereSeparator: \.isWhitespace)
        var condensed = transcript
        if words.count > 1400 {
            var bullets: [String] = []
            var i = 0
            while i < words.count {
                let chunk = words[i..<min(i + 1200, words.count)].joined(separator: " ")
                let s = LanguageModelSession(instructions: """
                Condense this part of a meeting transcript into terse bullet points: facts, \
                numbers, names, decisions, and action items. Keep "Me"/"Them" attribution. No preamble.
                """)
                bullets.append(try await s.respond(to: chunk).content)
                i += 1200
            }
            condensed = bullets.joined(separator: "\n")
            let cw = condensed.split(whereSeparator: \.isWhitespace)
            if cw.count > 1800 { condensed = cw.prefix(1800).joined(separator: " ") + " …" }
        }
        let s = LanguageModelSession(instructions: instructions)
        return try await s.respond(to: prompt(m, transcript: condensed)).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits a leading "# Title" line off the model output.
    static func splitTitle(_ text: String) -> (title: String?, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("# ") else { return (nil, trimmed) }
        let firstLine = trimmed.prefix { $0 != "\n" }
        let title = firstLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
        let body = trimmed.dropFirst(firstLine.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? nil : title, body)
    }
}

// MARK: - Window

final class MeetingNotesWindow: NSWindow {}

@MainActor
final class MeetingNotesController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
                                    NSTableViewDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private var config: Config
    private(set) var meetings: [Meeting] = []
    private var selectedID: String?
    private(set) var recordingID: String?
    private var recorder: MeetingRecorder?
    private var recordStart: Date?
    private var baseSeconds: Double = 0
    private var volatile: [String: String] = [:]
    private var enhancing: Set<String> = []
    private var dirty: Set<String> = []
    private var saveWork: DispatchWorkItem?
    private var ticker: Timer?
    private var tab = 0  // 0 My Notes · 1 Enhanced · 2 Transcript
    private var suppressTextEvents = false

    // Sidebar filters — a per-Mac view preference, kept in UserDefaults (not
    // config.json, so the Windows schema contract is untouched).
    private var rows: [MeetingSidebarRow] = []
    private var contextFilter = UserDefaults.standard.string(forKey: "meetings.filter.context") ?? MeetingSidebar.allContexts
    private var dateFilter = MeetingDateFilter(rawValue: UserDefaults.standard.integer(forKey: "meetings.filter.date")) ?? .any
    private var lengthFilter = MeetingLengthFilter(rawValue: UserDefaults.standard.integer(forKey: "meetings.filter.length")) ?? .any
    private var grouping = MeetingGrouping(rawValue: UserDefaults.standard.integer(forKey: "meetings.filter.grouping")) ?? .date

    /// Fired whenever recording starts or stops (status menu / notch can mirror it).
    var onRecordingChange: ((Bool) -> Void)?

    var isRecording: Bool { recordingID != nil }

    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let newButton = NSButton(title: "New Meeting", target: nil, action: nil)
    private let titleField = NSTextField()
    private let timeLabel = NSTextField(labelWithString: "")
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private let tabs = NSSegmentedControl(labels: ["My Notes", "Enhanced", "Transcript"],
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let enhanceButton = NSButton(title: "Enhance", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let textScroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { textScroll.documentView as! NSTextView }
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyState = NSTextField(wrappingLabelWithString: "")
    private let contextPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let datePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let lengthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let groupPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let noMatch = NSTextField(wrappingLabelWithString: "No meetings match these filters.")
    private let clearFiltersButton = NSButton(title: "Clear Filters", target: nil, action: nil)
    /// The open meeting's own context, beside its title.
    private let meetingContextPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(config: Config) {
        self.config = config
        let window = MeetingNotesWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Meeting Notes"
        window.center()
        window.setFrameAutosaveName("GRCWhisperMeetings")
        window.minSize = NSSize(width: 680, height: 420)
        window.isReleasedWhenClosed = false  // closing hides; a recording keeps going
        super.init(window: window)
        window.delegate = self
        buildUI()
        applyAppearance()
        meetings = MeetingStore.all()
        if contextFilter != MeetingSidebar.allContexts, contextFilter != MeetingSidebar.noContext,
           !MeetingSidebar.contexts(meetings).contains(contextFilter) {
            contextFilter = MeetingSidebar.allContexts  // that label's last meeting was deleted
        }
        reloadSidebar()
        selectedID = rows.lazy.compactMap { if case .meeting(let id) = $0 { return id } else { return nil } }.first
            ?? meetings.first?.id
        selectRow(for: selectedID)
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Public

    func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if tab == 0 { window?.makeFirstResponder(textView) }
    }

    func updateConfig(_ c: Config) {
        config = c
        applyAppearance()
    }

    /// hold + O: start a fresh meeting (or reuse the selected one if it's still
    /// untouched by a recording), or stop the running one and enhance it.
    func toggleRecording() {
        if isRecording { stopRecording(autoEnhance: true); return }
        if let m = selected, m.segments.isEmpty, m.enhanced.isEmpty, m.recordedSeconds == 0 {
            record(into: m.id)
        } else {
            newMeeting()
            if let id = selectedID { record(into: id) }
        }
    }

    /// Offscreen design check (`meeting-preview`).
    func previewSeed() {
        var m = Meeting.blank()
        m.title = "Q4 field rollout sync"
        m.recordedSeconds = 1712
        m.notes = "- pilot crews: 3 → 5?\n- meter backlog\n- Rhett to send updated map"
        m.segments = [
            .init(speaker: "them", start: 4, text: "Okay, I think everyone's here. Let's start with the pilot crews."),
            .init(speaker: "me", start: 9, text: "Sure. We're running three crews right now and the backlog is about eleven hundred meters."),
            .init(speaker: "them", start: 18, text: "Can we get to five crews before Thanksgiving?"),
            .init(speaker: "me", start: 23, text: "If the trucks come in by the fifteenth, yes."),
            .init(speaker: "them", start: 31, text: "Great. Rhett will send the updated map by Friday."),
        ]
        m.enhanced = "## Pilot crews\n- Running 3 crews today; target 5 before Thanksgiving, contingent on trucks arriving by Nov 15\n\n## Meter backlog\n- ~1,100 meters outstanding\n\n## Action items\n- [ ] Rhett — send updated map — Friday"
        m.context = "Work"
        func past(_ title: String, days: Int, minutes: Double, _ context: String?) -> Meeting {
            var x = Meeting.blank(context: context)
            x.title = title
            x.created = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
            x.recordedSeconds = minutes * 60
            return x
        }
        meetings = [m,
                    past("Contractor walkthrough — barn roof", days: 0, minutes: 22, "Home"),
                    past("Weekly ops standup", days: 1, minutes: 14, "Work"),
                    past("APS routing review", days: 4, minutes: 51, "Work"),
                    past("Vet call — goats", days: 6, minutes: 9, "Home"),
                    past("DialAI advisory", days: 19, minutes: 38, "Advisory"),
                    past("Quick sync", days: 45, minutes: 6, nil)]
        selectedID = m.id
        reloadSidebar()
        tab = 2
        tabs.selectedSegment = 2
        render()
    }

    func previewFilters(context: String?, date: Int?, length: Int?) {
        if let context { contextFilter = context == "none" ? MeetingSidebar.noContext : context }
        if let date { dateFilter = MeetingDateFilter(rawValue: date) ?? .any }
        if let length { lengthFilter = MeetingLengthFilter(rawValue: length) ?? .any }
        reloadSidebar()
    }

    func previewGroup(_ g: MeetingGrouping) {
        grouping = g
        reloadSidebar()
    }

    func previewTab(_ t: Int) {
        tab = t
        tabs.selectedSegment = t
        render()
    }

    // MARK: Model helpers

    private var selected: Meeting? { meetings.first { $0.id == selectedID } }
    private func index(_ id: String?) -> Int? { meetings.firstIndex { $0.id == id } }

    private func newMeeting() {
        // A new meeting joins the context being looked at, so it doesn't vanish
        // from the list the moment it's made.
        let inherit = (contextFilter == MeetingSidebar.allContexts || contextFilter == MeetingSidebar.noContext)
            ? nil : contextFilter
        let m = Meeting.blank(context: inherit)
        meetings.insert(m, at: 0)
        MeetingStore.save(m)
        selectedID = m.id
        // A 0-minute meeting fails "Over 45 min" etc. — widen date/length so it shows.
        if !MeetingSidebar.matches(m, context: contextFilter, date: dateFilter, length: lengthFilter, now: Date()) {
            dateFilter = .any
            lengthFilter = .any
            saveFilters()
        }
        reloadSidebar()
        tab = 0
        tabs.selectedSegment = 0
        render()
        window?.makeFirstResponder(titleField)
    }

    private func markDirty(_ id: String) {
        dirty.insert(id)
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSaves() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func flushSaves() {
        for id in dirty { if let i = index(id) { MeetingStore.save(meetings[i]) } }
        dirty.removeAll()
    }

    // MARK: Recording

    private func record(into id: String) {
        guard recordingID == nil, let i = index(id) else { return }
        recordingID = id
        baseSeconds = meetings[i].recordedSeconds
        recordStart = Date()
        volatile = [:]
        let rec = MeetingRecorder()
        recorder = rec
        rec.onFinal = { seg in
            DispatchQueue.main.async { [weak self] in self?.append(seg, to: id) }
        }
        rec.onVolatile = { speaker, text in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.recordingID == id else { return }
                self.volatile[speaker] = text
                if self.selectedID == id, self.tab == 2 { self.renderTranscript() }
            }
        }
        rec.onWarning = { text in DispatchQueue.main.async { [weak self] in self?.setStatus(text, warn: true) } }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock() }
        }
        setStatus("Starting…")
        updateChrome()
        onRecordingChange?(true)
        log("meetings: recording \(id)")
        let locale = Locale(identifier: config.localeIdentifier)
        Task { @MainActor in
            do {
                let warning = try await rec.start(locale: locale, offset: baseSeconds)
                guard self.recordingID == id else { return }
                if let warning { self.setStatus(warning, warn: true) }
                else { self.setStatus("Listening — your mic is “Me”, everything the Mac plays is “Them”. Type notes as you go.") }
            } catch {
                log("meetings: start failed: \(error)")
                await rec.stop()
                self.endRecordingState()
                self.setStatus("Couldn't start recording: \(error.localizedDescription)", warn: true)
            }
        }
    }

    func stopRecording(autoEnhance: Bool) {
        guard let id = recordingID, let rec = recorder, recordButton.isEnabled else { return }
        recordButton.isEnabled = false
        setStatus("Finishing the transcript…")
        Task { @MainActor in
            await rec.stop()
            // Let finals dispatched during stop() land before anything reads them.
            DispatchQueue.main.async {
                if let i = self.index(id), let start = self.recordStart {
                    self.meetings[i].recordedSeconds = self.baseSeconds + Date().timeIntervalSince(start)
                    MeetingStore.save(self.meetings[i])
                }
                self.endRecordingState()
                let hasText = self.meetings.first { $0.id == id }.map { !$0.segments.isEmpty } ?? false
                if autoEnhance, hasText { self.enhance(id) } else {
                    self.setStatus(hasText ? "Saved." : "Saved — no speech was transcribed.")
                }
            }
        }
    }

    private func endRecordingState() {
        recordingID = nil
        recorder = nil
        volatile = [:]
        ticker?.invalidate()
        ticker = nil
        recordButton.isEnabled = true
        updateChrome()
        render()
        reloadSidebar()
        onRecordingChange?(false)
    }

    private func append(_ seg: MeetingSegment, to id: String) {
        guard let i = index(id) else { return }
        meetings[i].segments.append(seg)
        markDirty(id)
        if selectedID == id, tab == 2 { renderTranscript() }
    }

    private func updateClock() {
        guard isRecording, let start = recordStart else { timeLabel.stringValue = ""; return }
        timeLabel.stringValue = "● " + MeetingText.clock(baseSeconds + Date().timeIntervalSince(start))
    }

    // MARK: Enhance

    private func enhance(_ id: String) {
        guard !enhancing.contains(id), let m = meetings.first(where: { $0.id == id }) else { return }
        guard !m.segments.isEmpty || !m.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setStatus("Nothing to enhance yet — record the meeting or type some notes first.", warn: true)
            return
        }
        flushSaves()
        enhancing.insert(id)
        updateChrome()
        setStatus("Writing enhanced notes…")
        let cfg = config
        Task { @MainActor in
            defer { self.enhancing.remove(id); self.updateChrome() }
            do {
                let (raw, engine) = try await MeetingEnhancer.enhance(m, config: cfg)
                guard let i = self.index(id) else { return }
                let (title, body) = MeetingEnhancer.splitTitle(raw)
                self.meetings[i].enhanced = body
                if let title, title.lowercased() != "meeting notes",
                   self.meetings[i].title.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.meetings[i].title = title
                }
                MeetingStore.save(self.meetings[i])
                self.reloadSidebar()
                if self.selectedID == id {
                    self.tab = 1
                    self.tabs.selectedSegment = 1
                    self.render()
                }
                self.setStatus("Enhanced with \(engine).")
            } catch {
                log("meetings: enhance failed: \(error)")
                self.setStatus("Enhance failed: \(error.localizedDescription)", warn: true)
            }
        }
    }

    // MARK: Actions

    @objc private func recordClicked() {
        if isRecording { stopRecording(autoEnhance: true); return }
        if selected == nil { newMeeting() }
        if let id = selectedID { record(into: id) }
    }

    @objc private func newClicked() { newMeeting() }

    @objc private func tabChanged() {
        tab = tabs.selectedSegment
        render()
    }

    @objc private func enhanceClicked() {
        if let id = selectedID { enhance(id) }
    }

    @objc private func copyClicked() {
        guard let m = selected else { return }
        let text: String
        switch tab {
        case 0: text = m.notes
        case 1: text = m.enhanced.isEmpty ? MeetingText.markdown(m) : "# \(m.displayTitle)\n\n\(m.enhanced)"
        default: text = MeetingText.plain(m)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setStatus("Copied.")
    }

    /// The meeting under a right-click, else the selected row.
    private func targetMeeting() -> Meeting? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard let id = meetingID(atRow: row) else { return nil }
        return meetings.first { $0.id == id }
    }

    @objc private func copyMarkdown() {
        guard let m = targetMeeting() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MeetingText.markdown(m), forType: .string)
        setStatus("Copied the whole meeting as Markdown.")
    }

    @objc private func deleteMeeting() {
        guard let m = targetMeeting(), let window else { return }
        guard m.id != recordingID else { setStatus("Stop the recording before deleting this meeting.", warn: true); return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(m.displayTitle)”?"
        alert.informativeText = "Its notes and transcript are removed from this Mac. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            MeetingStore.delete(m.id)
            self.dirty.remove(m.id)
            self.meetings.removeAll { $0.id == m.id }
            if self.selectedID == m.id { self.selectedID = self.firstVisibleID() ?? self.meetings.first?.id }
            self.reloadSidebar()
            self.render()
        }
    }

    // MARK: Rendering

    private func setStatus(_ text: String, warn: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = warn ? .systemOrange : .secondaryLabelColor
    }

    private func updateChrome() {
        let recordingThis = recordingID != nil && recordingID == selectedID
        if isRecording {
            recordButton.title = recordingThis ? "Stop" : "Stop (other meeting)"
            recordButton.bezelColor = .systemRed
            window?.title = "● Recording — Meeting Notes"
        } else {
            let resumable = (selected?.recordedSeconds ?? 0) > 0
            recordButton.title = resumable ? "Resume" : "Record"
            recordButton.bezelColor = nil
            window?.title = "Meeting Notes"
            timeLabel.stringValue = ""
        }
        let busy = selectedID.map { enhancing.contains($0) } ?? false
        enhanceButton.isEnabled = selected != nil && !busy && !recordingThis
        enhanceButton.title = busy ? "Enhancing…" : ((selected?.enhanced.isEmpty ?? true) ? "Enhance" : "Re-enhance")
        copyButton.isEnabled = selected != nil
        updateClock()
    }

    private func render() {
        let has = selected != nil
        for v in [titleField, meetingContextPopup, tabs, textScroll, enhanceButton, copyButton] as [NSView] { v.isHidden = !has }
        rebuildMeetingContextPopup()
        emptyState.isHidden = has
        updateChrome()
        guard let m = selected else { hint.isHidden = true; return }
        if titleField.currentEditor() == nil { titleField.stringValue = m.title }
        suppressTextEvents = true
        defer { suppressTextEvents = false }
        switch tab {
        case 0:
            setPlain(m.notes, editable: true)
            hint.stringValue = "Type rough notes while the meeting runs — a few words per point is plenty. Enhance keeps them as the outline and fills in the details from the transcript."
            hint.isHidden = !m.notes.isEmpty
        case 1:
            setPlain(m.enhanced, editable: true)
            hint.stringValue = m.segments.isEmpty && m.notes.isEmpty
                ? "Record the meeting (or type notes), then Enhance to get a summary, decisions, and action items."
                : "Nothing here yet — click Enhance."
            hint.isHidden = !m.enhanced.isEmpty
        default:
            renderTranscript()
        }
    }

    private static let plainAttributes: [NSAttributedString.Key: Any] = {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        return [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor, .paragraphStyle: para]
    }()

    /// Replaces the text AND its attributes — the transcript tab's styling must
    /// not leak into the editable tabs (or into what the user types next).
    private func setPlain(_ s: String, editable: Bool) {
        textView.isEditable = editable
        textView.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: Self.plainAttributes))
        textView.typingAttributes = Self.plainAttributes
    }

    private func renderTranscript() {
        guard tab == 2, let m = selected else { return }
        let clip = textScroll.contentView
        let atBottom = clip.bounds.maxY >= (textView.frame.height - 24)
        let body = NSMutableAttributedString()
        let stamp: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                    .foregroundColor: NSColor.tertiaryLabelColor]
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 10
        para.lineSpacing = 2
        func speaker(_ s: String) -> [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
             .foregroundColor: s == "me" ? NSColor.systemBlue : NSColor.systemPurple]
        }
        let text: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]
        for turn in MeetingText.turns(m.segments) {
            body.append(NSAttributedString(string: MeetingText.clock(turn.start) + "  ", attributes: stamp))
            body.append(NSAttributedString(string: MeetingText.label(turn.speaker) + "  ", attributes: speaker(turn.speaker)))
            body.append(NSAttributedString(string: turn.text + "\n", attributes: text))
        }
        if recordingID == m.id {
            let live: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor]
            for sp in ["them", "me"] {
                guard let v = volatile[sp], !v.isEmpty else { continue }
                body.append(NSAttributedString(string: "…  ", attributes: stamp))
                body.append(NSAttributedString(string: MeetingText.label(sp) + "  ", attributes: speaker(sp)))
                body.append(NSAttributedString(string: v + "\n", attributes: live))
            }
        }
        body.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: body.length))
        suppressTextEvents = true
        textView.isEditable = false
        textView.textStorage?.setAttributedString(body)
        suppressTextEvents = false
        hint.stringValue = recordingID == m.id ? "Listening… the transcript appears here as people speak."
                                              : "No transcript — click Record when the meeting starts."
        hint.isHidden = body.length > 0
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    private func selectRow(for id: String?) {
        guard let id, let row = rows.firstIndex(of: .meeting(id)) else { table.deselectAll(nil); return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func meetingID(atRow row: Int) -> String? {
        guard rows.indices.contains(row), case .meeting(let id) = rows[row] else { return nil }
        return id
    }

    private func firstVisibleID() -> String? {
        rows.lazy.compactMap { if case .meeting(let id) = $0 { return id } else { return nil } }.first
    }

    // MARK: Filters & contexts

    private func saveFilters() {
        let d = UserDefaults.standard
        d.set(contextFilter, forKey: "meetings.filter.context")
        d.set(dateFilter.rawValue, forKey: "meetings.filter.date")
        d.set(lengthFilter.rawValue, forKey: "meetings.filter.length")
        d.set(grouping.rawValue, forKey: "meetings.filter.grouping")
    }

    /// Recompute rows from the filters, redraw, keep the selection, and
    /// refresh every popup (the context list grows as labels are used).
    private func reloadSidebar() {
        rows = MeetingSidebar.rows(meetings, context: contextFilter, date: dateFilter,
                                   length: lengthFilter, grouping: grouping)
        table.reloadData()
        selectRow(for: selectedID)
        let filtered = contextFilter != MeetingSidebar.allContexts || dateFilter != .any || lengthFilter != .any
        noMatch.isHidden = !(rows.isEmpty && !meetings.isEmpty)
        clearFiltersButton.isHidden = noMatch.isHidden || !filtered
        rebuildFilterPopups()
        rebuildMeetingContextPopup()
    }

    private func rebuildFilterPopups() {
        contextPopup.removeAllItems()
        contextPopup.addItem(withTitle: "All contexts")
        contextPopup.lastItem?.representedObject = MeetingSidebar.allContexts
        contextPopup.menu?.addItem(.separator())
        for name in MeetingSidebar.contexts(meetings) {
            contextPopup.addItem(withTitle: name)
            contextPopup.lastItem?.representedObject = name
        }
        contextPopup.menu?.addItem(.separator())
        contextPopup.addItem(withTitle: "No context")
        contextPopup.lastItem?.representedObject = MeetingSidebar.noContext
        let idx = contextPopup.itemArray.firstIndex { ($0.representedObject as? String) == contextFilter } ?? 0
        contextPopup.selectItem(at: idx)

        datePopup.removeAllItems()
        datePopup.addItems(withTitles: MeetingDateFilter.allCases.map(\.title))
        datePopup.selectItem(at: dateFilter.rawValue)
        lengthPopup.removeAllItems()
        lengthPopup.addItems(withTitles: MeetingLengthFilter.allCases.map(\.title))
        lengthPopup.selectItem(at: lengthFilter.rawValue)
        groupPopup.removeAllItems()
        groupPopup.addItems(withTitles: MeetingGrouping.allCases.map(\.title))
        groupPopup.selectItem(at: grouping.rawValue)
    }

    private func rebuildMeetingContextPopup() {
        let p = meetingContextPopup
        p.removeAllItems()
        p.addItem(withTitle: "No context")
        p.lastItem?.representedObject = ""
        p.menu?.addItem(.separator())
        for name in MeetingSidebar.contexts(meetings) {
            p.addItem(withTitle: name)
            p.lastItem?.representedObject = name
        }
        p.menu?.addItem(.separator())
        p.addItem(withTitle: "New Context…")
        p.lastItem?.representedObject = "\u{0}new"
        let current = selected?.context ?? ""
        p.selectItem(at: p.itemArray.firstIndex { ($0.representedObject as? String) == current } ?? 0)
    }

    @objc private func filterChanged(_ sender: NSPopUpButton) {
        switch sender {
        case contextPopup:
            contextFilter = (sender.selectedItem?.representedObject as? String) ?? MeetingSidebar.allContexts
        case datePopup: dateFilter = MeetingDateFilter(rawValue: sender.indexOfSelectedItem) ?? .any
        case lengthPopup: lengthFilter = MeetingLengthFilter(rawValue: sender.indexOfSelectedItem) ?? .any
        default: grouping = MeetingGrouping(rawValue: sender.indexOfSelectedItem) ?? .date
        }
        saveFilters()
        reloadSidebar()
    }

    @objc private func clearFilters() {
        contextFilter = MeetingSidebar.allContexts
        dateFilter = .any
        lengthFilter = .any
        saveFilters()
        reloadSidebar()
    }

    @objc private func meetingContextChanged(_ sender: NSPopUpButton) {
        guard let id = selectedID else { return }
        let value = (sender.selectedItem?.representedObject as? String) ?? ""
        if value == "\u{0}new" { askForNewContext(id); return }
        setContext(value.isEmpty ? nil : value, for: id)
    }

    private func setContext(_ context: String?, for id: String) {
        guard let i = index(id) else { return }
        meetings[i].context = context
        MeetingStore.save(meetings[i])
        dirty.remove(id)
        reloadSidebar()
        if let context { setStatus("Filed under \(context).") } else { setStatus("Context cleared.") }
    }

    private func askForNewContext(_ id: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "New context"
        alert.informativeText = "A label for grouping and filtering meetings — e.g. Clients, Family, Board."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Context name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else {
                self.rebuildMeetingContextPopup()  // put the popup back on the real value
                return
            }
            // Reuse an existing label that differs only by case.
            let existing = MeetingSidebar.contexts(self.meetings)
                .first { $0.caseInsensitiveCompare(name) == .orderedSame }
            self.setContext(existing ?? name, for: id)
        }
    }

    private func applyAppearance() {
        window?.appearance = NSAppearance(named: config.appearance.isDark ? .darkAqua : .aqua)
    }

    // MARK: Delegates

    func textDidChange(_ notification: Notification) {
        guard !suppressTextEvents, let i = index(selectedID) else { return }
        switch tab {
        case 0: meetings[i].notes = textView.string; hint.isHidden = !textView.string.isEmpty
        case 1: meetings[i].enhanced = textView.string; hint.isHidden = !textView.string.isEmpty
        default: return
        }
        markDirty(meetings[i].id)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === titleField, let i = index(selectedID) else { return }
        meetings[i].title = titleField.stringValue
        markDirty(meetings[i].id)
        if let row = rows.firstIndex(of: .meeting(meetings[i].id)) {
            table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
    }

    func windowWillClose(_ notification: Notification) { flushSaves() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        meetingID(atRow: row) != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 26 }
        return 46
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if case .header(let name) = rows[row] {
            let hid = NSUserInterfaceItemIdentifier("meetingHeader")
            let h = (tableView.makeView(withIdentifier: hid, owner: self) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = hid
                let label = NSTextField(labelWithString: "")
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(label)
                c.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                    label.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                    label.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -4),
                ])
                return c
            }()
            h.textField?.stringValue = name
            return h
        }
        let id = NSUserInterfaceItemIdentifier("meetingCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? MeetingCell) ?? {
            let c = MeetingCell(); c.identifier = id; return c
        }()
        guard let mid = meetingID(atRow: row), let m = meetings.first(where: { $0.id == mid }) else { return cell }
        cell.title.stringValue = m.displayTitle
        var sub = MeetingCell.dateFormatter.string(from: m.created)
        if m.id == recordingID { sub = "● Recording" }
        else if m.recordedSeconds >= 60 { sub += " · \(Int(m.recordedSeconds / 60)) min" }
        // The context rides the subtitle unless the list is already grouped by it.
        if grouping != .context, let c = m.context, !c.isEmpty { sub += " · \(c)" }
        cell.subtitle.stringValue = sub
        cell.subtitle.textColor = m.id == recordingID ? .systemRed : .secondaryLabelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let id = meetingID(atRow: table.selectedRow), id != selectedID else { return }
        window?.makeFirstResponder(nil)  // commit any title edit to the old meeting
        selectedID = id
        render()
    }

    // MARK: Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("m"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 46
        table.style = .sourceList
        table.floatsGroupRows = false
        table.dataSource = self
        table.delegate = self
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy as Markdown", action: #selector(copyMarkdown), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete Meeting…", action: #selector(deleteMeeting), keyEquivalent: "").target = self
        table.menu = menu
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false

        for p in [contextPopup, datePopup, lengthPopup, groupPopup] {
            p.controlSize = .small
            p.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            p.target = self
            p.action = #selector(filterChanged(_:))
            p.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        noMatch.font = .systemFont(ofSize: 12)
        noMatch.textColor = .secondaryLabelColor
        noMatch.alignment = .center
        noMatch.isHidden = true
        clearFiltersButton.target = self
        clearFiltersButton.action = #selector(clearFilters)
        clearFiltersButton.bezelStyle = .rounded
        clearFiltersButton.controlSize = .small
        clearFiltersButton.isHidden = true
        meetingContextPopup.controlSize = .small
        meetingContextPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        meetingContextPopup.target = self
        meetingContextPopup.action = #selector(meetingContextChanged(_:))

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow

        newButton.target = self
        newButton.action = #selector(newClicked)
        newButton.bezelStyle = .rounded
        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        newButton.imagePosition = .imageLeading

        let divider = NSBox()
        divider.boxType = .separator
        // The editor pane paints its own ground (dynamic, so it follows the
        // Lite/Dark setting) instead of relying on the window background.
        let paper = NSBox()
        paper.boxType = .custom
        paper.borderWidth = 0
        paper.fillColor = .textBackgroundColor

        titleField.placeholderString = "Untitled meeting"
        titleField.font = .systemFont(ofSize: 20, weight: .semibold)
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.delegate = self
        titleField.lineBreakMode = .byTruncatingTail

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.textColor = .systemRed

        recordButton.target = self
        recordButton.action = #selector(recordClicked)
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .large
        recordButton.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        recordButton.imagePosition = .imageLeading

        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0

        enhanceButton.target = self
        enhanceButton.action = #selector(enhanceClicked)
        enhanceButton.bezelStyle = .rounded
        enhanceButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        enhanceButton.imagePosition = .imageLeading
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.bezelStyle = .rounded

        textScroll.drawsBackground = false
        textScroll.borderType = .noBorder
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: 14)

        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .tertiaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        emptyState.stringValue = "No meetings yet.\n\nClick Record when a call starts (or hold the Power Tools hotkey + O). Your mic is transcribed as “Me” and whatever the Mac plays as “Them” — all on this Mac. Type rough notes alongside; Enhance turns them into clean notes with action items."
        emptyState.font = .systemFont(ofSize: 14)
        emptyState.textColor = .secondaryLabelColor
        emptyState.alignment = .center

        let views: [NSView] = [paper, sidebar, tableScroll, newButton, contextPopup, datePopup, lengthPopup, groupPopup,
                               noMatch, clearFiltersButton, meetingContextPopup,
                               divider, titleField, timeLabel, recordButton,
                               tabs, enhanceButton, copyButton, textScroll, hint, statusLabel, emptyState]
        for v in views { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let sideW: CGFloat = 250
        let pad: CGFloat = 20
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: sideW),

            newButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            newButton.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            newButton.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),

            contextPopup.topAnchor.constraint(equalTo: newButton.bottomAnchor, constant: 10),
            contextPopup.leadingAnchor.constraint(equalTo: newButton.leadingAnchor),
            contextPopup.trailingAnchor.constraint(equalTo: sidebar.centerXAnchor, constant: -3),
            datePopup.centerYAnchor.constraint(equalTo: contextPopup.centerYAnchor),
            datePopup.leadingAnchor.constraint(equalTo: sidebar.centerXAnchor, constant: 3),
            datePopup.trailingAnchor.constraint(equalTo: newButton.trailingAnchor),
            lengthPopup.topAnchor.constraint(equalTo: contextPopup.bottomAnchor, constant: 6),
            lengthPopup.leadingAnchor.constraint(equalTo: contextPopup.leadingAnchor),
            lengthPopup.trailingAnchor.constraint(equalTo: contextPopup.trailingAnchor),
            groupPopup.centerYAnchor.constraint(equalTo: lengthPopup.centerYAnchor),
            groupPopup.leadingAnchor.constraint(equalTo: datePopup.leadingAnchor),
            groupPopup.trailingAnchor.constraint(equalTo: datePopup.trailingAnchor),

            noMatch.topAnchor.constraint(equalTo: tableScroll.topAnchor, constant: 24),
            noMatch.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            noMatch.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            clearFiltersButton.topAnchor.constraint(equalTo: noMatch.bottomAnchor, constant: 8),
            clearFiltersButton.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor),

            tableScroll.topAnchor.constraint(equalTo: lengthPopup.bottomAnchor, constant: 8),
            tableScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            paper.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            paper.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            paper.topAnchor.constraint(equalTo: content.topAnchor),
            paper.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            recordButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            recordButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            timeLabel.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: recordButton.leadingAnchor, constant: -10),

            titleField.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: pad),
            meetingContextPopup.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
            meetingContextPopup.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 8),
            meetingContextPopup.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -12),

            tabs.topAnchor.constraint(equalTo: recordButton.bottomAnchor, constant: 14),
            tabs.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            copyButton.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            enhanceButton.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            enhanceButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),

            textScroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
            textScroll.leadingAnchor.constraint(equalTo: titleField.leadingAnchor, constant: -4),
            textScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad + 4),
            textScroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            hint.topAnchor.constraint(equalTo: textScroll.topAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: textScroll.leadingAnchor, constant: 9),
            hint.trailingAnchor.constraint(equalTo: textScroll.trailingAnchor, constant: -9),

            statusLabel.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

            emptyState.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            emptyState.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 60),
            emptyState.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -60),
        ])
    }
}

/// Sidebar row: title over date/duration.
final class MeetingCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        for v in [title, subtitle] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - CLI test path (`meeting-test`)

/// Transcribe audio files through the SAME LiveTranscriber the app uses — the
/// first file as "me", the second (optional) as "them" — with no microphone,
/// ScreenCaptureKit, or TCC involved. Returns the assembled meeting.
func meetingTestRun(me: URL, them: URL?, locale: Locale) async throws -> Meeting {
    try await AppleSpeechUtterance.ensureAssets(locale: locale)
    var m = Meeting.blank()
    let collected = SegmentBox()
    for (speaker, url) in [("me", me), ("them", them)] {
        guard let url else { continue }
        let t = LiveTranscriber(speaker: speaker, locale: locale, offset: 0, wallClock: false)
        t.onFinal = { collected.add($0) }
        try await t.start()
        let file = try AVAudioFile(forReading: url)
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
            try file.read(into: buf, frameCount: 4096)
            if buf.frameLength == 0 { break }
            if let mono = buf.monoFloat(loudest: speaker == "me") { t.feed(mono) }
        }
        await t.finish()
        m.recordedSeconds = max(m.recordedSeconds, Double(file.length) / file.processingFormat.sampleRate)
    }
    m.segments = collected.all()
    return m
}

private final class SegmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MeetingSegment] = []
    func add(_ s: MeetingSegment) { lock.lock(); items.append(s); lock.unlock() }
    func all() -> [MeetingSegment] { lock.lock(); defer { lock.unlock() }; return items }
}
