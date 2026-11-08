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
// bot joins the call: that split falls out of which wire the audio came in on.
// People in the ROOM share the mic, so an on-device diarizer (RoomDiarizer)
// splits the mic into "Me" (your enrolled voice) and "Speaker 2", "3"…. You type rough notes in the window while it
// listens; Stop (or hold + O again) finalizes the transcript and Enhance merges
// your notes with it into structured notes (Claude → OpenAI → on-device).
//
// Storage is one JSON file per meeting under
// ~/Library/Application Support/GRC Whisper/Meetings/ — deliberately NOT a
// SQLite table, so the Mac/Windows schema-parity contract is untouched. Audio is
// never written to disk; only text is kept. Pictures pasted into notes live in
// Meetings/<id>/ next to the JSON (see MeetingPictures.swift).

// MARK: - Model

struct MeetingSegment: Codable, Equatable {
    /// "me" (you), "room1"…"room4" (others at the mic, from RoomDiarizer),
    /// "them1"…"them4" (people on the call, by voice), or "them" (the call,
    /// before its voice model loaded or with Room speakers off).
    var speaker: String
    /// Seconds from the start of the meeting's first recording.
    var start: Double
    var text: String
    /// End of the phrase, same clock. Optional: older meeting files lack it.
    var end: Double? = nil
}

