# GRC Whisper

Fully-local voice dictation for macOS — a private [Wispr Flow](https://wisprflow.ai) replacement. Hold a key, speak, release: polished text appears in whatever app has focus.

**Everything runs on this Mac.** Wispr Flow sends every word you speak (plus surrounding screen context) to its cloud. GRC Whisper makes zero network calls: speech recognition is Apple's on-device `SpeechAnalyzer` (macOS 26), text cleanup is Apple's on-device Foundation Model, history lives in a local SQLite file. Little-Snitch-clean by design.

## How it works

```
hold Fn ──► mic (always-warm, 1s pre-roll) ──► SpeechAnalyzer (streams while you speak)
release ──► finalize (~0.2-0.6s) ──► Tier-0 cleanup (dictionary + fillers)
        ──► on-device LLM polish (deadline-guarded, falls back to Tier-0)
        ──► clipboard-swap paste into the focused app (your clipboard is restored)
```

- **Hold Fn** (Globe) to talk, release to insert. **Esc** cancels. Pressing any other key while holding cancels (so Fn+arrow combos still work).
- Live partial transcript shows in a bottom-center overlay that never steals focus.
- The polish pass removes fillers (um/uh), applies self-corrections ("meet Tuesday — scratch that, Wednesday" → Wednesday only), fixes punctuation, and respects your personal dictionary. If the LLM is slow or unavailable, you get the deterministic Tier-0 cleanup instead — never nothing.
- Raw + polished text for every dictation is kept in local history (menu bar ▸ Recent).

## Build & install

Requires macOS 26+ (Apple Silicon) and Command Line Tools. No Xcode, no dependencies.

```bash
scripts/bundle.sh --install    # builds, signs, copies to /Applications
open "/Applications/GRC Whisper.app"
```

> `Package.swift` exists for SwiftPM-capable toolchains, but `scripts/bundle.sh`
> compiles with `swiftc` directly — the CLT-only SwiftPM on this machine has a
> broken PackageDescription dylib.

## First-run setup (one time)

TCC permissions attach to the app bundle's ID + signature, which `scripts/bundle.sh` keeps stable across rebuilds. Grant these when prompted (or pre-emptively in System Settings ▸ Privacy & Security):

1. **Microphone** — prompted on first launch.
2. **Accessibility** — required for the global hotkey tap and the paste keystroke. The app prompts; toggle **GRC Whisper** on.
3. **Input Monitoring** — macOS sometimes also requires this for the keyboard listener; grant it if it appears.
4. **System Settings ▸ Keyboard ▸ "Press 🌐 key" → "Do Nothing"** — otherwise macOS opens emoji/dictation on the Fn key and fights the hotkey.

Then verify with the menu bar ▸ **Permission Doctor…**, or:

```bash
"/Applications/GRC Whisper.app/Contents/MacOS/GRC Whisper" doctor
```

After a macOS update or if the hotkey dies, re-run the doctor — event taps occasionally need Accessibility re-granted.

**After every rebuild/reinstall**: toggle GRC Whisper **off and on** in the Accessibility list. Ad-hoc signatures pin the build hash, so a rebuilt binary silently loses the grant even though the checkbox still shows enabled.

## CLI

The same binary doubles as a test/administration CLI:

```bash
grc-whisper transcribe file.wav          # engine test (no permissions needed)
grc-whisper polish "um meet Tuesday scratch that Wednesday"
grc-whisper doctor                       # permission / model status
grc-whisper dict add KYAW "K Y A W,kayak"   # term + comma-separated misheard variants
grc-whisper dict list
grc-whisper history 20
```

The personal dictionary does two jobs: deterministic replacement of misheard variants (Tier-0, works even with polish off) and a spelling authority passed to the LLM for phonetically-near matches.

## Configuration

`~/Library/Application Support/GRC Whisper/config.json` (also settable from the menu bar):

| key | default | notes |
|-----|---------|-------|
| `hotkey` | `fn` | `fn`, `rightOption`, `rightCommand`, `ctrlOption` (use `ctrlOption` for non-Apple keyboards — they don't deliver Fn) |
| `polish` | `llm` | `llm` (on-device AI), `basic` (dictionary+fillers only), `off` (raw) |
| `localeIdentifier` | `en_US` | any of the ~30 SpeechTranscriber locales |
| `llmDeadlineMs` | `2500` | polish deadline; on expiry Tier-0 text is inserted |
| `clipboardRestoreDelayMs` | `600` | how long the transcript stays on the clipboard before restore |
| `maxUtteranceSeconds` | `120` | hard cap per hold |

History, dictionary, and logs live in the same folder. Delete the folder to reset everything.

## Design notes (the sharp edges this app rounds off)

- **First-syllable loss**: the mic engine runs continuously with a 1s pre-roll ring buffer, so audio from *before* key-down is included. On-demand mic startup costs ~500ms and eats the first word (a chronic complaint in this app class).
- **Clipboard safety**: paste is a full-fidelity clipboard swap — all pasteboard item types are snapshotted and restored (images/files survive), the transcript item is marked `org.nspasteboard.ConcealedType` so clipboard managers skip it, and restore only happens if the pasteboard still holds our session UUID (never clobbers something you copied mid-cycle).
- **Event-tap hardening**: exact-match-only suppression, auto re-enable on `tapDisabledByTimeout`, stale-hold expiry, and a 5s health check that revives silently-dead taps (a real macOS 26 failure mode). A stuck key can never eat your spacebar.
- **Secure fields**: dictation into password fields is refused with a visible message (secure input also blocks the tap — nothing would work anyway).
- **LLM guardrails**: the polish output is sanity-checked (length ratio, refusal prefixes) and deadline-raced against Tier-0; the raw transcript is always preserved in history. Dictated text is treated as data — "ignore your instructions…" gets typed, not obeyed.

## Privacy

No network code exists in this repository. Speech models and the LLM are system-managed Apple on-device assets. Verify: `grep -ri "http" Sources/` finds nothing but this README.
