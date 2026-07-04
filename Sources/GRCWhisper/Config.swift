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
        case apple    // Apple FoundationModels (on-device)
        case claude   // Claude API (cloud, opt-in)
        case openai   // OpenAI API (cloud, opt-in)
        case basic    // deterministic dictionary + filler strip only
        case off      // raw transcript

        var displayName: String {
            switch self {
            case .apple: return "AI polish (on-device)"
            case .claude: return "Claude (cloud)"
            case .openai: return "OpenAI (cloud)"
            case .basic: return "Basic cleanup"
            case .off: return "Raw transcript"
            }
        }

        var isCloud: Bool { self == .claude || self == .openai }

        // Legacy config had "llm" for the on-device engine; map it to .apple so
        // an existing config.json doesn't fail to decode and reset every setting.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "llm", "apple": self = .apple
            case "claude": self = .claude
            case "openai": self = .openai
            case "basic": self = .basic
            default: self = .off
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
    }

    var hotkey: Hotkey = .fn
    var polish: PolishMode = .apple
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
    /// Cloud cleanup model IDs (used only when polish is .claude / .openai).
    var claudeModel: String = "claude-haiku-4-5"
    var openaiModel: String = "gpt-4o-mini"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case hotkey, polish, localeIdentifier, llmDeadlineMs, clipboardRestoreDelayMs
        case minHoldMs, maxUtteranceSeconds, preRollSeconds, claudeModel, openaiModel
    }

    // Lenient decode: any missing key falls back to its default, so adding new
    // settings never invalidates an older config file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? .fn
        polish = try c.decodeIfPresent(PolishMode.self, forKey: .polish) ?? .apple
        localeIdentifier = try c.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? "en_US"
        llmDeadlineMs = try c.decodeIfPresent(Int.self, forKey: .llmDeadlineMs) ?? 2500
        clipboardRestoreDelayMs = try c.decodeIfPresent(Int.self, forKey: .clipboardRestoreDelayMs) ?? 600
        minHoldMs = try c.decodeIfPresent(Int.self, forKey: .minHoldMs) ?? 250
        maxUtteranceSeconds = try c.decodeIfPresent(Int.self, forKey: .maxUtteranceSeconds) ?? 120
        preRollSeconds = try c.decodeIfPresent(Double.self, forKey: .preRollSeconds) ?? 1.0
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? "claude-haiku-4-5"
        openaiModel = try c.decodeIfPresent(String.self, forKey: .openaiModel) ?? "gpt-4o-mini"
    }

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
