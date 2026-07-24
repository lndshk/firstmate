#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-supervisor-tests.XXXXXX") || exit 1
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/bin"
BOARD_DIR="$TMP_ROOT/board"
TMUX_LOG="$TMP_ROOT/tmux.log"
SLEEP_LOG="$TMP_ROOT/sleep.log"
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
    case "$pid" in
      ''|*[!0-9]*) ;;
      *) kill -CONT "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true ;;
    esac
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
  *display-message*fm-unreadable*)
    printf '%%3\n'
    ;;
  *capture-pane*fm-unreadable*)
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$FAKEBIN/tmux"

cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_SLEEP_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TEST_SLEEP_LOG"
exec /bin/sleep "$@"
SH
chmod +x "$FAKEBIN/sleep"

cat > "$FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
target=
for arg in "$@"; do target=$arg; done
if [ "${FM_TEST_FAIL_RECEIPT_CURSOR:-0}" = 1 ]; then
  case "$target" in
    *".firstmate-supervisor.receipt-"*|*".firstmate-supervisor.task-"*"/receipt") exit 1 ;;
  esac
fi
if [ "${FM_TEST_FAIL_ESCALATION_MARKER:-0}" = 1 ]; then
  case "$target" in
    *".firstmate-supervisor.task-"*"/escalated-"*) exit 1 ;;
  esac
fi
if [ "${FM_TEST_FAIL_HEARTBEAT:-0}" = 1 ]; then
  case "$target" in
    *".firstmate-supervisor.heartbeat") exit 1 ;;
  esac
fi
if [ -n "${FM_TEST_DELAY_HEARTBEAT_SIGNAL:-}" ]; then
  case "$target" in
    *".firstmate-supervisor.heartbeat")
      : > "$FM_TEST_DELAY_HEARTBEAT_SIGNAL"
      /bin/sleep 1
      ;;
  esac
fi
exec /bin/mv "$@"
SH
chmod +x "$FAKEBIN/mv"

cat > "$FAKEBIN/rm" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_FAIL_ERROR_CLEAR:-0}" = 1 ]; then
  for arg in "$@"; do
    case "$arg" in
      *".firstmate-supervisor.error") exit 1 ;;
    esac
  done
fi
if [ "${FM_TEST_FAIL_RECEIPT_CLEAR:-0}" = 1 ]; then
  for arg in "$@"; do
    case "$arg" in
      *".firstmate-supervisor.task-"*"/receipt") exit 1 ;;
    esac
  done
fi
if [ "${FM_TEST_FAIL_TASK_STATE_CLEAR:-0}" = 1 ]; then
  for arg in "$@"; do
    case "$arg" in
      *".firstmate-supervisor.task-"*) exit 1 ;;
    esac
  done
fi
if [ "${FM_TEST_FAIL_TASK_UNLOCK:-0}" = 1 ]; then
  for arg in "$@"; do
    case "$arg" in
      *".firstmate-supervisor.state.lock/pid") exit 1 ;;
    esac
  done
fi
exec /bin/rm "$@"
SH
chmod +x "$FAKEBIN/rm"

cat > "$FAKEBIN/cat" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  *".firstmate-supervisor.state.lock/pid")
    case "${FM_TEST_TASK_UNLOCK_OWNER:-}" in
      missing) exit 1 ;;
      corrupt) printf 'not-a-pid\n'; exit 0 ;;
    esac
    ;;
esac
exec /bin/cat "$@"
SH
chmod +x "$FAKEBIN/cat"

write_meta() { # <id> <window> <deadline>
  {
    printf 'window=%s\n' "$2"
    printf 'kind=ship\n'
    printf 'receipt-deadline=%s\n' "$3"
  } > "$HOME_DIR/state/$1.meta"
}

task_state_dir() {
  printf '%s/state/.firstmate-supervisor.task-%s\n' \
    "$1" "$(printf '%s' "$2" | tr -c 'A-Za-z0-9_.-' '_')"
}

now=$(date +%s)
write_meta pre-deadline fm-waiting "$((now + 300))"
write_meta post-deadline fm-waiting 1
write_meta busy-after-deadline fm-busy 1
write_meta busy-dead-pid fm-busy 1
printf 'process-pid=2147483647\n' >> "$HOME_DIR/state/busy-dead-pid.meta"
write_meta unreadable-after-deadline fm-unreadable 1
printf 'process-pid=2147483647\n' >> "$HOME_DIR/state/unreadable-after-deadline.meta"
write_meta terminal-task fm-gone "$((now + 300))"
write_meta late-terminal fm-gone 1
write_meta transitioned-terminal fm-waiting "$((now + 1))"
write_meta batched-receipts fm-waiting "$((now - 5))"
write_meta failed-task fm-gone "$((now + 300))"
write_meta missing-process fm-gone "$((now + 300))"
write_meta invalid-deadline fm-waiting tomorrow
printf 'done: PR https://example.test/42 checks green\n' > "$HOME_DIR/state/terminal-task.status"
printf 'done: late terminal receipt\n' > "$HOME_DIR/state/late-terminal.status"
printf 'working: on-time receipt\n' > "$HOME_DIR/state/transitioned-terminal.status"
printf 'working: stamped on-time receipt\t%s\ndone: stamped late receipt\t%s\n' \
  "$((now - 10))" "$now" > "$HOME_DIR/state/batched-receipts.status"
printf 'failed: deterministic test failure\n' > "$HOME_DIR/state/failed-task.status"

BRIEF_HOME="$TMP_ROOT/brief-home"
mkdir -p "$BRIEF_HOME/data" "$BRIEF_HOME/state"
FM_HOME="$BRIEF_HOME" FM_SECONDMATE_CHARTER=supervision \
  "$ROOT/bin/fm-brief.sh" receipt-writer --secondmate firstmate >/dev/null \
  || fail "timestamped status brief generation failed"
grep -F "printf '%s\\t%s\\n'" "$BRIEF_HOME/data/receipt-writer/brief.md" >/dev/null \
  || fail "generated brief did not stamp status receipts"
grep -F 'date +%s' "$BRIEF_HOME/data/receipt-writer/brief.md" >/dev/null \
  || fail "generated brief omitted the receipt epoch"

run_supervisor() {
  run_supervisor_home "$HOME_DIR" "$BOARD_DIR" "$@"
}

run_supervisor_home() {
  local home=$1 board=$2
  shift 2
  PATH="$FAKEBIN:$PATH" \
    FM_TEST_TMUX_LOG="$TMUX_LOG" \
    FM_TEST_SLEEP_LOG="$SLEEP_LOG" \
    FM_HOME="$home" \
    FM_BOARD_DIR="$board" \
    "$ROOT/bin/fm-supervisor.sh" "$@"
}

run_supervisor --once || fail "controlled supervisor cycle failed"
SNAPSHOT="$HOME_DIR/state/firstmate-supervisor.tsv"
BOARD="$BOARD_DIR/board.html"
[ -s "$SNAPSHOT" ] || fail "machine-readable snapshot was not written"
[ -s "$BOARD" ] || fail "board was not written"
snapshot_before_wake_error=$(cksum "$SNAPSHOT")
mkdir "$HOME_DIR/state/.wake-queue"
if run_supervisor --once >/dev/null 2>&1; then
  fail "unreadable wake queue produced a successful snapshot"
fi
[ "$(cksum "$SNAPSHOT")" = "$snapshot_before_wake_error" ] \
  || fail "unreadable wake queue replaced the last valid snapshot"
grep -F 'snapshot-write-failed' "$HOME_DIR/state/.firstmate-supervisor.error" >/dev/null \
  || fail "unreadable wake queue did not record a snapshot failure"
rmdir "$HOME_DIR/state/.wake-queue"
mkdir "$HOME_DIR/state/.wake-queue.seq"
if run_supervisor --once >/dev/null 2>&1; then
  fail "unreadable wake sequence produced a successful snapshot"
fi
[ "$(cksum "$SNAPSHOT")" = "$snapshot_before_wake_error" ] \
  || fail "unreadable wake sequence replaced the last valid snapshot"
