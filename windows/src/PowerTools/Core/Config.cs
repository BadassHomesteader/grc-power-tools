using System.Text.Json;
using System.Text.Json.Nodes;

namespace PowerTools.Core;

/// <summary>
/// All user-tunable settings, persisted as config.json in the app data folder.
///
/// PARITY CONTRACT: the JSON schema — key names, enum raw values, defaults,
/// lenient per-field decode, sorted-keys save — matches Sources/PowerTools/
/// Config.swift exactly. A config.json written by either platform loads on the
/// other. Mac-only settings (finderEnterOpens, keyHomeEnd, …) are carried
/// through untouched; Windows ignores them at runtime because Explorer already
/// behaves that way natively.
/// </summary>
public sealed class Config
{
    public enum Hotkey { Fn, RightOption, RightCommand, CtrlOption, ShiftCommand, OptionShift }
    public enum GrabModifiers { CtrlCmd, OptCmd, CtrlOpt, CtrlOptCmd }
    public enum OverlayPosition { BottomCenter, BottomLeft, BottomRight, Center, TopCenter, TopLeft, TopRight }
    public enum Appearance { Dark, Light }
    public enum SnapSizes { Thirds, Quarters, ThirdsQuarters, Fifths }
    public enum GridSize { C6x4, C8x6, C12x8, C16x10, C24x16 }
    public enum AIChatMode { Both, Native, Browser }
    public enum PolishMode { Apple, Claude, OpenAI, Basic, Off }
    public enum ASREngine { Apple, Parakeet }

    /// <summary>Default Power Ring slots — mirror of PowerRingCatalog.defaultSlots.</summary>
    public static readonly string[] DefaultPowerRingSlots =
        { "screenText", "screenshot", "clipboard", "pasteAs", "agentPad", "macroPad", "color", "readAloud" };

    public sealed class Connection
    {
        public string Id = "";
        public string Name = "Connection";
        public string LeaderKey = "";   // single letter, stored uppercase
        public string Endpoint = "";
        public string AuthHeader = "X-Api-Key";
        public string BodyTemplate = "{\"title\":\"%TEXT%\"}";

        public string TokenAccount => $"capture:{Id}";
    }

    public sealed class MacroButton
    {
        public string Title = "";
        public string Chord = "";
        public string Text = "";
        public bool PressReturn;
        public string Keywords = "";
        public string MenuPath = "";
        /// Pad column; blank = automatic (Favorites for folder moves, Actions otherwise).
        public string Group = "";
    }

    public sealed class MacroProfile
    {
        // Keeps the Mac key name; on Windows this will hold the process/exe
        // identity once the Macro Pad ships (Phase 5).
        public string BundleID = "";
        public string Name = "App";
        public List<MacroButton> Buttons = new();
    }

