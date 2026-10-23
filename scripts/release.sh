#!/bin/zsh
# One-command release for Clip Builder:
#   1. Determines the release version: if the current MARKETING_VERSION is
#      already tagged on GitHub, bumps it (last component +1) and always
#      increments CURRENT_PROJECT_VERSION — so every published pkg/dmg
#      carries a new version number.
#   2. Updates the version references in the Getting Started guide (HTML only;
#      no PDF is generated).
#   3. Builds, signs, and notarizes the pkg (make_pkg.sh).
#   4. Commits the bump, tags v<version>, pushes, and creates the GitHub
#      release with the pkg attached.
#
# Usage: scripts/release.sh [--tests | --skip-tests]
#   In a terminal the script asks whether to run the unit tests first.
#   Without a terminal (CI, a background run) the tests run unless
#   --skip-tests or RELEASE_SKIP_TESTS=1 says otherwise; --tests forces them
#   and skips the question.
#
# Environment (defaults match this machine's setup):
#   DEVELOPER_DIR    Xcode to build with
#   NOTARY_PROFILE   notarytool keychain profile
#   RELEASE_SKIP_TESTS  1 skips the unit tests (same as --skip-tests)
set -euo pipefail

RUN_TESTS=""   # "" = ask when interactive, else run
for arg in "$@"; do
    case "$arg" in
        --tests) RUN_TESTS=1 ;;
        --skip-tests) RUN_TESTS=0 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "error: unknown option $arg (use --tests or --skip-tests)" >&2; exit 2 ;;
    esac
done
[[ -z $RUN_TESTS && "${RELEASE_SKIP_TESTS:-0}" == 1 ]] && RUN_TESTS=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="$REPO_ROOT/Clip Builder.xcodeproj/project.pbxproj"
GUIDE="$REPO_ROOT/docs/ClipBuilder-Getting-Started.html"
DIST_DIR="$REPO_ROOT/dist"

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

# The only place the unit tests run: a failing suite aborts the release
# before any version bump, build or publish. There is no commit-time gate.
# The user may choose to skip them for this release.
if [[ -z $RUN_TESTS ]]; then
    if [[ -t 0 && -t 1 ]]; then
        printf 'Run the unit tests before releasing? [Y/n] '
        read -r answer
        case "$answer" in
            [nN]|[nN][oO]) RUN_TESTS=0 ;;
            *) RUN_TESTS=1 ;;
        esac
    else
        RUN_TESTS=1
    fi
fi
if [[ $RUN_TESTS == 1 ]]; then
    step "Running unit tests"
    "$REPO_ROOT/scripts/test.sh" || { echo "error: unit tests failed — release aborted (nothing was bumped, built or published)" >&2; exit 1; }
else
    step "Skipping unit tests (chosen for this release)"
fi

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

# ------------------------------------------------------------- build + sign
step "Building and notarizing pkg"
"$REPO_ROOT/scripts/make_pkg.sh"
PKG="$DIST_DIR/ClipBuilder-$VERSION.pkg"
[[ -f $PKG ]] || { echo "error: expected $PKG from make_pkg.sh" >&2; exit 1; }

# --------------------------------------------------------- commit + publish
step "Committing, tagging v$VERSION, pushing"
git -C "$REPO_ROOT" add "$PBXPROJ" "$GUIDE"
git -C "$REPO_ROOT" commit -m "Release $VERSION (build $NEW_BUILD)"
git -C "$REPO_ROOT" tag "v$VERSION"
git -C "$REPO_ROOT" push origin HEAD "v$VERSION"

step "Creating GitHub release v$VERSION"
gh release create "v$VERSION" "$PKG" --title "Clip Builder $VERSION" --generate-notes

step "Done — released Clip Builder $VERSION"
