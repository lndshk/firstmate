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
SCRIPT_REVISION=$(
  for runtime_file in \
    "$SCRIPT_DIR/fm-supervisor.sh" \
    "$SCRIPT_DIR/fm-wake-lib.sh" \
    "$SCRIPT_DIR/fm-tmux-lib.sh" \
    "$SCRIPT_DIR/fm-windows-scratch-sweep.sh" \
    "$SCRIPT_DIR/fm-windows-scratch-sweep.ps1"; do
    printf '%s\t' "${runtime_file##*/}"
    cksum < "$runtime_file"
  done | cksum | awk '{ print $1 "-" $2 }'
)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
INTERVAL="${FM_SUPERVISOR_INTERVAL:-15}"
START_WAIT="${FM_SUPERVISOR_START_WAIT:-5}"
case "$INTERVAL" in ''|0|*[!0-9]*) INTERVAL=15 ;; esac
case "$START_WAIT" in ''|0|*[!0-9]*) START_WAIT=5 ;; esac
TEARDOWN_GRACE=$((INTERVAL * 2 + 5))
LOCK="$STATE/.firstmate-supervisor.lock"
CONTROL_LOCK="$STATE/.firstmate-supervisor.control.lock"
PIDFILE="$STATE/.firstmate-supervisor.pid"
OWNER_RECEIPT="$STATE/.firstmate-supervisor.owner"
HEARTBEAT="$STATE/.firstmate-supervisor.heartbeat"
SNAPSHOT="${FM_SUPERVISOR_SNAPSHOT:-$STATE/firstmate-supervisor.tsv}"
ESCALATIONS="$STATE/.firstmate-supervisor.escalations"
LOG="$STATE/.firstmate-supervisor.log"
ERROR="$STATE/.firstmate-supervisor.error"
WINDOWS_SCRATCH_SWEEP_STAMP="$STATE/.windows-scratch-sweep.last"
WINDOWS_SCRATCH_SWEEP_INTERVAL="${FM_WINDOWS_SCRATCH_SWEEP_INTERVAL:-86400}"
CURRENT_TASK_DIR=
CURRENT_TASK_GENERATION=
CURRENT_STATUS_START_LINE=
CURRENT_STATUS_BOUNDARY_TRUSTED=

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-local-compat.sh
. "$SCRIPT_DIR/fm-local-compat.sh"

OWNER_STATE=$(cd "$STATE" 2>/dev/null && pwd -P) || {
  printf 'error: cannot resolve supervisor state directory: %s\n' "$STATE" >&2
  exit 1
}
OWNER_TOKEN=$(printf '%s' "$OWNER_STATE" | cksum | awk '{ print $1 "-" $2 }')

now_epoch() { date +%s; }
is_uint() {
  case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}
is_epoch() {
  is_uint "$1" && [ "${#1}" -le 10 ]
}

maybe_sweep_windows_scratch() {
  local now last tmp
  case "$WINDOWS_SCRATCH_SWEEP_INTERVAL" in ''|0|*[!0-9]*) return 0 ;; esac
  [ -x "$SCRIPT_DIR/fm-windows-scratch-sweep.sh" ] || return 0
  now=$(now_epoch)
  last=$(cat "$WINDOWS_SCRATCH_SWEEP_STAMP" 2>/dev/null || true)
  if is_uint "$last" && [ $((now - last)) -lt "$WINDOWS_SCRATCH_SWEEP_INTERVAL" ]; then
    return 0
  fi
  if ! "$SCRIPT_DIR/fm-windows-scratch-sweep.sh"; then
    return 1
  fi
  tmp="$WINDOWS_SCRATCH_SWEEP_STAMP.tmp.$$"
  if ! { printf '%s\n' "$now" > "$tmp" && mv -f "$tmp" "$WINDOWS_SCRATCH_SWEEP_STAMP"; }; then
    rm -f "$tmp"
    return 1
  fi
}
clean_field() { LC_ALL=C tr '\t\r\n' '   '; }
snapshot_field() {
  if [ -n "$1" ]; then printf '%s' "$1" | clean_field
  else printf -- '-'; fi
}
meta_field() {
  [ -f "$1" ] || return 1
  awk -v prefix="$2=" '
    index($0, prefix) == 1 {
      value=substr($0, length(prefix) + 1)
      found=1
    }
    END { if (found) print value }
  ' "$1"
}
single_meta_field() {
  [ -f "$1" ] || return 1
  awk -v prefix="$2=" '
    index($0, prefix) == 1 {
      value=substr($0, length(prefix) + 1)
      count++
    }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "$1"
}
meta_field_count() {
  [ -f "$1" ] || return 1
  awk -v prefix="$2=" 'index($0, prefix) == 1 { count++ } END { print count + 0 }' "$1"
}
last_receipt_record() {
  awk -v start="$2" 'NR > start && NF { number=NR; line=$0 } END { printf "%d\t%s\n", number + 0, line }' "$1"
}
read_optional_file() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    [ -f "$1" ] || return 1
    cat "$1"
  fi
}

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
  fm_pane_exists "$1"
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

supervisor_process_matches_revision() {
  local pid=$1 command
  fm_pid_alive "$pid" || return 1
  command=$(ps -ww -p "$pid" -o command= 2>/dev/null) || return 1
  case "$command" in
    *"fm-supervisor.sh"*"--run"*"--owner-token=$OWNER_TOKEN"*"--revision=$SCRIPT_REVISION"*) return 0 ;;
  esac
  return 1
}

supervisor_pid_is_ours() {
  local pid=$1 lock_pid
  fm_pid_alive "$pid" || return 1
  lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$pid" ] || return 1
  supervisor_process_matches_owner "$pid"
}

