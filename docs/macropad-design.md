# Hardware Macro Pad for Claude Code — Design Review

*2026-07-15 · Inspired by OpenAI's Codex Micro announcement ([video](https://www.youtube.com/watch?v=m8uUUUsMD3Y), a Work Louder macropad for Codex, $230 limited drop at openai.com/supply)*

## What the Codex Micro does (from the launch video)

| Capability | How the Micro does it |
|---|---|
| Voice dictation into the agent | Hold a key, talk; prompt appears without touching the laptop keyboard |
| Skills / Plan mode | Analog stick swipes mapped to common skills; swipe up = Plan mode |
| Reasoning effort | Rotary dial switches quick task ↔ deep reasoning |
| Task switching | Each pinned task maps to a key; click to switch |
| Attention at a glance | Six frosted "Agent Keys" light per status: idle / thinking / complete / needs-input / error |
| Surface the app | Double-tap when the app is backgrounded |
| Permission requests | Switch to task, press Accept |
| Queue follow-up work | Hold voice again while a task runs |
| Customization | All controls remappable (skills, create PR, etc.) |

Every one of these is reproducible for **Claude Code** with Power Tools as the hub — and with a Stream Deck's LCD keys the status feedback can be *richer* than the Micro's RGB.

## What Power Tools already has

Roughly half the system exists today:

| Codex Micro piece | Existing Power Tools module |
|---|---|
| Voice → prompt | Dictation pipeline (`AudioCapture`, `Transcriber`, `Polisher`) |
| Action-per-key model | `MacroButton` (chord/text/return) + `MacroProfile` per-app profiles in `Config.swift` |
| HTTP actions | `Connection` model + `CloudPolish.postCapture` (Quick Capture) |
| Keystroke output | `Inserter` (CGEvent synthesis, synthetic-event tagging) |
| Hold/leader trigger engine | `HotkeyMonitor` (CGEventTap, hold-leader + digits) |
| On-screen macro pad | `MacroPad.swift` floating panel — the software twin of this feature |
| Settings pane pattern | `SettingsWindow` sidebar sections (`connectionsTab` / `macroPadTab` as templates) |

What does **not** exist: any HID/IOKit code (device attribution is greenfield), and any awareness of Claude Code sessions.

## Architecture: three layers

### 1. Claude Code control plane (no hardware required — this is the core)

Claude Code exposes everything needed via hooks + terminal input:

- **Session registry** — Power Tools runs a localhost HTTP server (e.g. `127.0.0.1:8377`). A `SessionStart` command hook POSTs `{session_id, cwd, pid, $TMUX_PANE, tty}` (command hooks inherit the session env); `SessionEnd` removes it. This maps every session to a tmux pane / iTerm2 session / Terminal tab via tty triangulation.
- **Attention states** — `Notification` hooks (`permission_prompt`, `idle_prompt`, `agent_needs_input`, `agent_completed`), `Stop` (idle), `StopFailure` (error, has `error_type`), `UserPromptSubmit` (busy). Hooks natively support `"type": "http"` handlers — no curl wrappers.
- **Remote permission Accept/Deny — zero keystrokes** — the `PermissionRequest` hook POSTs the pending request and Power Tools' HTTP *response* decides it: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`. Returning no decision falls through to the normal TUI dialog, so the app is a pass-through that only intervenes when a pad key is pressed. Keep the endpoint fast; a dead endpoint stalls dialogs until hook timeout.
- **Prompt injection (dictation → session)** — best: `tmux send-keys -l '<text>'`, ~150 ms delay, then `Enter` as a separate call (one call can race bracketed-paste and not submit; confirm via the `UserPromptSubmit` hook). Fallbacks: iTerm2 `write text` (AppleScript/Python API), Terminal.app `do script in tab`, and CGEventPostToPid only as last resort (defeated by Secure Keyboard Entry).
- **Mode/effort controls** — Shift+Tab (`chat:cycleMode`) = `tmux send-keys BTab`; `Escape` interrupts; Option+T thinking, Option+O fast mode, Option/Meta+P model picker. `~/.claude/keybindings.json` is hot-reloaded and can host deterministic custom chords so injected keys are unambiguous across versions.
- **Focus a session** — tmux `switch-client`/`select-pane`, or iTerm2/Terminal AppleScript `select` + `activate`.

Prior art validating this exact stack: claude-control (tmux dashboard), AgentDeck (Stream Deck+ → coding agents), terminaldeck, happy-cli (owns the session via the Agent SDK — the upgrade path if managed sessions are ever wanted).

**Config safety:** installation must *surgically merge* the hook entries into `~/.claude/settings.json` — never rewrite the file. Hooks only run after workspace trust, and hook config loads at session start, so sessions started before install won't report.

### 2. Device input layer

Three tiers, cheapest-friction first:

