import Foundation
import AppKit
import Network

/// Claude Code bridge — the plumbing behind the Agent Pad (a virtual Codex
/// Micro for Claude Code). Three pieces:
///
/// - `ClaudeHookServer`: a tiny localhost HTTP server. Claude Code hooks
///   (installed by `ClaudeHooksInstaller`) POST every session event here —
///   session started/ended, prompt submitted, turn finished, permission
///   dialog waiting — so Power Tools always knows which sessions exist and
///   which need attention. Loopback-only; the payload carries no secrets and
///   every action is user-initiated from the pad.
/// - `ClaudeSessionRegistry`: folds those events into per-session state.
/// - `ClaudeInjector`: steers a session — focus its terminal tab, type a
///   prompt into it, answer a permission dialog. tmux is the reliable path
///   (no window focus needed); Terminal.app is scripted by tty; everything
///   else (VS Code, iTerm2) gets activate-then-synthesize via `Inserter`.

// MARK: - Session model

struct ClaudeSession: Codable {
    enum State: String, Codable {
        case busy             // a turn is running
        case idle             // finished, waiting for input
        case unseen           // finished while the user wasn't looking (the IDE tab's orange dot)
        case needsPermission  // a permission dialog is on screen
        case needsInput       // Claude asked a question / sat idle
        case error            // the turn died (rate limit, billing, …)

        var label: String {
            switch self {
            case .busy: return "working…"
            case .idle: return "idle"
            case .unseen: return "done — unseen"
            case .needsPermission: return "needs permission"
            case .needsInput: return "needs input"
            case .error: return "failed"
            }
        }
    }

    var id: String
    var cwd: String = ""
    /// Controlling terminal of the claude process ("ttys003"), reported by the
    /// hook script — it's how we find the right Terminal.app tab.
    var tty: String = ""
    var claudePID: pid_t = 0
    var tmuxPane: String = ""
    /// The GUI app hosting the session (Terminal, VS Code, …), resolved once by
    /// walking the claude process's ancestry.
    var hostPID: pid_t = 0
    var hostBundleID: String = ""
    var state: State = .idle
    /// One-line context for the state ("Bash: rm -rf …" for a permission ask).
    var detail: String = ""
    /// Human title — the session's first real prompt (IDE tabs all share one
    /// cwd, so the folder name alone is useless). Backfilled from the
    /// transcript or captured from UserPromptSubmit.
    var label: String = ""
    var labelBackfillStarted = false
    var started = Date()
    var stateChanged = Date()

    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "session" : name
    }

    var displayTitle: String { label.isEmpty ? projectName : label }

    /// Short tty tag ("s003") to tell two sessions in the same project apart.
    var ttyTag: String {
        tty.hasPrefix("tty") ? String(tty.dropFirst(3)) : tty
    }
}

// MARK: - Registry

/// Folds hook events into ordered session state. Main-actor: events arrive via
/// the server's main-queue callback, reads come from the UI.
@MainActor
final class ClaudeSessionRegistry {
    private var sessions: [String: ClaudeSession] = [:]
    var onChange: (([ClaudeSession]) -> Void)?

    var ordered: [ClaudeSession] {
        sessions.values.sorted { $0.started < $1.started }
    }

    // MARK: Persistence — the app restarts (updates, crashes) must not blank
    // the pad; sessions reload and the liveness prune drops the stale ones.

    private static var persistURL: URL {
        Config.appSupportDir.appendingPathComponent("agent-sessions.json")
    }

    func loadPersisted() {
        guard let data = try? Data(contentsOf: Self.persistURL),
              let list = try? JSONDecoder().decode([ClaudeSession].self, from: data) else { return }
        // Skip placeholders persisted by older builds that predate the "/"
        // utility-process filter.
        for s in list where !(s.id.hasPrefix("pid-") && s.cwd == "/") { sessions[s.id] = s }
        pruneDead()
        onChange?(ordered)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(ordered) {
            try? data.write(to: Self.persistURL, options: .atomic)
        }
    }

