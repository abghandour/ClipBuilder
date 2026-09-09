#!/bin/zsh
# Shared by the pre-commit and pre-push hooks: run the unit tests once per
# tree. A tree that already passed (recorded in .git/tests-passed-tree) is
# not retested, so a commit verified by pre-commit pushes without a rerun.
#
# Usage: verify-tests.sh <tree-hash> <label>
set -euo pipefail

TREE="$1"
LABEL="$2"
REPO_ROOT="$(git rev-parse --show-toplevel)"
STAMP="$(git rev-parse --git-dir)/tests-passed-tree"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$TREE" ]]; then
    echo "[$LABEL] unit tests already passed for this tree; skipping."
    exit 0
fi

echo "[$LABEL] running unit tests (scripts/test.sh) — a few minutes…"
LOG="$(mktemp -t clipbuilder-hook-tests)"
if "$REPO_ROOT/scripts/test.sh" -retry-tests-on-failure -test-iterations 2 > "$LOG" 2>&1; then
    echo "$TREE" > "$STAMP"
    echo "[$LABEL] unit tests passed."
    rm -f "$LOG"
    exit 0
fi

echo "[$LABEL] UNIT TESTS FAILED — refusing to continue." >&2
grep -E "error:|Test case .* failed|Failing tests:|^\s+\S+Tests\.\S+\(\)$|\*\* TEST" "$LOG" >&2 || tail -40 "$LOG" >&2
echo "Full log: $LOG" >&2
echo "Fix the tests, or for a deliberate exception use --no-verify (the pre-push hook will still run them)." >&2
exit 1
