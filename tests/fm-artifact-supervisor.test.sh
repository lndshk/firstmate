#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-artifact-supervisor.XXXXXX")
SUPERVISOR_PID=
cleanup() {
  [ -n "$SUPERVISOR_PID" ] && kill "$SUPERVISOR_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$TMP/bin" "$TMP/board"

cat >"$TMP/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"display-message"*"fm-busy"*) echo '%1' ;;
  *"capture-pane"*"fm-busy"*) echo 'Working (8s • esc to interrupt)' ;;
  *"display-message"*"fm-waiting"*) echo '%2' ;;
  *"capture-pane"*"fm-waiting"*) echo 'idle prompt' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/bin/tmux"

meta() { printf 'window=%s\nkind=ship\n%s' "$2" "${3:-}" >"$HOME_DIR/state/$1.meta"; }
meta busy fm-busy 'process-pid=999999
receipt-deadline=1
'
meta waiting fm-waiting "receipt-deadline=$(( $(date +%s) + 60 ))
"
meta overdue fm-waiting 'receipt-deadline=1
'
meta reported fm-waiting 'receipt-deadline=1
'
meta combined fm-gone 'artifact=missing-artifact
receipt-deadline=1
'
printf 'working: busy without receipt\n' >"$HOME_DIR/state/busy.status"
printf 'working: receipt already recorded\n' >"$HOME_DIR/state/reported.status"
touch "$HOME_DIR/state/.last-watcher-beat"

run_once() {
  PATH="$TMP/bin:$PATH" FM_HOME="$HOME_DIR" FM_BOARD_DIR="$TMP/board" \
    FM_BOARD_OUT="$TMP/board/board.html" FM_BOARD_BODY="$TMP/no-body" \
    "$ROOT/bin/fm-artifact-supervisor.sh" --once
}

run_once
first=$(sed -n 's/.*data-epoch="\([0-9]*\)".*/\1/p' "$TMP/board/board.html")
grep -F $'busy\tactive\tbusy pane observed' "$HOME_DIR/state/artifact-supervisor.tsv" >/dev/null
grep -F $'waiting\tactive-unverified\tawaiting durable receipt' "$HOME_DIR/state/artifact-supervisor.tsv" >/dev/null
grep -F $'overdue\tstalled\treceipt deadline passed' "$HOME_DIR/state/artifact-supervisor.tsv" >/dev/null
grep -F $'reported\tactive-unverified\tawaiting durable receipt' "$HOME_DIR/state/artifact-supervisor.tsv" >/dev/null
grep -q '>active<' "$TMP/board/board.html"
grep -q '>active-unverified<' "$TMP/board/board.html"
grep -q '>stalled<' "$TMP/board/board.html"
grep -q 'receipt-deadline' "$HOME_DIR/state/.artifact-supervisor.escalations"
grep -F $'busy\treceipt-deadline\t' "$HOME_DIR/state/.artifact-supervisor.escalations" >/dev/null
grep -F $'combined\tartifact-missing\t' "$HOME_DIR/state/.artifact-supervisor.escalations" >/dev/null
grep -F $'combined\twindow-gone\t' "$HOME_DIR/state/.artifact-supervisor.escalations" >/dev/null
grep -F $'combined\treceipt-deadline\t' "$HOME_DIR/state/.artifact-supervisor.escalations" >/dev/null
! grep -F $'reported\treceipt-deadline\t' "$HOME_DIR/state/.artifact-supervisor.escalations" >/dev/null

printf '%s\t1\theartbeat\theartbeat\tcontrolled wake\n' "$(date +%s)" >"$HOME_DIR/state/.wake-queue"
peek=$(FM_HOME="$HOME_DIR" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_peek' -- "$ROOT")
printf '%s\n' "$peek" | grep -F $'\theartbeat\theartbeat\tcontrolled wake' >/dev/null
[ -s "$HOME_DIR/state/.wake-queue" ]
sleep 1
run_once
second=$(sed -n 's/.*data-epoch="\([0-9]*\)".*/\1/p' "$TMP/board/board.html")
[ "$second" -gt "$first" ]
[ -s "$HOME_DIR/state/.wake-queue" ]
[ "$(find "$HOME_DIR/state/.artifact-supervisor.heartbeat" -mmin -1 | wc -l | tr -d ' ')" = 1 ]

sleep 30 &
UNRELATED_PID=$!
printf '%s\n' "$UNRELATED_PID" >"$HOME_DIR/state/.artifact-supervisor.pid"
PATH="$TMP/bin:$PATH" FM_HOME="$HOME_DIR" FM_BOARD_DIR="$TMP/board" FM_BOARD_OUT="$TMP/board/board.html" \
  FM_ARTIFACT_SUPERVISOR_INTERVAL=1 "$ROOT/bin/fm-artifact-supervisor.sh" restart >/dev/null
kill -0 "$UNRELATED_PID"
kill "$UNRELATED_PID" 2>/dev/null || true

(cd "$ROOT" && PATH="$TMP/bin:$PATH" FM_HOME="$HOME_DIR" FM_BOARD_DIR="$TMP/board" FM_BOARD_OUT="$TMP/board/board.html" \
  FM_ARTIFACT_SUPERVISOR_INTERVAL=1 bin/fm-artifact-supervisor.sh start) >/dev/null
for _ in 1 2 3 4 5; do [ -s "$HOME_DIR/state/.artifact-supervisor.pid" ] && break; sleep 1; done
SUPERVISOR_PID=$(cat "$HOME_DIR/state/.artifact-supervisor.pid")
kill -0 "$SUPERVISOR_PID"
[ -f "$HOME_DIR/state/.artifact-supervisor.heartbeat" ]
printf 'ok - wake advances snapshot and board; missing receipts classify by deadline\n'
