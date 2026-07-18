import Foundation
import AppKit
import SQLite3

/// Cursor sessions for the Agent Pad — watch-only tier, like Codex.
///
/// Cursor keeps everything in a SQLite store
/// (~/Library/Application Support/Cursor/User/globalStorage/state.vscdb,
/// WAL — cross-process read-only opens are safe). Two populations matter:
///  - ItemTable key cloudAgentRepository.agents.<user>: the cloud-agent fleet
///    as a JSON list — name, status, isUnread, isKilled, isArchived,
///    repoUrl/workspaceRootPath, createdAt/updatedAt (epoch ms).
///  - composerHeaders table: local Agents-Window/chat composers — the value
///    JSON carries name, hasBlockingPendingActions (blocked on the user),
///    hasUnreadMessages, isDraft; isSubagent/isArchived are columns.
///
/// Rows re-derive on every refresh and ride the registry's external channel.
/// Watch-only: Cursor is Electron (AX-opaque), so focus = activate the app.
enum CursorWatcher {
    static let bundleID = "com.todesktop.230313mzl4w4u92"   // Cursor.app (ToDesktop id)

    private static let activeWindow: TimeInterval = 24 * 3600
    /// A record updated this recently is a running turn.
    private static let busyWindow: TimeInterval = 60
    /// Cloud isUnread NEVER clears when the user reads the result (verified
    /// live: still true 70min after completion, mid-viewing) — it's a
    /// finished marker, not a seen-signal. Treat it as attention only while
    /// the finish is fresh, then let the row settle to idle.
    private static let unseenWindow: TimeInterval = 30 * 60

    struct Snapshot: Sendable {
        var id: String
        var cwd: String
        var title: String
        var state: ClaudeSession.State
        var detail: String
        var started: Date
        var changed: Date
    }

    @MainActor
    static func refresh(into registry: ClaudeSessionRegistry) {
        Task.detached(priority: .utility) {
            guard let snaps = scan() else { return }   // DB busy — keep current rows
            await MainActor.run {
                let rows = snaps.map { s -> ClaudeSession in
                    var row = ClaudeSession(id: s.id)
                    row.kind = "cursor"
                    row.cwd = s.cwd
                    row.label = s.title
                    row.state = s.state
                    row.detail = s.detail
                    row.started = s.started
                    row.stateChanged = s.changed
                    return row
                }
                registry.setExternal(kind: "cursor", rows)
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
            log("agentpad: focus cursor — no app for \(bundleID)")
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
            log("agentpad: focus cursor → open \(err == nil ? "ok" : "err \(err!.localizedDescription)")")
        }
    }

    // MARK: SQLite scan

    /// nil = store unreadable right now (locked/missing) — caller keeps the
    /// previous rows rather than blanking the pad.
    nonisolated static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Snapshot]? {
        let db = home.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: db.path) else { return [] }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 250)

        var snaps: [Snapshot] = []
        snaps += cloudAgents(handle)
        snaps += localComposers(handle)
        snaps.sort { $0.changed > $1.changed }
        return snaps
    }

    private nonisolated static func cloudAgents(_ db: OpaquePointer) -> [Snapshot] {
        let rows = query(db, "SELECT value FROM ItemTable WHERE key LIKE 'cloudAgentRepository.agents.%'")
        let cutoff = Date().addingTimeInterval(-activeWindow)
        var out: [Snapshot] = []
        for row in rows {
            guard let data = row.first?.data(using: .utf8),
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
            for a in list {
                if a["isArchived"] as? Bool == true { continue }
                let updated = msDate(a["updatedAt"]) ?? .distantPast
                guard updated > cutoff else { continue }
                let name = a["name"] as? String ?? ""
                let bcId = a["bcId"] as? String ?? name
                var state: ClaudeSession.State = .idle
                var detail = ""
                if a["isKilled"] as? Bool == true {
                    state = .error
                    detail = "killed"
                } else if Date().timeIntervalSince(updated) < busyWindow {
                    state = .busy
                } else if a["isUnread"] as? Bool == true,
                          Date().timeIntervalSince(updated) < unseenWindow {
                    state = .unseen
                }
                // The VM's workspaceRootPath is a generic "/workspace" — the
                // repo name is the meaningful project identity.
                var cwd = (a["repoUrl"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
                if cwd.isEmpty { cwd = a["workspaceRootPath"] as? String ?? "" }
                if detail.isEmpty, let branch = a["branchName"] as? String, !branch.isEmpty {
                    detail = "cloud · \(branch)"
                }
                out.append(Snapshot(id: "cursor-cloud-\(bcId)", cwd: cwd, title: name,
                                    state: state, detail: detail,
                                    started: msDate(a["createdAt"]) ?? updated, changed: updated))
            }
        }
        return out
    }

    private nonisolated static func localComposers(_ db: OpaquePointer) -> [Snapshot] {
        let rows = query(db, """
            SELECT composerId, IFNULL(createdAt,0), IFNULL(lastUpdatedAt,0), value FROM composerHeaders \
            WHERE isArchived = 0 AND IFNULL(isSubagent,0) = 0
            """)
        let cutoff = Date().addingTimeInterval(-activeWindow)
        var out: [Snapshot] = []
        for row in rows {
            guard row.count >= 4, let data = row[3].data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if o["isDraft"] as? Bool == true { continue }
            guard let name = o["name"] as? String, !name.isEmpty else { continue }
            let updated = Date(timeIntervalSince1970: (Double(row[2]) ?? 0) / 1000)
            guard updated > cutoff else { continue }
            var state: ClaudeSession.State = .idle
            var detail = ""
            if o["hasBlockingPendingActions"] as? Bool == true {
                state = .needsInput
                detail = "waiting for you — in Cursor"
            } else if Date().timeIntervalSince(updated) < 20 {
                state = .busy
            } else if o["hasUnreadMessages"] as? Bool == true {
                state = .unseen
            }
            let created = Date(timeIntervalSince1970: (Double(row[1]) ?? 0) / 1000)
            out.append(Snapshot(id: "cursor-\(row[0])", cwd: "", title: name,
                                state: state, detail: detail,
                                started: created, changed: updated))
        }
        return out
    }

    /// Timestamps arrive as ms since epoch, sometimes numeric, sometimes string.
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

    /// Tiny text-only query helper — every value read via column_text.
    private nonisolated static func query(_ db: OpaquePointer, _ sql: String) -> [[String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String] = []
            for i in 0..<sqlite3_column_count(stmt) {
                row.append(sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "")
            }
            out.append(row)
        }
        return out
    }
}
