#!/bin/zsh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
DERIVED_DATA="${CLIPBUILDER_TEST_DERIVED_DATA:-/private/tmp/clipbuilder-tests}"

# Unit and integration tests. The integration suites disable themselves
# when ffmpeg/ffprobe are not installed, so no -skip-testing here.
exec xcodebuild \
    -quiet \
    -project "$REPO_ROOT/Clip Builder.xcodeproj" \
    -scheme MyApp \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY=- \
    test \
    -only-testing:ClipBuilderTests