supervisor_pid_is_current() {
  local pid=$1 receipt_pid receipt_revision
  supervisor_pid_is_ours "$pid" || return 1
  receipt_pid=$(meta_field "$OWNER_RECEIPT" pid) || return 1
  receipt_revision=$(meta_field "$OWNER_RECEIPT" revision) || return 1
  [ "$receipt_pid" = "$pid" ] && [ "$receipt_revision" = "$SCRIPT_REVISION" ] \
    && supervisor_process_matches_revision "$pid"
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

task_generation() { # <meta>
  local generation clean
  generation=$(single_meta_field "$1" generation) || return 1
  [ -n "$generation" ] || return 1
  clean=$(printf '%s' "$generation" | clean_field)
  [ "$clean" = "$generation" ] || return 1
  printf '%s\n' "$generation"
}

task_state_dir() { # <id> <generation>
  local id=$1 generation=$2 key
  key=$(printf '%s\t%s' "$id" "$generation" | cksum | awk '{ print $1 "-" $2 }') \
    || return 1
  printf '%s/.firstmate-supervisor.task-%s-%s\n' \
    "$STATE" \
    "$(printf '%s' "$id" | tr -c 'A-Za-z0-9_.-' '_')" \
    "$key"
}

write_task_identity() { # <dir> <id> <generation>
  local dir=$1 id=$2 generation=$3 id_tmp generation_tmp
  id_tmp="$dir/id.tmp.$$"
  generation_tmp="$dir/generation.tmp.$$"
  if ! printf '%s\n' "$id" > "$id_tmp" \
    || ! printf '%s\n' "$generation" > "$generation_tmp" \
    || ! mv -f "$id_tmp" "$dir/id" \
    || ! mv -f "$generation_tmp" "$dir/generation"; then
    rm -f "$id_tmp" "$generation_tmp"
    return 1
  fi
}

repair_task_identity_from_meta() { # <dir>
  local dir=$1 meta id generation expected saved_id saved_generation
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in ''|*[!A-Za-z0-9_.-]*) continue ;; esac
    generation=$(task_generation "$meta" 2>/dev/null || true)
    [ -n "$generation" ] || continue
    expected=$(task_state_dir "$id" "$generation") || return 1
    [ "$expected" = "$dir" ] || continue
    saved_id=$(read_optional_file "$dir/id") || return 1
    saved_generation=$(read_optional_file "$dir/generation") || return 1
    [ -z "$saved_id" ] || [ "$saved_id" = "$id" ] || return 1
    [ -z "$saved_generation" ] || [ "$saved_generation" = "$generation" ] || return 1
    write_task_identity "$dir" "$id" "$generation"
    return
  done
  return 1
}

select_task_state() { # <meta> <id>
  local generation dir saved_id saved_generation
  generation=$(task_generation "$1") || return 1
  dir=$(task_state_dir "$2" "$generation") || return 1
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  else
    mkdir "$dir" || return 1
  fi
  saved_id=$(read_optional_file "$dir/id") || return 1
  saved_generation=$(read_optional_file "$dir/generation") || return 1
  if [ -n "$saved_id" ] && [ "$saved_id" != "$2" ]; then
    return 1
  fi
  if [ -n "$saved_generation" ] && [ "$saved_generation" != "$generation" ]; then
    return 1
  fi
  if [ "$saved_id" != "$2" ] || [ "$saved_generation" != "$generation" ]; then
    write_task_identity "$dir" "$2" "$generation" || return 1
  fi
  CURRENT_TASK_DIR=$dir
  CURRENT_TASK_GENERATION=$generation
}

select_status_boundary() { # <meta> <status-file>
  local meta=$1 receipt_file=$2 count declared saved desired start tmp
  count=$(meta_field_count "$meta" status-start-line) || return 1
  saved=$(read_optional_file "$CURRENT_TASK_DIR/status-start-line") || return 1
  if [ "$count" -eq 0 ]; then
    case "$saved" in
      legacy:*)
        start=${saved#legacy:}
        is_uint "$start" || return 1
        ;;
      '')
        if [ -e "$receipt_file" ] || [ -L "$receipt_file" ]; then
          [ -f "$receipt_file" ] || return 1
          start=$(awk 'END { print NR + 0 }' "$receipt_file") || return 1
        else
          start=0
        fi
        desired="legacy:$start"
        tmp="$CURRENT_TASK_DIR/status-start-line.tmp.$$"
        printf '%s\n' "$desired" > "$tmp" \
          && mv -f "$tmp" "$CURRENT_TASK_DIR/status-start-line" || return 1
        ;;
      *) return 1 ;;
    esac
    CURRENT_STATUS_BOUNDARY_TRUSTED=0
  elif [ "$count" -eq 1 ]; then
    declared=$(single_meta_field "$meta" status-start-line) || return 1
    is_uint "$declared" || return 1
    desired="meta:$declared"
    case "$saved" in
      "$desired") ;;
      "$declared"|'')
        tmp="$CURRENT_TASK_DIR/status-start-line.tmp.$$"
        printf '%s\n' "$desired" > "$tmp" \
          && mv -f "$tmp" "$CURRENT_TASK_DIR/status-start-line" || return 1
        ;;
      *) return 1 ;;
    esac
    start=$declared
    CURRENT_STATUS_BOUNDARY_TRUSTED=1
  else
    return 1
  fi
  CURRENT_STATUS_START_LINE=$start
}

legacy_deadline_trusted() { # <deadline> <now>
  local deadline=$1 now=$2 saved desired tmp
  saved=$(read_optional_file "$CURRENT_TASK_DIR/deadline-boundary") || return 2
  desired="meta:$deadline"
  case "$saved" in
    "$desired") return 0 ;;
    '')
      if [ "$deadline" -gt "$now" ]; then
        saved=$desired
      else
        saved=unverified
      fi
      tmp="$CURRENT_TASK_DIR/deadline-boundary.tmp.$$"
      printf '%s\n' "$saved" > "$tmp" \
        && mv -f "$tmp" "$CURRENT_TASK_DIR/deadline-boundary" || return 2
      [ "$saved" = "$desired" ]
      ;;
    *) return 1 ;;
  esac
}

