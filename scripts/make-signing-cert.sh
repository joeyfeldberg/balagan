#!/bin/bash
# Ensures there is a code-signing identity for `make app` — preferring an Apple-issued one, otherwise
# creating a local self-signed "Balagan Local Signing" certificate in your login keychain.
#
# Why this matters (verified 2026-09-06): an *ad-hoc* signed bundle is refused desktop-notification
# authorization by macOS ("Notifications are not allowed for this application"), so every banner is
# silently dropped and no Notifications entry ever appears in System Settings. What fixed it was a
# stable signing identity (this self-signed cert was enough) **plus a single LaunchServices
# registration for the bundle id** — a stale/duplicate record for another copy (dist/, a .previous
# backup in /Applications) kept the daemon refusing even after re-signing. scripts/install-app.sh does
# the registration cleanup. After installing, macOS prompts "Balagan would like to send you
# notifications" — click Allow. Distribution to other Macs still needs Developer ID + notarization.
#
# Run it yourself (it writes to your keychain and may prompt for your login password once):
#   scripts/make-signing-cert.sh && make app && scripts/install-app.sh
set -euo pipefail

NAME="${BALAGAN_SIGNING_NAME:-Balagan Local Signing}"
KEYCHAIN="${BALAGAN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

existing="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development: [^"]*\|Developer ID Application: [^"]*\|Mac Developer: [^"]*\)".*/\1/p' | head -1)"
if [ -n "$existing" ]; then
  echo "==> Apple-issued identity found, nothing to do: $existing"
  exit 0
fi
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "==> Identity \"$NAME\" already exists and is valid for code signing."
  exit 0
fi

WORK="$(mktemp -d /tmp/tb-sign.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating self-signed code-signing certificate \"$NAME\" (10 years)…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$NAME/O=Balagan" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1

openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass:balagan -name "$NAME" 2>/dev/null \
|| openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass:balagan -name "$NAME"

echo "==> Importing into $(basename "$KEYCHAIN") (codesign may use the key without prompting)…"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P balagan \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild >/dev/null

echo "==> Trusting it for code signing (user trust domain — macOS may ask for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "==> Result:"
security find-identity -v -p codesigning | grep "$NAME" \
  || { echo "!! identity not reported valid — open Keychain Access, find \"$NAME\", set Trust → Code Signing: Always Trust"; exit 1; }
echo "==> Done. Now: make app && scripts/install-app.sh"
