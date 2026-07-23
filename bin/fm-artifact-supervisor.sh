#!/usr/bin/env bash
# Usage: fm-artifact-supervisor.sh [start|restart|status|ack ACTION|--once|--loop]
# Deterministic task-contract evaluator and normal-mode action router.  It does
# not execute repair commands, write to tmux, or inject chat; those boundaries
# deliberately remain outside this service.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
INTERVAL="${FM_ARTIFACT_SUPERVISOR_INTERVAL:-15}"
LOCK="$STATE/.artifact-supervisor.lock"; PIDFILE="$STATE/.artifact-supervisor.pid"
HEARTBEAT="$STATE/.artifact-supervisor.heartbeat"; SNAPSHOT="$STATE/artifact-supervisor.tsv"
LOG="$STATE/.artifact-supervisor.log"; ERROR="$STATE/.artifact-supervisor.error"
EVENTS="$STATE/.artifact-supervisor.events"; ACTIONS="$STATE/.artifact-supervisor.actions"
MACHINE="$STATE/.artifact-supervisor.state"

. "$SCRIPT_DIR/fm-wake-lib.sh"
. "$SCRIPT_DIR/fm-tmux-lib.sh"
now_epoch(){ date +%s; }
is_uint(){ case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
mtime_epoch(){ if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi; }
age_of(){ local m; m=$(mtime_epoch "$1") || { echo 999999; return; }; echo $(( $(now_epoch) - m )); }
field(){ sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }
# The dispatch manifest has descriptive v1 names; the compact test manifest
# names remain accepted so the evaluator can be exercised independently.  This
# is a schema adapter, not a legacy-meta fallback: both forms require an
# explicit verified operation manifest.
mf_field(){
  local f=$1 k=$2 v
  v=$(field "$f" "$k")
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  case "$k" in
    start) field "$f" started-at;;
    no-progress) field "$f" no-progress-seconds;;
    retry-cap) field "$f" retry-max-attempts;;
    success-predicate) field "$f" success-predicate-id;;
    success-args) field "$f" success-predicate-args;;
    failure-predicate) field "$f" failure-predicate-id;;
    failure-args) field "$f" failure-predicate-args;;
    identity) field "$f" command-identity;;
    *) printf '';;
  esac
}
absolute_path(){ case "$1" in /*) printf '%s' "$1";; *) printf '%s' "$FM_HOME/$1";; esac; }
clean(){ LC_ALL=C tr '\t\r\n' '   '; }
pid_alive(){ fm_pid_alive "$1"; }
pane_exists(){ tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1; }

# Manifests are intentionally boring line-oriented records.  Atomic rename at
# dispatch and strict required keys make them portable to bash 3.2 and easy to
# inspect.  A legacy .meta is never implicitly promoted to a contract.
manifest_valid(){ # <file> <id>
  local f=$1 id=$2 k v
  [ -f "$f" ] || return 1
  case "$(head -1 "$f" 2>/dev/null)" in manifest-v1) :;; schema=firstmate.operation-manifest/v1) [ "$(field "$f" verification)" = verified ] || return 1;; *) return 1;; esac
  [ "$(field "$f" task-id)" = "$id" ] || return 1
  for k in owner route identity start deadline no-progress success-predicate failure-predicate retry-classes retry-cap idempotency-key escalation-action acknowledgement-deadline; do
    v=$(mf_field "$f" "$k"); [ -n "$v" ] || return 1
  done
  is_uint "$(mf_field "$f" start)" && is_uint "$(mf_field "$f" deadline)" && is_uint "$(mf_field "$f" no-progress)" && is_uint "$(mf_field "$f" retry-cap)" && is_uint "$(mf_field "$f" acknowledgement-deadline)"
}

arg(){ # args are deterministic key=value pairs separated by ;
  printf '%s\n' "$1" | tr ';' '\n' | sed -n "s/^$2=//p" | tail -1
}
predicate_eval(){ # <id> <predicate-id> <args>; stdout: state<TAB>code<TAB>evidence
  local id=$1 p=$2 a=$3 path expected actual max pid revision state run result alarm tuple
  case "$p" in
    always-pass) printf 'pass\tok\tdeterministic always-pass';;
    always-fail) printf 'fail\tsemantic-failure\tdeterministic always-fail';;
    file-exists) path=$(absolute_path "$(arg "$a" path)"); [ -n "$(arg "$a" path)" ] && [ -e "$path" ] && printf 'pass\tok\t%s exists' "$path" || printf 'fail\tartifact-missing\t%s missing' "$path";;
    file-content) path=$(absolute_path "$(arg "$a" path)"); expected=$(arg "$a" expected); [ -f "$path" ] && grep -F -- "$expected" "$path" >/dev/null 2>&1 && printf 'pass\tok\tcontent matched' || printf 'fail\tcontent-mismatch\tcontent did not match';;
    file-hash) path=$(absolute_path "$(arg "$a" path)"); expected=$(arg "$a" sha256); actual=$( (shasum -a 256 "$path" 2>/dev/null || sha256sum "$path" 2>/dev/null) | awk '{print $1}'); [ -n "$actual" ] && [ "$actual" = "$expected" ] && printf 'pass\tok\thash matched' || printf 'fail\thash-mismatch\thash did not match';;
    file-tail) path=$(absolute_path "$(arg "$a" path)"); expected=$(arg "$a" expected); [ -f "$path" ] && tail -1 "$path" | grep -F -- "$expected" >/dev/null 2>&1 && printf 'pass\tok\ttail matched' || printf 'fail\ttail-mismatch\ttail did not match';;
    file-fresh) path=$(absolute_path "$(arg "$a" path)"); max=$(arg "$a" max-age); [ -f "$path" ] && is_uint "$max" && [ "$(age_of "$path")" -le "$max" ] && printf 'pass\tok\tfresh' || printf 'fail\tartifact-stale\tfreshness bound exceeded';;
    command-receipt) path=$(absolute_path "$(arg "$a" path)"); expected=$(arg "$a" exit); [ -f "$path" ] && grep -qxF "exit=${expected:-0}" "$path" && printf 'pass\tok\tterminal command receipt matched' || printf 'fail\tcommand-receipt-missing\tterminal command receipt absent or mismatched';;
    process-health) pid=$(arg "$a" pid); revision=$(arg "$a" revision); [ -n "$pid" ] && pid_alive "$pid" && { [ -z "$revision" ] || ps -p "$pid" -o command= 2>/dev/null | grep -F -- "$revision" >/dev/null; } && printf 'pass\tok\tprocess identity healthy' || printf 'fail\tprocess-unhealthy\tprocess identity or revision failed';;
    transaction-state) path=$(absolute_path "$(arg "$a" path)"); expected=$(arg "$a" state); [ -f "$path" ] && grep -qxF "$expected" "$path" && printf 'pass\tok\ttransaction terminal state matched' || printf 'fail\ttransaction-state\ttransaction state mismatched';;
    scheduled-run) path=$(absolute_path "$(arg "$a" path)"); run=$(arg "$a" run-id); result=$(arg "$a" result); alarm=$(arg "$a" alarm); [ -f "$path" ] && grep -qxF "run-id=$run" "$path" && grep -qxF "result=$result" "$path" && grep -qxF "alarm=$alarm" "$path" && printf 'pass\tok\tscheduled run binding matched' || printf 'fail\tscheduled-run-binding\trun/result/alarm binding mismatched';;
    domain-tuple) path=$(absolute_path "$(arg "$a" path)"); tuple=$(arg "$a" expected); [ -f "$path" ] && grep -qxF "$tuple" "$path" && printf 'pass\tok\tregistered domain tuple matched' || printf 'fail\tdomain-predicate\tregistered domain tuple mismatched';;
    *) printf 'fail\tpredicate-schema\tunknown predicate id %s' "$p";;
  esac
}

failure_class(){ case "$1" in lock-contention|network-temporary|service-unavailable) echo transient;; predicate-schema|content-mismatch|hash-mismatch|tail-mismatch|domain-predicate|transaction-state|scheduled-run-binding|semantic-failure) echo semantic;; *) echo boundary;; esac; }

write_machine(){ # id liveness predicate outcome route reason annotation
  local id=$1 tmp="$MACHINE/$id.tmp.$$"
  mkdir -p "$MACHINE" || return 1
  { printf 'state-v1\n'; printf 'task-id=%s\nliveness=%s\npredicate=%s\noutcome=%s\nroute=%s\nreason=%s\nannotation=%s\nupdated-at=%s\n' "$id" "$2" "$3" "$4" "$5" "$(printf '%s' "$6"|clean)" "$(printf '%s' "$7"|clean)" "$(now_epoch)"; } > "$tmp" && mv -f "$tmp" "$MACHINE/$id.state"
}
event_id(){ printf '%s' "$1|$2|$3" | cksum | awk '{print $1}'; }
route_failure(){ # id manifest predicate code evidence
  local id=$1 mf=$2 predicate=$3 code=$4 evidence=$5 eid action tmp retry classes cap attempts
  eid=$(event_id "$id" "$predicate" "$code"); action="$ACTIONS/$eid.action"; mkdir -p "$ACTIONS" || return 1
  [ -f "$action" ] && return 0
  classes=$(mf_field "$mf" retry-classes); cap=$(mf_field "$mf" retry-cap); attempts=0
  retry=none; case ",$classes," in *,"$(failure_class "$code")",*) [ "$attempts" -lt "$cap" ] && retry=bounded-idempotent;; esac
  tmp="$action.tmp.$$"
  { printf 'action-v1\nevent-id=%s\ntask-id=%s\nowner=%s\nroute=%s\nstate=queued\nfailed-predicate=%s\nfailure-code=%s\nevidence=%s\nnext-command=%s\nretry=%s\nidempotency-key=%s\nacknowledgement-deadline=%s\ncreated-at=%s\n' "$eid" "$id" "$(mf_field "$mf" owner)" "$(mf_field "$mf" route)" "$predicate" "$code" "$(printf '%s' "$evidence"|clean)" "$(mf_field "$mf" escalation-action)" "$retry" "$(mf_field "$mf" idempotency-key)" "$(mf_field "$mf" acknowledgement-deadline)" "$(now_epoch)"; } > "$tmp" && mv -f "$tmp" "$action" || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now_epoch)" "$eid" "$id" "$predicate" "$code" >> "$EVENTS"
}

classify_meta(){ # preserves the first 7 snapshot columns expected by board
  local meta=$1 id mf window pid live=unknown pred=pending outcome=none route=unqueued reason annotation="" deadline now p pa code evidence state class receipt
  id=$(basename "$meta" .meta); mf="$STATE/$id.manifest"; window=$(field "$meta" window); pid=$(field "$meta" process-pid); [ -n "$pid" ] || pid=$(field "$meta" pid)
  if ! manifest_valid "$mf" "$id"; then
    write_machine "$id" unknown pending blocked unqueued manifest-missing 'legacy record requires explicit fm-manifest-migrate' || return 1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" blocked 'mandatory manifest missing' '' 999999 '' 0; return
  fi
  annotation=$(tail -1 "$STATE/$id.status" 2>/dev/null || true)
  if [ -n "$pid" ]; then if pid_alive "$pid"; then live=alive; else live=gone; fi
  elif [ -n "$window" ] && pane_exists "$window" && fm_pane_is_busy "$window"; then live=alive
  elif [ -n "$window" ] && ! pane_exists "$window"; then live=gone; fi
  deadline=$(mf_field "$mf" deadline); now=$(now_epoch); p=$(mf_field "$mf" success-predicate)
  if [ "$now" -gt "$deadline" ]; then pred=expired; code=deadline-expired; evidence="deadline $deadline passed"
  else IFS=$'\t' read -r pred code evidence <<EOF
$(predicate_eval "$id" "$p" "$(mf_field "$mf" success-args)")
EOF
  fi
  if [ "$pred" = pass ]; then outcome=success
  elif [ "$pred" = fail ] || [ "$pred" = expired ]; then outcome=failed; route_failure "$id" "$mf" "$p" "$code" "$evidence" || return 1; route=queued
  else case "$annotation" in blocked:*) outcome=blocked;; needs-decision:*) outcome=needs-decision;; failed:*) outcome=failed;; esac; fi
  # Hard evidence always wins presentation.  Busy is liveness only, never success.
  case "$pred/$outcome" in fail/*|expired/*) class=failed;; pass/success) class=success;; */blocked) class=blocked;; */needs-decision) class=needs-decision;; *) class=active-unverified;; esac
  write_machine "$id" "$live" "$pred" "$outcome" "$route" "$code" "$annotation" || return 1
  receipt_age=$(age_of "$STATE/$id.status"); printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$class" "$(printf '%s' "$code"|clean)" "$(printf '%s' "$annotation"|clean)" "$receipt_age" "$deadline" 0
}

