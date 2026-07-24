namespace PowerTools.Core;

/// <summary>
/// App data locations. Mirrors the Mac app's
/// ~/Library/Application Support/GRC Whisper/ — same folder name, same file
/// names, so config.json / keys.json / grc-whisper.sqlite are drop-in
/// compatible across machines.
/// </summary>
public static class Paths
{
    public static string AppSupportDir
    {
        get
        {
            // POWERTOOLS_DATA_DIR redirects everything — used by the test
            // harness and handy for portable installs.
            var dir = Environment.GetEnvironmentVariable("POWERTOOLS_DATA_DIR")
                ?? Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "GRC Whisper");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    public static string ConfigFile => Path.Combine(AppSupportDir, "config.json");
    public static string KeysFile => Path.Combine(AppSupportDir, "keys.json");
    public static string DatabaseFile => Path.Combine(AppSupportDir, "grc-whisper.sqlite");
    public static string LogFile => Path.Combine(AppSupportDir, "grc-whisper.log");
}
