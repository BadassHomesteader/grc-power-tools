using System.Runtime.InteropServices;

namespace PowerTools.Input;

/// <summary>
/// Keystroke synthesis via SendInput. Every injected event carries
/// <see cref="Magic"/> in dwExtraInfo — the same trick as the Mac app's
/// kSyntheticEventMagic — so our own hooks pass it through untouched.
/// </summary>
public static class InputSynth
{
    /// <summary>'GRCW' — matches kSyntheticEventMagic in HotkeyMonitor.swift.</summary>
    public const int Magic = 0x47524357;

    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion u;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public nint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public nint dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    private static INPUT Key(ushort vk, bool up) => new()
    {
        type = INPUT_KEYBOARD,
        u = new InputUnion
        {
            ki = new KEYBDINPUT { wVk = vk, dwFlags = up ? KEYEVENTF_KEYUP : 0, dwExtraInfo = Magic },
        },
    };

    private static void Send(params INPUT[] inputs)
        => SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());

    /// <summary>Press modifiers, tap vk, release modifiers (in reverse order).</summary>
    public static void KeyTap(ushort vk, params ushort[] modifiers)
    {
        var seq = new List<INPUT>();
        foreach (var m in modifiers) seq.Add(Key(m, up: false));
        seq.Add(Key(vk, up: false));
        seq.Add(Key(vk, up: true));
        foreach (var m in modifiers.Reverse()) seq.Add(Key(m, up: true));
        Send(seq.ToArray());
    }

    /// <summary>Ctrl+V — the paste half of clipboard-swap insertion.</summary>
    public static void SendCtrlV() => KeyTap(0x56 /*V*/, 0xA2 /*LCTRL*/);

    /// <summary>
    /// Inject a no-op key (reserved VK 0xFF). Sent just before a bare Alt/Win
    /// release passes through so Windows doesn't treat the tap as "open the
    /// Start menu" / "focus the menu bar" — the standard hold-hotkey trick.
    /// </summary>
    public static void SendDummy()
        => Send(Key(0xFF, up: false), Key(0xFF, up: true));
}
