#!/usr/bin/env bash
# fm-supervise-daemon.sh — presence-gated sub-supervisor (closes #27's P2).
#
# Wraps bin/fm-watch.sh: runs it as a child, classifies each wake reason, and
# either SELF-HANDLES the routine majority in bash (no firstmate turn) or
# ESCALATES a batched, distilled digest to the supervisor pane on
# captain-relevant events only. This is the token-efficient replacement for the
# prior always-inject daemon: routine signal/stale/heartbeat wakes cost zero
# firstmate context; only done/needs-decision/blocked/failed/persistent-wedge/
# check-output events reach the LLM, and even then as one pre-read digest per
# batch window.
#
# PRESENCE-GATING (the /afk contract). The daemon is the away-mode engine: it
# injects ONLY when the durable away-mode flag state/.afk is present. Invoking
# the /afk skill sets that flag and starts this daemon; any real (unmarked)
# user message clears it and firstmate resumes full per-wake responsiveness.
# When afk is off, the daemon stays quiet — it self-handles routine wakes and
# buffers escalations without injecting, so the base one-shot fm-watch.sh
# protocol is the active mechanism. Escalations that arrive while afk is off
# survive in state/.subsuper-escalations and are flushed on the next
# "while you were out" catch-up or when afk is re-entered.
#
# IN-BAND SENTINEL MARKER. Every daemon injection is prefixed with
# FM_INJECT_MARK (ASCII unit separator, 0x1f) — a byte a human would never type
# at the start of a message. Firstmate's contract: a message that starts with
# the marker is an internal escalation (stay afk); a message without it means
# the captain is back (exit afk, flush catch-up, resume per-wake responsiveness).
# The marker and the busy-guard solve the same problem — the daemon and the
# human share one input channel — so they live together under /afk.
#
# Reliability model (see AGENTS.md §8):
#   - Nothing is lost: the #29 watcher enqueues every wake to state/.wake-queue
#     BEFORE advancing its suppression markers, so a crash/restart/missed
#     injection is recovered on the next fm-wake-drain.sh. The daemon does not
#     touch the queue; it only reads the watcher's stdout reason.
#   - Fail-safe-to-escalate: any wake the classifier cannot confidently mark
#     routine is escalated.
#   - Bounded wedge latency: a stale pane is escalated only after it has been
#     idle for STALE_ESCALATE_SECS (configurable), rechecked once. A wedged
#     crewmate is therefore detected within STALE_ESCALATE_SECS + a tick, never
#     lost. Crewmates are autonomous, so a delayed stale response does not stall
#     a healthy crewmate's own progress.
#     Buffered escalation delivery also has a max-defer alarm: if a digest stays
#     undelivered past FM_MAX_DEFER_SECS, the daemon retries a normal flush and
#     writes state/.subsuper-inject-wedged if submit still cannot be confirmed.
#   - Cheap heartbeat catch-all: every HEARTBEAT_SCAN_SECS the daemon greps all
#     state/*.status for a captain-relevant line the per-wake classifier might
#     have missed (e.g. a status verb outside CAPTAIN_RE) and escalates it.
#   - Stall-check catch-all: every FM_STALL_CHECK_SCAN_SECS the daemon runs the
#     full (non---fast) bin/fm-stall-check.sh sweep and buffers any NEW finding.
#     This is what present-mode firstmate already runs at every heartbeat and
#     every wake-handling turn (AGENTS.md §8); without it, away-mode is BLIND to
#     two classes the status-line catch-all above structurally cannot see: an
#     idle secondmate advisor with no time-based wake to trigger on, and a child
#     parked on needs-decision/blocked/failed inside a SEPARATE secondmate
#     home's state dir. fm-stall-check.sh re-fires the same finding every sweep
#     (it has no ack mechanism by design), so stall_check_scan dedupes by a
#     kind+id identity marker before buffering — one escalation per occurrence,
#     not a repeat every tick. See stall_check_scan for why this always runs
#     the full sweep (never --fast) and the cadence/cost tradeoff.
#
# The robustness shell from the prior always-inject version is preserved:
# single-instance lock (portable mkdir-based, no flock dependency), crash-loop
# backoff, pane-gone guard, and a signal-trapped shutdown that flushes buffered
# escalations before exit.
#
# Usage: fm-supervise-daemon.sh
#          Long-lived background loop. Normally started by the /afk skill, which
#          sets state/.afk first. Env knobs:
#          FM_SUPERVISOR_TARGET     supervisor tmux target (override; otherwise
#                                   auto-discovered from TMUX_PANE, then
#                                   firstmate:0 fallback)
#          FM_INJECT_SKIP           |-prefixes force-self-handle bypassing
#                                   classification (default "heartbeat"); empty
#                                   disables. Use sparingly: it overrides the
#                                   captain-relevant escalation for matching
#                                   kinds.
#          FM_STALE_ESCALATE_SECS   idle seconds before a stale pane escalates
#                                   as a possible wedge (default 240)
#          FM_ESCALATE_BATCH_SECS   buffer window for batched escalation
#                                   digests; 0 = flush immediately (default 90)
#          FM_HEARTBEAT_SCAN_SECS   cadence for the catch-all status scan
#                                   (default 300)
#          FM_STALL_CHECK_SCAN_SECS cadence for running bin/fm-stall-check.sh's
#                                   full sweep as a housekeeping catch-all
#                                   (default 300; always the full sweep, never
#                                   --fast — see stall_check_scan)
#          FM_STALL_REALARM_SECS    how long a stall-check finding stays deduped
#                                   before an unresolved one alarms again
#                                   (default 1800; <=0 means alarm on every sweep
#                                   it persists — never a disable). Its own knob,
#                                   deliberately independent of both the sweep
#                                   cadence above and FM_MAX_DEFER_SECS below.
#          FM_HOUSEKEEPING_TICK     seconds between housekeeping passes while
#                                   the watcher is mid-cycle (default 15)
#          FM_BUSY_REGEX            OR-ed busy signatures (mirrors fm-watch.sh)
#          FM_COMPOSER_IDLE_RE      empty-composer regex applied after dim-ghost
#                                   and structural border stripping (default:
#                                   bare prompt glyphs plus busy footers)
#          FM_MAX_DEFER_SECS        max seconds a buffered escalation may sit
#                                   undelivered before one normal flush attempt
#                                   plus one idle-only Escape recovery probe;
#                                   if that cannot confirm a submit, a wedge
#                                   alarm fires and is queued for Firstmate's
#                                   next turn (default 300; 0 disables)
#          FM_INJECT_ESCAPE_SETTLE   seconds to wait after that single Escape
#                                   probe before re-reading the composer
#                                   (default 0.1)
#          FM_INJECT_CONFIRM_RETRIES Enter-retry attempts on a swallowed Enter
#                                   (default 3); the digest is typed once, only
#                                   Enter is retried. Composer-empty detection is
#                                   structural and style-aware (bin/fm-tmux-lib.sh):
#                                   it drops dim/faint ghost text and strips the
#                                   harness's box borders before deciding, so a
#                                   ghost-only or bordered-but-empty composer is
#                                   not misread as pending input.
#          FM_INJECT_CONFIRM_SLEEP  seconds between daemon submit checks
#                                   (default 0.5)
#          FM_LOG_MAX_BYTES / FM_LOG_KEEP_LINES / FM_CRASH_*  log + crash guards
#          FM_STATE_OVERRIDE        alternate state dir (testing)
#          Logs each wake to state/.supervise-daemon.log (size-capped). Single
#          instance via portable mkdir lock on state/.supervise-daemon.lock. Trapped
#          SIGTERM/SIGINT shut down within ~1s, flush escalations, release the
#          lock. A crashing fm-watch.sh is logged and restarted, never killing
#          the daemon; a tight crash-restart spin is detected and backed off.
set -u

