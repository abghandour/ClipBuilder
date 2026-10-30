#!/bin/zsh
# Start Clip Builder from the command line.
#
#   ./run.sh                 launch the last Release build (build/) on the normal data folder
#   ./run.sh --debug         launch the Debug build-for-testing product (build-debug/)
#   ./run.sh --build         rebuild Release first (ad-hoc signed), then launch
#   ./run.sh --fresh         quit a running instance first; otherwise a running app is reused
#   ./run.sh --log           run in the foreground with stdout/stderr in this terminal
#   ./run.sh --data <path>   point the app at another data folder (-ClipBuilderDataFolder)
#
# Options combine, e.g. ./run.sh --debug --fresh --log

set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

config=Release
derived=build
build=0
fresh=0
foreground=0
data=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) config=Debug; derived=build-debug ;;
    --build) build=1 ;;
    --fresh) fresh=1 ;;
    --log) foreground=1 ;;
    --data) data="$2"; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

app="$derived/Build/Products/$config/Clip Builder.app"

if (( build )); then
  action=build
  [[ $config == Debug ]] && action=build-for-testing
  xcodebuild -project "Clip Builder.xcodeproj" -scheme MyApp -configuration "$config" \
    -derivedDataPath "$derived" -destination 'generic/platform=macOS' CODE_SIGN_IDENTITY=- \
    "$action" 2>&1 | grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)" || true
fi

if [[ ! -d "$app" ]]; then
  echo "No app at $app — run with --build first." >&2
  exit 1
fi

if (( fresh )); then
  pkill -x "Clip Builder" 2>/dev/null || true
  sleep 1
fi

args=()
[[ -n $data ]] && args=(-ClipBuilderDataFolder "$data")

if (( foreground )); then
  exec "$app/Contents/MacOS/Clip Builder" "${args[@]}"
elif (( ${#args[@]} )); then
  open -n "$app" --args "${args[@]}"
else
  open "$app"
fi