cleanup_task_state_dir() { # <dir>
  local dir=$1 path
  case "$dir" in "$STATE"/.firstmate-supervisor.task-*) ;; *) return 1 ;; esac
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  for path in \
    "$dir/id" \
    "$dir/generation" \
    "$dir/status-start-line" \
    "$dir/deadline-boundary" \
    "$dir/receipt" \
    "$dir/deadline" \
    "$dir"/escalated-* \
    "$dir"/*.tmp.*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -f "$path" ] || [ -L "$path" ] || return 1
    rm -f "$path" || return 1
  done
  rmdir "$dir"
}

task_state_has_matching_meta() {
  local dir=$1 meta id generation expected
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in ''|*[!A-Za-z0-9_.-]*) continue ;; esac
    generation=$(task_generation "$meta" 2>/dev/null || true)
    [ -n "$generation" ] || continue
    expected=$(task_state_dir "$id" "$generation") || return 1
    [ "$expected" != "$dir" ] || return 0
  done
  return 1
}

garbage_collect_task_state() {
  local dir id generation meta
  for dir in "$STATE"/.firstmate-supervisor.task-*; do
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    id=$(read_optional_file "$dir/id") || return 1
    generation=$(read_optional_file "$dir/generation") || return 1
    case "$id" in
      ''|*[!A-Za-z0-9_.-]*)
        if repair_task_identity_from_meta "$dir"; then
          continue
        fi
        if task_state_has_matching_meta "$dir"; then
          continue
        fi
        cleanup_task_state_dir "$dir" || return 1
        continue
        ;;
    esac
    if [ -z "$generation" ]; then
      if repair_task_identity_from_meta "$dir"; then
        continue
      fi
      if task_state_has_matching_meta "$dir"; then
        continue
      fi
      cleanup_task_state_dir "$dir" || return 1
      continue
    fi
    meta="$STATE/$id.meta"
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || continue
    if task_state_has_matching_meta "$dir"; then
      continue
    fi
    cleanup_task_state_dir "$dir" || return 1
  done
}

teardown_marker_path() { # <id>
  case "$1" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  printf '%s/.firstmate-supervisor.teardown-%s\n' "$STATE" "$1"
}

process_identity() { # <pid>
  local pid=$1 started status
  is_uint "$pid" || return 1
  fm_pid_alive "$pid" || return 1
  status=$(LC_ALL=C ps -p "$pid" -o stat= 2>/dev/null) || return 1
  case "$status" in *Z*) return 1 ;; esac
  started=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  [ -n "$started" ] || return 1
  printf '%s' "$started" | cksum | awk '{ print $1 "-" $2 }'
}

escalate_once() { # <id> <condition> <action> [evidence]
  local id=$1 condition=$2 action=$3 marker evidence previous tmp
  [ -n "$CURRENT_TASK_DIR" ] || return 1
  marker="$CURRENT_TASK_DIR/escalated-$(escalation_key "$condition" condition)"
  if [ $# -lt 4 ]; then
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      [ -f "$marker" ] || return 1
      return 0
    fi
  else
    evidence=$4
    previous=$(read_optional_file "$marker") || return 1
    [ "$previous" = "$evidence" ] && return 0
  fi
  printf '%s\t%s\t%s\t%s\n' \
    "$(now_epoch)" \
    "$(printf '%s' "$id" | clean_field)" \
    "$(printf '%s' "$condition" | clean_field)" \
    "$(printf '%s' "$action" | clean_field)" >> "$ESCALATIONS" || return 1
  fm_wake_append \
    signal \
    "supervisor:$id" \
    "$condition: $action" || return 1
  if [ $# -lt 4 ]; then
    : > "$marker"
  else
    tmp="$marker.tmp.$$"
    printf '%s\n' "$evidence" > "$tmp" && mv -f "$tmp" "$marker"
  fi
}

clear_escalation() { # <id> <condition>
  [ -n "$CURRENT_TASK_DIR" ] || return 1
  rm -f "$CURRENT_TASK_DIR/escalated-$(escalation_key "$2" condition)"
}

clear_other_teardown_escalations() { # [current-condition]
  local current=${1:-} keep="" marker
  [ -n "$CURRENT_TASK_DIR" ] || return 1
  if [ -n "$current" ] && [ "$current" != - ]; then
    keep="$CURRENT_TASK_DIR/escalated-$(escalation_key "$current" condition)"
  fi
  for marker in "$CURRENT_TASK_DIR"/escalated-teardown-*; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    [ "$marker" != "$keep" ] || continue
    [ -f "$marker" ] || [ -L "$marker" ] || return 1
    rm -f "$marker" || return 1
  done
}

receipt_evidence() { # <id> <status-file> <raw-receipt> <line>; prints <version><tab><time>
  local id=$1 receipt_file=$2 raw=$3 line=$4 receipt hash version observed cursor
  local saved saved_version saved_time tmp
  receipt=$(fm_receipt_text "$raw")
  hash=$(printf '%s' "$receipt" | cksum | awk '{ print $1 "-" $2 }')
  version="$line-$hash"
  observed=$(fm_receipt_explicit_time "$raw" 2>/dev/null || true)
  if [ -z "$observed" ]; then
    observed=$(fm_path_mtime "$receipt_file") || return 1
  fi
  is_epoch "$observed" || return 1
  [ -n "$CURRENT_TASK_DIR" ] || return 1
  cursor="$CURRENT_TASK_DIR/receipt"
  saved=$(read_optional_file "$cursor") || return 1
  IFS="$(printf '\t')" read -r saved_version saved_time <<EOF
$saved
EOF
  if [ "$saved_version" = "$version" ] && is_epoch "$saved_time"; then
    observed=$saved_time
  fi
  if [ "$saved_version" != "$version" ] || ! is_epoch "$saved_time"; then
    tmp="$cursor.tmp.$$"
    printf '%s\t%s\n' "$version" "$observed" > "$tmp" \
      && mv -f "$tmp" "$cursor" || return 1
  fi
  printf '%s\t%s\n' "$version" "$observed"
}

clear_receipt_evidence() { # <id>
  [ -n "$CURRENT_TASK_DIR" ] || return 1
  rm -f "$CURRENT_TASK_DIR/receipt"
}

timestamped_deadline_satisfaction() { # <status-file> <deadline> <start-line>; prints <version><tab><time>
  local receipt_file=$1 deadline=$2 start_line=$3 candidate line raw receipt receipt_time hash tab
  if [ ! -e "$receipt_file" ] && [ ! -L "$receipt_file" ]; then
    return 1
  fi
  [ -f "$receipt_file" ] || return 2
  candidate=$(awk -F '\t' -v deadline="$deadline" -v start="$start_line" '
    NR > start && NF && $NF ~ /^[0-9]+$/ && length($NF) <= 10 && $NF <= deadline {
      text=$0
      sub(/\t[0-9]+$/, "", text)
      if (length(text) > 0) {
        print NR "\t" $0
        exit
      }
    }
  ' "$receipt_file") || return 2
  [ -n "$candidate" ] || return 1
  tab=$(printf '\t')
  line=${candidate%%"$tab"*}
  raw=${candidate#*"$tab"}
  receipt_time=$(fm_receipt_explicit_time "$raw") || return 1
  is_epoch "$receipt_time" || return 1
  receipt=$(fm_receipt_text "$raw")
  [ -n "$receipt" ] || return 1
  hash=$(printf '%s' "$receipt" | cksum | awk '{ print $1 "-" $2 }')
  printf '%s\t%s\n' "$line-$hash" "$receipt_time"
}

deadline_satisfaction() { # <id> <deadline> <status-file> <receipt-version> <receipt-time> <start-line>; prints <version><tab><time>
  local id=$1 deadline=$2 receipt_file=$3 receipt_version=$4 receipt_time=$5 start_line=$6 cursor
  local saved saved_deadline saved_version saved_time candidate candidate_status tmp
  [ -n "$CURRENT_TASK_DIR" ] || return 2
  cursor="$CURRENT_TASK_DIR/deadline"
  saved=$(read_optional_file "$cursor") || return 2
  IFS="$(printf '\t')" read -r saved_deadline saved_version saved_time <<EOF
$saved
EOF
  if [ "$saved_deadline" = "$deadline" ] \
    && [ -n "$saved_version" ] \
    && is_epoch "$saved_time"; then
    printf '%s\t%s\n' "$saved_version" "$saved_time"
    return 0
  fi
  candidate_status=0
  candidate=$(timestamped_deadline_satisfaction "$receipt_file" "$deadline" "$start_line") \
    || candidate_status=$?
  if [ "$candidate_status" -eq 2 ]; then
    return 2
  elif [ "$candidate_status" -eq 0 ] && [ -n "$candidate" ]; then
    IFS="$(printf '\t')" read -r receipt_version receipt_time <<EOF
$candidate
EOF
  fi
  if [ -n "$receipt_version" ] \
    && is_epoch "$receipt_time" \
    && [ "$receipt_time" -le "$deadline" ]; then
    tmp="$cursor.tmp.$$"
    printf '%s\t%s\t%s\n' "$deadline" "$receipt_version" "$receipt_time" > "$tmp" \
      && mv -f "$tmp" "$cursor" || return 2
    printf '%s\t%s\n' "$receipt_version" "$receipt_time"
    return 0
  fi
  [ "$saved_deadline" = "$deadline" ] || rm -f "$cursor" || return 2
  return 1
}

clear_deadline_satisfaction() { # <id>
  [ -n "$CURRENT_TASK_DIR" ] || return 1
  rm -f "$CURRENT_TASK_DIR/deadline"
}

validated_teardown_record() { # <marker>
  local marker=$1 record format generation owner_pid owner_identity progress
  local marker_state marker_condition identity_checksum identity_size tab extra
  record=$(awk -F '\t' '
    NR == 1 && NF == 7 { record=$0; next }
    { invalid=1 }
    END {
      if (NR != 1 || invalid) exit 1
      print record
    }
  ' "$marker") || return 1
  tab=$(printf '\t')
  IFS="$tab" read -r \
    format generation owner_pid owner_identity progress marker_state marker_condition extra <<EOF
$record
EOF
  [ "$format" = v1 ] || return 1
  case "$generation" in generation:?*) ;; *) return 1 ;; esac
  is_uint "$owner_pid" || return 1
  case "$owner_identity" in
    *-*)
      identity_checksum=${owner_identity%-*}
      identity_size=${owner_identity#*-}
      ;;
    *) return 1 ;;
  esac
  is_uint "$identity_checksum" && is_uint "$identity_size" || return 1
  is_epoch "$progress" || return 1
  case "$marker_condition" in
    ''|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  case "$marker_state" in
    active|complete) [ "$marker_condition" = - ] || return 1 ;;
    failed) [ "$marker_condition" != - ] || return 1 ;;
    *) return 1 ;;
  esac
  [ -z "$extra" ] || return 1
  printf '%s\n' "$record"
}

matching_teardown_state() { # <meta> <id>; prints <state><tab><reason><tab><condition><tab><action>
  local id=$2 marker record format generation owner_pid owner_identity
  local progress marker_state marker_condition current_identity age tab action
  marker=$(teardown_marker_path "$id") || return 1
  [ -e "$marker" ] || [ -L "$marker" ] || return 1
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  record=$(validated_teardown_record "$marker") || return 1
  tab=$(printf '\t')
  IFS="$tab" read -r \
    format generation owner_pid owner_identity progress marker_state marker_condition <<EOF
$record
EOF
  [ "$generation" = "generation:$CURRENT_TASK_GENERATION" ] || return 1
  age=$(( $(now_epoch) - progress ))
  [ "$age" -ge 0 ] || age=0
  case "$marker_state" in
    active)
      current_identity=$(process_identity "$owner_pid" 2>/dev/null || true)
      if [ -n "$current_identity" ] && [ "$current_identity" = "$owner_identity" ]; then
        printf 'active\tteardown owner is live\t-\t-\n'
      else
        action="inspect the recorded teardown owner and task resources"
        printf 'stalled\tteardown owner is missing\tteardown-owner-missing\t%s\n' "$action"
      fi
      ;;
    complete)
      if [ "$age" -le "$TEARDOWN_GRACE" ]; then
        printf 'active-unverified\tteardown completion is awaiting metadata removal\t-\t-\n'
      else
        action="inspect why completed teardown metadata remains"
        printf 'stalled\tteardown completed but metadata remains\tteardown-incomplete\t%s\n' "$action"
      fi
      ;;
    failed)
      action="inspect the recorded teardown failure before retrying cleanup"
      [ "$marker_condition" != - ] || marker_condition=failed
      printf 'stalled\tteardown reported failure\tteardown-%s\t%s\n' \
        "$marker_condition" "$action"
      ;;
  esac
}

select_orphan_task_state() {
  local id=$1 generation=$2 dir saved_id="" saved_generation=""
  dir=$(task_state_dir "$id" "$generation") || return 1
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    if [ -e "$dir/id" ] || [ -L "$dir/id" ]; then
      [ -f "$dir/id" ] && [ ! -L "$dir/id" ] || return 1
      saved_id=$(cat "$dir/id") || return 1
    fi
    if [ -e "$dir/generation" ] || [ -L "$dir/generation" ]; then
      [ -f "$dir/generation" ] && [ ! -L "$dir/generation" ] || return 1
      saved_generation=$(cat "$dir/generation") || return 1
    fi
    [ -z "$saved_id" ] || [ "$saved_id" = "$id" ] || return 1
    [ -z "$saved_generation" ] || [ "$saved_generation" = "$generation" ] || return 1
    if [ "$saved_id" != "$id" ] || [ "$saved_generation" != "$generation" ]; then
      write_task_identity "$dir" "$id" "$generation" || return 1
    fi
  else
    mkdir "$dir" || return 1
    write_task_identity "$dir" "$id" "$generation" || return 1
  fi
  CURRENT_TASK_DIR=$dir
  CURRENT_TASK_GENERATION=$generation
}

reconcile_orphan_teardown_markers() {
  local marker id record format generation owner_pid owner_identity progress
  local marker_state marker_condition meta current current_identity tab action
  for marker in "$STATE"/.firstmate-supervisor.teardown-*; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    case "$marker" in *.tmp.*) continue ;; esac
    [ -f "$marker" ] && [ ! -L "$marker" ] || continue
    id=${marker##*/.firstmate-supervisor.teardown-}
    case "$id" in ''|*[!A-Za-z0-9_.-]*) continue ;; esac
    record=$(validated_teardown_record "$marker") || continue
    tab=$(printf '\t')
    IFS="$tab" read -r \
      format generation owner_pid owner_identity progress marker_state marker_condition <<EOF
