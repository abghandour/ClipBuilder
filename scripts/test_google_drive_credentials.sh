#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
check="$root/scripts/check_google_drive_credentials.sh"
cp "$root/Configuration/GoogleDrive-Info.plist" "$tmp/config.plist"
if /bin/sh "$check" "$tmp/config.plist" >"$tmp/log" 2>&1; then echo 'Empty credentials passed' >&2; exit 1; fi
if /bin/sh "$check" "$tmp/missing.plist" >"$tmp/log" 2>&1; then echo 'Missing credentials passed' >&2; exit 1; fi
/usr/libexec/PlistBuddy -c 'Set :GoogleOAuthClientID sample-id' "$tmp/config.plist"
if /bin/sh "$check" "$tmp/config.plist" >"$tmp/log" 2>&1; then echo 'Partial credentials passed' >&2; exit 1; fi
/usr/libexec/PlistBuddy -c 'Set :GoogleOAuthClientSecret sample-secret' "$tmp/config.plist"
/bin/sh "$check" "$tmp/config.plist" >"$tmp/log" 2>&1
test ! -s "$tmp/log"
/usr/libexec/PlistBuddy -c 'Set :GoogleOAuthClientSecret $(UNRESOLVED)' "$tmp/config.plist"
if /bin/sh "$check" "$tmp/config.plist" >"$tmp/log" 2>&1; then echo 'Unresolved credentials passed' >&2; exit 1; fi
mkdir -p "$tmp/repo/scripts"
cp "$root/scripts/make_pkg.sh" "$check" "$tmp/repo/scripts/"
if UNSIGNED=1 /bin/zsh "$tmp/repo/scripts/make_pkg.sh" >"$tmp/log" 2>&1; then echo 'Packaging accepted missing credentials' >&2; exit 1; fi
grep -q 'Google Drive release credentials are missing' "$tmp/log"
echo 'PASS: credential validation and packaging preflight'
