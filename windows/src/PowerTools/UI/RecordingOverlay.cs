using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Runtime.InteropServices;
using PowerTools.Core;

namespace PowerTools.UI;

/// <summary>
/// The dictation status pill — minimal Windows counterpart of OverlayPanel.
/// Borderless, topmost, click-through-irrelevant, and NON-ACTIVATING so focus
/// never leaves the app being dictated into. Shows state + a live level bar.
/// </summary>
public sealed class RecordingOverlay : Window
{
    private readonly TextBlock _label;
    private readonly Border _levelFill;

    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TOOLWINDOW = 0x00000080;

    [DllImport("user32.dll")]
    private static extern int GetWindowLongW(nint hWnd, int index);
    [DllImport("user32.dll")]
    private static extern int SetWindowLongW(nint hWnd, int index, int value);

    public RecordingOverlay(Config config)
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        Focusable = false;
        SizeToContent = SizeToContent.WidthAndHeight;

        _label = new TextBlock
        {
            Text = "● Listening…",
            Foreground = Brushes.White,
            FontSize = 14,
            Margin = new Thickness(14, 8, 14, 4),
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        _levelFill = new Border
        {
            Background = new SolidColorBrush(Color.FromRgb(80, 200, 120)),
            Height = 3,
            Width = 0,
            HorizontalAlignment = HorizontalAlignment.Left,
            CornerRadius = new CornerRadius(1.5),
        };
        var levelTrack = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(60, 255, 255, 255)),
            Height = 3,
            Width = 160,
            Margin = new Thickness(14, 0, 14, 10),
            CornerRadius = new CornerRadius(1.5),
            Child = _levelFill,
        };
        var stack = new StackPanel();
        stack.Children.Add(_label);
        stack.Children.Add(levelTrack);

        Content = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(230, 28, 28, 30)),
            CornerRadius = new CornerRadius(14),
            Child = stack,
        };

        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            SetWindowLongW(hwnd, GWL_EXSTYLE,
                GetWindowLongW(hwnd, GWL_EXSTYLE) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
        };
        Loaded += (_, _) => Position(config.OverlayPos);
    }

    private void Position(Config.OverlayPosition pos)
    {
        var area = SystemParameters.WorkArea;
        const int margin = 24;
        Left = pos switch
        {
            Config.OverlayPosition.BottomLeft or Config.OverlayPosition.TopLeft => area.Left + margin,
            Config.OverlayPosition.BottomRight or Config.OverlayPosition.TopRight => area.Right - ActualWidth - margin,
            _ => area.Left + (area.Width - ActualWidth) / 2,
        };
        Top = pos switch
        {
            Config.OverlayPosition.TopCenter or Config.OverlayPosition.TopLeft or Config.OverlayPosition.TopRight
                => area.Top + margin,
            Config.OverlayPosition.Center => area.Top + (area.Height - ActualHeight) / 2,
            _ => area.Bottom - ActualHeight - margin,
        };
    }

    public void SetState(string text) => _label.Text = text;

    public void SetLevel(float level) =>
        _levelFill.Width = Math.Clamp(level, 0f, 1f) * 160;
}
