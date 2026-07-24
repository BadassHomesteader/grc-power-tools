using System.Windows;
using PowerTools.Core;
using PowerTools.Input;
using PowerTools.Tray;
using PowerTools.UI;

namespace PowerTools;

public static class Program
{
    [STAThread]
    public static void Main()
    {
        using var mutex = new Mutex(initiallyOwned: true, "GRC.PowerTools.SingleInstance", out var createdNew);
        if (!createdNew) return;   // already running — the tray icon is the UI

        Logger.Log("app: Power Tools for Windows starting (phase 1)");
        var config = Config.Load();
        using var store = new Store();

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var dispatcher = app.Dispatcher;

        var hook = new KeyboardHook(config.HotkeyChoice,
            e => dispatcher.BeginInvoke(() => HandleHook(e)));
        hook.PowerRingEnabled = config.PowerRing;

        var leaders = new Dictionary<int, string>();
        foreach (var conn in config.Connections)
            if (KeyboardHook.VkForLetter(conn.LeaderKey) is { } vk)
                leaders[vk] = conn.Id;
        hook.SetConnectionLeaders(leaders);

        if (!hook.Start())
            Logger.Log("app: global hotkey unavailable — running tray-only");

        using var tray = new TrayIcon(
            onSettings: () => SettingsWindow.ShowSingleton(config),
            onQuit: () => app.Shutdown());

        app.Exit += (_, _) =>
        {
            hook.Dispose();
            Logger.Log("app: shutting down");
        };
        app.Run();
    }

    /// <summary>
    /// Hook event sink. Phase 1 proves the input spine end-to-end by logging;
    /// Phase 2 replaces this with the AppController dictation state machine.
    /// </summary>
    private static void HandleHook(HookEvent e)
    {
        Logger.Log($"hook: {e}");
    }
}