$record
EOF
    meta="$STATE/$id.meta"
    if [ -f "$meta" ]; then
      current=$(task_generation "$meta" 2>/dev/null || true)
      [ "generation:$current" != "$generation" ] || continue
      # Same-id evidence from another generation is intentionally quarantined.
      continue
    fi
    case "$marker_state" in
      complete)
        rm -f "$marker" || return 1
        ;;
      active)
        current_identity=$(process_identity "$owner_pid" 2>/dev/null || true)
        if [ -n "$current_identity" ] && [ "$current_identity" = "$owner_identity" ]; then
          continue
        fi
        select_orphan_task_state "$id" "${generation#generation:}" || return 1
        action="inspect resources left by the exited teardown owner"
        escalate_once "$id" teardown-owner-missing "$action" "$generation" || return 1
        printf 'escalation\t%s\tteardown-owner-missing\t%s\n' \
          "$(snapshot_field "$id")" "$(snapshot_field "$action")"
        rm -f "$marker" || return 1
        ;;
      failed)
        select_orphan_task_state "$id" "${generation#generation:}" || return 1
        action="inspect resources left by the failed teardown"
        escalate_once "$id" teardown-failed "$action" "$generation" || return 1
        printf 'escalation\t%s\tteardown-failed\t%s\n' \
          "$(snapshot_field "$id")" "$(snapshot_field "$action")"
        rm -f "$marker" || return 1
        ;;
    esac
  done
}

