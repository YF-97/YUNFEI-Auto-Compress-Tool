#!/bin/bash
set -euo pipefail

APP_NAME="YUNFEI自动压缩_1.0.2.51"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
STAGING_DIR="$BUILD_DIR/dmg"
DMG_NAME="${APP_NAME}.dmg"

bash "$ROOT_DIR/build_app.sh"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$BUILD_DIR/$DMG_NAME"

echo "Built: $BUILD_DIR/$DMG_NAME"
