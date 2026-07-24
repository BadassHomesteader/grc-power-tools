using System.Runtime.InteropServices;
using PowerTools.Core;

namespace PowerTools.Input;

/// <summary>
/// Global push-to-talk hotkey via WH_KEYBOARD_LL + WH_MOUSE_LL — the Windows
/// mirror of HotkeyMonitor.swift, keeping its hardening rules:
/// - suppress ONLY exact hotkey/leader events, never anything else
/// - stale-hold expiry so a missed key-up can never wedge the state machine
/// - a non-hotkey keypress during a hold cancels dictation
/// - paired key-ups of consumed keys are swallowed (no orphan reaches apps)
/// - our own synthesized input (dwExtraInfo magic) passes through untouched
///
/// Modifier mapping from the Mac config values: Option → Alt, Command → Win.
/// Known Windows-only caveats, by design (documented, not fought):
/// - the hook sees nothing while a UAC-elevated window has focus
/// - "optionShift" (Alt+Shift) collides with the input-language switch if
///   multiple layouts are installed — disable that hotkey or pick another combo
/// - "fn" has no VK on PC keyboards; it falls back to Alt+Shift with a log line
/// </summary>
public sealed class KeyboardHook : IDisposable
{
    // ---- Win32 ----

    private const int WH_KEYBOARD_LL = 13;
    private const int WH_MOUSE_LL = 14;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const int WM_RBUTTONDOWN = 0x0204;
    private const int WM_RBUTTONUP = 0x0205;

