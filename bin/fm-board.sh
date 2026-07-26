#!/usr/bin/env bash
# Render the Firstmate Board once from the deterministic supervisor snapshot.
# The always-on fm-supervisor.sh process is the sole refresh owner.
# Usage: fm-board.sh --once|status
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SNAPSHOT="${FM_SUPERVISOR_SNAPSHOT:-$STATE/firstmate-supervisor.tsv}"
BOARD_DIR="${FM_BOARD_DIR:-$STATE/board}"
OUT="${FM_BOARD_OUT:-$BOARD_DIR/board.html}"
HEARTBEAT="$STATE/.firstmate-supervisor.heartbeat"
PIDFILE="$STATE/.firstmate-supervisor.pid"
OWNER_RECEIPT="$STATE/.firstmate-supervisor.owner"
DEFAULT_STALE_AFTER=60
owner_pid=$(cat "$PIDFILE" 2>/dev/null || true)
receipt_pid=$(sed -n 's/^pid=//p' "$OWNER_RECEIPT" 2>/dev/null | tail -1)
owner_interval=$(sed -n 's/^interval=//p' "$OWNER_RECEIPT" 2>/dev/null | tail -1)
case "$owner_pid" in
  ''|*[!0-9]*) ;;
  *)
    case "$owner_interval" in
      ''|0|*[!0-9]*) ;;
      *)
        if [ "$receipt_pid" = "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
          DEFAULT_STALE_AFTER=$((owner_interval * 2 + 5))
        fi
        ;;
    esac
    ;;
esac
STALE_AFTER="${FM_BOARD_STALE_AFTER:-$DEFAULT_STALE_AFTER}"
case "$STALE_AFTER" in ''|0|*[!0-9]*) STALE_AFTER=$DEFAULT_STALE_AFTER ;; esac

