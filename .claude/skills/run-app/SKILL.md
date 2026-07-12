---
name: run-app
description: Build and launch Clip Builder locally. Use when asked to run, build, launch, or screenshot the app, or to verify a change works in the real app. Covers the exact xcodebuild incantation (scheme, DEVELOPER_DIR, signing) this project needs.
---

# Build and run Clip Builder

## The one command that builds

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project "Clip Builder.xcodeproj" \
    -scheme MyApp \
    -configuration Release \
    -derivedDataPath build \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_IDENTITY=- \
    build 2>&1 | xcbeautify
```

Non-obvious parts, all required:

- **`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`** — `xcode-select` on this Mac points at the Command Line Tools; without the override, xcodebuild fails. (SwiftLint needs the same override for SourceKit.)
- **`-scheme MyApp`** — the scheme is `MyApp`, not "Clip Builder", despite the project/app name.
- **`CODE_SIGN_IDENTITY=-`** — ad-hoc signing for local runs. Never distribute these products; releases go through `scripts/release.sh`.
- **`xcbeautify`** is installed (`/opt/homebrew/bin/xcbeautify`) — always pipe through it; raw xcodebuild output is enormous. Drop the pipe only when debugging the build system itself.
- Run from the repo root. The project path contains a space — keep the quotes.

Built app: `build/Build/Products/Release/Clip Builder.app`

## Launching

```bash
# Kill any running instance first (open reuses a running app otherwise)
pkill -x "Clip Builder" 2>/dev/null
open "build/Build/Products/Release/Clip Builder.app"
```

To see stdout/stderr live (e.g. verifying log output or a crash), run the binary directly instead of `open`:

```bash
"build/Build/Products/Release/Clip Builder.app/Contents/MacOS/Clip Builder"
```

## Verifying behavior

- App data lives in `~/Documents/ClipBuilder/` (profiles as `<Name>.json`, SQLite DBs under `data/profiles_db/`, builder autosave under `data/builder_state/`, caches under `data/.cache/`). Inspecting these files after driving the UI is often the fastest verification.
- The app needs `ffmpeg` on PATH for all video features (installed via Homebrew on this machine).
- Deployment target is macOS 26; this machine runs macOS 27 with the 27 SDK — both fine.
- The XcodeBuildMCP server is configured for this project (build/run/log-capture tools) — use its tools if they're available in the session; this file's commands are the fallback that always works.

## Screenshots

`screencapture -x -o out.png` captures the screen; for a window capture use `screencapture -l $(osascript -e 'tell app "Clip Builder" to id of window 1') out.png` after the app is frontmost. Give the app a second to settle after launch.