rmdir "$HOME_DIR/state/.wake-queue.seq"
printf '1\n' > "$HOME_DIR/state/.wake-queue.seq"
printf '1\t1\theartbeat\theartbeat\theartbeat\n' > "$HOME_DIR/state/.wake-queue"
sequence_copy="$HOME_DIR/state/wake-sequence-copy"
FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_release() {
    local lockdir=$1 pid current
    current=${BASHPID:-$$}
    pid=$(cat "$lockdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    rm -f "$lockdir/pid" 2>/dev/null || true
    rmdir "$lockdir" 2>/dev/null || true
    : > "$STATE/.wake-queue.seq"
  }
  fm_wake_peek "$2" >/dev/null
' -- "$ROOT" "$sequence_copy" || fail "locked wake snapshot failed"
[ "$(cat "$sequence_copy")" = 1 ] \
  || fail "wake sequence was not copied before the queue lock was released"
rm -f "$HOME_DIR/state/.wake-queue" "$HOME_DIR/state/.wake-queue.seq" "$sequence_copy"
run_supervisor --once || fail "supervisor did not recover after wake read failures"
grep -F $'task\tpre-deadline\tactive-unverified\t' "$SNAPSHOT" >/dev/null \
  || fail "pre-deadline missing receipt was not active-unverified"
grep -F $'task\tpost-deadline\tstalled\treceipt deadline passed\t' "$SNAPSHOT" >/dev/null \
  || fail "post-deadline missing receipt was not stalled"
grep -F $'task\tterminal-task\tterminal\tterminal receipt recorded\t' "$SNAPSHOT" >/dev/null \
  || fail "terminal receipt was not terminal"
grep -F $'task\tbusy-after-deadline\tactive\tbusy pane observed\t' "$SNAPSHOT" >/dev/null \
  || fail "live busy task was falsely stalled"
grep -F $'task\tbusy-dead-pid\tactive\tbusy pane observed\t' "$SNAPSHOT" >/dev/null \
  || fail "busy pane was stalled by a dead declared PID"
grep -F $'task\tunreadable-after-deadline\tactive-unverified\tpane activity could not be verified\t' "$SNAPSHOT" >/dev/null \
  || fail "unreadable pane was falsely stalled"
grep -F $'task\tlate-terminal\tterminal\tterminal receipt recorded\t' "$SNAPSHOT" >/dev/null \
  || fail "late terminal receipt was not terminal"
grep -F $'task\tbatched-receipts\tterminal\tterminal receipt recorded\tdone: stamped late receipt\t' "$SNAPSHOT" >/dev/null \
  || fail "stamped receipt metadata leaked into the task snapshot"
grep -F $'task\tmissing-process\tstalled\trecorded process is missing\t' "$SNAPSHOT" >/dev/null \
  || fail "missing recorded process was not stalled"
grep -F $'\tpost-deadline\tmissed-receipt-deadline\tobtain the declared receipt or investigate the direct report' \
  "$HOME_DIR/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "missed deadline did not produce an actionable durable escalation"
grep -F $'\tmissing-process\tmissing-process\tinspect or relaunch the recorded direct-report process' \
  "$HOME_DIR/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "missing process did not produce an actionable durable escalation"
grep -F $'\tbusy-dead-pid\tmissing-process\tinspect or relaunch the recorded direct-report process' \
  "$HOME_DIR/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "busy pane suppressed dead-PID escalation"
grep -F $'\tunreadable-after-deadline\tmissing-process\tinspect or relaunch the recorded direct-report process' \
  "$HOME_DIR/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "unreadable pane suppressed dead-PID escalation"
grep -F $'\tunreadable-after-deadline\tmissed-receipt-deadline\tobtain the declared receipt or investigate the direct report' \
  "$HOME_DIR/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "unreadable pane suppressed missed-receipt escalation"
grep -F $'\tlate-terminal\tmissed-receipt-deadline\tobtain the declared receipt or investigate the direct report' \
  "$HOME_DIR/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "late terminal receipt erased the deadline breach"
grep -F $'\tfailed-task\tfailed-receipt\tact on terminal receipt: failed: deterministic test failure' \
  "$HOME_DIR/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "failed receipt did not produce an actionable durable escalation"
grep -F $'contract\ttransitioned-terminal\tany-receipt\t' "$SNAPSHOT" \
  | grep -F $'\tsatisfied\t' >/dev/null \
  || fail "on-time receipt satisfaction was not explicit in the snapshot"
grep -F $'contract\tbatched-receipts\tany-receipt\t' "$SNAPSHOT" \
  | grep -F $'\tsatisfied\t' \
  | grep -F $'\t'"$((now - 10))" >/dev/null \
  || fail "first stamped receipt was lost behind a later receipt before reconciliation"
grep -F $'escalation\tpost-deadline\tmissed-receipt-deadline\tobtain the declared receipt or investigate the direct report' \
  "$SNAPSHOT" >/dev/null \
  || fail "current missed deadline was not represented in the snapshot"
grep -F 'Current escalation queue' "$BOARD" >/dev/null \
  || fail "board omitted the current escalation queue"
grep -F 'obtain the declared receipt or investigate the direct report' "$BOARD" >/dev/null \
  || fail "board omitted the current deadline action"
grep -F $'task\tinvalid-deadline\tstalled\tinvalid receipt deadline declaration\t-\t-\tfm-waiting\t-' \
  "$SNAPSHOT" >/dev/null \
  || fail "invalid deadline was not surfaced without a presented due time"
grep -F $'escalation\tinvalid-deadline\tinvalid-receipt-deadline\treplace the invalid receipt deadline with an absolute Unix epoch' \
  "$SNAPSHOT" >/dev/null \
  || fail "invalid deadline did not produce an actionable snapshot escalation"
if awk -F '\t' '$1 == "contract" && $2 == "invalid-deadline" { found=1 } END { exit !found }' \
  "$SNAPSHOT"; then
  fail "invalid deadline was presented as an enforceable contract"
fi
[ -s "$(task_state_dir "$HOME_DIR" late-terminal)/receipt" ] \
  || fail "late terminal receipt timing evidence was not persisted"

snapshot_before_status_error=$(cksum "$SNAPSHOT")
receipt_before_status_error=$(cksum "$(task_state_dir "$HOME_DIR" terminal-task)/receipt")
mv "$HOME_DIR/state/terminal-task.status" "$HOME_DIR/state/terminal-task.status.saved"
mkdir "$HOME_DIR/state/terminal-task.status"
if run_supervisor --once >/dev/null 2>&1; then
  fail "unreadable status path produced a successful snapshot"
fi
[ "$(cksum "$SNAPSHOT")" = "$snapshot_before_status_error" ] \
  || fail "unreadable status path replaced the last valid snapshot"
[ "$(cksum "$(task_state_dir "$HOME_DIR" terminal-task)/receipt")" = \
    "$receipt_before_status_error" ] \
  || fail "unreadable status path changed persisted receipt evidence"
snapshot_error_logs=$(awk -F '\t' '$2 == "snapshot-write-failed" { count++ } END { print count + 0 }' \
  "$HOME_DIR/state/.firstmate-supervisor.log")
if run_supervisor --once >/dev/null 2>&1; then
  fail "repeated unreadable status path produced a successful snapshot"
fi
[ "$(awk -F '\t' '$2 == "snapshot-write-failed" { count++ } END { print count + 0 }' \
    "$HOME_DIR/state/.firstmate-supervisor.log")" -eq "$snapshot_error_logs" ] \
  || fail "identical persistent cycle failure appended another log entry"
rm -f "$HOME_DIR/state/.firstmate-supervisor.error"
mkdir "$HOME_DIR/state/.firstmate-supervisor.error"
if run_supervisor --once >/dev/null 2>&1; then
  fail "unwritable error state produced a successful snapshot"
fi
if run_supervisor --once >/dev/null 2>&1; then
  fail "repeated unwritable error state produced a successful snapshot"
fi
[ "$(awk -F '\t' '$2 == "snapshot-write-failed" { count++ } END { print count + 0 }' \
    "$HOME_DIR/state/.firstmate-supervisor.log")" -eq "$snapshot_error_logs" ] \
  || fail "unwritable error state defeated authoritative log deduplication"
rmdir "$HOME_DIR/state/.firstmate-supervisor.error"
rmdir "$HOME_DIR/state/terminal-task.status"
mv "$HOME_DIR/state/terminal-task.status.saved" "$HOME_DIR/state/terminal-task.status"
run_supervisor --once || fail "supervisor did not recover after status read failure"

snapshot_before_meta_error=$(cksum "$SNAPSHOT")
mkdir "$HOME_DIR/state/nonregular.meta"
if run_supervisor --once >/dev/null 2>&1; then
  fail "non-regular metadata path produced a successful snapshot"
fi
[ "$(cksum "$SNAPSHOT")" = "$snapshot_before_meta_error" ] \
  || fail "non-regular metadata path replaced the last valid snapshot"
rmdir "$HOME_DIR/state/nonregular.meta"
run_supervisor --once || fail "supervisor did not recover after metadata path failure"

write_meta cursor-write fm-waiting "$((now + 300))"
printf 'working: cursor persistence must succeed\n' > "$HOME_DIR/state/cursor-write.status"
snapshot_before_cursor_error=$(cksum "$SNAPSHOT")
if FM_TEST_FAIL_RECEIPT_CURSOR=1 run_supervisor --once >/dev/null 2>&1; then
  fail "receipt cursor write failure produced a successful snapshot"
fi
[ "$(cksum "$SNAPSHOT")" = "$snapshot_before_cursor_error" ] \
  || fail "receipt cursor write failure replaced the last valid snapshot"
rm -f "$HOME_DIR/state/cursor-write.meta" "$HOME_DIR/state/cursor-write.status"
rm -rf "$(task_state_dir "$HOME_DIR" cursor-write)"
run_supervisor --once || fail "supervisor did not recover after receipt cursor write failure"

transitioned_version=$(cut -f2 "$(task_state_dir "$HOME_DIR" transitioned-terminal)/deadline")
sleep 2
printf 'done: terminal receipt after deadline\n' >> "$HOME_DIR/state/transitioned-terminal.status"
run_supervisor --once || fail "transitioned terminal receipt cycle failed"
grep -F $'task\ttransitioned-terminal\tterminal\tterminal receipt recorded\t' "$SNAPSHOT" >/dev/null \
  || fail "transitioned terminal receipt was not terminal"
grep -F $'contract\ttransitioned-terminal\tany-receipt\t' "$SNAPSHOT" \
  | grep -F $'\tsatisfied\t'"$transitioned_version"$'\t' >/dev/null \
  || fail "later receipt revoked the first on-time receipt satisfaction"
if awk -F '\t' '$1 == "escalation" && $2 == "transitioned-terminal" && $3 == "missed-receipt-deadline" { found=1 } END { exit !found }' \
  "$SNAPSHOT"; then
  fail "satisfied receipt contract became a current deadline escalation"
fi

printf 'needs-decision: choose deterministic recovery\n' >> "$HOME_DIR/state/failed-task.status"
run_supervisor --once || fail "distinct failed-receipt cycle failed"
failed_escalations=$(awk -F '\t' '$2 == "failed-task" && $3 == "failed-receipt" { count++ } END { print count + 0 }' \
  "$HOME_DIR/state/.firstmate-supervisor.escalations")
[ "$failed_escalations" -eq 2 ] || fail "distinct failed receipt was suppressed"
run_supervisor --once || fail "failed-receipt dedupe cycle failed"
failed_escalations=$(awk -F '\t' '$2 == "failed-task" && $3 == "failed-receipt" { count++ } END { print count + 0 }' \
  "$HOME_DIR/state/.firstmate-supervisor.escalations")
[ "$failed_escalations" -eq 2 ] || fail "unchanged failed receipt was escalated twice"
awk -F '\t' '$2 == "failed-task" && $3 == "failed-receipt" && NF == 5 && $5 != "" { found=1 } END { exit !found }' \
  "$HOME_DIR/state/.firstmate-supervisor.escalations" \
  || fail "durable escalation omitted its crash-recovery token"

ATOMIC_HOME="$TMP_ROOT/atomic-home"
ATOMIC_BOARD="$TMP_ROOT/atomic-board"
mkdir -p "$ATOMIC_HOME/state" "$ATOMIC_BOARD"
{
  printf 'window=fm-gone\n'
  printf 'kind=ship\n'
} > "$ATOMIC_HOME/state/atomic-task.meta"
if FM_TEST_FAIL_ESCALATION_MARKER=1 \
  run_supervisor_home "$ATOMIC_HOME" "$ATOMIC_BOARD" --once >/dev/null 2>&1; then
  fail "failed escalation marker persistence produced a successful cycle"
fi
[ ! -s "$ATOMIC_HOME/state/.firstmate-supervisor.escalations" ] \
  || fail "escalation was appended before its recovery marker persisted"
run_supervisor_home "$ATOMIC_HOME" "$ATOMIC_BOARD" --once \
  || fail "escalation did not recover after marker persistence failure"
run_supervisor_home "$ATOMIC_HOME" "$ATOMIC_BOARD" --once \
  || fail "recovered escalation dedupe cycle failed"
[ "$(awk -F '\t' '$2 == "atomic-task" && $3 == "missing-process" { count++ } END { print count + 0 }' \
    "$ATOMIC_HOME/state/.firstmate-supervisor.escalations")" -eq 1 ] \
  || fail "recovered escalation was not journaled exactly once"

PENDING_HOME="$TMP_ROOT/pending-home"
PENDING_BOARD="$TMP_ROOT/pending-board"
mkdir -p "$PENDING_HOME/state" "$PENDING_BOARD"
{
  printf 'window=fm-gone\n'
  printf 'kind=ship\n'
} > "$PENDING_HOME/state/pending-task.meta"
mkdir "$PENDING_HOME/state/.firstmate-supervisor.escalations"
if run_supervisor_home "$PENDING_HOME" "$PENDING_BOARD" --once >/dev/null 2>&1; then
  fail "failed escalation journal append produced a successful cycle"
fi
[ -s "$(task_state_dir "$PENDING_HOME" pending-task)/escalated-missing-process-condition" ] \
  || fail "failed escalation journal append did not preserve its pending record"
rmdir "$PENDING_HOME/state/.firstmate-supervisor.escalations"
printf 'done: condition resolved before journal recovery\n' \
  > "$PENDING_HOME/state/pending-task.status"
run_supervisor_home "$PENDING_HOME" "$PENDING_BOARD" --once \
  || fail "resolved escalation did not reconcile its pending journal record"
[ "$(awk -F '\t' '$2 == "pending-task" && $3 == "missing-process" { count++ } END { print count + 0 }' \
    "$PENDING_HOME/state/.firstmate-supervisor.escalations")" -eq 1 ] \
  || fail "resolved pending escalation was not journaled exactly once"
[ ! -e "$(task_state_dir "$PENDING_HOME" pending-task)/escalated-missing-process-condition" ] \
  || fail "resolved pending escalation marker was not cleared after journaling"

CLEAR_HOME="$TMP_ROOT/clear-home"
CLEAR_BOARD="$TMP_ROOT/clear-board"
mkdir -p "$CLEAR_HOME/state" "$CLEAR_BOARD"
{
  printf 'window=\n'
  printf 'kind=ship\n'
} > "$CLEAR_HOME/state/clear-task.meta"
mkdir -p "$(task_state_dir "$CLEAR_HOME" clear-task)"
printf 'stale receipt evidence\n' > "$(task_state_dir "$CLEAR_HOME" clear-task)/receipt"
if FM_TEST_FAIL_RECEIPT_CLEAR=1 \
  run_supervisor_home "$CLEAR_HOME" "$CLEAR_BOARD" --once >/dev/null 2>&1; then
  fail "receipt evidence removal failure produced a successful cycle"
fi
[ ! -e "$CLEAR_HOME/state/.firstmate-supervisor.heartbeat" ] \
  || fail "receipt evidence removal failure published a heartbeat"
run_supervisor_home "$CLEAR_HOME" "$CLEAR_BOARD" --once \
  || fail "supervisor did not recover after receipt evidence removal failure"

ERROR_CLEAR_HOME="$TMP_ROOT/error-clear-home"
ERROR_CLEAR_BOARD="$TMP_ROOT/error-clear-board"
mkdir -p "$ERROR_CLEAR_HOME/state" "$ERROR_CLEAR_BOARD"
printf '1\tsnapshot-write-failed\n' \
  > "$ERROR_CLEAR_HOME/state/.firstmate-supervisor.log"
printf '1\tsnapshot-write-failed\n' \
  > "$ERROR_CLEAR_HOME/state/.firstmate-supervisor.error"
if FM_TEST_FAIL_ERROR_CLEAR=1 \
  run_supervisor_home "$ERROR_CLEAR_HOME" "$ERROR_CLEAR_BOARD" --once >/dev/null 2>&1; then
  fail "error-state removal failure produced a successful cycle"
fi
[ ! -e "$ERROR_CLEAR_HOME/state/.firstmate-supervisor.heartbeat" ] \
  || fail "error-state removal failure published a heartbeat"
if FM_TEST_FAIL_HEARTBEAT=1 \
  run_supervisor_home "$ERROR_CLEAR_HOME" "$ERROR_CLEAR_BOARD" --once >/dev/null 2>&1; then
  fail "heartbeat persistence failure produced a successful cycle"
fi
[ "$(awk -F '\t' '$2 == "recovered" { count++ } END { print count + 0 }' \
  "$ERROR_CLEAR_HOME/state/.firstmate-supervisor.log")" -eq 0 ] \
  || fail "recovery was recorded before the complete cycle succeeded"
[ ! -e "$ERROR_CLEAR_HOME/state/.firstmate-supervisor.heartbeat" ] \
  || fail "failed recovery cycle retained a readiness heartbeat"
run_supervisor_home "$ERROR_CLEAR_HOME" "$ERROR_CLEAR_BOARD" --once \
  || fail "supervisor did not recover after error-state removal failure"
[ -s "$ERROR_CLEAR_HOME/state/.firstmate-supervisor.heartbeat" ] \
  || fail "successful recovery did not publish its final heartbeat"
[ "$(awk -F '\t' '$2 == "recovered" { count++ } END { print count + 0 }' \
  "$ERROR_CLEAR_HOME/state/.firstmate-supervisor.log")" -eq 1 ] \
  || fail "successful complete cycle did not record one recovery"

GENERATION_HOME="$TMP_ROOT/generation-home"
GENERATION_BOARD="$TMP_ROOT/generation-board"
mkdir -p "$GENERATION_HOME/state" "$GENERATION_BOARD"
{
  printf 'window=\n'
  printf 'kind=ship\n'
  printf 'generation=first-generation\n'
} > "$GENERATION_HOME/state/reused-task.meta"
run_supervisor_home "$GENERATION_HOME" "$GENERATION_BOARD" --once \
  || fail "initial generated task cycle failed"
generation_dir=$(task_state_dir "$GENERATION_HOME" reused-task)
printf 'stale receipt evidence\n' > "$generation_dir/receipt"
printf 'v2\t1\treused-task\tfuture-condition\tinspect stale generation\ttoken-old\told\n' \
  > "$generation_dir/escalated-future-condition"
{
  printf 'window=\n'
  printf 'kind=ship\n'
  printf 'generation=second-generation\n'
} > "$GENERATION_HOME/state/reused-task.meta"
run_supervisor_home "$GENERATION_HOME" "$GENERATION_BOARD" --once \
  || fail "reused task generation cycle failed"
grep -Fx 'generation:second-generation' "$generation_dir/generation" >/dev/null \
  || fail "reused task did not adopt its new generation"
[ ! -e "$generation_dir/receipt" ] \
  || fail "reused task inherited stale receipt evidence"
[ ! -e "$generation_dir/escalated-future-condition" ] \
  || fail "reused task inherited a stale escalation marker"
grep -F $'1\treused-task\tfuture-condition\tinspect stale generation\ttoken-old' \
  "$GENERATION_HOME/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "generation reset discarded pending escalation history"

PROMOTION_HOME="$TMP_ROOT/promotion-home"
PROMOTION_BOARD="$TMP_ROOT/promotion-board"
mkdir -p "$PROMOTION_HOME/state" "$PROMOTION_BOARD"
{
  printf 'window=\n'
  printf 'worktree=/immutable-worktree\n'
  printf 'project=/immutable-project\n'
  printf 'kind=scout\n'
} > "$PROMOTION_HOME/state/promoted-task.meta"
printf 'working: preserve receipt across promotion\n' \
  > "$PROMOTION_HOME/state/promoted-task.status"
run_supervisor_home "$PROMOTION_HOME" "$PROMOTION_BOARD" --once \
  || fail "legacy promotion setup cycle failed"
promotion_dir=$(task_state_dir "$PROMOTION_HOME" promoted-task)
promotion_generation=$(cat "$promotion_dir/generation")
promotion_receipt=$(cksum "$promotion_dir/receipt")
sed 's/^kind=scout$/kind=ship/' "$PROMOTION_HOME/state/promoted-task.meta" \
  > "$PROMOTION_HOME/state/promoted-task.meta.next"
mv "$PROMOTION_HOME/state/promoted-task.meta.next" \
  "$PROMOTION_HOME/state/promoted-task.meta"
run_supervisor_home "$PROMOTION_HOME" "$PROMOTION_BOARD" --once \
  || fail "legacy promoted task cycle failed"
[ "$(cat "$promotion_dir/generation")" = "$promotion_generation" ] \
  || fail "task promotion changed the immutable legacy identity"
[ "$(cksum "$promotion_dir/receipt")" = "$promotion_receipt" ] \
  || fail "task promotion reset persisted receipt evidence"

EXCLUDED_HOME="$TMP_ROOT/excluded-home"
EXCLUDED_BOARD="$TMP_ROOT/excluded-board"
mkdir -p "$EXCLUDED_HOME/state" "$EXCLUDED_BOARD"
{
  printf 'window=fm-gone\n'
  printf 'kind=ship\n'
  printf 'generation=teardown-generation\n'
} > "$EXCLUDED_HOME/state/excluded-task.meta"
excluded_owner=${BASHPID:-$$}
excluded_identity=$(LC_ALL=C ps -p "$excluded_owner" -o lstart= 2>/dev/null \
  | cksum | awk '{ print $1 "-" $2 }')
printf 'v1\tgeneration:teardown-generation\t%s\t%s\t%s\tactive\t-\n' \
  "$excluded_owner" "$excluded_identity" "$(date +%s)" \
  > "$EXCLUDED_HOME/state/.firstmate-supervisor.teardown-excluded-task"
run_supervisor_home "$EXCLUDED_HOME" "$EXCLUDED_BOARD" --once \
  || fail "teardown-excluded task cycle failed"
if awk -F '\t' '$1 == "task" && $2 == "excluded-task" { found=1 } END { exit !found }' \
  "$EXCLUDED_HOME/state/firstmate-supervisor.tsv"; then
  fail "teardown-excluded task remained in the snapshot"
fi
[ ! -s "$EXCLUDED_HOME/state/.firstmate-supervisor.escalations" ] \
  || fail "teardown-excluded task produced a durable escalation"

DEAD_TEARDOWN_HOME="$TMP_ROOT/dead-teardown-home"
DEAD_TEARDOWN_BOARD="$TMP_ROOT/dead-teardown-board"
mkdir -p "$DEAD_TEARDOWN_HOME/state" "$DEAD_TEARDOWN_BOARD"
{
  printf 'window=fm-gone\n'
  printf 'kind=ship\n'
  printf 'generation=dead-teardown-generation\n'
} > "$DEAD_TEARDOWN_HOME/state/dead-teardown.meta"
printf 'v1\tgeneration:dead-teardown-generation\t2147483647\tdead-owner\t%s\tactive\t-\n' \
  "$(date +%s)" \
  > "$DEAD_TEARDOWN_HOME/state/.firstmate-supervisor.teardown-dead-teardown"
run_supervisor_home "$DEAD_TEARDOWN_HOME" "$DEAD_TEARDOWN_BOARD" --once \
  || fail "dead teardown owner reconciliation cycle failed"
grep -F $'\tdead-teardown\tteardown-owner-exited\trerun teardown for the recorded task and inspect interrupted cleanup\t' \
  "$DEAD_TEARDOWN_HOME/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "dead teardown owner was not durably escalated"
grep -F $'escalation\tdead-teardown\tteardown-owner-exited\trerun teardown for the recorded task and inspect interrupted cleanup' \
  "$DEAD_TEARDOWN_HOME/state/firstmate-supervisor.tsv" >/dev/null \
  || fail "dead teardown owner was not surfaced in the snapshot"

COMPLETE_TEARDOWN_HOME="$TMP_ROOT/complete-teardown-home"
COMPLETE_TEARDOWN_BOARD="$TMP_ROOT/complete-teardown-board"
mkdir -p "$COMPLETE_TEARDOWN_HOME/state" "$COMPLETE_TEARDOWN_BOARD"
printf 'v1\tgeneration:complete-teardown\t%s\t%s\t%s\tcomplete\t-\n' \
  "$excluded_owner" "$excluded_identity" "$(date +%s)" \
  > "$COMPLETE_TEARDOWN_HOME/state/.firstmate-supervisor.teardown-complete-teardown"
run_supervisor_home "$COMPLETE_TEARDOWN_HOME" "$COMPLETE_TEARDOWN_BOARD" --once \
  || fail "completed teardown marker reclamation cycle failed"
[ ! -e "$COMPLETE_TEARDOWN_HOME/state/.firstmate-supervisor.teardown-complete-teardown" ] \
  || fail "observer did not reclaim a successful teardown marker"

INCOMPLETE_TEARDOWN_HOME="$TMP_ROOT/incomplete-teardown-home"
INCOMPLETE_TEARDOWN_BOARD="$TMP_ROOT/incomplete-teardown-board"
mkdir -p "$INCOMPLETE_TEARDOWN_HOME/state" "$INCOMPLETE_TEARDOWN_BOARD"
{
  printf 'window=fm-gone\n'
  printf 'kind=ship\n'
  printf 'generation=incomplete-teardown-generation\n'
} > "$INCOMPLETE_TEARDOWN_HOME/state/incomplete-teardown.meta"
printf 'v1\tgeneration:incomplete-teardown-generation\t2147483647\tdead-owner\t%s\tcomplete\t-\n' \
  "$(date +%s)" \
  > "$INCOMPLETE_TEARDOWN_HOME/state/.firstmate-supervisor.teardown-incomplete-teardown"
run_supervisor_home "$INCOMPLETE_TEARDOWN_HOME" "$INCOMPLETE_TEARDOWN_BOARD" --once \
  || fail "incomplete teardown reconciliation cycle failed"
grep -F $'\tincomplete-teardown\tteardown-incomplete\trerun teardown because its completion marker conflicts with task metadata\t' \
  "$INCOMPLETE_TEARDOWN_HOME/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "incomplete teardown was not durably escalated"
grep -F $'escalation\tincomplete-teardown\tteardown-incomplete\trerun teardown because its completion marker conflicts with task metadata' \
  "$INCOMPLETE_TEARDOWN_HOME/state/firstmate-supervisor.tsv" >/dev/null \
  || fail "incomplete teardown was not surfaced in the snapshot"

LEGACY_RETIRE_HOME="$TMP_ROOT/legacy-retire-home"
LEGACY_RETIRE_BOARD="$TMP_ROOT/legacy-retire-board"
mkdir -p \
  "$LEGACY_RETIRE_HOME/state/.firstmate-supervisor.retirements" \
  "$LEGACY_RETIRE_HOME/state/.firstmate-supervisor.retirement-intents" \
  "$LEGACY_RETIRE_BOARD"
{
  printf 'window=fm-gone\n'
  printf 'kind=ship\n'
  printf 'generation=legacy-retirement\n'
} > "$LEGACY_RETIRE_HOME/state/legacy-retire.meta"
printf 'v1\t3\tlegacy-retire\tfailed\tmetadata-cleanup-failed\tretry teardown safely\tretire-token\n' \
  > "$LEGACY_RETIRE_HOME/state/.firstmate-supervisor.retirements/legacy-retire"
printf 'v1\t2\tlegacy-retire\tpending\t-\tcomplete task retirement\tpending-token\n' \
  > "$LEGACY_RETIRE_HOME/state/.firstmate-supervisor.retirement-intents/legacy-retire"
run_supervisor_home "$LEGACY_RETIRE_HOME" "$LEGACY_RETIRE_BOARD" --once \
  || fail "legacy retirement migration cycle failed"
grep -F $'3\tlegacy-retire\tretirement-metadata-cleanup-failed\tretry teardown safely\tretire-token' \
  "$LEGACY_RETIRE_HOME/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "legacy retirement failure was not durably journaled"
grep -F $'2\tlegacy-retire\tretirement-pending\tcomplete task retirement\tpending-token' \
  "$LEGACY_RETIRE_HOME/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "legacy pending retirement was not durably journaled"
[ ! -e "$LEGACY_RETIRE_HOME/state/.firstmate-supervisor.retirements" ] \
  || fail "legacy retirement records survived migration"
[ ! -e "$LEGACY_RETIRE_HOME/state/.firstmate-supervisor.retirement-intents" ] \
  || fail "legacy retirement intents survived migration"
[ ! -e "$LEGACY_RETIRE_HOME/state/.firstmate-supervisor.teardown-legacy-retire" ] \
  || fail "legacy retirement evidence was bound to current same-ID metadata"
awk -F '\t' '$1 == "task" && $2 == "legacy-retire" { found=1 } END { exit !found }' \
  "$LEGACY_RETIRE_HOME/state/firstmate-supervisor.tsv" \
  || fail "legacy retirement evidence excluded current same-ID metadata"

LEGACY_ESC_HOME="$TMP_ROOT/legacy-escalation-home"
LEGACY_ESC_BOARD="$TMP_ROOT/legacy-escalation-board"
mkdir -p "$LEGACY_ESC_HOME/state" "$LEGACY_ESC_BOARD"
printf 'v2\t4\tlegacy-orphan\tfailed-receipt\tact on legacy failure\tlegacy-token\told\n' \
  > "$LEGACY_ESC_HOME/state/.firstmate-supervisor.escalated-legacy-orphan-failed-receipt"
run_supervisor_home "$LEGACY_ESC_HOME" "$LEGACY_ESC_BOARD" --once \
  || fail "legacy pending escalation migration cycle failed"
grep -F $'4\tlegacy-orphan\tfailed-receipt\tact on legacy failure\tlegacy-token' \
  "$LEGACY_ESC_HOME/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "legacy pending escalation was not durably journaled"
[ ! -e "$LEGACY_ESC_HOME/state/.firstmate-supervisor.escalated-legacy-orphan-failed-receipt" ] \
  || fail "legacy pending escalation marker survived migration"

RAW_LEGACY_HOME="$TMP_ROOT/raw-legacy-home"
RAW_LEGACY_BOARD="$TMP_ROOT/raw-legacy-board"
mkdir -p "$RAW_LEGACY_HOME/state" "$RAW_LEGACY_BOARD"
printf '4\traw-legacy\tfailed-receipt\tact on legacy failure\told-token\n' \
  > "$RAW_LEGACY_HOME/state/.firstmate-supervisor.escalations"
printf 'old-token\n' \
  > "$RAW_LEGACY_HOME/state/.firstmate-supervisor.escalated-raw-legacy-failed-receipt"
run_supervisor_home "$RAW_LEGACY_HOME" "$RAW_LEGACY_BOARD" --once \
  || fail "raw legacy escalation cleanup cycle failed"
[ "$(wc -l < "$RAW_LEGACY_HOME/state/.firstmate-supervisor.escalations")" -eq 1 ] \
  || fail "raw legacy escalation was appended to the durable journal again"
[ ! -e "$RAW_LEGACY_HOME/state/.firstmate-supervisor.escalated-raw-legacy-failed-receipt" ] \
  || fail "raw legacy escalation marker survived cleanup"

ORPHAN_HOME="$TMP_ROOT/orphan-home"
ORPHAN_BOARD="$TMP_ROOT/orphan-board"
mkdir -p "$ORPHAN_HOME/state" "$ORPHAN_BOARD"
{
  printf 'window=\n'
  printf 'kind=ship\n'
  printf 'generation=orphan-generation\n'
} > "$ORPHAN_HOME/state/orphan-task.meta"
run_supervisor_home "$ORPHAN_HOME" "$ORPHAN_BOARD" --once \
  || fail "orphan setup cycle failed"
orphan_dir=$(task_state_dir "$ORPHAN_HOME" orphan-task)
printf 'v2\t2\torphan-task\tfuture-condition\tinspect orphan\ttoken-orphan\torphan\n' \
  > "$orphan_dir/escalated-future-condition"
printf 'legacy receipt\n' \
  > "$ORPHAN_HOME/state/.firstmate-supervisor.receipt-orphan-task-receipt"
rm -f "$ORPHAN_HOME/state/orphan-task.meta"
if FM_TEST_FAIL_TASK_STATE_CLEAR=1 \
  run_supervisor_home "$ORPHAN_HOME" "$ORPHAN_BOARD" --once >/dev/null 2>&1; then
  fail "orphan cleanup failure produced a successful cycle"
fi
[ -d "$orphan_dir" ] \
  || fail "failed orphan cleanup lost its retry state"
rm -f "$ORPHAN_HOME/state/.firstmate-supervisor.heartbeat"
run_supervisor_home "$ORPHAN_HOME" "$ORPHAN_BOARD" --once \
  || fail "orphan task state was not reclaimed"
[ ! -e "$orphan_dir" ] \
  || fail "absent task retained supervisor-owned state"
[ ! -e "$ORPHAN_HOME/state/.firstmate-supervisor.receipt-orphan-task-receipt" ] \
  || fail "absent task retained legacy supervisor state"
grep -F $'2\torphan-task\tfuture-condition\tinspect orphan\ttoken-orphan' \
  "$ORPHAN_HOME/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "orphan reclamation discarded pending escalation history"
if awk -F '\t' '$1 == "task" && $2 == "orphan-task" { found=1 } END { exit !found }' \
  "$ORPHAN_HOME/state/firstmate-supervisor.tsv"; then
  fail "absent task remained in the supervisor snapshot"
fi

UNLOCK_HOME="$TMP_ROOT/unlock-home"
UNLOCK_BOARD="$TMP_ROOT/unlock-board"
mkdir -p "$UNLOCK_HOME/state" "$UNLOCK_BOARD"
{
  printf 'window=\n'
  printf 'kind=ship\n'
  printf 'generation=unlock-generation\n'
} > "$UNLOCK_HOME/state/unlock-task.meta"
if FM_TEST_FAIL_TASK_UNLOCK=1 \
  run_supervisor_home "$UNLOCK_HOME" "$UNLOCK_BOARD" --once >/dev/null 2>&1; then
  fail "task-state unlock failure produced a successful cycle"
fi
[ ! -e "$UNLOCK_HOME/state/.firstmate-supervisor.heartbeat" ] \
  || fail "task-state unlock failure published a healthy heartbeat"
grep -F 'task-state-unlock-failed' "$UNLOCK_HOME/state/.firstmate-supervisor.error" >/dev/null \
  || fail "task-state unlock failure omitted durable cycle error state"
/bin/rm -f "$UNLOCK_HOME/state/.firstmate-supervisor.state.lock/pid"
rmdir "$UNLOCK_HOME/state/.firstmate-supervisor.state.lock"

for unlock_owner in missing corrupt; do
  UNKNOWN_UNLOCK_HOME="$TMP_ROOT/unknown-unlock-$unlock_owner-home"
  UNKNOWN_UNLOCK_BOARD="$TMP_ROOT/unknown-unlock-$unlock_owner-board"
  mkdir -p "$UNKNOWN_UNLOCK_HOME/state" "$UNKNOWN_UNLOCK_BOARD"
  {
    printf 'window=\n'
    printf 'kind=ship\n'
    printf 'generation=unknown-unlock-%s\n' "$unlock_owner"
  } > "$UNKNOWN_UNLOCK_HOME/state/unknown-unlock.meta"
  if FM_TEST_TASK_UNLOCK_OWNER="$unlock_owner" \
    run_supervisor_home \
      "$UNKNOWN_UNLOCK_HOME" "$UNKNOWN_UNLOCK_BOARD" --once >/dev/null 2>&1; then
    fail "$unlock_owner task-state lock owner produced a successful cycle"
  fi
  [ ! -e "$UNKNOWN_UNLOCK_HOME/state/.firstmate-supervisor.heartbeat" ] \
    || fail "$unlock_owner task-state lock owner published a healthy heartbeat"
  grep -F 'task-state-unlock-failed' \
    "$UNKNOWN_UNLOCK_HOME/state/.firstmate-supervisor.error" >/dev/null \
    || fail "$unlock_owner task-state lock owner omitted durable failure state"
  /bin/rm -f "$UNKNOWN_UNLOCK_HOME/state/.firstmate-supervisor.state.lock/pid"
  rmdir "$UNKNOWN_UNLOCK_HOME/state/.firstmate-supervisor.state.lock"
done

OVERLAP_HOME="$TMP_ROOT/overlap-home"
OVERLAP_BOARD="$TMP_ROOT/overlap-board"
OVERLAP_BAD_BOARD="$TMP_ROOT/overlap-bad-board"
OVERLAP_SIGNAL="$TMP_ROOT/overlap-heartbeat"
mkdir -p "$OVERLAP_HOME/state" "$OVERLAP_BOARD"
: > "$OVERLAP_BAD_BOARD"
{
  printf 'window=\n'
  printf 'kind=ship\n'
  printf 'generation=overlap-generation\n'
} > "$OVERLAP_HOME/state/overlap-task.meta"
FM_TEST_DELAY_HEARTBEAT_SIGNAL="$OVERLAP_SIGNAL" \
  run_supervisor_home "$OVERLAP_HOME" "$OVERLAP_BOARD" --once &
overlap_first=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e "$OVERLAP_SIGNAL" ] && break
  /bin/sleep 0.1
