import Foundation
import AppKit

/// Grok Bot bots for the Agent Pad and the notch — watch-only tier, like
/// Codex and Cursor.
///
/// "Grok Bot" is Anysphere's Sand desktop app (bundle com.anysphere.sand). It
/// persists its client state as JSON blobs under
/// ~/Library/Application Support/Grok Bot/sand-client-persistence/, one file
/// per key with the key base32-encoded into the file name:
///  - …roster.last-roster — one row per bot: name, description,
///    lastActivityAt, hasUnread/unreadCount, awaitingUserResponse.
///  - …transcript.replicas.<botId> — the bot's entries; a trailing
///    send-message with no reply yet, or a message still streaming, means the
///    bot is working right now.
///
/// Names, states and counts only. The transcripts hold real content (one
/// bot's carries credential notes), and none of it is ever surfaced.
/// Rows re-derive on every refresh and ride the registry's external channel.
/// Watch-only: an Electron app, so focus = activate it.
enum GrokBotWatcher {
    static let bundleID = "com.anysphere.sand"

    /// A bot that has not moved in this long drops off unless it needs you.
    private static let activeWindow: TimeInterval = 24 * 3600
    /// A message sent this recently with no reply yet = the bot is working.
    private static let busyWindow: TimeInterval = 15 * 60
    /// The roster has two dozen bots; the pad and the notch triage the top.
    private static let maxRows = 8
    /// Unread output counts as attention for this long after the bot last
    /// moved; older unread settles to idle (the count stays on the row) so a
    /// week of unopened bots cannot outrank a working session forever.
    private static let unseenWindow: TimeInterval = 6 * 3600

    struct Snapshot: Sendable {
        var id: String
        var name: String
        var description: String
        var state: ClaudeSession.State
        var detail: String
        var created: Date
        var changed: Date
    }

    @MainActor
    static func refresh(into registry: ClaudeSessionRegistry) {
        Task.detached(priority: .utility) {
            guard let snaps = scan() else { return }   // store mid-write — keep current rows
            await MainActor.run {
                let rows = snaps.map { s -> ClaudeSession in
                    var row = ClaudeSession(id: s.id)
                    row.kind = "grok"
                    row.hostBundleID = bundleID
                    // The bot's name is the identity line; its description the task line.
                    row.project = s.name
                    row.label = s.description
                    row.state = s.state
                    row.detail = s.detail
                    row.started = s.created
                    row.stateChanged = s.changed
                    // Elapsed reads "since it last did anything", not since the
                    // bot was created weeks ago.
                    row.startedAt = s.changed
                    return row
                }
                registry.setExternal(kind: "grok", rows)
            }
        }
    }

    /// Same activation path as the other watch-only agents — activate() from
    /// a background app is dropped; openApplication(activates:) is not.
    @MainActor
    static func focus() {
        let url = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard let url else {
            log("agentpad: focus grok — no app for \(bundleID)")
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
            log("agentpad: focus grok → open \(err == nil ? "ok" : "err \(err!.localizedDescription)")")
        }
    }

    // MARK: Scan

