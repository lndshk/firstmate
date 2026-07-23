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
  *"display-message"*"-t fm-working"*) echo '%1' ;;
  *"capture-pane"*"-t fm-working"*) echo 'Working (8s • esc to interrupt)' ;;
  *"display-message"*"-t fm-idle"*) echo '%2' ;;
  *"capture-pane"*"-t fm-idle"*) echo 'idle prompt' ;;
  *"display-message"*"-t fm-custom"*) echo '%3' ;;
  *"capture-pane"*"-t fm-custom"*) echo 'custom-busy-signal' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/bin/tmux"

meta() { printf 'window=%s\nkind=ship\n' "$2" >"$STATE_HOME/state/$1.meta"; }
stale() { touch -d '2000-01-01 00:00:00' "$@" 2>/dev/null || touch -t 200001010000 "$@"; }
meta working fm-working
meta idle fm-idle
meta custom fm-custom
meta terminal fm-terminal
meta stalled fm-gone
meta '<img src=x onerror=alert(1)>' fm-idle
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
grep -q '&lt;img src=x onerror=alert(1)&gt;' "$TMP/board/board.html"
! grep -q '<img src=x onerror=alert(1)>' "$TMP/board/board.html"
grep -q 'Terminal receipt recorded; pane presence does not imply work' "$TMP/board/board.html"
grep -q 'Recorded pane is gone without a terminal receipt' "$TMP/board/board.html"
grep -q 'Artifact supervisor: healthy' "$TMP/board/board.html"
grep -q 'watcher healthy' "$TMP/board/board.html"

PATH="$TMP/bin:$PATH" FM_HOME="$STATE_HOME" FM_BUSY_REGEX='custom-busy-signal' FM_BOARD_DIR="$TMP/board" FM_BOARD_OUT="$TMP/board/board.html" FM_BOARD_BODY="$TMP/none" "$ROOT/bin/fm-board.sh" --once
grep '<code>custom</code>' "$TMP/board/board.html" | grep -q 'state active">active<'

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
custom	active-unverified	awaiting durable receipt		7		0
windowless	stalled	recorded pane is gone	no durable status receipt	0		0
TSV
PATH="$TMP/bin:$PATH" FM_HOME="$STATE_HOME" FM_BOARD_DIR="$TMP/board" FM_BOARD_OUT="$TMP/board/board.html" FM_BOARD_BODY="$TMP/none" "$ROOT/bin/fm-board.sh" --once
grep -q 'working: snapshot authority' "$TMP/board/board.html"
grep -q 'result: snapshot result' "$TMP/board/board.html"
grep -q '>windowless<' "$TMP/board/board.html"
grep -q 'recorded pane is gone' "$TMP/board/board.html"
grep '<code>custom</code>' "$TMP/board/board.html" | grep -q '<td></td><td>7s ago</td>'
stale "$STATE_HOME/state/.artifact-supervisor.heartbeat"
PATH="$TMP/bin:$PATH" FM_HOME="$STATE_HOME" FM_ARTIFACT_STALE_AFTER=1 FM_BOARD_DIR="$TMP/board" FM_BOARD_OUT="$TMP/board/board.html" FM_BOARD_BODY="$TMP/none" "$ROOT/bin/fm-board.sh" --once
grep -q 'working: active shell task' "$TMP/board/board.html"
! grep -q 'working: snapshot authority' "$TMP/board/board.html"
touch "$STATE_HOME/state/.artifact-supervisor.heartbeat"
stale "$STATE_HOME/state/artifact-supervisor.tsv"
PATH="$TMP/bin:$PATH" FM_HOME="$STATE_HOME" FM_ARTIFACT_STALE_AFTER=1 FM_BOARD_DIR="$TMP/board" FM_BOARD_OUT="$TMP/board/board.html" FM_BOARD_BODY="$TMP/none" "$ROOT/bin/fm-board.sh" --once
grep -q 'working: active shell task' "$TMP/board/board.html"
! grep -q 'working: snapshot authority' "$TMP/board/board.html"
rm -f "$STATE_HOME/state/artifact-supervisor.tsv"

mkdir -p "$TMP/root/bin"
cp "$ROOT/bin/fm-board.sh" "$ROOT/bin/fm-tmux-lib.sh" "$TMP/root/bin/"
(
  unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_BOARD_DIR FM_BOARD_OUT FM_BOARD_BODY
  PATH="$TMP/bin:$PATH" "$TMP/root/bin/fm-board.sh" --once
)
[ -f "$TMP/root/state/board/board.html" ]

sleep 1
printf 'failed: deterministic failure receipt\n' >"$STATE_HOME/state/working.status"
PATH="$TMP/bin:$PATH" FM_HOME="$STATE_HOME" FM_BOARD_DIR="$TMP/board" FM_BOARD_OUT="$TMP/board/board.html" FM_BOARD_BODY="$TMP/none" "$ROOT/bin/fm-board.sh" --once
second=$(sed -n 's/.*data-epoch="\([0-9]*\)".*/\1/p' "$TMP/board/board.html")
[ "$second" -gt "$first" ]
grep -q 'deterministic failure receipt' "$TMP/board/board.html"
grep -q '>terminal<' "$TMP/board/board.html"
printf 'ok - board timestamp advances and receipt state wins\n'
