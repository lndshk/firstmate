#!/usr/bin/env bash
# Trust-kernel acceptance: machine predicates route one owned action, and an
# interrupted supervisor replays it without duplicating it or involving a pane.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-artifact-supervisor.XXXXXX")
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT
HOME_DIR="$TMP/home"; mkdir -p "$HOME_DIR/state" "$TMP/bin" "$TMP/board"

# No task in this test has a pane. If the evaluator calls tmux for its failure
# decision this stub fails, making the no-LLM/no-board route boundary explicit.
cat >"$TMP/bin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP/bin/tmux"

manifest(){
  local id=$1 predicate=$2 args=$3 deadline=$4
  cat >"$HOME_DIR/state/$id.manifest" <<EOF
manifest-v1
task-id=$id
owner=repair-owner
route=repair-queue
identity=command:fixture
start=1
deadline=$deadline
no-progress=30
receipt=fixture-receipt
success-predicate=$predicate
success-args=$args
failure-predicate=always-fail
failure-args=
retry-classes=lock-contention
retry-cap=1
idempotency-key=fixture-$id
escalation-action=bin/fm-supported-repair --task $id
acknowledgement-deadline=60
EOF
}
printf 'window=never-used\nkind=ship\nprocess-pid=999999\n' >"$HOME_DIR/state/semantic.meta"
manifest semantic file-content 'path=receipt;expected=accepted' $(( $(date +%s) + 60 ))
printf 'wrong\n' >"$HOME_DIR/receipt"

run(){ PATH="$TMP/bin:$PATH" FM_HOME="$HOME_DIR" FM_BOARD_DIR="$TMP/board" FM_BOARD_OUT="$TMP/board/board.html" FM_BOARD_BODY="$TMP/no-body" "$ROOT/bin/fm-artifact-supervisor.sh" --once; }
run
grep -F $'semantic\tfailed\tcontent-mismatch' "$HOME_DIR/state/artifact-supervisor.tsv" >/dev/null
state="$HOME_DIR/state/.artifact-supervisor.state/semantic.state"
grep -qx 'liveness=gone' "$state"
grep -qx 'predicate=fail' "$state"
grep -qx 'outcome=failed' "$state"
grep -qx 'route=queued' "$state"
actions=("$HOME_DIR/state/.artifact-supervisor.actions/"*.action)
[ "${#actions[@]}" -eq 1 ]
action=${actions[0]}
event=$(sed -n 's/^event-id=//p' "$action")
grep -qx 'owner=repair-owner' "$action"
grep -qx 'route=repair-queue' "$action"
grep -qx 'failed-predicate=file-content' "$action"
grep -qx 'failure-code=content-mismatch' "$action"
grep -qx 'state=queued' "$action"

# Simulate a crash after the durable event/action and before acknowledgement.
rm -f "$HOME_DIR/state/.artifact-supervisor.heartbeat" "$HOME_DIR/state/artifact-supervisor.tsv"
run
[ "$(find "$HOME_DIR/state/.artifact-supervisor.actions" -name '*.action' | wc -l | tr -d ' ')" = 1 ]
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-artifact-supervisor.sh" ack "$event" >/dev/null
grep -qx 'state=acknowledged' "$action"

# Busy is liveness evidence only: a dead declared PID and expired hard contract
# stays failed/expired rather than being presented as active.
printf 'window=never-used\nkind=ship\nprocess-pid=999999\n' >"$HOME_DIR/state/expired.meta"
manifest expired always-pass '' 1
run
grep -F $'expired\tfailed\tdeadline-expired' "$HOME_DIR/state/artifact-supervisor.tsv" >/dev/null

# A legacy meta is visible but explicitly unverified/blocked, never silently
# classified as assigned or working.
printf 'window=never-used\nkind=ship\n' >"$HOME_DIR/state/legacy.meta"
run
grep -F $'legacy\tblocked\tmandatory manifest missing' "$HOME_DIR/state/artifact-supervisor.tsv" >/dev/null
printf 'ok - deterministic predicates route durable owned actions across restart\n'