    /// Sweep running `claude` processes and add any the hooks haven't reported
    /// (live but silent since before the hooks existed). When exactly one
    /// recent transcript matches the process's project, the row adopts its
    /// real session id + title; otherwise it shows as an untitled idle row
    /// keyed "pid-N" and upgrades in place on its first hook event.
    func refreshDiscovered() {
        ClaudeDiscovery.runningSessions { [weak self] procs in
            // The log parse is file IO — off the main thread, then apply.
            DispatchQueue.global(qos: .utility).async {
                let tabs = ClaudeDiscovery.ideTabSessions()
                DispatchQueue.main.async { [weak self] in
                    self?.applyDiscovery(procs: procs, tabs: tabs)
                }
            }
        }
    }

    private func applyDiscovery(procs: [ClaudeDiscovery.Proc], tabs: [ClaudeDiscovery.IDETab]) {
        for proc in procs {
            // cwd "/" is the extension's utility process, not a chat session.
            if proc.cwd == "/" { continue }
            if sessions.values.contains(where: { $0.claudePID == proc.pid }) { continue }
            var id = "pid-\(proc.pid)"
            var label = ""
            let known = Set(sessions.keys)
            let candidates = ClaudeDiscovery.transcripts(inProjectFor: proc.cwd, since: proc.started)
                .filter { !known.contains($0.stem) }
            if candidates.count == 1, let only = candidates.first {
                id = only.stem
                label = Self.titleFromTranscript(only.path) ?? ""
            }
            var s = ClaudeSession(id: id)
            s.cwd = proc.cwd
            s.claudePID = proc.pid
            s.label = label
            s.labelBackfillStarted = true   // we already tried; events refresh it
            s.started = proc.started
            s.stateChanged = proc.started
            if let host = ClaudeInjector.resolveHostApp(of: proc.pid) {
                s.hostPID = host.pid
                s.hostBundleID = host.bundleID
            }
            sessions[id] = s
        }

        // Placeholder adoption: an IDE-hosted process can't reveal its session
        // id, but the log knows which tabs exist. Pair the newest placeholders
        // with the most recently active unclaimed tabs — if a pairing is ever
        // wrong, the row self-corrects on that session's next hook event.
        let terminalHosts = ["com.apple.Terminal", "com.googlecode.iterm2"]
        var unclaimed = tabs.reversed().filter { sessions[$0.id] == nil }
        let placeholders = sessions.values
            .filter { $0.id.hasPrefix("pid-") && !terminalHosts.contains($0.hostBundleID) }
            .sorted { $0.started > $1.started }
        for ph in placeholders {
            guard let tab = unclaimed.first else { break }
            unclaimed.removeFirst()
            var s = ph
            s.id = tab.id
            s.label = tab.title
            sessions.removeValue(forKey: ph.id)
            sessions[tab.id] = s
        }

        // Tab titles from the IDE extension log are canonical — they're what
        // the user actually sees in the tab strip; overwrite heuristic labels.
        // The same log stream drives the tab's attention dot (waiting_input),
        // which the hooks don't always surface — apply it when it's newer than
        // what the hooks last told us. Runs after adoption so fresh swaps get
        // their state too.
        for tab in tabs {
            guard var s = sessions[tab.id] else { continue }
            if s.label != tab.title { s.label = tab.title }
            // Effective state: the session-state line, overlaid by the newer
            // tab-strip flags (pending permission dialog / unseen completion).
            var mapped: ClaudeSession.State?
            var at = tab.at
            switch tab.state {
            case "running": mapped = .busy
            case "waiting_input": mapped = .needsInput
            case "idle": mapped = .idle
            default: break
            }
            if let flagsAt = tab.flagsAt, flagsAt >= (at ?? .distantPast) {
                if tab.pendingPerms { mapped = .needsPermission; at = flagsAt }
                else if tab.unseen { mapped = .unseen; at = flagsAt }
            }
            if let mapped, let at, at > s.stateChanged, mapped != s.state {
                s.state = mapped
                s.detail = ""
                s.stateChanged = at
            }
            sessions[tab.id] = s
        }

        pruneDead()
        persist()
        onChange?(ordered)
    }

