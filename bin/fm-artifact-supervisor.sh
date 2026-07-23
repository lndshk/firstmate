#!/usr/bin/env bash
# Durable, presence-neutral artifact supervision for a Firstmate home.
# It never writes to tmux or a chat pane.  The AFK daemon remains the only
# component that may batch and inject chat escalation digests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
INTERVAL="${FM_ARTIFACT_SUPERVISOR_INTERVAL:-15}"
LOCK="$STATE/.artifact-supervisor.lock"
PIDFILE="$STATE/.artifact-supervisor.pid"
HEARTBEAT="$STATE/.artifact-supervisor.heartbeat"
SNAPSHOT="$STATE/artifact-supervisor.tsv"
ESCALATIONS="$STATE/.artifact-supervisor.escalations"
LOG="$STATE/.artifact-supervisor.log"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"

now_epoch() { date +%s; }
mtime_epoch() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null
  else stat -c %Y "$1" 2>/dev/null; fi
}
age_of() {
  local m
  m=$(mtime_epoch "$1") || { printf '%s' 999999; return; }
  printf '%s' "$(( $(now_epoch) - m ))"
}
meta_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }
last_receipt() { awk 'NF { line=$0 } END { print line }' "$1" 2>/dev/null; }
clean_field() { LC_ALL=C tr '\t\r\n' '   '; }
terminal_receipt() {
  case "$1" in done:*|failed:*|blocked:*|needs-decision:*|result:*|terminal:*|pr-ready:*|merged:*) return 0 ;; esac
  return 1
}
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
receipt_failure() {
  case "$1" in failed:*|blocked:*|needs-decision:*) return 0 ;; esac
  return 1
}
pane_exists() { tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1; }
pid_alive() { fm_pid_alive "$1"; }
supervisor_pid_is_ours() { # <pid>
  local pid=$1 command lock_pid
  fm_pid_alive "$pid" || return 1
  lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$pid" ] || return 1
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in *"$SCRIPT_DIR/fm-artifact-supervisor.sh"*'--loop'*) return 0 ;; esac
  return 1
}
absolute_path() {
  case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$FM_HOME/$1" ;; esac
}

escalate_once() { # <id> <reason> <action>
  local id=$1 reason=$2 action=$3 key marker
  key=$(printf '%s' "$id-$reason" | tr -c 'A-Za-z0-9_.-' '_')
  marker="$STATE/.artifact-supervisor.escalated-$key"
  [ -e "$marker" ] && return 0
  printf '%s\t%s\t%s\t%s\n' "$(now_epoch)" "$id" "$reason" "$action" >> "$ESCALATIONS"
  : > "$marker"
}
clear_escalation() { # <id> <reason>
  local key
  key=$(printf '%s' "$1-$2" | tr -c 'A-Za-z0-9_.-' '_')
  rm -f "$STATE/.artifact-supervisor.escalated-$key"
}

