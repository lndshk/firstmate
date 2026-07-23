#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-artifact-service.XXXXXX")
HOME_DIR="$TMP/home"
SERVICE="$ROOT/bin/fm-artifact-supervisor-service.sh"
mkdir -p "$HOME_DIR/state" "$TMP/bin" "$TMP/board"
cleanup() {
  FM_HOME="$HOME_DIR" "$SERVICE" stop >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

cat >"$TMP/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *display-message*) echo '%1' ;; *capture-pane*) echo 'idle prompt' ;; *) exit 1 ;; esac
SH
chmod +x "$TMP/bin/tmux"
printf 'window=fm-test\nkind=ship\n' >"$HOME_DIR/state/test.meta"

run_service() {
  PATH="$TMP/bin:$PATH" FM_HOME="$HOME_DIR" FM_BOARD_DIR="$TMP/board" FM_BOARD_OUT="$TMP/board/board.html" \
    FM_BOARD_BODY="$TMP/no-body" FM_ARTIFACT_SERVICE_INTERVAL=1 FM_ARTIFACT_SUPERVISOR_INTERVAL=1 "$SERVICE" "$@"
}
run_service start >/dev/null
for _ in 1 2 3 4 5; do [ -s "$HOME_DIR/state/.artifact-supervisor.service.pid" ] && [ -s "$HOME_DIR/state/.artifact-supervisor.pid" ] && [ -f "$HOME_DIR/state/.artifact-supervisor.service.heartbeat" ] && break; sleep 1; done
service_pid=$(cat "$HOME_DIR/state/.artifact-supervisor.service.pid")
worker_pid=$(cat "$HOME_DIR/state/.artifact-supervisor.pid")
kill -0 "$service_pid"
kill -0 "$worker_pid"
[ -f "$HOME_DIR/state/.artifact-supervisor.service.heartbeat" ]
grep -F $'service-started\t' "$HOME_DIR/state/.artifact-supervisor.service.events" >/dev/null

# A child crash is recovered by the service without bootstrap or a human/LLM.
kill -TERM "$worker_pid"
for _ in 1 2 3 4 5; do
  next=$(cat "$HOME_DIR/state/.artifact-supervisor.pid" 2>/dev/null || true)
  [ -n "$next" ] && [ "$next" != "$worker_pid" ] && kill -0 "$next" 2>/dev/null && break
  sleep 1
done
[ "$next" != "$worker_pid" ]
kill -0 "$next"
grep -F $'worker-started\t' "$HOME_DIR/state/.artifact-supervisor.service.events" >/dev/null

# Stop owns the worker it launched: no orphaned polling loop remains.
run_service stop
for _ in 1 2 3 4 5; do kill -0 "$next" 2>/dev/null || break; sleep 1; done
! kill -0 "$next" 2>/dev/null
[ ! -e "$HOME_DIR/state/.artifact-supervisor.service.pid" ]
echo 'ok - service restarts observer and tears down owned worker'