    /// Ingest one wrapped hook event: {"event", "tty", "ppid", "tmux", "payload"}.
    func ingest(_ obj: [String: Any]) {
        guard let event = obj["event"] as? String else { return }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        guard let sid = payload["session_id"] as? String, !sid.isEmpty else { return }

        if event == "SessionEnd" {
            sessions.removeValue(forKey: sid)
            onChange?(ordered)
            return
        }

        // Any event may be the first we see (the app can start after the
        // session did), so create-on-first-sight, not just on SessionStart.
        var s = sessions[sid] ?? ClaudeSession(id: sid)
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty { s.cwd = cwd }
        if let tty = obj["tty"] as? String, !tty.isEmpty, tty != "??" { s.tty = tty }
        if let pane = obj["tmux"] as? String, !pane.isEmpty { s.tmuxPane = pane }
        if let ppid = obj["ppid"] as? Int, ppid > 1, s.claudePID == 0 {
            s.claudePID = pid_t(ppid)
            if let host = ClaudeInjector.resolveHostApp(of: pid_t(ppid)) {
                s.hostPID = host.pid
                s.hostBundleID = host.bundleID
            }
            // A discovery placeholder for this process is superseded by the
            // real session the moment it speaks.
            if sid != "pid-\(ppid)" { sessions.removeValue(forKey: "pid-\(ppid)") }
        }

        switch event {
        case "SessionStart":
            s.state = .idle
        case "UserPromptSubmit":
            s.state = .busy
            s.detail = ""
        case "Stop":
            s.state = .idle
            s.detail = ""
        case "StopFailure":
            s.state = .error
            s.detail = (payload["error_type"] as? String)
                ?? (payload["message"] as? String) ?? "turn failed"
        case "Notification":
            let type = payload["notification_type"] as? String ?? ""
            let message = payload["message"] as? String ?? ""
            switch type {
            case "permission_prompt":
                s.state = .needsPermission
                s.detail = message
            case "idle_prompt", "agent_needs_input", "elicitation_dialog":
                s.state = .needsInput
                s.detail = message
            case "agent_completed":
                s.state = .idle
                s.detail = ""
            default:
                break
            }
        default:
            break
        }
        // Title: a fresh UserPromptSubmit carries the prompt directly; anything
        // else gets a one-time transcript read (covers sessions that were
        // already running — their first prompt predates our hooks).
        if s.label.isEmpty, event == "UserPromptSubmit",
           let prompt = payload["prompt"] as? String,
           let title = Self.cleanTitle(prompt) {
            s.label = title
        }
        if s.label.isEmpty, !s.labelBackfillStarted,
           let transcript = payload["transcript_path"] as? String {
            s.labelBackfillStarted = true
            Task.detached(priority: .utility) {
                let title = Self.titleFromTranscript(transcript)
                await MainActor.run { [weak self] in
                    guard let self, let title, var cur = self.sessions[sid], cur.label.isEmpty else { return }
                    cur.label = title
                    self.sessions[sid] = cur
                    self.persist()
                    self.onChange?(self.ordered)
                }
            }
        }
        s.stateChanged = Date()
        sessions[sid] = s
        pruneDead()
        persist()
        onChange?(ordered)
    }

    /// First usable line of a prompt: skip blanks, slash-command/meta markup
    /// ("<command-name>…"), and bare URLs (a pasted link says nothing about
    /// the task — the sentence after it does).
    nonisolated static func cleanTitle(_ text: String) -> String? {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("<") { continue }
            if line.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil { continue }
            if line.range(of: #"^[~/][^ ]*$"#, options: .regularExpression) != nil { continue }  // bare path
            let collapsed = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return collapsed.count > 60 ? String(collapsed.prefix(57)) + "…" : collapsed
        }
        return nil
    }

