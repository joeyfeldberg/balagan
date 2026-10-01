#!/bin/bash
# Assembles a real, double-clickable Balagan.app from the SwiftPM build.
#
#   scripts/build-app.sh [version]
#
# Produces dist/Balagan.app (ad-hoc signed). Drop it in /Applications.
# For distribution to other machines you'd swap the ad-hoc signature for a
# Developer ID identity + notarization (see the comment at the bottom).
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-$(cat VERSION 2>/dev/null || echo 0.1.0)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ID="com.joeyfeldberg.Balagan"
APP="dist/Balagan.app"
CONFIG=release

echo "==> Building (release)…"
swift build -c "$CONFIG" --product BalaganApp
swift build -c "$CONFIG" --product balagan-agent
swift build -c "$CONFIG" --product balagan
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP (v$VERSION build $BUILD_NUMBER)…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/BalaganApp" "$APP/Contents/MacOS/BalaganApp"
# Agent wrapper sits next to the app binary so the app auto-discovers it.
[ -f "$BIN_DIR/balagan-agent" ] && cp "$BIN_DIR/balagan-agent" "$APP/Contents/MacOS/balagan-agent"
# `balagan` control CLI ships inside the bundle; symlink it onto PATH to use it (hint printed below).
[ -f "$BIN_DIR/balagan" ] && cp "$BIN_DIR/balagan" "$APP/Contents/MacOS/balagan"
# SwiftPM resource bundle (holds AppIcon.png etc.) — Bundle.module resolves it from Resources/.
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

echo "==> Generating AppIcon.icns…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
SRC="Sources/BalaganApp/Resources/AppIcon.png"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s"           "$SRC" --out "$ICONSET/icon_${s}x${s}.png"   >/dev/null
  sips -z "$((s*2))" "$((s*2))" "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Writing Info.plist…"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Balagan</string>
  <key>CFBundleDisplayName</key>     <string>Balagan</string>
  <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>      <string>BalaganApp</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundleVersion</key>         <string>$BUILD_NUMBER</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
  <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Sign with a real identity when one exists — an ad-hoc signed bundle is refused desktop-notification
# authorization by macOS (banners silently dropped; see AGENTS.md gotchas). Preference:
# `BALAGAN_CODESIGN_IDENTITY` → an Apple-issued identity → any valid code-signing identity (e.g. the
# self-signed one scripts/make-signing-cert.sh creates — verified sufficient) → ad-hoc.
IDENTITY="${BALAGAN_CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\|Developer ID Application: [^"]*\|Mac Developer: [^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)"
fi
if [ -n "$IDENTITY" ]; then
  echo "==> Code signing with identity: $IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1 \
    || { echo "   (signing with \"$IDENTITY\" failed — falling back to ad-hoc)"; codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true; }
else
  echo "==> Code signing (ad-hoc — macOS will DENY desktop notifications; run scripts/make-signing-cert.sh)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped/failed — app still runs locally)"
fi

# Don't leave the dist/ copy registered with LaunchServices: a second record for the bundle id makes the
# notification daemon refuse authorization for the installed app (see AGENTS.md gotchas).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" >/dev/null 2>&1 || true

echo "==> Done: $APP  (v$VERSION, build $BUILD_NUMBER)"
echo "    Run:    open \"$APP\""
echo "    Install: scripts/install-app.sh   (moves the old copy out, keeps ONE LaunchServices record)"
echo "    CLI:     \`balagan\` auto-symlinks onto PATH on first launch (/usr/local/bin, /opt/homebrew/bin,"
echo "             or ~/.local/bin — first writable one wins). Manual fallback if none are writable:"
echo "               ln -sf /Applications/Balagan.app/Contents/MacOS/balagan /usr/local/bin/balagan"

# For real distribution to other Macs, replace the ad-hoc sign with:
#   codesign --force --deep --options runtime --sign "Developer ID Application: NAME (TEAMID)" "$APP"
#   xcrun notarytool submit ... && xcrun stapler staple "$APP"
