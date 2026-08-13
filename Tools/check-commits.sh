#!/usr/bin/env bash
#
# Runs the commit-msg hook against every commit in a range, so CI enforces
# exactly what the local hook does.
#
#   ./Tools/check-commits.sh                 # just HEAD
#   ./Tools/check-commits.sh origin/main..HEAD
#
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
HOOK="$ROOT/.githooks/commit-msg"
RANGE="${1:-HEAD~1..HEAD}"

# A new branch reports an all-zero "before" sha; there is no range to diff
# against, so fall back to the tip commit.
if printf '%s' "$RANGE" | grep -q '^0\{40\}'; then
    RANGE="HEAD~1..HEAD"
fi

# An unborn branch has no HEAD at all, which is what CI sees on the very first
# push. Nothing to validate is a pass, not an error.
if ! git rev-parse HEAD >/dev/null 2>&1; then
    echo "✓ No commits yet."
    exit 0
fi

if ! COMMITS=$(git rev-list "$RANGE" 2>/dev/null); then
    echo "No usable range ($RANGE). Checking HEAD only."
    COMMITS=$(git rev-parse HEAD)
fi

if [ -z "$COMMITS" ]; then
    echo "✓ No commits to check."
    exit 0
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

FAILED=0
COUNT=0
for sha in $COMMITS; do
    COUNT=$((COUNT + 1))
    git log -1 --format=%B "$sha" > "$TMP"
    if ! "$HOOK" "$TMP"; then
        echo "  ...in commit $(git log -1 --format='%h' "$sha")" >&2
        FAILED=$((FAILED + 1))
    fi
done

if [ "$FAILED" -gt 0 ]; then
    echo "✗ $FAILED of $COUNT commit message(s) rejected." >&2
    echo "  Rewrite them with: git rebase -i --reword $RANGE" >&2
    exit 1
fi

echo "✓ $COUNT commit message(s) conform to Conventional Commits."