done
[ -e "$OVERLAP_SIGNAL" ] || fail "overlapping cycle did not reach health publication"
if run_supervisor_home \
  "$OVERLAP_HOME" "$OVERLAP_BAD_BOARD" --once >/dev/null 2>&1; then
  fail "later overlapping failed cycle reported success"
fi
wait "$overlap_first" || fail "earlier overlapping successful cycle failed"
[ ! -e "$OVERLAP_HOME/state/.firstmate-supervisor.heartbeat" ] \
  || fail "earlier overlapping cycle overwrote later failed cycle health"
tail -n 1 "$OVERLAP_HOME/state/.firstmate-supervisor.log" \
  | grep -F 'board-refresh-failed' >/dev/null \
  || fail "overlapping cycle health publication reordered the final failure"

FAILED_HOME="$TMP_ROOT/failed-home"
FAILED_BOARD="$TMP_ROOT/failed-board"
mkdir -p "$FAILED_HOME/state"
: > "$FAILED_BOARD"
if failed_start=$(FM_SUPERVISOR_START_WAIT=2 run_supervisor_home "$FAILED_HOME" "$FAILED_BOARD" start 2>&1); then
  fail "new owner reported ready without a successful initial cycle"
fi
printf '%s\n' "$failed_start" \
  | grep -F 'failed to publish a fresh heartbeat after its initial cycle' >/dev/null \
  || fail "failed initial cycle did not report missing readiness: $failed_start"
