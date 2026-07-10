import Foundation

/// API-key store. Backed by an owner-only (0600) file in the app's data folder
/// rather than the macOS Keychain — the Keychain re-prompts for the login
/// password on every reinstall (its per-app ACL doesn't follow a rebuilt binary),
/// which is far more annoying than valuable for a local personal app. The file
/// is readable only by your account.
enum Keychain {
    private static var file: URL {
        Config.appSupportDir.appendingPathComponent("keys.json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }  // no file yet
        guard let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            // Corrupt keys file: don't silently report "never configured" — move
            // it aside for recovery and log loudly, so lost keys are explainable.
            let aside = file.deletingLastPathComponent().appendingPathComponent("keys.json.corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
            NSLog("PowerTools: keys.json was unreadable — moved to keys.json.corrupt; re-enter API keys in Settings")
            return [:]
        }
        return dict
    }

    private static func store(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        // Atomic replace (write-to-temp + rename) — no truncate-then-write window
        // that a mid-write kill can turn into a 0-byte file. Then owner-only perms.
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func set(_ value: String, account: String) {
        var dict = load()
        if value.isEmpty { dict[account] = nil } else { dict[account] = value }
        store(dict)
    }

    static func get(_ account: String) -> String? { load()[account] }

    static func has(_ account: String) -> Bool { (get(account)?.isEmpty == false) }
}
