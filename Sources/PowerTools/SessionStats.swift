import Foundation

/// Per-row metadata for the Agent Pad and the notch: which model a session is
/// running, how many turns it has taken, what it has spent, which branch it is
/// on, what it last did, and when it really started.
///
/// Everything here comes from files Claude Code already writes — the session
/// transcript, the per-process session file and the working copy's .git/HEAD —
/// so there is no extra process to run and nothing to thread through the hook
/// payloads.

/// Model · turns · tokens · last activity, folded INCREMENTALLY out of a
/// session transcript.
///
/// A transcript is append-only JSONL, so each refresh parses only the bytes
/// added since the last one and adds them to running totals. The pad and the
/// notch refresh every 10s with a row per session; re-reading a multi-megabyte
/// transcript each time, per row, would not be free.
@MainActor
final class TranscriptStats {
    static let shared = TranscriptStats()

    struct Totals {
        var model = ""
        var msgs = 0
        /// input + output. Cache reads are deliberately excluded — that is the
        /// same total Claude Code itself reports, and counting a 244k cache read
        /// as "spend" would make every long session look identical.
        var tokens = 0
        /// Claude Code's own generated title for the session ("ai-title"),
        /// which beats a truncated first prompt when one exists.
        var title = ""
        /// What the session last did — "Editing Foo.swift", "Bash: git status".
        var activity = ""
        /// The cwd the transcript itself reports: the real project directory
        /// even when the process's cwd is only an IDE workspace root.
        var cwd = ""
        /// The fold started mid-file (huge transcript), so the counts are
        /// lower bounds and the row says so ("128+ msgs").
        var partial = false
    }

    private struct Entry {
        var offset: UInt64
        var totals: Totals
    }
    private var cache: [String: Entry] = [:]

    /// A transcript past this size is folded from its tail only. The largest
    /// one on this machine is 324 MB; reading that on the main actor to count
    /// tokens would stall the app for seconds on every launch.
    static let boundedFoldThreshold: UInt64 = 32 << 20
    static let boundedFoldTail: UInt64 = 8 << 20

    func totals(for path: String) -> Totals {
        guard !path.isEmpty,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
        else { return Totals() }
        let end = size.uint64Value
        var entry = cache[path] ?? Entry(offset: 0, totals: Totals())
        // Shrunk = a different session reusing the path (or a rewrite): start over.
        if end < entry.offset { entry = Entry(offset: 0, totals: Totals()) }
        if end == entry.offset { return entry.totals }
        var skipFragment = false
        if entry.offset == 0, end > Self.boundedFoldThreshold {
            entry.offset = end - Self.boundedFoldTail
            entry.totals.partial = true
            skipFragment = true
        }

        guard let fh = FileHandle(forReadingAtPath: path) else { return entry.totals }
        defer { try? fh.close() }
        try? fh.seek(toOffset: entry.offset)
        guard var data = try? fh.readToEnd(), !data.isEmpty else { return entry.totals }
        if skipFragment {
            // Landed mid-line: drop the fragment up to and including its newline.
            guard let nl = data.firstIndex(of: 0x0A) else { return entry.totals }
            entry.offset += UInt64(data.distance(from: data.startIndex, to: nl) + 1)
            data = data[data.index(after: nl)...]
        }
        // Only fold WHOLE lines — the file may be mid-write, and half a JSON
        // object folded in once would corrupt the totals forever.
        guard !data.isEmpty, let lastNewline = data.lastIndex(of: 0x0A) else { return entry.totals }
        let whole = data[..<data.index(after: lastNewline)]

        for line in whole.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if let cwd = obj["cwd"] as? String, !cwd.isEmpty { entry.totals.cwd = cwd }
            if type == "ai-title", let t = obj["aiTitle"] as? String, !t.isEmpty {
                entry.totals.title = t
                continue
            }
            guard type == "assistant", let message = obj["message"] as? [String: Any] else { continue }
            if let model = message["model"] as? String { entry.totals.model = Self.shortModel(model) }
            if let content = message["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "tool_use" {
                    guard let name = block["name"] as? String else { continue }
                    entry.totals.activity = Self.describe(tool: name, input: block["input"] as? [String: Any] ?? [:])
                }
            }
            guard let usage = message["usage"] as? [String: Any] else { continue }
            entry.totals.msgs += 1
            entry.totals.tokens += (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
            entry.totals.tokens += (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
        }
        entry.offset += UInt64(whole.count)
        cache[path] = entry
        return entry.totals
    }

