#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STATE_HOME="$TMP/home"
mkdir -p "$STATE_HOME/state" "$TMP/bin" "$TMP/board"

cat >"$TMP/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"-t fm-working"*"display-message"*) echo '%1' ;;
  *"-t fm-working"*"capture-pane"*) echo 'Working (8s • esc to interrupt)' ;;
  *"-t fm-idle"*"display-message"*) echo '%2' ;;
  *"-t fm-idle"*"capture-pane"*) echo 'idle prompt' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/bin/tmux"

meta() { printf 'window=%s\nkind=ship\n' "$2" >"$STATE_HOME/state/$1.meta"; }
meta working fm-working
meta idle fm-idle
meta terminal fm-terminal
meta stalled fm-gone
printf 'kind=ship\n' >"$STATE_HOME/state/windowless.meta"
printf 'working: active shell task\n' >"$STATE_HOME/state/working.status"
printf 'working: waiting for another event\n' >"$STATE_HOME/state/idle.status"
printf 'done: https://example.test/pr/7\n' >"$STATE_HOME/state/terminal.status"
printf 'working: lost pane receipt\n' >"$STATE_HOME/state/stalled.status"
touch "$STATE_HOME/state/.last-watcher-beat"
touch "$STATE_HOME/state/.artifact-supervisor.heartbeat"

PATH="$TMP/bin:$PATH" FM_HOME="$STATE_HOME" FM_BOARD_BODY="$TMP/none" "$ROOT/bin/fm-board.sh" --once
[ -f "$STATE_HOME/state/board/board.html" ]

PATH="$TMP/bin:$PATH" FM_HOME="$STATE_HOME" FM_BOARD_DIR="$TMP/board" FM_BOARD_OUT="$TMP/board/board.html" FM_BOARD_BODY="$TMP/none" "$ROOT/bin/fm-board.sh" --once
first=$(sed -n 's/.*data-epoch="\([0-9]*\)".*/\1/p' "$TMP/board/board.html")
grep -q '>working<' "$TMP/board/board.html"
grep -q '>idle<' "$TMP/board/board.html"
grep -q '>terminal<' "$TMP/board/board.html"
grep -q '>stalled<' "$TMP/board/board.html"
grep -q 'Terminal receipt recorded; pane presence does not imply work' "$TMP/board/board.html"
grep -q 'Recorded pane is gone without a terminal receipt' "$TMP/board/board.html"
grep -q 'Artifact supervisor: healthy' "$TMP/board/board.html"
grep -q 'watcher healthy' "$TMP/board/board.html"

rm -f "$STATE_HOME/state/.last-watcher-beat"
PATH="$TMP/bin:$PATH" FM_HOME="$STATE_HOME" FM_BOARD_DIR="$TMP/board" FM_BOARD_OUT="$TMP/board/board.html" FM_BOARD_BODY="$TMP/none" "$ROOT/bin/fm-board.sh" --once
grep -q 'Artifact supervisor: healthy' "$TMP/board/board.html"
grep -q 'watcher stale/off' "$TMP/board/board.html"
touch "$STATE_HOME/state/.last-watcher-beat"

cat >"$STATE_HOME/state/artifact-supervisor.tsv" <<'TSV'
artifact-supervisor-v1
generated-at	1
working	active	busy pane observed	working: snapshot authority	0		0
idle	terminal	terminal receipt	result: snapshot result	0		0
windowless	stalled	recorded pane is gone	no durable status receipt	0		0
TSV
PATH="$TMP/bin:$PATH" FM_HOME="$STATE_HOME" FM_BOARD_DIR="$TMP/board" FM_BOARD_OUT="$TMP/board/board.html" FM_BOARD_BODY="$TMP/none" "$ROOT/bin/fm-board.sh" --once
grep -q 'working: snapshot authority' "$TMP/board/board.html"
grep -q 'result: snapshot result' "$TMP/board/board.html"
grep -q '>windowless<' "$TMP/board/board.html"
grep -q 'recorded pane is gone' "$TMP/board/board.html"
rm -f "$STATE_HOME/state/artifact-supervisor.tsv"

sleep 1
printf 'failed: deterministic failure receipt\n' >"$STATE_HOME/state/working.status"
PATH="$TMP/bin:$PATH" FM_HOME="$STATE_HOME" FM_BOARD_DIR="$TMP/board" FM_BOARD_OUT="$TMP/board/board.html" FM_BOARD_BODY="$TMP/none" "$ROOT/bin/fm-board.sh" --once
second=$(sed -n 's/.*data-epoch="\([0-9]*\)".*/\1/p' "$TMP/board/board.html")
[ "$second" -gt "$first" ]
grep -q 'deterministic failure receipt' "$TMP/board/board.html"
grep -q '>terminal<' "$TMP/board/board.html"
printf 'ok - board timestamp advances and receipt state wins\n'
