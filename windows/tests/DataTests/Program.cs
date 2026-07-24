using System.Text.Json;
using PowerTools.Asr;
using PowerTools.Core;

// Data-layer + polish tests for the Windows port, runnable on any OS
// (including windows-latest CI). Exit code 0 = all passed.
//
//   dotnet run                       run the test suite
//   dotnet run -- asr <wav> <words>  ASR smoke: transcribe wav, assert words appear
//                                    (downloads ~700 MB of models on first use)

var failures = 0;
void Check(bool cond, string name)
{
    Console.WriteLine($"{(cond ? "PASS" : "FAIL")}  {name}");
    if (!cond) failures++;
}

// Redirect all app data into a scratch dir — never touch real user data.
var scratch = Path.Combine(Path.GetTempPath(), $"pt-tests-{Guid.NewGuid():N}");
Environment.SetEnvironmentVariable("POWERTOOLS_DATA_DIR", scratch);

if (args.Length >= 1 && args[0] == "asr")
{
    // ASR smoke mode: models are big, so they live in a STABLE cache dir
    // (reused across runs), not the per-run scratch.
    var cache = Environment.GetEnvironmentVariable("POWERTOOLS_ASR_CACHE")
        ?? Path.Combine(Path.GetTempPath(), "pt-asr-models");
    Environment.SetEnvironmentVariable("POWERTOOLS_DATA_DIR", cache);
    await ParakeetEngine.EnsureModels(Console.WriteLine);
    using var engine = new ParakeetEngine();
    engine.Load();
    var samples = WavFile.ReadMono16k(args[1]);
    Console.WriteLine($"audio: {samples.Length / 16000.0:F1}s");
    var text = engine.Transcribe(samples);
    Console.WriteLine($"TRANSCRIPT: {text}");
    foreach (var word in args.Skip(2))
        Check(text.Contains(word, StringComparison.OrdinalIgnoreCase), $"transcript contains \"{word}\"");
    return Fin();
}

// ---- Config: defaults ----
{
    var cfg = Config.Load();   // no file → writes defaults
    Check(File.Exists(Paths.ConfigFile), "config: default file written");
    Check(cfg.HotkeyChoice == Config.Hotkey.OptionShift, "config: default hotkey optionShift");
    Check(cfg.MinHoldMs == 250 && cfg.AgentPadPort == 8377, "config: default scalars");
    Check(cfg.PowerRingSlots.SequenceEqual(Config.DefaultPowerRingSlots), "config: default ring slots");

    var json = JsonDocument.Parse(File.ReadAllText(Paths.ConfigFile)).RootElement;
    Check(json.GetProperty("hotkey").GetString() == "optionShift", "config: raw value optionShift");
    Check(json.GetProperty("polish").GetString() == "apple", "config: raw value apple");
    var keys = json.EnumerateObject().Select(p => p.Name).ToList();
    Check(keys.SequenceEqual(keys.OrderBy(k => k, StringComparer.Ordinal)), "config: keys sorted");
}

// ---- Config: full round-trip stability ----
{
    var cfg = Config.Load();
    cfg.HotkeyChoice = Config.Hotkey.RightCommand;
    cfg.Polish = Config.PolishMode.Claude;
    cfg.AsrEngine = Config.ASREngine.Parakeet;
    cfg.Connections.Add(new Config.Connection { Id = "todo", Name = "Todo", LeaderKey = "N", Endpoint = "https://example.com/api" });
    cfg.MacroPadProfiles.Add(new Config.MacroProfile
    {
        BundleID = "com.microsoft.Outlook",
        Name = "Outlook",
        Buttons = { new Config.MacroButton { Title = "Move", MenuPath = "Message,Move", PressReturn = true } },
    });
    cfg.Pronunciations["KYAW"] = "K Y A W";
    cfg.Save();
    var bytes1 = File.ReadAllBytes(Paths.ConfigFile);

    var re = Config.Load();
    Check(re.HotkeyChoice == Config.Hotkey.RightCommand, "roundtrip: hotkey");
    Check(re.Polish == Config.PolishMode.Claude, "roundtrip: polish");
    Check(re.AsrEngine == Config.ASREngine.Parakeet, "roundtrip: asrEngine");
    Check(re.Connections.Count == 1 && re.Connections[0].LeaderKey == "N", "roundtrip: connection");
    Check(re.MacroPadProfiles.Count == 1 && re.MacroPadProfiles[0].Buttons[0].MenuPath == "Message,Move", "roundtrip: macro profile");
    Check(re.Pronunciations["KYAW"] == "K Y A W", "roundtrip: pronunciations");
    re.Save();
    Check(File.ReadAllBytes(Paths.ConfigFile).SequenceEqual(bytes1), "roundtrip: byte-stable save");
    File.Delete(Paths.ConfigFile);
}

