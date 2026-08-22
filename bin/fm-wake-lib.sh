#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.

fm_receipt_explicit_time() {
  local raw=$1 tab suffix
  tab=$(printf '\t')
  suffix=${raw##*"$tab"}
  [ "$suffix" != "$raw" ] || return 1
  case "$suffix" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$suffix"
}

fm_receipt_text() {
  local raw=$1 tab suffix
  tab=$(printf '\t')
  suffix=${raw##*"$tab"}
  if [ "$suffix" != "$raw" ]; then
    case "$suffix" in
      ''|*[!0-9]*) ;;
      *) printf '%s' "${raw%"$tab$suffix"}"; return ;;
    esac
  fi
  printf '%s' "$raw"
}

[ "${FM_WAKE_LIB_PARSERS_ONLY:-0}" = 1 ] && return 0

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"
FM_LOCK_USE_FLOCK=${FM_LOCK_USE_FLOCK:-}
if [ -z "$FM_LOCK_USE_FLOCK" ]; then
  command -v flock >/dev/null 2>&1 && FM_LOCK_USE_FLOCK=1 || FM_LOCK_USE_FLOCK=0
fi
# A caller can hold a supervisory lock while it also snapshots the wake queue,
# so retain separate descriptors instead of replacing an outer advisory lock.
FM_LOCK_FLOCK_9=${FM_LOCK_FLOCK_9:-}
FM_LOCK_FLOCK_8=${FM_LOCK_FLOCK_8:-}
FM_LOCK_FLOCK_7=${FM_LOCK_FLOCK_7:-}
FM_LOCK_FLOCK_6=${FM_LOCK_FLOCK_6:-}
mkdir -p "$STATE"

fm_lock_flock_open() {
  local lockdir=$1
  if [ -z "$FM_LOCK_FLOCK_9" ]; then
    exec 9>"$lockdir.flock" || return 2
    flock -n -x 9 || { exec 9>&-; return 1; }
    FM_LOCK_FLOCK_9=$lockdir
    return 0
  fi
  if [ -z "$FM_LOCK_FLOCK_8" ]; then
    exec 8>"$lockdir.flock" || return 2
    flock -n -x 8 || { exec 8>&-; return 1; }
    FM_LOCK_FLOCK_8=$lockdir
    return 0
  fi
  if [ -z "$FM_LOCK_FLOCK_7" ]; then
    exec 7>"$lockdir.flock" || return 2
    flock -n -x 7 || { exec 7>&-; return 1; }
    FM_LOCK_FLOCK_7=$lockdir
    return 0
  fi
  if [ -z "$FM_LOCK_FLOCK_6" ]; then
    exec 6>"$lockdir.flock" || return 2
    flock -n -x 6 || { exec 6>&-; return 1; }
    FM_LOCK_FLOCK_6=$lockdir
    return 0
  fi
  printf 'fm_lock_try_acquire: too many nested locks\n' >&2
  return 2
}

fm_lock_flock_close() {
  local lockdir=$1
  case "$lockdir" in
    "$FM_LOCK_FLOCK_9") flock -u 9 2>/dev/null || true; exec 9>&-; FM_LOCK_FLOCK_9= ;;
    "$FM_LOCK_FLOCK_8") flock -u 8 2>/dev/null || true; exec 8>&-; FM_LOCK_FLOCK_8= ;;
    "$FM_LOCK_FLOCK_7") flock -u 7 2>/dev/null || true; exec 7>&-; FM_LOCK_FLOCK_7= ;;
    "$FM_LOCK_FLOCK_6") flock -u 6 2>/dev/null || true; exec 6>&-; FM_LOCK_FLOCK_6= ;;
    *) return 1 ;;
  esac
}

fm_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

fm_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

fm_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local path=$1 m
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

