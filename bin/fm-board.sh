#!/usr/bin/env bash
# Render the one Firstmate Board from deterministic shell state. The generated
# page also declares itself stale when this process no longer refreshes it.
set -u

FM_HOME="${FM_HOME:-/home/rob/firstmate}"
BOARD_DIR="${FM_BOARD_DIR:-/mnt/e/Quant/state/firstmate}"
OUT="${FM_BOARD_OUT:-$BOARD_DIR/board.html}"
BODY="${FM_BOARD_BODY:-$BOARD_DIR/board-body.html}"
PIDFILE="${FM_BOARD_PIDFILE:-$BOARD_DIR/.board-generator.pid}"
HEARTBEAT="${FM_BOARD_HEARTBEAT:-$BOARD_DIR/.board-generator.heartbeat}"
SESSION="${FM_BOARD_SESSION:-fm-board-generator}"
INTERVAL="${FM_BOARD_INTERVAL:-8}"
STALE_AFTER="${FM_BOARD_STALE_AFTER:-$((INTERVAL * 3))}"
STALL_AFTER="${FM_BOARD_STALL_AFTER:-180}"
SNAPSHOT="${FM_ARTIFACT_SNAPSHOT:-$FM_HOME/state/artifact-supervisor.tsv}"

now_epoch() { date +%s; }
mtime_epoch() { date -r "$1" +%s 2>/dev/null || echo 0; }
age_of() { local m; m=$(mtime_epoch "$1"); [ "$m" -gt 0 ] && echo "$(( $(now_epoch) - m ))" || echo 999999; }
age_text() {
  local s=$1
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm' "$((s / 60))"
  else printf '%sh' "$((s / 3600))"
  fi
}
escape_html() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

pane_busy() {
  local capture
  capture=$(timeout 3 tmux capture-pane -p -t "$1" 2>/dev/null | tail -8) || return 1
  printf '%s\n' "$capture" | grep -qiE 'esc to interrupt|esc interrupt|Working \(|Working\.\.\.|thinking'
}

pane_exists() { timeout 3 tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1; }

terminal_receipt() {
  case "$1" in
    done:*|failed:*|blocked:*|needs-decision:*|terminal:*|pr-ready:*|merged:*) return 0 ;;
    *) return 1 ;;
  esac
}

# The artifact supervisor is authoritative when its deterministic snapshot is
# available.  Keeping this fallback lets the board remain useful during an
# upgrade or while the supervisor has not completed its first cycle.
snapshot_row() { # <task-id>
  [ -f "$SNAPSHOT" ] || return 1
  awk -F '\t' -v wanted="$1" 'NR > 2 && $1 == wanted { print; exit }' "$SNAPSHOT"
}

render_row() {
  local meta=$1 id win kind status_file receipt status_age meta_age age state reason class pr snap
  id=$(basename "$meta" .meta)
  win=$(sed -n 's/^window=//p' "$meta" | head -1)
  kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
  [ -n "$win" ] || return 0
  status_file="$FM_HOME/state/$id.status"
  receipt=$(tail -1 "$status_file" 2>/dev/null || true)
  pr=$(sed -n 's/^pr=//p' "$meta" | head -1)
  [ -n "$receipt" ] || receipt='no durable status receipt'
  status_age=$(age_of "$status_file")
  meta_age=$(age_of "$meta")
  age=$status_age; [ "$age" -gt "$meta_age" ] && age=$meta_age
  snap=$(snapshot_row "$id" || true)
  if [ -n "$snap" ]; then
    IFS="$(printf '\t')" read -r _ state reason receipt status_age _ _ <<EOF
$snap
EOF
    class=$state
    age=$status_age
  else
    state=active-unverified; reason='Awaiting the next durable update.'; class=active-unverified
  # A receipt or recorded PR is authoritative, even if a stale pane still exists.
  if terminal_receipt "$receipt" || [ -n "$pr" ]; then
    state=terminal; class=terminal; reason='Terminal receipt recorded; pane presence does not imply work.'
  elif ! pane_exists "$win"; then
    state=stalled; class=bad; reason='Recorded pane is gone without a terminal receipt; inspect or relaunch.'
  elif pane_busy "$win"; then
    state=active; class=active; reason='Busy footer observed in the pane.'
  elif [ "$age" -ge "$STALL_AFTER" ]; then
    state=stalled; class=bad; reason="No durable update for $(age_text "$age"); inspect the idle pane."
  fi
  fi
  receipt=$(printf '%s' "$receipt" | cut -c1-260 | escape_html)
  reason=$(printf '%s' "$reason" | escape_html)
  printf '<tr><td><code>%s</code><small>%s</small></td><td><span class="state %s">%s</span></td><td>%s</td><td>%s ago</td><td class="reason %s">%s</td></tr>\n' \
    "$id" "${kind:-task}" "$class" "$state" "$receipt" "$(age_text "$age")" "$class" "$reason"
}

