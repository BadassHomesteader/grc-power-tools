# Monday hands-on checklist (first run on a real Windows machine)

Everything below is the part CI and macOS testing CANNOT cover — interactive
input, focus, and audio. Data layer, config parity, Tier-0 polish, and the
Parakeet ASR engine are already machine-verified.

## Get the build

Either grab the `PowerTools-win-x64` artifact from the latest green
[windows workflow run](../../actions/workflows/windows.yml) and run
`PowerTools.exe`, or build from source:

    dotnet run --project windows/src/PowerTools

## 1. First launch (~2 min)

- [ ] Tray icon appears with the Power Tools icon; double-click opens Settings
- [ ] `%APPDATA%\GRC Whisper\` created with config.json + grc-whisper.log
- [ ] Log shows `hotkey: listening for OptionShift` and `audio: warm capture started`
- [ ] Parakeet model download kicks off in the log (~700 MB — let it finish)

## 2. Dictation (the flagship — ~10 min)

- [ ] Hold **Alt+Shift**, speak, release → text pastes into Notepad
- [ ] Overlay pill shows bottom-center: "● Listening…" with a moving level bar,
      then "Transcribing…"; focus NEVER leaves Notepad
- [ ] Same into Word, Chrome (Gmail compose), Windows Terminal
- [ ] Copy something first → dictate → paste again (Ctrl+V) → your ORIGINAL
      clipboard is back (clipboard-swap restore)
- [ ] Dictated text does NOT appear in Win+V history (concealed formats)
- [ ] Tap Alt+Shift briefly (<250 ms) → nothing happens (min-hold guard)
- [ ] Hold and press Esc mid-speech → cancels, nothing pastes
- [ ] Quick sanity: does a bare Alt+Shift tap flip your input language? If you
      have one keyboard layout only, it won't. Note behavior either way.

## 3. Hook edge cases (~5 min)

- [ ] While holding the hotkey, press an unrelated key (e.g. F5) → dictation
      cancels, the key reaches the app
- [ ] Leader chords log correctly (check grc-whisper.log): hold + T / W / 3 /
      arrows each log their event ("not yet implemented" is expected for most)
- [ ] Alt-tapping alone does NOT pop the window menu bar (dummy-key guard)
- [ ] Focus an elevated window (Task Manager run as admin) → hotkey silent
      there, works again after switching away — expected, note it
- [ ] Settings → change hotkey to Right Alt → restart app → Right Alt works,
      and the key no longer types/behaves as AltGr anywhere else

## 4. Settings & startup (~3 min)

- [ ] "Launch at sign-in" checkbox → sign out/in (or check
      HKCU\...\Run has "GRC Power Tools") → app auto-starts
- [ ] Settings hotkey change persists in config.json (`hotkey` key)
- [ ] Kill the app from Task Manager → relaunch → config intact

## 5. Parity spot-check (~2 min, optional)

- [ ] Copy your Mac `~/Library/Application Support/GRC Whisper/config.json`
      into `%APPDATA%\GRC Whisper\` → relaunch → your hotkey/settings apply,
      dictionary terms correct transcripts (say "kayak" → "KYAW" if that
      variant is in your dictionary)

## Known-expected rough edges (don't file these)

- Window management / pads / clipboard history chords log
  "not yet implemented" — Phases 3–5
- `polish: "apple"` runs basic cleanup (no on-device LLM on Windows);
  set a Claude key in keys.json (`{"claude": "sk-..."}`) for AI polish
- No audio ducking yet (muteWhileDictating is a no-op so far)
- Dictating before the model download finishes shows
  "Speech model still downloading…" and drops that utterance
