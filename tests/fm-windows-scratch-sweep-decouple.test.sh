#!/usr/bin/env bash
# The Windows scratch sweep must never fail the supervisor cycle it rides
# inside: a sweep failure is swallowed (logged via the sweep's own exit,
# not cycle_failed) while the snapshot/board still get written.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  [ -z "${TMP_ROOT:-}" ] || rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-windows-scratch-sweep-decouple.XXXXXX") || exit 1
HOME_DIR="$TMP_ROOT/home"
BOARD_DIR="$TMP_ROOT/board"
BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$HOME_DIR/state" "$BOARD_DIR" "$BIN_DIR"

# Mirror the real bin/ so fm-supervisor.sh finds fm-wake-lib.sh, fm-tmux-lib.sh,
# fm-board.sh, fm-windows-scratch-sweep.ps1, etc. next to a stubbed-out
# fm-windows-scratch-sweep.sh.
cp "$ROOT"/bin/*.sh "$ROOT"/bin/*.ps1 "$BIN_DIR/"

cat > "$BIN_DIR/fm-windows-scratch-sweep.sh" <<'SH'
#!/usr/bin/env bash
echo "stub sweep: simulated failure" >&2
exit 1
SH
chmod +x "$BIN_DIR/fm-windows-scratch-sweep.sh"

run_supervisor() {
  FM_HOME="$HOME_DIR" \
    FM_BOARD_DIR="$BOARD_DIR" \
    FM_WINDOWS_SCRATCH_SWEEP_INTERVAL=3600 \
    "$BIN_DIR/fm-supervisor.sh" --once
}

run_supervisor || fail "supervisor cycle failed even though only the Windows scratch sweep failed"

SNAPSHOT="$HOME_DIR/state/firstmate-supervisor.tsv"
BOARD="$BOARD_DIR/board.html"
ERROR_FILE="$HOME_DIR/state/.firstmate-supervisor.error"

[ -s "$SNAPSHOT" ] || fail "machine-readable snapshot was not written after a sweep failure"
[ -s "$BOARD" ] || fail "board was not written after a sweep failure"
[ -f "$ERROR_FILE" ] && grep -q "windows-scratch-sweep-failed" "$ERROR_FILE" &&
  fail "cycle recorded windows-scratch-sweep-failed instead of decoupling the sweep"

pass "a failing Windows scratch sweep does not fail the supervisor cycle"

# A successful sweep should be stamped so the next cycle inside the interval
# skips re-invoking it.
CALL_LOG="$TMP_ROOT/sweep-calls.log"
cat > "$BIN_DIR/fm-windows-scratch-sweep.sh" <<SH
#!/usr/bin/env bash
echo "call" >> "$CALL_LOG"
exit 0
SH
chmod +x "$BIN_DIR/fm-windows-scratch-sweep.sh"

run_supervisor || fail "supervisor cycle failed on a successful sweep"
[ -f "$CALL_LOG" ] || fail "successful sweep was never invoked"
first_calls=$(wc -l < "$CALL_LOG")
[ "$first_calls" = "1" ] || fail "expected exactly one sweep invocation, saw $first_calls"

run_supervisor || fail "second supervisor cycle failed"
second_calls=$(wc -l < "$CALL_LOG")
[ "$second_calls" = "1" ] || fail "sweep was re-invoked within its interval ($second_calls calls)"

pass "a successful Windows scratch sweep is stamped and not re-invoked within its interval"
