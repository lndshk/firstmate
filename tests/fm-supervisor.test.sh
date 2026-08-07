#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-supervisor-tests.XXXXXX") || exit 1
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/bin"
BOARD_DIR="$TMP_ROOT/board"
TMUX_LOG="$TMP_ROOT/tmux.log"
SLEEP_LOG="$TMP_ROOT/sleep.log"
export FM_WINDOWS_SCRATCH_SWEEP_INTERVAL=0
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
  *display-message*)
    # Real tmux (verified on 3.6): display-message -t answers with the client's
    # current pane when the target window is gone - it never fails, so it can
    # never prove a recorded window is still there. Emulating that makes the
    # fm-gone cases below fail loudly if pane presence is ever probed with it.
    printf '%%9\n'
    ;;
  *list-panes*fm-busy*)
    printf '%%1\n'
    ;;
  *capture-pane*fm-busy*)
    printf 'Working (8s · esc to interrupt)\n'
    ;;
  *list-panes*fm-waiting*)
    printf '%%2\n'
    ;;
  *capture-pane*fm-waiting*)
    printf 'idle prompt\n'
    ;;
  *list-panes*fm-unreadable*)
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
    *".firstmate-supervisor.task-"*"/receipt") exit 1 ;;
  esac
fi
exec /bin/mv "$@"
SH
chmod +x "$FAKEBIN/mv"

write_meta() { # <id> <window> <deadline>
  {
    printf 'window=%s\n' "$2"
    printf 'kind=ship\n'
    printf 'generation=test-%s\n' "$1"
    printf 'status-start-line=0\n'
    printf 'receipt-deadline=%s\n' "$3"
  } > "$HOME_DIR/state/$1.meta"
}

task_state_dir_for() { # <home> <id>
  local home=$1 id=$2 dir
  for dir in "$home"/state/.firstmate-supervisor.task-*; do
    [ -d "$dir" ] || continue
    [ "$(cat "$dir/id" 2>/dev/null || true)" = "$id" ] || continue
    printf '%s\n' "$dir"
    return
  done
  return 1
}

task_state_file() { # <home> <id> <name>
  local dir
  dir=$(task_state_dir_for "$1" "$2") || return 1
  printf '%s/%s\n' "$dir" "$3"
}

