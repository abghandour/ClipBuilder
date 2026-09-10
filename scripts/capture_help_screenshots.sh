#!/bin/zsh
# Refreshes the screenshots embedded in the in-app Training Guide
# (ClipBuilder/Resources/help-*.png) by building the app, driving its UI,
# and capturing window shots. Run it by hand when the guide's UI changed;
# release.sh no longer calls it, so the shipped screenshots only change when
# someone runs this and commits the PNGs.
#
# Needs Screen Recording + Accessibility permissions for the terminal
# running it, and a profile with analyzed scenes (and ideally a few
# generated reels for the review-sheet shot). A capture that fails keeps
# the existing PNG instead of overwriting it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES_DIR="$REPO_ROOT/ClipBuilder/Resources"
APP="$REPO_ROOT/build/Build/Products/Release/Clip Builder.app"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

# A locked or asleep screen makes System Events and screencapture block
# forever; bail out so release.sh ships the existing screenshots instead.
SESSION_INFO="$(ioreg -n Root -d1 -a 2>/dev/null || true)"
if [[ $SESSION_INFO == *'CGSSessionScreenIsLocked</key>'*'<true/>'* ]]; then
    echo "==> Screen is locked — cannot drive the UI; keeping existing screenshots" >&2
    exit 1
fi

# Never kill an instance we did not launch (the user's Xcode Debug build runs
# against their real data); ship the existing screenshots instead.
if pgrep -lf 'Clip Builder.app/Contents/MacOS/Clip Builder' 2>/dev/null | grep -v -F "$APP" | grep -q .; then
    echo "==> Another Clip Builder instance is running (not the capture build) — keeping existing screenshots" >&2
    exit 1
fi

echo "==> Building app for screenshot capture"
# A running instance holds the binary and makes CodeSign fail — quit it first.
pkill -f -x "$APP/Contents/MacOS/Clip Builder" 2>/dev/null || true
xcodebuild -project "$REPO_ROOT/Clip Builder.xcodeproj" \
    -scheme MyApp \
    -configuration Release \
    -derivedDataPath "$REPO_ROOT/build" \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_IDENTITY=- \
    build > /dev/null

echo "==> Launching app"
pkill -f -x "$APP/Contents/MacOS/Clip Builder" 2>/dev/null || true
sleep 1
open "$APP"
sleep 5

# Consistent window geometry so screenshots are comparable across releases.
# The app has no AppleScript dictionary (no window IDs for `screencapture -l`),
# so captures are region-based on this known geometry.
WIN_X=60 WIN_Y=60 WIN_W=1280 WIN_H=800
osascript <<EOF
tell application "Clip Builder" to activate
tell application "System Events" to tell process "Clip Builder"
    set position of window 1 to {$WIN_X, $WIN_Y}
    set size of window 1 to {$WIN_W, $WIN_H}
end tell
EOF
sleep 1

FAILED=0

# capture_window <output-name>
capture_window() {
    local out="$RES_DIR/$1"
    local tmp
    tmp="$(mktemp -d)/$1"
    if screencapture -o -x -R "$WIN_X,$WIN_Y,$WIN_W,$WIN_H" "$tmp" 2>/dev/null && [[ -s $tmp ]]; then
        # screencapture stamps Finder metadata xattrs on the file; codesign
        # rejects bundle resources carrying them ("resource fork ... detritus").
        xattr -c "$tmp"
        mv "$tmp" "$out"
        echo "    captured $1"
    else
        echo "    ! failed to capture $1 — keeping existing" >&2
        FAILED=1
    fi
}

# capture_tab <output-name> <cmd-digit>
capture_tab() {
    osascript -e 'tell application "Clip Builder" to activate' \
              -e "tell application \"System Events\" to keystroke \"$2\" using command down"
    sleep 2
    capture_window "$1"
}

echo "==> Capturing tab screenshots"
capture_tab help-scenes.png 2
capture_tab help-wizard.png 4

# AI Lessons has no ⌘-digit shortcut; it is the last row of the sidebar's
# resources group, reached through the accessibility tree by its title.
echo "==> Capturing AI Lessons"
if osascript <<EOF 2>/dev/null | grep -q true
tell application "Clip Builder" to activate
tell application "System Events" to tell process "Clip Builder"
    try
        click (first static text of window 1 whose value is "AI Lessons")
        delay 2
        return exists (first static text of window 1 whose value is "What the AI reads…")
    on error
        return false
    end try
end tell
EOF
then
    capture_window help-lessons.png
else
    echo "    ! could not open AI Lessons — keeping existing help-lessons.png" >&2
    FAILED=1
fi

# The review sheet can't be reached reliably through the accessibility tree
# (SwiftUI's AX snapshots are flaky), so relaunch with the LibraryView hook
# that auto-opens the sheet for the newest reel. Nothing opens if the
# library is empty — generate a reel first for a fresh shot.
echo "==> Capturing review sheet"
pkill -f -x "$APP/Contents/MacOS/Clip Builder" 2>/dev/null || true
sleep 1
open "$APP" --args --auto-open-review
sleep 5
osascript <<EOF
tell application "Clip Builder" to activate
tell application "System Events" to tell process "Clip Builder"
    set position of window 1 to {$WIN_X, $WIN_Y}
    set size of window 1 to {$WIN_W, $WIN_H}
end tell
tell application "System Events" to keystroke "6" using command down
EOF
sleep 4
if osascript -e 'tell application "System Events" to tell process "Clip Builder" to exists sheet 1 of window 1' | grep -q true; then
    capture_window help-review.png
else
    echo "    ! review sheet did not open (empty library?) — keeping existing help-review.png" >&2
    FAILED=1
fi

pkill -f -x "$APP/Contents/MacOS/Clip Builder" 2>/dev/null || true
if [[ $FAILED -ne 0 ]]; then
    echo "==> Done with warnings — some screenshots were not refreshed"
    exit 1
fi
echo "==> Done — screenshots refreshed in ClipBuilder/Resources/"