    public Hotkey HotkeyChoice = Hotkey.OptionShift;
    public PolishMode Polish = PolishMode.Apple;
    public ASREngine AsrEngine = ASREngine.Apple;
    public string LocaleIdentifier = "en_US";
    public int LlmDeadlineMs = 2500;
    public int ClipboardRestoreDelayMs = 600;
    public int MinHoldMs = 250;
    public int MaxUtteranceSeconds = 120;
    public double PreRollSeconds = 1.0;
    public string ClaudeModel = "claude-haiku-4-5";
    public string OpenaiModel = "gpt-4o-mini";
    public OverlayPosition OverlayPos = OverlayPosition.BottomCenter;
    public Appearance Theme = Appearance.Dark;
    public AIChatMode ChatMode = AIChatMode.Both;
    public SnapSizes Snap = SnapSizes.Thirds;
    public GridSize Grid = GridSize.C12x8;
    public bool SnapAssist = true;
    public bool WindowPalette = true;
    public bool ClipboardHistory = true;
    public bool LastWindowSwitch = true;   // Mac-only at runtime (Alt-Tab is native window-MRU)
    public bool GrabAndMove = true;
    public GrabModifiers GrabMods = GrabModifiers.CtrlCmd;
    public bool MuteWhileDictating = true;
    public bool FinderEnterOpens = true;   // Mac-only, carried for parity
    public bool KeyHomeEnd = true;         // Mac-only, carried for parity
    public bool FinderBackspaceUp = true;  // Mac-only, carried for parity
    public bool FinderDeleteTrash = true;  // Mac-only, carried for parity
    public bool TaskManagerShortcut = true; // Mac-only, carried for parity (Ctrl+Shift+Esc is native)
    public string CaptureEndpoint = "";
    public string CaptureAuthHeader = "X-Api-Key";
    public string CaptureBodyTemplate = "{\"title\":\"%TEXT%\"}";
    public List<Connection> Connections = new();
    public bool MacroPad = true;
    public List<MacroProfile> MacroPadProfiles = new();
    public int MacroPadStepDelayMs = 350;
    /// Mac-only (three-finger-tap summon of the Macro Pad); preserved for schema parity.
    public bool MacroPadThreeFingerTap = true;
    public bool AgentPad = true;
    public int AgentPadPort = 8377;
    public bool AgentPadCodex = true;
    public bool AgentPadCursor = true;
    public bool RestorePads = true;
    public bool PowerRing = true;
    public List<string> PowerRingSlots = new(DefaultPowerRingSlots);
    /// Mac-only (annotation whiteboard on hold + E); preserved for schema parity.
    public bool Whiteboard = true;
    public Dictionary<string, string> Pronunciations = new();

    // ---- enum raw-value maps (must match the Swift rawValues verbatim) ----

    private static readonly (Hotkey V, string S)[] HotkeyRaw =
        { (Hotkey.Fn, "fn"), (Hotkey.RightOption, "rightOption"), (Hotkey.RightCommand, "rightCommand"),
          (Hotkey.CtrlOption, "ctrlOption"), (Hotkey.ShiftCommand, "shiftCommand"), (Hotkey.OptionShift, "optionShift") };
    private static readonly (GrabModifiers V, string S)[] GrabRaw =
        { (GrabModifiers.CtrlCmd, "ctrlCmd"), (GrabModifiers.OptCmd, "optCmd"),
          (GrabModifiers.CtrlOpt, "ctrlOpt"), (GrabModifiers.CtrlOptCmd, "ctrlOptCmd") };
    private static readonly (OverlayPosition V, string S)[] OverlayRaw =
        { (OverlayPosition.BottomCenter, "bottomCenter"), (OverlayPosition.BottomLeft, "bottomLeft"),
          (OverlayPosition.BottomRight, "bottomRight"), (OverlayPosition.Center, "center"),
          (OverlayPosition.TopCenter, "topCenter"), (OverlayPosition.TopLeft, "topLeft"),
          (OverlayPosition.TopRight, "topRight") };
    private static readonly (Appearance V, string S)[] AppearanceRaw =
        { (Appearance.Dark, "dark"), (Appearance.Light, "light") };
    private static readonly (SnapSizes V, string S)[] SnapRaw =
        { (SnapSizes.Thirds, "thirds"), (SnapSizes.Quarters, "quarters"),
          (SnapSizes.ThirdsQuarters, "thirdsQuarters"), (SnapSizes.Fifths, "fifths") };
    private static readonly (GridSize V, string S)[] GridRaw =
        { (GridSize.C6x4, "c6x4"), (GridSize.C8x6, "c8x6"), (GridSize.C12x8, "c12x8"),
          (GridSize.C16x10, "c16x10"), (GridSize.C24x16, "c24x16") };
    private static readonly (AIChatMode V, string S)[] ChatRaw =
        { (AIChatMode.Both, "both"), (AIChatMode.Native, "native"), (AIChatMode.Browser, "browser") };
    private static readonly (ASREngine V, string S)[] AsrRaw =
        { (ASREngine.Apple, "apple"), (ASREngine.Parakeet, "parakeet") };

