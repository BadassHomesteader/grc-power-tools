using System.Drawing;
using PowerTools.Core;
using WinForms = System.Windows.Forms;

namespace PowerTools.Tray;

/// <summary>
/// System-tray presence — the Windows stand-in for the Mac menu-bar item.
/// WinForms NotifyIcon is the one WinForms dependency in the app; everything
/// user-facing beyond this menu is WPF.
/// </summary>
public sealed class TrayIcon : IDisposable
{
    private readonly WinForms.NotifyIcon _icon;

    public TrayIcon(Action onSettings, Action onQuit)
    {
        var menu = new WinForms.ContextMenuStrip();
        menu.Items.Add("Settings…", null, (_, _) => onSettings());
        menu.Items.Add("Open data folder", null, (_, _) =>
            System.Diagnostics.Process.Start("explorer.exe", Paths.AppSupportDir));
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("Quit Power Tools", null, (_, _) => onQuit());

        _icon = new WinForms.NotifyIcon
        {
            Text = "GRC Power Tools",
            Icon = LoadIcon(),
            ContextMenuStrip = menu,
            Visible = true,
        };
        _icon.DoubleClick += (_, _) => onSettings();
    }

    private static Icon LoadIcon()
    {
        try
        {
            if (Environment.ProcessPath is { } exe && Icon.ExtractAssociatedIcon(exe) is { } icon)
                return icon;
        }
        catch { }
        return SystemIcons.Application;
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