    /// Pull a title out of a session transcript (~/.claude/projects/…/<id>.jsonl):
    /// a stored summary line if one exists, else the first real user message.
    nonisolated static func titleFromTranscript(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path),
              let data = try? fh.read(upToCount: 262_144) else { return nil }
        try? fh.close()
        var firstPrompt: String?
        for lineData in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(lineData.utf8))) as? [String: Any]
            else { continue }
            let type = obj["type"] as? String
            if type == "summary", let s = obj["summary"] as? String, let t = cleanTitle(s) {
                return t   // a compaction summary is the best title there is
            }
            guard firstPrompt == nil, type == "user", (obj["isMeta"] as? Bool) != true,
                  let message = obj["message"] as? [String: Any] else { continue }
            var text: String?
            if let s = message["content"] as? String { text = s }
            else if let parts = message["content"] as? [[String: Any]] {
                text = parts.first { $0["type"] as? String == "text" }?["text"] as? String
            }
            if let text, let t = cleanTitle(text) { firstPrompt = t }
        }
        return firstPrompt
    }

    /// Drop sessions whose claude process is gone (crash / kill -9 — SessionEnd
    /// never fired). kill(pid, 0) probes liveness without signaling. Sessions
    /// that never reported a pid can't be probed — age those out instead.
    func pruneDead() {
        var changed = false
        for (sid, s) in sessions {
            let dead = (s.claudePID > 0 && kill(s.claudePID, 0) != 0 && errno == ESRCH)
                || (s.claudePID == 0 && s.stateChanged.timeIntervalSinceNow < -12 * 3600)
            if dead {
                sessions.removeValue(forKey: sid)
                changed = true
            }
        }
        if changed {
            persist()
            onChange?(ordered)
        }
    }
}

// MARK: - Discovery

/// Finds live `claude` processes the hooks haven't told us about — sessions
/// that were already running (and silent) when Power Tools started. Both the
/// terminal CLI and the IDE extension's sidecar run a binary named `claude`.
enum ClaudeDiscovery {
    struct Proc {
        let pid: pid_t
        let cwd: String
        let started: Date
    }

    /// Enumerate running claude processes with their working directory and
    /// start time. Shells out (ps + lsof), so results come back async on main.
    nonisolated static func runningSessions(completion: @escaping ([Proc]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            // pid + executable path (no args) — match the binary name exactly.
            var pids: [pid_t] = []
            var startDates: [pid_t: Date] = [:]
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            for line in runLines("/bin/ps", ["-axo", "pid=,lstart=,comm="]) {
                let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                guard cols.count >= 7, let pid = pid_t(cols[0]) else { continue }
                let comm = cols[6...].joined(separator: " ")
                guard comm == "claude" || comm.hasSuffix("/claude") else { continue }
                pids.append(pid)
                startDates[pid] = fmt.date(from: cols[1...5].joined(separator: " ")) ?? Date()
            }
            guard !pids.isEmpty else { DispatchQueue.main.async { completion([]) }; return }
            // One lsof call for all pids: cwd per process.
            var cwds: [pid_t: String] = [:]
            var current: pid_t = 0
            for line in runLines("/usr/sbin/lsof", ["-a", "-p", pids.map(String.init).joined(separator: ","), "-d", "cwd", "-Fn"]) {
                if line.hasPrefix("p"), let pid = pid_t(line.dropFirst()) { current = pid }
                else if line.hasPrefix("n"), current != 0 { cwds[current] = String(line.dropFirst()) }
            }
            let procs = pids.compactMap { pid -> Proc? in
                guard let cwd = cwds[pid] else { return nil }
                return Proc(pid: pid, cwd: cwd, started: startDates[pid] ?? Date())
            }
            DispatchQueue.main.async { completion(procs) }
        }
    }

