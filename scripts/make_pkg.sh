#!/bin/zsh
# Builds a Release copy of Clip Builder and packages it into a macOS .pkg
# installer that also installs dependencies via a guided post-install setup.
#
# Signing (auto-detected from the keychain, override via env):
#   APP_SIGN_IDENTITY       "Developer ID Application: ..." — signs the app
#   INSTALLER_SIGN_IDENTITY "Developer ID Installer: ..."   — signs the pkg
#   NOTARY_PROFILE          notarytool keychain profile — notarizes + staples
#   UNSIGNED=1              force an unsigned (ad-hoc) build
#
# Output: dist/ClipBuilder-<version>.pkg
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/Clip Builder.xcodeproj"
SCHEME="MyApp"
APP_NAME="Clip Builder"
BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
INSTALLER_DIR="$REPO_ROOT/scripts/installer"
PKG_ID="com.mokotti-solutions.clipbuilder.pkg"

# ------------------------------------------------------- signing identities
if [[ "${UNSIGNED:-0}" != "1" ]]; then
    : "${APP_SIGN_IDENTITY:=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
    : "${INSTALLER_SIGN_IDENTITY:=$(security find-identity -v 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Installer: [^"]*\)".*/\1/p' | head -1)}"
else
    APP_SIGN_IDENTITY=""
    INSTALLER_SIGN_IDENTITY=""
fi

if [[ -n "${APP_SIGN_IDENTITY:-}" ]]; then
    echo "==> Signing app with: $APP_SIGN_IDENTITY"
    SIGN_ARGS=(
        CODE_SIGN_STYLE=Manual
        "CODE_SIGN_IDENTITY=$APP_SIGN_IDENTITY"
        ENABLE_HARDENED_RUNTIME=YES
        "OTHER_CODE_SIGN_FLAGS=--timestamp"
        # Keep the debug-only get-task-allow entitlement out of the binary —
        # the notary service rejects any executable that carries it.
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    )
else
    echo "==> No Developer ID Application identity — building unsigned (ad-hoc)"
    SIGN_ARGS=(CODE_SIGN_IDENTITY=-)
fi

echo "==> Building $APP_NAME (Release)"
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'generic/platform=macOS' \
    "${SIGN_ARGS[@]}" \
    build

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app not found at $APP_PATH" >&2
    exit 1
fi

if [[ -n "${APP_SIGN_IDENTITY:-}" ]]; then
    echo "==> Verifying app signature"
    codesign --verify --strict --deep --verbose=1 "$APP_PATH"
fi

VERSION=$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "1.0")
PKG_NAME="ClipBuilder-$VERSION.pkg"
STAGING_DIR=$(mktemp -d)
trap 'rm -rf "$STAGING_DIR"' EXIT

echo "==> Staging payload"
PAYLOAD="$STAGING_DIR/root"
mkdir -p "$PAYLOAD/Applications" "$PAYLOAD/Library/Application Support/ClipBuilder"
cp -R "$APP_PATH" "$PAYLOAD/Applications/"
cp "$INSTALLER_DIR/Clip Builder Setup.command" "$PAYLOAD/Library/Application Support/ClipBuilder/"
chmod 755 "$PAYLOAD/Library/Application Support/ClipBuilder/Clip Builder Setup.command"
# Strip extended attributes so pkgbuild doesn't emit ._* AppleDouble files.
xattr -rc "$PAYLOAD" 2>/dev/null || true

echo "==> Staging install scripts"
SCRIPTS="$STAGING_DIR/scripts"
mkdir -p "$SCRIPTS"
cp "$INSTALLER_DIR/postinstall" "$SCRIPTS/postinstall"
chmod 755 "$SCRIPTS/postinstall"

echo "==> Building component package"
pkgbuild \
    --root "$PAYLOAD" \
    --scripts "$SCRIPTS" \
    --identifier "$PKG_ID" \
    --version "$VERSION" \
    --install-location / \
    "$STAGING_DIR/ClipBuilderApp.pkg"

echo "==> Building distribution package"
sed "s/__VERSION__/$VERSION/g" "$INSTALLER_DIR/distribution.xml" > "$STAGING_DIR/distribution.xml"
mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$PKG_NAME"

PRODUCT_ARGS=(
    --distribution "$STAGING_DIR/distribution.xml"
    --resources "$INSTALLER_DIR/resources"
    --package-path "$STAGING_DIR"
)
if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
    echo "==> Signing pkg with: $INSTALLER_SIGN_IDENTITY"
    PRODUCT_ARGS+=(--sign "$INSTALLER_SIGN_IDENTITY" --timestamp)
fi
productbuild "${PRODUCT_ARGS[@]}" "$DIST_DIR/$PKG_NAME"

# ------------------------------------------------------------- notarization
if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing (this uploads to Apple and can take a few minutes)"
    NOTARY_OUTPUT=$(xcrun notarytool submit "$DIST_DIR/$PKG_NAME" \
        --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee /dev/stderr)
    if ! print -r -- "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
        SUBMISSION_ID=$(print -r -- "$NOTARY_OUTPUT" | sed -n 's/^ *id: //p' | head -1)
        echo "error: notarization was not accepted" >&2
        if [[ -n "$SUBMISSION_ID" ]]; then
            echo "==> Fetching notarization log" >&2
            xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        fi
        exit 1
    fi
    echo "==> Stapling notarization ticket"
    xcrun stapler staple "$DIST_DIR/$PKG_NAME"
    echo "==> Gatekeeper assessment"
    spctl -a -vv -t install "$DIST_DIR/$PKG_NAME"
elif [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
    echo "==> Skipping notarization (set NOTARY_PROFILE=<profile> to notarize)"
    echo "    One-time setup: xcrun notarytool store-credentials <profile> \\"
    echo "        --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>"
fi

echo "==> Done: $DIST_DIR/$PKG_NAME"
if [[ -z "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
    echo "    Note: the pkg is unsigned — recipients may need to right-click → Open,"
    echo "    or approve it in System Settings → Privacy & Security."
fi