[ ! -e "$FAILED_HOME/state/.firstmate-supervisor.heartbeat" ] \
  || fail "failed initial cycle published a readiness heartbeat"
[ ! -e "$FAILED_HOME/state/.firstmate-supervisor.pid" ] \
  || fail "failed initial cycle retained its PID receipt"
[ ! -d "$FAILED_HOME/state/.firstmate-supervisor.lock" ] \
  || fail "failed initial cycle retained its ownership lock"
if failed_retry=$(FM_SUPERVISOR_START_WAIT=2 run_supervisor_home "$FAILED_HOME" "$FAILED_BOARD" start 2>&1); then
  fail "immediate retry accepted a failed no-heartbeat owner"
fi
printf '%s\n' "$failed_retry" \
  | grep -F 'failed to publish a fresh heartbeat after its initial cycle' >/dev/null \
  || fail "immediate retry did not perform a fresh activation attempt: $failed_retry"
[ ! -e "$FAILED_HOME/state/.firstmate-supervisor.pid" ] \
  || fail "failed retry retained its PID receipt"
[ ! -d "$FAILED_HOME/state/.firstmate-supervisor.lock" ] \
  || fail "failed retry retained its ownership lock"

DEFAULT_HOME="$TMP_ROOT/default-home"
DEFAULT_BOARD="$TMP_ROOT/default-board"
mkdir -p "$DEFAULT_HOME/state" "$DEFAULT_BOARD"
run_supervisor_home "$DEFAULT_HOME" "$DEFAULT_BOARD" start >/dev/null \
  || fail "default-interval supervisor start failed"