    /// Transcripts in a project's folder touched since `since` (with slack for
    /// clock/parse skew) — candidates for which session a silent process is.
    /// The project folder name is the cwd with every "/" and "." dashed.
    nonisolated static func transcripts(inProjectFor cwd: String, since: Date) -> [(stem: String, path: String)] {
        let slug = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(slug)")
        let cutoff = since.addingTimeInterval(-120)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { url in
            guard url.pathExtension == "jsonl",
                  let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  mtime > cutoff else { return nil }
            return (url.deletingPathExtension().lastPathComponent, url.path)
        }
    }

    struct IDETab {
        let id: String
        let title: String
        var state: String = ""   // running / idle / waiting_input ("" = unknown)
        var at: Date?            // log-line timestamp of the last state we saw
        /// The tab-strip attention dot: `rename_tab` flags (matched by title
        /// prefix — those lines carry no sessionId).
        var unseen = false
        var pendingPerms = false
        var flagsAt: Date?
    }

    /// Canonical tab titles AND states: the IDE extension logs `rename_session`
    /// / `update_session_state` webview messages carrying sessionId, the exact
    /// tab title, and the state driving the tab's attention dot. Returned
    /// oldest→newest by last appearance, so callers can pair the most recent
    /// tabs first. Covers Antigravity + VS Code + Cursor.
    nonisolated static func ideTabSessions() -> [IDETab] {
        var tabs: [String: IDETab] = [:]
        var order: [String] = []
        let fm = FileManager.default
        let appSupport = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        for app in ["Antigravity IDE", "Code", "Cursor"] {
            let logsRoot = appSupport.appendingPathComponent("\(app)/logs")
            guard let launches = try? fm.contentsOfDirectory(atPath: logsRoot.path) else { continue }
            // Launch dirs are timestamp-named; open tabs re-announce themselves
            // after an IDE restart, so the two newest launches cover reloads.
            for launch in launches.sorted().suffix(2) {
                let launchDir = logsRoot.appendingPathComponent(launch)
                let windows = (try? fm.contentsOfDirectory(atPath: launchDir.path)) ?? []
                for w in windows where w.hasPrefix("window") {
                    let logPath = launchDir.appendingPathComponent("\(w)/exthost/Anthropic.claude-code/Claude VSCode.log").path
                    guard let fh = FileHandle(forReadingAtPath: logPath) else { continue }
                    // Titles repeat on every state change — the tail is plenty.
                    let size = (try? fh.seekToEnd()) ?? 0
                    try? fh.seek(toOffset: size > 2_097_152 ? size - 2_097_152 : 0)
                    let data = (try? fh.readToEnd()) ?? Data()
                    try? fh.close()
                    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                        // rename_tab drives the tab-strip attention dot but has
                        // no sessionId — pair by (truncated) title prefix.
                        if line.contains("\"rename_tab\"") {
                            guard let raw = Self.titleRegex.capture(line),
                                  let tabTitle = try? JSONDecoder().decode(String.self, from: Data("\"\(raw)\"".utf8))
                            else { continue }
                            let prefix = tabTitle.hasSuffix("…") ? String(tabTitle.dropLast()) : tabTitle
                            guard !prefix.isEmpty,
                                  let key = tabs.first(where: { $0.value.title.hasPrefix(prefix) })?.key
                            else { continue }
                            tabs[key]?.unseen = line.contains("\"hasUnseenCompletion\":true")
                            tabs[key]?.pendingPerms = line.contains("\"hasPendingPermissions\":true")
                            tabs[key]?.flagsAt = Self.lineTime.date(from: String(line.prefix(23)))
                            continue
                        }
                        guard line.contains("rename_session") || line.contains("update_session_state"),
                              let sid = Self.sidRegex.capture(line),
                              let raw = Self.titleRegex.capture(line),
                              let title = try? JSONDecoder().decode(String.self, from: Data("\"\(raw)\"".utf8)),
                              !title.isEmpty else { continue }
                        var tab = tabs[sid] ?? IDETab(id: sid, title: title)
                        tab = IDETab(id: sid, title: title, state: tab.state, at: tab.at,
                                     unseen: tab.unseen, pendingPerms: tab.pendingPerms, flagsAt: tab.flagsAt)
                        if line.contains("update_session_state"), let state = Self.stateRegex.capture(line) {
                            tab.state = state
                            tab.at = Self.lineTime.date(from: String(line.prefix(23)))
                        }
                        tabs[sid] = tab
                        order.removeAll { $0 == sid }
                        order.append(sid)
                    }
                }
            }
        }
        return order.compactMap { tabs[$0] }
    }

    nonisolated private static let sidRegex = try! NSRegularExpression(pattern: #""sessionId":"([0-9a-fA-F-]{36})""#)
    nonisolated private static let titleRegex = try! NSRegularExpression(pattern: #""title":"((?:[^"\\]|\\.)*)""#)
    nonisolated private static let stateRegex = try! NSRegularExpression(pattern: #""state":"([a-z_]+)""#)
    nonisolated private static let lineTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"   // the exthost log's line prefix
        return f
    }()

    nonisolated fileprivate static func runLines(_ path: String, _ args: [String]) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

private extension NSRegularExpression {
    /// First capture group of the first match, or nil.
    func capture(_ line: Substring) -> String? {
        let s = String(line)
        guard let m = firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}

// MARK: - Hook server

/// Minimal loopback HTTP server for the hook POSTs. One short-lived connection
/// per event; body is JSON; the reply is always `200 {}` — the hook script
/// never blocks Claude Code on us.
final class ClaudeHookServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.grc.whisper.hookserver")
    /// Delivered on the main queue.
    var onEvent: (([String: Any]) -> Void)?
    /// GET /sessions debug endpoint: called on the main queue, returns the
    /// current session list as JSON (curl 127.0.0.1:<port>/sessions).
    var sessionsJSON: (() -> Data)?

    func start(port: Int) -> Bool {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let params = NWParameters.tcp
        // Loopback only — hook events must not be reachable off this Mac.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return false }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.stateUpdateHandler = { state in
            if case .failed(let err) = state { log("hookserver: listener failed: \(err)") }
        }
        l.start(queue: queue)
        listener = l
        log("hookserver: listening on 127.0.0.1:\(port)")
        return true
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
                guard let self else { conn.cancel(); return }
                if let data { buffer.append(data) }
                if error != nil || buffer.count > 1_048_576 { conn.cancel(); return }
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headers = String(decoding: buffer.subdata(in: 0..<headerEnd.lowerBound), as: UTF8.self)
                    if headers.hasPrefix("GET /sessions") {
                        DispatchQueue.main.async { [weak self] in
                            let body = self?.sessionsJSON?() ?? Data("[]".utf8)
                            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                            conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
                        }
                        return
                    }
                    let contentLength = headers.split(separator: "\r\n")
                        .first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                    let bodyStart = headerEnd.upperBound
                    if buffer.count - bodyStart >= contentLength {
                        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                        self.dispatch(body)
                        let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
                        return
                    }
                }
                if complete { conn.cancel(); return }
                readMore()
            }
        }
        readMore()
    }

    private func dispatch(_ body: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return }
        DispatchQueue.main.async { [weak self] in self?.onEvent?(obj) }
    }
}

