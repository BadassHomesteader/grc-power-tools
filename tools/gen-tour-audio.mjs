// Generate the site walkthrough voiceover (site/assets/tour/NN.mp3) via Azure Speech REST.
// Usage: SPEECH_KEY=$(az cognitiveservices account keys list -n grc-speech -g grc-book-listen-rg --query key1 -o tsv) \
//        node tools/gen-tour-audio.mjs
// Keep SCENES in sync with the SCENES captions in site/walkthrough.html.
import { writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const KEY = process.env.SPEECH_KEY;
if (!KEY) { console.error('SPEECH_KEY missing'); process.exit(1); }
const REGION = 'eastus';
const VOICE = 'en-US-AndrewMultilingualNeural';
const FORMAT = 'audio-24khz-96kbitrate-mono-mp3';
const OUT = join(dirname(fileURLToPath(import.meta.url)), '..', 'site', 'assets', 'tour');

const SCENES = [
  ['01', `This is Power Tools — the PowerToys of macOS. One hotkey, a whole toolbox. Hold Option and Shift, and a hint strip appears: every tool is one tap away. And the core tools run entirely on your Mac — no cloud, no account, no subscription.`],
  ['02', `Prefer the mouse? Hold the hotkey and right-click, anywhere, and the Power Ring fans eight tools out around your cursor. Flick toward one and release. The whole slice counts, so a sloppy flick still lands. You choose the eight in Settings — and everything you're about to see is one flick away.`],
  ['03', `First, dictation. Hold the hotkey and just talk. A live waveform floats at the bottom of the screen while Apple's on-device speech engine streams your words. Let go, and a polished transcript lands in whatever app has focus — filler words removed, self-corrections applied, punctuation fixed. Your audio never leaves the Mac.`],
  ['04', `Windows switchers, this one's for you. Hold the hotkey and tap an arrow: the focused window snaps to that side. Tap again to cycle a half, a third, two thirds. Chain two arrows and it lands in a corner. And right after a snap, Snap Assist offers your other windows to fill the empty space — just like Windows.`],
  ['05', `Prefer to see your targets? Hold and tap W for the snap palette — halves, thirds, quarter columns, and a mini grid you drag across to sketch any rectangle. Tap S to snapshot every window's position as a saved layout — meeting mode, one keystroke.`],
  ['06', `Command Tab, fixed. Hold Command, and you get a strip of live window thumbnails — every window, not every app. Two Excel windows are two entries. Tab or the arrows move the highlight; release to switch.`],
  ['07', `Hold and tap H for the clipboard history macOS never shipped — your recent copies, text and images, thumbnails included. Pick one, and it pastes right where you were. Tap P instead for Advanced Paste: plain text, summarize, rewrite, bullets, or translate — whatever's on your clipboard, reshaped.`],
  ['08', `Point at anything on screen. Hold and tap T, drag a region, and the recognized text is on your clipboard — tables come back ready for a spreadsheet. Tap R, and the region is read aloud. S grabs a screenshot; G sends it to Google Lens. All the recognition runs on-device.`],
  ['09', `Hold and tap B for the Macro Pad — an on-screen stream deck that floats beside your work and never steals focus. Buttons swap with the app in front; the Outlook profile files mail in one tap, and on-device OCR of the open email lights up the right button. Tap digits to fire without the mouse. Drag the pad to a corner and it docks there — or collapse it to a mini strip of squares, and hover to peek.`],
  ['10', `Running Claude Code? Hold and tap J for the Agent Pad — every live session at a glance, color-coded: blue is working, green is idle, orange is waiting on you, red failed. Click a row to focus that terminal, or send it a prompt — typed or dictated — and when an agent needs a permission, Approve and Deny are right on the row. It docks to a corner too, and collapses to a strip of status lights — one glance shows which agent needs you.`],
  ['11', `Hold and tap N for Quick Capture: a small box pops up — type or dictate a line, press Return, and it posts to a connection you configure: your to-do app, an n eight n webhook, any endpoint. Inline shorthand parses as you type — p one sets priority, tomorrow becomes the due date, at calls becomes a context. Add as many connections as you like, each on its own letter — and a failed post reopens with your text intact.`],
  ['12', `Free, open source, signed and notarized. Download the D M G, drag it into Applications, grant two permissions — and hold Option Shift. Power Tools. One hotkey, a whole toolbox.`],
];

const xml = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

async function synth(text) {
  const ssml = `<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="en-US"><voice name="${VOICE}">${xml(text)}</voice></speak>`;
  let lastErr;
  for (let attempt = 0; attempt < 4; attempt++) {
    if (attempt) await new Promise((r) => setTimeout(r, 500 * 4 ** (attempt - 1)));
    const res = await fetch(`https://${REGION}.tts.speech.microsoft.com/cognitiveservices/v1`, {
      method: 'POST',
      headers: {
        'Ocp-Apim-Subscription-Key': KEY,
        'Content-Type': 'application/ssml+xml',
        'X-Microsoft-OutputFormat': FORMAT,
        'User-Agent': 'power-tools-tour',
      },
      body: ssml,
    });
    if (res.ok) return Buffer.from(await res.arrayBuffer());
    lastErr = new Error(`TTS ${res.status}: ${(await res.text()).slice(0, 200)}`);
    if (res.status !== 429 && res.status < 500) throw lastErr;
  }
  throw lastErr;
}

// Optional args: scene ids to (re)generate, e.g. `node tools/gen-tour-audio.mjs 08 11`
const only = process.argv.slice(2);
await mkdir(OUT, { recursive: true });
for (const [id, text] of SCENES) {
  if (only.length && !only.includes(id)) continue;
  const buf = await synth(text);
  await writeFile(join(OUT, `${id}.mp3`), buf);
  console.log(`${id}.mp3  ${(buf.length / 1024).toFixed(0)} KB`);
  await new Promise((r) => setTimeout(r, 250));
}
console.log('done');
