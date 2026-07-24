using System.Globalization;

namespace PowerTools.Core;

/// <summary>
/// Timestamped session log appended to grc-whisper.log, same format as the Mac
/// app's `log()`: "[ISO8601] message". Serialized on a background queue so
/// callers never block on disk.
/// </summary>
public static class Logger
{
    private static readonly object Gate = new();

    public static void Log(string message)
    {
        var ts = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        var line = $"[{ts}] {message}";
        Console.Error.WriteLine(line);
        Task.Run(() =>
        {
            lock (Gate)
            {
                try { File.AppendAllText(Paths.LogFile, line + Environment.NewLine); }
                catch { /* logging must never throw into app code */ }
            }
        });
    }
}
