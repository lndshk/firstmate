#!/usr/bin/env bash
# Usage: fm-artifact-supervisor-service.sh [start|stop|restart|status|--loop]
#
# Keep the artifact observer/router behind one durable, process-owned service
# boundary.  The observer remains responsible for its own singleton lock and
# atomic state writes; this wrapper only owns its lifetime.  In particular it
# never reads or drains the wake queue, so AFK retains chat/wake ownership.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SUPERVISOR="$SCRIPT_DIR/fm-artifact-supervisor.sh"
INTERVAL="${FM_ARTIFACT_SERVICE_INTERVAL:-2}"
LOCK="$STATE/.artifact-supervisor.service.lock"
PIDFILE="$STATE/.artifact-supervisor.service.pid"
WORKERFILE="$STATE/.artifact-supervisor.service.worker"
HEARTBEAT="$STATE/.artifact-supervisor.service.heartbeat"
LOG="$STATE/.artifact-supervisor.service.log"
ERROR="$STATE/.artifact-supervisor.service.error"
EVENTS="$STATE/.artifact-supervisor.service.events"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

now_epoch() { date +%s; }
pid_alive() { fm_pid_alive "$1"; }

lock_pid() { cat "$LOCK/pid" 2>/dev/null || true; }
service_pid_is_ours() { # <pid>
  local pid=$1 command
  pid_alive "$pid" || return 1
  [ "$(lock_pid)" = "$pid" ] || return 1
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in *"$SCRIPT_DIR/fm-artifact-supervisor-service.sh"*'--loop'*) return 0 ;; esac
  return 1
}
worker_pid_is_ours() { # <pid>
  local pid=$1 command
  pid_alive "$pid" || return 1
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in *"$SCRIPT_DIR/fm-artifact-supervisor.sh"*'--loop'*) return 0 ;; esac
  return 1
}
worker_pid() { cat "$STATE/.artifact-supervisor.pid" 2>/dev/null || true; }
event() { printf '%s\t%s\t%s\n' "$(now_epoch)" "$1" "$2" >> "$EVENTS"; }

ensure_worker() {
  local pid n=0 lock_pid
  pid=$(worker_pid)
  if worker_pid_is_ours "$pid"; then
    return 0
  fi
  # A TERM'd worker normally releases this immediately.  If it died between
  # trap delivery and cleanup, remove only a proven-dead lock before relaunch;
  # otherwise a one-shot worker would exit and the service would wait a full
  # cycle before trying again.
  while [ -d "$STATE/.artifact-supervisor.lock" ] && [ "$n" -lt 5 ]; do
    lock_pid=$(cat "$STATE/.artifact-supervisor.lock/pid" 2>/dev/null || true)
    if ! pid_alive "$lock_pid"; then
      fm_lock_remove_stale "$STATE/.artifact-supervisor.lock" "$lock_pid" || true
    fi
    [ -d "$STATE/.artifact-supervisor.lock" ] || break
    sleep 1
    n=$((n + 1))
  done
  # Invoke the worker through bash so this boundary also works in checkouts
  # where tracked scripts have not yet had their executable bit restored.
  nohup bash "$SUPERVISOR" --loop >> "$LOG" 2>&1 &
  # The worker writes its PID after acquiring its own lock.  Keep the wait
  # bounded so a broken observer cannot strand the service loop indefinitely.
  n=0
  while [ "$n" -lt 20 ]; do
    pid=$(worker_pid)
    if worker_pid_is_ours "$pid"; then
      printf '%s\n' "$pid" > "$WORKERFILE"
      event worker-started "$pid"
      return 0
    fi
    sleep 1
    n=$((n + 1))
  done
  return 1
}

stop_worker() {
  local pid
  pid=$(cat "$WORKERFILE" 2>/dev/null || true)
  if worker_pid_is_ours "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    local n=0
    while pid_alive "$pid" && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
    event worker-stopped "$pid"
  fi
  rm -f "$WORKERFILE"
}

loop() {
  mkdir -p "$STATE"
  if ! fm_lock_try_acquire "$LOCK"; then
    echo "artifact supervisor service already running${FM_LOCK_HELD_PID:+ (pid $FM_LOCK_HELD_PID)}" >&2
    return 1
  fi
  printf '%s\n' "$$" > "$PIDFILE"
  trap 'stop_worker; rm -f "$PIDFILE"; fm_lock_release "$LOCK"; exit 0' INT TERM EXIT
  event service-started "$$"
  while :; do
    if ensure_worker; then
      : > "$HEARTBEAT"
      rm -f "$ERROR"
    else
      printf '%s\tworker-start-failed\n' "$(now_epoch)" > "$ERROR"
      event worker-start-failed "observer did not publish a verified PID"
    fi
    sleep "$INTERVAL"
  done
}

start() {
  local pid
  mkdir -p "$STATE"
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if service_pid_is_ours "$pid"; then
    printf 'artifact supervisor service already running: pid %s\n' "$pid"
    return 0
  fi
  nohup "$0" --loop >> "$LOG" 2>&1 &
  printf 'artifact supervisor service starting: pid %s\n' "$!"
}

stop() {
  local pid n=0
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if service_pid_is_ours "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    while pid_alive "$pid" && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
  fi
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  --loop) loop ;;
  status) printf 'service-pid=%s worker-pid=%s heartbeat=%s\n' "$(cat "$PIDFILE" 2>/dev/null || echo off)" "$(worker_pid)" "$HEARTBEAT" ;;
  *) echo "usage: $0 [start|stop|restart|status|--loop]" >&2; exit 2 ;;
esac
