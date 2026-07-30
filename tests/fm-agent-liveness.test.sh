#!/usr/bin/env bash
# Agent process-tree liveness: dead panes are reported and blocked, while a
# verified agent remains alive through both idle-composer and child-shell states.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-agent-liveness-tests.XXXXXX")
TMUX_SOCKET=
cleanup() {
  if [ -n "${TMUX_SOCKET:-}" ]; then
    tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
  fi
  [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

FAKEBIN="$TMP_ROOT/fakebin"
PS_SNAPSHOT="$TMP_ROOT/ps.txt"
SEND_LOG="$TMP_ROOT/send.log"
mkdir -p "$FAKEBIN"
: > "$SEND_LOG"

cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
cat "$FM_FAKE_PS_SNAPSHOT"
SH

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=
format=
prev=
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  if [ "$prev" = "-F" ]; then format=$arg; fi
  case "$arg" in '#{'*) format=$arg ;; esac
  prev=$arg
done
case "${1:-}" in
  display-message)
    case "$format:$target" in
      '#{pane_pid}:sess:idle') printf '10\n' ;;
      '#{pane_pid}:sess:busy') printf '20\n' ;;
      '#{pane_pid}:sess:dead') printf '30\n' ;;
      '#{pane_current_command}:sess:idle') printf 'node\n' ;;
      '#{pane_current_command}:sess:busy') printf 'bash\n' ;;
      '#{pane_current_command}:sess:dead') printf 'bash\n' ;;
      '#{cursor_y}:'*) printf '0\n' ;;
      *) exit 1 ;;
    esac
    ;;
  capture-pane)
    printf '> \n'
    ;;
  send-keys)
    printf '%s\n' "$*" >> "$FM_FAKE_SEND_LOG"
    ;;
  list-windows)
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$FAKEBIN/ps" "$FAKEBIN/tmux"

cat > "$PS_SNAPSHOT" <<'EOF'
 10 1 Ss bash bash -l
100 10 Sl node node /opt/claude
 20 1 Ss bash bash -l
200 20 Sl node node /opt/codex
201 200 S bash bash -lc run-tests
202 201 S sleep sleep 30
 30 1 Ss bash bash -l
 40 1 Ss bash bash -l
400 40 Sl opencode opencode
 50 1 Ss bash bash -l
500 50 Sl pi pi
 60 1 Ss bash bash -l
600 60 Z node node /opt/claude
EOF

for pid in 10 20 40 50; do
  PATH="$FAKEBIN:$PATH" FM_FAKE_PS_SNAPSHOT="$PS_SNAPSHOT" \
    "$ROOT/bin/fm-harness.sh" agent-in-tree "$pid" \
    || fail "verified harness ancestor $pid was not marked alive"
done
if PATH="$FAKEBIN:$PATH" FM_FAKE_PS_SNAPSHOT="$PS_SNAPSHOT" \
  "$ROOT/bin/fm-harness.sh" agent-in-tree 30; then
  fail "bare login shell was marked alive"
fi
if PATH="$FAKEBIN:$PATH" FM_FAKE_PS_SNAPSHOT="$PS_SNAPSHOT" \
  "$ROOT/bin/fm-harness.sh" agent-in-tree 60; then
  fail "zombie agent was marked alive"
fi
pass "shared harness knowledge identifies live agent trees and excludes shells/zombies"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
touch "$HOME_DIR/state/.last-watcher-beat"
cat > "$HOME_DIR/state/idle-advisor.meta" <<'EOF'
window=sess:idle
kind=secondmate
EOF
cat > "$HOME_DIR/state/busy-crew.meta" <<'EOF'
window=sess:busy
kind=ship
EOF
cat > "$HOME_DIR/state/dead-advisor.meta" <<'EOF'
window=sess:dead
kind=secondmate
EOF

stall_out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
  FM_FAKE_PS_SNAPSHOT="$PS_SNAPSHOT" FM_FAKE_SEND_LOG="$SEND_LOG" \
  "$ROOT/bin/fm-stall-check.sh") || fail "stall check exited non-zero"
printf '%s\n' "$stall_out" \
  | grep -F 'dead?: dead-advisor - window sess:dead has no live agent process (pane at bash)' >/dev/null \
  || fail "dead advisor finding missing: $stall_out"
printf '%s\n' "$stall_out" | grep -E 'dead\\?: (idle-advisor|busy-crew)' >/dev/null \
  && fail "live idle or mid-shell agent was reported dead: $stall_out"
pass "stall check reports only the dead pane, preserving live idle and mid-shell agents"

if PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
  FM_FAKE_PS_SNAPSHOT="$PS_SNAPSHOT" FM_FAKE_SEND_LOG="$SEND_LOG" \
  "$ROOT/bin/fm-send.sh" sess:dead 'do not execute this' >/dev/null 2>"$TMP_ROOT/send.err"; then
  fail "fm-send accepted a dead pane"
fi
grep -F 'refusing to send to sess:dead: no live agent process (pane at bash)' "$TMP_ROOT/send.err" >/dev/null \
  || fail "fm-send did not explain the dead-pane refusal"
[ ! -s "$SEND_LOG" ] || fail "fm-send typed into the dead shell before refusing"
pass "fm-send refuses a dead pane before typing"

PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
  FM_FAKE_PS_SNAPSHOT="$PS_SNAPSHOT" FM_FAKE_SEND_LOG="$SEND_LOG" \
  FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 \
  "$ROOT/bin/fm-send.sh" sess:busy 'continue after tests' >/dev/null 2>"$TMP_ROOT/live-send.err" \
  || fail "fm-send rejected a live agent running a child shell: $(cat "$TMP_ROOT/live-send.err")"