classify_meta() { # <meta>; prints one TSV task row
  local meta=$1 id window pid deadline raw_deadline receipt receipt_raw receipt_record
  local receipt_line receipt_file now tab evidence
  local state reason process_condition="" deadline_condition="" receipt_condition=""
  local contract_condition=""
  local teardown_result teardown_status teardown_state teardown_reason
  local teardown_condition teardown_action
  local boundary_status=0 deadline_boundary_status=0
  local pane_activity=idle pid_activity=idle receipt_version="" receipt_time=""
  local deadline_status="" deadline_version="-" deadline_time="-"
  local deadline_action="" process_action="" receipt_action="" contract_action=""
  local satisfaction
  id=$(basename "$meta" .meta)
  CURRENT_TASK_DIR=
  CURRENT_TASK_GENERATION=
  CURRENT_STATUS_START_LINE=
  CURRENT_STATUS_BOUNDARY_TRUSTED=
  if ! select_task_state "$meta" "$id"; then
    printf 'task\t%s\tactive-unverified\t%s\t-\t-\t-\t-\n' \
      "$(snapshot_field "$id")" \
      "$(snapshot_field "explicit task generation is missing or invalid")"
    printf 'escalation\t%s\tunverified-task-generation\t%s\n' \
      "$(snapshot_field "$id")" \
      "$(snapshot_field "verify task identity before relying on legacy evidence")"
    return 0
  fi
  window=$(meta_field "$meta" window) || return 1
  pid=$(meta_field "$meta" process-pid) || return 1
  [ -n "$pid" ] || pid=$(meta_field "$meta" pid) || return 1
  raw_deadline=$(meta_field "$meta" receipt-deadline) || return 1
  [ -n "$raw_deadline" ] || raw_deadline=$(meta_field "$meta" deadline) || return 1
  deadline=$raw_deadline
  if [ -n "$deadline" ] && ! is_epoch "$deadline"; then
    contract_condition=invalid-receipt-deadline
    deadline=
  fi
  receipt_file="$STATE/$id.status"
  if [ -e "$receipt_file" ] || [ -L "$receipt_file" ]; then
    [ -f "$receipt_file" ] || return 1
  fi
  select_status_boundary "$meta" "$receipt_file" || boundary_status=$?
  if [ "$boundary_status" -eq 0 ] \
    && { [ -e "$receipt_file" ] || [ -L "$receipt_file" ]; }; then
    receipt_record=$(last_receipt_record "$receipt_file" "$CURRENT_STATUS_START_LINE") || return 1
    tab=$(printf '\t')
    receipt_line=${receipt_record%%"$tab"*}
    receipt_raw=${receipt_record#*"$tab"}
  elif [ "$boundary_status" -eq 0 ]; then
    receipt_line=0
    receipt_raw=
  else
    receipt_line=0
    receipt_raw=
  fi
  receipt=$(fm_receipt_text "$receipt_raw")
  now=$(now_epoch)

  if [ -n "$receipt" ]; then
    evidence=$(receipt_evidence \
      "$id" "$receipt_file" "$receipt_raw" "$receipt_line") || return 1
    IFS="$(printf '\t')" read -r receipt_version receipt_time <<EOF
$evidence
EOF
  elif [ "$boundary_status" -eq 0 ]; then
    clear_receipt_evidence "$id" || return 1
  fi
  if is_epoch "$deadline"; then
    if [ "$boundary_status" -ne 0 ]; then
      deadline_boundary_status=1
    elif [ "$CURRENT_STATUS_BOUNDARY_TRUSTED" != 1 ]; then
      legacy_deadline_trusted "$deadline" "$now" \
        || deadline_boundary_status=$?
    fi
    if [ "$deadline_boundary_status" -eq 2 ]; then
      return 1
    elif [ "$deadline_boundary_status" -ne 0 ]; then
      deadline_status=unverified
    elif satisfaction=$(deadline_satisfaction \
      "$id" "$deadline" "$receipt_file" "$receipt_version" "$receipt_time" \
      "$CURRENT_STATUS_START_LINE"); then
      deadline_status=satisfied
      IFS="$(printf '\t')" read -r deadline_version deadline_time <<EOF
$satisfaction
EOF
    elif [ "$?" -eq 2 ]; then
      return 1
    elif [ "$deadline" -le "$now" ]; then
      deadline_status=missed
      deadline_condition=missed-receipt-deadline
    else
      deadline_status=pending
    fi
  elif [ "$boundary_status" -eq 0 ]; then
    clear_deadline_satisfaction "$id" || return 1
  fi

  teardown_status=0
  teardown_result=$(matching_teardown_state "$meta" "$id") || teardown_status=$?
  if [ "$teardown_status" -eq 2 ]; then
    return 1
  elif [ "$teardown_status" -eq 0 ]; then
    IFS="$(printf '\t')" read -r \
      teardown_state teardown_reason teardown_condition teardown_action <<EOF
$teardown_result
EOF
    if [ "$teardown_condition" != - ]; then
      escalate_once \
        "$id" "$teardown_condition" "$teardown_action" "$teardown_result" || return 1
    fi
  fi

  if terminal_receipt "$receipt"; then
    state=terminal
    reason="terminal receipt recorded"
    if failed_receipt "$receipt"; then
      receipt_condition=failed-receipt
    fi
  else
    if [ "$teardown_status" -eq 0 ]; then
      state=$teardown_state
      reason=$teardown_reason
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
    elif [ -n "$contract_condition" ]; then
      state=stalled
      reason="invalid receipt deadline declaration"
    else
      state=active-unverified
      reason="awaiting verifiable activity or receipt"
    fi
    fi
  fi

  if [ -n "$process_condition" ]; then
    process_action="inspect or relaunch the recorded direct-report process"
    escalate_once "$id" "$process_condition" "$process_action" || return 1
  else
    clear_escalation "$id" missing-process || return 1
  fi
  if [ -n "$deadline_condition" ]; then
    deadline_action="obtain the declared receipt or investigate the direct report"
    escalate_once "$id" "$deadline_condition" "$deadline_action" || return 1
  else
    clear_escalation "$id" missed-receipt-deadline || return 1
  fi
  if [ -n "$receipt_condition" ]; then
    receipt_action="act on terminal receipt: $receipt"
    escalate_once "$id" "$receipt_condition" "$receipt_action" "$receipt_version" || return 1
  else
    clear_escalation "$id" failed-receipt || return 1
  fi
  if [ -n "$contract_condition" ]; then
    contract_action="replace the invalid receipt deadline with an absolute Unix epoch"
    escalate_once \
      "$id" "$contract_condition" "$contract_action" "$raw_deadline" || return 1
  else
    clear_escalation "$id" invalid-receipt-deadline || return 1
  fi
  clear_other_teardown_escalations "${teardown_condition:-}" || return 1

  printf 'task\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(snapshot_field "$id")" \
    "$state" \
    "$(snapshot_field "$reason")" \
    "$(snapshot_field "$receipt")" \
    "$(snapshot_field "$deadline")" \
    "$(snapshot_field "$window")" \
    "$(snapshot_field "$pid")"
  if is_epoch "$deadline"; then
    printf 'contract\t%s\tany-receipt\t%s\t%s\t%s\t%s\n' \
      "$(snapshot_field "$id")" \
      "$deadline" \
      "$deadline_status" \
      "$deadline_version" \
      "$deadline_time"
  fi
  if [ -n "$process_condition" ]; then
    printf 'escalation\t%s\t%s\t%s\n' \
      "$(snapshot_field "$id")" \
      "$process_condition" \
      "$(snapshot_field "$process_action")"
  fi
  if [ -n "$deadline_condition" ]; then
    printf 'escalation\t%s\t%s\t%s\n' \
      "$(snapshot_field "$id")" \
      "$deadline_condition" \
      "$(snapshot_field "$deadline_action")"
  fi
  if [ -n "$receipt_condition" ]; then
    printf 'escalation\t%s\t%s\t%s\n' \
      "$(snapshot_field "$id")" \
      "$receipt_condition" \
      "$(snapshot_field "$receipt_action")"
  fi
  if [ -n "$contract_condition" ]; then
    printf 'escalation\t%s\t%s\t%s\n' \
      "$(snapshot_field "$id")" \
      "$contract_condition" \
      "$(snapshot_field "$contract_action")"
  fi
  if [ -n "${teardown_condition:-}" ] && [ "$teardown_condition" != - ]; then
    printf 'escalation\t%s\t%s\t%s\n' \
      "$(snapshot_field "$id")" \
      "$teardown_condition" \
      "$(snapshot_field "$teardown_action")"
  fi
}

wake_snapshot() { # prints: <count><tab><last-seq>
  local wakes count queue_last_seq durable_last_seq sequence_copy
  sequence_copy="$STATE/.wake-queue.seq.peek.$(fm_current_pid)"
  wakes=$(fm_wake_peek "$sequence_copy" 2>/dev/null) || {
    rm -f "$sequence_copy"
    return 1
  }
  durable_last_seq=$(cat "$sequence_copy" 2>/dev/null) || {
    rm -f "$sequence_copy"
    return 1
  }
  rm -f "$sequence_copy"
  is_uint "$durable_last_seq" || return 1
  count=$(printf '%s\n' "$wakes" | awk 'NF { n++ } END { print n + 0 }') || return 1
  queue_last_seq=$(printf '%s\n' "$wakes" | awk -F '\t' 'NF >= 2 && $2 ~ /^[0-9]+$/ && $2 > max { max=$2 } END { print max + 0 }') || return 1
  [ "$queue_last_seq" -le "$durable_last_seq" ] || durable_last_seq=$queue_last_seq
  printf '%s\t%s\n' "$count" "$durable_last_seq"
}

write_snapshot() {
  local tmp rows meta wake wake_count wake_last_seq status
  tmp="$SNAPSHOT.tmp.$$"
  rows="$tmp.rows"
  rm -f "$rows"
  reconcile_orphan_teardown_markers >> "$rows" || {
    rm -f "$tmp" "$rows"
    return 1
  }
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    classify_meta "$meta" >> "$rows" || {
      rm -f "$tmp" "$rows"
      return 1
    }
  done
  garbage_collect_task_state || {
    rm -f "$tmp" "$rows"
    return 1
  }
  wake=$(wake_snapshot) || {
    rm -f "$tmp" "$rows"
    return 1
  }
  IFS="$(printf '\t')" read -r wake_count wake_last_seq <<EOF
$wake
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
  if ! printf '%s\n' "$(now_epoch)" > "$tmp" \
    || ! mv -f "$tmp" "$HEARTBEAT"; then
    rm -f "$tmp"
    return 1
  fi
}

last_log_condition() {
  local previous="" tab
  if [ -e "$LOG" ] || [ -L "$LOG" ]; then
    [ -f "$LOG" ] || return 1
    previous=$(tail -n 1 "$LOG" 2>/dev/null) || return 1
  fi
  tab=$(printf '\t')
  case "$previous" in
    *"$tab"*) printf '%s\n' "${previous#*"$tab"}" ;;
  esac
}

