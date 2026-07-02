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

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>GRC Whisper records while you hold the dictation hotkey and transcribes entirely on this Mac.</string>
    <key>NSHumanReadableCopyright</key><string>Local-only dictation. No network. No cloud.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature with a FIXED identifier: keeps TCC grants across rebuilds.
# No hardened runtime — it would require audio-input entitlements and buys
# nothing for a local ad-hoc build.
echo "==> codesign (ad-hoc, identifier $BUNDLE_ID)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "==> built $APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> installing to /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "==> installed. Launch it: open '/Applications/$APP_NAME.app'"
fi