    /// One line of what a tool call is doing, in the words the row has room for.
    static func describe(tool: String, input: [String: Any]) -> String {
        let file = ((input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }) ?? ""
        switch tool {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return file.isEmpty ? "Editing" : "Editing \(file)"
        case "Read":
            return file.isEmpty ? "Reading" : "Reading \(file)"
        case "Bash":
            let cmd = ((input["command"] as? String) ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return cmd.isEmpty ? "Bash" : "Bash: " + String(cmd.prefix(48))
        case "Grep", "Glob":
            if let pattern = input["pattern"] as? String, !pattern.isEmpty {
                return "Searching \(String(pattern.prefix(24)))"
            }
            return "Searching"
        case "Agent", "Task":
            return "Delegating"
        case "WebFetch", "WebSearch":
            return "Browsing"
        default:
            return tool
        }
    }

    /// "claude-opus-5" → "Opus", "claude-haiku-4-5-20251001" → "Haiku",
    /// "gpt-5-codex" → "GPT". Family only: the row has no space for a version,
    /// and the family is what the reader is actually triaging on.
    static func shortModel(_ raw: String) -> String {
        let m = raw.lowercased()
        for (needle, name) in [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku"),
                               ("fable", "Fable"), ("gpt", "GPT"), ("gemini", "Gemini")]
        where m.contains(needle) {
            return name
        }
        return raw.split(separator: "-").first.map(String.init)?.capitalized ?? ""
    }
}

/// The per-process file Claude Code writes at ~/.claude/sessions/<pid>.json:
/// the real start time, the session id, the canonical cwd, and whether the
/// process is the CLI or an IDE extension ("claude-vscode"). Files outlive
/// their process and pids recycle, so a hit is only trusted by the caller when
/// its sessionId matches the row.
@MainActor
final class SessionMeta {
    static let shared = SessionMeta()

    struct Info {
        var sessionId = ""
        var cwd = ""
        var startedAt: Date?
        var entrypoint = ""
    }

    private struct Entry {
        var stamp: Date
        var info: Info?
    }
    private var cache: [pid_t: Entry] = [:]

    func info(pid: pid_t) -> Info? {
        guard pid > 0 else { return nil }
        let path = NSHomeDirectory() + "/.claude/sessions/\(pid).json"
        guard let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { cache[pid] = nil; return nil }
        if let hit = cache[pid], hit.stamp == stamp { return hit.info }
        var info: Info?
        if let data = FileManager.default.contents(atPath: path),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var i = Info()
            i.sessionId = obj["sessionId"] as? String ?? ""
            i.cwd = obj["cwd"] as? String ?? ""
            if let ms = (obj["startedAt"] as? NSNumber)?.doubleValue, ms > 0 {
                i.startedAt = Date(timeIntervalSince1970: ms / 1000)
            }
            i.entrypoint = obj["entrypoint"] as? String ?? ""
            info = i
        }
        cache[pid] = Entry(stamp: stamp, info: info)
        return info
    }
}

/// Where a session's transcript actually lives. Claude Code names the project
/// folder after the cwd the session STARTED in; the registry's cwd can drift
/// (lsof reports the live cwd, IDE tabs report the workspace root), so the
/// naive slug misses for rows that changed directory. Tries the slugs it knows,
/// then sweeps ~/.claude/projects for the id once, and remembers the answer.
@MainActor
final class TranscriptLocator {
    static let shared = TranscriptLocator()

    private var found: [String: String] = [:]
    private var missedAt: [String: Date] = [:]
    private static let retryAfter: TimeInterval = 60
    private static var root: String { NSHomeDirectory() + "/.claude/projects/" }

    func path(id: String, cwds: [String]) -> String {
        guard !id.isEmpty else { return "" }
        let fm = FileManager.default
        if let p = found[id] {
            if fm.fileExists(atPath: p) { return p }
            found[id] = nil
        }
        // The direct candidates are two stats — always try them, even after a
        // miss: a session's transcript appears a moment after its first hook,
        // and a one-shot `claude -p` can start AND end inside the retry window.
        // Only the directory sweep is rationed.
        for cwd in cwds where !cwd.isEmpty {
            let p = Self.root + Self.slug(cwd) + "/" + id + ".jsonl"
            if fm.fileExists(atPath: p) { found[id] = p; missedAt[id] = nil; return p }
        }
        if let t = missedAt[id], t.timeIntervalSinceNow > -Self.retryAfter { return "" }
        if let dirs = try? fm.contentsOfDirectory(atPath: Self.root) {
            for d in dirs {
                let p = Self.root + d + "/" + id + ".jsonl"
                if fm.fileExists(atPath: p) { found[id] = p; return p }
            }
        }
        missedAt[id] = Date()
        return ""
    }

