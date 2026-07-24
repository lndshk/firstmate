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
    "$SCRIPT_DIR/fm-tmux-lib.sh"; do
    printf '%s\t' "${runtime_file##*/}"
    cksum < "$runtime_file"
  done | cksum | awk '{ print $1 "-" $2 }'
)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
INTERVAL="${FM_SUPERVISOR_INTERVAL:-15}"
START_WAIT="${FM_SUPERVISOR_START_WAIT:-5}"
TASK_LOCK_WAIT="${FM_SUPERVISOR_TASK_LOCK_WAIT:-5}"
case "$INTERVAL" in ''|0|*[!0-9]*) INTERVAL=15 ;; esac
case "$START_WAIT" in ''|0|*[!0-9]*) START_WAIT=5 ;; esac
case "$TASK_LOCK_WAIT" in ''|*[!0-9]*) TASK_LOCK_WAIT=5 ;; esac
LOCK="$STATE/.firstmate-supervisor.lock"
CONTROL_LOCK="$STATE/.firstmate-supervisor.control.lock"
TASK_STATE_LOCK="$STATE/.firstmate-supervisor.state.lock"
PIDFILE="$STATE/.firstmate-supervisor.pid"
OWNER_RECEIPT="$STATE/.firstmate-supervisor.owner"
HEARTBEAT="$STATE/.firstmate-supervisor.heartbeat"
SNAPSHOT="${FM_SUPERVISOR_SNAPSHOT:-$STATE/firstmate-supervisor.tsv}"
ESCALATIONS="$STATE/.firstmate-supervisor.escalations"
LOG="$STATE/.firstmate-supervisor.log"
ERROR="$STATE/.firstmate-supervisor.error"

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
is_epoch() {
  is_uint "$1" && [ "${#1}" -le 10 ]
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
last_receipt_record() {
  awk 'NF { number=NR; line=$0 } END { printf "%d\t%s\n", number + 0, line }' "$1"
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

task_state_dir() {
  printf '%s/.firstmate-supervisor.task-%s' \
    "$STATE" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_')"
}

teardown_marker_path() {
  printf '%s/.firstmate-supervisor.teardown-%s' \
    "$STATE" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_')"
}

ensure_task_state_dir() {
  local dir
  dir=$(task_state_dir "$1") || return 1
  mkdir -p "$dir" && [ -d "$dir" ]
}

migrate_task_state_file() { # <id> <legacy-path> <name>; prints current path
  local id=$1 legacy=$2 name=$3 dir current
  dir=$(task_state_dir "$id") || return 1
  current="$dir/$name"
  if [ ! -e "$current" ] && [ ! -L "$current" ] \
    && { [ -e "$legacy" ] || [ -L "$legacy" ]; }; then
    [ -f "$legacy" ] || return 1
    ensure_task_state_dir "$id" || return 1
    mv -f "$legacy" "$current" || return 1
  fi
  printf '%s\n' "$current"
}

escalation_logged() { # <id> <condition> <token>
  local id=$1 condition=$2 token=$3
  if [ ! -e "$ESCALATIONS" ] && [ ! -L "$ESCALATIONS" ]; then
    return 1
  fi
  [ -f "$ESCALATIONS" ] || return 2
  awk -F '\t' -v id="$id" -v condition="$condition" -v token="$token" '
    $2 == id && $3 == condition && $5 == token { found=1; exit }
    END { exit !found }
  ' "$ESCALATIONS"
}

escalation_default_action() {
  case "$1" in
    missing-process) printf '%s\n' 'inspect or relaunch the recorded direct-report process' ;;
    missed-receipt-deadline) printf '%s\n' 'obtain the declared receipt or investigate the direct report' ;;
    failed-receipt) printf '%s\n' 'act on the previously observed failed terminal receipt' ;;
    invalid-receipt-deadline) printf '%s\n' 'replace the invalid receipt deadline with an absolute Unix epoch' ;;
    *) return 1 ;;
  esac
}

reconcile_escalation_marker() { # <marker> [id condition action]
  local marker=$1 fallback_id=${2:-} fallback_condition=${3:-} fallback_action=${4:-}
  local previous tab format event_epoch id condition action token evidence logged_status
  previous=$(read_optional_file "$marker") || return 1
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 0
  fi
  tab=$(printf '\t')
  case "$previous" in
    "v2$tab"*)
      IFS="$tab" read -r \
        format event_epoch id condition action token evidence <<EOF
