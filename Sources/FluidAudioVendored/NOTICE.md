Vendored from https://github.com/FluidInference/FluidAudio at commit
2e860df5bd29391f24b9132e527311bf1d096145 (2026-07-19), Apache License 2.0
(see LICENSE-FluidAudio).

Only the ASR-relevant subset is vendored — Sources/FluidAudio/{ASR,Shared,ITN}
plus the 3 top-level files, and the MachTaskSelfWrapper C target (used by
Shared/SystemInfo.swift). Diarizer/, TTS/, VAD/, FastClusterWrapper, and the
NemoTextProcessing binary dependency are NOT vendored — confirmed unreachable
from Power Tools' narrow ASR-only usage (AsrModels.downloadAndLoad → AsrManager
.loadModels/.transcribe).

Rationale: swiftpm is broken on the dev machine, and a GitHub-Actions-built
static-library artifact turned out to be blocked by a genuine Swift-compiler
version mismatch between this machine and CI's available toolchains — see
git history around 2026-07-20 for the full trail. Vendoring source lets this
compile with the same plain `swiftc` invocation as the rest of the app.

To update: re-clone FluidAudio, diff the same folder set, re-copy, re-check
MachTaskSelfWrapper/FastClusterWrapper usage in case that changed upstream.
