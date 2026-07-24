#!/usr/bin/env bash
# Always-on deterministic supervisor for one main Firstmate home.
#
# Usage: fm-supervisor.sh start|restart|status
# Test/internal: fm-supervisor.sh --once|--run --owner-token=<token>
#
# The process observes durable wakes, state/*.meta, status receipts, declared
# receipt deadlines, and recorded panes. It writes a machine-readable snapshot,
# durable actionable escalations, and the existing HTML board. It never sends
# keys, injects chat, drains the wake queue, schedules work, or changes AFK
# state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
INTERVAL="${FM_SUPERVISOR_INTERVAL:-15}"
START_WAIT="${FM_SUPERVISOR_START_WAIT:-5}"
case "$INTERVAL" in ''|0|*[!0-9]*) INTERVAL=15 ;; esac
case "$START_WAIT" in ''|0|*[!0-9]*) START_WAIT=5 ;; esac
LOCK="$STATE/.firstmate-supervisor.lock"
CONTROL_LOCK="$STATE/.firstmate-supervisor.control.lock"
PIDFILE="$STATE/.firstmate-supervisor.pid"
OWNER_RECEIPT="$STATE/.firstmate-supervisor.owner"
HEARTBEAT="$STATE/.firstmate-supervisor.heartbeat"
SNAPSHOT="${FM_SUPERVISOR_SNAPSHOT:-$STATE/firstmate-supervisor.tsv}"
ESCALATIONS="$STATE/.firstmate-supervisor.escalations"
LOG="$STATE/.firstmate-supervisor.log"
ERROR="$STATE/.firstmate-supervisor.error"
WAIT_PID=

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"

OWNER_STATE=$(cd "$STATE" 2>/dev/null && pwd -P) || {
  printf 'error: cannot resolve supervisor state directory: %s\n' "$STATE" >&2
  exit 1
}
OWNER_TOKEN=$(printf '%s' "$OWNER_STATE" | cksum | awk '{ print $1 "-" $2 }')

now_epoch() { date +%s; }
is_uint() {
  case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}
clean_field() { LC_ALL=C tr '\t\r\n' '   '; }
snapshot_field() {
  if [ -n "$1" ]; then printf '%s' "$1" | clean_field
  else printf -- '-'; fi
}
meta_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }
last_receipt() { awk 'NF { line=$0 } END { print line }' "$1" 2>/dev/null; }
last_receipt_line() { awk 'NF { line=NR } END { print line + 0 }' "$1" 2>/dev/null; }

terminal_receipt() {
  case "$1" in
    done:*|failed:*|blocked:*|needs-decision:*|result:*|terminal:*|pr-ready:*|merged:*) return 0 ;;
  esac
  return 1
}

failed_receipt() {
  case "$1" in failed:*|blocked:*|needs-decision:*) return 0 ;; esac
  return 1
}

pane_exists() {
  [ -n "$1" ] && tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1
}

supervisor_process_matches_owner() {
  local pid=$1 command
  fm_pid_alive "$pid" || return 1
  command=$(ps -ww -p "$pid" -o command= 2>/dev/null) || return 2
  [ -n "$command" ] || return 2
  case "$command" in
    *"fm-supervisor.sh"*"--run"*"--owner-token=$OWNER_TOKEN"*) return 0 ;;
    *"fm-supervisor.sh"*"--run"*"--owner-token="*) return 1 ;;
  esac
  return 2
}

supervisor_pid_is_ours() {
  local pid=$1 lock_pid
  fm_pid_alive "$pid" || return 1
  lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$pid" ] || return 1
  supervisor_process_matches_owner "$pid"
}