classify_meta() { # <meta>; prints snapshot row
  local meta=$1 id window pid receipt_file receipt deadline artifact artifact_max artifact_path
  local class reason receipt_age artifact_age now fail_reason="" fail_action=""
  id=$(basename "$meta" .meta)
  window=$(meta_field "$meta" window)
  pid=$(meta_field "$meta" process-pid); [ -n "$pid" ] || pid=$(meta_field "$meta" pid)
  receipt_file="$STATE/$id.status"
  receipt=$(last_receipt "$receipt_file")
  receipt_age=$(age_of "$receipt_file")
  deadline=$(meta_field "$meta" receipt-deadline); [ -n "$deadline" ] || deadline=$(meta_field "$meta" deadline)
  artifact=$(meta_field "$meta" artifact)
  artifact_max=$(meta_field "$meta" artifact-max-age)
  artifact_age=0
  now=$(now_epoch)

  if [ -n "$artifact" ]; then
    artifact_path=$(absolute_path "$artifact")
    artifact_age=$(age_of "$artifact_path")
    if [ ! -e "$artifact_path" ]; then
      fail_reason=artifact-missing; fail_action="restore declared artifact $artifact"
    elif is_uint "$artifact_max" && [ "$artifact_age" -gt "$artifact_max" ]; then
      fail_reason=artifact-stale; fail_action="refresh declared artifact $artifact"
    fi
  fi

  if terminal_receipt "$receipt"; then
    class=terminal; reason="terminal receipt"
    if receipt_failure "$receipt"; then
      fail_reason=receipt-failure; fail_action="act on terminal receipt: $receipt"
    fi
  elif [ -n "$window" ] && ! pane_exists "$window"; then
    class=stalled; reason="recorded pane is gone"; fail_reason=window-gone; fail_action="inspect or relaunch recorded pane"
  elif [ -n "$window" ] && fm_pane_is_busy "$window"; then
    class=active; reason="busy pane observed"
    if [ -n "$pid" ] && ! pid_alive "$pid"; then
      fail_reason=process-gone; fail_action="inspect or relaunch task process"
    fi
  elif [ -n "$pid" ] && ! pid_alive "$pid"; then
    class=stalled; reason="declared process $pid is gone"; fail_reason=process-gone; fail_action="inspect or relaunch task process"
  elif [ -n "$pid" ] && pid_alive "$pid"; then
    class=active; reason="declared process is alive"
  elif is_uint "$deadline" && [ "$deadline" -le "$now" ]; then
    class=stalled; reason="receipt deadline passed"; fail_reason=receipt-deadline; fail_action="obtain a durable receipt or investigate task"
  else
    class=active-unverified; reason="awaiting durable receipt"
  fi

  # Artifact failure is a real contract failure. It is never mistaken for a
  # missing-receipt stall on an otherwise busy task, but it is escalated.
  if [ -n "$fail_reason" ]; then escalate_once "$id" "$fail_reason" "$fail_action"; else
    clear_escalation "$id" artifact-missing; clear_escalation "$id" artifact-stale
    clear_escalation "$id" receipt-failure; clear_escalation "$id" process-gone
    clear_escalation "$id" window-gone; clear_escalation "$id" receipt-deadline
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$class" "$reason" "$(printf '%s' "$receipt" | clean_field)" "$receipt_age" "${deadline:-}" "$artifact_age"
}

write_snapshot() {
  local tmp meta
  tmp="$SNAPSHOT.tmp.$$"
  {
    printf 'artifact-supervisor-v1\n'
    printf 'generated-at\t%s\n' "$(now_epoch)"
    for meta in "$STATE"/*.meta; do [ -f "$meta" ] && classify_meta "$meta"; done | LC_ALL=C sort
  } > "$tmp" && mv -f "$tmp" "$SNAPSHOT"
}

cycle() {
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  [ -s "$FM_WAKE_QUEUE" ] && cat "$FM_WAKE_QUEUE" >/dev/null 2>&1 || true
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  write_snapshot
  [ -x "$SCRIPT_DIR/fm-board.sh" ] && "$SCRIPT_DIR/fm-board.sh" --once >/dev/null 2>&1 || true
  : > "$HEARTBEAT"
}

loop() {
  mkdir -p "$STATE"
  if ! fm_lock_try_acquire "$LOCK"; then
    echo "artifact supervisor already running${FM_LOCK_HELD_PID:+ (pid $FM_LOCK_HELD_PID)}" >&2
    return 1
  fi
  printf '%s\n' "$$" > "$PIDFILE"
  trap 'rm -f "$PIDFILE"; fm_lock_release "$LOCK"; exit 0' INT TERM EXIT
  while :; do cycle; sleep "$INTERVAL"; done
}

start() {
  local pid
  mkdir -p "$STATE"
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if supervisor_pid_is_ours "$pid"; then printf 'artifact supervisor already running: pid %s\n' "$pid"; return 0; fi
  rm -f "$PIDFILE"
  nohup "$0" --loop >> "$LOG" 2>&1 &
  printf 'artifact supervisor starting: pid %s\n' "$!"
}

restart() {
  local pid n=0
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if supervisor_pid_is_ours "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    while fm_pid_alive "$pid" && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
  fi
  start
}

case "${1:-start}" in
  start) start ;;
  restart) restart ;;
  --loop) loop ;;
  --once) mkdir -p "$STATE"; cycle ;;
  status) printf 'pid=%s heartbeat-age=%s snapshot=%s\n' "$(cat "$PIDFILE" 2>/dev/null || echo off)" "$(age_of "$HEARTBEAT")" "$SNAPSHOT" ;;
  *) echo "usage: $0 [start|restart|status|--once]" >&2; exit 2 ;;
esac