fm_lock_try_acquire() {
  local lockdir=$1 pid open_status attempt
  FM_LOCK_HELD_PID=
  if [ "$FM_LOCK_USE_FLOCK" = 1 ]; then
    # mkdir followed by writing pid is not atomic: under load, a contender can
    # otherwise reclaim the ownerless directory before its creator runs.  The
    # directory remains a readable receipt; flock is the ownership primitive.
    fm_lock_flock_open "$lockdir"
    open_status=$?
    if [ "$open_status" -ne 0 ]; then
      [ "$open_status" -eq 2 ] && return 2
      # The owner takes the advisory lock immediately before publishing its
      # human-readable pid receipt.  Give that short handoff time to finish so
      # singleton callers can still identify the running owner.
      attempt=0
      while [ "$attempt" -lt 10 ]; do
        FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
        [ -n "$FM_LOCK_HELD_PID" ] && break
        sleep 0.01
        attempt=$((attempt + 1))
      done
      return 1
    fi
    if [ -e "$lockdir" ]; then
      pid=$(cat "$lockdir/pid" 2>/dev/null || true)
      if fm_pid_alive "$pid"; then
        FM_LOCK_HELD_PID=$pid
        fm_lock_flock_close "$lockdir"
        return 1
      fi
      case "$pid" in
        ''|*[!0-9]*)
          # This may be a pre-upgrade owner publishing its receipt.  The
          # advisory lock makes it safe to fail closed rather than steal it.
          fm_lock_flock_close "$lockdir"
          return 1
          ;;
      esac
      rm -f "$lockdir/pid" 2>/dev/null || { fm_lock_flock_close "$lockdir"; return 1; }
      rmdir "$lockdir" 2>/dev/null || { fm_lock_flock_close "$lockdir"; return 1; }
    fi
    if mkdir "$lockdir" 2>/dev/null && { fm_current_pid > "$lockdir/pid"; } 2>/dev/null; then
      return 0
    fi
    rm -f "$lockdir/pid" 2>/dev/null || true
    rmdir "$lockdir" 2>/dev/null || true
    fm_lock_flock_close "$lockdir"
    return 1
  fi

  # Without flock, a noclobber gate serializes both receipt publication and
  # inspection.  The gate is released only after the receipt directory is gone.
  if ( set -C; : > "$lockdir.guard" ) 2>/dev/null; then
    if [ -e "$lockdir" ]; then
      pid=$(cat "$lockdir/pid" 2>/dev/null || true)
      if fm_pid_alive "$pid"; then
        FM_LOCK_HELD_PID=$pid
        rm -f "$lockdir.guard" 2>/dev/null || true
        return 1
      fi
      case "$pid" in
        ''|*[!0-9]*)
          [ "$(fm_path_age "$lockdir")" -ge "$FM_LOCK_STALE_AFTER" ] || {
            FM_LOCK_HELD_PID=$pid
            rm -f "$lockdir.guard" 2>/dev/null || true
            return 1
          }
          ;;
      esac
      rm -f "$lockdir/pid" 2>/dev/null || { rm -f "$lockdir.guard" 2>/dev/null || true; return 1; }
      rmdir "$lockdir" 2>/dev/null || { rm -f "$lockdir.guard" 2>/dev/null || true; return 1; }
    fi
    if mkdir "$lockdir" 2>/dev/null && { fm_current_pid > "$lockdir/pid"; } 2>/dev/null; then
      return 0
    fi
    rm -f "$lockdir/pid" 2>/dev/null || true
    rmdir "$lockdir" 2>/dev/null || true
    rm -f "$lockdir.guard" 2>/dev/null || true
    return 1
  fi

  FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
  return 1
}

fm_lock_acquire_wait() {
  local lockdir=$1 status
  while :; do
    fm_lock_try_acquire "$lockdir"
    status=$?
    [ "$status" -eq 0 ] && return 0
    [ "$status" -eq 2 ] && return 2
    sleep 0.1
  done
}

fm_lock_release() {
  local lockdir=$1 pid current status=0
  current=${BASHPID:-$$}
  if [ "$FM_LOCK_USE_FLOCK" = 1 ] && { [ "$FM_LOCK_FLOCK_9" = "$lockdir" ] || [ "$FM_LOCK_FLOCK_8" = "$lockdir" ] || [ "$FM_LOCK_FLOCK_7" = "$lockdir" ] || [ "$FM_LOCK_FLOCK_6" = "$lockdir" ]; }; then
    pid=$(cat "$lockdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || status=1
    if [ "$status" -eq 0 ]; then
      rm -f "$lockdir/pid" 2>/dev/null || status=1
      rmdir "$lockdir" 2>/dev/null || status=1
    fi
    fm_lock_flock_close "$lockdir" || status=1
    return "$status"
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null) || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$pid" = "$current" ] || return 1
  rm -f "$lockdir/pid" 2>/dev/null || return 1
  rmdir "$lockdir" 2>/dev/null || return 1
  [ "$FM_LOCK_USE_FLOCK" != 1 ] && rm -f "$lockdir.guard" 2>/dev/null
}

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  local release_status
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  status=0

  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  if fm_lock_release "$FM_WAKE_QUEUE_LOCK"; then
    release_status=0
  else
    release_status=$?
  fi
  [ "$status" -ne 0 ] || status=$release_status
  return "$status"
}

fm_wake_restore_queue() {
  local drained=$1 restore
  restore="$STATE/.wake-queue.restore.$(fm_current_pid)"
  if [ -e "$FM_WAKE_QUEUE" ]; then
    cat "$drained" "$FM_WAKE_QUEUE" > "$restore" && mv "$restore" "$FM_WAKE_QUEUE"
  else
    mv "$drained" "$FM_WAKE_QUEUE"
  fi
}

fm_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}

# Print a locked, deduplicated copy of the durable wake queue without consuming
# it. The always-on supervisor uses this to reconcile wake state while leaving
# ownership of the real drain with Firstmate and the existing AFK flow.
fm_wake_peek() {
  local peek sequence_copy seq_file status release_status
  peek="$STATE/.wake-queue.peek.$(fm_current_pid)"
  sequence_copy=${1:-}
  seq_file="$STATE/.wake-queue.seq"
  status=0

  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if [ -s "$FM_WAKE_QUEUE" ]; then
    cat "$FM_WAKE_QUEUE" > "$peek" || status=$?
  else
    : > "$peek" || status=$?
  fi
  if [ "$status" -eq 0 ] && [ -n "$sequence_copy" ]; then
    if [ -e "$seq_file" ]; then
      cat "$seq_file" > "$sequence_copy" || status=$?
    else
      printf '0\n' > "$sequence_copy" || status=$?
    fi
  fi
  if fm_lock_release "$FM_WAKE_QUEUE_LOCK"; then
    release_status=0
  else
    release_status=$?
  fi
  [ "$status" -ne 0 ] || status=$release_status

  if [ "$status" -eq 0 ]; then
    fm_wake_print_deduped "$peek" || status=$?
  fi
  rm -f "$peek"
  if [ "$status" -ne 0 ] && [ -n "$sequence_copy" ]; then
    rm -f "$sequence_copy"
  fi
  return "$status"
}