// MARK: - Injector

/// Sends input to a session's terminal. Order of preference:
/// 1. tmux send-keys (no focus dance, works with the terminal in background)
/// 2. Terminal.app scripting by tty (`do script in tab` writes to the tty)
/// 3. activate the host app + synthesize keystrokes (VS Code, iTerm2, …) —
///    the degraded tier: it types into whatever widget holds focus there.
enum ClaudeInjector {
    /// Walk the process ancestry until a real GUI app owns the pid — that's the
    /// terminal (or editor) window hosting the session.
    static func resolveHostApp(of pid: pid_t) -> (pid: pid_t, bundleID: String)? {
        var current = pid
        for _ in 0..<15 {
            if let app = NSRunningApplication(processIdentifier: current),
               let bid = app.bundleIdentifier, bid != "com.grc.whisper" {
                return (current, bid)
            }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func tmuxPath() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Bring the session's terminal tab/window to the front.
    static func focus(_ s: ClaudeSession) {
        if s.hostBundleID == "com.apple.Terminal", !s.tty.isEmpty {
            runAppleScript(selectTerminalTabScript(tty: s.tty)) { _ in }
            return
        }
        if s.hostPID > 0, let app = NSRunningApplication(processIdentifier: s.hostPID) {
            app.activate()
        }
    }

    /// Type a prompt into the session and submit it. Completion (main queue)
    /// gets nil on success or a short error string.
    static func send(_ s: ClaudeSession, text: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Tier 1: tmux — text and Enter as two calls with a beat between,
            // or bracketed-paste can swallow the submit.
            if !s.tmuxPane.isEmpty, let tmux = tmuxPath() {
                let ok1 = run(tmux, ["send-keys", "-t", s.tmuxPane, "-l", text])
                usleep(200_000)
                let ok2 = run(tmux, ["send-keys", "-t", s.tmuxPane, "Enter"])
                DispatchQueue.main.async { completion(ok1 && ok2 ? nil : "tmux send-keys failed") }
                return
            }
            // Tier 2: Terminal.app — `do script in tab` writes text + newline
            // straight to the tty; no focus needed.
            if s.hostBundleID == "com.apple.Terminal", !s.tty.isEmpty {
                runAppleScript(doScriptInTabScript(tty: s.tty, text: text)) { found in
                    completion(found ? nil : "couldn't find the Terminal tab (tty \(s.tty))")
                }
                return
            }
            // Tier 3: focus the host app and type. Focus must land first.
            DispatchQueue.main.async {
                focus(s)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(400)) {
                    Inserter.typeText(text)
                    usleep(200_000)
                    Inserter.postKey(CGKeyCode(36 /* kVK_Return */), flags: [])
                    DispatchQueue.main.async { completion(nil) }
                }
            }
        }
    }

