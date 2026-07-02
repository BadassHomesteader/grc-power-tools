import Foundation

/// All user-tunable settings, persisted as JSON in Application Support.
struct Config: Codable {
    enum Hotkey: String, Codable, CaseIterable {
        case fn            // hold Globe/Fn (default, Wispr parity)
        case rightOption
        case rightCommand
        case ctrlOption    // hold Control+Option together (external keyboards)

        var displayName: String {
            switch self {
            case .fn: return "Fn / Globe"
            case .rightOption: return "Right Option"
            case .rightCommand: return "Right Command"
            case .ctrlOption: return "Control + Option"
            }
        }
    }

    enum PolishMode: String, Codable, CaseIterable {
        case llm    // Tier 0 + on-device FoundationModels cleanup
        case basic  // Tier 0 only (dictionary + filler strip)
        case off    // raw transcript

        var displayName: String {
            switch self {
            case .llm: return "AI polish (on-device)"
            case .basic: return "Basic cleanup"
            case .off: return "Raw transcript"
            }
        }
    }

    var hotkey: Hotkey = .fn
    var polish: PolishMode = .llm
    var localeIdentifier: String = "en_US"
    /// Soft deadline for the LLM polish pass; on expiry we fall back to Tier-0 text.
    var llmDeadlineMs: Int = 2500
    /// Delay before restoring the user's clipboard after paste.
    var clipboardRestoreDelayMs: Int = 600
    /// Ignore taps shorter than this (accidental Fn presses).
    var minHoldMs: Int = 250
    /// Hard cap per utterance.
    var maxUtteranceSeconds: Int = 120
    /// Seconds of audio kept warm before the key goes down (protects first syllable).
    var preRollSeconds: Double = 1.0

    static var appSupportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GRC Whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var configURL: URL { appSupportDir.appendingPathComponent("config.json") }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            let cfg = Config()
            cfg.save()
            return cfg
        }
        return cfg
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Config.configURL)
        }
    }
}
