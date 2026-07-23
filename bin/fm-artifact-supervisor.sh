#!/usr/bin/env bash
# Usage: fm-artifact-supervisor.sh [start|restart|status|--once]
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
ERROR="$STATE/.artifact-supervisor.error"

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
  printf '%s\t%s\t%s\t%s\n' "$(now_epoch)" "$id" "$reason" "$action" >> "$ESCALATIONS" || return 1
  : > "$marker" || return 1
}
clear_escalation() { # <id> <reason>
  local key
  key=$(printf '%s' "$1-$2" | tr -c 'A-Za-z0-9_.-' '_')
  rm -f "$STATE/.artifact-supervisor.escalated-$key"
}

classify_meta() { # <meta>; prints snapshot row
  local meta=$1 id window pid receipt_file receipt deadline artifact artifact_max artifact_path
  local class reason receipt_age artifact_age now artifact_reason="" artifact_action=""
  local receipt_reason="" receipt_action="" process_reason="" process_action=""
  local window_reason="" window_action="" deadline_reason="" deadline_action=""
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
      artifact_reason=artifact-missing; artifact_action="restore declared artifact $artifact"
    elif is_uint "$artifact_max" && [ "$artifact_age" -gt "$artifact_max" ]; then
      artifact_reason=artifact-stale; artifact_action="refresh declared artifact $artifact"
    fi
  fi

  if terminal_receipt "$receipt"; then
    class=terminal; reason="terminal receipt"
    if receipt_failure "$receipt"; then
      receipt_reason=receipt-failure; receipt_action="act on terminal receipt: $receipt"
    fi
  else
    if [ -n "$window" ] && ! pane_exists "$window"; then
      window_reason=window-gone; window_action="inspect or relaunch recorded pane"
    fi
    if [ -n "$pid" ] && ! pid_alive "$pid"; then
      process_reason=process-gone; process_action="inspect or relaunch task process"
    fi
    if [ -z "$receipt" ] && is_uint "$deadline" && [ "$deadline" -le "$now" ]; then
      deadline_reason=receipt-deadline; deadline_action="obtain a durable receipt or investigate task"
    fi

    if [ -n "$window_reason" ]; then
      class=stalled; reason="recorded pane is gone"
    elif [ -n "$window" ] && fm_pane_is_busy "$window"; then
      class=active; reason="busy pane observed"
    elif [ -n "$process_reason" ]; then
      class=stalled; reason="declared process $pid is gone"
    elif [ -n "$pid" ] && pid_alive "$pid"; then
      class=active; reason="declared process is alive"
    elif [ -n "$deadline_reason" ]; then
      class=stalled; reason="receipt deadline passed"
    else
      class=active-unverified; reason="awaiting durable receipt"
    fi
  fi

  if [ -n "$artifact_reason" ]; then escalate_once "$id" "$artifact_reason" "$artifact_action" || return 1; else clear_escalation "$id" artifact-missing; clear_escalation "$id" artifact-stale; fi
  if [ -n "$receipt_reason" ]; then escalate_once "$id" "$receipt_reason" "$receipt_action" || return 1; else clear_escalation "$id" receipt-failure; fi
  if [ -n "$process_reason" ]; then escalate_once "$id" "$process_reason" "$process_action" || return 1; else clear_escalation "$id" process-gone; fi
  if [ -n "$window_reason" ]; then escalate_once "$id" "$window_reason" "$window_action" || return 1; else clear_escalation "$id" window-gone; fi
  if [ -n "$deadline_reason" ]; then escalate_once "$id" "$deadline_reason" "$deadline_action" || return 1; else clear_escalation "$id" receipt-deadline; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$class" "$reason" "$(printf '%s' "$receipt" | clean_field)" "$receipt_age" "${deadline:-}" "$artifact_age"
}

write_snapshot() {
  local tmp rows meta status
  tmp="$SNAPSHOT.tmp.$$"
  rows="$tmp.rows"
  rm -f "$rows"
  : > "$rows" || return 1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    classify_meta "$meta" >> "$rows" || { rm -f "$tmp" "$rows"; return 1; }
  done
  {
    printf 'artifact-supervisor-v1\n'
    printf 'generated-at\t%s\n' "$(now_epoch)"
    LC_ALL=C sort "$rows"
  } > "$tmp" && mv -f "$tmp" "$SNAPSHOT"
  status=$?
  rm -f "$rows"
  return "$status"
}

cycle() {
  fm_wake_peek >/dev/null 2>&1 || true
  if ! write_snapshot; then
    printf '%s\tsnapshot-write-failed\n' "$(now_epoch)" >> "$LOG" 2>/dev/null || true
    printf '%s\tsnapshot-write-failed\n' "$(now_epoch)" > "$ERROR" 2>/dev/null || true
    return 1
  fi
  if ! [ -x "$SCRIPT_DIR/fm-board.sh" ] || ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_ARTIFACT_SNAPSHOT="$SNAPSHOT" FM_ARTIFACT_STALE_AFTER="$((INTERVAL * 3))" "$SCRIPT_DIR/fm-board.sh" --once >/dev/null 2>&1; then
    printf '%s\tboard-refresh-failed\n' "$(now_epoch)" >> "$LOG" 2>/dev/null || true
    printf '%s\tboard-refresh-failed\n' "$(now_epoch)" > "$ERROR" 2>/dev/null || true
    return 1
  fi
  if ! : > "$HEARTBEAT"; then
    printf '%s\theartbeat-write-failed\n' "$(now_epoch)" >> "$LOG" 2>/dev/null || true
    printf '%s\theartbeat-write-failed\n' "$(now_epoch)" > "$ERROR" 2>/dev/null || true
    return 1
  fi
  rm -f "$ERROR"
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
  nohup "$SCRIPT_DIR/fm-artifact-supervisor.sh" --loop >> "$LOG" 2>&1 &
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