    enum ControlKey {
        case acceptYes   // permission dialog: Y = yes
        case denyEscape  // permission dialog: Esc = no
        case cycleMode   // Shift+Tab cycles default → acceptEdits → plan
        case interrupt   // Esc stops the current turn
    }

    /// Send a single control key to the session. Same tiers as send(); the
    /// non-tmux paths focus the terminal first and synthesize the key.
    static func sendControl(_ s: ClaudeSession, _ key: ControlKey, completion: @escaping (String?) -> Void) {
        if !s.tmuxPane.isEmpty, let tmux = tmuxPath() {
            let keyName: String
            switch key {
            case .acceptYes: keyName = "y"
            case .denyEscape, .interrupt: keyName = "Escape"
            case .cycleMode: keyName = "BTab"
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = run(tmux, ["send-keys", "-t", s.tmuxPane, keyName])
                DispatchQueue.main.async { completion(ok ? nil : "tmux send-keys failed") }
            }
            return
        }
        // Focus, give the window a beat to become key, then synthesize.
        focus(s)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(400)) {
            switch key {
            case .acceptYes: Inserter.typeText("y")
            case .denyEscape, .interrupt: Inserter.postKey(CGKeyCode(53 /* kVK_Escape */), flags: [])
            case .cycleMode: Inserter.postKey(CGKeyCode(48 /* kVK_Tab */), flags: .maskShift)
            }
            DispatchQueue.main.async { completion(nil) }
        }
    }

    // MARK: AppleScript plumbing

    private static func selectTerminalTabScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return "true"
                    end if
                end repeat
            end repeat
        end tell
        return "false"
        """
    }

    private static func doScriptInTabScript(tty: String, text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        do script "\(escaped)" in t
                        return "true"
                    end if
                end repeat
            end repeat
        end tell
        return "false"
        """
    }

    /// osascript in a child process (not NSAppleScript): a stalled Terminal
    /// can't hang our main thread, and Automation TCC still attributes to us.
    private static func runAppleScript(_ script: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do {
                try p.run()
                p.waitUntilExit()
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async { completion(p.terminationStatus == 0 && text == "true") }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch { return false }
    }
}