FM_DAEMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_DAEMON_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-wake-lib.sh
FM_WAKE_LIB_PARSERS_ONLY=1 . "$FM_DAEMON_DIR/fm-wake-lib.sh"
unset FM_WAKE_LIB_PARSERS_ONLY

# Shared tmux pane primitives (busy/composer detection + verify-retry submit).
# Sourced at top level so BOTH the executed daemon and the unit tests (which
# source this file for its pure functions) get the corrected composer detection.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_DAEMON_DIR/fm-tmux-lib.sh"

# --- tunables ---------------------------------------------------------------
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
INJECT_SKIP_DEFAULT="heartbeat"
STALE_ESCALATE_SECS_DEFAULT=240
ESCALATE_BATCH_SECS_DEFAULT=90
HEARTBEAT_SCAN_SECS_DEFAULT=300
STALL_CHECK_SCAN_SECS_DEFAULT=300
# How long a stall-check finding stays deduped before an unresolved one alarms
# again. This is deliberately its OWN knob rather than a reuse of an existing
# one: any window equal to (or below) STALL_CHECK_SCAN_SECS collapses the dedup
# entirely, since the very next sweep is already past it, which would both alarm
# on every sweep and make STALL_CHECK_MISSES_TO_CLEAR's flap absorption
# unreachable. 1800 is (a) 6x the default sweep cadence, so no plausible
# retuning of that cadence can make the two collide, and (b) the same value
# fm-stall-check.sh already uses for FM_ADVISOR_IDLE_STALL_SECS, which is the
# same class of how-long-is-too-long-to-stay-quiet judgment.
# <=0 follows FM_ESCALATE_BATCH_SECS's "immediate" idiom, NOT
# FM_MAX_DEFER_SECS's "disabled" idiom: it means alarm on every sweep the
# condition persists. There is deliberately no disable value, because a disable
# path is exactly the permanent suppression stall_check_scan's governing
# principle forbids.
STALL_REALARM_SECS_DEFAULT=1800
HOUSEKEEPING_TICK_DEFAULT=15
# Max time a buffered escalation may sit undelivered before the daemon retries
# the normal flush path and, if that cannot confirm a submit, raises a loud wedge
# alarm. The escape hatch makes a guard false-positive visible instead of silent.
MAX_DEFER_SECS_DEFAULT=300
# Consecutive sweeps in which a known stall-check finding must be ABSENT before
# its dedup marker is cleared as genuinely resolved. N=1 offers no protection at
# all - the very first absence clears the marker, so a single flapping sweep (a
# momentarily busy child pane, a status file caught mid-write, a transient
# fm-peek.sh probe failure) re-escalates the identical finding. N=2 is the
# smallest value that absorbs one dropped sweep, and costs only one further
# cadence interval of latency before a genuinely resolved marker frees up.
# FM_STALL_REALARM_SECS independently bounds the cost of being wrong in either
# direction, so N needs no defensive tuning beyond this.
STALL_CHECK_MISSES_TO_CLEAR=2
CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'
# Busy footers + composer-empty detection now live in bin/fm-tmux-lib.sh
# (FM_TMUX_BUSY_REGEX_DEFAULT / fm_tmux_composer_state); FM_BUSY_REGEX still
# overrides the busy set here, as before.
INJECT_FAIL_SLEEP_DEFAULT=30
INJECT_CONFIRM_RETRIES_DEFAULT=3
INJECT_CONFIRM_SLEEP_DEFAULT=0.5
INJECT_ESCAPE_SETTLE_DEFAULT=0.1
CRASH_THRESHOLD_DEFAULT=10
CRASH_WINDOW_DEFAULT=60
CRASH_BACKOFF_DEFAULT=60
CRASH_NORMAL_SLEEP_DEFAULT=5
LOG_MAX_BYTES_DEFAULT=1048576
LOG_KEEP_LINES_DEFAULT=2000

# --- presence-gating + sentinel marker --------------------------------------
# The in-band sentinel: ASCII unit separator (0x1f). Invisible and untypable on
# a normal keyboard, so no real user message starts with it. Every daemon
# injection is prefixed with this byte; firstmate treats a leading marker as an
# internal escalation (stay afk) and its absence as "captain is back" (exit afk).
# Portable across harnesses: it travels with the message text, independent of
# any harness-level typed-vs-injected distinction.
FM_INJECT_MARK=$'\x1f'
AFK_FLAG_NAME=".afk"

# Resolve the effective state dir. FM_STATE_OVERRIDE wins (testing); otherwise
# $FM_HOME/state. Kept as a function so the pure
# classifiers can take an explicit state arg without depending on globals.
_state_root() { printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"; }

# --- portable stat (same trap as fm-watch.sh: no `stat -f || stat -c`) -------
if [ "$(uname)" = Darwin ]; then
  _stat_file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  _stat_file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
_now() { date +%s; }
_file_age() {  # seconds since mtime; very large if missing
  local f=$1 m
  m=$(_stat_file_mtime "$f") || { echo 999999; return; }
  echo $(( $(_now) - m ))
}

_hash_text() {
  if command -v md5 >/dev/null 2>&1; then printf '%s' "$1" | md5 -q
  else printf '%s' "$1" | md5sum | cut -d ' ' -f1; fi
}

# --- presence-gating helpers (PURE-ish: side-effect-free reads of state) -----
# afk_active: 0 if the durable away-mode flag exists, 1 otherwise.
afk_active() {  # <state>
  [ -e "$1/$AFK_FLAG_NAME" ]
}

# afk_enter / afk_exit: write/clear the away-mode flag. Called by the /afk
# skill (enter) and by firstmate on user return (exit). Durable: a plain file,
# so recovery (§5) re-enters afk if it is present after a restart.
afk_enter() {  # <state>
  mkdir -p "$1"
  date '+%s' > "$1/$AFK_FLAG_NAME"
}

afk_exit() {  # <state>
  rm -f "$1/$AFK_FLAG_NAME"
}

# should_exit_afk: encodes firstmate's afk-exit contract as a testable function.
#   afk inactive            -> 1 (nothing to exit)
#   message has marker      -> 1 (internal escalation; stay afk)
#   message is /afk command -> 1 (re-entering/extending afk; stay afk)
#   anything else           -> 0 (captain is back; exit afk)
# Bias toward exit: only the marker and an explicit /afk invocation keep afk
# alive. A false exit is self-correcting (the captain re-runs /afk).
should_exit_afk() {  # <state> <message-text>
  local state=$1 msg=$2
  afk_active "$state" || return 1
  message_is_injection "$msg" && return 1
  case "$msg" in
    /afk*) return 1 ;;
  esac
  return 0
}

# message_is_injection: 0 if the given message text starts with the sentinel
# marker (a daemon escalation), 1 otherwise (a real user message). Firstmate's
# afk-exit contract uses this: marker present -> stay afk; absent -> captain is
# back. Bias ambiguous cases toward exit (a false exit is self-correcting).
message_is_injection() {  # <message-text>
  local msg=$1
  [ -n "$msg" ] || return 1
  case "$msg" in
    "$FM_INJECT_MARK"*) return 0 ;;
  esac
  return 1
}

