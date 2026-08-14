#!/usr/bin/env bash
# Run behavior tests in isolated process groups and fail if a test leaks one.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v setsid >/dev/null 2>&1; then
  echo "error: tests/run-tests.sh requires setsid to isolate test process groups" >&2
  exit 2
fi

group_members() {
  local group=$1
  ps -eo pid=,pgid=,stat=,args= | awk -v group="$group" '
    $2 == group && $3 !~ /^Z/ { print }
  '
}

group_count() {
  group_members "$1" | awk 'END { print NR + 0 }'
}

ACTIVE_GROUP=
RUNNER_CLEANING=0

reap_group() {
  local group=$1 members attempt
  kill -TERM -- "-$group" 2>/dev/null || true
  for attempt in 1 2 3 4 5; do
    members=$(group_members "$group")
    [ -z "$members" ] && return 0
    sleep 1
  done
  kill -KILL -- "-$group" 2>/dev/null || true
  members=$(group_members "$group")
  [ -z "$members" ]
}

cleanup_active_group() {
  [ "$RUNNER_CLEANING" = 1 ] && return
  RUNNER_CLEANING=1
  [ -n "$ACTIVE_GROUP" ] && reap_group "$ACTIVE_GROUP" || true
}

# If the runner itself is stopped, it owns the active test group and must not
# leave that test's background children behind for the outer shell to inherit.
trap cleanup_active_group EXIT
trap 'cleanup_active_group; exit 130' INT
trap 'cleanup_active_group; exit 143' TERM
trap 'cleanup_active_group; exit 129' HUP

run_one() {
  local script=$1 pid rc before after members
  FM_TEST_PROCESS_GUARD=1 setsid "$script" &
  pid=$!
  ACTIVE_GROUP=$pid
  # Exclude the test leader itself: at launch there should be no descendants.
  before=$(group_count "$pid")
  before=$((before > 0 ? before - 1 : 0))

  if wait "$pid"; then
    rc=0
  else
    rc=$?
  fi

  # EXIT traps send TERM asynchronously.  Give a correctly-cleaning test a
  # short reap window, then treat every remaining group member as a leak.
  members=
  for _attempt in 1 2 3 4 5; do
    members=$(group_members "$pid")
    [ -z "$members" ] && break
    sleep 0.1
  done
  after=$(printf '%s\n' "$members" | awk 'NF { count++ } END { print count + 0 }')
  if [ "$after" -ne 0 ]; then
    printf 'not ok - process leak: %s (descendants before=%s after=%s)\n' \
      "$script" "$before" "$after" >&2
    printf '%s\n' "$members" >&2
    reap_group "$pid" || true
    ACTIVE_GROUP=
    return 1
  fi

  if [ "$rc" -ne 0 ]; then
    ACTIVE_GROUP=
    return "$rc"
  fi
  printf 'process guard: %s descendants before=%s after=0\n' "$script" "$before"
  ACTIVE_GROUP=
}

if [ "$#" -eq 0 ]; then
  set -- "$ROOT"/tests/*.test.sh
fi

status=0
for test_script in "$@"; do
  run_one "$test_script" || status=1
done
exit "$status"