record_error() {
  local previous timestamp
  previous=$(last_log_condition) || return 1
  [ "$previous" != "$1" ] || return 0
  timestamp=$(now_epoch)
  printf '%s\t%s\n' "$timestamp" "$1" >> "$LOG" 2>/dev/null || return 1
  { printf '%s\t%s\n' "$timestamp" "$1" > "$ERROR"; } 2>/dev/null || true
}

record_recovery() {
  local previous timestamp
  previous=$(last_log_condition) || return 1
  case "$previous" in
    *-failed)
      timestamp=$(now_epoch)
      printf '%s\trecovered\n' "$timestamp" >> "$LOG" 2>/dev/null || return 1
      ;;
  esac
}

cycle_failed() {
  rm -f "$HEARTBEAT" 2>/dev/null || true
  record_error "$1" || true
  return 1
}

cycle() {
  mkdir -p "$STATE" || return 1
  maybe_sweep_windows_scratch || true
  if ! write_snapshot; then
    cycle_failed snapshot-write-failed
    return
  fi
  if ! FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" \
    FM_SUPERVISOR_SNAPSHOT="$SNAPSHOT" \
    "$SCRIPT_DIR/fm-board.sh" --once >/dev/null 2>&1; then
    cycle_failed board-refresh-failed
    return
  fi
  if ! rm -f "$ERROR"; then
    cycle_failed error-clear-failed
    return
  fi
  if ! write_heartbeat; then
    cycle_failed heartbeat-write-failed
    return
  fi
  if ! record_recovery; then
    cycle_failed recovery-log-failed
    return
  fi
}