/// One word of a mic phrase with its time — what lets a phrase that runs
/// across two people in the room be split between them. Not stored.
struct MeetingWord {
    var text: String
    var start: Double
    var end: Double
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
    /// The OneNote page this meeting was last sent to (re-sending replaces it).
    var oneNotePageID: String?
    var oneNoteURL: String?
    /// The live assist list (action items / questions / decisions), Markdown.
    var live: String?
    /// The meeting's agenda as pasted/loaded — one topic per line, or a whole
    /// invite. Live checks items off as they're discussed; Enhance reports coverage.
    var agenda: String?
    /// Names the user gave speakers in this meeting: "them1" → "Ralph".
    var speakerNames: [String: String]?

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
        try? FileManager.default.removeItem(at: MeetingImages.dir(id))  // its pictures
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
        let thems = sorted.filter { isCall($0.speaker) }.map { (start: $0.start, words: Set(words($0.text))) }
        guard !thems.isEmpty else { return sorted }
        return sorted.filter { seg in
            guard !isCall(seg.speaker) else { return true }   // any mic speaker can echo the call
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

    /// The call side: "them", or "them1"… once the call's voices are told apart.
    static func isCall(_ speaker: String) -> Bool { speaker.hasPrefix("them") }

    /// Display name: a name the user gave this speaker in this meeting, else
    /// Me / Speaker N (room) / Them N (call) / Them.
    static func label(_ speaker: String, names: [String: String]? = nil) -> String {
        if let n = names?[speaker]?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        switch speaker {
        case "me": return "Me"
        case "them": return "Them"
        default:
            if speaker.hasPrefix("room") { return "Speaker \(speaker.dropFirst(4))" }
            if speaker.hasPrefix("them") { return "Them \(speaker.dropFirst(4))" }
            return speaker.capitalized
        }
    }

    static func color(_ speaker: String) -> NSColor {
        switch speaker {
        case "me": return .systemBlue
        case "them", "them1": return .systemPurple
        case "them2": return .systemIndigo
        case "them3": return .systemBrown
        case "them4": return .systemCyan
        case "room1": return .systemPink
        case "room2": return .systemGreen
        case "room3": return .systemOrange
        default: return .systemTeal
        }
    }

    /// Said once wherever a transcript goes to a model.
    static let speakerKey = "\"Me\" is the user. \"Speaker 1/2/3…\" are other people in the room with the user " +
        "(told apart by voice — labels can be wrong). \"Them 1/2/3…\" are different people on the call, told apart " +
        "by voice the same way; plain \"Them\" is the call with voices not told apart. A real name means the user " +
        "named that speaker."

    /// Plain transcript, one turn per paragraph — what Copy and the enhancer see.
    static func plain(_ m: Meeting) -> String {
        turns(m.segments).map { "[\(clock($0.start))] \(label($0.speaker, names: m.speakerNames)): \($0.text)" }
            .joined(separator: "\n\n")
    }

    /// Whole meeting as Markdown (sidebar ▸ Copy as Markdown).
    static func markdown(_ m: Meeting) -> String {
        var parts = ["# \(m.displayTitle)",
                     DateFormatter.localizedString(from: m.created, dateStyle: .long, timeStyle: .short)]
        // Pictures point at their files on this Mac, so the Markdown still renders.
        func pics(_ s: String) -> String {
            MeetingImages.rewrite(s) { "![](\(MeetingImages.url(m.id, $0).absoluteString))" }
        }
        if !m.enhanced.isEmpty { parts.append(pics(m.enhanced)) }
        if !m.notes.isEmpty { parts.append("## My notes\n\n" + pics(m.notes)) }
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
    /// With `wordTimes`, finals come here instead, with each word's time.
    var onFinalWords: ((MeetingSegment, [MeetingWord]) -> Void)?
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
    /// `wordTimes`: ask for each word's audio time (the mic, for room speakers).
    init(speaker: String, locale: Locale, offset: Double, wallClock: Bool = true, wordTimes: Bool = false) {
        self.speaker = speaker
        self.offset = offset
        self.wallClock = wallClock
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                        reportingOptions: [.volatileResults],
                                        attributeOptions: wordTimes ? [.audioTimeRange] : [])
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
                        let end = result.range.end.seconds
                        let seg = MeetingSegment(speaker: speaker,
                                                 start: offset + (start.isFinite ? start : 0),
                                                 text: text,
                                                 end: end.isFinite ? offset + end : nil)
                        if let words = self?.onFinalWords {
                            // Runs carrying a time are words; untimed runs (spaces,
                            // punctuation) stick to the word before them.
                            var list: [MeetingWord] = []
                            for run in result.text.runs {
                                let piece = String(result.text[run.range].characters)
                                if let r = run.audioTimeRange, r.start.seconds.isFinite, r.end.seconds.isFinite {
                                    list.append(MeetingWord(text: piece, start: offset + r.start.seconds, end: offset + r.end.seconds))
                                } else if !list.isEmpty {
                                    list[list.count - 1].text += piece
                                }
                            }
                            words(seg, list)
                        } else {
                            self?.onFinal?(seg)
                        }
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
    /// Room speakers (see RoomDiarizer): set once its model is loaded, read on
    /// the mic thread — hence the lock.
    private let roomLock = NSLock()
    private var _room: RoomDiarizer?
    private var room: RoomDiarizer? { roomLock.withLock { _room } }
    private var micSeconds: Double = 0
    /// The same for the call audio: Them 1, 2, 3 (also under roomLock).
    private var _call: RoomDiarizer?
    private var call: RoomDiarizer? { roomLock.withLock { _call } }
    private var callSeconds: Double = 0
    private var recordingOffset: Double = 0
    /// Mic phrases waiting for their speaker label; stop() waits for them.
    private let labeling = DispatchGroup()
    /// Held for the whole recording: keeps macOS from App-Napping Power Tools
    /// while it sits behind the call window (which throttles the clock and the
    /// once-a-minute Live refresh) and from idle-sleeping mid-meeting.
    private var activity: NSObjectProtocol?

    /// Returns a warning to show when only part of the meeting can be heard.
    func start(locale: Locale, offset: Double) async throws -> String? {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
            reason: "Recording a meeting")
        try await AppleSpeechUtterance.ensureAssets(locale: locale)

        let micAllowed = await AudioCapture.requestMicPermission()
        let screenAllowed = CGPreflightScreenCaptureAccess()
        guard micAllowed || screenAllowed else {
            throw NSError(domain: "GRCWhisper", code: 21, userInfo: [NSLocalizedDescriptionKey:
                "Power Tools needs Microphone and/or Screen Recording permission to hear the meeting."])
        }
        var warnings: [String] = []

        recordingOffset = offset
        if micAllowed {
            let t = makeTranscriber("me", locale: locale, offset: offset, wordTimes: RoomDiarizer.enabled)
            try await t.start()
            let m = MeetingMic()
            m.onBuffer = { [weak t, weak self] buf in
                t?.feed(buf)
                guard let self else { return }
                self.roomLock.withLock { self.micSeconds += Double(buf.frameLength) / buf.format.sampleRate }
                self.room?.feed(buf)
            }
            do { try m.start(); mic = m } catch { warnings.append("Mic unavailable (\(error.localizedDescription))") }
            if mic != nil, RoomDiarizer.enabled { startDiarizer("room") }
        } else {
            warnings.append("Microphone permission is off — only the other side is transcribed")
        }

        if screenAllowed {
            let t = makeTranscriber("them", locale: locale, offset: offset, wordTimes: RoomDiarizer.enabled)
            try await t.start()
            let s = SystemAudioCapture()
            s.onBuffer = { [weak t, weak self] buf in
                t?.feed(buf)
                guard let self else { return }
                self.roomLock.withLock { self.callSeconds += Double(buf.frameLength) / buf.format.sampleRate }
                self.call?.feed(buf)
            }
            s.onStop = { [weak self] _ in self?.onWarning?("System audio capture stopped — only your mic is being transcribed now") }
            do { try await s.start(); system = s } catch {
                warnings.append("System audio unavailable (\(error.localizedDescription))")
            }
            if system != nil, RoomDiarizer.enabled { startDiarizer("them") }
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

    /// Loads a diarizer model (a one-time download the first time) without
    /// holding up the recording; phrases before it's ready stay "Me" / "Them".
    /// "room" = voices at the mic, "them" = voices on the call.
    private func startDiarizer(_ prefix: String) {
        let isCall = prefix == "them"
        Task.detached { [weak self] in
            do {
                let models = try await RoomDiarizer.models(for: prefix)
                guard let self, isCall ? self.system != nil : self.mic != nil else { return }
                let start = self.roomLock.withLock { isCall ? self.callSeconds : self.micSeconds }
                let r = RoomDiarizer(models: models, enrollment: isCall ? nil : VoiceSample.load(),
                                     clockStart: start, prefix: prefix)
                self.roomLock.withLock { if isCall { self._call = r } else { self._room = r } }
            } catch {
                log("meetings: \(isCall ? "call" : "room") speakers unavailable: \(error)")
            }
        }
    }

    /// A finished phrase waits for its diarizer to catch up, then takes the
    /// speaker label of whoever spoke most during it (split per word).
    private func labelPhrase(_ seg: MeetingSegment, words: [MeetingWord]) {
        guard let room = MeetingText.isCall(seg.speaker) ? call : room else { onFinal?(seg); return }
        labeling.enter()
        let offset = recordingOffset
        DispatchQueue.global().asyncAfter(deadline: .now() + RoomDiarizer.labelDelay) { [weak self] in
            room.afterPending {
                for s in room.split(seg, words: words, offset: offset) { self?.onFinal?(s) }
                self?.labeling.leave()
            }
        }
    }

    /// "This is me" while recording: the diarizer relabels from now on, and
    /// the user's recent speech becomes the voice sample for next meetings.
    /// Returns the seconds of voice saved (0 = none).
    func claimMe(label: String) -> Double {
        guard let samples = room?.claimMe(label: label) else { return 0 }
        let seconds = Double(samples.count) / VoiceSample.rate
        guard seconds >= 3 else { return 0 }
        VoiceSample.save(samples)
        return seconds
    }

    private func makeTranscriber(_ speaker: String, locale: Locale, offset: Double, wordTimes: Bool = false) -> LiveTranscriber {
        let t = LiveTranscriber(speaker: speaker, locale: locale, offset: offset, wordTimes: wordTimes)
        t.onFinal = { [weak self] in self?.onFinal?($0) }
        if wordTimes { t.onFinalWords = { [weak self] seg, words in self?.labelPhrase(seg, words: words) } }
        t.onVolatile = { [weak self] in self?.onVolatile?(speaker, $0) }
        transcribers.append(t)
        return t
    }

    func stop() async {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        mic?.stop()
        mic = nil
        await system?.stop()
        system = nil
        let ts = transcribers
        transcribers = []
        await withTaskGroup(of: Void.self) { group in
            for t in ts { group.addTask { await t.finish() } }
        }
        // The last mic phrases are still waiting for their speaker label.
        let group = labeling
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = group.wait(timeout: .now() + RoomDiarizer.labelDelay + 4)
                cont.resume()
            }
        }
        room?.finish()
        call?.finish()
        roomLock.withLock { _room = nil; micSeconds = 0; _call = nil; callSeconds = 0 }
    }
}

// MARK: - Enhancer

enum MeetingEnhancer {
    static let instructions = """
    You turn a meeting transcript plus the user's own rough notes into clean meeting notes.

    Speakers: "Me" is the user. "Speaker 1", "Speaker 2"… are other people in the room \
    with the user, told apart by voice (labels can be wrong). "Them 1", "Them 2"… are \
    different people on the call, told apart by voice the same way; plain "Them" is the \
    call with its voices not told apart — infer distinct people from context when names \
    are used, otherwise say "they". A real name in place of a label is a speaker the \
    user named — use it. Transcription errors are common; read charitably \
    (e.g. "cruise" next to "crews" is probably "crews").

    Output EXACTLY this Markdown structure, in this order:

    # <specific title naming what the meeting was about — never "Meeting Notes">

    <BODY: if the user wrote notes, keep every point they wrote, in their order and \
    wording, as "-" bullets (keep their headings as "##"), each expanded with the \
    relevant specifics from the transcript — numbers, names, dates, reasons. If they \
    wrote nothing, group the discussion under 2-5 "##" topic headings of your own.>

    ## Summary
    <2-3 sentences>

    ## Agenda
    - ✓ <agenda item> — <one line on what was said>   ("◐" when only partly covered, "- ○ <agenda item> — not discussed" when untouched)
    <include this Agenda section ONLY when an AGENDA is given: one line per agenda item, in its order>

    ## Decisions
    - <only things actually agreed; omit this section if none>

    ## Action items
    - [ ] <Owner> — <task> — <due date; leave this part off entirely when none was stated>

    ## Open questions
    - <unresolved items; omit this section if none>

    Rules: concise, "-" bullets, no preamble or closing remarks, and never invent \
    facts that aren't in the notes or transcript.
    """

