#!/bin/bash
# Installs dist/Balagan.app into /Applications the way that keeps macOS happy:
#   - verifies the signature first,
#   - never overwrites the running bundle in place (a live signed binary rewritten in place gets the
#     process killed) — the old copy is moved out of /Applications entirely, not kept as a sibling,
#   - leaves exactly ONE LaunchServices registration for the bundle id. Duplicate/stale records (a
#     `.previous` copy in /Applications, the dist/ build) made the notification daemon refuse
#     authorization even for a correctly signed bundle (verified 2026-09-06).
# The running app keeps working from its old inodes; relaunch to pick up the new build.
set -euo pipefail

SRC="${1:-$(cd "$(dirname "$0")/.." && pwd)/dist/Balagan.app}"
DEST="/Applications/Balagan.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[ -d "$SRC" ] || { echo "!! $SRC not found — run make app first"; exit 1; }
echo "==> Verifying signature of $SRC"
codesign --verify --deep --strict "$SRC"
codesign -dv --verbose=2 "$SRC" 2>&1 | grep -E "^Authority|^Signature" | sed 's/^/    /' || true
if codesign -dv "$SRC" 2>&1 | grep -q "Signature=adhoc"; then
  echo "!! ad-hoc signed: macOS will refuse desktop notifications. Run scripts/make-signing-cert.sh and rebuild."
fi

# Earlier installs moved their copy aside to /tmp/Balagan-previous.*, and macOS registers a moved
# app again, so those piled up as duplicate LaunchServices records (the notification problem above).
# Unregister and delete every one that no running Balagan is still using; a copy in use stays until
# that app quits (it loads resources from its bundle).
IN_USE="$(lsof -Fn -c BalaganApp 2>/dev/null | sed -n 's#^n\(/private/tmp/Balagan-previous\.[^/]*\)/.*#\1#p' | sort -u || true)"
for previous in /private/tmp/Balagan-previous.*; do
  [ -d "$previous" ] || continue
  if printf '%s\n' "$IN_USE" | grep -qxF "$previous"; then continue; fi
  "$LSREGISTER" -u "$previous/Balagan.app" >/dev/null 2>&1 || true
  rm -rf "$previous"
done

if [ -d "$DEST" ]; then
  OLD="$(mktemp -d /tmp/Balagan-previous.XXXXXX)/Balagan.app"
  echo "==> Moving the installed copy aside to $OLD (running app keeps its inodes)"
  "$LSREGISTER" -u "$DEST" >/dev/null 2>&1 || true
  mv "$DEST" "$OLD"
fi
echo "==> Installing"
ditto "$SRC" "$DEST"
echo "==> LaunchServices: single registration for the bundle id"
"$LSREGISTER" -u "$SRC" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "==> Installed build $BUILD at $DEST. Relaunch Balagan to pick it up; if macOS asks to allow notifications, click Allow."
