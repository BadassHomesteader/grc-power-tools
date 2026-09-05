import Foundation
import CoreGraphics

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

    /// Modifier combo for Grab & Move (hold + drag anywhere on a window).
    /// ⇧-combos are deliberately absent: ⇧-click is select-range everywhere.
    enum GrabModifiers: String, Codable, CaseIterable {
        case ctrlCmd     // ⌃⌘ — DEFAULT (Easy Move+Resize convention, no system gesture)
        case optCmd      // ⌥⌘
        case ctrlOpt     // ⌃⌥ (collides if the main hotkey is Control+Option)
        case ctrlOptCmd  // ⌃⌥⌘

        var displayName: String {
            switch self {
            case .ctrlCmd: return "⌃⌘  Control + Command"
            case .optCmd: return "⌥⌘  Option + Command"
            case .ctrlOpt: return "⌃⌥  Control + Option"
            case .ctrlOptCmd: return "⌃⌥⌘  Control + Option + Command"
            }
        }

        /// Short glyph form for help text ("hold ⌃⌘ and drag").
        var glyphs: String {
            switch self {
            case .ctrlCmd: return "⌃⌘"
            case .optCmd: return "⌥⌘"
            case .ctrlOpt: return "⌃⌥"
            case .ctrlOptCmd: return "⌃⌥⌘"
            }
        }

        var flags: CGEventFlags {
            switch self {
            case .ctrlCmd: return [.maskControl, .maskCommand]
            case .optCmd: return [.maskAlternate, .maskCommand]
            case .ctrlOpt: return [.maskControl, .maskAlternate]
            case .ctrlOptCmd: return [.maskControl, .maskAlternate, .maskCommand]
            }
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = GrabModifiers(rawValue: raw) ?? .ctrlCmd
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

    /// Which speech engine transcribes dictation. Parakeet (FluidAudio) trades
    /// Apple's zero-setup on-device engine for faster local ASR; models download
    /// from HuggingFace on first use.
    enum ASREngine: String, Codable, CaseIterable {
        case apple      // Apple SpeechAnalyzer (on-device, no download)
        case parakeet   // FluidAudio Parakeet TDT (on-device, downloads models on first use)

        var displayName: String {
            switch self {
            case .apple: return "Apple (built-in)"
            case .parakeet: return "Parakeet (faster, downloads on first use)"
            }
        }

        // Lenient decode, matching every other enum here: unknown/legacy values
        // fall back to the default instead of failing the whole config load.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = ASREngine(rawValue: raw) ?? .apple
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer(); try c.encode(rawValue)
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

    /// One Macro Pad button: an "open" step — either a keystroke chord
    /// ("cmd+shift+m") OR, when the target app has no shortcut for the action
    /// (New Outlook dropped Move's), a `menuPath` ("Message,Move") clicked via
    /// the Accessibility API — then optional literal text typed into whatever
    /// that opened, then an optional Return. `keywords` (comma-separated)
    /// light the button up as a suggestion when they appear in the target
    /// window's reading pane.
    struct MacroButton: Codable {
        /// The menu path the Outlook folder buttons ride (Message ▸ Move) —
        /// shared by the pad (Favorites column, Move search) and Settings.
        static let moveMenuPath = "Message,Move"

        var title: String
        var chord: String
        var text: String
        var pressReturn: Bool
        var keywords: String
        var menuPath: String
        /// Column on the pad. Blank = automatic: folder-move buttons →
        /// "Favorites", everything else → "Actions". Any other name makes
        /// its own column.
        var group: String

        init(title: String, chord: String = "", text: String = "",
             pressReturn: Bool = false, keywords: String = "", menuPath: String = "", group: String = "") {
            self.title = title; self.chord = chord; self.text = text
            self.pressReturn = pressReturn; self.keywords = keywords; self.menuPath = menuPath
            self.group = group
        }

        private enum CodingKeys: String, CodingKey { case title, chord, text, pressReturn, keywords, menuPath, group }

        // Lenient: a partial/legacy element decodes with defaults instead of throwing.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            chord = try c.decodeIfPresent(String.self, forKey: .chord) ?? ""
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            pressReturn = try c.decodeIfPresent(Bool.self, forKey: .pressReturn) ?? false
            keywords = try c.decodeIfPresent(String.self, forKey: .keywords) ?? ""
            menuPath = try c.decodeIfPresent(String.self, forKey: .menuPath) ?? ""
            group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        }
    }

    /// Macro Pad profile: the buttons shown while `bundleID` is frontmost.
    struct MacroProfile: Codable {
        var bundleID: String
        var name: String
        var buttons: [MacroButton]

        init(bundleID: String, name: String, buttons: [MacroButton]) {
            self.bundleID = bundleID; self.name = name; self.buttons = buttons
        }

        private enum CodingKeys: String, CodingKey { case bundleID, name, buttons }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? ""
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "App"
            buttons = try c.decodeIfPresent([MacroButton].self, forKey: .buttons) ?? []
        }
    }

    /// Macro Pad (hold hotkey + B): floating per-app button panel.
    var macroPad: Bool = true
    var macroPadProfiles: [MacroProfile] = []
    /// Pause between macro steps (chord → text → Return) — the Outlook Move
    /// dialog needs a beat to open and to filter before Return commits.
    var macroPadStepDelayMs: Int = 350
    /// Hold hotkey + a trackpad tap summons the pad beside the cursor (rides the
    /// private MultitouchSupport framework; silently off when unavailable).
    var macroPadThreeFingerTap: Bool = true
    /// How many fingers the summon tap needs — 3 or 4.
    var macroPadSummonFingers: Int = 3

    /// Agent Pad (hold hotkey + J): floating Claude Code session panel fed by
    /// hooks POSTing to a loopback server. Port changes need an app relaunch
    /// AND a hook re-install (the port is baked into the settings.json entries).
    var agentPad: Bool = true
    var agentPadPort: Int = 8377
    /// Show Codex (ChatGPT app) threads as watch-only rows.
    var agentPadCodex: Bool = true
    /// Show Cursor sessions (cloud agents + Agents Window) as watch-only rows.
    var agentPadCursor: Bool = true
    /// Show Grok Bot (Anysphere Sand) bots as watch-only rows.
    var agentPadGrok: Bool = true
    /// Reopen pads that were open when the app last quit (updates included).
    var restorePads: Bool = true

    /// The notch strip — the one surface allowed to live in the camera housing.
    /// On by default is safe because it draws NOTHING when no source has
    /// anything to say (no sessions, quota quiet ⇒ no pixels at all).
    var notchStrip: Bool = true
    var notchAgents: Bool = true
    /// Off by default: quota would otherwise be a dot permanently parked in the
    /// menu bar. On, it still only appears once a window passes `notchQuotaAt`.
    var notchQuota: Bool = false
    var notchQuotaAt: Int = 60
    /// One-shot guard for moving pads off the retired notch berths, so the
    /// migration can never re-enable a source the user later switched off.
    var notchStripMigrated: Bool = false

    /// Whether Power Tools' floating surfaces appear in screenshots, screen
    /// recordings and screen sharing. ON by default — hiding things from a
    /// capture without being asked would be its own surprise — but the notch
    /// strip is permanent, so this is the switch that keeps it out of demos
    /// and client calls. See CaptureVisibility.
    var showInCaptures: Bool = true

    /// Notch modules — panels the notch hosts, as opposed to sources that
    /// publish into it. Each can be switched off; the ⋯ mark disappears when
    /// none are on.
    var notchModules: [String] = ["usage", "hotkeys", "snap", "clock", "calendar", "weather", "chat"]
    /// World clock zones, IANA identifiers.
    var notchClockZones: [String] = ["America/New_York", "Europe/London", "Asia/Tokyo"]
    /// Weather: places typed in Settings, each geocoded once to a lat/lon so
    /// the module needs no location permission and no API key. Several are
    /// allowed — the module stacks them.
    struct WeatherPlace: Codable, Equatable {
        var name: String
        var lat: Double
        var lon: Double
    }
    var weatherPlaces: [WeatherPlace] = []
    /// Legacy single-place fields, kept so an older config still loads; folded
    /// into `weatherPlaces` in `init(from:)` and no longer read anywhere else.
    var weatherPlace: String = ""
    var weatherLat: Double = 0
    var weatherLon: Double = 0
    var weatherFahrenheit: Bool = true
    /// Power Ring: hold hotkey + right-click → radial menu. Slots are catalog
    /// ids, clockwise from the top (see PowerRingCatalog).
    var powerRing: Bool = true
    var powerRingSlots: [String] = PowerRingCatalog.defaultSlots
    /// Annotation whiteboard: hold hotkey + E → draw on the clipboard image
    /// (or a fresh region grab when the clipboard has no image).
    var whiteboard: Bool = true

    var hotkey: Hotkey = .optionShift
    var polish: PolishMode = .apple
    var asrEngine: ASREngine = .apple
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
    /// Grab & Move: hold `grabMoveModifiers` + left-drag anywhere on a window to
    /// move it (AltDrag / Easy Move+Resize style).
    var grabAndMove: Bool = true
    var grabMoveModifiers: GrabModifiers = .ctrlCmd
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

    /// Read Aloud (hold + R) pronunciation fixes: word → phonetic respelling,
    /// e.g. {"Juergs": "Yergs", "KYAW": "K Y A W"}. Matched case-insensitively
    /// on word boundaries; only the spoken text changes, never the OCR copy.
    /// Hand-edits to config.json load on the next app launch.
    var pronunciations: [String: String] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case hotkey, polish, asrEngine, localeIdentifier, llmDeadlineMs, clipboardRestoreDelayMs
        case minHoldMs, maxUtteranceSeconds, preRollSeconds, claudeModel, openaiModel
        case overlayPosition, appearance, aiChatMode, snapSizes, gridSize, snapAssist
        case windowPalette, clipboardHistory, lastWindowSwitch, muteWhileDictating, finderEnterOpens
        case grabAndMove, grabMoveModifiers
        case keyHomeEnd, finderBackspaceUp, finderDeleteTrash, taskManagerShortcut
        case captureEndpoint, captureAuthHeader, captureBodyTemplate
        case connections
        case macroPad, macroPadProfiles, macroPadStepDelayMs, macroPadThreeFingerTap, macroPadSummonFingers
        case agentPad, agentPadPort, agentPadCodex, agentPadCursor, agentPadGrok, restorePads
        case notchStrip, notchAgents, notchQuota, notchQuotaAt, notchStripMigrated
        case showInCaptures
        case notchModules, notchClockZones, weatherPlaces, weatherPlace, weatherLat, weatherLon, weatherFahrenheit
        case powerRing, powerRingSlots
        case whiteboard
        case pronunciations
    }

    // Lenient decode: any missing OR type-mismatched value falls back to its
    // default, so adding new settings — or one hand-edited bad value — never
    // invalidates the rest of the config file. (A throwing field here used to
    // make load() fail wholesale and save defaults over the file.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys, _ def: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? def
        }
        hotkey = field(.hotkey, .optionShift)
        polish = field(.polish, .apple)
        asrEngine = field(.asrEngine, .apple)
        localeIdentifier = field(.localeIdentifier, "en_US")
        llmDeadlineMs = field(.llmDeadlineMs, 2500)
        clipboardRestoreDelayMs = field(.clipboardRestoreDelayMs, 600)
        minHoldMs = field(.minHoldMs, 250)
        maxUtteranceSeconds = field(.maxUtteranceSeconds, 120)
        preRollSeconds = field(.preRollSeconds, 1.0)
        claudeModel = field(.claudeModel, "claude-haiku-4-5")
        openaiModel = field(.openaiModel, "gpt-4o-mini")
        overlayPosition = field(.overlayPosition, .bottomCenter)
        appearance = field(.appearance, .dark)
        aiChatMode = field(.aiChatMode, .both)
        snapSizes = field(.snapSizes, .thirds)
        snapAssist = field(.snapAssist, true)
        gridSize = field(.gridSize, .c12x8)
        windowPalette = field(.windowPalette, true)
        clipboardHistory = field(.clipboardHistory, true)
        lastWindowSwitch = field(.lastWindowSwitch, true)
        grabAndMove = field(.grabAndMove, true)
        grabMoveModifiers = field(.grabMoveModifiers, .ctrlCmd)
        muteWhileDictating = field(.muteWhileDictating, true)
        finderEnterOpens = field(.finderEnterOpens, true)
        // Migration: the old combined `windowsKeys` flag (read from a separate
        // container so it needn't be a CodingKey the synthesized encoder must
        // satisfy) seeds all four if the granular keys aren't present yet.
        enum LegacyKeys: String, CodingKey { case windowsKeys }
        let legacyWinKeys = ((try? decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(Bool.self, forKey: .windowsKeys)) ?? nil)
        keyHomeEnd = field(.keyHomeEnd, legacyWinKeys ?? true)
        finderBackspaceUp = field(.finderBackspaceUp, legacyWinKeys ?? true)
        finderDeleteTrash = field(.finderDeleteTrash, legacyWinKeys ?? true)
        taskManagerShortcut = field(.taskManagerShortcut, legacyWinKeys ?? true)
        captureEndpoint = field(.captureEndpoint, "")
        captureAuthHeader = field(.captureAuthHeader, "X-Api-Key")
        captureBodyTemplate = field(.captureBodyTemplate, "{\"title\":\"%TEXT%\"}")
        connections = field(.connections, [])
        macroPad = field(.macroPad, true)
        macroPadProfiles = field(.macroPadProfiles, [])
        // Migration: New Outlook dropped the ⌘⇧M shortcut for Move (still true
        // as of this writing — the menu item now has no keyboard shortcut at
        // all), so any button still carrying that dead chord is switched to
        // clicking Message ▸ Move directly via the Accessibility API instead.
        if let idx = macroPadProfiles.firstIndex(where: {
            $0.bundleID.caseInsensitiveCompare("com.microsoft.Outlook") == .orderedSame
        }) {
            for bi in macroPadProfiles[idx].buttons.indices
            where macroPadProfiles[idx].buttons[bi].chord == "cmd+shift+m" {
                macroPadProfiles[idx].buttons[bi].chord = ""
                macroPadProfiles[idx].buttons[bi].menuPath = "Message,Move"
            }
        }
        macroPadStepDelayMs = field(.macroPadStepDelayMs, 350)
        macroPadThreeFingerTap = field(.macroPadThreeFingerTap, true)
        macroPadSummonFingers = min(5, max(2, field(.macroPadSummonFingers, 3)))
        agentPad = field(.agentPad, true)
        agentPadPort = field(.agentPadPort, 8377)
        agentPadCodex = field(.agentPadCodex, true)
        agentPadCursor = field(.agentPadCursor, true)
        agentPadGrok = field(.agentPadGrok, true)
        restorePads = field(.restorePads, true)
        notchStrip = field(.notchStrip, true)
        notchAgents = field(.notchAgents, true)
        notchQuota = field(.notchQuota, false)
        notchQuotaAt = field(.notchQuotaAt, 60)
        notchStripMigrated = field(.notchStripMigrated, false)
        showInCaptures = field(.showInCaptures, true)
        notchModules = field(.notchModules, ["usage", "hotkeys", "snap", "clock", "calendar", "weather", "chat"])
        // `save()` writes the whole config, so every existing config.json carries
        // the OLD default list verbatim and would hide any module added later.
        // A list that still equals that old default is not a choice — it takes
        // the new default; a list the user actually edited is left alone.
        if notchModules == ["usage", "hotkeys", "snap", "clock", "weather", "chat"] {
            notchModules = ["usage", "hotkeys", "snap", "clock", "calendar", "weather", "chat"]
        }
        notchClockZones = field(.notchClockZones, ["America/New_York", "Europe/London", "Asia/Tokyo"])
        weatherPlaces = field(.weatherPlaces, [])
        weatherPlace = field(.weatherPlace, "")
        weatherLat = field(.weatherLat, 0)
        weatherLon = field(.weatherLon, 0)
        weatherFahrenheit = field(.weatherFahrenheit, true)
        // An older config carried a single place — fold it into the list once
        // so multi-place users and legacy users converge on `weatherPlaces`.
        if weatherPlaces.isEmpty, abs(weatherLat) + abs(weatherLon) > 0 {
            weatherPlaces = [WeatherPlace(name: weatherPlace, lat: weatherLat, lon: weatherLon)]
        }
        powerRing = field(.powerRing, true)
        powerRingSlots = field(.powerRingSlots, PowerRingCatalog.defaultSlots)
        whiteboard = field(.whiteboard, true)
        pronunciations = field(.pronunciations, [:])
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
        guard let data = try? Data(contentsOf: configURL) else {
            let cfg = Config()   // first launch — no file yet
            cfg.save()
            return cfg
        }
        guard var cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            // Unparseable JSON (not just a bad field — those fall back per-field).
            // Preserve the file for recovery and do NOT save defaults over it;
            // run on in-memory defaults instead.
            let aside = appSupportDir.appendingPathComponent("config.json.unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.copyItem(at: configURL, to: aside)
            NSLog("PowerTools: config.json failed to parse — using defaults this run; original preserved at config.json.unreadable")
            return Config()
        }
        if cfg.migrateLegacyCapture() { cfg.save() }
        return cfg
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Config.configURL, options: .atomic)
        }
    }
}