task_state_dir_for_generation() { # <home> <id> <generation>
  local home=$1 id=$2 generation=$3 dir
  for dir in "$home"/state/.firstmate-supervisor.task-*; do
    [ -d "$dir" ] || continue
    [ "$(cat "$dir/id" 2>/dev/null || true)" = "$id" ] || continue
    [ "$(cat "$dir/generation" 2>/dev/null || true)" = "$generation" ] || continue
    printf '%s\n' "$dir"
    return
  done
  return 1
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
rm -f "$HOME_DIR/state/.wake-queue" "$HOME_DIR/state/.wake-queue.seq"
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
late_receipt_cursor=$(task_state_file "$HOME_DIR" late-terminal receipt) \
  || fail "late terminal task state was not created"
[ -s "$late_receipt_cursor" ] \
  || fail "late terminal receipt timing evidence was not persisted"

snapshot_before_status_error=$(cksum "$SNAPSHOT")
terminal_receipt_cursor=$(task_state_file "$HOME_DIR" terminal-task receipt) \
  || fail "terminal task state was not created"
receipt_before_status_error=$(cksum "$terminal_receipt_cursor")
mv "$HOME_DIR/state/terminal-task.status" "$HOME_DIR/state/terminal-task.status.saved"
mkdir "$HOME_DIR/state/terminal-task.status"
if run_supervisor --once >/dev/null 2>&1; then
  fail "unreadable status path produced a successful snapshot"
fi
[ "$(cksum "$SNAPSHOT")" = "$snapshot_before_status_error" ] \
  || fail "unreadable status path replaced the last valid snapshot"
[ "$(cksum "$terminal_receipt_cursor")" = \
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
rmdir "$HOME_DIR/state/terminal-task.status"
mv "$HOME_DIR/state/terminal-task.status.saved" "$HOME_DIR/state/terminal-task.status"
run_supervisor --once || fail "supervisor did not recover after status read failure"

write_meta cursor-write fm-waiting "$((now + 300))"
printf 'working: cursor persistence must succeed\n' > "$HOME_DIR/state/cursor-write.status"
snapshot_before_cursor_error=$(cksum "$SNAPSHOT")
if FM_TEST_FAIL_RECEIPT_CURSOR=1 run_supervisor --once >/dev/null 2>&1; then
  fail "receipt cursor write failure produced a successful snapshot"
fi
[ "$(cksum "$SNAPSHOT")" = "$snapshot_before_cursor_error" ] \
  || fail "receipt cursor write failure replaced the last valid snapshot"
rm -f "$HOME_DIR/state/cursor-write.meta" "$HOME_DIR/state/cursor-write.status"
run_supervisor --once || fail "supervisor did not recover after receipt cursor write failure"

write_meta partial-identity fm-waiting "$((now + 300))"
partial_generation=test-partial-identity
partial_key=$(printf '%s\t%s' partial-identity "$partial_generation" | cksum | awk '{ print $1 "-" $2 }')
partial_dir="$HOME_DIR/state/.firstmate-supervisor.task-partial-identity-$partial_key"
mkdir "$partial_dir"
printf 'partial-identity\n' > "$partial_dir/id"
run_supervisor --once || fail "partial task identity repair cycle failed"
[ "$(cat "$partial_dir/generation" 2>/dev/null || true)" = "$partial_generation" ] \
  || fail "partial task identity was not repaired from matching metadata"
rm -f "$HOME_DIR/state/partial-identity.meta"
orphan_partial="$HOME_DIR/state/.firstmate-supervisor.task-interrupted-identity"
mkdir "$orphan_partial"
printf 'interrupted\n' > "$orphan_partial/id.tmp.123"
run_supervisor --once || fail "orphan partial task identity reclamation cycle failed"
[ ! -e "$partial_dir" ] || fail "repaired task state was not reclaimed after metadata disappeared"
[ ! -e "$orphan_partial" ] || fail "orphan partial task identity wedged reclamation"

write_meta ambiguous-current fm-waiting "$((now + 300))"
ambiguous_generation=test-ambiguous-current
ambiguous_key=$(
  printf '%s\t%s' ambiguous-current "$ambiguous_generation" \
    | cksum | awk '{ print $1 "-" $2 }'
)
ambiguous_dir="$HOME_DIR/state/.firstmate-supervisor.task-ambiguous-current-$ambiguous_key"
mkdir "$ambiguous_dir"
printf 'different-task\n' > "$ambiguous_dir/id"
printf '%s\n' "$ambiguous_generation" > "$ambiguous_dir/generation"
run_supervisor --once || fail "ambiguous current task-state quarantine cycle failed"
[ -d "$ambiguous_dir" ] || fail "ambiguous current task state was reclaimed while metadata existed"
[ "$(cat "$ambiguous_dir/id")" = different-task ] \
  || fail "ambiguous current task state was repaired while metadata existed"
rm -f "$HOME_DIR/state/ambiguous-current.meta"
run_supervisor --once || fail "ambiguous orphan task-state reclamation cycle failed"
[ ! -e "$ambiguous_dir" ] || fail "ambiguous task state was not reclaimed after metadata disappeared"

transitioned_deadline_cursor=$(task_state_file "$HOME_DIR" transitioned-terminal deadline) \
  || fail "transitioned task deadline state was not created"
transitioned_version=$(cut -f2 "$transitioned_deadline_cursor")
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

write_meta duplicate-generation fm-waiting "$((now + 300))"
printf 'generation=duplicate-generation-two\n' >> "$HOME_DIR/state/duplicate-generation.meta"
run_supervisor --once || fail "duplicate generation quarantine cycle failed"
grep -F $'task\tduplicate-generation\tactive-unverified\texplicit task generation or status boundary is missing or invalid\t' \
  "$SNAPSHOT" >/dev/null && fail "duplicate generation used the obsolete boundary error"
grep -F $'task\tduplicate-generation\tactive-unverified\texplicit task generation is missing or invalid\t' \
  "$SNAPSHOT" >/dev/null || fail "duplicate generation declaration was accepted"
if task_state_dir_for "$HOME_DIR" duplicate-generation >/dev/null 2>&1; then
  fail "duplicate generation declaration created authoritative task state"
fi
rm -f "$HOME_DIR/state/duplicate-generation.meta"

write_meta immutable-boundary fm-waiting "$((now + 300))"
run_supervisor --once || fail "initial immutable status-boundary cycle failed"
immutable_boundary_dir=$(task_state_dir_for "$HOME_DIR" immutable-boundary) \
  || fail "immutable status boundary was not persisted"
sed 's/^status-start-line=.*/status-start-line=1/' \
  "$HOME_DIR/state/immutable-boundary.meta" > "$HOME_DIR/state/immutable-boundary.meta.new"
mv "$HOME_DIR/state/immutable-boundary.meta.new" "$HOME_DIR/state/immutable-boundary.meta"
run_supervisor --once || fail "changed status-boundary quarantine cycle failed"
grep -F $'task\timmutable-boundary\tactive-unverified\tawaiting verifiable activity or receipt\t-\t' \
  "$SNAPSHOT" >/dev/null || fail "changed status boundary disabled process observation"
[ -d "$immutable_boundary_dir" ] || fail "changed current status boundary reclaimed task state"
rm -f "$HOME_DIR/state/immutable-boundary.meta"

write_meta legacy-boundary fm-busy 1
sed '/^status-start-line=/d' "$HOME_DIR/state/legacy-boundary.meta" \
  > "$HOME_DIR/state/legacy-boundary.meta.new"
mv "$HOME_DIR/state/legacy-boundary.meta.new" "$HOME_DIR/state/legacy-boundary.meta"
printf 'failed: ambiguous pre-boundary receipt\t1\n' > "$HOME_DIR/state/legacy-boundary.status"
run_supervisor --once || fail "legacy status-boundary baseline cycle failed"
grep -F $'task\tlegacy-boundary\tactive\tbusy pane observed\t-\t1\tfm-busy\t-' \
  "$SNAPSHOT" >/dev/null || fail "legacy receipt history disabled live process observation"
grep -F $'contract\tlegacy-boundary\tany-receipt\t1\tunverified\t-\t-' \
  "$SNAPSHOT" >/dev/null || fail "legacy deadline history was treated as authoritative"
if grep -F $'escalation\tlegacy-boundary\tfailed-receipt\t' "$SNAPSHOT" >/dev/null \
  || grep -F $'escalation\tlegacy-boundary\tmissed-receipt-deadline\t' "$SNAPSHOT" >/dev/null; then
  fail "legacy receipt or deadline history escaped quarantine"
fi
printf 'failed: proven post-boundary receipt\t%s\n' "$(date +%s)" \
  >> "$HOME_DIR/state/legacy-boundary.status"
run_supervisor --once || fail "post-boundary legacy receipt cycle failed"
grep -F $'task\tlegacy-boundary\tterminal\tterminal receipt recorded\tfailed: proven post-boundary receipt\t' \
  "$SNAPSHOT" >/dev/null || fail "post-boundary legacy receipt was not consumed"
grep -F $'escalation\tlegacy-boundary\tfailed-receipt\t' "$SNAPSHOT" >/dev/null \
  || fail "post-boundary legacy failure was not escalated"

write_meta legacy-future-deadline fm-busy "$(( $(date +%s) + 5 ))"
sed '/^status-start-line=/d' "$HOME_DIR/state/legacy-future-deadline.meta" \
  > "$HOME_DIR/state/legacy-future-deadline.meta.new"
mv "$HOME_DIR/state/legacy-future-deadline.meta.new" \
  "$HOME_DIR/state/legacy-future-deadline.meta"
run_supervisor --once || fail "future legacy deadline baseline cycle failed"
sleep 6
run_supervisor --once || fail "future legacy missed-deadline cycle failed"
grep -F $'contract\tlegacy-future-deadline\tany-receipt\t' "$SNAPSHOT" \
  | grep -F $'\tmissed\t-\t-' >/dev/null \
  || fail "future legacy deadline remained quarantined after baseline"
grep -F $'escalation\tlegacy-future-deadline\tmissed-receipt-deadline\t' \
  "$SNAPSHOT" >/dev/null || fail "future legacy missed deadline was not escalated"
legacy_deadline_dir=$(task_state_dir_for "$HOME_DIR" legacy-future-deadline) \
  || fail "future legacy deadline boundary state was not created"
rm -f "$HOME_DIR/state/legacy-future-deadline.meta"
run_supervisor --once || fail "legacy deadline-boundary orphan reclamation cycle failed"
[ ! -e "$legacy_deadline_dir" ] \
  || fail "legacy deadline boundary blocked exact-generation reclamation"

write_meta legacy-boundary-teardown fm-gone "$((now + 300))"
sed '/^status-start-line=/d' "$HOME_DIR/state/legacy-boundary-teardown.meta" \
  > "$HOME_DIR/state/legacy-boundary-teardown.meta.new"
mv "$HOME_DIR/state/legacy-boundary-teardown.meta.new" \
  "$HOME_DIR/state/legacy-boundary-teardown.meta"
printf 'done: ambiguous pre-boundary terminal\n' \
  > "$HOME_DIR/state/legacy-boundary-teardown.status"
printf 'v1\tgeneration:test-legacy-boundary-teardown\t2147483647\t0-0\t%s\tactive\t-\n' \
  "$(date +%s)" \
  > "$HOME_DIR/state/.firstmate-supervisor.teardown-legacy-boundary-teardown"
run_supervisor --once || fail "legacy-boundary teardown observation cycle failed"
grep -F $'task\tlegacy-boundary-teardown\tstalled\tteardown owner is missing\t-\t' \
  "$SNAPSHOT" >/dev/null || fail "legacy receipt boundary disabled teardown observation"
grep -F $'escalation\tlegacy-boundary-teardown\tteardown-owner-missing\t' \
  "$SNAPSHOT" >/dev/null || fail "legacy-boundary teardown failure was not escalated"

write_meta reused-id fm-gone 1
sed 's/^generation=.*/generation=reused-one/' \
  "$HOME_DIR/state/reused-id.meta" > "$HOME_DIR/state/reused-id.meta.new"
mv "$HOME_DIR/state/reused-id.meta.new" "$HOME_DIR/state/reused-id.meta"
printf 'done: prior generation receipt\t1\n' > "$HOME_DIR/state/reused-id.status"
run_supervisor --once || fail "first reused-id generation cycle failed"
grep -F $'task\treused-id\tterminal\tterminal receipt recorded\t' "$SNAPSHOT" >/dev/null \
  || fail "first reused-id generation did not consume its receipt"
reused_old_dir=$(task_state_dir_for "$HOME_DIR" reused-id) \
  || fail "first reused-id generation state was not created"
sed \
  -e 's/^generation=.*/generation=reused-two/' \
  -e 's/^status-start-line=.*/status-start-line=1/' \
  -e 's/^window=.*/window=fm-waiting/' \
  "$HOME_DIR/state/reused-id.meta" \
  > "$HOME_DIR/state/reused-id.meta.new"
mv "$HOME_DIR/state/reused-id.meta.new" "$HOME_DIR/state/reused-id.meta"
run_supervisor --once || fail "second reused-id generation cycle failed"
grep -F $'task\treused-id\tstalled\treceipt deadline passed\t-\t1\tfm-waiting\t-' \
  "$SNAPSHOT" >/dev/null || fail "reused task id inherited a prior-generation receipt"
grep -F $'contract\treused-id\tany-receipt\t1\tmissed\t-\t-' \
  "$SNAPSHOT" >/dev/null || fail "reused task id inherited prior deadline satisfaction"
reused_new_dir=$(task_state_dir_for_generation "$HOME_DIR" reused-id reused-two) \
  || fail "second reused-id generation state was not created"
[ "$reused_new_dir" != "$reused_old_dir" ] \
  || fail "reused task id retained the prior generation state directory"
[ -e "$reused_old_dir" ] \
  || fail "prior generation evidence was collected before task metadata disappeared"
if awk -F '\t' '$1 == "escalation" && $2 == "reused-id" && $3 == "missing-process" { found=1 } END { exit !found }' \
  "$SNAPSHOT"; then
  fail "reused task id inherited a prior generation escalation"
fi
rm -f "$HOME_DIR/state/reused-id.meta"
run_supervisor --once || fail "orphan generation reclamation cycle failed"
[ ! -e "$reused_old_dir" ] \
  || fail "prior reused-id generation was not reclaimed after metadata disappeared"
[ ! -e "$reused_new_dir" ] \
  || fail "orphan generation state was not reclaimed authoritatively"

test_owner_started=$(LC_ALL=C ps -p "$$" -o lstart=) \
  || fail "could not read teardown test owner start time"
test_owner_identity=$(printf '%s' "$test_owner_started" | cksum | awk '{ print $1 "-" $2 }') \
  || fail "could not derive teardown test owner identity"
write_meta teardown-live fm-gone "$((now + 300))"
printf 'v1\tgeneration:test-teardown-live\t%s\t%s\t%s\tactive\t-\n' \
  "$$" "$test_owner_identity" "$(date +%s)" \
  > "$HOME_DIR/state/.firstmate-supervisor.teardown-teardown-live"
teardown_live_before=$(cksum "$HOME_DIR/state/.firstmate-supervisor.teardown-teardown-live")
run_supervisor --once || fail "live teardown observation cycle failed"
grep -F $'task\tteardown-live\tactive\tteardown owner is live\t' "$SNAPSHOT" >/dev/null \
  || fail "live teardown owner was falsely stalled"
[ "$(cksum "$HOME_DIR/state/.firstmate-supervisor.teardown-teardown-live")" = \
    "$teardown_live_before" ] \
  || fail "supervisor rewrote a live teardown marker"
[ ! -d "$HOME_DIR/state/.firstmate-supervisor.teardown-locks" ] \
  || fail "supervisor created the obsolete teardown marker-lock subsystem"

printf 'v1\tgeneration:test-teardown-live\t%s\t%s\t%s\tfailed\tcommand-failed\n' \
  "$$" "$test_owner_identity" "$(date +%s)" \
  > "$HOME_DIR/state/.firstmate-supervisor.teardown-teardown-live"
run_supervisor --once || fail "first teardown failure cycle failed"
teardown_retry_count=$(awk -F '\t' \
  '$2 == "teardown-live" && $3 == "teardown-command-failed" { count++ } END { print count + 0 }' \
  "$HOME_DIR/state/.firstmate-supervisor.escalations")
[ "$teardown_retry_count" -eq 1 ] || fail "first teardown failure was not escalated once"
printf 'v1\tgeneration:test-teardown-live\t%s\t%s\t%s\tactive\t-\n' \
  "$$" "$test_owner_identity" "$(date +%s)" \
  > "$HOME_DIR/state/.firstmate-supervisor.teardown-teardown-live"
run_supervisor --once || fail "resolved teardown failure cycle failed"
printf 'v1\tgeneration:test-teardown-live\t%s\t%s\t%s\tfailed\tcommand-failed\n' \
  "$$" "$test_owner_identity" "$(date +%s)" \
  > "$HOME_DIR/state/.firstmate-supervisor.teardown-teardown-live"
run_supervisor --once || fail "retried teardown failure cycle failed"
teardown_retry_count=$(awk -F '\t' \
  '$2 == "teardown-live" && $3 == "teardown-command-failed" { count++ } END { print count + 0 }' \
  "$HOME_DIR/state/.firstmate-supervisor.escalations")
[ "$teardown_retry_count" -eq 2 ] || fail "retried teardown failure lost its escalation wake"

write_meta teardown-dead fm-gone "$((now + 300))"
printf 'v1\tgeneration:test-teardown-dead\t2147483647\t0-0\t%s\tactive\t-\n' \
  "$(date +%s)" > "$HOME_DIR/state/.firstmate-supervisor.teardown-teardown-dead"
run_supervisor --once || fail "dead teardown observation cycle failed"
grep -F $'task\tteardown-dead\tstalled\tteardown owner is missing\t' "$SNAPSHOT" >/dev/null \
  || fail "missing teardown owner was not stalled"
grep -F $'escalation\tteardown-dead\tteardown-owner-missing\tinspect the recorded teardown owner and task resources' \
  "$SNAPSHOT" >/dev/null \
  || fail "missing teardown owner lacked a non-destructive action"
grep -F $'\tsignal\tsupervisor:teardown-dead\tteardown-owner-missing:' \
  "$HOME_DIR/state/.wake-queue" >/dev/null \
  || fail "missing teardown owner did not produce normal-mode wake delivery"

write_meta terminal-teardown fm-gone "$((now + 300))"
printf 'done: terminal before teardown\n' > "$HOME_DIR/state/terminal-teardown.status"
printf 'v1\tgeneration:test-terminal-teardown\t2147483647\t0-0\t%s\tactive\t-\n' \
  "$(date +%s)" > "$HOME_DIR/state/.firstmate-supervisor.teardown-terminal-teardown"
run_supervisor --once || fail "terminal teardown observation cycle failed"
grep -F $'task\tterminal-teardown\tterminal\tterminal receipt recorded\t' "$SNAPSHOT" >/dev/null \
  || fail "teardown failure overrode terminal receipt classification"
grep -F $'escalation\tterminal-teardown\tteardown-owner-missing\t' "$SNAPSHOT" >/dev/null \
  || fail "terminal receipt suppressed teardown-owner escalation"
grep -F $'\tsignal\tsupervisor:terminal-teardown\tteardown-owner-missing:' \
  "$HOME_DIR/state/.wake-queue" >/dev/null \
  || fail "terminal teardown-owner failure did not enqueue a normal wake"

write_meta legacy-marker fm-gone "$((now + 300))"
printf 'legacy evidence without generation\n' \
  > "$HOME_DIR/state/.firstmate-supervisor.teardown-legacy-marker"
printf 'temporary partial marker\n' \
  > "$HOME_DIR/state/.firstmate-supervisor.teardown-partial.tmp.123"
run_supervisor --once || fail "legacy teardown quarantine cycle failed"
grep -F $'task\tlegacy-marker\tstalled\trecorded process is missing\t' "$SNAPSHOT" >/dev/null \
  || fail "ambiguous legacy teardown evidence influenced task classification"
if grep -F $'escalation\tlegacy-marker\tteardown-' "$SNAPSHOT" >/dev/null; then
  fail "ambiguous legacy evidence produced teardown advice"
fi
grep -Fx 'legacy evidence without generation' \
  "$HOME_DIR/state/.firstmate-supervisor.teardown-legacy-marker" >/dev/null \
  || fail "supervisor rewrote ambiguous legacy evidence"
grep -Fx 'temporary partial marker' \
  "$HOME_DIR/state/.firstmate-supervisor.teardown-partial.tmp.123" >/dev/null \
  || fail "supervisor consumed a temporary teardown artifact"

write_meta malformed-owner fm-gone "$((now + 300))"
printf 'v1\tgeneration:test-malformed-owner\tnot-a-pid\t0-0\t%s\tactive\t-\n' \
  "$(date +%s)" > "$HOME_DIR/state/.firstmate-supervisor.teardown-malformed-owner"
write_meta malformed-fields fm-gone "$((now + 300))"
printf 'v1\tgeneration:test-malformed-fields\t2147483647\t0-0\t%s\tactive\t-\textra\n' \
  "$(date +%s)" > "$HOME_DIR/state/.firstmate-supervisor.teardown-malformed-fields"
write_meta malformed-lines fm-gone "$((now + 300))"
printf 'v1\tgeneration:test-malformed-lines\t2147483647\t0-0\t%s\tactive\t-\nextra\n' \
  "$(date +%s)" > "$HOME_DIR/state/.firstmate-supervisor.teardown-malformed-lines"
run_supervisor --once || fail "malformed teardown marker quarantine cycle failed"
for malformed_id in malformed-owner malformed-fields malformed-lines; do
  grep -F "task	$malformed_id	stalled	recorded process is missing	" "$SNAPSHOT" >/dev/null \
    || fail "malformed teardown marker influenced $malformed_id classification"
  if grep -F "escalation	$malformed_id	teardown-" "$SNAPSHOT" >/dev/null; then
    fail "malformed teardown marker produced teardown advice for $malformed_id"
  fi
done

printf 'v1\tgeneration:orphan-complete\t2147483647\t0-0\t%s\tcomplete\t-\n' \
  "$(date +%s)" > "$HOME_DIR/state/.firstmate-supervisor.teardown-orphan-complete"
run_supervisor --once || fail "completed orphan marker reclamation cycle failed"
[ ! -e "$HOME_DIR/state/.firstmate-supervisor.teardown-orphan-complete" ] \
  || fail "provably completed orphan marker was not reclaimed"

ORPHAN_STATE_HOME="$TMP_ROOT/orphan-state-home"
ORPHAN_STATE_BOARD="$TMP_ROOT/orphan-state-board"
ORPHAN_STATE_TARGET="$ORPHAN_STATE_HOME/target"
mkdir -p "$ORPHAN_STATE_HOME/state" "$ORPHAN_STATE_BOARD" "$ORPHAN_STATE_TARGET"
orphan_state_generation=orphan-state-generation
orphan_state_key=$(
  printf '%s\t%s' orphan-state "$orphan_state_generation" \
    | cksum | awk '{ print $1 "-" $2 }'
)
orphan_state_dir="$ORPHAN_STATE_HOME/state/.firstmate-supervisor.task-orphan-state-$orphan_state_key"
ln -s "$ORPHAN_STATE_TARGET" "$orphan_state_dir"
printf 'v1\tgeneration:%s\t2147483647\t0-0\t%s\tactive\t-\n' \
  "$orphan_state_generation" "$(date +%s)" \
  > "$ORPHAN_STATE_HOME/state/.firstmate-supervisor.teardown-orphan-state"
if run_supervisor_home "$ORPHAN_STATE_HOME" "$ORPHAN_STATE_BOARD" --once >/dev/null 2>&1; then
  fail "orphan teardown wrote through a symlinked task-state directory"
fi
if find "$ORPHAN_STATE_TARGET" -mindepth 1 -print -quit | grep . >/dev/null; then
  fail "orphan teardown changed the symlink target"
fi
[ -f "$ORPHAN_STATE_HOME/state/.firstmate-supervisor.teardown-orphan-state" ] \
  || fail "unsafe orphan task state consumed teardown evidence"
rm -f "$orphan_state_dir"
mkdir "$orphan_state_dir"
printf 'other-task\n' > "$orphan_state_dir/id"
printf '%s\n' "$orphan_state_generation" > "$orphan_state_dir/generation"
if run_supervisor_home "$ORPHAN_STATE_HOME" "$ORPHAN_STATE_BOARD" --once >/dev/null 2>&1; then
  fail "orphan teardown accepted mismatched task-state identity"
fi
[ ! -e "$orphan_state_dir/escalated-teardown-owner-missing-condition" ] \
  || fail "orphan teardown wrote through mismatched task state"
[ -f "$ORPHAN_STATE_HOME/state/.firstmate-supervisor.teardown-orphan-state" ] \
  || fail "mismatched orphan task state consumed teardown evidence"
printf 'orphan-state\n' > "$orphan_state_dir/id"
rm -f "$orphan_state_dir/generation"
run_supervisor_home "$ORPHAN_STATE_HOME" "$ORPHAN_STATE_BOARD" --once \
  || fail "partial orphan task-state repair failed"
[ ! -e "$orphan_state_dir" ] \
  || fail "repaired orphan task state was not reclaimed"
[ ! -e "$ORPHAN_STATE_HOME/state/.firstmate-supervisor.teardown-orphan-state" ] \
  || fail "validated orphan teardown evidence was not consumed"
grep -F $'\torphan-state\tteardown-owner-missing\t' \
  "$ORPHAN_STATE_HOME/state/.firstmate-supervisor.escalations" >/dev/null \
  || fail "validated orphan teardown did not escalate"

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
if once_while_running=$(run_supervisor --once 2>&1); then
  fail "internal once cycle overlapped the live supervisor owner"
fi
printf '%s\n' "$once_while_running" \
  | grep -F 'refusing --once while the supervisor owner is running' >/dev/null \
  || fail "overlapping once cycle did not identify the live owner"
[ "$(cat "$HOME_DIR/state/.firstmate-supervisor.pid")" = "$first_pid" ] \
  || fail "refused once cycle disturbed the owner PID receipt"
[ "$(cat "$HOME_DIR/state/.firstmate-supervisor.lock/pid")" = "$first_pid" ] \
  || fail "refused once cycle disturbed the owner runtime lock"
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
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-wake-drain.sh" >/dev/null \
  || fail "could not clear prior supervisor escalation wakes"
controlled_previous_seq=$(cat "$HOME_DIR/state/.wake-queue.seq" 2>/dev/null || echo 0)
controlled_expected_seq=$((controlled_previous_seq + 1))
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
for _ in 1 2 3 4 5 6 7 8 9 10; do
  second_generated=$(awk -F '\t' '$1 == "generated-at" { print $2 }' "$SNAPSHOT")
  second_board_generated=$(sed -n 's/.*const generated=\([0-9][0-9]*\),.*/\1/p' "$BOARD")
  wake_last_seq=$(awk -F '\t' '$1 == "wake-last-seq" { print $2 }' "$SNAPSHOT")
  if [ "$second_generated" -gt "$first_generated" ] \
    && [ "$second_board_generated" -gt "$first_board_generated" ] \
    && [ "$wake_last_seq" = "$controlled_expected_seq" ]; then
    break
  fi
  sleep 1
done
[ "$second_generated" -gt "$first_generated" ] || fail "drained wake did not advance running snapshot"
[ "$second_board_generated" -gt "$first_board_generated" ] || fail "drained wake did not advance running board"
[ "$wake_last_seq" = "$controlled_expected_seq" ] \
  || fail "running supervisor lost drained wake sequence"
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
  "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-tmux-lib.sh" \
  "$ROOT/bin/fm-windows-scratch-sweep.sh" \
  "$ROOT/bin/fm-windows-scratch-sweep.ps1" "$REVISION_BIN/"
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
    "$REVISION_BIN/fm-tmux-lib.sh" \
    "$REVISION_BIN/fm-windows-scratch-sweep.sh" \
    "$REVISION_BIN/fm-windows-scratch-sweep.ps1"; do
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