$previous
EOF
      [ "$format" = v2 ] \
        && is_epoch "$event_epoch" \
        && [ -n "$id" ] \
        && [ -n "$condition" ] \
        && [ -n "$action" ] \
        && [ -n "$token" ] || return 1
      [ -z "$fallback_id" ] || [ "$id" = "$fallback_id" ] || return 1
      [ -z "$fallback_condition" ] \
        || [ "$condition" = "$fallback_condition" ] || return 1
      ;;
    "v1$tab"*)
      [ -n "$fallback_id" ] && [ -n "$fallback_condition" ] || return 0
      token=${previous#*"${tab}"}
      token=${token%%"$tab"*}
      [ -n "$token" ] || return 1
      event_epoch=$(now_epoch)
      id=$fallback_id
      condition=$fallback_condition
      action=$fallback_action
      if [ -z "$action" ]; then
        action=$(escalation_default_action "$condition") || return 1
      fi
      ;;
    *) return 0 ;;
  esac
  if escalation_logged "$id" "$condition" "$token"; then
    return 0
  else
    logged_status=$?
    [ "$logged_status" -eq 1 ] || return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$event_epoch" "$id" "$condition" "$action" "$token" >> "$ESCALATIONS"
}

reconcile_pending_escalations() {
  local marker
  for marker in "$STATE"/.firstmate-supervisor.task-*/escalated-*; do
    if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
      continue
    fi
    case "$marker" in
      *.tmp.*) rm -f "$marker" || return 1; continue ;;
    esac
    reconcile_escalation_marker "$marker" || return 1
  done
}

reconcile_task_escalations() { # <id>
  local id=$1 condition action marker legacy dir
  dir=$(task_state_dir "$id") || return 1
  for condition in \
    missing-process \
    missed-receipt-deadline \
    failed-receipt \
    invalid-receipt-deadline; do
    action=$(escalation_default_action "$condition") || return 1
    legacy="$STATE/.firstmate-supervisor.escalated-$(escalation_key "$id" "$condition")"
    marker=$(migrate_task_state_file \
      "$id" "$legacy" "escalated-$(escalation_key "$condition" condition)") || return 1
    reconcile_escalation_marker "$marker" "$id" "$condition" "$action" || return 1
  done
  for marker in "$dir"/escalated-*; do
    if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
      continue
    fi
    case "$marker" in
      *.tmp.*) rm -f "$marker" || return 1; continue ;;
    esac
    reconcile_escalation_marker "$marker" || return 1
  done
}

meta_generation() {
  local meta=$1 generation window worktree project home signature
  generation=$(meta_field "$meta" generation) || return 1
  if [ -n "$generation" ]; then
    generation=$(printf '%s' "$generation" | clean_field)
    printf 'generation:%s\n' "$generation"
    return
  fi
  window=$(meta_field "$meta" window) || return 1
  worktree=$(meta_field "$meta" worktree) || return 1
  project=$(meta_field "$meta" project) || return 1
  home=$(meta_field "$meta" home) || return 1
  signature=$(printf '%s\t%s\t%s\t%s' \
    "$window" "$worktree" "$project" "$home" \
    | cksum | awk '{ print $1 "-" $2 }') || return 1
  printf 'legacy:%s\n' "$signature"
}

task_teardown_excluded() { # <meta> <id>
  local meta=$1 id=$2 marker expected recorded
  marker=$(teardown_marker_path "$id") || return 2
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 1
  fi
  [ -f "$marker" ] || return 2
  expected=$(meta_generation "$meta") || return 2
  recorded=$(read_optional_file "$marker") || return 2
  [ "$recorded" = "$expected" ]
}

write_task_identity() {
  local id=$1 generation=$2 dir generation_tmp id_tmp
  dir=$(task_state_dir "$id") || return 1
  mkdir -p "$dir" || return 1
  generation_tmp="$dir/generation.tmp.$$"
  id_tmp="$dir/id.tmp.$$"
  if ! printf '%s\n' "$generation" > "$generation_tmp" \
    || ! printf '%s\n' "$id" > "$id_tmp" \
    || ! mv -f "$generation_tmp" "$dir/generation" \
    || ! mv -f "$id_tmp" "$dir/id"; then
    rm -f "$generation_tmp" "$id_tmp"
    return 1
  fi
}