grep -F 'continue after tests' "$SEND_LOG" >/dev/null \
  || fail "live mid-shell send did not reach tmux"
pass "fm-send accepts a live agent whose foreground command is a shell"

WATCH_HOME="$TMP_ROOT/watch-home"
mkdir -p "$WATCH_HOME/state"
touch "$WATCH_HOME/state/.last-check" "$WATCH_HOME/state/.last-heartbeat"
cat > "$WATCH_HOME/state/dead-advisor.meta" <<'EOF'
window=sess:dead
kind=secondmate
EOF
watch_out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$WATCH_HOME" \
  FM_FAKE_PS_SNAPSHOT="$PS_SNAPSHOT" FM_FAKE_SEND_LOG="$SEND_LOG" \
  FM_WATCH_KEEPALIVE=0 FM_POLL=0.01 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
  "$ROOT/bin/fm-watch.sh") || fail "watcher exited non-zero"
[ "$watch_out" = 'stale: sess:dead (no live agent process)' ] \
  || fail "watcher did not wake immediately for dead secondmate: $watch_out"
pass "watcher wakes for a dead secondmate without changing its live-idle exemption"

test_real_tmux_process_tree() {
  local target tag agent_command agent_pid= command state proof_home out before after tmux_env
  command -v tmux >/dev/null 2>&1 || { pass "real tmux proof skipped (tmux unavailable)"; return 0; }
  TMUX_SOCKET="fm-agent-live-$$"
  target=proof:agent
  tag="codex-live-fixture-$$"
  tmux -L "$TMUX_SOCKET" new-session -d -s proof -n agent
  tmux_env=$(tmux -L "$TMUX_SOCKET" display-message -p -t "$target" '#{socket_path},#{pid},0')
  agent_command="python3 -c 'import os,signal,subprocess,sys; p=subprocess.Popen([\"bash\",\"-c\",\"while :; do sleep 1; done\"], preexec_fn=os.setpgrp); signal.signal(signal.SIGTERM,lambda *_:(os.killpg(p.pid,signal.SIGTERM),sys.exit(0))); os.tcsetpgrp(0,p.pid); p.wait()' $tag"
  tmux -L "$TMUX_SOCKET" send-keys -t "$target" -l "$agent_command"
  tmux -L "$TMUX_SOCKET" send-keys -t "$target" Enter

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    agent_pid=$(ps -axo pid=,args= | awk -v tag="$tag" 'index($0, tag) && index($0, "awk -v tag=") == 0 { print $1; exit }')
    command=$(tmux -L "$TMUX_SOCKET" display-message -p -t "$target" '#{pane_current_command}')
    state=$(TMUX="$tmux_env" bash -c '. "$1"; fm_pane_agent_state "$2"' _ "$ROOT/bin/fm-tmux-lib.sh" "$target" 2>/dev/null || true)
    [ -n "$agent_pid" ] && [ "$command" = bash ] && [ "$state" = alive ] && break
    sleep 0.2
  done
  [ -n "$agent_pid" ] || fail "real tmux agent fixture did not start"
  [ "$command" = bash ] || fail "real tmux fixture was not visibly mid-shell (pane at $command)"
  [ "$state" = alive ] || fail "live real tmux agent was not detected through its child shell"

  proof_home="$TMP_ROOT/real-home"
  mkdir -p "$proof_home/state" "$proof_home/data"
  touch "$proof_home/state/.last-watcher-beat"
  printf 'window=%s\nkind=secondmate\n' "$target" > "$proof_home/state/real-advisor.meta"
  out=$(FM_HOME="$proof_home" TMUX="$tmux_env" "$ROOT/bin/fm-stall-check.sh") \
    || fail "real live-agent stall check exited non-zero"
  [ -z "$out" ] || fail "live real tmux agent was reported stalled/dead: $out"
  pass "real tmux pane at bash remains alive while its agent parent runs"

  kill -TERM "$agent_pid"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    state=$(TMUX="$tmux_env" bash -c '. "$1"; fm_pane_agent_state "$2"' _ "$ROOT/bin/fm-tmux-lib.sh" "$target" 2>/dev/null || true)
    [ "$state" = dead ] && break
    sleep 0.2
  done
  [ "$state" = dead ] || fail "killed real tmux agent still appeared alive"
  out=$(FM_HOME="$proof_home" TMUX="$tmux_env" "$ROOT/bin/fm-stall-check.sh") \
    || fail "real dead-agent stall check exited non-zero"
  printf '%s\n' "$out" \
    | grep -F "dead?: real-advisor - window $target has no live agent process (pane at bash)" >/dev/null \
    || fail "killed real tmux agent was not reported dead: $out"

  before=$(tmux -L "$TMUX_SOCKET" capture-pane -p -t "$target")
  if FM_HOME="$proof_home" TMUX="$tmux_env" "$ROOT/bin/fm-send.sh" "$target" 'must-not-hit-shell' >/dev/null 2>"$TMP_ROOT/real-send.err"; then
    fail "fm-send accepted the killed real tmux agent pane"
  fi
  after=$(tmux -L "$TMUX_SOCKET" capture-pane -p -t "$target")
  [ "$before" = "$after" ] || fail "fm-send changed the dead real tmux pane"
  grep -F 'no live agent process' "$TMP_ROOT/real-send.err" >/dev/null \
    || fail "real dead-pane refusal was not explained"
  pass "killed real tmux agent is reported dead and fm-send leaves its shell untouched"

  tmux -L "$TMUX_SOCKET" kill-server
  TMUX_SOCKET=
}

test_real_tmux_process_tree

printf 'all agent liveness tests passed\n'
