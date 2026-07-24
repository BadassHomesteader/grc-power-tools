using System.Text.Json;

namespace PowerTools.Core;

/// <summary>
/// API-key store backed by keys.json in the app data folder — the same file
/// and account-key layout as the Mac app's Keychain.swift (which deliberately
/// avoids the OS keychain). A corrupt file is moved aside as keys.json.corrupt
/// rather than silently reporting "never configured".
/// </summary>
public static class SecretsStore
{
    private static Dictionary<string, string> Load()
    {
        if (!File.Exists(Paths.KeysFile)) return new();
        try
        {
            return JsonSerializer.Deserialize<Dictionary<string, string>>(
                File.ReadAllText(Paths.KeysFile)) ?? new();
        }
        catch
        {
            var aside = Path.Combine(Paths.AppSupportDir, "keys.json.corrupt");
            try
            {
                File.Delete(aside);
                File.Move(Paths.KeysFile, aside);
            }
            catch { }
            Logger.Log("secrets: keys.json was unreadable — moved to keys.json.corrupt; re-enter API keys in Settings");
            return new();
        }
    }

    private static void Save(Dictionary<string, string> dict)
    {
        var tmp = Paths.KeysFile + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(dict));
        File.Move(tmp, Paths.KeysFile, overwrite: true);
        // NTFS has no 0600; the file lives under the user profile, which is
        // already inaccessible to other non-admin accounts.
    }

    public static void Set(string account, string value)
    {
        var dict = Load();
        if (string.IsNullOrEmpty(value)) dict.Remove(account);
        else dict[account] = value;
        Save(dict);
    }

    public static string? Get(string account) => Load().TryGetValue(account, out var v) ? v : null;

    public static bool Has(string account) => !string.IsNullOrEmpty(Get(account));
}
