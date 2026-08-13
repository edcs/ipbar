#!/usr/bin/env bash
#
# Turns Conventional Commit subjects into release notes.
#
#   ./Tools/release-notes.sh [from-ref] [to-ref]
#
# With no arguments it covers everything since the previous tag. Written here
# rather than pulled in as an action: the commit format is already enforced by
# .githooks/commit-msg, so this is a read of the log rather than a dependency
# with write access to the repo.
#
set -euo pipefail

TO="${2:-HEAD}"
if [ -n "${1:-}" ]; then
    FROM="$1"
else
    # The tag before this one, or the very beginning if this is the first.
    FROM=$(git describe --tags --abbrev=0 "${TO}^" 2>/dev/null || true)
fi
RANGE=${FROM:+"$FROM..$TO"}
RANGE=${RANGE:-"$TO"}

# Tolerated rather than required: a clone with no origin still gets notes,
# just without links.
REPO=$(git remote get-url origin 2>/dev/null \
    | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##' || true)

breaking=""; feat=""; fix=""; perf=""; other=""

while IFS=$'\x1f' read -r sha subject; do
    [ -n "$subject" ] || continue

    # type(scope)!: description
    if [[ "$subject" =~ ^([a-z]+)(\(([^\)]+)\))?(!)?:[[:space:]]*(.*)$ ]]; then
        type="${BASH_REMATCH[1]}"
        scope="${BASH_REMATCH[3]}"
        bang="${BASH_REMATCH[4]}"
        text="${BASH_REMATCH[5]}"
    else
        # Merges and anything else that slipped past the hook.
        continue
    fi

    link=""
    [ -n "$REPO" ] && link=" ([\`${sha:0:7}\`](https://github.com/$REPO/commit/$sha))"
    entry="- ${scope:+**$scope**: }${text}${link}"

    if [ -n "$bang" ]; then
        breaking="${breaking}${entry}"$'\n'
        continue
    fi
    case "$type" in
        feat) feat="${feat}${entry}"$'\n' ;;
        fix)  fix="${fix}${entry}"$'\n' ;;
        perf) perf="${perf}${entry}"$'\n' ;;
        docs|style|refactor|test|build|ci|chore|revert) other="${other}${entry}"$'\n' ;;
        *)    other="${other}${entry}"$'\n' ;;
    esac
done < <(git log --no-merges --reverse --format="%H%x1f%s" $RANGE)

section() {
    [ -n "$2" ] || return 0
    printf '## %s\n\n%s\n' "$1" "$2"
}

section "Breaking changes" "$breaking"
section "Added" "$feat"
section "Fixed" "$fix"
section "Performance" "$perf"

# The rest is real work but not news, so it is present and folded away rather
# than padding the top of the notes.
if [ -n "$other" ]; then
    printf '<details>\n<summary>Other changes</summary>\n\n%s\n</details>\n' "$other"
fi

if [ -z "$breaking$feat$fix$perf$other" ]; then
    echo "No changes recorded."
fi

if [ -n "$FROM" ] && [ -n "$REPO" ]; then
    printf '\n**Full changelog**: https://github.com/%s/compare/%s...%s\n' "$REPO" "$FROM" "$TO"
fi