// ---- Config: legacy migrations + lenient decode ----
{
    File.WriteAllText(Paths.ConfigFile, """
    {"captureEndpoint":"https://old.example.com/add","captureAuthHeader":"X-Api-Key",
     "windowsKeys":false,"hotkey":"bogus","polish":"llm","snapSizes":"halvesThirds",
     "minHoldMs":"not-a-number"}
    """);
    SecretsStore.Set("capture", "tok123");
    var cfg = Config.Load();
    Check(cfg.Connections.Count == 1 && cfg.Connections[0].Id == "default"
          && cfg.Connections[0].LeaderKey == "N", "migration: legacy capture folded");
    Check(cfg.CaptureEndpoint == "", "migration: endpoint consumed");
    Check(SecretsStore.Get("capture:default") == "tok123", "migration: token moved");
    Check(!cfg.KeyHomeEnd && !cfg.FinderBackspaceUp, "migration: windowsKeys seeds granular");
    Check(cfg.HotkeyChoice == Config.Hotkey.OptionShift, "lenient: unknown hotkey → default");
    Check(cfg.Polish == Config.PolishMode.Apple, "lenient: legacy llm → apple");
    Check(cfg.Snap == Config.SnapSizes.Thirds, "lenient: legacy snapSizes → thirds");
    Check(cfg.MinHoldMs == 250, "lenient: type mismatch → default");
    File.Delete(Paths.ConfigFile);
}

// ---- Config: unparseable file preserved ----
{
    File.WriteAllText(Paths.ConfigFile, "{ not json !!!");
    var cfg = Config.Load();
    Check(cfg.HotkeyChoice == Config.Hotkey.OptionShift, "corrupt: defaults in memory");
    Check(File.Exists(Path.Combine(Paths.AppSupportDir, "config.json.unreadable")), "corrupt: original preserved");
    Check(File.ReadAllText(Path.Combine(Paths.AppSupportDir, "config.json.unreadable")) == "{ not json !!!", "corrupt: content intact");
    File.Delete(Paths.ConfigFile);
}

// ---- Store ----
{
    using var store = new Store(Path.Combine(scratch, "test.sqlite"));
    store.AddHistory("Notepad", "um hello", "Hello", 900);
    var hist = store.RecentHistory();
    Check(hist.Count == 1 && hist[0].Polished == "Hello" && hist[0].App == "Notepad", "store: history");
    Check(hist[0].Timestamp.EndsWith("Z") && hist[0].Timestamp.Contains('T'), "store: ISO8601 ts");

    store.AddDictTerm("KYAW", "K Y A W");
    store.AddDictTerm("KYAW", "K Y A W, kayak");   // upsert
    var dict = store.Dictionary();
    Check(dict.Count == 1 && dict[0].Misheard == "K Y A W, kayak", "store: dictionary upsert");

    store.AddClip("first");
    store.AddClip("second");
    store.AddClip("first");    // bump, not duplicate
    var clips = store.RecentClips();
    Check(clips.Count == 2 && clips[0].Content == "first", "store: clip bump to top");

    store.AddImageClip(new byte[] { 137, 80, 78, 71 }, "Image · 2×2");
    Check(store.RecentClips()[0].Image is { Length: 4 }, "store: image clip");

    store.AddLayout("Work", "{\"windows\":[]}");
    store.RenameLayout(store.Layouts()[0].Id, "Home");
    Check(store.Layouts()[0].Name == "Home", "store: layout rename");
}

// ---- Tier-0 polish ----
{
    var noDict = Array.Empty<DictEntry>();
    // The leading comma of ", uh," survives Tier-0 (pattern order matches the
    // Swift original); the LLM tier is what smooths it out.
    Check(Polisher.Tier0("um so basically we need to, uh, ship the update", noDict)
          == "So basically we need to, ship the update", "tier0: filler strip");
    Check(Polisher.Tier0("so, um, yeah", noDict) == "So, yeah", "tier0: comma absorption");
    var dict = new[] { new DictEntry("KYAW", "K Y A W, kayak") };
    Check(Polisher.Tier0("check the kayak dashboard", dict) == "Check the KYAW dashboard", "tier0: dictionary variant");
    Check(Polisher.Tier0("hello   world , again", noDict) == "Hello world, again", "tier0: whitespace + punct");
    Check(Polisher.Sane("hello there friend", "Hello there, friend."), "sane: accepts normal");
    Check(!Polisher.Sane("hello", "I'm sorry, I can't help with that request at all"), "sane: rejects refusal");
    Check(!Polisher.Sane("a long sentence about many things here", "hm"), "sane: rejects over-shrink");
}

return Fin();

int Fin()
{
    try { Directory.Delete(scratch, recursive: true); } catch { }
    Console.WriteLine(failures == 0 ? "ALL TESTS PASSED" : $"{failures} FAILURES");
    return failures == 0 ? 0 : 1;
}