    private const int VK_ESCAPE = 0x1B;
    private const int VK_RETURN = 0x0D;
    private const int VK_LEFT = 0x25;
    private const int VK_UP = 0x26;
    private const int VK_RIGHT = 0x27;
    private const int VK_DOWN = 0x28;
    private const int VK_LSHIFT = 0xA0;
    private const int VK_RSHIFT = 0xA1;
    private const int VK_LCONTROL = 0xA2;
    private const int VK_RCONTROL = 0xA3;
    private const int VK_LMENU = 0xA4;   // left Alt
    private const int VK_RMENU = 0xA5;   // right Alt
    private const int VK_LWIN = 0x5B;
    private const int VK_RWIN = 0x5C;

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public nint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public int ptX;
        public int ptY;
        public uint mouseData;
        public uint flags;
        public uint time;
        public nint dwExtraInfo;
    }

    private delegate nint HookProc(int nCode, nint wParam, nint lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetWindowsHookExW(int idHook, HookProc lpfn, nint hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(nint hhk);

    [DllImport("user32.dll")]
    private static extern nint CallNextHookEx(nint hhk, int nCode, nint wParam, nint lParam);

    [DllImport("user32.dll")]
    private static extern int GetMessageW(out MSG lpMsg, nint hWnd, uint min, uint max);

    [DllImport("user32.dll")]
    private static extern bool PostThreadMessageW(uint idThread, uint msg, nint wParam, nint lParam);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public nint hwnd;
        public uint message;
        public nint wParam;
        public nint lParam;
        public uint time;
        public int ptX;
        public int ptY;
    }

    private const uint WM_QUIT = 0x0012;

    // ---- state (all touched only on the hook thread, except the flags below) ----

    private readonly Config.Hotkey _hotkey;
    private readonly Action<HookEvent> _dispatch;   // marshals to the UI thread
    private nint _keyboardHook;
    private nint _mouseHook;
    private HookProc? _keyboardProc;                // rooted so the GC never collects the delegate
    private HookProc? _mouseProc;
    private Thread? _thread;
    private uint _threadId;
    private System.Threading.Timer? _staleTimer;

    private volatile bool _held;
    private DateTime _heldSince;
    private bool _interrupted;
    private bool _windowMode;
    private bool _ringSwallowUp;
    private readonly HashSet<int> _swallowedKeyUps = new();
    private readonly HashSet<int> _keysDown = new();   // repeat detection: LL hooks have no repeat flag

    private enum Pending
    {
        None, Ocr, ReadAloud, Ai, Screenshot, Search, FileCopy, FileCut, FilePaste,
        AdvancedPaste, ClipboardHistory, FindMouse, ColorPicker, QuickCapture,
    }
    private Pending _pending = Pending.None;
    private string _pendingConnectionId = "";

    // Flags set from the UI thread, read on the hook thread — same plain-bool
    // discipline as the Mac tap (a torn read is impossible for a bool).
    public volatile bool MacroPadVisible;
    public volatile bool CheatSheetVisible;
    public volatile bool PowerRingEnabled = true;
    public volatile bool PowerRingVisible;
    public volatile int MacroPadButtonCount;

    private Dictionary<int, string> _connectionLeaders = new();
    private readonly object _leadersLock = new();

    /// <summary>Quick Capture leaders: VK → connection id (letters map to their ASCII VK).</summary>
    public void SetConnectionLeaders(Dictionary<int, string> map)
    {
        lock (_leadersLock) _connectionLeaders = new(map);
    }

    private string? ConnectionLeader(int vk)
    {
        lock (_leadersLock) return _connectionLeaders.TryGetValue(vk, out var id) ? id : null;
    }

    /// <summary>VK for an A–Z leader letter (null otherwise) — letters ARE their VK on Windows.</summary>
    public static int? VkForLetter(string letter)
    {
        var ch = letter.Trim().ToUpperInvariant();
        return ch.Length == 1 && ch[0] is >= 'A' and <= 'Z' ? ch[0] : null;
    }

    /// <summary>VK → macro pad button index for the digit row (1…9 then 0 = tenth).</summary>
    private static int? MacroDigitIndex(int vk) => vk switch
    {
        >= 0x31 and <= 0x39 => vk - 0x31,   // 1..9 → 0..8
        0x30 => 9,                          // 0 → tenth button
        _ => null,
    };

    public KeyboardHook(Config.Hotkey hotkey, Action<HookEvent> dispatch)
    {
        if (hotkey == Config.Hotkey.Fn)
        {
            Logger.Log("hotkey: 'fn' has no Windows key — falling back to Alt+Shift (optionShift)");
            hotkey = Config.Hotkey.OptionShift;
        }
        _hotkey = hotkey;
        _dispatch = dispatch;
    }

    public bool Start()
    {
        var ready = new ManualResetEventSlim();
        var ok = false;
        _thread = new Thread(() =>
        {
            _threadId = GetCurrentThreadId();
            _keyboardProc = KeyboardCallback;
            _mouseProc = MouseCallback;
            _keyboardHook = SetWindowsHookExW(WH_KEYBOARD_LL, _keyboardProc, nint.Zero, 0);
            _mouseHook = SetWindowsHookExW(WH_MOUSE_LL, _mouseProc, nint.Zero, 0);
            ok = _keyboardHook != nint.Zero;
            ready.Set();
            if (!ok) return;
            while (GetMessageW(out _, nint.Zero, 0, 0) > 0) { }
            if (_keyboardHook != nint.Zero) UnhookWindowsHookEx(_keyboardHook);
            if (_mouseHook != nint.Zero) UnhookWindowsHookEx(_mouseHook);
        })
        { Name = "grc-whisper.hotkey", IsBackground = true };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
        ready.Wait(TimeSpan.FromSeconds(5));

        if (!ok)
        {
            Logger.Log("hotkey: SetWindowsHookEx FAILED");
            return false;
        }

        // Stale-hold expiry, same 150s rule as the Mac tap's health timer.
        _staleTimer = new System.Threading.Timer(_ =>
        {
            if (_held && DateTime.UtcNow - _heldSince > TimeSpan.FromSeconds(150))
            {
                Logger.Log("hotkey: stale hold (>150s), forcing cancel");
                _held = false;
                _interrupted = false;
                _windowMode = false;
                _pending = Pending.None;
                _swallowedKeyUps.Clear();
                _dispatch(new HookEvent.Cancel());
            }
        }, null, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));

        Logger.Log($"hotkey: listening for {_hotkey}");
        return true;
    }

    public void Dispose()
    {
        _staleTimer?.Dispose();
        if (_threadId != 0) PostThreadMessageW(_threadId, WM_QUIT, 0, 0);
    }

    // ---- mouse: leader + right-click = Power Ring ----

    private nint MouseCallback(int nCode, nint wParam, nint lParam)
    {
        if (nCode < 0) return CallNextHookEx(_mouseHook, nCode, wParam, lParam);
        var info = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
        if (info.dwExtraInfo == InputSynth.Magic)
            return CallNextHookEx(_mouseHook, nCode, wParam, lParam);

        switch ((int)wParam)
        {
            case WM_RBUTTONDOWN when _held && PowerRingEnabled:
                // Swallow the down so no context menu opens underneath, and its
                // paired up; windowMode makes the leader release end quietly.
                _windowMode = true;
                _ringSwallowUp = true;
                _dispatch(new HookEvent.PowerRing());
                return 1;
            case WM_RBUTTONUP when _ringSwallowUp:
                _ringSwallowUp = false;
                return 1;
        }
        return CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    // ---- keyboard ----

    private nint KeyboardCallback(int nCode, nint wParam, nint lParam)
    {
        if (nCode < 0) return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
        var info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        if (info.dwExtraInfo == InputSynth.Magic)
            return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);

        var msg = (int)wParam;
        var vk = (int)info.vkCode;
        var isDownMsg = msg is WM_KEYDOWN or WM_SYSKEYDOWN;
        var isUpMsg = msg is WM_KEYUP or WM_SYSKEYUP;
        if (!isDownMsg && !isUpMsg)
            return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);

        // LL hooks carry no auto-repeat flag; a down for a key already down is one.
        var isRepeat = isDownMsg && _keysDown.Contains(vk);
        if (isDownMsg) _keysDown.Add(vk);
        if (isUpMsg) _keysDown.Remove(vk);

        var swallow = Handle(vk, isDownMsg, isRepeat);
        return swallow ? 1 : CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
    }

    /// <summary>Returns true to swallow the event.</summary>
    private bool Handle(int vk, bool isDown, bool isRepeat)
    {
        // -- hotkey engage/release --
        switch (_hotkey)
        {
            case Config.Hotkey.RightOption:   // Right Alt — single key, fully suppressed like Fn on Mac
                if (vk == VK_RMENU) return HandleSingleKeyHotkey(isDown, isRepeat);
                break;
            case Config.Hotkey.RightCommand:  // Right Win — suppressed, so Start never fires
                if (vk == VK_RWIN) return HandleSingleKeyHotkey(isDown, isRepeat);
                break;
            case Config.Hotkey.CtrlOption:    // Ctrl+Alt (AltGr counts — international keyboards beware)
                if (IsModifier(vk)) { HandleComboChange(ModDown(VK_LCONTROL, VK_RCONTROL) && ModDown(VK_LMENU, VK_RMENU)); }
                break;
            case Config.Hotkey.ShiftCommand:  // Shift+Win
                if (IsModifier(vk)) { HandleComboChange(ModDown(VK_LSHIFT, VK_RSHIFT) && ModDown(VK_LWIN, VK_RWIN)); }
                break;
            case Config.Hotkey.OptionShift:   // Alt+Shift — default
            default:
                if (IsModifier(vk)) { HandleComboChange(ModDown(VK_LMENU, VK_RMENU) && ModDown(VK_LSHIFT, VK_RSHIFT)); }
                break;
        }

        // -- leader chords while the hotkey is held --
        if (_held && isDown)
            return HandleLeader(vk, isRepeat);

        // Swallow the paired keyUp of any key we consumed mid-hold — not gated
        // on _held, so a key still down at hotkey release has its up swallowed.
        if (!isDown && _swallowedKeyUps.Remove(vk))
            return true;

        return false;
    }

    private static bool IsModifier(int vk) => vk is VK_LSHIFT or VK_RSHIFT or VK_LCONTROL or VK_RCONTROL
        or VK_LMENU or VK_RMENU or VK_LWIN or VK_RWIN;

    private bool ModDown(int left, int right) => _keysDown.Contains(left) || _keysDown.Contains(right);

    /// <summary>Right Alt / Right Win as the hotkey: events suppressed entirely.</summary>
    private bool HandleSingleKeyHotkey(bool isDown, bool isRepeat)
    {
        if (isRepeat) return true;   // held key repeats must not re-engage
        HotkeyFlag(isDown);
        return true;
    }

    private void HandleComboChange(bool bothDown)
    {
        // Combos are never suppressed: plain modifiers must keep working for
        // normal chords (same rule as the Mac ctrlOption/optionShift paths).
        if (bothDown != _held) HotkeyFlag(bothDown);
    }

    private void HotkeyFlag(bool isDown)
    {
        if (isDown && !_held)
        {
            _held = true;
            _heldSince = DateTime.UtcNow;
            _interrupted = false;
            _pending = Pending.None;
            _windowMode = false;
            _dispatch(new HookEvent.Down());
        }
        else if (!isDown && _held)
        {
            _held = false;
            var p = _pending;
            var connId = _pendingConnectionId;
            _pending = Pending.None;
            _pendingConnectionId = "";
            var wasWindow = _windowMode;
            _windowMode = false;

            // A bare Alt/Win tap opens the menu bar / Start menu on release;
            // neutralize it with a no-op keystroke before ours passes through.
            if (_hotkey is Config.Hotkey.OptionShift or Config.Hotkey.CtrlOption or Config.Hotkey.ShiftCommand)
                InputSynth.SendDummy();

            if (wasWindow)
            {
                _dispatch(new HookEvent.WindowEnd());
            }
            else if (!_interrupted)
            {
                _dispatch(p switch
                {
                    Pending.None => new HookEvent.Up(DictationCommand.Dictate),
                    Pending.Ai => new HookEvent.Up(DictationCommand.Ai),
                    Pending.Ocr => new HookEvent.Ocr(),
                    Pending.ReadAloud => new HookEvent.ReadAloud(),
                    Pending.Screenshot => new HookEvent.Screenshot(),
                    Pending.Search => new HookEvent.Search(),
                    Pending.FileCopy => new HookEvent.FileCopy(),
                    Pending.FileCut => new HookEvent.FileCut(),
                    Pending.FilePaste => new HookEvent.FilePaste(),
                    Pending.AdvancedPaste => new HookEvent.AdvancedPaste(),
                    Pending.ClipboardHistory => new HookEvent.ClipboardHistory(),
                    Pending.FindMouse => new HookEvent.FindMouse(),
                    Pending.ColorPicker => new HookEvent.ColorPicker(),
                    Pending.QuickCapture => new HookEvent.QuickCapture(connId),
                    _ => (HookEvent)new HookEvent.Cancel(),
                });
            }
            _interrupted = false;
        }
    }

    /// <summary>A keydown while the hotkey is held. Returns true to swallow.</summary>
    private bool HandleLeader(int vk, bool isRepeat)
    {
        // Macro pad digits: while the pad is shown, a digit with a real button
        // fires it; unmapped digits keep their normal meaning.
        if (MacroPadVisible && MacroDigitIndex(vk) is { } idx && idx < MacroPadButtonCount)
        {
            _windowMode = true;
            _swallowedKeyUps.Add(vk);
            if (!isRepeat) _dispatch(new HookEvent.MacroPadDigit(idx));
            return true;
        }

        bool Arm(Pending p)
        {
            _pending = p;
            _swallowedKeyUps.Add(vk);
            return true;
        }
        bool Toggle(HookEvent e)
        {
            // Toggles fire immediately; release just ends the session. Auto-
            // repeat swallowed but not dispatched (a held B must not re-toggle).
            _windowMode = true;
            _swallowedKeyUps.Add(vk);
            if (!isRepeat) _dispatch(e);
            return true;
        }
        bool ArmConnection(int key)
        {
            if (ConnectionLeader(key) is not { } id) return false;
            _pending = Pending.QuickCapture;
            _pendingConnectionId = id;
            _swallowedKeyUps.Add(vk);
            return true;
        }

        switch (vk)
        {
            case VK_ESCAPE:
                _interrupted = true;
                _swallowedKeyUps.Add(vk);
                if (CheatSheetVisible) _dispatch(new HookEvent.CheatSheetClose());
                if (PowerRingVisible) _dispatch(new HookEvent.PowerRingClose());
                _dispatch(new HookEvent.Cancel());
                return true;
            case 'T': return Arm(Pending.Ocr);
            case 'R': return ArmConnection(vk) || Arm(Pending.ReadAloud);
            case 'A': return Arm(Pending.Ai);
            case 'S': return Arm(Pending.Screenshot);
            case 'G': return Arm(Pending.Search);
            case 'C': return Arm(Pending.FileCopy);
            case 'X': return Arm(Pending.FileCut);
            case 'V': return Arm(Pending.FilePaste);
            case 'P': return Arm(Pending.AdvancedPaste);
            case 'H': return Arm(Pending.ClipboardHistory);
            case 'M': return Arm(Pending.FindMouse);
            case 'K': return Arm(Pending.ColorPicker);
            // 'D' (new document) is Mac-only — Explorer's New menu is native.
            case 'B': return ArmConnection(vk) || Toggle(new HookEvent.MacroPad());
            case 'J': return ArmConnection(vk) || Toggle(new HookEvent.AgentPad());
            case 'Q': return ArmConnection(vk) || Toggle(new HookEvent.CheatSheet());
            case '3': return Toggle(new HookEvent.Grid());
            case 'W': return Toggle(new HookEvent.WindowPalette());
            case VK_LEFT or VK_RIGHT or VK_UP or VK_DOWN or VK_RETURN:
                // Window moves fire immediately and repeat while held (tap ←←
                // to shrink); release then just ends the session.
                _windowMode = true;
                _swallowedKeyUps.Add(vk);
                _dispatch(new HookEvent.Window(vk switch
                {
                    VK_LEFT => WindowMove.Left,
                    VK_RIGHT => WindowMove.Right,
                    VK_UP => WindowMove.Up,
                    VK_DOWN => WindowMove.Down,
                    _ => WindowMove.Maximize,
                }));
                return true;
            default:
                if (IsModifier(vk)) return false;   // the hotkey's own modifiers
                if (ArmConnection(vk)) return true; // user-assigned leader (e.g. +N)
                // During a window session other keys pass through (digits reach
                // the palette) and must NOT dispatch a racing cancel.
                if (_windowMode) return false;
                _interrupted = true;
                _dispatch(new HookEvent.Cancel());
                return false;   // unrelated combo passes through, like the Mac tap
        }
    }
}
