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
SERVICE="$SCRIPT_DIR/fm-artifact-supervisor-service.sh"
SUPERVISOR="$SCRIPT_DIR/fm-artifact-supervisor.sh"
INTERVAL="${FM_ARTIFACT_SERVICE_INTERVAL:-2}"
SUPERVISOR_INTERVAL="${FM_ARTIFACT_SUPERVISOR_INTERVAL:-15}"
WORKER_STALE_AFTER="${FM_ARTIFACT_WORKER_STALE_AFTER:-$((SUPERVISOR_INTERVAL * 3))}"
WORKER_STARTUP_GRACE="${FM_ARTIFACT_WORKER_STARTUP_GRACE:-$((SUPERVISOR_INTERVAL * 2))}"
WORKER_STOP_TIMEOUT="${FM_ARTIFACT_WORKER_STOP_TIMEOUT:-20}"
LOCK="$STATE/.artifact-supervisor.service.lock"
PIDFILE="$STATE/.artifact-supervisor.service.pid"
WORKERFILE="$STATE/.artifact-supervisor.service.worker"
HEARTBEAT="$STATE/.artifact-supervisor.service.heartbeat"
WORKER_HEARTBEAT="$STATE/.artifact-supervisor.heartbeat"
LOG="$STATE/.artifact-supervisor.service.log"
ERROR="$STATE/.artifact-supervisor.service.error"
EVENTS="$STATE/.artifact-supervisor.service.events"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

now_epoch() { date +%s; }
pid_alive() {
  local pid=$1 state
  fm_pid_alive "$pid" || return 1
  state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$state" in *Z*) return 1 ;; esac
  [ -n "$state" ]
}
mtime_epoch() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}
age_of() {
  local modified
  modified=$(mtime_epoch "$1") || return 1
  printf '%s\n' "$(( $(now_epoch) - modified ))"
}

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
  local pid=$1 command worker_lock_pid
  pid_alive "$pid" || return 1
  worker_lock_pid=$(cat "$STATE/.artifact-supervisor.lock/pid" 2>/dev/null || true)
  [ "$worker_lock_pid" = "$pid" ] || return 1
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in *"$SCRIPT_DIR/fm-artifact-supervisor.sh"*'--loop'*) return 0 ;; esac
  return 1
}
worker_pid() { cat "$STATE/.artifact-supervisor.pid" 2>/dev/null || true; }
owned_worker_pid() { awk 'NR == 1 { print $1 }' "$WORKERFILE" 2>/dev/null || true; }
owned_worker_phase() { awk 'NR == 1 { print $2 }' "$WORKERFILE" 2>/dev/null || true; }
record_worker() {
  local pid=$1 phase=$2 tmp="$WORKERFILE.tmp.$$"
  printf '%s %s\n' "$pid" "$phase" > "$tmp" && mv -f "$tmp" "$WORKERFILE"
}
worker_heartbeat_fresh() {
  local age
  age=$(age_of "$WORKER_HEARTBEAT") || return 1
  [ "$age" -le "$WORKER_STALE_AFTER" ]
}
worker_within_startup_grace() {
  local pid=$1 age
  [ "$(owned_worker_pid)" = "$pid" ] || return 1
  [ "$(owned_worker_phase)" = starting ] || return 1
  age=$(age_of "$WORKERFILE") || return 1
  [ "$age" -le "$WORKER_STARTUP_GRACE" ]
}
event() { printf '%s\t%s\t%s\n' "$(now_epoch)" "$1" "$2" >> "$EVENTS"; }

ensure_worker() {
  local pid n=0 lock_pid owned phase
  pid=$(worker_pid)
  if worker_pid_is_ours "$pid"; then
    owned=$(owned_worker_pid)
    phase=$(owned_worker_phase)
    if [ "$owned" != "$pid" ]; then
      record_worker "$pid" running || return 1
      event worker-adopted "$pid"
      phase=running
    fi
    if worker_heartbeat_fresh; then
      [ "$phase" = running ] || record_worker "$pid" running || return 1
      return 0
    fi
    if worker_within_startup_grace "$pid"; then
      return 0
    fi
    event worker-unhealthy "$pid heartbeat stale or missing"
    stop_worker || return 1
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
      record_worker "$pid" starting || return 1
      event worker-started "$pid"
      return 0
    fi
    sleep 1
    n=$((n + 1))
  done
  return 1
}

stop_worker() {
  local pid n=0
  pid=$(owned_worker_pid)
  if worker_pid_is_ours "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    while pid_alive "$pid" && [ "$n" -lt "$WORKER_STOP_TIMEOUT" ]; do sleep 1; n=$((n + 1)); done
    if pid_alive "$pid"; then
      event worker-stop-timeout "$pid"
      kill -KILL "$pid" 2>/dev/null || true
      n=0
      while pid_alive "$pid" && [ "$n" -lt 5 ]; do sleep 1; n=$((n + 1)); done
      if pid_alive "$pid"; then
        event worker-stop-failed "$pid"
        return 1
      fi
    fi
    event worker-stopped "$pid"
  fi
  rm -f "$WORKERFILE" "$WORKER_HEARTBEAT"
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
  nohup "$SERVICE" --loop >> "$LOG" 2>&1 &
  printf 'artifact supervisor service starting: pid %s\n' "$!"
}

stop() {
  local pid n=0
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if service_pid_is_ours "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    while pid_alive "$pid" && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
    if pid_alive "$pid"; then
      printf 'artifact supervisor service did not terminate: pid %s\n' "$pid" >&2
      return 1
    fi
    # The service trap normally removes this.  Once the process is proven
    # gone, removing a stale receipt is safe and prevents start() from ever
    # treating it as a candidate replacement.
    rm -f "$PIDFILE"
  elif [ -n "$pid" ] && pid_alive "$pid"; then
    printf 'artifact supervisor service PID is not verified; refusing restart: pid %s\n' "$pid" >&2
    return 1
  fi
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  # Never overlap generations: replacement launch is contingent on a confirmed
  # old-service exit, including the PID receipt becoming stale.
  restart) stop && start ;;
  --loop) loop ;;
  status) printf 'service-pid=%s worker-pid=%s heartbeat=%s\n' "$(cat "$PIDFILE" 2>/dev/null || echo off)" "$(worker_pid)" "$HEARTBEAT" ;;
  *) echo "usage: $0 [start|stop|restart|status|--loop]" >&2; exit 2 ;;
esac
