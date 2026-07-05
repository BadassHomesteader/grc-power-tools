#!/bin/bash
# Build a Developer-ID-signed, notarized, stapled "Power Tools.dmg" that friends
# can download and open with no Gatekeeper warnings.
#
# ONE-TIME SETUP (needs an Apple Developer Program membership):
#   1. Create a "Developer ID Application" certificate (Xcode ▸ Settings ▸ Accounts
#      ▸ your team ▸ Manage Certificates ▸ + ▸ Developer ID Application). Confirm:
#         security find-identity -v -p codesigning
#   2. App-specific password: appleid.apple.com ▸ Sign-In & Security ▸ App-Specific
#      Passwords ▸ generate one.
#   3. Store notary credentials once (creates a keychain profile named "PowerTools"):
#         xcrun notarytool store-credentials "PowerTools" \
#           --apple-id "you@example.com" --team-id "YOURTEAMID" --password "xxxx-xxxx-xxxx-xxxx"
#
# THEN:  scripts/release.sh
#   (override DEVELOPER_ID / NOTARY_PROFILE via env if your names differ)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Power Tools"
APP="dist/$APP_NAME.app"
DMG="dist/$APP_NAME.dmg"
SIGN_ID="${DEVELOPER_ID:-Developer ID Application}"   # matches your one Developer ID cert
NOTARY_PROFILE="${NOTARY_PROFILE:-PowerTools}"
ENT="$(mktemp).plist"

echo "==> preflight: a Developer ID cert must exist"
if ! security find-identity -v -p codesigning | grep -qi "Developer ID Application"; then
    echo "!! No 'Developer ID Application' identity found. Do the one-time setup at the top of this script." >&2
    exit 1
fi

echo "==> build the app bundle"
scripts/bundle.sh    # assembles dist/Power Tools.app (local-signed; we re-sign below)

echo "==> hardened-runtime entitlements (microphone)"
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
PLIST

echo "==> re-sign with Developer ID + hardened runtime + secure timestamp"
codesign --force --options runtime --timestamp \
    --entitlements "$ENT" --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> zip + submit to Apple notary service (waits for the result)"
ZIP="$(mktemp).zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$ZIP"

echo "==> staple the notarization ticket onto the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> build a drag-to-Applications .dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo ""
echo "==> DONE: $DMG"
echo "    Signed + notarized + stapled — friends download it, drag to Applications, and it just opens."
spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | head -3 || true
