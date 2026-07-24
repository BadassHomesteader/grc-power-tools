using Microsoft.Win32;

namespace PowerTools.Platform;

/// <summary>
/// Launch-at-login via the HKCU Run key — the Windows analog of the Mac app's
/// SMAppService.mainApp registration. Per-user, no elevation needed.
/// </summary>
public static class StartupManager
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "GRC Power Tools";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string;
        }
    }

    public static void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled && Environment.ProcessPath is { } exe)
            key.SetValue(ValueName, $"\"{exe}\"");
        else
            key.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}