clear_foreign_runtime_lock() {
  local lock_pid match
  lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  fm_pid_alive "$lock_pid" || return 0
  if supervisor_process_matches_owner "$lock_pid"; then
    printf 'error: supervisor runtime lock is held by owner pid %s without a valid PID receipt\n' "$lock_pid" >&2
    return 1
  else
    match=$?
  fi
  if [ "$match" -eq 2 ]; then
    printf 'error: supervisor runtime lock is held by unverified pid %s; inspect it before retrying\n' "$lock_pid" >&2
    return 1
  fi
  [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$lock_pid" ] || return 1
  rm -f "$LOCK/pid" 2>/dev/null || return 1
  rmdir "$LOCK" 2>/dev/null
}

escalation_key() {
  printf '%s-%s' "$1" "$2" | tr -c 'A-Za-z0-9_.-' '_'
}

escalate_once() { # <id> <condition> <action> [evidence]
  local id=$1 condition=$2 action=$3 marker evidence previous tmp
  marker="$STATE/.firstmate-supervisor.escalated-$(escalation_key "$id" "$condition")"
  if [ $# -lt 4 ]; then
    [ -e "$marker" ] && return 0
  else
    evidence=$4
    previous=$(cat "$marker" 2>/dev/null || true)
    [ "$previous" = "$evidence" ] && return 0
  fi
  printf '%s\t%s\t%s\t%s\n' \
    "$(now_epoch)" \
    "$(printf '%s' "$id" | clean_field)" \
    "$(printf '%s' "$condition" | clean_field)" \
    "$(printf '%s' "$action" | clean_field)" >> "$ESCALATIONS" || return 1
  if [ $# -lt 4 ]; then
    : > "$marker"
  else
    tmp="$marker.tmp.$$"
    printf '%s\n' "$evidence" > "$tmp" && mv -f "$tmp" "$marker"
  fi
}

clear_escalation() { # <id> <condition>
  rm -f "$STATE/.firstmate-supervisor.escalated-$(escalation_key "$1" "$2")"
}

receipt_evidence() { # <id> <status-file> <receipt>; prints <version><tab><time>
  local id=$1 receipt_file=$2 receipt=$3 line hash version observed cursor
  local saved_version saved_time tmp
  line=$(last_receipt_line "$receipt_file")
  hash=$(printf '%s' "$receipt" | cksum | awk '{ print $1 "-" $2 }')
  version="$line-$hash"
  observed=$(fm_path_mtime "$receipt_file" 2>/dev/null || true)
  is_uint "$observed" || observed=$(now_epoch)
  cursor="$STATE/.firstmate-supervisor.receipt-$(escalation_key "$id" receipt)"
  IFS="$(printf '\t')" read -r saved_version saved_time <<EOF
$(cat "$cursor" 2>/dev/null || true)
EOF
  if [ "$saved_version" = "$version" ] && is_uint "$saved_time"; then
    observed=$saved_time
  fi
  if [ "$saved_version" != "$version" ] || ! is_uint "$saved_time"; then
    tmp="$cursor.tmp.$$"
    printf '%s\t%s\n' "$version" "$observed" > "$tmp" \
      && mv -f "$tmp" "$cursor" || return 1
  fi
  printf '%s\t%s\n' "$version" "$observed"
}

clear_receipt_evidence() { # <id>
  rm -f "$STATE/.firstmate-supervisor.receipt-$(escalation_key "$1" receipt)"
}

classify_meta() { # <meta>; prints one TSV task row
  local meta=$1 id window pid deadline receipt receipt_file now
  local state reason process_condition="" deadline_condition="" receipt_condition=""
  local pane_activity=idle pid_activity=idle receipt_version="" receipt_time=""
  id=$(basename "$meta" .meta)
  window=$(meta_field "$meta" window)
  pid=$(meta_field "$meta" process-pid)
  [ -n "$pid" ] || pid=$(meta_field "$meta" pid)
  deadline=$(meta_field "$meta" receipt-deadline)
  [ -n "$deadline" ] || deadline=$(meta_field "$meta" deadline)
  receipt_file="$STATE/$id.status"
  receipt=$(last_receipt "$receipt_file")
  now=$(now_epoch)

  if [ -n "$receipt" ]; then
    IFS="$(printf '\t')" read -r receipt_version receipt_time <<EOF
$(receipt_evidence "$id" "$receipt_file" "$receipt")
EOF
  else
    clear_receipt_evidence "$id"
  fi
  if is_uint "$deadline" && [ "$deadline" -le "$now" ]; then
    if [ -z "$receipt" ] || ! is_uint "$receipt_time" || [ "$receipt_time" -gt "$deadline" ]; then
      deadline_condition=missed-receipt-deadline
    fi
  fi

  if terminal_receipt "$receipt"; then
    state=terminal
    reason="terminal receipt recorded"
    if failed_receipt "$receipt"; then
      receipt_condition=failed-receipt
    fi
  else
    if [ -n "$window" ]; then
      if pane_exists "$window"; then
        pane_activity=$(fm_pane_busy_state "$window")
      else
        pane_activity=missing
        process_condition=missing-process
      fi
    fi
    if [ -n "$pid" ]; then
      if fm_pid_alive "$pid"; then
        pid_activity=active
      else
        pid_activity=missing
        process_condition=missing-process
      fi
    fi

    if [ "$pane_activity" = busy ]; then
      state=active
      reason="busy pane observed"
    elif [ "$pid_activity" = active ]; then
      state=active
      reason="declared process is alive"
    elif [ "$pane_activity" = unknown ]; then
      state=active-unverified
      reason="pane activity could not be verified"
    elif [ -n "$process_condition" ]; then
      state=stalled
      reason="recorded process is missing"
    elif [ -n "$deadline_condition" ]; then
      state=stalled
      reason="receipt deadline passed"
    else
      state=active-unverified
      reason="awaiting verifiable activity or receipt"
    fi
  fi

  if [ -n "$process_condition" ]; then
    escalate_once "$id" "$process_condition" \
      "inspect or relaunch the recorded direct-report process" || return 1
  else
    clear_escalation "$id" missing-process
  fi
  if [ -n "$deadline_condition" ]; then
    escalate_once "$id" "$deadline_condition" \
      "obtain the declared receipt or investigate the direct report" || return 1
  else
    clear_escalation "$id" missed-receipt-deadline
  fi
  if [ -n "$receipt_condition" ]; then
    escalate_once "$id" "$receipt_condition" \
      "act on terminal receipt: $receipt" "$receipt_version" || return 1
  else
    clear_escalation "$id" failed-receipt
  fi

  printf 'task\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(snapshot_field "$id")" \
    "$state" \
    "$(snapshot_field "$reason")" \
    "$(snapshot_field "$receipt")" \
    "$(snapshot_field "$deadline")" \
    "$(snapshot_field "$window")" \
    "$(snapshot_field "$pid")"
}

wake_snapshot() { # prints: <count><tab><last-seq>
  local wakes count queue_last_seq durable_last_seq
  wakes=$(fm_wake_peek 2>/dev/null || true)
  count=$(printf '%s\n' "$wakes" | awk 'NF { n++ } END { print n + 0 }')
  queue_last_seq=$(printf '%s\n' "$wakes" | awk -F '\t' 'NF >= 2 && $2 ~ /^[0-9]+$/ && $2 > max { max=$2 } END { print max + 0 }')
  durable_last_seq=$(cat "$STATE/.wake-queue.seq" 2>/dev/null || echo 0)
  is_uint "$durable_last_seq" || durable_last_seq=0
  [ "$queue_last_seq" -le "$durable_last_seq" ] || durable_last_seq=$queue_last_seq
  printf '%s\t%s\n' "$count" "$durable_last_seq"
}

write_snapshot() {
  local tmp rows meta wake_count wake_last_seq status
  tmp="$SNAPSHOT.tmp.$$"
  rows="$tmp.rows"
  rm -f "$rows"
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    classify_meta "$meta" >> "$rows" || {
      rm -f "$tmp" "$rows"
      return 1
    }
  done
  IFS="$(printf '\t')" read -r wake_count wake_last_seq <<EOF
$(wake_snapshot)
EOF
  {
    printf 'firstmate-supervisor-v1\n'
    printf 'generated-at\t%s\n' "$(now_epoch)"
    printf 'wake-count\t%s\n' "$wake_count"
    printf 'wake-last-seq\t%s\n' "$wake_last_seq"
    [ ! -f "$rows" ] || LC_ALL=C sort "$rows"
  } > "$tmp" || {
    rm -f "$tmp" "$rows"
    return 1
  }
  mv -f "$tmp" "$SNAPSHOT"
  status=$?
  rm -f "$rows"
  return "$status"
}

write_heartbeat() {
  local tmp
  tmp="$HEARTBEAT.tmp.$$"
  printf '%s\n' "$(now_epoch)" > "$tmp" && mv -f "$tmp" "$HEARTBEAT"
}

record_error() {
  printf '%s\t%s\n' "$(now_epoch)" "$1" >> "$LOG" 2>/dev/null || true
  printf '%s\t%s\n' "$(now_epoch)" "$1" > "$ERROR" 2>/dev/null || true
}

cycle() {
  mkdir -p "$STATE"
  if ! write_snapshot; then
    record_error snapshot-write-failed
    return 1
  fi
  if ! FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" \
    FM_SUPERVISOR_SNAPSHOT="$SNAPSHOT" \
    "$SCRIPT_DIR/fm-board.sh" --once >/dev/null 2>&1; then
    record_error board-refresh-failed
    return 1
  fi
  if ! write_heartbeat; then
    record_error heartbeat-write-failed
    return 1
  fi
  rm -f "$ERROR"
}

run_loop() {
  local owner_tmp
  mkdir -p "$STATE"
  if ! fm_lock_try_acquire "$LOCK"; then
    printf 'supervisor already running%s\n' "${FM_LOCK_HELD_PID:+ (pid $FM_LOCK_HELD_PID)}" >&2
    return 1
  fi
  owner_tmp="$OWNER_RECEIPT.tmp.$$"
  {
    printf 'pid=%s\n' "$$"
    printf 'interval=%s\n' "$INTERVAL"
  } > "$owner_tmp" && mv -f "$owner_tmp" "$OWNER_RECEIPT" || {
    fm_lock_release "$LOCK"
    return 1
  }
  printf '%s\n' "$$" > "$PIDFILE" || {
    rm -f "$OWNER_RECEIPT"
    fm_lock_release "$LOCK"
    return 1
  }
  trap 'owner_cleanup 0' INT TERM
  trap 'owner_cleanup $?' EXIT
  while :; do
    cycle || true
    sleep_interval
  done
}

owner_cleanup() {
  local status=$1
  trap - INT TERM EXIT
  if [ -n "$WAIT_PID" ]; then
    kill "$WAIT_PID" 2>/dev/null || true
    wait "$WAIT_PID" 2>/dev/null || true
    WAIT_PID=
  fi
  rm -f "$PIDFILE" "$OWNER_RECEIPT"
  fm_lock_release "$LOCK"
  exit "$status"
}

sleep_interval() {
  sleep "$INTERVAL" &
  WAIT_PID=$!
  wait "$WAIT_PID" 2>/dev/null || true
  WAIT_PID=
}

heartbeat_is_ready() { # <not-before-epoch>
  local not_before=$1 beat
  beat=$(cat "$HEARTBEAT" 2>/dev/null || true)
  is_uint "$beat" && [ "$beat" -ge "$not_before" ]
}

owner_interval() { # <pid>
  local pid=$1 receipt_pid receipt_interval
  receipt_pid=$(meta_field "$OWNER_RECEIPT" pid)
  receipt_interval=$(meta_field "$OWNER_RECEIPT" interval)
  [ "$receipt_pid" = "$pid" ] || return 1
  is_uint "$receipt_interval" && [ "$receipt_interval" -gt 0 ] || return 1
  printf '%s\n' "$receipt_interval"
}

heartbeat_is_healthy() { # <pid>
  local pid=$1 beat age max_age receipt_interval
  beat=$(cat "$HEARTBEAT" 2>/dev/null || true)
  is_uint "$beat" || return 1
  receipt_interval=$(owner_interval "$pid") || return 1
  age=$(( $(now_epoch) - beat ))
  max_age=$((receipt_interval * 2 + 5))
  [ "$age" -ge 0 ] && [ "$age" -le "$max_age" ]
}

child_has_exited() {
  local child=$1 stat
  fm_pid_alive "$child" || return 0
  stat=$(ps -p "$child" -o stat= 2>/dev/null || true)
  case "$stat" in *Z*) return 0 ;; esac
  return 1
}

clear_child_ownership() {
  local child=$1 lock_pid receipt_pid owner_pid
  receipt_pid=$(cat "$PIDFILE" 2>/dev/null || true)
  [ "$receipt_pid" != "$child" ] || rm -f "$PIDFILE"
  owner_pid=$(meta_field "$OWNER_RECEIPT" pid)
  [ "$owner_pid" != "$child" ] || rm -f "$OWNER_RECEIPT"
  lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ "$lock_pid" = "$child" ]; then
    rm -f "$LOCK/pid" 2>/dev/null || return 1
    rmdir "$LOCK" 2>/dev/null || return 1
  fi
}

stop_failed_child() {
  local child=$1 waited=0
  if ! child_has_exited "$child"; then
    supervisor_process_matches_owner "$child" || return 1
    kill -TERM "$child" 2>/dev/null || return 1
    while ! child_has_exited "$child" && [ "$waited" -lt "$START_WAIT" ]; do
      sleep 1
      waited=$((waited + 1))
    done
  fi
  if ! child_has_exited "$child"; then
    supervisor_process_matches_owner "$child" || return 1
    kill -KILL "$child" 2>/dev/null || return 1
    waited=0
    while ! child_has_exited "$child" && [ "$waited" -lt "$START_WAIT" ]; do
      sleep 1
      waited=$((waited + 1))
    done
  fi
  child_has_exited "$child" || return 1
  wait "$child" 2>/dev/null || true
  clear_child_ownership "$child"
}

wait_for_owner() { # <preferred-child-pid> <not-before-epoch>
  local child=$1 not_before=$2 waited=0 pid
  while [ "$waited" -lt "$START_WAIT" ]; do
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if supervisor_pid_is_ours "$pid" && heartbeat_is_ready "$not_before"; then
      printf 'supervisor running: pid %s\n' "$pid"
      return 0
    fi
    fm_pid_alive "$child" || break
    sleep 1
    waited=$((waited + 1))
  done
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if supervisor_pid_is_ours "$pid" && heartbeat_is_ready "$not_before"; then
    printf 'supervisor running: pid %s\n' "$pid"
    return 0
  fi
  if ! stop_failed_child "$child"; then
    printf 'error: supervisor failed readiness and could not relinquish ownership safely\n' >&2
    return 1
  fi
  printf 'error: supervisor failed to publish a fresh heartbeat after its initial cycle\n' >&2
  return 1
}

start_unlocked() {
  local pid child started
  mkdir -p "$STATE"
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if supervisor_pid_is_ours "$pid"; then
    if heartbeat_is_healthy "$pid"; then
      printf 'supervisor already running: pid %s\n' "$pid"
      return 0
    fi
    printf 'error: supervisor pid %s has no fresh heartbeat\n' "$pid" >&2
    return 1
  fi
  clear_foreign_runtime_lock || {
    printf 'error: could not clear a foreign supervisor lock\n' >&2
    return 1
  }
  rm -f "$HEARTBEAT" || {
    printf 'error: could not clear stale supervisor heartbeat\n' >&2
    return 1
  }
  started=$(now_epoch)
  nohup "$SCRIPT_DIR/fm-supervisor.sh" --run "--owner-token=$OWNER_TOKEN" >> "$LOG" 2>&1 &
  child=$!
  wait_for_owner "$child" "$started"
}

start() {
  mkdir -p "$STATE"
  if ! fm_lock_try_acquire "$CONTROL_LOCK"; then
    printf 'supervisor control operation already in progress%s\n' "${FM_LOCK_HELD_PID:+ (pid $FM_LOCK_HELD_PID)}" >&2
    return 1
  fi
  trap 'fm_lock_release "$CONTROL_LOCK"' EXIT
  start_unlocked
}

restart() {
  local pid waited=0 rc
  mkdir -p "$STATE"
  if ! fm_lock_try_acquire "$CONTROL_LOCK"; then
    printf 'supervisor control operation already in progress%s\n' "${FM_LOCK_HELD_PID:+ (pid $FM_LOCK_HELD_PID)}" >&2
    return 1
  fi
  trap 'fm_lock_release "$CONTROL_LOCK"' EXIT
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if supervisor_pid_is_ours "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    while fm_pid_alive "$pid" && [ "$waited" -lt "$START_WAIT" ]; do
      sleep 1
      waited=$((waited + 1))
    done
    if fm_pid_alive "$pid"; then
      printf 'error: supervisor pid %s did not stop; refusing duplicate start\n' "$pid" >&2
      return 1
    fi
  fi
  start_unlocked
  rc=$?
  return "$rc"
}

status() {
  local pid beat beat_age snapshot_age error
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  beat=$(cat "$HEARTBEAT" 2>/dev/null || true)
  beat_age=$(fm_path_age "$HEARTBEAT")
  snapshot_age=$(fm_path_age "$SNAPSHOT")
  error=$(cat "$ERROR" 2>/dev/null || true)
  if supervisor_pid_is_ours "$pid"; then
    printf 'state=running pid=%s heartbeat=%s heartbeat-age=%s snapshot-age=%s' \
      "$pid" "${beat:-missing}" "$beat_age" "$snapshot_age"
    [ -z "$error" ] || printf ' error=%s' "$(printf '%s' "$error" | clean_field)"
    printf '\n'
    return 0
  fi
  printf 'state=stopped pid=%s heartbeat=%s heartbeat-age=%s snapshot-age=%s' \
    "${pid:-none}" "${beat:-missing}" "$beat_age" "$snapshot_age"
  [ -z "$error" ] || printf ' error=%s' "$(printf '%s' "$error" | clean_field)"
  printf '\n'
  return 1
}

case "${1:-status}" in
  start) start ;;
  restart) restart ;;
  status) status ;;
  --once) cycle ;;
  --run)
    [ "${2:-}" = "--owner-token=$OWNER_TOKEN" ] || {
      printf 'error: supervisor owner token does not match this home\n' >&2
      exit 2
    }
    run_loop
    ;;
  *) printf 'usage: %s start|restart|status\n' "$0" >&2; exit 2 ;;
esac