ensure_task_generation() { # <meta> <id>
  local meta=$1 id=$2 dir generation saved_generation="" saved_id=""
  dir=$(task_state_dir "$id") || return 1
  generation=$(meta_generation "$meta") || return 1
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    saved_generation=$(read_optional_file "$dir/generation") || return 1
    saved_id=$(read_optional_file "$dir/id") || return 1
    if { [ -n "$saved_generation" ] \
      && [ "$saved_generation" != "$generation" ]; } \
      || { [ -n "$saved_id" ] && [ "$saved_id" != "$id" ]; }; then
      reconcile_task_escalations "$id" || return 1
      cleanup_task_state "$id" || return 1
      saved_generation=
      saved_id=
    fi
  fi
  if [ "$saved_generation" != "$generation" ] || [ "$saved_id" != "$id" ]; then
    write_task_identity "$id" "$generation" || return 1
  fi
}

garbage_collect_task_state() {
  local dir id meta
  for dir in "$STATE"/.firstmate-supervisor.task-*; do
    if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
      continue
    fi
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    id=$(read_optional_file "$dir/id") || return 1
    [ -n "$id" ] || id=${dir##*/.firstmate-supervisor.task-}
    case "$id" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
    meta="$STATE/$id.meta"
    if [ -e "$meta" ] || [ -L "$meta" ]; then
      [ -f "$meta" ] || return 1
      continue
    fi
    reconcile_task_escalations "$id" || return 1
    cleanup_task_state "$id" || return 1
  done
}

reconcile_teardown_markers() {
  local marker id meta expected recorded
  for marker in "$STATE"/.firstmate-supervisor.teardown-*; do
    if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
      continue
    fi
    [ -f "$marker" ] || return 1
    id=${marker##*/.firstmate-supervisor.teardown-}
    case "$id" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
    meta="$STATE/$id.meta"
    if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
      rm -f "$marker" || return 1
      continue
    fi
    [ -f "$meta" ] || return 1
    expected=$(meta_generation "$meta") || return 1
    recorded=$(read_optional_file "$marker") || return 1
    if [ "$recorded" != "$expected" ]; then
      rm -f "$marker" || return 1
    fi
  done
}

legacy_escalation_identity() { # <path>; prints <id><tab><condition>
  local path=$1 name condition id
  name=${path##*/.firstmate-supervisor.escalated-}
  for condition in \
    invalid-receipt-deadline \
    missed-receipt-deadline \
    missing-process \
    failed-receipt; do
    case "$name" in
      *-"$condition")
        id=${name%-"$condition"}
        [ -n "$id" ] || return 1
        printf '%s\t%s\n' "$id" "$condition"
        return 0
        ;;
    esac
  done
  return 1
}

reconcile_legacy_escalation() {
  local path=$1 previous identity id condition action epoch token logged_status tab
  previous=$(read_optional_file "$path") || return 1
  identity=$(legacy_escalation_identity "$path") || return 1
  IFS="$(printf '\t')" read -r id condition <<EOF
$identity
EOF
  action=$(escalation_default_action "$condition") || return 1
  tab=$(printf '\t')
  case "$previous" in
    "v2$tab"*)
      reconcile_escalation_marker "$path" "$id" "$condition" "$action" || return 1
      ;;
    "v1$tab"*)
      reconcile_escalation_marker "$path" "$id" "$condition" "$action" || return 1
      ;;
    *)
      epoch=$(fm_path_mtime "$path") || return 1
      is_epoch "$epoch" || return 1
      token=$(printf '%s\t%s\t%s' "$id" "$condition" "$previous" \
        | cksum | awk '{ print $1 "-" $2 }') || return 1
      if escalation_logged "$id" "$condition" "$token"; then
        :
      else
        logged_status=$?
        [ "$logged_status" -eq 1 ] || return 1
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$epoch" "$id" "$condition" "$action" "$token" >> "$ESCALATIONS" \
          || return 1
      fi
      ;;
  esac
}

garbage_collect_legacy_task_state() {
  local path
  for path in "$STATE"/.firstmate-supervisor.escalated-*; do
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
      continue
    fi
    [ -f "$path" ] || return 1
    reconcile_legacy_escalation "$path" || return 1
    rm -f "$path" || return 1
  done
  for path in \
    "$STATE"/.firstmate-supervisor.receipt-* \
    "$STATE"/.firstmate-supervisor.deadline-*; do
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
      continue
    fi
    [ -f "$path" ] || return 1
    rm -f "$path" || return 1
  done
}