    static func slug(_ cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    }
}

/// Fold in the row metadata the hooks never send: branch, model, turns,
/// tokens, last activity, true start time and Claude Code's own session title.
/// Every reader is cached and incremental, so this runs on every 10s refresh —
/// and once more when a session ends, so its tombstone keeps what the row
/// showed (the live registry never stores these; they ride on local copies).
@MainActor
enum SessionEnricher {
    static func enrich(_ session: ClaudeSession) -> ClaudeSession {
        var s = session
        guard !s.isWatchOnly else { return s }
        var metaCwd = ""
        if let meta = SessionMeta.shared.info(pid: s.claudePID), meta.sessionId == s.id {
            if let start = meta.startedAt { s.startedAt = start }
            if !meta.entrypoint.isEmpty { s.entrypoint = meta.entrypoint }
            metaCwd = meta.cwd
        }
        let path = TranscriptLocator.shared.path(id: s.id, cwds: [s.cwd, metaCwd])
        let totals = TranscriptStats.shared.totals(for: path)
        s.model = totals.model
        s.msgs = totals.msgs
        s.tokens = totals.tokens
        s.statsPartial = totals.partial
        s.activity = totals.activity
        // Claude Code's generated title beats the first-prompt backfill.
        if !totals.title.isEmpty { s.label = totals.title }
        // The transcript's cwd is the project; the process cwd may be only an
        // IDE workspace root, which is why every IDE row used to read "Code".
        let projectDir = totals.cwd.isEmpty ? s.cwd : totals.cwd
        s.project = (totals.cwd.isEmpty || totals.cwd == s.cwd)
            ? nil : (totals.cwd as NSString).lastPathComponent
        s.branch = GitBranch.shared.branch(forCwd: projectDir)
        return s
    }
}

/// "42s" under a minute, then "2m", then "1h 35m" — coarse on purpose: rows
/// rebuild on a 10s tick, so a seconds digit past the first minute would jump.
enum Elapsed {
    static func format(_ interval: TimeInterval) -> String {
        let s = Int(max(0, interval))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }
}

/// The checked-out branch for a working copy, read straight off .git/HEAD.
/// No `git` subprocess: the pad redraws every 10 seconds and spawning a process
/// per row on a timer is exactly the kind of thing that turns a status pad into
/// a battery complaint.
@MainActor
final class GitBranch {
    static let shared = GitBranch()

    private struct Entry {
        var head: String     // the .git/HEAD path we resolved to
        var stamp: Date      // its mtime when we last read it
        var branch: String
    }
    private var cache: [String: Entry] = [:]

    func branch(forCwd cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }
        guard let head = cache[cwd]?.head ?? Self.findHead(from: cwd) else { return "" }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: head))?[.modificationDate] as? Date
        if let hit = cache[cwd], hit.head == head, hit.stamp == stamp { return hit.branch }
        let branch = Self.read(head)
        cache[cwd] = Entry(head: head, stamp: stamp ?? .distantPast, branch: branch)
        return branch
    }

    /// Walk up to the first .git. A directory is the ordinary case; a FILE is a
    /// worktree or submodule and points at the real git dir.
    private static func findHead(from cwd: String) -> String? {
        var dir = URL(fileURLWithPath: cwd).standardized
        for _ in 0..<24 {
            let dot = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dot.path, isDirectory: &isDir) {
                if isDir.boolValue { return dot.appendingPathComponent("HEAD").path }
                if let text = try? String(contentsOf: dot, encoding: .utf8),
                   let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    let base = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                                                   : dir.appendingPathComponent(path).standardized
                    return base.appendingPathComponent("HEAD").path
                }
                return nil
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// "ref: refs/heads/main" → "main"; a bare sha means detached HEAD.
    private static func read(_ head: String) -> String {
        guard let text = try? String(contentsOfFile: head, encoding: .utf8) else { return "" }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref:") {
            return line.split(separator: "/").dropFirst(2).joined(separator: "/")
        }
        return line.isEmpty ? "" : String(line.prefix(7))
    }
}