// MARK: - Hooks installer

/// Surgically merges Power Tools' hook entries into ~/.claude/settings.json.
/// The user's existing hooks are never touched: we only remove/append entries
/// whose command references our script ("claude-hook.sh" is the marker), and
/// a backup of the previous file is written next to it every install.
enum ClaudeHooksInstaller {
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "StopFailure", "Notification"]

    static var scriptURL: URL { Config.appSupportDir.appendingPathComponent("claude-hook.sh") }
    static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static func isInstalled(settings: URL = defaultSettingsURL) -> Bool {
        guard let data = try? Data(contentsOf: settings),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("claude-hook.sh")
    }

    /// Write the forwarder script and merge one entry per event into settings.
    /// Idempotent: re-running replaces our entries (e.g. after a port change).
    static func install(port: Int, settings: URL = defaultSettingsURL) throws -> String {
        let script = """
        #!/bin/sh
        # Power Tools Agent Pad — forwards Claude Code hook events to the local app.
        # Managed by Power Tools; the settings.json entries referencing this file
        # are replaced on every install. stdin carries the hook's JSON payload;
        # $PPID is the claude process, whose tty identifies the terminal tab.
        # Always exits 0 so a quit/missing Power Tools never blocks Claude Code.
        EVENT="${1:-unknown}"
        PORT="${2:-8377}"
        PAYLOAD=$(cat)
        [ -n "$PAYLOAD" ] || PAYLOAD='{}'
        TTY=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')
        printf '{"event":"%s","tty":"%s","ppid":%s,"tmux":"%s","payload":%s}' \\
          "$EVENT" "$TTY" "${PPID:-0}" "${TMUX_PANE:-}" "$PAYLOAD" \\
          | curl -s -m 2 -X POST -H 'Content-Type: application/json' --data-binary @- \\
            "http://127.0.0.1:$PORT/hook" >/dev/null 2>&1
        exit 0
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var root = try readSettings(settings)
        backup(settings)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            // async everywhere except SessionEnd: the claude process exits right
            // after that hook, and an async curl gets killed mid-flight — the
            // session would linger on the pad until the liveness prune catches it.
            var hook: [String: Any] = [
                "type": "command",
                "command": "/bin/sh \"\(scriptURL.path)\" \(event) \(port)",
            ]
            if event != "SessionEnd" { hook["async"] = true }
            entries.append(["hooks": [hook]])
            hooks[event] = entries
        }
        root["hooks"] = hooks
        try writeSettings(root, to: settings)
        return "Hooks installed for \(events.count) events → 127.0.0.1:\(port). New Claude Code sessions will appear on the Agent Pad (already-running sessions won't report until restarted)."
    }

    static func remove(settings: URL = defaultSettingsURL) throws -> String {
        var root = try readSettings(settings)
        guard var hooks = root["hooks"] as? [String: Any] else { return "No hooks section — nothing to remove." }
        backup(settings)
        var removed = 0
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !isOurs($0) }
            removed += entries.count - kept.count
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try writeSettings(root, to: settings)
        try? FileManager.default.removeItem(at: scriptURL)
        return "Removed \(removed) Power Tools hook entries."
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String)?.contains("claude-hook.sh") == true }
    }

    private static func readSettings(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }  // no file yet — start fresh
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Refuse to touch a file we can't fully parse — a rewrite would
            // destroy whatever the user has in there.
            throw NSError(domain: "GRCWhisper", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "\(url.path) isn't valid JSON — fix it first, nothing was changed"])
        }
        return obj
    }

    private static func writeSettings(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func backup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent("settings.json.pt-backup")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
    }
}
