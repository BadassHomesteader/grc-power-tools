import Foundation

/// Per-row metadata for the Agent Pad: which model a session is running, how
/// many turns it has taken, what it has spent, and which branch it is on.
///
/// Everything here comes from files Claude Code already writes — the session
/// transcript and the working copy's .git/HEAD — so there is no extra process
/// to run and nothing to thread through the hook payloads.

/// Model · turns · tokens, folded INCREMENTALLY out of a session transcript.
///
/// A transcript is append-only JSONL, so each refresh parses only the bytes
/// added since the last one and adds them to running totals. The pad refreshes
/// every 10s with a row per session; re-reading a multi-megabyte transcript
/// each time, per row, would not be free.
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
    }

    private struct Entry {
        var offset: UInt64
        var totals: Totals
    }
    private var cache: [String: Entry] = [:]

    func totals(for path: String) -> Totals {
        guard !path.isEmpty,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
        else { return Totals() }
        let end = size.uint64Value
        var entry = cache[path] ?? Entry(offset: 0, totals: Totals())
        // Shrunk = a different session reusing the path (or a rewrite): start over.
        if end < entry.offset { entry = Entry(offset: 0, totals: Totals()) }
        if end == entry.offset { return entry.totals }

        guard let fh = FileHandle(forReadingAtPath: path) else { return entry.totals }
        defer { try? fh.close() }
        try? fh.seek(toOffset: entry.offset)
        guard let data = try? fh.readToEnd(), !data.isEmpty,
              // Only fold WHOLE lines — the file may be mid-write, and half a
              // JSON object folded in once would corrupt the totals forever.
              let lastNewline = data.lastIndex(of: 0x0A)
        else { return entry.totals }
        let whole = data[..<data.index(after: lastNewline)]

        for line in whole.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if type == "ai-title", let t = obj["aiTitle"] as? String, !t.isEmpty {
                entry.totals.title = t
                continue
            }
            guard type == "assistant", let message = obj["message"] as? [String: Any] else { continue }
            if let model = message["model"] as? String { entry.totals.model = Self.shortModel(model) }
            guard let usage = message["usage"] as? [String: Any] else { continue }
            entry.totals.msgs += 1
            entry.totals.tokens += (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
            entry.totals.tokens += (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
        }
        entry.offset += UInt64(whole.count)
        cache[path] = entry
        return entry.totals
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