write_teardown_marker() { # <meta> <id>
  local meta=$1 id=$2 marker generation tmp
  marker=$(teardown_marker_path "$id") || return 1
  generation=$(meta_generation "$meta") || return 1
  tmp="$marker.tmp.$$"
  if ! printf '%s\n' "$generation" > "$tmp" || ! mv -f "$tmp" "$marker"; then
    rm -f "$tmp"
    return 1
  fi
}

reconcile_legacy_retirement_record() { # <path> <root>
  local path=$1 root=$2 record format epoch id state condition action token
  local journal_condition logged_status meta
  [ -f "$path" ] || return 1
  record=$(read_optional_file "$path") || return 1
  IFS="$(printf '\t')" read -r \
    format epoch id state condition action token <<EOF
$record
EOF
  [ "$format" = v1 ] \
    && is_epoch "$epoch" \
    && [ -n "$id" ] \
    && [ "$path" = "$root/$id" ] \
    && [ -n "$token" ] || return 1
  case "$state" in
    pending) journal_condition=retirement-pending ;;
    failed)
      [ -n "$condition" ] && [ "$condition" != - ] || return 1
      journal_condition="retirement-$condition"
      ;;
    *) return 1 ;;
  esac
  [ -n "$action" ] && [ "$action" != - ] || return 1
  if escalation_logged "$id" "$journal_condition" "$token"; then
    :
  else
    logged_status=$?
    [ "$logged_status" -eq 1 ] || return 1
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$epoch" "$id" "$journal_condition" "$action" "$token" >> "$ESCALATIONS" \
      || return 1
  fi
  meta="$STATE/$id.meta"
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    [ -f "$meta" ] || return 1
    write_teardown_marker "$meta" "$id" || return 1
  fi
  rm -f "$path" || return 1
}

