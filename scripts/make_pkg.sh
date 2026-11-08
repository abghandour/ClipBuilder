#!/bin/zsh
# Builds a Release copy of Clip Builder and packages it into a macOS .pkg
# installer that also installs dependencies via a guided post-install setup.
#
# Signing (auto-detected from the keychain, override via env):
#   APP_SIGN_IDENTITY       "Developer ID Application: ..." — signs the app
#   INSTALLER_SIGN_IDENTITY "Developer ID Installer: ..."   — signs the pkg
#   NOTARY_PROFILE          notarytool keychain profile — notarizes + staples
#   UNSIGNED=1              force an unsigned (ad-hoc) build
#   PROVISIONING_PROFILE    path of the Developer ID provisioning profile to
#                           embed (default: the installed one for the bundle id)
#
# Channel (docs/Stable-Beta-Channels-Plan.md):
#   CHANNEL=stable (default) builds "Clip Builder" (MyApp, Release)
#   CHANNEL=beta             builds "Clip Builder Beta" (MyApp Beta, Release-Beta)
#
# A signed build embeds the channel's Developer ID provisioning profile and
# signs with the shared keychain group (ClipBuilder/Clip Builder.entitlements),
# so the stable and beta apps share keys. keychain-access-groups is a
# restricted entitlement: without the profile the app is killed at launch,
# so a missing profile fails the build.
#
# Output: dist/ClipBuilder-<version>.pkg, or dist/ClipBuilder-Beta-<version>.pkg
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/Clip Builder.xcodeproj"
BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
INSTALLER_DIR="$REPO_ROOT/scripts/installer"
ENTITLEMENTS="$REPO_ROOT/ClipBuilder/Clip Builder.entitlements"
KEYCHAIN_GROUP_SUFFIX="com.mokotti-solutions.clipbuilder.shared"

CHANNEL="${CHANNEL:-stable}"
case "$CHANNEL" in
    stable)
        SCHEME="MyApp"
        CONFIGURATION="Release"
        APP_NAME="Clip Builder"
        PKG_ID="com.mokotti-solutions.clipbuilder.pkg"
        PKG_PREFIX="ClipBuilder"
        ;;
    beta)
        SCHEME="MyApp Beta"
        CONFIGURATION="Release-Beta"
        APP_NAME="Clip Builder Beta"
        PKG_ID="com.mokotti-solutions.clipbuilder.beta.pkg"
        PKG_PREFIX="ClipBuilder-Beta"
        ;;
    *)
        echo "error: CHANNEL must be stable or beta, not '$CHANNEL'" >&2
        exit 1
        ;;
esac
echo "==> Channel: $CHANNEL"

# The build reads the ignored local override; never package the empty fallback.
/bin/sh "$REPO_ROOT/scripts/check_google_drive_credentials.sh" "$REPO_ROOT/Configuration/GoogleDrive-Local.plist"

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

if [[ "${UNSIGNED:-0}" == "1" ]]; then
    echo "==> UNSIGNED=1 — building unsigned (ad-hoc); never distribute this pkg"
    SIGN_ARGS=(CODE_SIGN_IDENTITY=-)