run_once() {
  local rc
  mkdir -p "$STATE" || return 1
  if ! fm_lock_try_acquire "$CONTROL_LOCK"; then
    printf 'supervisor control operation already in progress%s\n' \
      "${FM_LOCK_HELD_PID:+ (pid $FM_LOCK_HELD_PID)}" >&2
    return 1
  fi
  trap 'fm_lock_release "$LOCK"; fm_lock_release "$CONTROL_LOCK"' EXIT
  if ! fm_lock_try_acquire "$LOCK"; then
    printf 'error: refusing --once while the supervisor owner is running%s\n' \
      "${FM_LOCK_HELD_PID:+ (pid $FM_LOCK_HELD_PID)}" >&2
    fm_lock_release "$CONTROL_LOCK"
    trap - EXIT
    return 1
  fi
  cycle
  rc=$?
  fm_lock_release "$LOCK"
  fm_lock_release "$CONTROL_LOCK"
  trap - EXIT
  return "$rc"
}

run_loop() {
  local owner_tmp
  mkdir -p "$STATE"
  if ! fm_lock_try_acquire "$LOCK"; then
    printf 'supervisor already running%s\n' "${FM_LOCK_HELD_PID:+ (pid $FM_LOCK_HELD_PID)}" >&2
    return 1
  fi
  owner_tmp="$OWNER_RECEIPT.tmp.$$"
  if ! {
    printf 'pid=%s\n' "$$"
    printf 'interval=%s\n' "$INTERVAL"
    printf 'revision=%s\n' "$SCRIPT_REVISION"
  } > "$owner_tmp" || ! mv -f "$owner_tmp" "$OWNER_RECEIPT"; then
    fm_lock_release "$LOCK"
    return 1
  fi
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
  local status=$1 child_pid
  trap - INT TERM EXIT
  while IFS= read -r child_pid; do
    [ -n "$child_pid" ] || continue
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  done <<EOF
$(jobs -p)
EOF
  rm -f "$PIDFILE" "$OWNER_RECEIPT"
  fm_lock_release "$LOCK"
  exit "$status"
}

