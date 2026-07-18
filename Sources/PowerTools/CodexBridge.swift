import Foundation
import AppKit

/// Codex (OpenAI) sessions for the Agent Pad — watch-only tier.
///
/// Codex (the ChatGPT desktop app's coding surface AND the codex CLI — both
/// write the same store) has no hook server to lean on, but everything the
/// pad needs lands in ~/.codex:
///  - sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl — per-thread event
///    stream. `event_msg` payload types give the lifecycle: task_started →
///    busy, task_complete → idle, anything containing "approval" → blocked
///    on the user; a file still being appended (fresh mtime) is a running
///    turn regardless.
///  - .codex-global-state.json — thread-titles.titles (uuid → human title)
///    and thread-workspace-root-hints (uuid → workspace path).
///
/// Rows are re-derived from disk on every refresh (pad open + 10s tick) and
/// pushed into the registry as external "codex" rows: they triage, collapse
/// into the strip, and dismiss like Claude rows, but carry no remote-control
/// buttons — the host app is Electron (AX-opaque below the window, the
/// Antigravity lesson), so focus = activate the app.
enum CodexWatcher {
    /// ChatGPT.app hosts the Codex desktop surface.
    static let bundleID = "com.openai.codex"

    /// Threads untouched for longer than this fall off the pad.
    private static let activeWindow: TimeInterval = 24 * 3600
    /// A rollout written this recently is a turn in flight, whatever the last
    /// parsed lifecycle event says (the stream lags the state).
    private static let appendingWindow: TimeInterval = 20
    private static let maxRows = 8
    private static let tailBytes = 64 * 1024

    struct Snapshot: Sendable {
        var id: String
        var cwd: String
        var title: String
        var state: ClaudeSession.State
        var detail: String
        var started: Date
        var changed: Date
    }

    /// Scan off-main, deliver rows into the registry on main.
    @MainActor
    static func refresh(into registry: ClaudeSessionRegistry) {
        Task.detached(priority: .utility) {
            let snaps = scan()
            await MainActor.run {
                let rows = snaps.map { s -> ClaudeSession in
                    var row = ClaudeSession(id: s.id)
                    row.kind = "codex"
                    row.cwd = s.cwd
                    row.label = s.title
                    row.state = s.state
                    row.detail = s.detail
                    row.started = s.started
                    row.stateChanged = s.changed
                    return row
                }
                registry.setExternal(kind: "codex", rows)
            }
        }
    }

    /// Bring the Codex host app forward (per-thread focus is impossible from
    /// outside an Electron AX tree).
    @MainActor
    static func focus() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Disk scan

    nonisolated static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Snapshot] {
        let codex = home.appendingPathComponent(".codex")
        let sessionsDir = codex.appendingPathComponent("sessions")
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sessionsDir,
                                     includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        let cutoff = Date().addingTimeInterval(-activeWindow)
        var files: [(url: URL, mtime: Date, btime: Date?)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]),
                  let m = vals.contentModificationDate, m > cutoff else { continue }
            files.append((url, m, vals.creationDate))
        }
        files.sort { $0.mtime > $1.mtime }
        let state = globalState(codex)
        return files.prefix(maxRows).compactMap { f in
            snapshot(of: f.url, mtime: f.mtime, btime: f.btime,
                     titles: state.titles, hints: state.hints)
        }
    }

    /// thread-titles + workspace hints out of .codex-global-state.json.
    private nonisolated static func globalState(_ codex: URL) -> (titles: [String: String], hints: [String: String]) {
        guard let data = try? Data(contentsOf: codex.appendingPathComponent(".codex-global-state.json")),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([:], [:]) }
        let titles = ((obj["thread-titles"] as? [String: Any])?["titles"] as? [String: String]) ?? [:]
        let hints = (obj["thread-workspace-root-hints"] as? [String: String]) ?? [:]
        return (titles, hints)
    }

    private nonisolated static func snapshot(of url: URL, mtime: Date, btime: Date?,
                                             titles: [String: String], hints: [String: String]) -> Snapshot? {
        // rollout-2026-07-17T13-03-42-<uuid>.jsonl — the uuid is the thread id.
        let base = url.deletingPathExtension().lastPathComponent
        guard base.count > 36 else { return nil }
        let uuid = String(base.suffix(36))
        guard uuid.contains("-") else { return nil }

        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        // Head: session_meta (line 1 — tens of KB, it embeds the base
        // instructions) → cwd; first user_message → fallback title, the same
        // "first real prompt" discipline the Claude rows use.
        var cwd = hints[uuid] ?? ""
        var firstPrompt = ""
        if let head = try? fh.read(upToCount: 256 * 1024), !head.isEmpty {
            for line in head.split(separator: UInt8(ascii: "\n")) {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                if o["type"] as? String == "session_meta",
                   let p = o["payload"] as? [String: Any] {
                    // Codex spawns internal helper threads (guardian review,
                    // etc.) — only user-started threads belong on the pad.
                    if let src = p["thread_source"] as? String, src != "user" { return nil }
                    if let metaCwd = p["cwd"] as? String, !metaCwd.isEmpty { cwd = metaCwd }
                    continue
                }
                if firstPrompt.isEmpty, o["type"] as? String == "event_msg",
                   let p = o["payload"] as? [String: Any], p["type"] as? String == "user_message",
                   let msg = p["message"] as? String {
                    let line1 = msg.split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .first { !$0.isEmpty } ?? ""
                    firstPrompt = String(line1.prefix(80))
                    if !cwd.isEmpty { break }
                }
            }
        }

        // Tail: newest lifecycle event wins. Walk backward so one read decides.
        var state = ClaudeSession.State.idle
        var detail = ""
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? fh.seek(toOffset: start)
        if let tail = try? fh.readToEnd(), !tail.isEmpty {
            var lines = tail.split(separator: UInt8(ascii: "\n"))
            if start > 0, !lines.isEmpty { lines.removeFirst() }   // partial first line
            for line in lines.reversed() {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      o["type"] as? String == "event_msg",
                      let p = o["payload"] as? [String: Any],
                      let pt = p["type"] as? String else { continue }
                if pt.range(of: "approval", options: .caseInsensitive) != nil {
                    state = .needsInput
                    detail = "waiting for approval — in Codex"
                    break
                }
                if pt == "task_started" { state = .busy; break }
                if pt == "task_complete" { state = .idle; break }
            }
        }
        // Still being appended = a turn is running, even if task_started
        // scrolled out of the tail window.
        if state == .idle, Date().timeIntervalSince(mtime) < appendingWindow {
            state = .busy
        }

        return Snapshot(id: "codex-\(uuid)", cwd: cwd, title: titles[uuid] ?? firstPrompt,
                        state: state, detail: detail,
                        started: btime ?? mtime, changed: mtime)
    }
}
