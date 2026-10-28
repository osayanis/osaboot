#!/bin/bash
# Build + empaquetage .app + signature.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
echo "▶︎ swift build ($CONFIG)…"
swift build -c "$CONFIG"
BIN=".build/$CONFIG/OsaBoot"

APP="OsaBoot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OsaBoot"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OsaBoot</string>
  <key>CFBundleDisplayName</key><string>OsaBoot</string>
  <key>CFBundleIdentifier</key><string>com.osalabs.osaboot</string>
  <key>CFBundleExecutable</key><string>OsaBoot</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Image disque</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>iso</string><string>img</string><string>raw</string><string>bin</string></array>
    </dict>
  </array>
  <key>NSHumanReadableCopyright</key><string>OsaLabs</string>
</dict>
</plist>
PLIST

# wimlib-imagex (découpe d'install.wim), compilé par scripts/build-wimlib.sh, avec sa licence
if [ -x vendor/wimlib-imagex ]; then
  cp vendor/wimlib-imagex "$APP/Contents/Resources/wimlib-imagex"
  [ -f vendor/libwim.15.dylib ] && cp vendor/libwim.15.dylib "$APP/Contents/Resources/libwim.15.dylib"
  cp vendor/wimlib-COPYING.GPLv3 "$APP/Contents/Resources/wimlib-LICENCE-GPLv3.txt"
fi

# Certificat « Apple Development » du trousseau s'il existe (les permissions
# macOS restent accordées d'un build à l'autre), sinon signature ad-hoc.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')}"
for f in "$APP/Contents/Resources/libwim.15.dylib" "$APP/Contents/Resources/wimlib-imagex"; do [ -f "$f" ] && codesign --force --sign "${SIGN_ID:--}" "$f" 2>/dev/null; done
codesign --force --deep --sign "${SIGN_ID:--}" "$APP" 2>/dev/null || true
echo "✅ $APP prêt."
