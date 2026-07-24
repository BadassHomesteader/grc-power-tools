using System.Windows;
using System.Windows.Controls;
using PowerTools.Core;
using PowerTools.Platform;

namespace PowerTools.UI;

/// <summary>
/// Settings shell (Phase 1): hotkey choice, launch at login, appearance.
/// Later phases add the Dictation / Windows / Pads tabs as their features land
/// — same growth path the Mac SettingsWindow took.
/// </summary>
public sealed class SettingsWindow : Window
{
    private static SettingsWindow? _open;

    // Hotkey order matches the Config enum; display names use the Windows keys
    // (Option → Alt, Command → Win). "fn" is intentionally absent — no PC key.
    private static readonly (Config.Hotkey Value, string Label)[] HotkeyChoices =
    {
        (Config.Hotkey.OptionShift, "Alt + Shift  (default)"),
        (Config.Hotkey.RightOption, "Right Alt"),
        (Config.Hotkey.RightCommand, "Right Win"),
        (Config.Hotkey.CtrlOption, "Ctrl + Alt"),
        (Config.Hotkey.ShiftCommand, "Shift + Win"),
    };

    public static void ShowSingleton(Config config)
    {
        if (_open is not null)
        {
            _open.Activate();
            return;
        }
        _open = new SettingsWindow(config);
        _open.Closed += (_, _) => _open = null;
        _open.Show();
    }

    private SettingsWindow(Config config)
    {
        Title = "Power Tools — Settings";
        Width = 520;
        Height = 420;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var general = new StackPanel { Margin = new Thickness(16) };

        general.Children.Add(new TextBlock
        {
            Text = "Hold-to-talk hotkey",
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 4),
        });
        var hotkeyBox = new ComboBox { Width = 260, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var (_, label) in HotkeyChoices) hotkeyBox.Items.Add(label);
        var idx = Array.FindIndex(HotkeyChoices, h => h.Value == config.HotkeyChoice);
        hotkeyBox.SelectedIndex = idx >= 0 ? idx : 0;
        hotkeyBox.SelectionChanged += (_, _) =>
        {
            config.HotkeyChoice = HotkeyChoices[hotkeyBox.SelectedIndex].Value;
            config.Save();
            Logger.Log($"settings: hotkey → {config.HotkeyChoice} (restart to apply)");
        };
        general.Children.Add(hotkeyBox);
        general.Children.Add(new TextBlock
        {
            Text = "Changing the hotkey takes effect after Power Tools restarts.\n" +
                   "Alt + Shift also switches input language if you have several keyboard\n" +
                   "layouts installed — pick another combo or remove that Windows hotkey.",
            Foreground = SystemColors.GrayTextBrush,
            Margin = new Thickness(0, 4, 0, 16),
        });

        var login = new CheckBox
        {
            Content = "Launch Power Tools at sign-in",
            IsChecked = StartupManager.IsEnabled,
        };
        login.Checked += (_, _) => StartupManager.SetEnabled(true);
        login.Unchecked += (_, _) => StartupManager.SetEnabled(false);
        general.Children.Add(login);

        var about = new StackPanel { Margin = new Thickness(16) };
        about.Children.Add(new TextBlock
        {
            Text = "GRC Power Tools for Windows",
            FontSize = 16,
            FontWeight = FontWeights.SemiBold,
        });
        about.Children.Add(new TextBlock
        {
            Text = "Phase 1 — core infrastructure. Dictation, window management,\n" +
                   "clipboard tools, pads, and the Agent Pad arrive in later phases.\n\n" +
                   $"Data folder: {Paths.AppSupportDir}\n" +
                   "Settings and history are shared-schema with the macOS app.",
            Margin = new Thickness(0, 8, 0, 0),
        });

        Content = new TabControl
        {
            Items =
            {
                new TabItem { Header = "General", Content = general },
                new TabItem { Header = "About", Content = about },
            },
        };
    }
}
