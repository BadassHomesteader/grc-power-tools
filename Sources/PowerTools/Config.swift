import Foundation

/// All user-tunable settings, persisted as JSON in Application Support.
struct Config: Codable {
    enum Hotkey: String, Codable, CaseIterable {
        case fn            // hold Globe/Fn (needs "Press 🌐 → Do Nothing" in Keyboard settings)
        case rightOption
        case rightCommand
        case ctrlOption    // hold Control+Option together (external keyboards)
        case shiftCommand  // hold Shift+Command together
        case optionShift   // hold Option+Shift together — DEFAULT: ambidextrous, low-collision, any keyboard

        var displayName: String {
            switch self {
            case .fn: return "Fn / Globe"
            case .rightOption: return "Right Option"
            case .rightCommand: return "Right Command"
            case .ctrlOption: return "Control + Option"
            case .shiftCommand: return "Shift + Command"
            case .optionShift: return "Option + Shift"
            }
        }

        // Lenient decode so an unknown/legacy value can never throw (which would
        // wipe the whole config on load).
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Hotkey(rawValue: raw) ?? .optionShift
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer(); try c.encode(rawValue)
        }
    }

    enum OverlayPosition: String, Codable, CaseIterable {
        case bottomCenter, bottomLeft, bottomRight
        case center
        case topCenter, topLeft, topRight

        var displayName: String {
            switch self {
            case .bottomCenter: return "Bottom center"
            case .bottomLeft: return "Bottom left"
            case .bottomRight: return "Bottom right"
            case .center: return "Center"
            case .topCenter: return "Top center"
            case .topLeft: return "Top left"
            case .topRight: return "Top right"
            }
        }
    }

    enum Appearance: String, Codable, CaseIterable {
        case dark, light
        var displayName: String { self == .dark ? "Dark" : "Lite" }
        var isDark: Bool { self == .dark }
    }

    /// The set of sizes a window snap cycles through on repeated arrow taps.
    /// Bigger monitors benefit from smaller fractions (¼, ⅕).
    enum SnapSizes: String, Codable, CaseIterable {
        case thirds          // ½ ⅓ ⅔
        case quarters        // ½ ¼ ¾
        case thirdsQuarters  // ½ ⅓ ⅔ ¼ ¾
        case fifths          // ½ ⅕ ⅘

        var displayName: String {
            switch self {
            case .thirds:         return "½ · ⅓ · ⅔"
            case .quarters:       return "½ · ¼ · ¾"
            case .thirdsQuarters: return "½ · ⅓ · ⅔ · ¼ · ¾"
            case .fifths:         return "½ · ⅕ · ⅘  (big screens)"
            }
        }

        // Each preset pairs a small fraction with its large complement, so a repeat
        // tap can also make the window the BIG side of the split (⅓↔⅔, ¼↔¾, ⅕↔⅘).
        var steps: [(fraction: CGFloat, label: String)] {
            let third: CGFloat = 1.0 / 3.0
            let twoThird: CGFloat = 2.0 / 3.0
            switch self {
            case .thirds:         return [(0.5, "½"), (third, "⅓"), (twoThird, "⅔")]
            case .quarters:       return [(0.5, "½"), (0.25, "¼"), (0.75, "¾")]
            case .thirdsQuarters: return [(0.5, "½"), (third, "⅓"), (twoThird, "⅔"), (0.25, "¼"), (0.75, "¾")]
            case .fifths:         return [(0.5, "½"), (0.2, "⅕"), (0.8, "⅘")]
            }
        }

        // Legacy raw values (halvesThirds…) or anything unknown fall back to .thirds
        // instead of throwing (which would wipe the whole config on load).
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = SnapSizes(rawValue: raw) ?? .thirds
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
    }

    /// Columns × rows of the draw-a-grid window placement overlay.
    enum GridSize: String, Codable, CaseIterable {
        case c6x4, c8x6, c12x8, c16x10, c24x16

        var cols: Int { switch self { case .c6x4: return 6; case .c8x6: return 8; case .c12x8: return 12; case .c16x10: return 16; case .c24x16: return 24 } }
        var rows: Int { switch self { case .c6x4: return 4; case .c8x6: return 6; case .c12x8: return 8; case .c16x10: return 10; case .c24x16: return 16 } }
        var displayName: String { "\(cols) × \(rows)" }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = GridSize(rawValue: raw) ?? .c12x8
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer(); try c.encode(rawValue)
        }
    }

    /// What the AI leader (hold + A) does with your dictated words.
    enum AIChatMode: String, Codable, CaseIterable {
        case both     // in-app chat, with an "Open in claude.ai" button
        case native   // in-app chat only
        case browser  // open claude.ai in the browser instead

        var displayName: String {
            switch self {
            case .both: return "In-app + browser"
            case .native: return "In-app chat only"
            case .browser: return "Browser (claude.ai)"
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

    /// A Quick Capture "connection": hold the hotkey + `leaderKey` opens a capture
    /// panel that POSTs to `endpoint`. Each has its own token (Keychain account
    /// `capture:<id>`). Nothing app-specific — a connection can point anywhere.
    struct Connection: Codable {
        var id: String
        var name: String
        var leaderKey: String   // single letter, e.g. "N"; case-insensitive
        var endpoint: String
        var authHeader: String
        var bodyTemplate: String

        var tokenAccount: String { "capture:\(id)" }

        init(id: String, name: String, leaderKey: String, endpoint: String,
             authHeader: String = "X-Api-Key", bodyTemplate: String = "{\"title\":\"%TEXT%\"}") {
            self.id = id; self.name = name; self.leaderKey = leaderKey.uppercased()
            self.endpoint = endpoint; self.authHeader = authHeader; self.bodyTemplate = bodyTemplate
        }

        private enum CodingKeys: String, CodingKey { case id, name, leaderKey, endpoint, authHeader, bodyTemplate }

        // Lenient: a partial/legacy element decodes with defaults instead of throwing.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Connection"
            leaderKey = (try c.decodeIfPresent(String.self, forKey: .leaderKey) ?? "").uppercased()
            endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
            authHeader = try c.decodeIfPresent(String.self, forKey: .authHeader) ?? "X-Api-Key"
            bodyTemplate = try c.decodeIfPresent(String.self, forKey: .bodyTemplate) ?? "{\"title\":\"%TEXT%\"}"
        }
    }

    /// Quick Capture connections. Each has its own hotkey leader letter.
    var connections: [Connection] = []

    var hotkey: Hotkey = .optionShift
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
    /// Where the dictation bar appears.
    var overlayPosition: OverlayPosition = .bottomCenter
    /// Light or dark theme for the overlay, settings, and chat windows.
    var appearance: Appearance = .dark
    /// What hold + A does: in-app chat, browser, or both.
    var aiChatMode: AIChatMode = .both
    /// Sizes window snaps cycle through on repeated arrow taps.
    var snapSizes: SnapSizes = .thirds
    /// Columns × rows of the draw-a-grid overlay.
    var gridSize: GridSize = .c12x8
    /// After snapping a window to a side, offer the other windows to fill the gap.
    var snapAssist: Bool = true
    /// Moom-style snap palette on hold + W.
    var windowPalette: Bool = true
    /// Record text/image copies; hold + H opens the recent-clips palette (Win+V).
    var clipboardHistory: Bool = true
    /// ⌘Tab works like Windows Alt-Tab: window-level MRU switching across apps
    /// (replaces the macOS app switcher; ⇧⌘Tab walks backwards). ⌘` untouched.
    var lastWindowSwitch: Bool = true
    /// Mute the speakers while the dictation key is held, so a call or music
    /// playing through them can't bleed into the transcript. Restored on release.
    var muteWhileDictating: Bool = true
    /// Plain ⏎ in Finder opens the selection (Windows-style) instead of
    /// renaming. Return still types normally in rename/search fields.
    var finderEnterOpens: Bool = true
    /// Windows-style keys — each independently toggleable.
    var keyHomeEnd: Bool = true          // Home/End = line start/end in text fields
    var finderBackspaceUp: Bool = true   // Finder Backspace = up a folder
    var finderDeleteTrash: Bool = true   // Finder Delete (⌦) = Move to Trash
    var taskManagerShortcut: Bool = true // ⌃⇧⎋ = Activity Monitor

    /// Quick Capture (hold hotkey + N): POST a typed/dictated line to any HTTP
    /// endpoint — a personal todo app, an n8n webhook, etc. Nothing app-specific
    /// ships here; the endpoint/header/body are all user config and the token
    /// lives in Keychain under "capture". An empty endpoint disables the feature.
    var captureEndpoint: String = ""
    /// Auth header name sent with the capture POST (empty = send no auth header).
    var captureAuthHeader: String = "X-Api-Key"
    /// JSON body template; `%TEXT%` is replaced with the JSON-escaped capture text.
    var captureBodyTemplate: String = "{\"title\":\"%TEXT%\"}"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case hotkey, polish, localeIdentifier, llmDeadlineMs, clipboardRestoreDelayMs
        case minHoldMs, maxUtteranceSeconds, preRollSeconds, claudeModel, openaiModel
        case overlayPosition, appearance, aiChatMode, snapSizes, gridSize, snapAssist
        case windowPalette, clipboardHistory, lastWindowSwitch, muteWhileDictating, finderEnterOpens
        case keyHomeEnd, finderBackspaceUp, finderDeleteTrash, taskManagerShortcut
        case captureEndpoint, captureAuthHeader, captureBodyTemplate
        case connections
    }

    // Lenient decode: any missing key falls back to its default, so adding new
    // settings never invalidates an older config file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? .optionShift
        polish = try c.decodeIfPresent(PolishMode.self, forKey: .polish) ?? .apple
        localeIdentifier = try c.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? "en_US"
        llmDeadlineMs = try c.decodeIfPresent(Int.self, forKey: .llmDeadlineMs) ?? 2500
        clipboardRestoreDelayMs = try c.decodeIfPresent(Int.self, forKey: .clipboardRestoreDelayMs) ?? 600
        minHoldMs = try c.decodeIfPresent(Int.self, forKey: .minHoldMs) ?? 250
        maxUtteranceSeconds = try c.decodeIfPresent(Int.self, forKey: .maxUtteranceSeconds) ?? 120
        preRollSeconds = try c.decodeIfPresent(Double.self, forKey: .preRollSeconds) ?? 1.0
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? "claude-haiku-4-5"
        openaiModel = try c.decodeIfPresent(String.self, forKey: .openaiModel) ?? "gpt-4o-mini"
        overlayPosition = try c.decodeIfPresent(OverlayPosition.self, forKey: .overlayPosition) ?? .bottomCenter
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .dark
        aiChatMode = try c.decodeIfPresent(AIChatMode.self, forKey: .aiChatMode) ?? .both
        snapSizes = try c.decodeIfPresent(SnapSizes.self, forKey: .snapSizes) ?? .thirds
        snapAssist = try c.decodeIfPresent(Bool.self, forKey: .snapAssist) ?? true
        gridSize = try c.decodeIfPresent(GridSize.self, forKey: .gridSize) ?? .c12x8
        windowPalette = try c.decodeIfPresent(Bool.self, forKey: .windowPalette) ?? true
        clipboardHistory = try c.decodeIfPresent(Bool.self, forKey: .clipboardHistory) ?? true
        lastWindowSwitch = try c.decodeIfPresent(Bool.self, forKey: .lastWindowSwitch) ?? true
        muteWhileDictating = try c.decodeIfPresent(Bool.self, forKey: .muteWhileDictating) ?? true
        finderEnterOpens = try c.decodeIfPresent(Bool.self, forKey: .finderEnterOpens) ?? true
        // Migration: the old combined `windowsKeys` flag (read from a separate
        // container so it needn't be a CodingKey the synthesized encoder must
        // satisfy) seeds all four if the granular keys aren't present yet.
        enum LegacyKeys: String, CodingKey { case windowsKeys }
        let legacyWinKeys = try decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(Bool.self, forKey: .windowsKeys)
        keyHomeEnd = try c.decodeIfPresent(Bool.self, forKey: .keyHomeEnd) ?? legacyWinKeys ?? true
        finderBackspaceUp = try c.decodeIfPresent(Bool.self, forKey: .finderBackspaceUp) ?? legacyWinKeys ?? true
        finderDeleteTrash = try c.decodeIfPresent(Bool.self, forKey: .finderDeleteTrash) ?? legacyWinKeys ?? true
        taskManagerShortcut = try c.decodeIfPresent(Bool.self, forKey: .taskManagerShortcut) ?? legacyWinKeys ?? true
        captureEndpoint = try c.decodeIfPresent(String.self, forKey: .captureEndpoint) ?? ""
        captureAuthHeader = try c.decodeIfPresent(String.self, forKey: .captureAuthHeader) ?? "X-Api-Key"
        captureBodyTemplate = try c.decodeIfPresent(String.self, forKey: .captureBodyTemplate) ?? "{\"title\":\"%TEXT%\"}"
        // try? so a malformed element can never wipe the whole config on load.
        connections = (try? c.decodeIfPresent([Connection].self, forKey: .connections)) ?? []
    }

    /// One-time migration: fold the pre-multi-connection single fields into
    /// connections[]. Returns true if anything changed (so the caller persists).
    mutating func migrateLegacyCapture() -> Bool {
        guard connections.isEmpty, !captureEndpoint.isEmpty else { return false }
        let conn = Connection(id: "default", name: "Todo", leaderKey: "N",
                              endpoint: captureEndpoint, authHeader: captureAuthHeader,
                              bodyTemplate: captureBodyTemplate)
        connections = [conn]
        // Move the token from the legacy account to the per-connection one.
        if let tok = Keychain.get("capture"), Keychain.get(conn.tokenAccount) == nil {
            Keychain.set(tok, account: conn.tokenAccount)
        }
        captureEndpoint = ""   // consumed; connections[] is now the source of truth
        return true
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
              var cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            let cfg = Config()
            cfg.save()
            return cfg
        }
        if cfg.migrateLegacyCapture() { cfg.save() }
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