write_snapshot(){ local tmp="$SNAPSHOT.tmp.$$" rows="$SNAPSHOT.tmp.$$.rows" meta; rm -f "$rows"; : > "$rows" || return 1; for meta in "$STATE"/*.meta; do [ -f "$meta" ] && classify_meta "$meta" >> "$rows" || { rm -f "$tmp" "$rows"; return 1; }; done; { printf 'artifact-supervisor-v2\ngenerated-at\t%s\n' "$(now_epoch)"; LC_ALL=C sort "$rows"; } > "$tmp" && mv -f "$tmp" "$SNAPSHOT"; local rc=$?; rm -f "$rows"; return $rc; }
cycle(){ if ! write_snapshot; then printf '%s\tsnapshot-write-failed\n' "$(now_epoch)" > "$ERROR"; return 1; fi; if ! [ -x "$SCRIPT_DIR/fm-board.sh" ] || ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_ARTIFACT_SNAPSHOT="$SNAPSHOT" FM_ARTIFACT_STALE_AFTER="$((INTERVAL*3))" "$SCRIPT_DIR/fm-board.sh" --once >/dev/null 2>&1; then printf '%s\tboard-refresh-failed\n' "$(now_epoch)" > "$ERROR"; return 1; fi; : > "$HEARTBEAT" || return 1; rm -f "$ERROR"; }
supervisor_pid_is_ours(){ local pid=$1 cmd lockpid; pid_alive "$pid" || return 1; lockpid=$(cat "$LOCK/pid" 2>/dev/null||true); [ "$lockpid" = "$pid" ] || return 1; cmd=$(ps -p "$pid" -o command= 2>/dev/null||true); case "$cmd" in *"$SCRIPT_DIR/fm-artifact-supervisor.sh"*'--loop'*) return 0;; *) return 1;; esac; }
loop(){ mkdir -p "$STATE"; fm_lock_try_acquire "$LOCK" || return 1; printf '%s\n' "$$" > "$PIDFILE"; trap 'rm -f "$PIDFILE"; fm_lock_release "$LOCK"; exit 0' INT TERM EXIT; while :; do cycle || true; sleep "$INTERVAL"; done; }
start(){ mkdir -p "$STATE"; local pid; pid=$(cat "$PIDFILE" 2>/dev/null||true); supervisor_pid_is_ours "$pid" && { echo "artifact supervisor already running: pid $pid"; return; }; nohup "$SCRIPT_DIR/fm-artifact-supervisor.sh" --loop >> "$LOG" 2>&1 & echo "artifact supervisor starting: pid $!"; }
restart(){ local pid; pid=$(cat "$PIDFILE" 2>/dev/null||true); supervisor_pid_is_ours "$pid" && kill -TERM "$pid" 2>/dev/null || true; start; }
ack(){ local f="$ACTIONS/$1.action" tmp; [ -f "$f" ] || { echo "unknown action: $1" >&2; return 2; }; tmp="$f.tmp.$$"; sed 's/^state=.*/state=acknowledged/; /^acknowledged-at=/d' "$f" > "$tmp" && printf 'acknowledged-at=%s\n' "$(now_epoch)" >> "$tmp" && mv -f "$tmp" "$f"; }
case "${1:-start}" in start) start;; restart) restart;; --loop) loop;; --once) mkdir -p "$STATE"; cycle;; status) printf 'pid=%s heartbeat-age=%s snapshot=%s events=%s\n' "$(cat "$PIDFILE" 2>/dev/null||echo off)" "$(age_of "$HEARTBEAT")" "$SNAPSHOT" "$EVENTS";; ack) ack "${2:?action id required}";; *) echo "usage: $0 [start|restart|status|ack ACTION|--once]" >&2; exit 2;; esac