    static func prompt(_ m: Meeting, transcript: String) -> String {
        let notes = MeetingImages.rewrite(m.notes) { _ in "[picture]" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        <MY_NOTES>
        \(notes.isEmpty ? "(none)" : notes)
        </MY_NOTES>
        <AGENDA>
        \(m.agenda?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? m.agenda! : "(none)")
        </AGENDA>
        <LIVE_LIST note="running list made during the call; the transcript wins where they differ">
        \(m.live?.isEmpty == false ? m.live! : "(none)")
        </LIVE_LIST>
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
                numbers, names, decisions, and action items. Keep the "Me" / "Speaker N" / "Them" attribution. No preamble.
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
                                    NSTableViewDelegate, NSTextViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
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
    private var tab = 0  // 0 My Notes · 1 Enhanced · 2 Transcript · 3 Live · 4 Agenda
    /// Segment order on screen → internal tab id (Agenda sits first).
    private static let segmentTabs = [4, 0, 1, 2, 3]
    private func showTab(_ t: Int) {
        tab = t
        tabs.selectedSegment = Self.segmentTabs.firstIndex(of: t) ?? 1
    }
    // Live assist (MeetingLive.swift).
    private var livePanel: MeetingLivePanel?
    private var liveBusy: Set<String> = []
    private var liveAt: [String: Date] = [:]
    private var liveSegCount: [String: Int] = [:]
    private var liveError: [String: String] = [:]
    private var liveRefreshes: [String: Int] = [:]
    private var answers: [String: [MeetingLive.Answer]] = [:]
    // Coach (MeetingCoach.swift): cues live in memory only, never in the file.
    private var coachCues: [String: [MeetingCoach.Cue]] = [:]
    private var coachSegCount: [String: Int] = [:]
    private var coachAt = Date.distantPast
    private var coachBusy = false
    private var coachOverrideUsed = false
    private let coachPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let askField = NSTextField()
    private let livePanelButton = NSButton(title: "Floating Panel", target: nil, action: nil)
    private var textBottomToStatus: NSLayoutConstraint!
    private var textBottomToAsk: NSLayoutConstraint!
    /// Show the floating panel when a recording starts. Closing it with ✕
    /// turns this off (closing is final); "Floating Panel" turns it back on.
    private static let livePanelPref = "meetings.live.panel"
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
    private let exportButton = NSButton(title: "", target: nil, action: nil)
    private var exportSheet: MeetingExportSheet?
    private let titleField = NSTextField()
    private let timeLabel = NSTextField(labelWithString: "")
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private let tabs = NSSegmentedControl(labels: ["Agenda", "Notes", "Enhanced", "Transcript", "Live"],
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let enhanceButton = NSButton(title: "Enhance", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let textScroll: NSScrollView = {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let tv = NotesTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv
        return scroll
    }()
    private var textView: NotesTextView { textScroll.documentView as! NotesTextView }
    private let oneNoteButton = NSPopUpButton(frame: .zero, pullsDown: true)
    /// Meetings to send to OneNote once their auto-enhance finishes.
    private var sendWhenEnhanced: Set<String> = []
    private var sendingToOneNote: Set<String> = []
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
        showTab(2)
        render()
    }

    /// Puts a generated picture into the sample meeting's notes (`meeting-preview … pics`).
    /// Returns the meeting id so the caller can delete its picture folder afterwards.
    func previewPicture() -> String? {
        guard let i = index(selectedID) else { return nil }
        let img = NSImage(size: NSSize(width: 900, height: 420), flipped: false) { r in
            NSColor(srgbRed: 0.93, green: 0.95, blue: 0.98, alpha: 1).setFill(); r.fill()
            NSColor.systemBlue.setFill()
            for (k, h) in [0.35, 0.6, 0.45, 0.8, 0.7].enumerated() {
                NSRect(x: 80 + CGFloat(k) * 150, y: 40, width: 90, height: 320 * h).fill()
            }
            ("Whiteboard — crew plan" as NSString).draw(at: NSPoint(x: 30, y: 380), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 22)])
            return true
        }
        guard let name = MeetingImages.save(img, meetingID: meetings[i].id) else { return nil }
        meetings[i].notes = "- pilot crews: 3 → 5?\n- whiteboard from the room:\n![](\(name))\n- Rhett to send updated map"
        showTab(0)
        render()
        return meetings[i].id
    }

    /// Live tab + floating panel with a sample list (`meeting-preview … live`).
    func previewLive() -> NSBitmapImageRep? {
        guard let i = index(selectedID) else { return nil }
        meetings[i].agenda = "1. Pilot crew count\n2. Meter backlog\n3. Truck delivery\n4. Safety stand-down"
        meetings[i].live = "## Agenda\n- ✓ Pilot crew count — 3 today, target 5\n- ◐ Meter backlog — ~1,100; timing unclear\n- ✓ Truck delivery — needed by Nov 15\n- ○ Safety stand-down\n\n## Action items\n- Them (Rhett) — send updated map — Friday\n- Me — confirm truck delivery date — before Nov 15\n\n## Questions to ask\n- Who owns crew 4 and 5 hiring if trucks slip?\n- Is the 1,100-meter backlog before or after this week's installs?\n\n## Decisions\n- Target 5 crews before Thanksgiving, contingent on trucks"
        answers[meetings[i].id] = [MeetingLive.Answer(question: "What date did they give for the trucks?",
                                                      answer: "You said the trucks need to arrive by the 15th for five crews to work; nobody confirmed the date.")]
        liveAt[meetings[i].id] = Date()
        showTab(3)
        render()
        showLivePanel()
        updatePanel()
        return livePanel?.snapshot()
    }

    /// The selected (sample) meeting, for CLI checks.
    var previewMeeting: Meeting? { selected }

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
        showTab(t)
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
        showTab(0)
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
        startTicker(id)
        if UserDefaults.standard.object(forKey: Self.livePanelPref) as? Bool ?? true { showLivePanel() }
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
                else { self.setStatus("Listening — you are “Me”, others in the room are “Speaker 2, 3…”, the call is “Them”. Type notes as you go.") }
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
                let sendAfter = OneNote.autoSend && OneNote.isSignedIn && hasText
                if autoEnhance, hasText {
                    if sendAfter { self.sendWhenEnhanced.insert(id) }
                    self.enhance(id)
                } else {
                    self.setStatus(hasText ? "Saved." : "Saved — no speech was transcribed.")
                    if sendAfter { self.sendToOneNote(id) }
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
            defer {
                self.enhancing.remove(id)
                self.updateChrome()
                // "Send automatically when a meeting ends" — even if Enhance
                // failed, the notes and transcript still go.
                if self.sendWhenEnhanced.remove(id) != nil { self.sendToOneNote(id) }
            }
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
                    self.showTab(1)
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
        tab = Self.segmentTabs[max(0, tabs.selectedSegment)]
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
        case 2: text = MeetingText.plain(m)
        case 4: text = m.agenda ?? ""
        default:
            let qa = (answers[m.id] ?? []).map { "Q: \($0.question)\nA: \($0.answer ?? "…")" }
            text = ([m.live ?? ""] + (qa.isEmpty ? [] : ["## Answers\n\n" + qa.joined(separator: "\n\n")]))
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        if tab < 2 {  // notes / enhanced may hold pictures
            // Pictures come along when pasting into Mail, Notes, Word, OneNote…
            MeetingImages.writeRich(text, meetingID: m.id, to: NSPasteboard.general)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
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

    // MARK: Export

    @objc private func exportClicked() { openExport(preselect: selectedID) }
    @objc private func exportTarget() { openExport(preselect: targetMeeting()?.id) }

    /// The Export sheet over this window; the given meeting starts ticked.
    private func openExport(preselect id: String?) {
        guard let window, exportSheet == nil else { return }
        guard !meetings.isEmpty else { setStatus("No meetings to export yet."); return }
        let sheet = MeetingExportSheet(meetings: meetings, preselect: id.map { [$0] } ?? [])
        sheet.window.appearance = window.appearance
        sheet.onDone = { [weak self] msg in
            self?.exportSheet = nil
            if let msg { self?.setStatus(msg) }
        }
        exportSheet = sheet
        window.beginSheet(sheet.window)
    }

    /// Preview/test: the export sheet built over the sample data, unattached.
    func previewExport(selectDayRow: Int?) -> MeetingExportSheet {
        let sheet = MeetingExportSheet(meetings: meetings, preselect: selectedID.map { [$0] } ?? [])
        sheet.window.appearance = window?.appearance
        if let r = selectDayRow { sheet.testToggleDay(r) }
        return sheet
    }

    @objc private func deleteMeeting() {
        guard let m = targetMeeting(), let window else { return }
        guard m.id != recordingID else { setStatus("Stop the recording before deleting this meeting.", warn: true); return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(m.displayTitle)”?"
        alert.informativeText = "Its notes, pictures, and transcript are removed from this Mac (a copy already sent to OneNote stays there). This can't be undone."
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

    // MARK: Live

    private func layoutLiveControls() {
        let live = tab == 3 && selected != nil
        askField.isHidden = !live
        livePanelButton.isHidden = !live
        coachPopup.isHidden = !live
        textBottomToStatus.isActive = !live
        textBottomToAsk.isActive = live
    }

    private func renderLive() {
        guard tab == 3, let m = selected else { return }
        suppressTextEvents = true
        textView.isEditable = false
        textView.textStorage?.setAttributedString(MeetingLive.attributed(live: m.live, answers: answers[m.id] ?? [], agenda: m.agenda,
                                                                           cue: coachCues[m.id]?.last))
        suppressTextEvents = false
        if recordingID == m.id {
            hint.stringValue = liveBusy.contains(m.id) ? "Reading the conversation so far…"
                : "Listening — action items, questions to ask, and decisions appear here about a minute in, then refresh every minute."
        } else if m.segments.isEmpty {
            hint.stringValue = "While a meeting records, action items, questions to ask, and decisions appear here about once a minute. You can ask questions about the meeting below any time."
        } else {
            hint.stringValue = "No live list for this meeting — ask a question about it below."
        }
        hint.isHidden = textView.string.count > 0
    }

    private func liveStatus(_ id: String) -> String {
        if liveBusy.contains(id) { return "Updating…" }
        if let e = liveError[id] { return "Live update failed: \(e)" }
        if let m = meetings.first(where: { $0.id == id }), m.live != nil, let t = liveAt[id] {
            return "Updated " + DateFormatter.localizedString(from: t, dateStyle: .none, timeStyle: .short)
                + (recordingID == id ? " · next in ~1 min" : "")
        }
        return recordingID == id ? "Listening… first list about a minute in." : ""
    }

    private func updateLiveViews(_ id: String) {
        if selectedID == id, tab == 3 { renderLive() }
        updatePanel()
    }

    /// The panel follows the recording meeting, else the selected one.
    private func updatePanel() {
        guard let p = livePanel, p.isVisible, let id = recordingID ?? selectedID,
              let m = meetings.first(where: { $0.id == id }) else { return }
        p.update(title: m.displayTitle, content: MeetingLive.attributed(live: m.live, answers: answers[id] ?? [], agenda: m.agenda,
                                                                        cue: coachCues[id]?.last),
                 status: liveStatus(id) + (MeetingCoach.enabled ? " · Coach on" : ""))
    }

    private func showLivePanel() {
        if livePanel == nil {
            let p = MeetingLivePanel(dark: config.appearance.isDark)
            p.onAsk = { [weak self] q in
                guard let self, let id = self.recordingID ?? self.selectedID else { return }
                self.ask(q, id: id)
            }
            p.onRefresh = { [weak self] in
                guard let self, let id = self.recordingID ?? self.selectedID else { return }
                self.refreshLive(id, auto: false)
            }
            p.onUserClose = { UserDefaults.standard.set(false, forKey: Self.livePanelPref) }
            p.onCoachToggle = { [weak self] in self?.setCoach(!MeetingCoach.enabled) }
            livePanel = p
        }
        livePanel?.show()
        updatePanel()
    }

    private func buildCoachMenu() {
        coachPopup.removeAllItems()
        coachPopup.addItem(withTitle: MeetingCoach.enabled ? "Coach: On" : "Coach: Off")
        coachPopup.addItem(withTitle: MeetingCoach.enabled ? "Turn coach off" : "Turn coach on")
        coachPopup.addItem(withTitle: "Edit coach prompt…")
        for item in coachPopup.itemArray.dropFirst() { item.target = self; item.action = #selector(coachMenuPicked(_:)) }
        coachPopup.toolTip = "Private cues while a meeting records: one next move and one sentence you could say. Shown only here."
    }

    @objc private func coachMenuPicked(_ sender: NSMenuItem) {
        if sender.title.hasPrefix("Edit") { MeetingCoach.editPrompt() } else { setCoach(!MeetingCoach.enabled) }
    }

    private func setCoach(_ on: Bool) {
        MeetingCoach.enabled = on
        log("meetings: coach \(on ? "on" : "off")")
        buildCoachMenu()
        livePanel?.setCoach(on)
        if let id = recordingID ?? selectedID { updateLiveViews(id) }
    }

    /// Every second while recording: at most every 20 s, only on new talk, never
    /// inside the 75 s cooldown — except once if someone asked to stop.
    private func coachTick() {
        guard MeetingCoach.enabled, let id = recordingID, !coachBusy,
              let m = meetings.first(where: { $0.id == id }), !m.segments.isEmpty else { return }
        let now = Date()
        let seen = coachSegCount[id] ?? 0
        guard now.timeIntervalSince(coachAt) >= MeetingCoach.checkEvery, m.segments.count > seen else { return }
        let recent = coachCues[id] ?? []
        if let last = recent.last, now.timeIntervalSince(last.at) < MeetingCoach.cooldown {
            let newTalk = m.segments.suffix(m.segments.count - seen).map(\.text).joined(separator: " ")
            guard !coachOverrideUsed, MeetingCoach.askedToStop(newTalk) else { return }
            coachOverrideUsed = true
        }
        coachBusy = true
        coachAt = now
        coachSegCount[id] = m.segments.count
        let meetingNow = baseSeconds + (recordStart.map { now.timeIntervalSince($0) } ?? 0)
        let cfg = config
        Task { @MainActor in
            defer { self.coachBusy = false }
            do {
                if let cue = try await MeetingCoach.evaluate(m, meetingNow: meetingNow, recent: recent, config: cfg) {
                    self.coachCues[id, default: []].append(cue)
                    self.coachOverrideUsed = false
                    log("meetings: coach cue (\(cue.signal))")
                    self.updateLiveViews(id)
                }
            } catch {
                log("meetings: coach failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func livePanelClicked() {
        UserDefaults.standard.set(true, forKey: Self.livePanelPref)
        showLivePanel()
    }

    @objc private func askSubmitted() {
        let q = askField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let id = selectedID else { return }
        askField.stringValue = ""
        ask(q, id: id)
    }

    /// The 1 s recording clock, which also drives the automatic live refresh.
    private func startTicker(_ id: String) {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock(); self?.liveTick(); self?.coachTick() }
        }
        // .common, not the default mode: menus, sheets, and dragging the
        // window or a scroller run the loop in other modes and would stall it.
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        liveAt[id] = Date()  // first live list about a minute in
    }

    /// CLI check (`live-auto-test`): drives the REAL timer + liveTick path with
    /// scripted transcript lines instead of audio. Returns the meeting id.
    func testAutoLive(_ lines: [(TimeInterval, MeetingSegment)]) -> String {
        var m = Meeting.blank()
        m.title = "live-auto-test"
        meetings.insert(m, at: 0)
        selectedID = m.id
        recordingID = m.id
        recordStart = Date()
        baseSeconds = 0
        startTicker(m.id)
        for (at, seg) in lines {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in self?.append(seg, to: m.id) }
        }
        return m.id
    }

    func testLiveState(_ id: String) -> (live: String?, refreshes: Int, busy: Bool) {
        (meetings.first { $0.id == id }?.live, liveRefreshes[id] ?? 0, liveBusy.contains(id))
    }

    func testStop(_ id: String) {
        ticker?.invalidate(); ticker = nil
        recordingID = nil
        meetings.removeAll { $0.id == id }
        dirty.remove(id)
        saveWork?.cancel()
        MeetingStore.delete(id)
    }

    /// Every second while recording: refresh once a minute, and only when
    /// something new was said.
    private func liveTick() {
        guard let id = recordingID, !liveBusy.contains(id),
              let m = meetings.first(where: { $0.id == id }) else { return }
        guard Date().timeIntervalSince(liveAt[id] ?? .distantPast) >= MeetingLive.interval,
              m.segments.count > (liveSegCount[id] ?? 0) else { return }
        refreshLive(id)
    }

    private func refreshLive(_ id: String, auto: Bool = true) {
        guard !liveBusy.contains(id), let m = meetings.first(where: { $0.id == id }), !m.segments.isEmpty else { return }
        liveRefreshes[id, default: 0] += 1
        log("meetings: live refresh #\(liveRefreshes[id]!) (\(auto ? "auto" : "manual")) on \(m.segments.count) segments")
        let started = Date()
        liveBusy.insert(id)
        liveSegCount[id] = m.segments.count
        liveAt[id] = Date()
        updateLiveViews(id)
        let cfg = config
        Task { @MainActor in
            defer { self.liveBusy.remove(id); self.updateLiveViews(id) }
            do {
                let text = try await MeetingLive.refresh(m, config: cfg)
                guard let i = self.index(id) else { return }
                self.meetings[i].live = text
                self.liveError[id] = nil
                self.markDirty(id)
                log("meetings: live updated in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            } catch {
                log("meetings: live refresh failed: \(error)")
                self.liveError[id] = error.localizedDescription
            }
        }
    }

    private func ask(_ question: String, id: String) {
        flushSaves()
        guard let m = meetings.first(where: { $0.id == id }) else { return }
        answers[id, default: []].append(MeetingLive.Answer(question: question, answer: nil))
        let slot = answers[id]!.count - 1
        updateLiveViews(id)
        let cfg = config
        Task { @MainActor in
            let a: String
            do { a = try await MeetingLive.ask(question, m, config: cfg) } catch {
                a = "Couldn't answer: \(error.localizedDescription)"
            }
            if self.answers[id]?.indices.contains(slot) == true { self.answers[id]![slot].answer = a }
            self.updateLiveViews(id)
        }
    }

    // MARK: OneNote

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === oneNoteButton.menu else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }  // item 0 is the button's title
        func add(_ title: String, _ action: Selector?, enabled: Bool = true, on: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled && action != nil
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        let m = selected
        let busy = m.map { sendingToOneNote.contains($0.id) } ?? false
        if OneNote.isSignedIn {
            add(m?.oneNotePageID == nil ? "Send to OneNote" : "Send Again (replaces the page)",
                #selector(sendSelectedToOneNote), enabled: m != nil && !busy)
            add("Open in OneNote", #selector(openInOneNote), enabled: m?.oneNoteURL != nil)
            menu.addItem(.separator())
            add("Send automatically when a meeting ends", #selector(toggleAutoSend), on: OneNote.autoSend)
            add(OneNote.sectionName.map { "Section: \($0)…" } ?? "Choose Section…", #selector(chooseSectionClicked))
            menu.addItem(.separator())
            add("Signed in as \(OneNote.account ?? "Microsoft account")", nil)
            add("Sign Out", #selector(oneNoteSignOut))
        } else {
            add("Sign In to OneNote…", #selector(oneNoteSignIn))
            add("Works with a personal or work Microsoft account.", nil)
        }
    }

    @objc private func sendSelectedToOneNote() { if let id = selectedID { sendToOneNote(id) } }
    @objc private func sendTargetToOneNote() { if let m = targetMeeting() { sendToOneNote(m.id) } }

    @objc private func openInOneNote() {
        guard let s = selected?.oneNoteURL, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleAutoSend() {
        OneNote.autoSend.toggle()
        setStatus(OneNote.autoSend ? "Meetings will be sent to OneNote when you stop recording (after Enhance)."
                                   : "Automatic OneNote sending is off.")
        if OneNote.autoSend, OneNote.sectionID == nil { chooseSection(thenSend: nil) }
    }

    @objc private func chooseSectionClicked() { chooseSection(thenSend: nil) }

    @objc private func oneNoteSignOut() {
        OneNote.signOut()
        setStatus("Signed out of OneNote.")
    }

    @objc private func oneNoteSignIn() { signInToOneNote(thenSend: nil) }

    private func signInToOneNote(thenSend id: String?) {
        setStatus("Opening Microsoft sign-in…")
        Task { @MainActor in
            do {
                try await OneNote.signIn(from: self.window)
                self.setStatus("Signed in to OneNote as \(OneNote.account ?? "your Microsoft account").")
                self.chooseSection(thenSend: id)
            } catch {
                self.setStatus("OneNote sign-in: \(error.localizedDescription)", warn: true)
            }
        }
    }

    /// Lists the account's sections in a sheet; the pick is remembered.
    private func chooseSection(thenSend id: String?) {
        guard OneNote.isSignedIn else { signInToOneNote(thenSend: id); return }
        setStatus("Loading your OneNote sections…")
        Task { @MainActor in
            let sections: [OneNote.Section]
            do { sections = try await OneNote.sections() } catch {
                self.setStatus(error.localizedDescription, warn: true)
                return
            }
            guard let window = self.window else { return }
            guard !sections.isEmpty else {
                self.setStatus("No OneNote sections found — create a notebook in OneNote first.", warn: true)
                return
            }
            self.setStatus("")
            let alert = NSAlert()
            alert.messageText = "Send meetings to which OneNote section?"
            alert.informativeText = "Each meeting becomes one page: enhanced notes, your notes and pictures, then the transcript."
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
            for s in sections {
                popup.addItem(withTitle: s.name)
                popup.lastItem?.representedObject = s.id
                if s.id == OneNote.sectionID { popup.select(popup.lastItem) }
            }
            alert.accessoryView = popup
            alert.addButton(withTitle: id == nil ? "Use This Section" : "Send")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn,
                      let item = popup.selectedItem, let sid = item.representedObject as? String else { return }
                OneNote.setSection(id: sid, name: item.title)
                self.setStatus("OneNote section: \(item.title).")
                if let id { self.sendToOneNote(id) }
            }
        }
    }

    private func sendToOneNote(_ id: String) {
        guard !sendingToOneNote.contains(id) else { return }
        guard OneNote.isSignedIn else { signInToOneNote(thenSend: id); return }
        guard OneNote.sectionID != nil else { chooseSection(thenSend: id); return }
        flushSaves()
        guard let m = meetings.first(where: { $0.id == id }) else { return }
        sendingToOneNote.insert(id)
        setStatus("Sending “\(m.displayTitle)” to OneNote…")
        Task { @MainActor in
            defer { self.sendingToOneNote.remove(id) }
            do {
                let page = try await OneNote.send(m)
                guard let i = self.index(id) else { return }
                self.meetings[i].oneNotePageID = page.id
                self.meetings[i].oneNoteURL = page.url
                MeetingStore.save(self.meetings[i])
                self.setStatus("Sent “\(m.displayTitle)” to OneNote ▸ \(OneNote.sectionName ?? "your section").")
            } catch {
                log("meetings: OneNote send failed: \(error)")
                self.setStatus(error.localizedDescription, warn: true)
            }
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
        defer { layoutLiveControls(); updatePanel() }
        let has = selected != nil
        for v in [titleField, meetingContextPopup, tabs, textScroll, enhanceButton, copyButton, oneNoteButton] as [NSView] { v.isHidden = !has }
        rebuildMeetingContextPopup()
        emptyState.isHidden = has
        updateChrome()
        guard let m = selected else { hint.isHidden = true; return }
        if titleField.currentEditor() == nil { titleField.stringValue = m.title }
        suppressTextEvents = true
        defer { suppressTextEvents = false }
        switch tab {
        case 0:
            setNotes(m.notes, meetingID: m.id)
            hint.stringValue = "Type rough notes while the meeting runs — a few words per point is plenty. Paste or drop pictures right in. Enhance keeps your notes as the outline and fills in the details from the transcript."
            hint.isHidden = !m.notes.isEmpty
        case 1:
            setNotes(m.enhanced, meetingID: m.id)
            hint.stringValue = m.segments.isEmpty && m.notes.isEmpty
                ? "Record the meeting (or type notes), then Enhance to get a summary, decisions, and action items."
                : "Nothing here yet — click Enhance."
            hint.isHidden = !m.enhanced.isEmpty
        case 2:
            renderTranscript()
        case 4:
            textView.isEditable = true
            textView.saveImage = nil
            textView.acceptsDocuments = true
            textView.textStorage?.setAttributedString(NSAttributedString(string: m.agenda ?? "", attributes: Self.plainAttributes))
            textView.typingAttributes = Self.plainAttributes
            hint.stringValue = "Paste the agenda — one topic per line — or paste the whole invite or email, or drop in a document (Word, PDF, text). While the meeting records, Live checks off each topic as it's covered so nothing gets missed."
            hint.isHidden = !(m.agenda ?? "").isEmpty
        default:
            renderLive()
        }
    }

    private static let plainAttributes: [NSAttributedString.Key: Any] = {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        return [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor, .paragraphStyle: para]
    }()

    /// Replaces the text AND its attributes — the transcript tab's styling must
    /// not leak into the editable tabs (or into what the user types next).
    private func setNotes(_ s: String, meetingID: String) {
        textView.isEditable = true
        textView.acceptsDocuments = false
        textView.saveImage = { img in
            MeetingImages.save(img, meetingID: meetingID).flatMap {
                MeetingImages.attachment(meetingID: meetingID, fileName: $0)
            }
        }
        textView.textStorage?.setAttributedString(
            MeetingImages.attributed(s, meetingID: meetingID, attributes: Self.plainAttributes))
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
             .foregroundColor: MeetingText.color(s)]
        }
        let text: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]
        for turn in MeetingText.turns(m.segments) {
            body.append(NSAttributedString(string: MeetingText.clock(turn.start) + "  ", attributes: stamp))
            var who = speaker(turn.speaker)
            // Every speaker but you is clickable: name them, or "This is me" (room).
            if turn.speaker != "me", let url = URL(string: "speaker://\(turn.speaker)") {
                who[.link] = url
                who[.toolTip] = turn.speaker.hasPrefix("room") ? "Click to name this speaker, or if this is you"
                                                               : "Click to name this speaker"
            }
            body.append(NSAttributedString(string: MeetingText.label(turn.speaker, names: m.speakerNames), attributes: who))
            body.append(NSAttributedString(string: "  ", attributes: speaker(turn.speaker)))
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

    // MARK: Speakers

    /// A click on a speaker's name in the transcript.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "speaker", let label = url.host,
              let id = selectedID, let i = index(id) else { return false }
        let named = meetings[i].speakerNames?[label] != nil
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = [id, label]
            menu.addItem(item)
        }
        add(named ? "Rename…" : "Name this speaker…", #selector(nameSpeakerClicked(_:)))
        if named { add("Remove name", #selector(clearNameClicked(_:))) }
        if label.hasPrefix("room") {
            menu.addItem(.separator())
            add("This is me", #selector(claimMeClicked(_:)))
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)   // screen coordinates
        return true
    }

    @objc private func nameSpeakerClicked(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let window, let i = index(pair[0]) else { return }
        let (id, label) = (pair[0], pair[1])
        let alert = NSAlert()
        alert.messageText = "Name \(MeetingText.label(label))"
        alert.informativeText = "Shown in this meeting's transcript, notes, and exports. New lines from this voice get the name too."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        field.stringValue = meetings[i].speakerNames?[label] ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.nameSpeaker(label, field.stringValue, meetingID: id)
        }
    }

    @objc private func clearNameClicked(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        nameSpeaker(pair[1], "", meetingID: pair[0])
    }

    /// Names (or, with "", un-names) one speaker label in one meeting.
    func nameSpeaker(_ label: String, _ name: String, meetingID id: String) {
        guard let i = index(id) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = meetings[i].speakerNames ?? [:]
        names[label] = n.isEmpty ? nil : n
        meetings[i].speakerNames = names.isEmpty ? nil : names
        markDirty(id)
        log("meetings: \(label) " + (n.isEmpty ? "name removed" : "named"))
        setStatus(n.isEmpty ? "Name removed." : "Named \(n).")
        renderTranscript()
        updateLiveViews(id)
    }

    @objc private func claimMeClicked(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        claimMe(pair[1], meetingID: pair[0])
    }

    /// That speaker becomes "Me" in this meeting (a previous "Me" takes its
    /// label); while recording, also from now on and in future meetings.
    func claimMe(_ label: String, meetingID id: String) {
        guard let i = index(id) else { return }
        for j in meetings[i].segments.indices {
            switch meetings[i].segments[j].speaker {
            case label: meetings[i].segments[j].speaker = "me"
            case "me": meetings[i].segments[j].speaker = label
            default: break
            }
        }
        // That label now belongs to whoever was "Me" before — its name doesn't.
        meetings[i].speakerNames?[label] = nil
        if meetings[i].speakerNames?.isEmpty == true { meetings[i].speakerNames = nil }
        markDirty(id)
        var saved = 0.0
        if recordingID == id { saved = recorder?.claimMe(label: label) ?? 0 }
        log("meetings: \(label) claimed as me" + (saved > 0 ? String(format: " — saved %.0f s of voice for next meetings", saved) : ""))
        setStatus(saved > 0 ? "Got it — you're “Me” from now on, and the next meeting will know your voice."
                            : "Got it — those lines are yours now.")
        renderTranscript()
        updateLiveViews(id)
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
        livePanel?.setDark(config.appearance.isDark)
    }

    // MARK: Delegates

    func textDidChange(_ notification: Notification) {
        guard !suppressTextEvents, let i = index(selectedID) else { return }
        switch tab {
        case 0: meetings[i].notes = MeetingImages.markdown(textView.attributedString()); hint.isHidden = !textView.string.isEmpty
        case 1: meetings[i].enhanced = MeetingImages.markdown(textView.attributedString()); hint.isHidden = !textView.string.isEmpty
        case 4:
            let a = textView.string
            meetings[i].agenda = a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : a
            hint.isHidden = !a.isEmpty
            updatePanel()
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
        menu.addItem(withTitle: "Export…", action: #selector(exportTarget), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Send to OneNote", action: #selector(sendTargetToOneNote), keyEquivalent: "").target = self
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
        exportButton.target = self
        exportButton.action = #selector(exportClicked)
        exportButton.bezelStyle = .rounded
        exportButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
        exportButton.imagePosition = .imageOnly
        exportButton.toolTip = "Export meetings — pick one, many, or a whole day to copy into a bot"

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
        tabs.selectedSegment = 1  // My Notes

        enhanceButton.target = self
        enhanceButton.action = #selector(enhanceClicked)
        enhanceButton.bezelStyle = .rounded
        enhanceButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        enhanceButton.imagePosition = .imageLeading
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.bezelStyle = .rounded
        // Icon-only so the five tabs and the three actions share one row.
        copyButton.title = ""
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyButton.imagePosition = .imageOnly
        copyButton.toolTip = "Copy this tab"
        askField.placeholderString = "Ask about this meeting — e.g. “what date did they give for the trucks?”"
        askField.bezelStyle = .roundedBezel
        askField.target = self
        askField.action = #selector(askSubmitted)
        livePanelButton.target = self
        livePanelButton.action = #selector(livePanelClicked)
        buildCoachMenu()
        livePanelButton.bezelStyle = .rounded
        livePanelButton.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
        livePanelButton.imagePosition = .imageLeading
        livePanelButton.toolTip = "Float the live list above your call window"
        oneNoteButton.bezelStyle = .rounded
        oneNoteButton.addItem(withTitle: "OneNote")
        oneNoteButton.menu?.delegate = self

        textScroll.drawsBackground = false
        textScroll.borderType = .noBorder
        textView.delegate = self
        // Rich so it can hold inline pictures; NotesTextView only ever reads
        // plain text or images off the pasteboard, so no styles sneak in.
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: 14)
        // Clickable speaker names keep their own color — no blue underline.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]

        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .tertiaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        emptyState.stringValue = "No meetings yet.\n\nClick Record when a call starts (or hold the Power Tools hotkey + O). You are “Me”, other people in the room are “Speaker 2, 3…” (told apart by voice) and whatever the Mac plays is “Them” — all on this Mac. Type rough notes alongside; Enhance turns them into clean notes with action items."
        emptyState.font = .systemFont(ofSize: 14)
        emptyState.textColor = .secondaryLabelColor
        emptyState.alignment = .center

        let views: [NSView] = [paper, sidebar, tableScroll, newButton, exportButton, contextPopup, datePopup, lengthPopup, groupPopup,
                               noMatch, clearFiltersButton, meetingContextPopup,
                               divider, titleField, timeLabel, recordButton,
                               tabs, enhanceButton, copyButton, oneNoteButton, textScroll, hint, statusLabel, emptyState,
                               askField, coachPopup, livePanelButton]
        for v in views { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let sideW: CGFloat = 250
        let pad: CGFloat = 20
        textBottomToStatus = textScroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8)
        textBottomToAsk = textScroll.bottomAnchor.constraint(equalTo: askField.topAnchor, constant: -8)
        textBottomToStatus.isActive = true
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: sideW),

            newButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            newButton.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            exportButton.centerYAnchor.constraint(equalTo: newButton.centerYAnchor),
            exportButton.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            exportButton.widthAnchor.constraint(equalToConstant: 34),
            newButton.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -6),

            contextPopup.topAnchor.constraint(equalTo: newButton.bottomAnchor, constant: 10),
            contextPopup.leadingAnchor.constraint(equalTo: newButton.leadingAnchor),
            contextPopup.trailingAnchor.constraint(equalTo: sidebar.centerXAnchor, constant: -3),
            datePopup.centerYAnchor.constraint(equalTo: contextPopup.centerYAnchor),
            datePopup.leadingAnchor.constraint(equalTo: sidebar.centerXAnchor, constant: 3),
            datePopup.trailingAnchor.constraint(equalTo: exportButton.trailingAnchor),
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
            oneNoteButton.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            oneNoteButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            copyButton.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: oneNoteButton.leadingAnchor, constant: -8),
            enhanceButton.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            enhanceButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            enhanceButton.leadingAnchor.constraint(greaterThanOrEqualTo: tabs.trailingAnchor, constant: 12),

            textScroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
            textScroll.leadingAnchor.constraint(equalTo: titleField.leadingAnchor, constant: -4),
            textScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad + 4),
            askField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            askField.trailingAnchor.constraint(equalTo: coachPopup.leadingAnchor, constant: -8),
            coachPopup.centerYAnchor.constraint(equalTo: askField.centerYAnchor),
            coachPopup.trailingAnchor.constraint(equalTo: livePanelButton.leadingAnchor, constant: -8),
            askField.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
            livePanelButton.centerYAnchor.constraint(equalTo: askField.centerYAnchor),
            livePanelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

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
/// `roomEnrollment` (16 kHz mono) also runs the room-speaker diarizer over the
/// "me" file — enrolled with it — and labels each mic phrase, like a live meeting.
func meetingTestRun(me: URL, them: URL?, locale: Locale, roomEnrollment: [Float]? = nil) async throws -> Meeting {
    try await AppleSpeechUtterance.ensureAssets(locale: locale)
    var m = Meeting.blank()
    let collected = SegmentBox()
    var mic: RoomDiarizer?, call: RoomDiarizer?
    if let roomEnrollment {
        mic = RoomDiarizer(models: try await RoomDiarizer.models(),
                           enrollment: roomEnrollment.isEmpty ? nil : roomEnrollment, clockStart: 0)
        if them != nil {
            call = RoomDiarizer(models: try await RoomDiarizer.models(for: "them"),
                                enrollment: nil, clockStart: 0, prefix: "them")
        }
    }
    for (speaker, url) in [("me", me), ("them", them)] {
        guard let url else { continue }
        let room = speaker == "me" ? mic : call
        let t = LiveTranscriber(speaker: speaker, locale: locale, offset: 0, wallClock: false,
                                wordTimes: room != nil)
        t.onFinal = { collected.add($0) }
        let pending = WordBox()
        if room != nil { t.onFinalWords = { pending.add($0, $1) } }
        try await t.start()
        let file = try AVAudioFile(forReading: url)
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
            try file.read(into: buf, frameCount: 4096)
            if buf.frameLength == 0 { break }
            if let mono = buf.monoFloat(loudest: speaker == "me") {
                t.feed(mono)
                room?.feed(mono)
            }
        }
        await t.finish()
        if let room {
            room.finish()   // every buffer through the diarizer before labeling
            if ProcessInfo.processInfo.environment["PT_WORD_DEBUG"] != nil {
                for (_, words) in pending.all() { for w in words {
                    print(String(format: "  word %6.2f–%6.2f %@ → %@", w.start, w.end, w.text.debugDescription, room.label(from: max(w.start, w.end - 0.3), to: w.end, minSpan: 0.2) ?? "nil"))
                } }
            }
            for (seg, words) in pending.all() { for s in room.split(seg, words: words, offset: 0) { collected.add(s) } }
        }
        m.recordedSeconds = max(m.recordedSeconds, Double(file.length) / file.processingFormat.sampleRate)
    }
    m.segments = collected.all()
    return m
}

final class WordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(MeetingSegment, [MeetingWord])] = []
    func add(_ s: MeetingSegment, _ w: [MeetingWord]) { lock.withLock { items.append((s, w)) } }
    func all() -> [(MeetingSegment, [MeetingWord])] { lock.withLock { items } }
}

private final class SegmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MeetingSegment] = []
    func add(_ s: MeetingSegment) { lock.lock(); items.append(s); lock.unlock() }
    func all() -> [MeetingSegment] { lock.lock(); defer { lock.unlock() }; return items }
}