default_first_pid=$(cat "$DEFAULT_HOME/state/.firstmate-supervisor.pid" 2>/dev/null || true)
default_restart_started=$(date +%s)
run_supervisor_home "$DEFAULT_HOME" "$DEFAULT_BOARD" restart >/dev/null \
  || fail "default-interval supervisor restart exceeded its stop budget"
default_restart_elapsed=$(( $(date +%s) - default_restart_started ))
default_second_pid=$(cat "$DEFAULT_HOME/state/.firstmate-supervisor.pid" 2>/dev/null || true)
[ "$default_second_pid" != "$default_first_pid" ] \
  || fail "default-interval restart retained the old owner"
[ "$default_restart_elapsed" -le 5 ] \
  || fail "default-interval restart was not responsive: ${default_restart_elapsed}s"
grep -Fx '15' "$SLEEP_LOG" >/dev/null \
  || fail "default interval wait was split into one-second processes"

FM_SUPERVISOR_INTERVAL=1 run_supervisor start >/dev/null || fail "supervisor start failed"
for _ in 1 2 3 4 5; do
  first_pid=$(cat "$HOME_DIR/state/.firstmate-supervisor.pid" 2>/dev/null || true)
  case "$first_pid" in ''|*[!0-9]*) sleep 1 ;; *) break ;; esac
