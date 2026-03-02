#!/bin/bash
set -euo pipefail

APP_NAME="YUNFEI自动压缩_1.0.2.49"
BIN_NAME="SubtitleCompress"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
ICON_SOURCE="/Users/yunfei/Desktop/logo.png"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
ICON_FILE="$RES_DIR/AppIcon.icns"

mkdir -p "$BIN_DIR"

SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
export SDKROOT
export MACOSX_DEPLOYMENT_TARGET=13.0

xcrun swiftc \
  -O \
  -parse-as-library \
  -sdk "$SDKROOT" \
  -target x86_64-apple-macos13.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework Foundation \
  -framework UniformTypeIdentifiers \
  "$ROOT_DIR/main.swift" \
  -o "$BIN_DIR/$BIN_NAME"

mkdir -p "$RES_DIR"

if [ ! -f "$ICON_SOURCE" ]; then
  echo "Logo not found: $ICON_SOURCE"
  exit 1
fi

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>YUNFEI自动压缩_1.0.2.49</string>
  <key>CFBundleDisplayName</key>
  <string>YUNFEI自动压缩_1.0.2.49</string>
  <key>CFBundleIdentifier</key>
  <string>com.yunfei.subtitle-compress</string>
  <key>CFBundleVersion</key>
  <string>1.0.2.49</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.2.49</string>
  <key>CFBundleExecutable</key>
  <string>SubtitleCompress</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "Built: $APP_DIR"