- **Tier A — QMK/VIA pad on F13–F24 (zero TCC prompts).** A VIA-remapped pad (keys + encoder detents → F13–F24) is just a keyboard sending keys nothing else uses. `HotkeyMonitor`'s existing tap can consume them — no Input Monitoring, no new permissions. Ship this first.
- **Tier B — any spare keyboard as a macro pad (generic).** IOHIDManager listen-only on the chosen VID/PID device (Input Monitoring TCC) tracks which usages are down on *that* device; the existing active CGEventTap (Accessibility TCC, already required) swallows matching keycodes before they reach the foreground app. True seizure (`kIOHIDOptionsTypeSeizeDevice`) of keyboard-class devices is **root-gated in IOHIDFamily** — not available to a notarized Developer ID app — so listen+swallow is the correct MVP; a root `SMAppService` daemon is the only upgrade path and isn't worth the friction. Known edge cases: secure-input fields blind the tap (detect via `IsSecureEventInputEnabled()`, warn in menu bar); re-arm on `kCGEventTapDisabledByTimeout`; re-bind on hotplug by VID+PID+product string (serials often empty on cheap pads); Karabiner-Elements seizes all keyboards through its virtual device — detect it and guide the user to its ignored-devices list (or emit a `device_if` complex-modification instead).
- **Tier C — Elgato Stream Deck (visual feedback).** Not a keyboard: vendor HID, seizable without root and generally without Input Monitoring. Protocol (per-key JPEG upload, dial press/rotate, touch strip) is community-documented (den.dev write-ups; python-elgato-streamdeck as reference spec). No maintained macOS Swift lib exists (Elgato's StreamDeckKit is iPadOS-only; Codedeck is stale) — implement directly on IOHIDManager. The Elgato desktop app must not be running (device contention).

### 3. Action glue (mostly reuse)

A new `PadKey` mapping model (extend `MacroButton`/`MacroProfile`): key → action where action ∈ {focus session N, accept/deny permission, dictate-to-session (hold), inject canned prompt, cycle mode, interrupt, effort/model dial, existing macro actions}. Dispatch through the existing `AppController` switch; new `HotkeyMonitor.Callback` cases. Status out: menu-bar badge (Tier A/B) or painted LCD keys (Tier C). Settings pane follows `connectionsTab`/`macroPadTab` patterns.

## Hardware verdict

| Device | Price | Feedback | Protocol | Verdict |
|---|---|---|---|---|
| **Elgato Stream Deck +** | $179.99 | 8 LCD keys + touch strip + 4 push dials | Vendor HID, community-documented, no TCC | **Primary pick** — only sub-$200 device whose display we can fully drive; beats the Micro's RGB |
| **DOIO KB16 "Megalodon"** | ~$69–93 | 16 keys + 3 knobs + OLED, per-key RGB | QMK mainline; VIA → F13–F24 today; host-driven RGB needs custom firmware (`raw_hid_receive`, usage page 0xFF60) | **Budget pick** — works with Tier A on day one |
| OpenAI Codex Micro (Work Louder) | $230 | 6 status-lit Agent Keys, dial, joystick | Proprietary "Input" configurator; VIA/QMK unconfirmed; status-LED protocol undocumented | **Skip** for our own software — aesthetic inspiration only |
| Keychron Q0 Plus | ~$99 | knob, south-facing RGB (poor glanceability) | QMK/VIA | Backordered; RGB reads poorly through opaque caps |

## Packaging impact

- No new entitlements; no sandbox (already none). Hardened runtime unaffected.
- Tier A: zero new permissions. Tier B adds an Input Monitoring TCC prompt (`IOHIDRequestAccess`); there is no Info.plist usage-description key for it — onboarding UI + deep link to `Privacy_ListenEvent` needed. Accessibility is already requested at runtime.
- `scripts/bundle.sh` / `release.sh` unchanged; stable bundle ID keeps TCC grants across rebuilds (existing design).

## Phased plan (minimal first)

1. **Phase 1 — Claude Code control plane, no hardware.** Localhost server + surgical hooks installer + session registry + menu-bar attention states + `PermissionRequest` approve/deny + dictate-into-session via tmux (fallback iTerm2/Terminal). This alone reproduces most of the Codex Micro demo using existing hold-key hotkeys.
   **✅ Shipped in v1.19.0 as the Agent Pad** (hold hotkey + J): `ClaudeCodeBridge.swift` (loopback hook server + session registry + injector + hooks installer) and `AgentPad.swift` (floating session panel — status, focus, prompt/dictate, ⇧⇥ mode cycle, interrupt, approve/deny). Permission answers use the keystroke path (`Notification` hook + `y`/Esc) rather than the synchronous `PermissionRequest` gate.
2. **Phase 2 — Tier A pad support.** F13–F24 bindings in the existing tap; pad-key → session/action mapping UI; works with any VIA pad (KB16).
3. **Phase 3 — Stream Deck + module.** Direct HID; paint per-session status (color + project name + state icon); dials → effort/model/scroll.
4. **Later, only if demanded:** Tier B generic-keyboard engine; custom QMK raw-HID RGB for the KB16; managed sessions via Agent SDK (`--input-format stream-json`).

## Risks

- Claude Code TUI details (mode-cycle order, dialog options, notification types) move fast across releases — pin to documented keybinding actions + hook payloads, not screen-scraping; re-verify at code.claude.com/docs after major releases.
- `PermissionRequest` HTTP hook makes the app a synchronous gate — always answer fast, default to no-decision pass-through.
- Settings-merge bug could clobber a user's existing hooks — merge JSON surgically, never rewrite; test against a settings file that already has hooks.
- Secure-input and tap-timeout windows can leak Tier B pad keys into the foreground app as normal typing (password-field hazard) — detect and disable pad while secure input is active.
- Do not inject via `claude -p --resume <id>` into a session that's open interactively — two writers on one transcript.