sleep_interval() {
  sleep "$INTERVAL" &
  wait 2>/dev/null || true
}

heartbeat_is_ready() { # <not-before-epoch>
  local not_before=$1 beat
  beat=$(cat "$HEARTBEAT" 2>/dev/null || true)
  is_uint "$beat" && [ "$beat" -ge "$not_before" ]
}

owner_interval() { # <pid>
  local pid=$1 receipt_pid receipt_interval
  receipt_pid=$(meta_field "$OWNER_RECEIPT" pid) || return 1
  receipt_interval=$(meta_field "$OWNER_RECEIPT" interval) || return 1
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
    if supervisor_pid_is_current "$pid" && heartbeat_is_ready "$not_before"; then
      printf 'supervisor running: pid %s\n' "$pid"
      return 0
    fi
    fm_pid_alive "$child" || break
    sleep 1
    waited=$((waited + 1))
  done
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if supervisor_pid_is_current "$pid" && heartbeat_is_ready "$not_before"; then
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
    if ! supervisor_pid_is_current "$pid"; then
      if ! stop_failed_child "$pid"; then
        printf 'error: outdated supervisor pid %s could not be replaced safely\n' "$pid" >&2
        return 1
      fi
      pid=
    fi
  fi
  if [ -n "$pid" ] && supervisor_pid_is_current "$pid"; then
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
  nohup "$SCRIPT_DIR/fm-supervisor.sh" --run "--owner-token=$OWNER_TOKEN" \
    "--revision=$SCRIPT_REVISION" >> "$LOG" 2>&1 &
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
  local pid beat beat_age snapshot_age error state rc
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  beat=$(cat "$HEARTBEAT" 2>/dev/null || true)
  beat_age=$(fm_path_age "$HEARTBEAT")
  snapshot_age=$(fm_path_age "$SNAPSHOT")
  error=$(cat "$ERROR" 2>/dev/null || true)
  if supervisor_pid_is_ours "$pid"; then
    if ! supervisor_pid_is_current "$pid"; then
      state=outdated
      rc=1
    elif heartbeat_is_healthy "$pid"; then
      state=running
      rc=0
    else
      state=unhealthy
      rc=1
    fi
    printf 'state=%s pid=%s heartbeat=%s heartbeat-age=%s snapshot-age=%s' \
      "$state" \
      "$pid" "${beat:-missing}" "$beat_age" "$snapshot_age"
    [ -z "$error" ] || printf ' error=%s' "$(printf '%s' "$error" | clean_field)"
    printf '\n'
    return "$rc"
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
  --once) run_once ;;
  --run)
    [ "${2:-}" = "--owner-token=$OWNER_TOKEN" ] || {
      printf 'error: supervisor owner token does not match this home\n' >&2
      exit 2
    }
    [ "${3:-}" = "--revision=$SCRIPT_REVISION" ] || {
      printf 'error: supervisor revision does not match this script\n' >&2
      exit 2
    }
    run_loop
    ;;
  *) printf 'usage: %s start|restart|status\n' "$0" >&2; exit 2 ;;
esac
