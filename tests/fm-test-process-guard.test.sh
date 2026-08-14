#!/usr/bin/env bash
# Verify that the suite runner exposes and reaps an escaped test child.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/tests/run-tests.sh"
TMP_ROOT=

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-process-guard.XXXXXX")
fixture="$TMP_ROOT/leaks-child.sh"
output="$TMP_ROOT/runner.out"
cat > "$fixture" <<'SH'
#!/usr/bin/env bash
sleep 600 &
exit 0
SH
chmod +x "$fixture"

if "$RUNNER" "$fixture" >"$output" 2>&1; then
  fail "process guard accepted a test that leaked a child"
fi
grep -F 'not ok - process leak:' "$output" >/dev/null \
  || fail "process guard did not report the leaked child"

# Exercise the failure point that previously abandoned wake-queue appenders.
# The guarded run must still fail for the injected assertion, but never for a
# surviving process group member.
output="$TMP_ROOT/wake-failure.out"
if FM_TEST_FAIL_AFTER_BACKGROUND=1 "$RUNNER" "$ROOT/tests/fm-wake-queue.test.sh" >"$output" 2>&1; then
  fail "injected wake-queue failure unexpectedly passed"
fi
grep -F 'not ok - injected concurrent failure' "$output" >/dev/null \
  || fail "wake-queue failure fixture did not reach its background-job checkpoint"
! grep -F 'not ok - process leak:' "$output" >/dev/null \
  || fail "wake-queue failure left a process for the suite guard"

# The runner has its own signal cleanup: an interrupted suite must reap the
# currently-running test group, not merely notice it on its next invocation.
interrupt_fixture="$TMP_ROOT/interrupt-child.sh"
child_pid_file="$TMP_ROOT/interrupt-child.pid"
cat > "$interrupt_fixture" <<SH
#!/usr/bin/env bash
sleep 600 &
printf '%s\\n' "\$!" > "$child_pid_file"
wait
SH
chmod +x "$interrupt_fixture"
"$RUNNER" "$interrupt_fixture" >"$TMP_ROOT/runner-interrupt.out" 2>&1 &
runner_pid=$!
for _attempt in 1 2 3 4 5; do
  [ -s "$child_pid_file" ] && break
  sleep 0.1
done
[ -s "$child_pid_file" ] || fail "interrupted-run fixture did not start its child"
child_pid=$(cat "$child_pid_file")
kill -TERM "$runner_pid" 2>/dev/null || true
wait "$runner_pid" 2>/dev/null || true
sleep 0.2
! kill -0 "$child_pid" 2>/dev/null || fail "interrupted suite runner left child $child_pid"

# TERM is how an abandoned local test run is normally stopped.  Target the
# isolated group rather than this test's parent so the wake test's signal trap
# gets a real interruption and must reap its own children.
FM_TEST_PROCESS_GUARD=1 setsid "$ROOT/tests/fm-wake-queue.test.sh" >"$TMP_ROOT/wake-interrupt.out" 2>&1 &
wake_pid=$!
sleep 0.2
kill -TERM -- "-$wake_pid" 2>/dev/null || true
wait "$wake_pid" 2>/dev/null || true
sleep 0.2
left=$(ps -eo pgid=,stat= | awk -v group="$wake_pid" '$1 == group && $2 !~ /^Z/ { count++ } END { print count + 0 }')
[ "$left" -eq 0 ] || fail "interrupted wake-queue test left $left process(es)"
pass "suite process guard fails and reaps leaks; wake-queue failure and TERM leave none"