    static var storeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence")
    }

    /// nil = the roster could not be read right now (mid-write) — the caller
    /// keeps the previous rows rather than blanking the pad. [] = no store.
    nonisolated static func scan(dir: URL = storeDir) -> [Snapshot]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var rosterURL: URL?
        var transcripts: [String: URL] = [:]   // bot id → replica file
        for n in names where n.hasSuffix(".blob") {
            guard let key = base32Decode(String(n.dropLast(5))) else { continue }
            if key.hasSuffix(".roster.last-roster") { rosterURL = dir.appendingPathComponent(n) }
            if let r = key.range(of: ".transcript.replicas.") {
                transcripts[String(key[r.upperBound...])] = dir.appendingPathComponent(n)
            }
        }
        guard let rosterURL else { return [] }
        guard let data = try? Data(contentsOf: rosterURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = (root["value"] as? [String: Any])?["rows"] as? [[String: Any]] else { return nil }

        let now = Date()
        var out: [Snapshot] = []
        for r in rows {
            guard let id = r["id"] as? String, let name = r["name"] as? String, !name.isEmpty else { continue }
            if r["isHiddenFromSidebar"] as? Bool == true { continue }
            var changed = msDate(r["lastActivityAt"]) ?? msDate(r["updatedAt"]) ?? .distantPast
            let unread = (r["unreadCount"] as? NSNumber)?.intValue ?? 0
            let hasUnread = r["hasUnread"] as? Bool == true || unread > 0
            // awaitingUserResponse is {tabId, reason, since} while a bot waits.
            // The reason is the bot's own ask and can be sensitive ("type your
            // … password"), so it is never surfaced; `since` dates the wait.
            let awaiting = isAwaiting(r["awaitingUserResponse"])
            if awaiting, let since = msDate((r["awaitingUserResponse"] as? [String: Any])?["since"]) {
                changed = max(changed, since)
            }
            guard awaiting || hasUnread || now.timeIntervalSince(changed) < activeWindow else { continue }

            var state: ClaudeSession.State = .idle
            var detail = ""
            if awaiting {
                state = .needsInput
                detail = "waiting for you — in Grok Bot"
            } else if let t = transcripts[id], isWorking(t, now: now) {
                state = .busy
            } else if hasUnread {
                if now.timeIntervalSince(changed) < unseenWindow { state = .unseen }
                detail = unread > 0 ? "\(unread) unread" : ""
            }
            out.append(Snapshot(id: "grok-\(id)", name: name,
                                description: (r["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                state: state, detail: detail,
                                created: msDate(r["createdAt"]) ?? changed, changed: changed))
        }
        // A bot that waits on you is never cut by the cap, however old.
        out.sort { a, b in
            if (a.state == .needsInput) != (b.state == .needsInput) { return a.state == .needsInput }
            return a.changed > b.changed
        }
        return Array(out.prefix(maxRows))
    }

    /// The flag arrives as a Bool or as an object (empty = not waiting).
    private nonisolated static func isAwaiting(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let d = v as? [String: Any] {
            if d.isEmpty { return false }
            if let b = d["awaiting"] as? Bool { return b }
            if let b = d["isAwaiting"] as? Bool { return b }
            return true
        }
        return false
    }

    /// The transcript's LAST entry decides: a send-message with nothing after
    /// it (and recent) is a request in flight; an assistant message still
    /// streaming is a reply in progress. Only a replica touched within the
    /// busy window is even opened — the rest cannot be working.
    private nonisolated static func isWorking(_ url: URL, now: Date) -> Bool {
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              now.timeIntervalSince(mtime) < busyWindow,
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = (root["value"] as? [String: Any])?["entries"] as? [[String: Any]],
              let last = entries.last else { return false }
        let kind = last["kind"] as? String ?? ""
        let at = msDate(last["timestampMs"]) ?? mtime
        if kind == "send-message" { return now.timeIntervalSince(at) < busyWindow }
        if kind == "message", last["isStreaming"] as? Bool == true { return true }
        return false
    }

    private nonisolated static func msDate(_ v: Any?) -> Date? {
        let ms: Double?
        switch v {
        case let n as NSNumber: ms = n.doubleValue
        case let s as String: ms = Double(s)
        default: ms = nil
        }
        guard let ms, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// RFC 4648 base32 (the store lower-cases it and drops the padding).
    nonisolated static func base32Decode(_ s: String) -> String? {
        var map: [Character: UInt32] = [:]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".enumerated() { map[c] = UInt32(i) }
        var bits = 0
        var acc: UInt32 = 0
        var out: [UInt8] = []
        for ch in s.uppercased() where ch != "=" {
            guard let v = map[ch] else { return nil }
            acc = (acc << 5) | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> UInt32(bits)) & 0xFF))
                acc &= (1 << UInt32(bits)) - 1
            }
        }
        return String(bytes: out, encoding: .utf8)
    }
}