now_epoch() { date +%s; }
mtime_epoch() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null
  else stat -c %Y "$1" 2>/dev/null; fi
}
age_of() {
  local m
  m=$(mtime_epoch "$1") || { printf '999999'; return; }
  printf '%s' "$(( $(now_epoch) - m ))"
}
age_text() {
  local seconds=$1
  if [ "$seconds" -lt 60 ]; then printf '%ss' "$seconds"
  elif [ "$seconds" -lt 3600 ]; then printf '%sm' "$((seconds / 60))"
  else printf '%sh' "$((seconds / 3600))"
  fi
}
escape_html() {
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

snapshot_value() {
  awk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$SNAPSHOT" 2>/dev/null
}

task_count() {
  awk -F '\t' -v state="$1" '$1 == "task" && $3 == state { count++ } END { print count + 0 }' "$SNAPSHOT"
}

task_kind() {
  sed -n 's/^kind=//p' "$STATE/$1.meta" 2>/dev/null | tail -1
}

render_row() {
  local id=$1 state=$2 reason=$3 receipt=$4 deadline=$5 window=$6 pid=$7
  local kind contract contract_row contract_kind contract_state contract_version contract_time
  [ "$receipt" != - ] || receipt=""
  [ "$deadline" != - ] || deadline=""
  [ "$window" != - ] || window=""
  [ "$pid" != - ] || pid=""
  kind=$(task_kind "$id")
  [ -n "$kind" ] || kind=task
  [ -n "$receipt" ] || receipt="No durable receipt yet"
  contract_row=$(awk -F '\t' -v id="$id" \
    '$1 == "contract" && $2 == id { print $3 "\t" $5 "\t" $6 "\t" $7; exit }' \
    "$SNAPSHOT" 2>/dev/null)
  IFS="$(printf '\t')" read -r contract_kind contract_state contract_version contract_time <<EOF
$contract_row
EOF
  if [ -n "$deadline" ]; then
    contract="${contract_kind:-any-receipt} due at Unix $deadline"
    if [ -n "$contract_state" ]; then
      contract="$contract · $contract_state"
    fi
    if [ "$contract_state" = satisfied ] && [ -n "$contract_version" ]; then
      contract="$contract by $contract_version at $contract_time"
    fi
  else
    contract="No receipt deadline declared"
  fi
  if [ -n "$window" ]; then
    contract="$contract · $window"
  elif [ -n "$pid" ]; then
    contract="$contract · pid $pid"
  fi

  printf '<tr><td><code>%s</code><small>%s</small></td><td><span class="state %s">%s</span></td><td>%s</td><td>%s<small>%s</small></td></tr>\n' \
    "$(printf '%s' "$id" | escape_html)" \
    "$(printf '%s' "$kind" | escape_html)" \
    "$state" \
    "$state" \
    "$(printf '%s' "$receipt" | cut -c1-220 | escape_html)" \
    "$(printf '%s' "$reason" | escape_html)" \
    "$(printf '%s' "$contract" | escape_html)"
}

render_escalation_rows() {
  local record id condition action any=0
  while IFS="$(printf '\t')" read -r record id condition action; do
    [ "$record" = escalation ] || continue
    printf '<tr><td><code>%s</code></td><td>%s</td><td>%s</td></tr>\n' \
      "$(printf '%s' "$id" | escape_html)" \
      "$(printf '%s' "$condition" | escape_html)" \
      "$(printf '%s' "$action" | escape_html)"
    any=1
  done < "$SNAPSHOT"
  if [ "$any" -eq 0 ]; then
    printf '<tr><td colspan="3" class="empty">No current supervisor escalations.</td></tr>\n'
  fi
}

render_rows() {
  local record id state reason receipt deadline window pid any=0
  while IFS="$(printf '\t')" read -r record id state reason receipt deadline window pid; do
    [ "$record" = task ] || continue
    render_row "$id" "$state" "$reason" "$receipt" "$deadline" "$window" "$pid"
    any=1
  done < "$SNAPSHOT"
  if [ "$any" -eq 0 ]; then
    printf '<tr><td colspan="4" class="empty">No recorded direct reports in this Firstmate home.</td></tr>\n'
  fi
}

render_once() {
  local tmp generated wake_count wake_last active unverified stalled terminal snapshot_age
  [ -f "$SNAPSHOT" ] || {
    printf 'error: supervisor snapshot not found: %s\n' "$SNAPSHOT" >&2
    return 1
  }
  mkdir -p "$BOARD_DIR" || return 1
  tmp="$OUT.tmp.$$"
  generated=$(snapshot_value generated-at)
  [ -n "$generated" ] || generated=$(now_epoch)
  wake_count=$(snapshot_value wake-count)
  wake_last=$(snapshot_value wake-last-seq)
  active=$(task_count active)
  unverified=$(task_count active-unverified)
  stalled=$(task_count stalled)
  terminal=$(task_count terminal)
  snapshot_age=$(age_of "$SNAPSHOT")

  {
    cat <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="15">
<title>Firstmate Board</title>
<style>
:root{color-scheme:dark;--ink:#eef3f8;--muted:#8e9cad;--line:#293645;--panel:#111a24;--bg:#081019;--cyan:#4dd7df;--green:#73dd9a;--amber:#f6c768;--red:#ff7c79;--blue:#80bfff}
*{box-sizing:border-box}
body{margin:0;background:radial-gradient(circle at 12% -10%,#16324a 0,transparent 34rem),var(--bg);color:var(--ink);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;padding:clamp(16px,3vw,34px)}
main{width:min(1180px,100%);margin:auto}
header{display:flex;align-items:flex-end;justify-content:space-between;gap:20px;margin-bottom:22px}
.eyebrow{color:var(--cyan);font:700 11px/1.2 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.14em;text-transform:uppercase}
h1{font-size:clamp(28px,4vw,44px);line-height:1.05;letter-spacing:-.04em;margin:5px 0}
.stamp{color:var(--muted);font:12px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;text-align:right}
.health{border:1px solid #28566b;background:#0d2531;border-radius:10px;padding:11px 14px;margin-bottom:14px;display:flex;justify-content:space-between;gap:16px}
.health b{color:var(--cyan)}.health span{color:var(--muted)}
.summary{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px;margin-bottom:14px}
.metric{min-width:0;border:1px solid var(--line);background:linear-gradient(150deg,#152230,var(--panel));border-radius:10px;padding:14px}
.metric strong{display:block;font:700 26px/1 ui-monospace,SFMono-Regular,Menlo,monospace;margin-bottom:7px}
.metric span{color:var(--muted);font-size:12px}.metric.stalled strong{color:var(--red)}.metric.active strong{color:var(--green)}.metric.unverified strong{color:var(--amber)}.metric.terminal strong{color:var(--blue)}
.panel{border:1px solid var(--line);background:rgba(17,26,36,.94);border-radius:12px;overflow:hidden}
.panel + .panel{margin-top:14px}
.panel-head{display:flex;justify-content:space-between;gap:16px;align-items:center;padding:13px 15px;border-bottom:1px solid var(--line)}
.panel-head h2{font-size:13px;margin:0;letter-spacing:.04em}.panel-head span{color:var(--muted);font:11px ui-monospace,SFMono-Regular,Menlo,monospace}
.table-wrap{overflow-x:auto;max-width:100%}
table{border-collapse:collapse;width:100%;min-width:760px}th,td{padding:12px 14px;text-align:left;vertical-align:top;border-bottom:1px solid var(--line)}
tr:last-child td{border-bottom:0}th{color:var(--muted);font:600 10px ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.08em;text-transform:uppercase}
td{color:#d2dbe5}td:nth-child(1){width:19%}td:nth-child(2){width:18%}td:nth-child(3){width:31%}td:nth-child(4){width:32%}
code,small{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}small{display:block;color:var(--muted);margin-top:3px;overflow-wrap:anywhere}
.state{display:inline-block;border-radius:999px;padding:3px 8px;font:700 10px ui-monospace,SFMono-Regular,Menlo,monospace;white-space:nowrap}
.state.active{color:var(--green);background:#133322}.state.active-unverified{color:var(--amber);background:#392c12}.state.stalled{color:var(--red);background:#3e1c20}.state.terminal{color:var(--blue);background:#142f4b}
.empty{color:var(--muted);text-align:center;padding:30px}
@media(max-width:700px){
  header,.health{align-items:flex-start;flex-direction:column}.stamp{text-align:left}.summary{grid-template-columns:repeat(2,minmax(0,1fr))}
  .panel-head{align-items:flex-start}.table-wrap{overflow:visible}table{min-width:0}thead{display:none}
  tbody,tr,td{display:block;width:100%}tbody tr{padding:12px 14px;border-bottom:1px solid var(--line)}tbody tr:last-child{border-bottom:0}
  td,td:nth-child(n){border:0;padding:5px 0;width:100%}td::before{display:block;color:var(--muted);font:600 9px ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.08em;text-transform:uppercase;margin-bottom:3px}
  td:nth-child(1)::before{content:"Task"}td:nth-child(2)::before{content:"State"}td:nth-child(3)::before{content:"Last receipt"}td:nth-child(4)::before{content:"Evidence / action"}
  .escalations td:nth-child(2)::before{content:"Condition"}.escalations td:nth-child(3)::before{content:"Action"}
  td.empty::before{content:""}
}
@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important}}
</style>
</head>
<body>
<main>
<header>
  <div><div class="eyebrow">Deterministic fleet state</div><h1>Firstmate Board</h1></div>
  <div class="stamp">Snapshot <span id="snapshot-age">${snapshot_age}s ago</span><br>Unix $generated</div>
</header>
<div id="health" class="health"><b>Supervisor snapshot is live</b><span>No chat injection · wake queue preserved</span></div>
<section class="summary" aria-label="Task state summary">
  <div class="metric active"><strong>$active</strong><span>active</span></div>
  <div class="metric unverified"><strong>$unverified</strong><span>active-unverified</span></div>
  <div class="metric stalled"><strong>$stalled</strong><span>stalled</span></div>
  <div class="metric terminal"><strong>$terminal</strong><span>terminal</span></div>
</section>
<section class="panel">
  <div class="panel-head"><h2>Recorded direct reports</h2><span>$wake_count queued wake(s) · last sequence $wake_last</span></div>
  <div class="table-wrap"><table><thead><tr><th>Task</th><th>State</th><th>Last receipt</th><th>Evidence / action</th></tr></thead><tbody>
HTML
    render_rows
    cat <<HTML
  </tbody></table></div>
</section>
<section class="panel">
  <div class="panel-head"><h2>Current escalation queue</h2><span>Durable · no chat injection</span></div>
  <div class="table-wrap"><table class="escalations"><thead><tr><th>Task</th><th>Condition</th><th>Action</th></tr></thead><tbody>
HTML
    render_escalation_rows
    cat <<HTML
  </tbody></table></div>
</section>
</main>
<script>
const generated=$generated,limit=$STALE_AFTER,ageNode=document.querySelector('#snapshot-age'),health=document.querySelector('#health');
function refreshAge(){const age=Math.max(0,Math.floor(Date.now()/1000-generated));ageNode.textContent=age+'s ago';if(age>limit){health.style.borderColor='#73343a';health.style.background='#30171b';health.innerHTML='<b style="color:var(--red)">Supervisor snapshot is stale</b><span>Run fm-supervisor.sh status, then restart if needed.</span>'}}
refreshAge();setInterval(refreshAge,1000);
</script>
</body>
</html>
HTML
  } > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$OUT"
}

status() {
  if [ -f "$OUT" ]; then
    printf 'board=%s age=%s supervisor-heartbeat-age=%s\n' "$OUT" "$(age_of "$OUT")" "$(age_of "$HEARTBEAT")"
  else
    printf 'board=missing expected=%s supervisor-heartbeat-age=%s\n' "$OUT" "$(age_of "$HEARTBEAT")"
    return 1
  fi
}

case "${1:---once}" in
  --once) render_once ;;
  status) status ;;
  *) printf 'usage: %s --once|status\n' "$0" >&2; exit 2 ;;
esac