# strip_injection_marker: remove the leading sentinel marker (if present) so the
# digest text is clean for classification/relay. The afk-exit contract keys off
# the marker's PRESENCE; once detected, the marker byte should not appear in the
# distilled content firstmate relays to the captain or feeds back to classifiers.
strip_injection_marker() {  # <message-text>
  local msg=$1
  printf '%s' "${msg#"$FM_INJECT_MARK"}"
}

# Collapse all newlines to a literal " - " separator so the injected digest is
# a single line. Submission via send-keys + Enter is then unambiguous regardless
# of how the target TUI handles embedded newlines in its composer.
_collapse_newlines() {  # <text>
  local s=$1
  s=${s//$'\n'/ - }
  printf '%s' "$s"
}

# Auto-discover the supervisor pane at startup. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) — caller passes it in.
#   2. $TMUX_PANE — tmux sets this in every pane's environment; inherited by
#      the daemon when the /afk skill launches it from firstmate's own pane.
#   3. firstmate:0 — legacy fallback (may not resolve if the session is named
#      differently). The caller logs a warning in that case.
# Returns the resolved target on stdout; returns 1 if only the fallback is left
# AND the fallback does not resolve to a live pane.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# --- classification helpers (PURE: no side effects, testable) ---------------
# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line matches a captain-relevant verb.
status_is_captain_relevant() {
  local line=$1
  [ -n "$line" ] || return 1
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$CAPTAIN_RE_DEFAULT}"
}

# task id from a tmux window name "<session>:fm-<id>" -> "<id>"
window_to_task() {
  local w=$1 t
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# Decision protocol: every classifier prints exactly one line on stdout of the
# form "<action>|<distilled>" where action is "self" or "escalate". The distilled
# field for "self" is informational (logged); for "escalate" it is the pre-read
# summary firstmate would otherwise have to re-read.

classify_signal() {  # <reason-after-colon> <state>
  local reason=$1 state=$2 f raw last distilled="" rel="" all_seen=1 task seen
  for f in $reason; do
    [ -e "$f" ] || continue
    raw=$(last_status_line "$f")
    [ -n "$raw" ] || continue
    last=$(fm_receipt_text "$raw")
    distilled="${distilled}$(basename "$f"): ${last} | "
    status_is_captain_relevant "$last" || continue
    rel=1
    # Dedupe against the catch-all scan: if this status was already escalated
    # (seen marker matches), skip escalating again. The seen marker is the
    # single source of truth shared between the per-wake signal path and the
    # heartbeat scan. all_seen stays 1 only if EVERY relevant file was seen.
    task=$(basename "$f"); task="${task%.status}"
    seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
    [ "$(cat "$seen" 2>/dev/null || true)" = "$raw" ] || all_seen=0
  done
  # strip a trailing " | " separator so the distilled line is clean
  distilled="${distilled% | }"
  if [ -z "$rel" ]; then
    printf 'self|routine signal: %s' "$distilled"
  elif [ "$all_seen" = "1" ]; then
    # Every relevant status was already escalated by the catch-all scan;
    # self-handle to avoid a duplicate entry in the digest.
    printf 'self|signal already escalated (catch-all scan): %s' "$distilled"
  else
    printf 'escalate|%s' "$distilled"
  fi
}

# classify_stale decides the WAKE itself (one-shot per distinct hash). On a
# first sight of a non-terminal stale it returns "self" and the caller records a
# timestamp marker; persistence is escalated by housekeeping's recheck, not here.
classify_stale() {  # <window> <state> [detail]
  local win=$1 state=$2 detail=${3:-} task raw last seen
  task=$(window_to_task "$win")
  raw=$(last_status_line "$state/$task.status")
  last=$(fm_receipt_text "$raw")
  if [ -n "$last" ] && status_is_captain_relevant "$last"; then
    # Dedupe against the signal path: if this status was already escalated
    # (seen marker matches), self-handle to avoid a duplicate in the digest.
    seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
    if [ "$(cat "$seen" 2>/dev/null || true)" = "$raw" ]; then
      printf 'self|stale + terminal (already escalated by signal): %s' "$last"
      return
    fi
    printf 'escalate|stale + terminal status: %s' "$last"
    return
  fi
  # A dead agent is not transient staleness: the process is gone, it cannot
  # resume, and the watcher reports it once per task generation. Deferring it to
  # the persistence recheck loses it outright once the window itself disappears,
  # so escalate on the wake.
  case "$detail" in
    *"no live agent process"*)
      printf 'escalate|agent process gone (%s): %s' "$win" "${last:-no status}"
      return ;;
  esac
  # Non-terminal (or no status): defer to the persistence recheck. The caller
  # records/refreshes the stale marker so housekeeping can age it.
  printf 'self|transient stale (%s): %s' "$win" "${last:-no status}"
}

classify_check() {  # <full reason>  — check scripts print only when firstmate should wake
  printf 'escalate|%s' "$1"
}

classify_heartbeat() {
  # The wake itself is routine; the catch-all scan runs separately in
  # housekeeping on the HEARTBEAT_SCAN_SECS cadence.
  printf 'self|heartbeat (catch-all scan runs in housekeeping)'
}

# Anything unrecognized is escalated (fail-safe).
classify_unknown() {  # <reason>
  printf 'escalate|unknown wake: %s' "$1"
}

# --- stale marker + escalation buffer (stateful, but via explicit state dir) -
# Marker:   state/.subsuper-stale-<key>   contains the epoch first seen idle.
# Buffer:   state/.subsuper-escalations    one distilled line per escalation.
# Seen:     state/.subsuper-seen-status-<task>  last status line the scan
#           escalated, so the catch-all does not re-fire the same terminal.

_stale_key() { printf '%s' "$1" | tr ':/.' '___'; }

# Filesystem-safe identity for one bin/fm-stall-check.sh output line: its kind
# and id (the first two space-separated fields), with everything outside
# [A-Za-z0-9_.-] collapsed to '_'. Deliberately drops everything after the id
# (idle-seconds counts, commit counts, pane commands) so the SAME underlying
# condition keys identically while it persists — stall_check_scan dedupes it to
# one escalation per re-alarm window rather than one per tick — while a finding
# that is genuinely resolved (absent from STALL_CHECK_MISSES_TO_CLEAR
# consecutive sweeps) drops its marker, so a later recurrence of the same
# kind+id escalates as a new occurrence.
_stall_finding_key() {  # <fm-stall-check.sh output line>
  printf '%s' "$1" | awk '{print $1, $2}' | tr -c 'A-Za-z0-9_.-' '_'
}

# Read a non-negative integer out of a marker file, falling back to <default>
# when the file is missing, empty (an interrupted write), or not a plain count.
# Callers pick a <default> that fails toward alarming rather than staying quiet.
_read_int() {  # <file> <default>
  local v
  v=$(cat "$1" 2>/dev/null || true)
  case "$v" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$v" ;;
  esac
}

stale_marker_record() {  # <window> <state>  — create if absent
  local win=$1 state=$2 key marker
  key=$(_stale_key "$(window_to_task "$win")")
  marker="$state/.subsuper-stale-$key"
  [ -e "$marker" ] || _now > "$marker"
}