else
    # A missing identity must fail the release, not silently ship an
    # unsigned pkg — keychain items have vanished on this machine before.
    if [[ -z "${APP_SIGN_IDENTITY:-}" || -z "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
        [[ -z "${APP_SIGN_IDENTITY:-}" ]] \
            && echo "error: no Developer ID Application identity in the keychain (signs the app)" >&2
        [[ -z "${INSTALLER_SIGN_IDENTITY:-}" ]] \
            && echo "error: no Developer ID Installer identity in the keychain (signs the pkg)" >&2
        echo "Create the missing certificate(s) in Xcode: Settings > Accounts > Manage Certificates," >&2
        echo "or run with UNSIGNED=1 for an explicitly unsigned local build." >&2
        exit 1
    fi
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
fi

echo "==> Building $APP_NAME ($CONFIGURATION)"
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'generic/platform=macOS' \
    "${SIGN_ARGS[@]}" \
    build

APP_PATH="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app not found at $APP_PATH" >&2
    exit 1
fi

# Check the actual bundle too, in case the build configuration ignored the override.
/bin/sh "$REPO_ROOT/scripts/check_google_drive_credentials.sh" "$APP_PATH/Contents/Info.plist"

# ------------------------------------- provisioning profile + keychain group
# Re-sign the app (its nested code is already signed by the build) with the
# entitlements file and the channel's provisioning profile embedded. Done
# here rather than through xcodebuild settings, which would also apply the
# profile to the Swift package targets.
if [[ -n "${APP_SIGN_IDENTITY:-}" ]]; then
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist")
    TEAM_ID=$(print -r -- "$APP_SIGN_IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')
    [[ -n "$TEAM_ID" ]] || { echo "error: no team id in '$APP_SIGN_IDENTITY'" >&2; exit 1; }
    SIGN_CERT_SHA1=$(security find-certificate -c "$APP_SIGN_IDENTITY" -Z 2>/dev/null \
        | sed -n 's/^SHA-1 hash: //p' | head -1 | tr 'A-F' 'a-f')
    PROFILE_SCRATCH=$(mktemp -d)

    # Prints the profile's expiry (epoch) when it is for this app id, holds
    # the signing certificate, and has not expired; fails otherwise.
    profile_matches() {
        local plist="$PROFILE_SCRATCH/profile.plist" n=0 cert
        security cms -D -i "$1" > "$plist" 2>/dev/null || return 1
        [[ $(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$plist" 2>/dev/null) \
            == "$TEAM_ID.$BUNDLE_ID" ]] || return 1
        local expiry=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" \
            "$(plutil -extract ExpirationDate raw -o - "$plist")" +%s 2>/dev/null || echo 0)
        (( expiry > $(date +%s) )) || return 1
        while cert=$(plutil -extract "DeveloperCertificates.$n" raw -o - "$plist" 2>/dev/null); do
            if [[ $(print -r -- "$cert" | base64 -d | shasum | cut -c1-40) == "$SIGN_CERT_SHA1" ]]; then
                print -r -- "$expiry"
                return 0
            fi
            n=$((n + 1))
        done
        return 1
    }

    if [[ -z "${PROVISIONING_PROFILE:-}" ]]; then
        BEST_EXPIRY=0
        for candidate in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.provisionprofile(N) \
                         "$HOME/Library/MobileDevice/Provisioning Profiles/"*.provisionprofile(N); do
            if expiry=$(profile_matches "$candidate") && (( expiry > BEST_EXPIRY )); then
                PROVISIONING_PROFILE="$candidate"
                BEST_EXPIRY=$expiry
            fi
        done
    elif ! profile_matches "$PROVISIONING_PROFILE" > /dev/null; then
        echo "error: $PROVISIONING_PROFILE is not a current profile for $TEAM_ID.$BUNDLE_ID" >&2
        echo "       signed by '$APP_SIGN_IDENTITY'" >&2
        exit 1
    fi
    if [[ -z "${PROVISIONING_PROFILE:-}" ]]; then
        echo "error: no Developer ID provisioning profile for $TEAM_ID.$BUNDLE_ID that holds" >&2
        echo "       the '$APP_SIGN_IDENTITY' certificate is installed." >&2
        echo "Create one at developer.apple.com (Profiles > Developer ID, macOS) and put it in" >&2
        echo "~/Library/Developer/Xcode/UserData/Provisioning Profiles/, or set PROVISIONING_PROFILE." >&2
        exit 1
    fi
    echo "==> Embedding provisioning profile: $(basename "$PROVISIONING_PROFILE")"
    cp "$PROVISIONING_PROFILE" "$APP_PATH/Contents/embedded.provisionprofile"

    # The entitlements file uses Xcode variables; resolve them for codesign.
    RESOLVED_ENTITLEMENTS="$PROFILE_SCRATCH/app.entitlements"
    sed -e "s/\$(AppIdentifierPrefix)/$TEAM_ID./g" -e "s/\$(CFBundleIdentifier)/$BUNDLE_ID/g" \
        "$ENTITLEMENTS" > "$RESOLVED_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$RESOLVED_ENTITLEMENTS"
    if grep -q '\$(' "$RESOLVED_ENTITLEMENTS"; then
        echo "error: unresolved variable in $ENTITLEMENTS" >&2
        exit 1
    fi
    echo "==> Signing app with the shared keychain group ($TEAM_ID.$KEYCHAIN_GROUP_SUFFIX)"
    codesign --force --options runtime --timestamp \
        --entitlements "$RESOLVED_ENTITLEMENTS" \
        --sign "$APP_SIGN_IDENTITY" "$APP_PATH"
    rm -rf "$PROFILE_SCRATCH"

    SIGNED_GROUPS=$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null \
        | plutil -extract keychain-access-groups.0 raw -o - - 2>/dev/null || true)
    if [[ "$SIGNED_GROUPS" != "$TEAM_ID.$KEYCHAIN_GROUP_SUFFIX" ]]; then
        echo "error: the signed app does not carry the shared keychain group" >&2
        exit 1
    fi
fi

if [[ -n "${APP_SIGN_IDENTITY:-}" ]]; then
    echo "==> Verifying app signature"
    codesign --verify --strict --deep --verbose=1 "$APP_PATH"
fi

VERSION=$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "1.0")
PKG_NAME="$PKG_PREFIX-$VERSION.pkg"
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
sed "s/__APP_NAME__/$APP_NAME/g" "$INSTALLER_DIR/postinstall" > "$SCRIPTS/postinstall"
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
sed -e "s/__VERSION__/$VERSION/g" -e "s/__TITLE__/$APP_NAME/g" -e "s/__PKG_ID__/$PKG_ID/g" \
    "$INSTALLER_DIR/distribution.xml" > "$STAGING_DIR/distribution.xml"
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
