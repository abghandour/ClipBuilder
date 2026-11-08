#!/bin/zsh
# Blesses a published Clip Builder release as stable and names it
# (docs/Stable-Beta-Channels-Plan.md, Blessing and Release names):
#   1. Checks the name (one to three words: letters, digits, hyphens; never
#      used before, per ReleaseNames.json) and that v<version> is published.
#   2. Checks out tag v<version> in a throwaway git worktree, so the stable
#      binary comes from the tagged commit whatever the working tree holds.
#   3. Writes ClipBuilder/Resources/ReleaseName.txt there and builds, signs
#      and notarizes the stable pkg with that tag's own scripts/make_pkg.sh.
#      The About box then reads "Version <version> “<name>” (<build>)".
#   4. Checks the pkg's payload carries the name and the version.
#   5. Uploads ClipBuilder-<version>.pkg to the release (replacing the
#      unnamed one), retitles it "Clip Builder <version> “<name>”", clears
#      the prerelease flag, and marks it latest unless a newer stable exists.
#   6. Records the name in ReleaseNames.json, points the Getting Started
#      guide at the stable pkg, commits "Bless <version> as stable" on main
#      and pushes.
#
# Usage: scripts/bless.sh <version> ["<name>"] [--dry-run]
#   Without a name and with a terminal, asks for one.
#   --dry-run  runs every check and prints the plan; builds and publishes
#              nothing.
#
# Environment (defaults match this machine's setup):
#   DEVELOPER_DIR    Xcode to build with
#   NOTARY_PROFILE   notarytool keychain profile
set -euo pipefail