stale_marker_remove() {  # <window> <state>
  local win=$1 state=$2 key
  key=$(_stale_key "$(window_to_task "$win")")
  rm -f "$state/.subsuper-stale-$key"
}

# Record the seen-status marker for a captain-relevant status line so the
# heartbeat catch-all scan does not re-fire it. The single source of truth for
# the .subsuper-seen-status-<task> dedup state: called from both the per-wake
# escalate path and the catch-all scan.
mark_status_seen() {  # <state> <task> <last-line>
  local state=$1 task=$2 line=$3
  printf '%s' "$line" > "$state/.subsuper-seen-status-$(_stale_key "$task")"
}

# Mark every captain-relevant status line a per-wake classification escalated as
# seen, so the catch-all scan does not re-escalate the same line within
# HEARTBEAT_SCAN_SECS. Mirrors classify_signal/classify_stale's relevance test.
mark_escalated_seen() {  # <kind> <arg> <state>
  local kind=$1 arg=$2 state=$3 f raw last task
  case "$kind" in
    signal)
      for f in $arg; do
        [ -e "$f" ] || continue
        raw=$(last_status_line "$f")
        [ -n "$raw" ] || continue
        last=$(fm_receipt_text "$raw")
        status_is_captain_relevant "$last" || continue
        task=$(basename "$f"); task="${task%.status}"
        mark_status_seen "$state" "$task" "$raw"
      done ;;
    stale)
      task=$(window_to_task "$arg")
      raw=$(last_status_line "$state/$task.status")
      last=$(fm_receipt_text "$raw")
      [ -n "$last" ] && status_is_captain_relevant "$last" \
        && mark_status_seen "$state" "$task" "$raw" ;;
  esac
}

# Busy + composer-empty detection are the shared primitives in fm-tmux-lib.sh
# (one source of truth with fm-send.sh). These thin wrappers keep the daemon's
# call sites and the unit tests stable.
#
# pane_input_pending returns 0 (pending) when the cursor line holds real
# unsubmitted text - a human's half-typed line (the return race) or a previous
# injection whose Enter was swallowed. The detector drops dim/faint ghost text and
# strips the harness's composer box borders, so a ghost-only or idle bordered
# claude composer ("│ > … │") is correctly read as empty, not pending (incidents
# afk-invx-i5 and composer-robust).
pane_is_busy() { fm_pane_is_busy "$@"; }        # <window>
pane_input_pending() { fm_pane_input_pending "$@"; }  # <target>

escalate_add() {  # <state> <distilled-item>
  local state=$1 item=$2 buf
  buf="$state/.subsuper-escalations"
  [ -s "$buf" ] || _now > "${buf}.since"
  printf '%s\n' "$item" >> "$buf"
}

# Flush the escalation buffer as ONE batched, single-line digest to the
# supervisor pane. Returns 0 on successful inject (or empty buffer), non-zero on
# inject failure (buffer preserved for retry / catch-up).
escalate_flush() {  # <state>
  local state=$1 buf item n msg
  buf="$state/.subsuper-escalations"
  [ -s "$buf" ] || return 0
  n=$(wc -l < "$buf" 2>/dev/null || echo 0)
  # Join buffered items with the literal " | " separator into one digest line.
  msg=$(awk 'NR>1{printf " | "} {printf "%s",$0} END{print ""}' "$buf" 2>/dev/null)
  # Single-line wrapper: no embedded newlines (inject_msg also collapses as a
  # safety net, but keeping the source single-line makes the intent explicit).
  msg=$(printf 'Supervisor escalate (%s event(s)): %s (pre-read; re-arm not needed — watcher daemon-managed)' "$n" "$msg")
  if inject_msg "$msg" "$state"; then : > "$buf"; rm -f "${buf}.since" "$state/.subsuper-inject-wedged"; return 0; fi
  return 1
}

# Raise a loud, rate-limited alarm when escalations cannot be delivered after
# max-defer (the supervisor pane is genuinely busy/wedged, the compositor is
# misread, or the submit's Enter is swallowed). The daemon must NEVER silently
# wedge: this logs an ERROR, drops a durable marker, enqueues a durable signal
# for Firstmate's next turn, and flashes the supervisor client's status line.
# Nothing is lost — the buffer and the wake-queue both survive — but the stall
# stops being invisible even when injection itself is impossible.
inject_wedge_alarm() {  # <state> <age-seconds>
  local state=$1 age=$2 marker target payload
  marker="$state/.subsuper-inject-wedged"
  # Re-alarm at most once per max-defer window so a long wedge does not spam.
  if [ "$(_file_age "$marker")" -lt "${FM_MAX_DEFER_SECS:-$MAX_DEFER_SECS_DEFAULT}" ]; then
    return 0
  fi
  log "ERROR: away-mode escalation undelivered ${age}s; inject could not confirm a submit (supervisor pane busy or wedged). Buffer + wake-queue preserved; alarm marker written."
  {
    printf 'fm away-mode inject WEDGED: %ss undelivered as of %s\n' "$age" "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'The supervisor pane could not accept an escalation. Buffered items:\n'
    cat "$state/.subsuper-escalations" 2>/dev/null
  } > "$marker" 2>/dev/null || true
  # The display-message flash is useful only while someone happens to be
  # looking. Queue the alarm through the same durable wake primitive the normal
  # supervisor consumes, so its next turn sees this condition even if the
  # composer can never accept an injected digest. Source the full wake helper
  # in a subshell because this daemon normally imports its parsers only.
  payload="away-mode inject wedged ${age}s; buffered escalations preserved at $marker"
  (
    # shellcheck disable=SC2030 # deliberately subshell-local: scopes the override to this sourced call only
    FM_STATE_OVERRIDE="$state"
    export FM_STATE_OVERRIDE
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_DAEMON_DIR/fm-wake-lib.sh"
    fm_wake_append signal subsuper-inject-wedged "$payload"
  ) || log "ERROR: failed to enqueue durable inject-wedged wake"
  target="${FM_SUPERVISOR_TARGET:-$FM_SUPERVISOR_TARGET_DEFAULT}"
  tmux display-message -t "$target" "fm: away-mode escalations WEDGED ${age}s — see $marker" 2>/dev/null || true
}

_oldest_line_age() {  # <buf> -> seconds since the oldest buffered item first arrived (sidecar epoch)
  local f=$1 since
  [ -s "$f" ] || { echo 999999; return; }
  since="${f}.since"
  if [ -r "$since" ]; then
    echo $(( $(_now) - $(cat "$since" 2>/dev/null || echo 0) ))
  else
    echo 999999
  fi
}

