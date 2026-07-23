#!/usr/bin/env bash
# Record a PR-ready task: records pr=<url> and pr-state=<category> in
# state/<id>.meta and arms the
# watcher's merge poll by writing state/<id>.check.sh, which prints one line iff
# the PR is merged (the watcher's check contract: output = wake firstmate,
# silence = keep sleeping).
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
if [ -f "$META" ] && ! grep -qxF "pr=$URL" "$META"; then
  echo "pr=$URL" >> "$META"
fi

# A PR without any GitHub check contexts is still review-ready.  Record that
# terminal category explicitly so every status surface can distinguish it from
# an active task that merely happens to remain in the In flight backlog section.
# Failure to read GitHub is deliberately non-fatal: the merge poll remains the
# source of truth and a later invocation can refine the category.
pr_state=pr-ready/checks
check_count=$(gh pr view "$URL" --json statusCheckRollup --jq '.statusCheckRollup | length' 2>/dev/null || true)
if [ "$check_count" = "0" ]; then
  pr_state=pr-ready/no-ci
fi
if [ -f "$META" ]; then
  meta_tmp="$META.tmp.$$"
  awk -v state="$pr_state" '
    /^pr-state=/ { next }
    { print }
    END { print "pr-state=" state }
  ' "$META" > "$meta_tmp" && mv "$meta_tmp" "$META"
fi

cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
echo "armed: state/$ID.check.sh polls $URL ($pr_state)"
