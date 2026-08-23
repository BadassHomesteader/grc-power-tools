import Foundation

/// Provider quota for the Agent Pad header — "have I got runway to start this?"
///
/// Numbers come from the CodexBar CLI, read as a black box behind its
/// documented `dashboard-v1` JSON contract. Nothing here links CodexBar's code
/// or knows how any provider is authenticated; swapping it for a native reader
/// later means replacing `fetch()` alone.
///
/// This is opt-in by absence: with no `codexbar` on disk the pad behaves exactly
/// as it did before, and the header button never appears.
@MainActor
final class UsageReader {
    struct Window {
        let label: String
        let usedPercent: Int
        let resetAt: Date?
    }

    struct Provider {
        let id: String
        let name: String
        let plan: String
        let windows: [Window]
        let error: String
    }

    static let shared = UsageReader()

    /// Last good snapshot. Held across failures so one bad read doesn't blank
    /// the menu — the same "stale states stay honest" contract the pad's rows
    /// use, which is why `fetchedAt` is exposed rather than hidden.
    private(set) var providers: [Provider] = []
    private(set) var fetchedAt: Date?

    /// A read spawns a throwaway Claude session to scrape `/usage` and takes
    /// ~45s, so it runs rarely. The windows it reports are 5-hour and 7-day;
    /// nothing about them moves fast enough to justify paying that more often.
    private let interval: TimeInterval = 900
    private var inFlight = false

    /// Fired when a fetch lands, so an open menu can be rebuilt.
    var onUpdate: (() -> Void)?

    /// Where the CLI lives. Checked on every access rather than cached: the
    /// pad should start showing quota after an install without a relaunch.
    static var binaryPath: String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/codexbar",
            "/opt/homebrew/bin/codexbar",
            "/usr/local/bin/codexbar",
            "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { self.binaryPath != nil }

    /// Kick a refresh if the cached snapshot has aged out. Safe to call on
    /// every pad render — it self-throttles and never blocks the caller.
    func refreshIfStale() {
        guard !self.inFlight, let path = Self.binaryPath else { return }
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < self.interval { return }
        self.inFlight = true
        Task.detached(priority: .utility) {
            let rows = Self.fetch(path: path)
            await MainActor.run {
                self.inFlight = false
                // A failed read keeps the previous numbers but still stamps the
                // clock, so a dead reader backs off instead of retrying on
                // every render.
                if let rows {
                    self.providers = rows
                }
                self.fetchedAt = Date()
                self.onUpdate?()
            }
        }
    }

    /// "4m ago" for the menu header — quota is polled, not live, and saying so
    /// is cheaper than someone trusting a stale number.
    var ageDescription: String {
        guard let fetchedAt else { return "" }
        let mins = Int(Date().timeIntervalSince(fetchedAt) / 60)
        if mins < 1 { return "just now" }
        if mins < 60 { return "\(mins)m ago" }
        return "\(mins / 60)h ago"
    }

    // ------------------------------------------------------------- fetching

    /// Returns nil on any failure; the caller keeps its last good snapshot.
    private nonisolated static func fetch(path: String) -> [Provider]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["dashboard", "--identity", "redacted", "--timeout", "120"]
        // CodexBar locates the Claude CLI through a login shell, and decides
        // Claude is unavailable outright when USER is missing — it then reports
        // an unrelated browser-cookie error, so the cause is invisible. Neither
        // is load-bearing when launched from the app, but both keep a leaner
        // launch context from silently dropping the one provider that matters.
        var env = ProcessInfo.processInfo.environment
        env["USER"] = env["USER"] ?? NSUserName()
        if let claude = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                         "\(NSHomeDirectory())/.local/bin/claude"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        {
            env["CLAUDE_CLI_PATH"] = claude
        }
        p.environment = env

        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 || !data.isEmpty else { return nil }
        return self.parse(data)
    }

    /// Only the fields the header needs. Provider-specific window kinds
    /// (`codex-spark`, `claude-weekly-scoped-fable`, …) are deliberately left
    /// out: that vocabulary grows with every provider CodexBar adds, and the
    /// pad has room for the two windows people actually plan around.
    private nonisolated static func parse(_ data: Data) -> [Provider]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schemaVersion"] as? Int == 1,
              let rows = root["providers"] as? [[String: Any]]
        else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var out: [Provider] = []
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            if row["enabled"] as? Bool == false { continue }

            var windows: [Window] = []
            for w in (row["windows"] as? [[String: Any]] ?? []) {
                guard let kind = w["kind"] as? String,
                      ["session", "weekly", "monthly"].contains(kind),
                      let used = w["usedPercent"] as? NSNumber
                else { continue }
                let resetString = w["resetAt"] as? String ?? ""
                windows.append(Window(
                    label: (w["label"] as? String) ?? kind,
                    usedPercent: max(0, min(100, used.intValue)),
                    resetAt: iso.date(from: resetString) ?? isoPlain.date(from: resetString)))
            }

            let error = ((row["error"] as? [String: Any])?["message"] as? String) ?? ""
            if windows.isEmpty, error.isEmpty { continue }

            out.append(Provider(
                id: id,
                name: (row["name"] as? String) ?? id,
                plan: ((row["identity"] as? [String: Any])?["plan"] as? String) ?? "",
                windows: windows,
                error: error))
        }
        return out
    }
}

extension UsageReader.Window {
    /// "resets in 2h 14m" — the number you actually plan around.
    var resetDescription: String {
        guard let resetAt else { return "" }
        let secs = resetAt.timeIntervalSinceNow
        if secs <= 0 { return "resetting" }
        let mins = Int(secs / 60)
        if mins < 60 { return "resets in \(mins)m" }
        let hrs = mins / 60
        if hrs < 24 {
            let rem = mins % 60
            return rem > 0 ? "resets in \(hrs)h \(rem)m" : "resets in \(hrs)h"
        }
        let days = hrs / 24
        let remH = hrs % 24
        return remH > 0 ? "resets in \(days)d \(remH)h" : "resets in \(days)d"
    }
}