    private static string Raw<T>((T V, string S)[] map, T v) where T : struct
        => map.First(m => m.V.Equals(v)).S;

    private static T FromRaw<T>((T V, string S)[] map, string? s, T fallback) where T : struct
    {
        if (s is null) return fallback;
        foreach (var (v, raw) in map)
            if (raw == s) return v;
        return fallback;
    }

    private static string PolishRawValue(PolishMode p) => p switch
    {
        PolishMode.Apple => "apple", PolishMode.Claude => "claude", PolishMode.OpenAI => "openai",
        PolishMode.Basic => "basic", _ => "off",
    };

    // Same mapping as Swift: legacy "llm" → apple, anything unknown → off.
    private static PolishMode PolishFromRaw(string raw) => raw switch
    {
        "llm" or "apple" => PolishMode.Apple, "claude" => PolishMode.Claude,
        "openai" => PolishMode.OpenAI, "basic" => PolishMode.Basic, _ => PolishMode.Off,
    };

    // ---- load ----

    public static Config Load()
    {
        if (!File.Exists(Paths.ConfigFile))
        {
            var fresh = new Config();
            fresh.Save();
            return fresh;
        }

        JsonElement root;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(Paths.ConfigFile));
            root = doc.RootElement.Clone();
        }
        catch
        {
            // Unparseable JSON (not just a bad field — those fall back per-field).
            // Preserve the file for recovery and do NOT save defaults over it.
            var aside = Path.Combine(Paths.AppSupportDir, "config.json.unreadable");
            try { File.Delete(aside); File.Copy(Paths.ConfigFile, aside); } catch { }
            Logger.Log("config: config.json failed to parse — using defaults this run; original preserved at config.json.unreadable");
            return new Config();
        }

        var c = new Config();
        c.HotkeyChoice = FromRaw(HotkeyRaw, Str(root, "hotkey"), Hotkey.OptionShift);
        if (Str(root, "polish") is { } pRaw) c.Polish = PolishFromRaw(pRaw);
        c.AsrEngine = FromRaw(AsrRaw, Str(root, "asrEngine"), ASREngine.Apple);
        c.LocaleIdentifier = Str(root, "localeIdentifier") ?? "en_US";
        c.LlmDeadlineMs = Int(root, "llmDeadlineMs", 2500);
        c.ClipboardRestoreDelayMs = Int(root, "clipboardRestoreDelayMs", 600);
        c.MinHoldMs = Int(root, "minHoldMs", 250);
        c.MaxUtteranceSeconds = Int(root, "maxUtteranceSeconds", 120);
        c.PreRollSeconds = Dbl(root, "preRollSeconds", 1.0);
        c.ClaudeModel = Str(root, "claudeModel") ?? "claude-haiku-4-5";
        c.OpenaiModel = Str(root, "openaiModel") ?? "gpt-4o-mini";
        c.OverlayPos = FromRaw(OverlayRaw, Str(root, "overlayPosition"), OverlayPosition.BottomCenter);
        c.Theme = FromRaw(AppearanceRaw, Str(root, "appearance"), Appearance.Dark);
        c.ChatMode = FromRaw(ChatRaw, Str(root, "aiChatMode"), AIChatMode.Both);
        c.Snap = FromRaw(SnapRaw, Str(root, "snapSizes"), SnapSizes.Thirds);
        c.Grid = FromRaw(GridRaw, Str(root, "gridSize"), GridSize.C12x8);
        c.SnapAssist = Bool(root, "snapAssist", true);
        c.WindowPalette = Bool(root, "windowPalette", true);
        c.ClipboardHistory = Bool(root, "clipboardHistory", true);
        c.LastWindowSwitch = Bool(root, "lastWindowSwitch", true);
        c.GrabAndMove = Bool(root, "grabAndMove", true);
        c.GrabMods = FromRaw(GrabRaw, Str(root, "grabMoveModifiers"), GrabModifiers.CtrlCmd);
        c.MuteWhileDictating = Bool(root, "muteWhileDictating", true);
        c.FinderEnterOpens = Bool(root, "finderEnterOpens", true);
        // Migration parity: the old combined `windowsKeys` flag seeds all four
        // granular keys when they aren't present yet.
        bool? legacyWinKeys = OptBool(root, "windowsKeys");
        c.KeyHomeEnd = Bool(root, "keyHomeEnd", legacyWinKeys ?? true);
        c.FinderBackspaceUp = Bool(root, "finderBackspaceUp", legacyWinKeys ?? true);
        c.FinderDeleteTrash = Bool(root, "finderDeleteTrash", legacyWinKeys ?? true);
        c.TaskManagerShortcut = Bool(root, "taskManagerShortcut", legacyWinKeys ?? true);
        c.CaptureEndpoint = Str(root, "captureEndpoint") ?? "";
        c.CaptureAuthHeader = Str(root, "captureAuthHeader") ?? "X-Api-Key";
        c.CaptureBodyTemplate = Str(root, "captureBodyTemplate") ?? "{\"title\":\"%TEXT%\"}";
        c.Connections = ParseConnections(root);
        c.MacroPad = Bool(root, "macroPad", true);
        c.MacroPadProfiles = ParseProfiles(root);
        c.MacroPadStepDelayMs = Int(root, "macroPadStepDelayMs", 350);
        c.MacroPadThreeFingerTap = Bool(root, "macroPadThreeFingerTap", true);
        c.AgentPad = Bool(root, "agentPad", true);
        c.AgentPadPort = Int(root, "agentPadPort", 8377);
        c.AgentPadCodex = Bool(root, "agentPadCodex", true);
        c.AgentPadCursor = Bool(root, "agentPadCursor", true);
        c.RestorePads = Bool(root, "restorePads", true);
        c.PowerRing = Bool(root, "powerRing", true);
        c.PowerRingSlots = StrList(root, "powerRingSlots") ?? new(DefaultPowerRingSlots);
        c.Whiteboard = Bool(root, "whiteboard", true);
        c.Pronunciations = StrMap(root, "pronunciations");

        if (c.MigrateLegacyCapture()) c.Save();
        return c;
    }

    /// <summary>
    /// One-time migration parity with the Mac app: fold the pre-multi-connection
    /// single capture fields into Connections[]. Returns true if anything changed.
    /// </summary>
    public bool MigrateLegacyCapture()
    {
        if (Connections.Count > 0 || string.IsNullOrEmpty(CaptureEndpoint)) return false;
        var conn = new Connection
        {
            Id = "default", Name = "Todo", LeaderKey = "N",
            Endpoint = CaptureEndpoint, AuthHeader = CaptureAuthHeader, BodyTemplate = CaptureBodyTemplate,
        };
        Connections = new List<Connection> { conn };
        var tok = SecretsStore.Get("capture");
        if (tok is not null && SecretsStore.Get(conn.TokenAccount) is null)
            SecretsStore.Set(conn.TokenAccount, tok);
        CaptureEndpoint = "";   // consumed; Connections is now the source of truth
        return true;
    }

    // ---- save (pretty-printed, keys sorted at every level, like Swift's .sortedKeys) ----

    public void Save()
    {
        var rootObj = new JsonObject
        {
            ["hotkey"] = Raw(HotkeyRaw, HotkeyChoice),
            ["polish"] = PolishRawValue(Polish),
            ["asrEngine"] = Raw(AsrRaw, AsrEngine),
            ["localeIdentifier"] = LocaleIdentifier,
            ["llmDeadlineMs"] = LlmDeadlineMs,
            ["clipboardRestoreDelayMs"] = ClipboardRestoreDelayMs,
            ["minHoldMs"] = MinHoldMs,
            ["maxUtteranceSeconds"] = MaxUtteranceSeconds,
            ["preRollSeconds"] = PreRollSeconds,
            ["claudeModel"] = ClaudeModel,
            ["openaiModel"] = OpenaiModel,
            ["overlayPosition"] = Raw(OverlayRaw, OverlayPos),
            ["appearance"] = Raw(AppearanceRaw, Theme),
            ["aiChatMode"] = Raw(ChatRaw, ChatMode),
            ["snapSizes"] = Raw(SnapRaw, Snap),
            ["gridSize"] = Raw(GridRaw, Grid),
            ["snapAssist"] = SnapAssist,
            ["windowPalette"] = WindowPalette,
            ["clipboardHistory"] = ClipboardHistory,
            ["lastWindowSwitch"] = LastWindowSwitch,
            ["muteWhileDictating"] = MuteWhileDictating,
            ["finderEnterOpens"] = FinderEnterOpens,
            ["grabAndMove"] = GrabAndMove,
            ["grabMoveModifiers"] = Raw(GrabRaw, GrabMods),
            ["keyHomeEnd"] = KeyHomeEnd,
            ["finderBackspaceUp"] = FinderBackspaceUp,
            ["finderDeleteTrash"] = FinderDeleteTrash,
            ["taskManagerShortcut"] = TaskManagerShortcut,
            ["captureEndpoint"] = CaptureEndpoint,
            ["captureAuthHeader"] = CaptureAuthHeader,
            ["captureBodyTemplate"] = CaptureBodyTemplate,
            ["connections"] = new JsonArray(Connections.Select(cn => (JsonNode)new JsonObject
            {
                ["id"] = cn.Id, ["name"] = cn.Name, ["leaderKey"] = cn.LeaderKey,
                ["endpoint"] = cn.Endpoint, ["authHeader"] = cn.AuthHeader, ["bodyTemplate"] = cn.BodyTemplate,
            }).ToArray()),
            ["macroPad"] = MacroPad,
            ["macroPadProfiles"] = new JsonArray(MacroPadProfiles.Select(p => (JsonNode)new JsonObject
            {
                ["bundleID"] = p.BundleID, ["name"] = p.Name,
                ["buttons"] = new JsonArray(p.Buttons.Select(b => (JsonNode)new JsonObject
                {
                    ["title"] = b.Title, ["chord"] = b.Chord, ["text"] = b.Text,
                    ["pressReturn"] = b.PressReturn, ["keywords"] = b.Keywords, ["menuPath"] = b.MenuPath,
                    ["group"] = b.Group,
                }).ToArray()),
            }).ToArray()),
            ["macroPadStepDelayMs"] = MacroPadStepDelayMs,
            ["macroPadThreeFingerTap"] = MacroPadThreeFingerTap,
            ["agentPad"] = AgentPad,
            ["agentPadPort"] = AgentPadPort,
            ["agentPadCodex"] = AgentPadCodex,
            ["agentPadCursor"] = AgentPadCursor,
            ["restorePads"] = RestorePads,
            ["powerRing"] = PowerRing,
            ["powerRingSlots"] = new JsonArray(PowerRingSlots.Select(s => (JsonNode)s!).ToArray()),
            ["whiteboard"] = Whiteboard,
            ["pronunciations"] = new JsonObject(Pronunciations.Select(kv =>
                new KeyValuePair<string, JsonNode?>(kv.Key, kv.Value))),
        };

        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true }))
            WriteSorted(writer, rootObj);
        var tmp = Paths.ConfigFile + ".tmp";
        File.WriteAllBytes(tmp, stream.ToArray());
        File.Move(tmp, Paths.ConfigFile, overwrite: true);
    }

    private static void WriteSorted(Utf8JsonWriter w, JsonNode? node)
    {
        switch (node)
        {
            case JsonObject obj:
                w.WriteStartObject();
                foreach (var kv in obj.OrderBy(k => k.Key, StringComparer.Ordinal))
                {
                    w.WritePropertyName(kv.Key);
                    WriteSorted(w, kv.Value);
                }
                w.WriteEndObject();
                break;
            case JsonArray arr:
                w.WriteStartArray();
                foreach (var item in arr) WriteSorted(w, item);
                w.WriteEndArray();
                break;
            case null:
                w.WriteNullValue();
                break;
            default:
                node.WriteTo(w);
                break;
        }
    }

    // ---- lenient field helpers (bad type or missing key → default, never throw) ----

    private static string? Str(JsonElement o, string key)
        => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() : null;

    private static int Int(JsonElement o, string key, int def)
        => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n)
            ? n : def;

    private static double Dbl(JsonElement o, string key, double def)
        => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble() : def;

    private static bool Bool(JsonElement o, string key, bool def) => OptBool(o, key) ?? def;

    private static bool? OptBool(JsonElement o, string key)
        => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(key, out var v)
           && v.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? v.GetBoolean() : null;

    private static List<string>? StrList(JsonElement o, string key)
    {
        if (o.ValueKind != JsonValueKind.Object || !o.TryGetProperty(key, out var v) || v.ValueKind != JsonValueKind.Array)
            return null;
        return v.EnumerateArray()
            .Where(e => e.ValueKind == JsonValueKind.String)
            .Select(e => e.GetString()!).ToList();
    }

    private static Dictionary<string, string> StrMap(JsonElement o, string key)
    {
        var outMap = new Dictionary<string, string>();
        if (o.ValueKind != JsonValueKind.Object || !o.TryGetProperty(key, out var v) || v.ValueKind != JsonValueKind.Object)
            return outMap;
        foreach (var prop in v.EnumerateObject())
            if (prop.Value.ValueKind == JsonValueKind.String)
                outMap[prop.Name] = prop.Value.GetString()!;
        return outMap;
    }

    private static List<Connection> ParseConnections(JsonElement root)
    {
        var list = new List<Connection>();
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("connections", out var arr) || arr.ValueKind != JsonValueKind.Array)
            return list;
        foreach (var e in arr.EnumerateArray())
        {
            if (e.ValueKind != JsonValueKind.Object) continue;
            list.Add(new Connection
            {
                Id = Str(e, "id") ?? "",
                Name = Str(e, "name") ?? "Connection",
                LeaderKey = (Str(e, "leaderKey") ?? "").ToUpperInvariant(),
                Endpoint = Str(e, "endpoint") ?? "",
                AuthHeader = Str(e, "authHeader") ?? "X-Api-Key",
                BodyTemplate = Str(e, "bodyTemplate") ?? "{\"title\":\"%TEXT%\"}",
            });
        }
        return list;
    }

    private static List<MacroProfile> ParseProfiles(JsonElement root)
    {
        var list = new List<MacroProfile>();
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("macroPadProfiles", out var arr) || arr.ValueKind != JsonValueKind.Array)
            return list;
        foreach (var e in arr.EnumerateArray())
        {
            if (e.ValueKind != JsonValueKind.Object) continue;
            var profile = new MacroProfile
            {
                BundleID = Str(e, "bundleID") ?? "",
                Name = Str(e, "name") ?? "App",
            };
            if (e.TryGetProperty("buttons", out var btns) && btns.ValueKind == JsonValueKind.Array)
            {
                foreach (var b in btns.EnumerateArray())
                {
                    if (b.ValueKind != JsonValueKind.Object) continue;
                    profile.Buttons.Add(new MacroButton
                    {
                        Title = Str(b, "title") ?? "",
                        Chord = Str(b, "chord") ?? "",
                        Text = Str(b, "text") ?? "",
                        PressReturn = Bool(b, "pressReturn", false),
                        Keywords = Str(b, "keywords") ?? "",
                        MenuPath = Str(b, "menuPath") ?? "",
                        Group = Str(b, "group") ?? "",
                    });
                }
            }
            list.Add(profile);
        }
        return list;
    }
}
