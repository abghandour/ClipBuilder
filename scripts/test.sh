#!/bin/zsh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
DERIVED_DATA="${CLIPBUILDER_TEST_DERIVED_DATA:-/private/tmp/clipbuilder-tests}"

# Unit and integration tests. The integration suites disable themselves
# when ffmpeg/ffprobe are not installed, so no -skip-testing here.
# CLIPBUILDER_TEST_WORKERS caps the parallel test workers.
WORKERS=()
if [[ -n "${CLIPBUILDER_TEST_WORKERS:-}" ]]; then
    WORKERS=(-maximum-parallel-testing-workers "$CLIPBUILDER_TEST_WORKERS")
fi

run_tests() {
    xcodebuild \
        -quiet \
        -project "$REPO_ROOT/Clip Builder.xcodeproj" \
        -scheme MyApp \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGN_IDENTITY=- \
        test \
        -only-testing:ClipBuilderTests \
        "${WORKERS[@]}" \
        "$@"
}

# The full run launches every test at once and saturates the Mac for its
# first fifteen seconds; the suites below measure wall time (the script
# engine's ten-second budget, the main-thread watchdog) and time out in
# that stampede. They run in a second phase on an idle host. A targeted
# run (any argument) is a single phase.
TIMING_SUITES=(ScriptEngineTests ScriptReplayTests ScriptValidationTests ScriptExamplesTests
               BuilderScriptSessionTests MainThreadWatchdogTests)
if (( $# > 0 )); then
    run_tests "$@"
    exit 0
fi
SKIP=()
ONLY=()
for suite in "${TIMING_SUITES[@]}"; do
    SKIP+=(-skip-testing:"ClipBuilderTests/$suite")
    ONLY+=(-only-testing:"ClipBuilderTests/$suite")
done
run_tests "${SKIP[@]}"
run_tests "${ONLY[@]}"
