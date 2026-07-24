#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-supervisor-tests.XXXXXX") || exit 1
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/bin"
BOARD_DIR="$TMP_ROOT/board"
TMUX_LOG="$TMP_ROOT/tmux.log"
mkdir -p "$HOME_DIR/state" "$FAKEBIN" "$BOARD_DIR"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

cleanup() {
  local pid_file pid
  for pid_file in "$TMP_ROOT"/*/state/.firstmate-supervisor.pid; do
    [ -f "$pid_file" ] || continue
    pid=$(cat "$pid_file" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) ;; *) kill "$pid" 2>/dev/null || true ;; esac
  done
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TMUX_LOG"
case "$*" in
  *send-keys*)
    : > "$FM_TEST_TMUX_LOG.injected"
    exit 99
    ;;
  *display-message*fm-busy*)
    printf '%%1\n'
    ;;
  *capture-pane*fm-busy*)
    printf 'Working (8s · esc to interrupt)\n'
    ;;
  *display-message*fm-waiting*)
    printf '%%2\n'
    ;;
  *capture-pane*fm-waiting*)
    printf 'idle prompt\n'
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$FAKEBIN/tmux"

write_meta() { # <id> <window> <deadline>
  {
    printf 'window=%s\n' "$2"
    printf 'kind=ship\n'
    printf 'receipt-deadline=%s\n' "$3"
  } > "$HOME_DIR/state/$1.meta"
}

now=$(date +%s)
write_meta pre-deadline fm-waiting "$((now + 300))"
write_meta post-deadline fm-waiting 1
write_meta busy-after-deadline fm-busy 1
write_meta terminal-task fm-gone 1
write_meta failed-task fm-gone 1
write_meta missing-process fm-gone "$((now + 300))"
printf 'done: PR https://example.test/42 checks green\n' > "$HOME_DIR/state/terminal-task.status"
printf 'failed: deterministic test failure\n' > "$HOME_DIR/state/failed-task.status"

run_supervisor() {
  run_supervisor_home "$HOME_DIR" "$BOARD_DIR" "$@"
}

run_supervisor_home() {
  local home=$1 board=$2
  shift 2
  PATH="$FAKEBIN:$PATH" \
    FM_TEST_TMUX_LOG="$TMUX_LOG" \
    FM_HOME="$home" \
    FM_BOARD_DIR="$board" \
    "$ROOT/bin/fm-supervisor.sh" "$@"
}

run_supervisor --once || fail "controlled supervisor cycle failed"
SNAPSHOT="$HOME_DIR/state/firstmate-supervisor.tsv"
BOARD="$BOARD_DIR/board.html"
[ -s "$SNAPSHOT" ] || fail "machine-readable snapshot was not written"
[ -s "$BOARD" ] || fail "board was not written"
grep -F $'task\tpre-deadline\tactive-unverified\t' "$SNAPSHOT" >/dev/null \
  || fail "pre-deadline missing receipt was not active-unverified"
grep -F $'task\tpost-deadline\tstalled\treceipt deadline passed\t' "$SNAPSHOT" >/dev/null \
  || fail "post-deadline missing receipt was not stalled"
grep -F $'task\tterminal-task\tterminal\tterminal receipt recorded\t' "$SNAPSHOT" >/dev/null \
  || fail "terminal receipt was not terminal"
grep -F $'task\tbusy-after-deadline\tactive\tbusy pane observed\t' "$SNAPSHOT" >/dev/null \
  || fail "live busy task was falsely stalled"
grep -F $'task\tmissing-process\tstalled\trecorded process is missing\t' "$SNAPSHOT" >/dev/null \
  || fail "missing recorded process was not stalled"
grep -F $'\tpost-deadline\tmissed-receipt-deadline\tobtain the declared receipt or investigate the direct report' \
  "$HOME_DIR/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "missed deadline did not produce an actionable durable escalation"
grep -F $'\tmissing-process\tmissing-process\tinspect or relaunch the recorded direct-report process' \
  "$HOME_DIR/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "missing process did not produce an actionable durable escalation"
grep -F $'\tfailed-task\tfailed-receipt\tact on terminal receipt: failed: deterministic test failure' \
  "$HOME_DIR/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "failed receipt did not produce an actionable durable escalation"

first_generated=$(awk -F '\t' '$1 == "generated-at" { print $2 }' "$SNAPSHOT")
first_board_generated=$(sed -n 's/.*const generated=\([0-9][0-9]*\),.*/\1/p' "$BOARD")
sleep 1
FM_HOME="$HOME_DIR" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append heartbeat controlled "controlled wake"' -- "$ROOT" \
  || fail "could not append controlled wake"
run_supervisor --once || fail "wake reconciliation cycle failed"
second_generated=$(awk -F '\t' '$1 == "generated-at" { print $2 }' "$SNAPSHOT")
second_board_generated=$(sed -n 's/.*const generated=\([0-9][0-9]*\),.*/\1/p' "$BOARD")
[ "$second_generated" -gt "$first_generated" ] || fail "controlled wake did not advance snapshot"
[ "$second_board_generated" -gt "$first_board_generated" ] || fail "controlled wake did not advance board"
grep -Fx $'wake-count\t1' "$SNAPSHOT" >/dev/null || fail "snapshot did not reconcile controlled wake"
[ -s "$HOME_DIR/state/.wake-queue" ] || fail "supervisor consumed Firstmate-owned wake queue"
[ ! -e "$TMUX_LOG.injected" ] || fail "normal supervisor cycle injected chat"
if grep -F 'send-keys' "$TMUX_LOG" >/dev/null; then
  fail "normal supervisor attempted chat injection"
fi

FM_SUPERVISOR_INTERVAL=1 run_supervisor start >/dev/null || fail "supervisor start failed"
for _ in 1 2 3 4 5; do
  first_pid=$(cat "$HOME_DIR/state/.firstmate-supervisor.pid" 2>/dev/null || true)
  case "$first_pid" in ''|*[!0-9]*) sleep 1 ;; *) break ;; esac
