#!/bin/zsh
# Builds a Release copy of Clip Builder and packages it into a DMG.
# Output: dist/ClipBuilder-<version>.dmg
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/Clip Builder.xcodeproj"
SCHEME="MyApp"
APP_NAME="Clip Builder"
BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"

echo "==> Building $APP_NAME (Release)"
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_IDENTITY="-" \
    build

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app not found at $APP_PATH" >&2
    exit 1
fi

VERSION=$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "1.0")
DMG_NAME="ClipBuilder-$VERSION.dmg"
STAGING_DIR=$(mktemp -d)

echo "==> Staging DMG contents"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$DMG_NAME"

echo "==> Creating $DMG_NAME"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov -format UDZO \
    "$DIST_DIR/$DMG_NAME"

rm -rf "$STAGING_DIR"
echo "==> Done: $DIST_DIR/$DMG_NAME"
