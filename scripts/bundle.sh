#!/bin/bash
# Build grc-whisper and assemble "GRC Whisper.app".
#
# TCC permissions (Microphone / Accessibility / Input Monitoring) are keyed to
# bundle ID + code signature, so the app must ALWAYS be built as a bundle and
# signed with the same fixed identifier — bare binaries attach their grants to
# the invoking terminal, and identity churn silently revokes grants.
#
# usage: scripts/bundle.sh [--install]   (--install copies to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.grc.whisper"
APP_NAME="GRC Whisper"
VERSION="1.0.0"
DIST="dist"
APP="$DIST/$APP_NAME.app"

# NOTE: built with swiftc directly, not `swift build` — the CommandLineTools-only
# toolchain on this machine has a broken PackageDescription dylib (manifest link
# failure). No external dependencies, so swiftc is equivalent.
echo "==> swiftc release build"
mkdir -p .build
swiftc -swift-version 5 -O Sources/GRCWhisper/*.swift -o .build/GRCWhisper

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/GRCWhisper "$APP/Contents/MacOS/$APP_NAME"
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
    <string>GRC Whisper records while you hold the dictation hotkey and transcribes entirely on this Mac.</string>
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
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "==> installed. Launch it: open '/Applications/$APP_NAME.app'"
fi
