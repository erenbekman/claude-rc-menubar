#!/bin/bash
# Claude RC menü çubuğu uygulamasını derler ve .app paketini üretir.
#   ./build.sh            -> build/Claude RC.app
#   ./build.sh --install  -> ayrıca /Applications'a kopyalar ve başlatır
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Claude RC"
EXEC_NAME="ClaudeRC"
BUNDLE_ID="com.safepluspay.claude-rc"
VERSION="1.4"
BUILD="$HERE/build"
BUNDLE="$BUILD/$APP_NAME.app"

echo "==> Cleaning"
rm -rf "$BUILD"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

echo "==> Generating icon"
swift "$HERE/Sources/makeicon.swift" "$BUILD/icon_1024.png" >/dev/null
ICONSET="$BUILD/$EXEC_NAME.iconset"
mkdir -p "$ICONSET"
gen() { sips -z "$2" "$2" "$BUILD/icon_1024.png" --out "$ICONSET/$1" >/dev/null 2>&1; }
gen icon_16x16.png 16;      gen icon_16x16@2x.png 32
gen icon_32x32.png 32;      gen icon_32x32@2x.png 64
gen icon_128x128.png 128;   gen icon_128x128@2x.png 256
gen icon_256x256.png 256;   gen icon_256x256@2x.png 512
gen icon_512x512.png 512;   gen icon_512x512@2x.png 1024
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/$EXEC_NAME.icns"

echo "==> Info.plist"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>            <string>$EXEC_NAME</string>
  <key>CFBundleIconFile</key>              <string>$EXEC_NAME</string>
  <key>CFBundlePackageType</key>           <string>APPL</string>
  <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
  <key>CFBundleVersion</key>               <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>        <string>13.0</string>
  <key>LSUIElement</key>                   <true/>
  <key>NSHighResolutionCapable</key>       <true/>
  <key>NSHumanReadableCopyright</key>      <string>Claude RC</string>
</dict>
</plist>
PLIST

echo "==> Compiling (arm64 + x86_64)"
for ARCH in arm64 x86_64; do
  swiftc -O \
    -swift-version 5 \
    -target "$ARCH-apple-macos13.0" \
    -framework Cocoa -framework IOKit -framework SwiftUI \
    -framework CoreImage -framework UserNotifications \
    -o "$BUILD/$EXEC_NAME-$ARCH" \
    "$HERE/Sources/ClaudeRC.swift"
done
lipo -create "$BUILD/$EXEC_NAME-arm64" "$BUILD/$EXEC_NAME-x86_64" \
  -output "$BUNDLE/Contents/MacOS/$EXEC_NAME"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || codesign --force --sign - "$BUNDLE"

rm -rf "$ICONSET" "$BUILD/icon_1024.png" "$BUILD/$EXEC_NAME-arm64" "$BUILD/$EXEC_NAME-x86_64"
ditto -c -k --norsrc --noextattr --keepParent "$BUNDLE" "$BUILD/Claude-RC.zip"
echo "==> Ready: $BUNDLE"
echo "==> Archive: $BUILD/Claude-RC.zip"

if [[ "${1:-}" == "--install" ]]; then
  RUNNING="/Applications/$APP_NAME.app/Contents/MacOS/$EXEC_NAME"
  if pgrep -f "$RUNNING" >/dev/null; then
    echo "==> WARNING: the running copy will be quit; open RC sessions will disconnect"
  fi
  pkill -f "$RUNNING" 2>/dev/null || true
  # Temiz kapanış çocuğu beklerken birkaç saniye sürebilir; gerçekten ölmesini bekle.
  for _ in $(seq 1 30); do
    pgrep -f "$RUNNING" >/dev/null || break
    sleep 0.5
  done
  echo "==> Copying to /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$BUNDLE" "/Applications/"
  xattr -cr "/Applications/$APP_NAME.app" 2>/dev/null || true
  open "/Applications/$APP_NAME.app"
  # Açıldığını doğrula: sessizce ölmesi en can sıkıcı hataydı.
  for _ in $(seq 1 30); do
    pgrep -f "$RUNNING" >/dev/null && break
    sleep 0.5
  done
  if pgrep -f "$RUNNING" >/dev/null; then
    echo "==> Installed and running: /Applications/$APP_NAME.app"
  else
    echo "!! Installed but did not start. Open it manually: open '/Applications/$APP_NAME.app'"
    exit 1
  fi
fi
