#!/bin/bash
# Build grc-whisper and assemble "Power Tools.app".
#
# TCC permissions (Microphone / Accessibility / Input Monitoring) are keyed to
# bundle ID + code signature, so the app must ALWAYS be built as a bundle and
# signed with the same fixed identifier — bare binaries attach their grants to
# the invoking terminal, and identity churn silently revokes grants.
#
# usage: scripts/bundle.sh [--install]   (--install copies to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

# Display name is "Power Tools"; BUNDLE_ID + signing identity stay fixed so TCC
# grants (Mic / Accessibility / Screen Recording) and saved keys survive the rename.
BUNDLE_ID="com.grc.whisper"
APP_NAME="Power Tools"
OLD_APP_NAME="GRC Whisper"
VERSION="1.26.0"
DIST="dist"
APP="$DIST/$APP_NAME.app"

# NOTE: built with swiftc directly, not `swift build` — the CommandLineTools-only
# toolchain on this machine has a broken PackageDescription dylib (manifest link
# failure), confirmed live and not a sandbox/permissions issue.
#
# FluidAudio (Parakeet ASR) is a real SPM dependency, but since swiftpm is
# broken here, and a GitHub-Actions-built artifact turned out to be blocked by
# a genuine Swift-compiler version mismatch between this machine and CI's
# available toolchains, its ASR-relevant source is vendored directly into
# Sources/FluidAudioVendored/ instead (see its NOTICE.md) — compiled by this
# same swiftc invocation, so no external dependency or network fetch at all.
echo "==> swiftc release build"
mkdir -p .build
# swiftc mishandles a bare .c file mixed into a large multi-file Swift build
# (passes it straight to ld, which rejects it) — precompile with clang instead.
clang -c Sources/FluidAudioVendored/MachTaskSelfWrapper/MachTaskSelf.c -o .build/MachTaskSelf.o
swiftc -swift-version 5 -O \
    -Xcc -ISources/FluidAudioVendored/MachTaskSelfWrapper/include \
    Sources/PowerTools/*.swift \
    $(find Sources/FluidAudioVendored -name "*.swift") \
    .build/MachTaskSelf.o \
    -o .build/PowerTools

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/PowerTools "$APP/Contents/MacOS/$APP_NAME"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Power Tools records while you hold the dictation hotkey and transcribes entirely on this Mac.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Power Tools asks Finder which folder is open so hold + D can create a new document there.</string>
    <key>NSHumanReadableCopyright</key><string>Local-only dictation. No network. No cloud.</string>
</dict>
</plist>
PLIST

# Prefer a stable self-signed identity (tools/make_signing_cert.sh) so TCC grants
# survive rebuilds; fall back to ad-hoc. No hardened runtime — it would require
# audio-input entitlements and buys nothing for a local build.
SIGN_ID="GRC Whisper Local Signing"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
    echo "==> codesign (stable identity: $SIGN_ID)"
    codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
    GRANT_NOTE="stable-signed: your Accessibility grant carries across reinstalls."
else
    echo "==> codesign (ad-hoc — run tools/make_signing_cert.sh to stop grant resets)"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
    GRANT_NOTE="ad-hoc: rebuilds reset the Accessibility grant. Re-add the app in
      System Settings > Privacy & Security > Accessibility, or run
      tools/make_signing_cert.sh once to make grants stick."
fi

echo "==> built $APP"
echo "NOTE: $GRANT_NOTE"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> installing to /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    # Clean up the pre-rename app so there aren't two copies in /Applications.
    rm -rf "/Applications/$OLD_APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "==> installed. Launch it: open '/Applications/$APP_NAME.app'"
fi