# Run the read-only fleet stall detector (bin/fm-stall-check.sh) and buffer any
# NEW finding for escalation. This closes the gap present-mode firstmate does
# not have: at every heartbeat and every wake-handling turn it runs this same
# script by hand (AGENTS.md §8); away-mode had no equivalent, so an idle
# secondmate advisor (no status change to wake the signal/stale path on) and a
# child parked on needs-decision/blocked/failed inside a SEPARATE secondmate
# home's state dir (a dir the watcher never reads) were both invisible for an
# entire afk stretch.
#
# Full sweep only, never --fast: fm-stall-check.sh's --fast flag is defined to
# skip exactly check_advisor_idle_stalls and check_secondmate_child_escalations
# (they are the ones that shell out to fm-peek.sh per pane) — the two checks
# this integration exists to reach. A --fast tier on a tighter cadence would
# cost more ticks for zero additional coverage of the gap being closed, so one
# tier is used instead of a two-tier fast/full split.
#
# Cadence: measured against a fixture sized to a live fleet (7 secondmates, 14
# children total, everything idle — the worst case that forces every
# pane-peek path) the full sweep cost ~3.5s; at fresh/non-idle statuses (no
# pane-peek paths triggered) it cost ~1.5s. On FM_STALL_CHECK_SCAN_SECS's
# default 300s that is at most a ~1% duty cycle, so it is folded into the same
# housekeeping tick as the FM_HEARTBEAT_SCAN_SECS catch-all rather than the
# 15s HOUSEKEEPING_TICK — a large fleet with many idle advisors would otherwise
# spend a meaningful fraction of every tick shelling out to tmux for no new
# information.
#
# THE GOVERNING PRINCIPLE FOR THIS FUNCTION'S MARKER LIFECYCLE: an escalation
# may be deduplicated, but it may NEVER be permanently suppressed by anything
# other than the condition actually going away.
#
# Dedup: fm-stall-check.sh is a re-firing verify-candidate emitter with no ack
# mechanism (its own header says so) — every sweep re-prints a persisting
# condition. A marker file per _stall_finding_key (kind+id) collapses that into
# one escalation per re-alarm window instead of one per tick. Three rules keep
# that dedup from becoming suppression:
#
#   - Re-alarm, never mute. A marker only silences its finding for
#     FM_STALL_REALARM_SECS (the same re-alarm-once-per-window pattern
#     inject_wedge_alarm uses, on its own knob so the two windows cannot
#     collide). Once a marker is that old and the sweep is STILL emitting the
#     finding, the condition is demonstrably unresolved — firstmate's answer to
#     the first alarm never landed, which is a real path (fm-send.sh refuses a
#     dead pane) — so it escalates again and the marker's stamp is refreshed. A
#     repeat alarm on a genuinely unresolved condition is correct, not spam.
#   - Absence must be corroborated. A marker is cleared only after the finding
#     is missing from STALL_CHECK_MISSES_TO_CLEAR consecutive sweeps, counted
#     in a per-key .subsuper-stallcheck-miss-<key> sidecar. One flapping sweep
#     therefore neither resolves the finding nor re-escalates it: a key that
#     reappears after a single miss keeps its existing marker and re-alarm
#     stamp, so it costs no firstmate turn.
#   - Only a real sweep is evidence. Everything above runs after the failed-
#     sweep early return below, so a sweep that could not run counts as neither
#     presence nor absence.
#
# After a corroborated clear, a later recurrence of the same kind+id is a fresh
# occurrence and escalates immediately.
#
# Failure is never silence: a sweep that cannot run (script missing after a
# partial self-update, lost executable bit, tmux unreachable) exits non-zero
# and prints nothing, which is indistinguishable from "all clear" unless the
# status is checked, so the sweep is run through a command substitution (a
# process substitution discards its exit status) with stderr captured. On a
# failed sweep the daemon logs an ERROR like every other failure path here and
# returns WITHOUT clearing markers: an empty failure output must not be read as
# "every finding resolved", which would both hide the outage and re-escalate
# the whole set once the sweep recovers.
stall_check_scan() {  # <state>
  local state=$1 home line key marker miss misses age now_s realarm current="" added=0 out err diag rc=0
  home=$(dirname "$state")
  err=$(mktemp "${TMPDIR:-/tmp}/fm-stallcheck.XXXXXX") || {
    log "ERROR: stall-check sweep skipped: mktemp failed; away-mode stall findings unavailable this tick (dedup markers preserved)"
    return 1
  }
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$FM_DAEMON_DIR/fm-stall-check.sh" 2>"$err") || rc=$?
  diag=$(tr '\n\t' '  ' < "$err" 2>/dev/null | cut -c1-300)
  rm -f "$err"
  if [ "$rc" -ne 0 ]; then
    log "ERROR: stall-check sweep failed (rc=$rc); away-mode stall findings unavailable this tick (dedup markers preserved): ${diag:-no stderr}"
    return 1
  fi
  now_s=$(_now)
  realarm=${FM_STALL_REALARM_SECS:-$STALL_REALARM_SECS_DEFAULT}
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=$(_stall_finding_key "$line")
    current="$current $key"
    marker="$state/.subsuper-seen-stallcheck-$key"
    rm -f "$state/.subsuper-stallcheck-miss-$key"
    if [ -e "$marker" ]; then
      age=$(( now_s - $(_read_int "$marker" 0) ))
      if [ "$realarm" -gt 0 ] && [ "$age" -lt "$realarm" ]; then
        continue
      fi
      log "escalate: stall-check re-alarm after ${age}s unresolved -> $line"
    else
      log "escalate: stall-check -> $line"
    fi
    escalate_add "$state" "$line"
    printf '%s\n' "$now_s" > "$marker"
    added=1
  done <<< "$out"
  for marker in "$state"/.subsuper-seen-stallcheck-*; do
    [ -e "$marker" ] || continue
    key="${marker##*.subsuper-seen-stallcheck-}"
    case " $current " in
      *" $key "*) continue ;;
    esac
    miss="$state/.subsuper-stallcheck-miss-$key"
    misses=$(( $(_read_int "$miss" 0) + 1 ))
    if [ "$misses" -ge "$STALL_CHECK_MISSES_TO_CLEAR" ]; then
      rm -f "$marker" "$miss"
    else
      printf '%s\n' "$misses" > "$miss"
    fi
  done
  # Mirror handle_wake's escalate path: attempt an immediate flush when
  # batching is disabled, rather than waiting for job (1)'s own batch-flush
  # check, which already ran earlier in this same housekeeping() tick.
  if [ "$added" = 1 ] && [ "${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" -le 0 ]; then
    escalate_flush "$state" || true
  fi
}

