#!/bin/zsh
# One-command release for Clip Builder:
#   1. Determines the release version: if the current MARKETING_VERSION is
#      already tagged on GitHub, bumps it (last component +1) and always
#      increments CURRENT_PROJECT_VERSION — so every published pkg/dmg
#      carries a new version number.
#   2. Updates the version references in the Getting Started guide (and
#      regenerates the PDF when Chrome is available).
#   3. Builds, signs, and notarizes the pkg (make_pkg.sh), then packages the
#      same Developer ID-signed app into a DMG, signs, notarizes, staples.
#   4. Commits the bump, tags v<version>, pushes, and creates the GitHub
#      release with the pkg, DMG, and PDF attached.
#
# Environment (defaults match this machine's setup):
#   DEVELOPER_DIR    Xcode to build with
#   NOTARY_PROFILE   notarytool keychain profile
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="$REPO_ROOT/Clip Builder.xcodeproj/project.pbxproj"
GUIDE="$REPO_ROOT/docs/ClipBuilder-Getting-Started.html"
DIST_DIR="$REPO_ROOT/dist"
APP_PATH="$REPO_ROOT/build/Build/Products/Release/Clip Builder.app"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export NOTARY_PROFILE="${NOTARY_PROFILE:-ClipBuilderNotary}"

step() { echo; echo "==> $1"; }

# ------------------------------------------------------------ preconditions
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    echo "error: working tree has uncommitted changes — commit or stash first" >&2
    exit 1
fi
for tool in gh xcrun; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found" >&2; exit 1; }
done

# ------------------------------------------------------------- version bump
CURRENT=$(sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' "$PBXPROJ" | head -1)
BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' "$PBXPROJ" | head -1)
[[ -n $CURRENT && -n $BUILD ]] || { echo "error: could not read versions from pbxproj" >&2; exit 1; }

if git -C "$REPO_ROOT" ls-remote --exit-code --tags origin "v$CURRENT" >/dev/null 2>&1; then
    # Current version already shipped — bump the last component.
    VERSION=$(print -r -- "$CURRENT" | awk -F. '{ $NF += 1; print }' OFS=.)
    step "Version $CURRENT already released — bumping to $VERSION"
else
    VERSION=$CURRENT
    step "Releasing unreleased version $VERSION"
fi
NEW_BUILD=$((BUILD + 1))

sed -i '' "s/MARKETING_VERSION = $CURRENT;/MARKETING_VERSION = $VERSION;/g; s/CURRENT_PROJECT_VERSION = $BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PBXPROJ"
echo "    MARKETING_VERSION $CURRENT -> $VERSION, build $BUILD -> $NEW_BUILD"

step "Updating Getting Started guide version references"
sed -i '' -E "s/ClipBuilder-[0-9.]+\.pkg/ClipBuilder-$VERSION.pkg/g; s/Clip Builder [0-9.]+ — Getting Started/Clip Builder $VERSION — Getting Started/g" "$GUIDE"
if [[ -x $CHROME ]]; then
    "$CHROME" --headless --disable-gpu --no-pdf-header-footer \
        --print-to-pdf="$REPO_ROOT/docs/ClipBuilder-Getting-Started.pdf" \
        "file://$GUIDE" 2>/dev/null
    echo "    PDF regenerated"
else
    echo "    ! Chrome not found — regenerate docs/ClipBuilder-Getting-Started.pdf manually"
fi

# ------------------------------------------------------------- build + sign
step "Building and notarizing pkg"
"$REPO_ROOT/scripts/make_pkg.sh"
PKG="$DIST_DIR/ClipBuilder-$VERSION.pkg"
[[ -f $PKG ]] || { echo "error: expected $PKG from make_pkg.sh" >&2; exit 1; }

step "Packaging DMG from the signed app"
DMG="$DIST_DIR/ClipBuilder-$VERSION.dmg"
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
[[ -n $SIGN_IDENTITY ]] || { echo "error: no Developer ID Application identity" >&2; exit 1; }
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Clip Builder" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

step "Notarizing DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
    | tee /dev/stderr | grep -q "status: Accepted" \
    || { echo "error: DMG notarization was not accepted" >&2; exit 1; }
xcrun stapler staple "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG"

# --------------------------------------------------------- commit + publish
step "Committing, tagging v$VERSION, pushing"
git -C "$REPO_ROOT" add "$PBXPROJ" "$GUIDE" "$REPO_ROOT/docs/ClipBuilder-Getting-Started.pdf"
git -C "$REPO_ROOT" commit -m "Release $VERSION (build $NEW_BUILD)"
git -C "$REPO_ROOT" tag "v$VERSION"
git -C "$REPO_ROOT" push origin HEAD "v$VERSION"

step "Creating GitHub release v$VERSION"
gh release create "v$VERSION" "$PKG" "$DMG" "$REPO_ROOT/docs/ClipBuilder-Getting-Started.pdf" \
    --title "Clip Builder $VERSION" --generate-notes

step "Done — released Clip Builder $VERSION"
