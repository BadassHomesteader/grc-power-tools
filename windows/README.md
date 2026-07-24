# Power Tools for Windows

The Windows build of GRC Power Tools — one app, same behavior on every machine.
C# / .NET 8 / WPF, living beside the macOS Swift app in this repo.

## Parity contract

The Windows and macOS apps share their data formats byte-for-byte:

- `config.json` — same keys, same enum raw values, same defaults, same lenient
  per-field decode, sorted-keys save (`Core/Config.cs` ↔ `Sources/PowerTools/Config.swift`)
- `grc-whisper.sqlite` — same tables, columns, and trim limits
  (`Core/Store.cs` ↔ `Sources/PowerTools/Store.swift`)
- `keys.json` — same account-key layout (`Core/SecretsStore.cs` ↔ `Keychain.swift`)

Data folder: `%APPDATA%\GRC Whisper\` (mirrors `~/Library/Application Support/GRC Whisper/`).
Mac-only settings (`finderEnterOpens`, `keyHomeEnd`, …) are preserved on load/save
and ignored at runtime — Explorer already behaves that way.

**Any schema change must land in both apps in the same commit.**

## Key mapping

Config hotkey values translate Option → Alt, Command → Win:

| config.json value | macOS | Windows |
|---|---|---|
| `optionShift` (default) | Option+Shift | Alt+Shift |
| `rightOption` | Right Option | Right Alt |
| `rightCommand` | Right Command | Right Win |
| `ctrlOption` | Control+Option | Ctrl+Alt |
| `shiftCommand` | Shift+Command | Shift+Win |
| `fn` | Globe/Fn | (no PC key — falls back to Alt+Shift) |

Leader chords (hold + T/R/A/S/G/C/X/V/P/H/M/K/B/J/Q/3/W/arrows/Enter/right-click)
match the Mac cheat sheet. Not ported because Windows does it natively:
Enter-opens/F2-renames, New ▸ document templates, Home/End, Ctrl+Shift+Esc,
window-MRU Alt-Tab.

## Build

On Windows:

    dotnet run --project src/PowerTools

On macOS/Linux (compile check only — WPF can't run here; `EnableWindowsTargeting`
makes the build work):

    dotnet build windows/PowerTools.Windows.sln

## Phase status

| Phase | Status |
|---|---|
| 1. Core infra (tray, hook, config, store, settings shell) | **this code** |
| 2. Dictation (WASAPI + sherpa-onnx Parakeet + inserter + overlay) | pending |
| 3. Window management suite | pending |
| 4. Clipboard history + Advanced Paste | pending |
| 5. Pads (Macro Pad, Power Ring, Quick Capture, cheat sheet) | pending |
| 6. Capture & misc (OCR, color picker, find mouse, read aloud) | pending |
| 7. Agent Pad + Claude Code bridge | pending |
| 8. Packaging (signing, installer, winget) | pending |

## Known limitations (by design)

- Low-level hooks see nothing while a UAC-elevated window has focus — the
  hotkey goes quiet there (Windows' version of the macOS TCC quirks).
- Alt+Shift collides with the input-language switch when several keyboard
  layouts are installed; pick another combo or remove that Windows hotkey.
- Polish has no on-device Apple-Intelligence equivalent — `polish: "apple"` in
  config runs the basic cleanup tier on Windows until a local backend lands.