done
case "${first_pid:-}" in ''|*[!0-9]*) fail "start did not publish PID receipt" ;; esac
kill -0 "$first_pid" 2>/dev/null || fail "published supervisor PID is not alive"
kill -STOP "$first_pid" 2>/dev/null || fail "could not pause supervisor for heartbeat-health test"
rm -f "$HOME_DIR/state/.firstmate-supervisor.heartbeat"
if unhealthy_status=$(run_supervisor status 2>&1); then
  fail "status reported a heartbeat-less owner as healthy"
fi
printf '%s\n' "$unhealthy_status" | grep -F "state=unhealthy pid=$first_pid heartbeat=missing" >/dev/null \
  || fail "status did not report the heartbeat-less owner as unhealthy: $unhealthy_status"
if unhealthy_start=$(FM_SUPERVISOR_INTERVAL=1 run_supervisor start 2>&1); then
  fail "idempotent start accepted an owner without a fresh heartbeat"
fi
printf '%s\n' "$unhealthy_start" | grep -F "supervisor pid $first_pid has no fresh heartbeat" >/dev/null \
  || fail "unhealthy existing owner did not report heartbeat failure: $unhealthy_start"
[ "$(cat "$HOME_DIR/state/.firstmate-supervisor.pid")" = "$first_pid" ] \
  || fail "heartbeat-health check replaced the existing owner"