DRY_RUN=0
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        -*) echo "error: unknown option $arg" >&2; exit 2 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
(( ${#POSITIONAL[@]} >= 1 && ${#POSITIONAL[@]} <= 2 )) \
    || { echo "usage: scripts/bless.sh <version> [\"<name>\"] [--dry-run]" >&2; exit 2; }
VERSION=${POSITIONAL[1]#v}
NAME=${POSITIONAL[2]:-}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAMES_FILE="$REPO_ROOT/ReleaseNames.json"
GUIDE="$REPO_ROOT/docs/ClipBuilder-Getting-Started.html"
DIST_DIR="$REPO_ROOT/dist"
TAG="v$VERSION"
PKG_NAME="ClipBuilder-$VERSION.pkg"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export NOTARY_PROFILE="${NOTARY_PROFILE:-ClipBuilderNotary}"

step() { echo; echo "==> $1"; }
fail() { echo "error: $1" >&2; exit 1; }

# 0 when $1 > $2 as dotted versions (1.152 > 1.99).
version_gt() {
    local -a a b
    a=("${(@s:.:)1}") b=("${(@s:.:)2}")
    local i n=$(( ${#a} > ${#b} ? ${#a} : ${#b} ))
    for (( i = 1; i <= n; i++ )); do
        (( ${a[i]:-0} > ${b[i]:-0} )) && return 0
        (( ${a[i]:-0} < ${b[i]:-0} )) && return 1
    done
    return 1
}

# ------------------------------------------------------------ preconditions
[[ $VERSION =~ '^[0-9]+(\.[0-9]+)+$' ]] || fail "version must look like 1.152, got '$VERSION'"
for tool in gh git jq xcrun pkgutil; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool not found"
done
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    # The bless commit goes on main; a dry run commits nothing.
    [[ $DRY_RUN == 1 ]] && echo "warning: working tree has uncommitted changes (a real run refuses)" >&2 \
        || fail "working tree has uncommitted changes — commit or stash first (the bless commit goes on main)"
fi
[[ "$(git -C "$REPO_ROOT" branch --show-current)" == main ]] || fail "check out main first"

step "Checking main and tag $TAG against origin"
git -C "$REPO_ROOT" fetch --quiet --tags origin main
git -C "$REPO_ROOT" merge-base --is-ancestor HEAD origin/main \
    || fail "main has commits that are not on origin — push them first"
[[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" == "$(git -C "$REPO_ROOT" rev-parse origin/main)" ]] \
    || fail "main is behind origin — pull first"
git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null || fail "no tag $TAG"
git -C "$REPO_ROOT" cat-file -e "$TAG:ClipBuilder/Services/ReleaseName.swift" 2>/dev/null \
    || fail "$TAG predates release names (1.152); its About box cannot show a name"

RELEASE_JSON=$(gh release view "$TAG" --json tagName,isPrerelease,isDraft,name,assets 2>/dev/null) \
    || fail "no GitHub release for $TAG"
[[ "$(jq -r .isDraft <<<"$RELEASE_JSON")" == false ]] || fail "$TAG is a draft; publish it first"
WAS_PRERELEASE=$(jq -r .isPrerelease <<<"$RELEASE_JSON")
HAS_STABLE_PKG=$(jq -r --arg n "$PKG_NAME" '[.assets[].name] | index($n) != null' <<<"$RELEASE_JSON")

# ------------------------------------------------------------------- name
if [[ -z $NAME ]]; then
    [[ -t 0 && -t 1 ]] || fail "give the release a name: scripts/bless.sh $VERSION \"<name>\""
    printf 'Name for Clip Builder %s: ' "$VERSION"
    read -r NAME
fi
NAME=$(print -r -- "$NAME" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')
[[ $NAME =~ '^[A-Za-z0-9]+(-[A-Za-z0-9]+)*( [A-Za-z0-9]+(-[A-Za-z0-9]+)*){0,2}$' ]] \
    || fail "a release name is one to three words of letters, digits and hyphens, got '$NAME'"
(( ${#NAME} <= 32 )) || fail "keep the name to 32 characters or fewer"

NAMES_JSON='{}'
[[ -f $NAMES_FILE ]] && NAMES_JSON=$(<"$NAMES_FILE")
jq -e 'type == "object"' <<<"$NAMES_JSON" >/dev/null || fail "ReleaseNames.json is not a JSON object"
EXISTING=$(jq -r --arg v "$VERSION" '.[$v] // empty' <<<"$NAMES_JSON")
[[ -z $EXISTING ]] || fail "$VERSION is already named “$EXISTING” in ReleaseNames.json"
TAKEN_BY=$(jq -r --arg n "$NAME" 'to_entries[] | select(.value | ascii_downcase == ($n | ascii_downcase)) | .key' <<<"$NAMES_JSON" | head -1)
[[ -z $TAKEN_BY ]] || fail "“$NAME” already names $TAKEN_BY; pick another"

# A stable release older than the current latest is blessed but does not
# take "latest" from it: stable apps never downgrade, new downloads should not.
LATEST_TAG=$(gh release view --json tagName -q .tagName 2>/dev/null || true)
MARK_LATEST=1
if [[ -n $LATEST_TAG && $LATEST_TAG != "$TAG" ]] && version_gt "${LATEST_TAG#v}" "$VERSION"; then
    MARK_LATEST=0
fi
TITLE="Clip Builder $VERSION “$NAME”"

step "Plan"
echo "    release:   $TAG ($([[ $WAS_PRERELEASE == true ]] && echo prerelease || echo already stable)$([[ $HAS_STABLE_PKG == true ]] && echo ", replacing its $PKG_NAME"))"
echo "    name:      $NAME"
echo "    title:     $TITLE"
echo "    latest:    $([[ $MARK_LATEST == 1 ]] && echo "yes" || echo "no, $LATEST_TAG is newer")"
echo "    commit:    Bless $VERSION as stable (ReleaseNames.json$([[ $MARK_LATEST == 1 ]] && echo ", Getting Started guide"))"
if [[ $DRY_RUN == 1 ]]; then
    step "Dry run — nothing built or published"
    exit 0
fi

# Notarization reads its credentials from the login keychain, which is
# locked while the screen is.
if ioreg -n Root -d1 -a 2>/dev/null | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
    fail "the screen is locked, so notarytool cannot read its keychain profile — unlock and rerun"
fi

# ------------------------------------------------------- worktree of the tag
WORK=$(mktemp -d "${TMPDIR:-/tmp}/clipbuilder-bless.XXXXXX")
TREE="$WORK/ClipBuilder"
cleanup() {
    git -C "$REPO_ROOT" worktree remove --force "$TREE" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

step "Checking out $TAG in a worktree"
git -C "$REPO_ROOT" worktree add --quiet --detach "$TREE" "$TAG"

# Local Swift packages are referenced relative to the repo (../VerticalCorn);
# link each beside the worktree so the build resolves them.
for rel in $(sed -n 's/^[[:space:]]*relativePath = \(\.\.\/[^;]*\);/\1/p' "$TREE/Clip Builder.xcodeproj/project.pbxproj"); do
    src="$REPO_ROOT/$rel"
    [[ -e $src ]] || fail "local package $rel not found beside the repo"
    ln -s "$(cd "$src" && pwd)" "$WORK/${rel#../}"
done

# Ignored local configuration (Google Drive credentials) never comes with a
# checkout; make_pkg.sh refuses to package without it.
for f in "$REPO_ROOT"/Configuration/*-Local.*(N); do
    cp "$f" "$TREE/Configuration/"
done

print -r -- "$NAME" > "$TREE/ClipBuilder/Resources/ReleaseName.txt"

# ------------------------------------------------------------- build + sign
step "Building and notarizing the stable pkg (this takes 5 to 10 minutes)"
# caffeinate keeps the display awake: an idle lock during the build locks
# the keychain, and notarytool then fails with "No Keychain password item".
caffeinate -di env CHANNEL=stable "$TREE/scripts/make_pkg.sh"
PKG="$TREE/dist/$PKG_NAME"
[[ -f $PKG ]] || fail "expected $PKG from make_pkg.sh"

step "Checking the pkg carries “$NAME” and $VERSION"
EXPANDED="$WORK/expanded"
pkgutil --expand-full "$PKG" "$EXPANDED" >/dev/null
APP=$(print -l "$EXPANDED"/*/Payload/Applications/*.app(N) | head -1)
[[ -n $APP ]] || fail "no app in the pkg payload"
[[ "$(head -1 "$APP/Contents/Resources/ReleaseName.txt" 2>/dev/null)" == "$NAME" ]] \
    || fail "the packaged app does not carry ReleaseName.txt with “$NAME”"
BUILT_VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)
[[ $BUILT_VERSION == "$VERSION" ]] || fail "the packaged app is $BUILT_VERSION, not $VERSION"
BUILD_NUMBER=$(defaults read "$APP/Contents/Info" CFBundleVersion)
mkdir -p "$DIST_DIR"
cp "$PKG" "$DIST_DIR/$PKG_NAME"

# ----------------------------------------------------------------- publish
step "Uploading $PKG_NAME to $TAG"
gh release upload "$TAG" "$DIST_DIR/$PKG_NAME" --clobber

step "Marking $TAG stable as “$NAME”"
EDIT_ARGS=(--title "$TITLE" --prerelease=false)
[[ $MARK_LATEST == 1 ]] && EDIT_ARGS+=(--latest) || EDIT_ARGS+=(--latest=false)
gh release edit "$TAG" "${EDIT_ARGS[@]}" >/dev/null

step "Recording the name and committing on main"
jq --arg v "$VERSION" --arg n "$NAME" '. + {($v): $n}' <<<"$NAMES_JSON" > "$WORK/names.json"
mv "$WORK/names.json" "$NAMES_FILE"
git -C "$REPO_ROOT" add "$NAMES_FILE"
if [[ $MARK_LATEST == 1 ]]; then
    # The stable download, never the beta's ClipBuilder-Beta-<version>.pkg.
    sed -i '' -E "s/ClipBuilder-[0-9.]+\.pkg/$PKG_NAME/g; s/Clip Builder [0-9.]+ — Getting Started/Clip Builder $VERSION — Getting Started/g" "$GUIDE"
    git -C "$REPO_ROOT" add "$GUIDE"
fi
git -C "$REPO_ROOT" commit --quiet -m "Bless $VERSION as stable (“$NAME”)"
git -C "$REPO_ROOT" push --quiet origin HEAD

step "Done — Clip Builder $VERSION “$NAME” (build $BUILD_NUMBER) is stable"
gh release view "$TAG" --json url -q .url