# --- housekeeping (runs every tick while the watcher is mid-cycle) ----------
# Five cheap jobs, each guarded so an empty/quiet fleet costs near zero:
#  1) batch flush: if the escalation buffer's oldest content is older than
#     ESCALATE_BATCH_SECS (or batching is disabled), inject one digest.
#  1b) max-defer escape: if the buffer is STILL undelivered past MAX_DEFER_SECS,
#     attempt one normal delivery, then one idle-only Escape probe if the guard
#     remains pending. It retries only after the probe reads empty; real text
#     remains untouched. Otherwise raise a wedge alarm plus durable wake.
#  2) stale recheck: for each pending stale marker past STALE_ESCALATE_SECS,
#     re-peek the pane; still idle -> escalate (wedge); resumed -> clear marker.
#  3) heartbeat scan: every HEARTBEAT_SCAN_SECS, grep state/*.status for a
#     captain-relevant line the per-wake classifier missed and escalate it.
#  4) stall-check scan: every FM_STALL_CHECK_SCAN_SECS, run the full
#     bin/fm-stall-check.sh sweep and escalate any new finding (see
#     stall_check_scan). Detection runs unconditionally, like (3); only
#     delivery is afk-gated (escalate_flush -> inject_msg), so afk-inactive
#     behavior is unchanged from before this integration.
housekeeping() {  # <state>
  local state=$1 now due f key task win marker age raw last max_defer oldest
  now=$(_now)

  # (1) batch flush
  if [ "${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" -le 0 ]; then
    escalate_flush "$state" || true
  else
    due=$(_oldest_line_age "$state/.subsuper-escalations")
    if [ "$due" -ge "${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" ]; then
      escalate_flush "$state" || true
    fi
  fi

  # (1b) max-defer escape. If the normal path still cannot deliver, an
  # idle-only Escape probe gets exactly one chance to dismiss a false-positive
  # UI layer. It never clears or types into remaining human input.
  max_defer=${FM_MAX_DEFER_SECS:-$MAX_DEFER_SECS_DEFAULT}
  if afk_active "$state" && [ "$max_defer" -gt 0 ] && [ -s "$state/.subsuper-escalations" ]; then
    oldest=$(_oldest_line_age "$state/.subsuper-escalations")
    # Throttle the alarm to once per max-defer window (the wedge marker doubles
    # as the throttle). A successful flush clears the buffer; a failed one alarms
    # and waits.
    if [ "$oldest" -ge "$max_defer" ] \
       && [ "$(_file_age "$state/.subsuper-inject-wedged")" -ge "$max_defer" ]; then
      if escalate_flush "$state" || max_defer_escape_recover "$state"; then
        log "inject recovered: max-defer flush succeeded after ${oldest}s undelivered"
        rm -f "$state/.subsuper-inject-wedged"
      else
        inject_wedge_alarm "$state" "$oldest"
      fi
    fi
  fi

  # (2) stale persistence recheck
  for marker in "$state"/.subsuper-stale-*; do
    [ -e "$marker" ] || continue
    key="${marker##*.subsuper-stale-}"
    age=$(( now - $(cat "$marker" 2>/dev/null || echo "$now") ))
    [ "$age" -ge "${FM_STALE_ESCALATE_SECS:-$STALE_ESCALATE_SECS_DEFAULT}" ] || continue
    # Reconstruct the window name from the key (best-effort: session is unknown,
    # so probe the live fm-* windows for one whose task matches).
    win=$(window_for_task "$key" 2>/dev/null || true)
    if [ -z "$win" ]; then
      # Window gone (task torn down): drop the marker, nothing to escalate.
      rm -f "$marker"; continue
    fi
    if pane_is_busy "$win"; then
      rm -f "$marker"   # crewmate resumed: benign
    else
      escalate_add "$state" "stale persisted ${age}s (possible wedge): $win"
      stale_marker_remove "$win" "$state"
    fi
  done

  # (3) heartbeat scan (catch-all for a captain-relevant status the per-wake
  #     classifier may have missed). Cheap: status files only, no tmux.
  if [ "$(_file_age "$state/.subsuper-last-scan")" -ge "${FM_HEARTBEAT_SCAN_SECS:-$HEARTBEAT_SCAN_SECS_DEFAULT}" ]; then
    _now > "$state/.subsuper-last-scan"
    for f in "$state"/*.status; do
      [ -e "$f" ] || continue
      raw=$(last_status_line "$f")
      last=$(fm_receipt_text "$raw")
      status_is_captain_relevant "$last" || continue
      task=$(basename "$f"); task="${task%.status}"
      local seen
      seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
      [ "$(cat "$seen" 2>/dev/null || true)" = "$raw" ] && continue
      escalate_add "$state" "$(basename "$f"): $last (catch-all scan)"
      mark_status_seen "$state" "$task" "$raw"
    done
  fi

  # (4) stall-check scan (see stall_check_scan for the full rationale).
  if [ "$(_file_age "$state/.subsuper-last-stallcheck")" -ge "${FM_STALL_CHECK_SCAN_SECS:-$STALL_CHECK_SCAN_SECS_DEFAULT}" ]; then
    _now > "$state/.subsuper-last-stallcheck"
    stall_check_scan "$state"
  fi
}

# Find a live fm-* window whose task id matches the given marker key.
window_for_task() {  # <task-key>
  local key=$1 w t
  for w in $(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep ':fm-' || true); do
    t=$(window_to_task "$w")
    [ "$(_stale_key "$t")" = "$key" ] && { printf '%s' "$w"; return 0; }
  done
  return 1
}

# --- injection --------------------------------------------------------------
# inject_msg: send one escalation digest to the supervisor pane.
# Returns 0 on successful inject (or empty buffer), non-zero if the pane is
# gone, the supervisor is busy, afk is inactive, or the verified submit cannot
# be confirmed after bounded retries. On non-zero the caller preserves
# the buffer so the escalation survives for the next cycle or the catch-up flush.
#
# Submit model:
#   - TYPE ONCE, then submit with Enter. Never retype the digest: a swallowed
#     Enter leaves our text in the composer, and retyping would concatenate two
#     sentinel-prefixed digests into one corrupted turn.
#   - SUBMIT ACK = the dim-ghost-aware and border-aware composer detector reports
#     empty after Enter.
#     Empty means the text was consumed; pending means Enter was swallowed; unknown
#     is treated as undelivered by this strict daemon path.
#   - COMPOSER GUARD before typing: if the cursor line already has real content
#     after dim/faint ghost text and borders are ignored (a human's half-typed
#     line, or a previous injection's unsent text), defer entirely - injecting
#     would merge with the human's text.
inject_msg() {  # <message> [state]
  local msg=$1 state target retries sleep_s verdict
  state="${2:-$(_state_root)}"
  # (1) Presence-gate: inject ONLY when afk is active. When afk is off, the
  # daemon self-handles and stays quiet; firstmate drives the base one-shot
  # watcher. Escalations buffer and survive for the next catch-up flush.
  afk_active "$state" || { log "inject deferred: afk inactive"; return 1; }
  # (2) Single-line digest: collapse any embedded newlines so submission via
  # send-keys + Enter is unambiguous regardless of how the TUI composer treats
  # them. Then prepend the sentinel marker — firstmate's afk-exit contract
  # keys off its presence at the start of the message.
  msg=$(_collapse_newlines "$msg")
  msg="${FM_INJECT_MARK}${msg}"
  target="${FM_SUPERVISOR_TARGET:-$FM_SUPERVISOR_TARGET_DEFAULT}"
  fm_pane_exists "$target" || return 1
  # (3) Busy-guard: never inject into an in-use pane. Two checks:
  #   a) pane_is_busy: the harness shows a busy footer (agent mid-turn).
  #   b) pane_input_pending: the cursor line has real unsubmitted text after
  #      dim/faint ghost text and borders are ignored (a human's half-typed line,
  #      or a previous injection whose Enter was swallowed).
  if pane_is_busy "$target"; then
    log "inject deferred: supervisor pane busy (agent mid-turn)"
    return 1
  fi
  if pane_input_pending "$target"; then
    log "inject deferred: supervisor pane has pending input (non-empty composer)"
    return 1
  fi
  # (4) Type the digest ONCE, then submit with Enter (retry Enter only, never
  # retype) via the shared submit primitive. Success = the composer is confirmed
  # EMPTY afterward (the text was consumed). An unconfirmed/unknown pane does NOT
  # count as delivered, so the buffer is preserved (strict) rather than cleared.
  retries=${FM_INJECT_CONFIRM_RETRIES:-$INJECT_CONFIRM_RETRIES_DEFAULT}
  sleep_s=${FM_INJECT_CONFIRM_SLEEP:-$INJECT_CONFIRM_SLEEP_DEFAULT}
  verdict=$(fm_tmux_submit_core "$target" "$msg" "$retries" "$sleep_s" "$sleep_s")
  if [ "$verdict" = empty ]; then
    return 0  # Composer cleared → submit confirmed.
  fi
  log "inject failed: submit unconfirmed after $retries retries (verdict=$verdict, text may be in composer)"
  return 1
}

# max_defer_escape_recover: one bounded, idle-only recovery probe for the
# narrow case where the composer guard itself is stuck false-positive. Escape
# was verified on a disposable real Claude Code v2.1.224 pane: normal typed,
# unsubmitted text remained pending and byte-for-byte visible after one Escape.
# Therefore a remaining pending/unknown state is fail-closed: we never type,
# submit, or otherwise disturb it. If Escape dismisses a transient renderer/UI
# layer and the shared detector becomes empty, retry the ordinary strict path.
max_defer_escape_recover() {  # <state>
  local state=$1 target before after settle
  target="${FM_SUPERVISOR_TARGET:-$FM_SUPERVISOR_TARGET_DEFAULT}"
  fm_pane_exists "$target" || return 1
  [ "$(fm_pane_busy_state "$target")" = idle ] || return 1
  before=$(fm_tmux_composer_state "$target")
  [ "$before" = pending ] || return 1
  settle=${FM_INJECT_ESCAPE_SETTLE:-$INJECT_ESCAPE_SETTLE_DEFAULT}
  after=$(fm_tmux_composer_escape_probe "$target" "$settle")
  if [ "$after" != empty ]; then
    log "inject max-defer Escape probe left composer $after; preserving input and buffer"
    return 1
  fi
  log "inject max-defer Escape probe recovered an empty composer; retrying strict flush"
  escalate_flush "$state"
}

# --- INJECT_SKIP prefix match (literal prefixes, no regex) ------------------
should_force_self() {  # <reason>
  local reason=$1 skip="${FM_INJECT_SKIP:-$INJECT_SKIP_DEFAULT}" prefix
  [ -n "$skip" ] || return 1
  local -a prefixes
  IFS='|' read -ra prefixes <<<"$skip"
  for prefix in "${prefixes[@]}"; do
    [ -n "$prefix" ] || continue
    [ "$reason" != "${reason#"$prefix"}" ] && return 0
  done
  return 1
}

# A real watcher WAKE reason starts with one of these prefixes. Anything else on
# the watcher child's stdout (e.g. "watcher: already running" on a singleton-lock
# collision, reachable if the daemon was SIGKILL'd and its orphaned watcher child
# still holds the #29 singleton lock) is a STATUS line, not a wake: handling it
# as an unknown wake would flood the escalation buffer and restart the child with
# no crash backoff. The main loop treats a non-wake line as idle (log + sleep +
# continue), so a singleton collision cannot hot-loop escalations.
is_wake_reason() {  # <reason>
  local reason=$1
  case "$reason" in
    signal:*|stale:*|check:*|heartbeat|heartbeat:*) return 0 ;;
  esac
  return 1
}

# --- dispatch one wake reason to self-handle or escalate --------------------
# Side effects: logging, marker records, escalation buffer appends.
handle_wake() {  # <reason> <state>
  local reason=$1 state=$2 decision action distilled
  local kind="" arg="" detail=""
  if should_force_self "$reason"; then
    log "wake force-self (FM_INJECT_SKIP): $reason"
    return
  fi
  case "$reason" in
    signal:*) kind=signal; arg="${reason#signal: }"
              decision=$(classify_signal "$arg" "$state") ;;
    stale:*)  kind=stale; arg="${reason#stale: }"
              # A stale reason may carry a trailing annotation after the window
              # name ("<window> (no live agent process)"). Every consumer below
              # keys off a bare window, so split it here at the parse boundary.
              case "$arg" in
                *' ('*) detail="${arg#* (}"; arg="${arg%% (*}" ;;
              esac
              decision=$(classify_stale "$arg" "$state" "$detail") ;;
    check:*)  decision=$(classify_check "$reason") ;;
    heartbeat|heartbeat:*) decision=$(classify_heartbeat) ;;
    *)        decision=$(classify_unknown "$reason") ;;
  esac
  action=${decision%%|*}
  distilled=${decision#*|}
  if [ "$action" = "escalate" ]; then
    log "escalate: $reason -> $distilled"
    escalate_add "$state" "$distilled"
    # A terminal-stale escalate must not leave a persistence marker behind, or
    # housekeeping re-escalates the same pane as a false wedge later.
    [ "$kind" = "stale" ] && stale_marker_remove "$arg" "$state"
    mark_escalated_seen "$kind" "$arg" "$state"
    [ "${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" -le 0 ] && { escalate_flush "$state" || true; }
  else
    # Transient (non-terminal) stale: record/refresh the marker so housekeeping
    # can age it; the persistence recheck, not this wake, escalates a wedge.
    [ "$kind" = "stale" ] && stale_marker_record "$arg" "$state"
    log "self-handle: $reason -> $distilled"
  fi
}

# --- log --------------------------------------------------------------------
# Uses LOG set by fm_super_main; harmless no-op-ish if unset (tests source fns
# directly and pass state explicitly, so they do not call log).
log() { [ -n "${LOG:-}" ] && printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

trim_log() {
  local sz tmp
  [ -n "${LOG:-}" ] || return 0
  sz=$(wc -c < "$LOG" 2>/dev/null) || return 0
  [ "$sz" -ge "${FM_LOG_MAX_BYTES:-$LOG_MAX_BYTES_DEFAULT}" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-daemon-log.XXXXXX") || return 0
  tail -n "${FM_LOG_KEEP_LINES:-$LOG_KEEP_LINES_DEFAULT}" "$LOG" >"$tmp" 2>/dev/null && mv -f "$tmp" "$LOG"
}

# ============================================================================
# Everything below runs only when the script is EXECUTED, not sourced. The pure
# classifiers above are sourceable for unit tests (tests/fm-wake-queue.test.sh).
# ============================================================================

fm_super_main() {
  local STATE
  STATE="$(_state_root)"
  mkdir -p "$STATE"

  # shellcheck source=bin/fm-wake-lib.sh
  FM_STATE_OVERRIDE="$STATE" . "$FM_DAEMON_DIR/fm-wake-lib.sh"

  local WATCH="$FM_DAEMON_DIR/fm-watch.sh"
  local LOG="$STATE/.supervise-daemon.log"
  local WATCH_ERR="$STATE/.supervise-daemon.watcher.err"
  local LOCK="$STATE/.supervise-daemon.lock"
  local PIDFILE="$STATE/.supervise-daemon.pid"
  local INJECT_FAIL_SLEEP=${FM_INJECT_FAIL_SLEEP:-$INJECT_FAIL_SLEEP_DEFAULT}
  local CRASH_THRESHOLD=${FM_CRASH_THRESHOLD:-$CRASH_THRESHOLD_DEFAULT}
  local CRASH_WINDOW=${FM_CRASH_WINDOW:-$CRASH_WINDOW_DEFAULT}
  local CRASH_BACKOFF=${FM_CRASH_BACKOFF:-$CRASH_BACKOFF_DEFAULT}
  local CRASH_NORMAL_SLEEP=${FM_CRASH_NORMAL_SLEEP:-$CRASH_NORMAL_SLEEP_DEFAULT}

  [ -x "$WATCH" ] || { echo "error: watcher not found or not executable: $WATCH" >&2; exit 1; }

  # --- single instance (portable mkdir-based lock, no flock dependency) ------
  if ! fm_lock_try_acquire "$LOCK"; then
    if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
      echo "error: another fm-supervise-daemon is already running (pid $FM_LOCK_HELD_PID, lock $LOCK held)" >&2
    else
      echo "error: another fm-supervise-daemon is already running (lock $LOCK held)" >&2
    fi
    exit 1
  fi
  echo "$$" > "$PIDFILE"

  # --- auto-discover the supervisor target (the pane running firstmate) -----
  # Priority: FM_SUPERVISOR_TARGET override > $TMUX_PANE (inherited from the
  # pane that launched the daemon, normally firstmate's own) > firstmate:0
  # fallback. Exporting the result into FM_SUPERVISOR_TARGET makes inject_msg
  # (which reads that env var) use the discovered pane without an extra global.
  local discovered target_source
  target_source="FM_SUPERVISOR_TARGET"
  if [ -z "${FM_SUPERVISOR_TARGET:-}" ]; then
    if [ -n "${TMUX_PANE:-}" ]; then
      target_source="TMUX_PANE"
    else
      target_source="FALLBACK(firstmate:0)"
    fi
  fi
  if discovered=$(discover_supervisor_target); then
    : # resolved cleanly
  else
    echo "warn: could not auto-discover supervisor pane (no FM_SUPERVISOR_TARGET or TMUX_PANE); falling back to '$discovered' — verify this is firstmate's pane" >&2
  fi
  FM_SUPERVISOR_TARGET="$discovered"
  local TARGET="$FM_SUPERVISOR_TARGET"

  # --- validate supervisor target at startup (a missing target is a typo) ---
  if ! fm_pane_exists "$TARGET"; then
    echo "error: supervisor target '$TARGET' does not resolve to a tmux pane; set FM_SUPERVISOR_TARGET" >&2
    log "startup failed: target '$TARGET' not found"
    fm_lock_release "$LOCK" 2>/dev/null || true
    rm -f "$PIDFILE" 2>/dev/null || true
    exit 1
  fi

  local afk_status="off"
  afk_active "$STATE" && afk_status="on"
  log "daemon starting (pid $$); target=$TARGET; target_source=$target_source; afk=$afk_status; inject_skip='${FM_INJECT_SKIP:-$INJECT_SKIP_DEFAULT}'; stale_escalate=${FM_STALE_ESCALATE_SECS:-$STALE_ESCALATE_SECS_DEFAULT}s; batch=${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}s"

  # --- shutdown: flush buffered escalations, reap child, release lock -------
  local WATCHER_PID="" CUR_TMP=""
  cleanup() {
    trap - TERM INT
    escalate_flush "$STATE" 2>/dev/null || true
    if [ -n "${WATCHER_PID:-}" ]; then
      kill "$WATCHER_PID" 2>/dev/null || true
      wait "$WATCHER_PID" 2>/dev/null || true
    fi
    if [ -n "${CUR_TMP:-}" ]; then
      rm -f "$CUR_TMP" 2>/dev/null || true
    fi
    fm_lock_release "$LOCK" 2>/dev/null || true
    rm -f "$PIDFILE" 2>/dev/null || true
    log "daemon shutting down"
    exit 0
  }
  trap cleanup TERM INT

  # --- crash-loop guard -----------------------------------------------------
  local crash_times=() backoff_secs=$CRASH_NORMAL_SLEEP
  record_crash() {
    local now t
    now=$(_now)
    local -a keep=()
    for t in "${crash_times[@]:-}"; do
      [ -n "$t" ] && [ $((now - t)) -lt "$CRASH_WINDOW" ] && keep+=("$t")
    done
    keep+=("$now")
    crash_times=("${keep[@]}")
    if [ "${#crash_times[@]}" -gt "$CRASH_THRESHOLD" ]; then
      log "ERROR: watcher crashed ${#crash_times[@]} times within ${CRASH_WINDOW}s; backing off ${CRASH_BACKOFF}s"
      crash_times=()
      backoff_secs=$CRASH_BACKOFF
    else
      backoff_secs=$CRASH_NORMAL_SLEEP
    fi
  }

  start_watcher() {
    CUR_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-watch.XXXXXX") || { log "error: mktemp failed; retrying in 5s"; sleep 5; return 1; }
    "$WATCH" >"$CUR_TMP" 2>>"$WATCH_ERR" &
    WATCHER_PID=$!
  }

  local rc reason
  while true; do
    # --- pane-gone guard (preserved) ---------------------------------------
    # With the #29 watcher's enqueue-before-suppress, a wake is no longer
    # swallowed by running the watcher with no injection target. We still back
    # off while the pane is gone: self-handling needs no pane, but escalation
    # has nowhere to go, and firstmate itself is the consumer of escalations.
    # Catch-up signals persist in state/*.status and flow on the next run, so
    # this delays rather than loses work.
    if ! fm_pane_exists "$TARGET"; then
      log "warn: supervisor target '$TARGET' gone; backing off ${INJECT_FAIL_SLEEP}s, will retry"
      # Flush is pointless with no pane; preserve any buffered escalations.
      sleep "$INJECT_FAIL_SLEEP"
      continue
    fi

    # --- (re)start watcher if it has exited --------------------------------
    if [ -z "${WATCHER_PID:-}" ] || ! kill -0 "${WATCHER_PID:-}" 2>/dev/null; then
      if [ -n "${WATCHER_PID:-}" ]; then
        # child exited: reap + classify its wake reason
        if wait "${WATCHER_PID}"; then rc=0; else rc=$?; fi
        reason=""
        if [ -n "${CUR_TMP:-}" ] && [ -e "${CUR_TMP:-}" ]; then
          reason=$(<"${CUR_TMP}")
        fi
        if [ -n "${CUR_TMP:-}" ]; then
          rm -f "${CUR_TMP}" 2>/dev/null || true
        fi
        CUR_TMP=""
        if [ "$rc" -ne 0 ] || [ -z "$reason" ]; then
          record_crash
          log "watcher exited rc=$rc reason='$reason'; restarting after ${backoff_secs}s"
          WATCHER_PID=""
          sleep "$backoff_secs"
          continue
        fi
        # Non-wake stdout (e.g. a watcher singleton-collision "already running"
        # status line) is NOT a wake: idling here prevents an escalation flood
        # and a backoff-less child restart. record_crash is intentionally
        # skipped (rc=0, this is normal idle, not a crash).
        if ! is_wake_reason "$reason"; then
          log "watcher non-wake stdout, idling: $reason"
          WATCHER_PID=""
          sleep "${HOUSEKEEPING_TICK:-$HOUSEKEEPING_TICK_DEFAULT}"
          continue
        fi
        log "wake: $reason"
        handle_wake "$reason" "$STATE"
        trim_log
      fi
      start_watcher || continue
    fi

    # --- one housekeeping tick (gated to HOUSEKEEPING_TICK), then poll -------
    # The watcher child runs on its own FM_POLL cadence internally; we only need
    # to detect its exit (the kill -0 above) promptly and run housekeeping often
    # enough that batch flushes, stale rechecks, and the catch-all scan fire on
    # cadence. Gating keeps a large fleet cheap between ticks.
    sleep 1
    if [ "$(_file_age "$STATE/.subsuper-last-housekeep")" -ge "${FM_HOUSEKEEPING_TICK:-$HOUSEKEEPING_TICK_DEFAULT}" ]; then
      _now > "$STATE/.subsuper-last-housekeep"
      housekeeping "$STATE"
    fi
  done
}

# Run only when executed, not when sourced (tests source the classifiers).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_super_main "$@"
fi