kill -CONT "$first_pid" 2>/dev/null || fail "could not resume supervisor after heartbeat-health test"
for _ in 1 2 3 4 5; do
  [ -s "$HOME_DIR/state/.firstmate-supervisor.heartbeat" ] && break
  sleep 1
done
[ -s "$HOME_DIR/state/.firstmate-supervisor.heartbeat" ] \
  || fail "resumed supervisor did not restore its heartbeat"
kill -STOP "$first_pid" 2>/dev/null || fail "could not pause supervisor for drained-wake test"
first_generated=$(awk -F '\t' '$1 == "generated-at" { print $2 }' "$SNAPSHOT")
first_board_generated=$(sed -n 's/.*const generated=\([0-9][0-9]*\),.*/\1/p' "$BOARD")
FM_HOME="$HOME_DIR" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append heartbeat controlled "controlled wake"' -- "$ROOT" \
  || fail "could not append controlled wake"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-wake-drain.sh" >/dev/null \
  || fail "Firstmate could not drain controlled wake"
[ ! -s "$HOME_DIR/state/.wake-queue" ] || fail "controlled wake queue was not drained"
sleep 1
kill -CONT "$first_pid" 2>/dev/null || fail "could not resume supervisor after drained wake"
second_generated=0
second_board_generated=0
wake_last_seq=0
for _ in 1 2 3 4 5; do
  second_generated=$(awk -F '\t' '$1 == "generated-at" { print $2 }' "$SNAPSHOT")
  second_board_generated=$(sed -n 's/.*const generated=\([0-9][0-9]*\),.*/\1/p' "$BOARD")
  wake_last_seq=$(awk -F '\t' '$1 == "wake-last-seq" { print $2 }' "$SNAPSHOT")
  if [ "$second_generated" -gt "$first_generated" ] \
    && [ "$second_board_generated" -gt "$first_board_generated" ] \
    && [ "$wake_last_seq" = 1 ]; then
    break
  fi
  sleep 1
done
[ "$second_generated" -gt "$first_generated" ] || fail "drained wake did not advance running snapshot"
[ "$second_board_generated" -gt "$first_board_generated" ] || fail "drained wake did not advance running board"
[ "$wake_last_seq" = 1 ] || fail "running supervisor lost drained wake sequence"
grep -Fx $'wake-count\t0' "$SNAPSHOT" >/dev/null || fail "snapshot claimed ownership of drained wake"
[ ! -e "$TMUX_LOG.injected" ] || fail "normal supervisor cycle injected chat"
if grep -F 'send-keys' "$TMUX_LOG" >/dev/null; then
  fail "normal supervisor attempted chat injection"
fi

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

REVISION_BIN="$TMP_ROOT/revision-bin"
REVISION_HOME="$TMP_ROOT/revision-home"
REVISION_BOARD="$TMP_ROOT/revision-board"
mkdir -p "$REVISION_BIN" "$REVISION_HOME/state" "$REVISION_BOARD"
cp "$ROOT/bin/fm-supervisor.sh" "$ROOT/bin/fm-board.sh" \
  "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-tmux-lib.sh" "$REVISION_BIN/"
FM_SUPERVISOR_INTERVAL=1 \
  PATH="$FAKEBIN:$PATH" \
  FM_TEST_TMUX_LOG="$TMUX_LOG" \
  FM_TEST_SLEEP_LOG="$SLEEP_LOG" \
  FM_HOME="$REVISION_HOME" \
  FM_BOARD_DIR="$REVISION_BOARD" \
  "$REVISION_BIN/fm-supervisor.sh" start >/dev/null \
  || fail "revision-test supervisor start failed"
revision_first_pid=$(cat "$REVISION_HOME/state/.firstmate-supervisor.pid" 2>/dev/null || true)
printf '\n' >> "$REVISION_BIN/fm-wake-lib.sh"
revision_start=$(FM_SUPERVISOR_INTERVAL=1 \
  PATH="$FAKEBIN:$PATH" \
  FM_TEST_TMUX_LOG="$TMUX_LOG" \
  FM_TEST_SLEEP_LOG="$SLEEP_LOG" \
  FM_HOME="$REVISION_HOME" \
  FM_BOARD_DIR="$REVISION_BOARD" \
  "$REVISION_BIN/fm-supervisor.sh" start) \
  || fail "start did not replace an outdated supervisor revision"
revision_second_pid=$(cat "$REVISION_HOME/state/.firstmate-supervisor.pid" 2>/dev/null || true)
case "$revision_second_pid" in ''|*[!0-9]*) fail "revision replacement did not publish a PID receipt" ;; esac
[ "$revision_second_pid" != "$revision_first_pid" ] \
  || fail "start retained the supervisor loaded with the old wake helper"
kill -0 "$revision_first_pid" 2>/dev/null \
  && fail "revision replacement left the old supervisor alive"
kill -0 "$revision_second_pid" 2>/dev/null \
  || fail "revision replacement did not leave a live supervisor"
printf '%s\n' "$revision_start" | grep -F "supervisor running: pid $revision_second_pid" >/dev/null \
  || fail "revision replacement did not report the new owner"
revision_expected=$(
  for runtime_file in \
    "$REVISION_BIN/fm-supervisor.sh" \
    "$REVISION_BIN/fm-wake-lib.sh" \
    "$REVISION_BIN/fm-tmux-lib.sh"; do
    printf '%s\t' "${runtime_file##*/}"
    cksum < "$runtime_file"
  done | cksum | awk '{ print $1 "-" $2 }'
)
grep -Fx "revision=$revision_expected" "$REVISION_HOME/state/.firstmate-supervisor.owner" >/dev/null \
  || fail "new owner did not record its complete runtime revision"

printf '\n' >> "$REVISION_BIN/fm-tmux-lib.sh"
revision_start=$(FM_SUPERVISOR_INTERVAL=1 \
  PATH="$FAKEBIN:$PATH" \
  FM_TEST_TMUX_LOG="$TMUX_LOG" \
  FM_TEST_SLEEP_LOG="$SLEEP_LOG" \
  FM_HOME="$REVISION_HOME" \
  FM_BOARD_DIR="$REVISION_BOARD" \
  "$REVISION_BIN/fm-supervisor.sh" start) \
  || fail "start did not replace a supervisor with an outdated tmux helper"
revision_third_pid=$(cat "$REVISION_HOME/state/.firstmate-supervisor.pid" 2>/dev/null || true)
case "$revision_third_pid" in ''|*[!0-9]*) fail "second helper replacement did not publish a PID receipt" ;; esac
[ "$revision_third_pid" != "$revision_second_pid" ] \
  || fail "start retained the supervisor loaded with the old tmux helper"
kill -0 "$revision_second_pid" 2>/dev/null \
  && fail "tmux helper replacement left the old supervisor alive"
kill -0 "$revision_third_pid" 2>/dev/null \
  || fail "tmux helper replacement did not leave a live supervisor"
printf '%s\n' "$revision_start" | grep -F "supervisor running: pid $revision_third_pid" >/dev/null \
  || fail "tmux helper replacement did not report the new owner"

