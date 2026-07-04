#!/bin/bash
# Create a self-signed code-signing identity so GRC Whisper keeps a STABLE
# signature across rebuilds. This is what lets the macOS Accessibility /
# Microphone / Input-Monitoring grants SURVIVE a reinstall instead of resetting
# every time — the whole point.
#
# Ad-hoc signing (`codesign --sign -`) pins a per-build code hash, so every
# rebuild looks like a different app to TCC and the grant is dropped. A fixed
# self-signed cert makes the app's designated requirement "certificate leaf =
# <constant hash>", which every future rebuild satisfies.
#
# The cert is self-signed and lives only in your login keychain. Gatekeeper does
# NOT trust it (exactly like ad-hoc) — it only gives TCC a constant identity.
# Remove it any time with:
#   security delete-certificate -c "GRC Whisper Local Signing"
set -euo pipefail

NAME="GRC Whisper Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "signing identity '$NAME' already present — nothing to do"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cs.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN=GRC Whisper Local Signing
[v3]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/cs.key" -out "$TMP/cs.crt" \
    -days 3650 -config "$TMP/cs.cnf" >/dev/null 2>&1
# -legacy: OpenSSL 3.x's default PKCS12 MAC isn't readable by Apple's `security`.
openssl pkcs12 -export -legacy -inkey "$TMP/cs.key" -in "$TMP/cs.crt" \
    -name "$NAME" -out "$TMP/cs.p12" -passout pass:grcwhisper >/dev/null 2>&1
# -A authorises codesign to use the key without a per-build keychain prompt.
security import "$TMP/cs.p12" -k ~/Library/Keychains/login.keychain-db \
    -P grcwhisper -T /usr/bin/codesign -A

echo "created signing identity '$NAME'. Rebuild with scripts/bundle.sh --install"
echo "and grant Accessibility once more — after that, reinstalls keep the grant."