done
case "${first_pid:-}" in ''|*[!0-9]*) fail "start did not publish PID receipt" ;; esac
kill -0 "$first_pid" 2>/dev/null || fail "published supervisor PID is not alive"
FM_SUPERVISOR_INTERVAL=1 run_supervisor restart >/dev/null || fail "supervisor restart failed"
second_pid=$(cat "$HOME_DIR/state/.firstmate-supervisor.pid" 2>/dev/null || true)
case "$second_pid" in ''|*[!0-9]*) fail "restart did not publish PID receipt" ;; esac
[ "$second_pid" != "$first_pid" ] || fail "restart retained the old owner"
kill -0 "$first_pid" 2>/dev/null && fail "restart left the old owner alive"
kill -0 "$second_pid" 2>/dev/null || fail "restart did not leave a live owner"
[ "$(cat "$HOME_DIR/state/.firstmate-supervisor.lock/pid")" = "$second_pid" ] \
  || fail "runtime singleton lock and PID receipt disagree"
third_start=$(FM_SUPERVISOR_INTERVAL=1 run_supervisor start) || fail "idempotent start failed"
printf '%s\n' "$third_start" | grep -F "already running: pid $second_pid" >/dev/null \
  || fail "idempotent start did not report the singleton owner"
[ "$(cat "$HOME_DIR/state/.firstmate-supervisor.pid")" = "$second_pid" ] \
  || fail "idempotent start created a duplicate owner"

OTHER_HOME="$TMP_ROOT/other-home"
OTHER_BOARD="$TMP_ROOT/other-board"
mkdir -p "$OTHER_HOME/state" "$OTHER_BOARD"
FM_SUPERVISOR_INTERVAL=1 run_supervisor_home "$OTHER_HOME" "$OTHER_BOARD" start >/dev/null \
  || fail "other-home supervisor start failed"
other_pid=$(cat "$OTHER_HOME/state/.firstmate-supervisor.pid" 2>/dev/null || true)
case "$other_pid" in ''|*[!0-9]*) fail "other-home supervisor did not publish a PID receipt" ;; esac
kill "$second_pid" 2>/dev/null || fail "could not stop current-home supervisor for ownership test"
for _ in 1 2 3 4 5; do
  kill -0 "$second_pid" 2>/dev/null || break
  sleep 1
done
kill -0 "$second_pid" 2>/dev/null && fail "current-home supervisor did not stop for ownership test"
mkdir -p "$HOME_DIR/state/.firstmate-supervisor.lock"
printf '%s\n' "$other_pid" > "$HOME_DIR/state/.firstmate-supervisor.lock/pid"
printf '%s\n' "$other_pid" > "$HOME_DIR/state/.firstmate-supervisor.pid"
FM_SUPERVISOR_INTERVAL=1 run_supervisor restart >/dev/null \
  || fail "restart did not recover from another home's reused PID"
own_pid=$(cat "$HOME_DIR/state/.firstmate-supervisor.pid" 2>/dev/null || true)
case "$own_pid" in ''|*[!0-9]*) fail "ownership-safe restart did not publish a PID receipt" ;; esac
[ "$own_pid" != "$other_pid" ] || fail "restart accepted another home's supervisor as owner"
kill -0 "$other_pid" 2>/dev/null || fail "restart terminated another home's supervisor"
kill -0 "$own_pid" 2>/dev/null || fail "ownership-safe restart did not leave a live owner"

printf 'ok - supervisor reconciles wakes, classifies contracts, escalates failures, stays no-chat, and restarts singleton-safe\n'
