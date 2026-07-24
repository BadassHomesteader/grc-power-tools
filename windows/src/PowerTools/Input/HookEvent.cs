namespace PowerTools.Input;

public enum DictationCommand { Dictate, Ai }
public enum WindowMove { Left, Right, Up, Down, Maximize }

/// <summary>
/// Events raised by the global hook — the Windows mirror of HotkeyMonitor.Callback.
/// Mac callbacks with native Windows behavior are deliberately absent:
/// cycleWindow* (Alt-Tab), finderOpen/synthKey remaps (Explorer), newDoc
/// (Explorer's New menu), activityMonitor (Ctrl+Shift+Esc).
/// </summary>
public abstract record HookEvent
{
    public sealed record Down : HookEvent;
    public sealed record Up(DictationCommand Command) : HookEvent;
    public sealed record Cancel : HookEvent;
    public sealed record Ocr : HookEvent;                       // hold + T
    public sealed record ReadAloud : HookEvent;                 // hold + R
    public sealed record Screenshot : HookEvent;                // hold + S
    public sealed record Search : HookEvent;                    // hold + G
    public sealed record FileCopy : HookEvent;                  // hold + C
    public sealed record FileCut : HookEvent;                   // hold + X
    public sealed record FilePaste : HookEvent;                 // hold + V
    public sealed record Window(WindowMove Move) : HookEvent;   // hold + arrows / Enter
    public sealed record WindowEnd : HookEvent;
    public sealed record Grid : HookEvent;                      // hold + 3
    public sealed record WindowPalette : HookEvent;             // hold + W
    public sealed record AdvancedPaste : HookEvent;             // hold + P
    public sealed record ClipboardHistory : HookEvent;          // hold + H
    public sealed record QuickCapture(string ConnectionId) : HookEvent;
    public sealed record FindMouse : HookEvent;                 // hold + M
    public sealed record ColorPicker : HookEvent;               // hold + K
    public sealed record MacroPad : HookEvent;                  // hold + B
    public sealed record MacroPadDigit(int Index) : HookEvent;  // hold + 1…9/0 while pad shown
    public sealed record AgentPad : HookEvent;                  // hold + J
    public sealed record CheatSheet : HookEvent;                // hold + Q
    public sealed record CheatSheetClose : HookEvent;
    public sealed record PowerRing : HookEvent;                 // hold + right-click
    public sealed record PowerRingClose : HookEvent;
}