supervisor_card() {
  local beat_age daemon_pid daemon_state activity activity_age
  beat_age=$(age_of "$FM_HOME/state/.last-watcher-beat")
  daemon_pid=$(cat "$FM_HOME/state/.supervise-daemon.pid" 2>/dev/null || true)
  daemon_state=off
  [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null && daemon_state=running
  activity=$(cat "$FM_HOME/state/.fm-activity" 2>/dev/null || echo 'no activity receipt')
  activity_age=$(age_of "$FM_HOME/state/.fm-activity")
  if [ "$beat_age" -ge "$STALE_AFTER" ]; then
    printf '<div class="supervisor bad"><b>Supervisor: stale</b><span>No heartbeat for %s; restart supervision before trusting task state.</span><small>daemon %s · %s (%s ago)</small></div>' "$(age_text "$beat_age")" "$daemon_state" "$(printf '%s' "$activity" | escape_html)" "$(age_text "$activity_age")"
  else
    printf '<div class="supervisor"><b>Supervisor: healthy</b><span>Heartbeat %s ago. State is derived from files, mtimes, and pane footers only.</span><small>daemon %s · %s (%s ago)</small></div>' "$(age_text "$beat_age")" "$daemon_state" "$(printf '%s' "$activity" | escape_html)" "$(age_text "$activity_age")"
  fi
}

render_once() {
  local tmp now rows body meta
  mkdir -p "$BOARD_DIR"
  tmp="$OUT.tmp.$$"
  now=$(TZ=America/New_York date '+%Y-%m-%d %H:%M:%S ET')
  rows=''
  for meta in "$FM_HOME"/state/*.meta; do [ -f "$meta" ] && rows="${rows}$(render_row "$meta")"; done
  [ -n "$rows" ] || rows='<tr><td colspan="5" class="empty">No recorded Firstmate panes.</td></tr>'
  body=''; [ -f "$BODY" ] && body=$(cat "$BODY")
  cat >"$tmp" <<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="$INTERVAL"><title>Firstmate Board</title>
<style>:root{--bg:#0d1117;--panel:#161b22;--line:#30363d;--text:#e6edf3;--muted:#8b949e;--green:#3fb950;--red:#f85149}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,sans-serif;padding:24px}.wrap{max-width:1180px;margin:auto}h1{margin:0;font-size:24px}.stamp{margin:3px 0 18px;color:var(--muted);font:12px ui-monospace,monospace}.generator{border:1px solid #1f6f3d;background:#12261b;padding:10px 13px;border-radius:8px;margin-bottom:12px}.generator.bad{border-color:#7a2e2e;background:#2a1618;color:#ffb1a6}.supervisor{border:1px solid var(--line);background:var(--panel);border-radius:8px;padding:13px;margin-bottom:12px;display:grid;gap:3px}.supervisor b{color:var(--green)}.supervisor.bad b{color:#ffb1a6}.supervisor small{font-family:ui-monospace,monospace;color:var(--muted)}.panel{border:1px solid var(--line);background:var(--panel);border-radius:8px;overflow:auto}.panel h2{font-size:13px;text-transform:uppercase;letter-spacing:.08em;margin:0;padding:13px 15px;color:var(--muted)}table{border-collapse:collapse;width:100%;min-width:850px}th,td{border-top:1px solid var(--line);padding:10px 12px;text-align:left;vertical-align:top}th{font:11px ui-monospace,monospace;color:var(--muted)}td{color:#c9d1d9}code,small{font-family:ui-monospace,monospace}small{display:block;color:var(--muted);margin-top:2px}.state{display:inline-block;border-radius:999px;padding:2px 8px;font:11px ui-monospace,monospace}.active{color:#7ee787;background:#12361f}.active-unverified{color:#c9d1d9;background:#30363d}.terminal{color:#79c0ff;background:#102a43}.stalled{color:#ffb1a6;background:#401b1d}.reason.stalled{color:#ff7b72;font-weight:600}.empty{color:var(--muted)}section{margin-top:16px}</style></head><body><main class="wrap">
<h1>Firstmate Board</h1><div class="stamp">Generated <time id="generated" data-epoch="$(now_epoch)">$now</time> · refreshes every ${INTERVAL}s</div>
<div id="generator" class="generator"><b>Board generator: live</b> <span id="generator-detail">fresh shell snapshot</span></div>
$(supervisor_card)
<div class="panel"><h2>Recorded panes — deterministic shell state</h2><table><thead><tr><th>Task</th><th>Current state</th><th>Last durable status</th><th>Age</th><th>Action</th></tr></thead><tbody>$rows</tbody></table></div>
$body
</main><script>const t=document.querySelector('#generated'),box=document.querySelector('#generator'),age=()=>Math.floor(Date.now()/1000-Number(t.dataset.epoch));function check(){const s=age();if(s>$STALE_AFTER){box.className='generator bad';box.innerHTML='<b>Board generator: stale/off</b> No new shell snapshot for '+s+'s. Restart fm-board.sh; do not trust this board.'}else document.querySelector('#generator-detail').textContent='fresh shell snapshot '+s+'s ago'}check();setInterval(check,1000)</script></body></html>
HTML
  mv -f "$tmp" "$OUT"
  touch "$HEARTBEAT"
}

loop() {
  trap 'rm -f "$PIDFILE"; exit 0' INT TERM EXIT
  printf '%s\n' "$$" >"$PIDFILE"
  while :; do render_once; sleep "$INTERVAL"; done
}

start() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "board generator already running in tmux session: $SESSION"
    return 0
  fi
  tmux new-session -d -s "$SESSION" "$0" --loop
  echo "board generator started in tmux session: $SESSION"
}

case "${1:-start}" in
  start) start ;;
  --loop) loop ;;
  --once) render_once ;;
  status) [ -f "$HEARTBEAT" ] && echo "heartbeat $(age_text "$(age_of "$HEARTBEAT")") ago" || echo 'off: no heartbeat' ;;
  *) echo "usage: $0 [start|status|--once]" >&2; exit 2 ;;
esac
