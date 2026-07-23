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
meta busy fm-busy 'receipt-deadline=1
'
meta waiting fm-waiting "receipt-deadline=$(( $(date +%s) + 60 ))
"
meta overdue fm-waiting 'receipt-deadline=1
'
printf 'working: busy without receipt\n' >"$HOME_DIR/state/busy.status"
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
grep -q '>active<' "$TMP/board/board.html"
grep -q '>active-unverified<' "$TMP/board/board.html"
grep -q '>stalled<' "$TMP/board/board.html"
grep -q 'receipt-deadline' "$HOME_DIR/state/.artifact-supervisor.escalations"

# A durable wake is drained by the supervisor and still causes a fresh snapshot
# and board render; this is the controlled no-chat wake path.
printf '%s\t1\theartbeat\theartbeat\tcontrolled wake\n' "$(date +%s)" >"$HOME_DIR/state/.wake-queue"
sleep 1
run_once
second=$(sed -n 's/.*data-epoch="\([0-9]*\)".*/\1/p' "$TMP/board/board.html")
[ "$second" -gt "$first" ]
[ ! -s "$HOME_DIR/state/.wake-queue" ]
[ "$(find "$HOME_DIR/state/.artifact-supervisor.heartbeat" -mmin -1 | wc -l | tr -d ' ')" = 1 ]

# The explicit command creates both singleton receipts without involving chat.
PATH="$TMP/bin:$PATH" FM_HOME="$HOME_DIR" FM_BOARD_DIR="$TMP/board" FM_BOARD_OUT="$TMP/board/board.html" \
  FM_ARTIFACT_SUPERVISOR_INTERVAL=1 "$ROOT/bin/fm-artifact-supervisor.sh" start >/dev/null
for _ in 1 2 3 4 5; do [ -s "$HOME_DIR/state/.artifact-supervisor.pid" ] && break; sleep 1; done
SUPERVISOR_PID=$(cat "$HOME_DIR/state/.artifact-supervisor.pid")
kill -0 "$SUPERVISOR_PID"
[ -f "$HOME_DIR/state/.artifact-supervisor.heartbeat" ]
printf 'ok - wake advances snapshot and board; missing receipts classify by deadline\n'