reconcile_legacy_retirements() {
  local root path
  for root in \
    "$STATE/.firstmate-supervisor.retirements" \
    "$STATE/.firstmate-supervisor.retirement-intents"; do
    if [ ! -e "$root" ] && [ ! -L "$root" ]; then
      continue
    fi
    [ -d "$root" ] && [ ! -L "$root" ] || return 1
    for path in "$root"/*; do
      if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        continue
      fi
      case "$path" in
        *.tmp.*) rm -f "$path" || return 1; continue ;;
      esac
      reconcile_legacy_retirement_record "$path" "$root" || return 1
    done
    rmdir "$root" 2>/dev/null || true
  done
}

escalate_once() { # <id> <condition> <action> [evidence]
  local id=$1 condition=$2 action=$3 marker legacy evidence="" previous tmp
  local tab format event_epoch saved_id saved_condition saved_action token saved_evidence
  local token_seed teardown_marker
  teardown_marker=$(teardown_marker_path "$id") || return 1
  if [ -e "$teardown_marker" ] || [ -L "$teardown_marker" ]; then
    [ -f "$teardown_marker" ] || return 1
    return 0
  fi
  legacy="$STATE/.firstmate-supervisor.escalated-$(escalation_key "$id" "$condition")"
  marker=$(migrate_task_state_file \
    "$id" "$legacy" "escalated-$(escalation_key "$condition" condition)") || return 1
  [ $# -lt 4 ] || evidence=$4
  id=$(printf '%s' "$id" | clean_field)
  condition=$(printf '%s' "$condition" | clean_field)
  action=$(printf '%s' "$action" | clean_field)
  evidence=$(printf '%s' "$evidence" | clean_field)
  previous=$(read_optional_file "$marker") || return 1
  tab=$(printf '\t')
  case "$previous" in
    "v2$tab"*)
      IFS="$tab" read -r \
        format event_epoch saved_id saved_condition saved_action token saved_evidence <<EOF
$previous
EOF
      [ "$format" = v2 ] \
        && is_epoch "$event_epoch" \
        && [ "$saved_id" = "$id" ] \
        && [ "$saved_condition" = "$condition" ] \
        && [ -n "$saved_action" ] \
        && [ -n "$token" ] || return 1
      reconcile_escalation_marker "$marker" "$id" "$condition" "$action" || return 1
      [ "$saved_evidence" != "$evidence" ] || return 0
      ;;
    "v1$tab"*)
      token=${previous#*"${tab}"}
      token=${token%%"$tab"*}
      saved_evidence=${previous#*"${tab}"}
      saved_evidence=${saved_evidence#*"${tab}"}
      [ -n "$token" ] || return 1
      reconcile_escalation_marker "$marker" "$id" "$condition" "$action" || return 1
      [ "$saved_evidence" != "$evidence" ] || return 0
      ;;
    *)
      if [ -e "$marker" ] || [ -L "$marker" ]; then
        [ -f "$marker" ] || return 1
        [ "$previous" != "$evidence" ] || return 0
      fi
      ;;
  esac
  ensure_task_state_dir "$id" || return 1
  event_epoch=$(now_epoch)
  token_seed="$event_epoch-$$-${RANDOM:-0}"
  token=$(printf '%s\t%s\t%s\t%s' \
    "$id" "$condition" "$evidence" "$token_seed" | cksum | awk '{ print $1 "-" $2 }')
  tmp="$marker.tmp.$$"
  if ! printf 'v2\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$event_epoch" "$id" "$condition" "$action" "$token" "$evidence" > "$tmp" \
    || ! mv -f "$tmp" "$marker"; then
    rm -f "$tmp"
    return 1
  fi
  reconcile_escalation_marker "$marker" "$id" "$condition" "$action"
}

clear_escalation() { # <id> <condition>
  local dir marker legacy action status=0
  dir=$(task_state_dir "$1") || return 1
  legacy="$STATE/.firstmate-supervisor.escalated-$(escalation_key "$1" "$2")"
  marker=$(migrate_task_state_file \
    "$1" "$legacy" "escalated-$(escalation_key "$2" condition)") || return 1
  action=$(escalation_default_action "$2") || return 1
  reconcile_escalation_marker "$marker" "$1" "$2" "$action" || return 1
  rm -f \
    "$legacy" \
    "$marker" || status=$?
  rmdir "$dir" 2>/dev/null || true
  return "$status"
}

receipt_evidence() { # <id> <status-file> <raw-receipt> <line>; prints <version><tab><time>
  local id=$1 receipt_file=$2 raw=$3 line=$4 receipt hash version observed cursor legacy
  local saved saved_version saved_time tmp
  receipt=$(fm_receipt_text "$raw")
  hash=$(printf '%s' "$receipt" | cksum | awk '{ print $1 "-" $2 }')
  version="$line-$hash"
  observed=$(fm_receipt_explicit_time "$raw" 2>/dev/null || true)
  if [ -z "$observed" ]; then
    observed=$(fm_path_mtime "$receipt_file") || return 1
  fi
  is_epoch "$observed" || return 1
  legacy="$STATE/.firstmate-supervisor.receipt-$(escalation_key "$id" receipt)"
  cursor=$(migrate_task_state_file "$id" "$legacy" receipt) || return 1
  saved=$(read_optional_file "$cursor") || return 1
  IFS="$(printf '\t')" read -r saved_version saved_time <<EOF
$saved
EOF
  if [ "$saved_version" = "$version" ] && is_epoch "$saved_time"; then
    observed=$saved_time
  fi
  if [ "$saved_version" != "$version" ] || ! is_epoch "$saved_time"; then
    ensure_task_state_dir "$id" || return 1
    tmp="$cursor.tmp.$$"
    printf '%s\t%s\n' "$version" "$observed" > "$tmp" \
      && mv -f "$tmp" "$cursor" || return 1
  fi
  printf '%s\t%s\n' "$version" "$observed"
}

clear_receipt_evidence() { # <id>
  local dir status=0
  dir=$(task_state_dir "$1") || return 1
  rm -f \
    "$STATE/.firstmate-supervisor.receipt-$(escalation_key "$1" receipt)" \
    "$dir/receipt" || status=$?
  rmdir "$dir" 2>/dev/null || true
  return "$status"
}

timestamped_deadline_satisfaction() { # <status-file> <deadline>; prints <version><tab><time>
  local receipt_file=$1 deadline=$2 candidate line raw receipt receipt_time hash tab
  if [ ! -e "$receipt_file" ] && [ ! -L "$receipt_file" ]; then
    return 1
  fi
  [ -f "$receipt_file" ] || return 2
  candidate=$(awk -F '\t' -v deadline="$deadline" '
    NF && $NF ~ /^[0-9]+$/ && length($NF) <= 10 && $NF <= deadline {
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

deadline_satisfaction() { # <id> <deadline> <status-file> <receipt-version> <receipt-time>; prints <version><tab><time>
  local id=$1 deadline=$2 receipt_file=$3 receipt_version=$4 receipt_time=$5 cursor legacy
  local saved saved_deadline saved_version saved_time candidate candidate_status tmp
  legacy="$STATE/.firstmate-supervisor.deadline-$(escalation_key "$id" receipt)"
  cursor=$(migrate_task_state_file "$id" "$legacy" deadline) || return 2
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
  candidate=$(timestamped_deadline_satisfaction "$receipt_file" "$deadline") \
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
    ensure_task_state_dir "$id" || return 2
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
  local dir status=0
  dir=$(task_state_dir "$1") || return 1
  rm -f \
    "$STATE/.firstmate-supervisor.deadline-$(escalation_key "$1" receipt)" \
    "$dir/deadline" || status=$?
  rmdir "$dir" 2>/dev/null || true
  return "$status"
}

classify_meta() { # <meta>; prints one TSV task row
  local meta=$1 id window pid deadline raw_deadline receipt receipt_raw receipt_record
  local receipt_line receipt_file now tab evidence
  local state reason process_condition="" deadline_condition="" receipt_condition=""
  local contract_condition=""
  local pane_activity=idle pid_activity=idle receipt_version="" receipt_time=""
  local deadline_status="" deadline_version="-" deadline_time="-"
  local deadline_action="" process_action="" receipt_action="" contract_action=""
  local satisfaction teardown_marker
  [ -f "$meta" ] || return 1
  id=$(basename "$meta" .meta)
  ensure_task_generation "$meta" "$id" || return 1
  window=$(meta_field "$meta" window) || return 1
  pid=$(meta_field "$meta" process-pid) || return 1
  if [ -z "$pid" ]; then
    pid=$(meta_field "$meta" pid) || return 1
  fi
  raw_deadline=$(meta_field "$meta" receipt-deadline) || return 1
  if [ -z "$raw_deadline" ]; then
    raw_deadline=$(meta_field "$meta" deadline) || return 1
  fi
  deadline=$raw_deadline
  if [ -n "$deadline" ] && ! is_epoch "$deadline"; then
    contract_condition=invalid-receipt-deadline
    deadline=
  fi
  receipt_file="$STATE/$id.status"
  if [ -e "$receipt_file" ] || [ -L "$receipt_file" ]; then
    [ -f "$receipt_file" ] || return 1
    receipt_record=$(last_receipt_record "$receipt_file") || return 1
    tab=$(printf '\t')
    receipt_line=${receipt_record%%"$tab"*}
    receipt_raw=${receipt_record#*"$tab"}
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
  else
    clear_receipt_evidence "$id" || return 1
  fi
  if is_epoch "$deadline"; then
    if satisfaction=$(deadline_satisfaction \
      "$id" "$deadline" "$receipt_file" "$receipt_version" "$receipt_time"); then
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
  else
    clear_deadline_satisfaction "$id" || return 1
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
    elif [ -n "$contract_condition" ]; then
      state=stalled
      reason="invalid receipt deadline declaration"
    else
      state=active-unverified
      reason="awaiting verifiable activity or receipt"
    fi
  fi

  teardown_marker=$(teardown_marker_path "$id") || return 1
  if [ -e "$teardown_marker" ] || [ -L "$teardown_marker" ]; then
    [ -f "$teardown_marker" ] || return 1
    return 0
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
  local tmp rows meta id excluded wake wake_count wake_last_seq status
  tmp="$SNAPSHOT.tmp.$$"
  rows="$tmp.rows"
  rm -f "$rows"
  for meta in "$STATE"/*.meta; do
    if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
      continue
    fi
    [ -f "$meta" ] || {
      rm -f "$tmp" "$rows"
      return 1
    }
    id=$(basename "$meta" .meta)
    if task_teardown_excluded "$meta" "$id"; then
      continue
    else
      excluded=$?
      if [ "$excluded" -ne 1 ]; then
        rm -f "$tmp" "$rows"
        return 1
      fi
    fi
    classify_meta "$meta" >> "$rows" || {
      rm -f "$tmp" "$rows"
      return 1
    }
  done
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

acquire_task_state_lock() {
  local attempts
  attempts=$((TASK_LOCK_WAIT * 10))
  while ! fm_lock_try_acquire "$TASK_STATE_LOCK"; do
    [ "$attempts" -gt 0 ] || return 1
    sleep 0.1
    attempts=$((attempts - 1))
  done
}

cleanup_task_state() { # <id>
  local id=$1 dir status=0
  dir=$(task_state_dir "$id") || return 1
  rm -rf "$dir" || status=$?
  rm -f \
    "$STATE/.firstmate-supervisor.receipt-$(escalation_key "$id" receipt)" \
    "$STATE/.firstmate-supervisor.deadline-$(escalation_key "$id" receipt)" \
    "$STATE/.firstmate-supervisor.escalated-$(escalation_key "$id" missing-process)" \
    "$STATE/.firstmate-supervisor.escalated-$(escalation_key "$id" missed-receipt-deadline)" \
    "$STATE/.firstmate-supervisor.escalated-$(escalation_key "$id" failed-receipt)" \
    "$STATE/.firstmate-supervisor.escalated-$(escalation_key "$id" invalid-receipt-deadline)" \
    || status=$?
  return "$status"
}

reconcile_task_state() {
  local meta id
  for meta in "$STATE"/*.meta; do
    if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
      continue
    fi
    [ -f "$meta" ] || return 1
    id=$(basename "$meta" .meta)
    ensure_task_generation "$meta" "$id" || return 1
  done
  garbage_collect_task_state || return 1
  reconcile_teardown_markers
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
  local previous_condition timestamp
  previous_condition=$(last_log_condition) || return 1
  [ "$previous_condition" != "$1" ] || return 0
  timestamp=$(now_epoch)
  printf '%s\t%s\n' "$timestamp" "$1" >> "$LOG" 2>/dev/null || return 1
  { printf '%s\t%s\n' "$timestamp" "$1" > "$ERROR"; } 2>/dev/null || true
}

clear_error_state() {
  rm -f "$ERROR"
}

record_recovery() {
  local previous_condition timestamp
  previous_condition=$(last_log_condition) || return 1
  case "$previous_condition" in
    *-failed)
      timestamp=$(now_epoch)
      printf '%s\trecovered\n' "$timestamp" >> "$LOG" 2>/dev/null || return 1
      ;;
  esac
}

error_state_is_clear() {
  local previous_condition
  if [ -e "$ERROR" ] || [ -L "$ERROR" ]; then
    return 1
  fi
  previous_condition=$(last_log_condition) || return 1
  case "$previous_condition" in
    *-failed) return 1 ;;
  esac
  return 0
}

cycle_locked() {
  mkdir -p "$STATE"
  if ! reconcile_legacy_retirements; then
    record_error task-state-reconcile-failed
    return 1
  fi
  if ! reconcile_task_state; then
    record_error task-state-reconcile-failed
    return 1
  fi
  if ! reconcile_pending_escalations; then
    record_error escalation-journal-failed
    return 1
  fi
  if ! write_snapshot; then
    record_error snapshot-write-failed
    return 1
  fi
  if ! garbage_collect_legacy_task_state; then
    record_error task-state-reconcile-failed
    return 1
  fi
  if ! FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" \
    FM_SUPERVISOR_SNAPSHOT="$SNAPSHOT" \
    "$SCRIPT_DIR/fm-board.sh" --once >/dev/null 2>&1; then
    record_error board-refresh-failed
    return 1
  fi
  return 0
}

cycle() {
  local status release_status
  mkdir -p "$STATE" || return 1
  if ! acquire_task_state_lock; then
    record_error task-state-lock-failed
    return 1
  fi
  cycle_locked
  status=$?
  fm_lock_release "$TASK_STATE_LOCK"
  release_status=$?
  if [ "$release_status" -ne 0 ]; then
    rm -f "$HEARTBEAT" 2>/dev/null || true
    record_error task-state-unlock-failed
    return 1
  fi
  [ "$status" -eq 0 ] || return "$status"
  if ! clear_error_state; then
    record_error error-clear-failed
    return 1
  fi
  if ! write_heartbeat; then
    record_error heartbeat-write-failed
    return 1
  fi
  if ! record_recovery; then
    record_error recovery-log-failed
    return 1
  fi
  return 0
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
  is_uint "$beat" && [ "$beat" -ge "$not_before" ] \
    && error_state_is_clear
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
  [ "$age" -ge 0 ] && [ "$age" -le "$max_age" ] \
    && error_state_is_clear
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
  owner_pid=$(meta_field "$OWNER_RECEIPT" pid 2>/dev/null || true)
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
  --once) cycle ;;
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