printf '\n' >> "$REVISION_BIN/fm-supervisor.sh"
revision_start=$(FM_SUPERVISOR_INTERVAL=1 \
  PATH="$FAKEBIN:$PATH" \
  FM_TEST_TMUX_LOG="$TMUX_LOG" \
  FM_TEST_SLEEP_LOG="$SLEEP_LOG" \
  FM_HOME="$REVISION_HOME" \
  FM_BOARD_DIR="$REVISION_BOARD" \
  "$REVISION_BIN/fm-supervisor.sh" start) \
  || fail "start did not replace an outdated supervisor script"
revision_fourth_pid=$(cat "$REVISION_HOME/state/.firstmate-supervisor.pid" 2>/dev/null || true)
case "$revision_fourth_pid" in ''|*[!0-9]*) fail "script replacement did not publish a PID receipt" ;; esac
[ "$revision_fourth_pid" != "$revision_third_pid" ] \
  || fail "start retained the supervisor loaded from the old script revision"
kill -0 "$revision_third_pid" 2>/dev/null \
  && fail "script replacement left the old supervisor alive"
kill -0 "$revision_fourth_pid" 2>/dev/null \
  || fail "script replacement did not leave a live supervisor"
printf '%s\n' "$revision_start" | grep -F "supervisor running: pid $revision_fourth_pid" >/dev/null \
  || fail "script replacement did not report the new owner"

CADENCE_HOME="$TMP_ROOT/cadence-home"
CADENCE_BOARD="$TMP_ROOT/cadence-board"
mkdir -p "$CADENCE_HOME/state" "$CADENCE_BOARD"
FM_SUPERVISOR_INTERVAL=3 FM_SUPERVISOR_START_WAIT=1 \
  run_supervisor_home "$CADENCE_HOME" "$CADENCE_BOARD" start >/dev/null \
  || fail "cross-cadence supervisor start failed"
cadence_pid=$(cat "$CADENCE_HOME/state/.firstmate-supervisor.pid" 2>/dev/null || true)
grep -Fx 'interval=3' "$CADENCE_HOME/state/.firstmate-supervisor.owner" >/dev/null \
  || fail "running owner did not persist its actual interval"
kill -STOP "$cadence_pid" 2>/dev/null || fail "could not pause cross-cadence owner"
printf '%s\n' "$(( $(date +%s) - 4 ))" > "$CADENCE_HOME/state/.firstmate-supervisor.heartbeat"
cadence_start=$(FM_SUPERVISOR_INTERVAL=1 FM_SUPERVISOR_START_WAIT=1 \
  run_supervisor_home "$CADENCE_HOME" "$CADENCE_BOARD" start) \
  || fail "short-cadence caller rejected healthy longer-cadence owner"
printf '%s\n' "$cadence_start" | grep -F "already running: pid $cadence_pid" >/dev/null \
  || fail "cross-cadence health check did not retain the owner"
printf '%s\n' "$(( $(date +%s) - 20 ))" > "$CADENCE_HOME/state/.firstmate-supervisor.heartbeat"
if cadence_stale=$(FM_SUPERVISOR_INTERVAL=30 FM_SUPERVISOR_START_WAIT=1 \
  run_supervisor_home "$CADENCE_HOME" "$CADENCE_BOARD" start 2>&1); then
  fail "long-cadence caller accepted owner stale under its actual cadence"
fi
printf '%s\n' "$cadence_stale" | grep -F "supervisor pid $cadence_pid has no fresh heartbeat" >/dev/null \
  || fail "stale cross-cadence owner did not report heartbeat failure: $cadence_stale"
kill -CONT "$cadence_pid" 2>/dev/null || fail "could not resume cross-cadence owner"

LONG_CADENCE_HOME="$TMP_ROOT/long-cadence-home"
LONG_CADENCE_BOARD="$TMP_ROOT/long-cadence-board"
mkdir -p "$LONG_CADENCE_HOME/state" "$LONG_CADENCE_BOARD"
FM_SUPERVISOR_INTERVAL=120 run_supervisor_home "$LONG_CADENCE_HOME" "$LONG_CADENCE_BOARD" start >/dev/null \
  || fail "long-cadence supervisor start failed"
grep -F ',limit=245,' "$LONG_CADENCE_BOARD/board.html" >/dev/null \
  || fail "board stale threshold ignored the running owner's cadence"
FM_BOARD_STALE_AFTER=17 \
  FM_HOME="$LONG_CADENCE_HOME" \
  FM_STATE_OVERRIDE="$LONG_CADENCE_HOME/state" \
  FM_BOARD_DIR="$LONG_CADENCE_BOARD" \
  "$ROOT/bin/fm-board.sh" --once \
  || fail "explicit board stale threshold render failed"
grep -F ',limit=17,' "$LONG_CADENCE_BOARD/board.html" >/dev/null \
  || fail "explicit board stale threshold was not preserved"

NO_OWNER_HOME="$TMP_ROOT/no-owner-home"
NO_OWNER_BOARD="$TMP_ROOT/no-owner-board"
mkdir -p "$NO_OWNER_HOME/state" "$NO_OWNER_BOARD"
cp "$LONG_CADENCE_HOME/state/firstmate-supervisor.tsv" "$NO_OWNER_HOME/state/firstmate-supervisor.tsv"
FM_HOME="$NO_OWNER_HOME" \
  FM_STATE_OVERRIDE="$NO_OWNER_HOME/state" \
  FM_BOARD_DIR="$NO_OWNER_BOARD" \
  "$ROOT/bin/fm-board.sh" --once \
  || fail "no-owner board fallback render failed"
grep -F ',limit=60,' "$NO_OWNER_BOARD/board.html" >/dev/null \
  || fail "board without an owner receipt did not use the safe fallback"

ROOT_OVERRIDE_HOME="$TMP_ROOT/root-override-home"
mkdir -p "$ROOT_OVERRIDE_HOME/state"
cp "$NO_OWNER_HOME/state/firstmate-supervisor.tsv" "$ROOT_OVERRIDE_HOME/state/firstmate-supervisor.tsv"
FM_ROOT_OVERRIDE="$ROOT_OVERRIDE_HOME" \
  FM_HOME= \
  FM_STATE_OVERRIDE= \
  FM_SUPERVISOR_SNAPSHOT= \
  FM_BOARD_DIR= \
  FM_BOARD_OUT= \
  "$ROOT/bin/fm-board.sh" --once \
  || fail "root-override board render failed"
[ -s "$ROOT_OVERRIDE_HOME/state/board/board.html" ] \
  || fail "standalone board ignored root override"

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

SHARED_HOME_A="$TMP_ROOT/shared-home-a"
SHARED_HOME_B="$TMP_ROOT/shared-home-b"
SHARED_STATE="$TMP_ROOT/shared/state"
SHARED_BOARD="$TMP_ROOT/shared/board"
mkdir -p "$SHARED_HOME_A" "$SHARED_HOME_B" "$SHARED_STATE" "$SHARED_BOARD"
PATH="$FAKEBIN:$PATH" FM_TEST_TMUX_LOG="$TMUX_LOG" \
  FM_HOME="$SHARED_HOME_A" FM_STATE_OVERRIDE="$SHARED_STATE" FM_BOARD_DIR="$SHARED_BOARD" \
  FM_SUPERVISOR_INTERVAL=1 "$ROOT/bin/fm-supervisor.sh" start >/dev/null \
  || fail "shared-state supervisor start failed"
shared_pid=$(cat "$SHARED_STATE/.firstmate-supervisor.pid" 2>/dev/null || true)
case "$shared_pid" in ''|*[!0-9]*) fail "shared-state supervisor did not publish a PID receipt" ;; esac
shared_start=$(PATH="$FAKEBIN:$PATH" FM_TEST_TMUX_LOG="$TMUX_LOG" \
  FM_HOME="$SHARED_HOME_B" FM_STATE_OVERRIDE="$SHARED_STATE" FM_BOARD_DIR="$SHARED_BOARD" \
  FM_SUPERVISOR_INTERVAL=1 "$ROOT/bin/fm-supervisor.sh" start) \
  || fail "second home did not accept shared-state singleton"
printf '%s\n' "$shared_start" | grep -F "already running: pid $shared_pid" >/dev/null \
  || fail "shared effective state did not resolve to one singleton owner"
[ "$(cat "$SHARED_STATE/.firstmate-supervisor.pid")" = "$shared_pid" ] \
  || fail "shared-state start replaced the singleton owner"
kill -0 "$shared_pid" 2>/dev/null || fail "shared-state singleton owner is not alive"

printf 'ok - supervisor reconciles wakes, classifies contracts, escalates failures, stays no-chat, and restarts singleton-safe\n'
