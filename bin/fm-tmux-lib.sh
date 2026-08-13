#!/usr/bin/env bash
# fm-tmux-lib.sh — shared tmux pane primitives for firstmate.
#
# ONE source of truth for: busy detection, composer-empty (pending-input)
# detection, agent process-tree liveness, Codex safety-prompt clearing, and a
# verify-and-retry-Enter submit.
# Sourced by the watcher, the away-mode daemon (bin/fm-supervise-daemon.sh), and
# bin/fm-send.sh so the pane/composer logic cannot drift between callers.
#
# Why this exists (incident afk-invx-i5): the daemon's old composer check only
# recognized a BARE prompt glyph ("> ") as an empty composer. claude draws its
# input box with box-drawing borders ("│ > … │"), so every idle claude pane read
# as "pending input" and the away-mode daemon deferred 100% of escalations for
# 9.5 hours with no escape. The detector below strips the box borders before
# deciding, so a bordered-but-empty composer is correctly seen as empty. The same
# corrected detector backs the submit acknowledgement (a submit "landed" iff the
# composer is empty afterward), fixing the parallel false "Enter swallowed".
#
# Ghost text (incident composer-robust): claude renders a predicted-next-prompt
# "suggestion" as dim/faint text inside an otherwise-empty composer. A plain
# capture cannot tell it apart from text a human typed, so the old reader saw an
# idle pane as holding pending input and the daemon deferred injection / firstmate
# misjudged the pane. The composer reader captures the visible pane WITH ANSI
# styling (tmux capture-pane -e), drops dim/faint (SGR 2) runs from it, then finds
# the prompt-bearing composer row in the result before deciding. This recognizes rendered
# placeholders without maintaining a brittle list of another program's UI strings.
# The styled capture is consumed internally and parsed into a boolean here; it is
# NEVER surfaced (fm-peek and every human/LLM-facing path stay plain). This is
# harness-generic: any harness that dims placeholder/ghost text benefits.
#
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer after
# dim-ghost and structural border stripping. FM_BUSY_REGEX overrides the busy
# footer set (mirrors fm-watch.sh / the daemon).
#
# All functions are `set -u` and `set -e` safe (guarded tmux calls, explicit
# returns) so they can be sourced into either context.

FM_TMUX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Busy footers per harness (mirror fm-watch.sh). claude/codex: "esc to
# interrupt"; opencode: "esc interrupt"; pi: "Working...".
FM_TMUX_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.'

# fm_pane_agent_state: classify a tmux pane as alive, dead, or unknown.
# A pane is alive when its root PID is an ancestor of any verified harness
# process. Foreground child commands therefore cannot hide the still-live agent.
#
# Uses `list-panes -t`, never `display-message -t`: display-message silently
# falls back to the CLIENT's current pane when the target window/session does
# not exist (verified on tmux 3.6 - no error, exit 0, wrong pane's data), which
# is exactly how a gone-9-days secondmate window once reported healthy with the
# supervisor's own pid. list-panes -t fails loudly ("can't find window/session")
# for a target that is genuinely gone, so that case maps to a firm 'dead'
# instead of inheriting whatever window happens to be active right now.
fm_pane_agent_state() { # <target>
  local target=$1 out rc pane_pid
  out=$(tmux list-panes -t "$target" -F '#{pane_pid}' 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      "can't find"*) printf 'dead'; return 0 ;;
      *) printf 'unknown'; return 0 ;;
    esac
  fi
  pane_pid=$(printf '%s\n' "$out" | head -n1)
  case "$pane_pid" in
    ''|*[!0-9]*) printf 'unknown'; return 0 ;;
  esac
  if "$FM_TMUX_LIB_DIR/fm-harness.sh" agent-in-tree "$pane_pid" >/dev/null 2>&1; then
    printf 'alive'
  else
    rc=$?
    [ "$rc" -eq 1 ] && printf 'dead' || printf 'unknown'
  fi
}

fm_pane_current_command() { # <target>
  tmux list-panes -t "$1" -F '#{pane_current_command}' 2>/dev/null | head -n1
}

# fm_pane_exists: 0 when <target> resolves to a pane that is really there.
# Same primitive rule as fm_pane_agent_state: `display-message -t` answers for
# the client's current pane when the target window/session is gone, so it can
# never prove presence; `list-panes -t` fails for a target that is gone.
fm_pane_exists() { # <target>
  [ -n "${1:-}" ] || return 1
  tmux list-panes -t "$1" >/dev/null 2>&1
}

# fm_tmux_strip_ghost: remove dim/faint (ANSI SGR 2) styled runs from one captured
# composer line, then drop any remaining escape sequences, leaving only the plain,
# normal-intensity text, the text a human actually typed. Dim/faint runs are
# ghost/placeholder text (e.g. claude's predicted-next-prompt suggestion) that
# fills an otherwise-empty composer and must never read as pending input. Reads the
# styled line on stdin (from `tmux capture-pane -e`) and prints plain text on
# stdout. LC_ALL=C makes awk walk bytes, so multibyte glyphs (e.g. ❯) and dim runs
# alike pass through or drop intact without locale-dependent character classes.
# A reset (SGR 0) or normal-intensity (SGR 22) ends a dim run; codes are processed
# left to right within a sequence so "ESC[0;2m" (reset then dim) reads as dim.
fm_tmux_strip_ghost() {  # [keep-dim]
  LC_ALL=C awk -v keepdim="${1:-}" '
    function sgr_code(v, b) {
      b = v
      sub(/:.*/, "", b)
      if (b == "") b = "0"
      return b
    }
    function skip_color_payload(a, p, k, mode, code) {
      if (index(a[p], ":") > 0) return p
      if (p >= k) return p
      mode = a[p + 1]
      code = sgr_code(mode)
      if (index(mode, ":") > 0) return p + 1
      if (code == "5") return p + 2
      if (code == "2") return p + 4
      return p + 1
    }
    {
      line = $0; out = ""; dim = 0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033") {            # ESC: consume a CSI ... final-byte sequence
          j = i + 1
          if (substr(line, j, 1) == "[") {
            j++; params = ""
            while (j <= n) {
              cc = substr(line, j, 1)
              if (cc ~ /[@-~]/) break
              params = params cc; j++
            }
            if (j <= n && substr(line, j, 1) == "m") {   # SGR: update dim/faint state
              if (params == "") params = "0"
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38" || code == "48" || code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") dim = 1
                else if (code == "0" || code == "22") dim = 0
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue          # lone/other ESC: drop the ESC byte only
        }
        if (dim == 0 || keepdim != "") out = out c   # keep normal-intensity bytes
        i++
      }
      print out
    }
  '
}

# fm_tmux_has_paste_chip: recognize a harness's collapsed paste marker. A paste
# chip is REAL unsubmitted content no matter how it is rendered, so it must never
# be treated as ghost text: some harnesses draw it dim/faint, which would
# otherwise erase it and make a full composer look empty (a false submit ack).
# This is a structural marker, not a suggestion-text allowlist.
fm_tmux_has_paste_chip() {  # <text>
  case "$1" in
    *'[Pasted Content '*' chars]'*) return 0 ;;
    *'[Pasted text '*' chars]'*) return 0 ;;
  esac
  return 1
}

# fm_tmux_is_composer_line: return success when a normalized visible-pane row is
# structurally a composer. Two shapes qualify: a row whose first non-border,
# non-whitespace character is a prompt glyph (Codex and pi use ›/❯; claude's
# bordered composer uses │ > ... │; a bare > covers simple TUIs), and a bordered
# row that holds nothing at all (claude renders an idle composer that way once
# its dim ghost suggestion is stripped). Requiring the glyph to come first
# deliberately avoids treating output that merely mentions one as a composer.
# Borders are removed by literal-string substitution per glyph, never by a
# single-character pattern: `${line#?}` drops one CHARACTER, which under the
# C/POSIX locale (an unset LANG, as a nohup'd supervisor or cron job sees) is one
# BYTE, leaving the tail of a 3-byte │ behind and hiding every claude composer.
fm_tmux_is_composer_line() {  # <normalized line>
  local line=$1 inner
  line=${line//$'\302\240'/ }
  line=${line//$'\342\200\257'/ }
  line="${line#"${line%%[![:space:]]*}"}"
  case "$line" in
    '›'|'› '*|'❯'|'❯ '*|'>'|'> '*) return 0 ;;
  esac
  case "$line" in
    '│'*|'┃'*|'|'*) ;;
    *) return 1 ;;
  esac
  inner=${line//│/}
  inner=${inner//┃/}
  inner=${inner//|/}
  inner="${inner#"${inner%%[![:space:]]*}"}"
  inner="${inner%"${inner##*[![:space:]]}"}"
  [ -n "$inner" ] || return 0
  case "$inner" in
    '›'|'› '*|'❯'|'❯ '*|'>'|'> '*) return 0 ;;
  esac
  return 1
}

# fm_tmux_composer_text: print the normalized composer line of <target>.
# Codex draws its status footer BELOW the composer, so cursor_y points at the
# footer rather than the input; trusting it reads a dim footer as an empty
# composer and fakes a submit acknowledgement. So scan the visible styled pane
# and select the lowest structural composer row (fm_tmux_is_composer_line).
# Only when the pane shows no such row at all does cursor_y decide, which keeps
# a blank cursor line, a shell prompt, and a harness whose idle composer needs
# FM_COMPOSER_IDLE_RE readable instead of collapsing them all into 'unknown'.
# A row's collapsed paste chip is kept even when the harness renders it dim,
# because it is unsubmitted content rather than a placeholder.
# The result has dim/faint ghost text removed, composer borders stripped, NBSP and
# narrow-NBSP prompt padding normalized to spaces, and surrounding whitespace
# trimmed. Returns non-zero only when the pane's state cannot be established.
# The whole capture is de-ghosted in ONE awk pass, not once per row: these reads
# are hot (every Enter retry, every daemon inject attempt) and fork/exec is not.
# That is byte-identical to per-row stripping because the awk program resets its
# dim state at the start of every input record.
fm_tmux_composer_text() {  # <target>
  local target=$1 raw plain line stripped cy idx i n rows
  raw=$(tmux capture-pane -e -p -t "$target" 2>/dev/null) || return 1
  plain=$(printf '%s\n' "$raw" | fm_tmux_strip_ghost)
  local -a rows_plain rows_raw
  rows_plain=(); rows_raw=()
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    rows_plain[$n]=$line
    n=$((n + 1))
  done <<EOF
$plain
EOF
  rows=0
  while IFS= read -r line || [ -n "$line" ]; do
    rows_raw[$rows]=$line
    rows=$((rows + 1))
  done <<EOF
$raw
EOF
  idx=-1
  i=0
  while [ "$i" -lt "$n" ]; do
    fm_tmux_is_composer_line "${rows_plain[$i]}" && idx=$i
    i=$((i + 1))
  done
  if [ "$idx" -lt 0 ]; then
    cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || return 1
    case "$cy" in ''|*[!0-9]*) return 1 ;; esac
    # A cursor past the captured rows means nothing is drawn there: an empty
    # composer, the same answer a single-row capture of that line would give.
    [ "$cy" -lt "$n" ] || { printf ''; return 0; }
    idx=$cy
  fi
  line=${rows_plain[$idx]}
  if [ "$idx" -lt "$rows" ] && fm_tmux_has_paste_chip "${rows_raw[$idx]}"; then
    line=$(printf '%s\n' "${rows_raw[$idx]}" | fm_tmux_strip_ghost keep-dim)
  fi
  # Strip the composer box borders (literal glyphs — no character classes).
  stripped=${line//│/}      # U+2502 light vertical (claude)
  stripped=${stripped//┃/}  # U+2503 heavy vertical
  stripped=${stripped//|/}  # ASCII pipe
  # Some TUIs pad a bare prompt with NBSP/narrow NBSP. Normalize them before the
  # ASCII trim below so "❯ " is still an empty prompt, not pending input.
  stripped=${stripped//$'\302\240'/ }
  stripped=${stripped//$'\342\200\257'/ }
  # Trim surrounding whitespace.
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  printf '%s' "$stripped"
}

# fm_tmux_composer_state: classify the prompt-bearing composer line of <target> as
#   empty   - no pending input (blank, a bare prompt, or only dim
#             ghost/placeholder text). Safe to inject; also the positive
#             acknowledgement that a submit landed.
#   pending - real, unsubmitted text on the cursor line (a human mid-typing, or a
#             previous injection whose Enter was swallowed). Defer / retry.
#   unknown - the composer's state could not be established: the pane could not
#             be read (tmux error), cursor_y was unavailable or unusable for a
#             pane showing no composer row, or a busy footer landed on the
#             selected row. None of those can confirm a submit, since a prior
#             turn may still be finishing with our text unsubmitted, and none of
#             them is safe to type into - see fm_pane_input_pending.
#
# The visible pane is captured WITH ANSI styling (capture-pane -e); its lowest
# structural composer row wins, even when a Codex footer is drawn below it. The
# capture is run through fm_tmux_strip_ghost so dim/faint ghost text drops out
# before both row selection and classification. The styled capture is internal
# only, never surfaced. The detector then strips the harness's box-drawing
# composer borders ("│ … │", heavy "┃", or a plain ASCII "|") using
# literal-string substitution (bash 3.2 safe, locale-independent — no \u escapes,
# no multibyte character classes), and asks whether anything real is left.
#
# 'empty' is the submit acknowledgement, so it is only ever reported for a row
# that was actually located and actually holds nothing. Any row that carries
# real text classifies as pending or unknown, never empty, whether it was found
# by prompt glyph or by the cursor_y fallback.
fm_tmux_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 stripped
  stripped=$(fm_tmux_composer_text "$target") || { printf 'unknown'; return 0; }
  # Nothing left inside the box = empty composer.
  [ -n "$stripped" ] || { printf 'empty'; return 0; }
  if [ -n "${FM_COMPOSER_IDLE_RE:-}" ] \
     && printf '%s' "$stripped" | grep -qiE "$FM_COMPOSER_IDLE_RE"; then
    printf 'empty'; return 0
  fi
  # Just a bare prompt glyph = empty composer (idle).
  case "$stripped" in
    '>'|'❯'|'›'|'$'|'%'|'#') printf 'empty'; return 0 ;;
  esac
  # A busy footer on the cursor row is not composer evidence. It cannot confirm
  # a submit because a prior turn may still be finishing with text unsubmitted.
  if printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    printf 'unknown'; return 0
  fi
  printf 'pending'; return 0
}

# fm_pane_input_pending: 0 when it is NOT safe to type into <target> - the
# composer holds real unsubmitted text, or its state could not be established.
# 'unknown' counts as pending on purpose. This is the one caller where the two
# answers are not symmetric: injecting into a pane we cannot read can overwrite a
# human's half-typed line, while deferring an escalation only delays it (and the
# away-mode daemon's max-defer path exists for exactly that). Only a composer
# positively confirmed empty is safe to type into.
fm_pane_input_pending() {  # <target>
  case "$(fm_tmux_composer_state "$1")" in
    pending|unknown) return 0 ;;
  esac
  return 1
}

# fm_tmux_composer_escape_probe: send one Escape to a PENDING composer, then
# report its state after a short settle. This is deliberately NOT a general
# clear operation: callers must still treat pending/unknown as unsafe and must
# never type into either state. It exists for the away-mode daemon's max-defer
# recovery only. On a real Claude Code v2.1.224 pane, one Escape left normal
# unsubmitted text intact (pending before and after), while it can dismiss a
# transient UI layer that is being mistaken for composer text.
fm_tmux_composer_escape_probe() {  # <target> [settle-seconds] -> empty|pending|unknown
  local target=$1 settle=${2:-0.1} state
  state=$(fm_tmux_composer_state "$target")
  [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
  tmux send-keys -t "$target" Escape 2>/dev/null || { printf 'unknown'; return 0; }
  sleep "$settle"
  fm_tmux_composer_state "$target"
}

# fm_pane_busy_state: print busy, idle, or unknown after scanning a 40-line tail.
fm_pane_busy_state() {  # <target>
  local win=$1 tail40
  tail40=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  if printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    printf 'busy'
  else
    printf 'idle'
  fi
}

# fm_pane_is_busy: 0 if the pane's last few non-blank lines show a busy footer
# (an agent mid-turn). Scans a 40-line tail like fm-watch.sh.
fm_pane_is_busy() {  # <target>
  [ "$(fm_pane_busy_state "$1")" = busy ]
}

# fm_tmux_safety_prompt_selection: recognize Codex's active
# `safety-buffering-prompt` menu on stdin and print the selected safe-action
# state (retry|waiting). The full ordered menu and confirmation footer are
# required, not merely the title/option words, so agent output discussing the
# dialog cannot trigger keypresses. Only Retry and Keep waiting are actionable;
# a menu already highlighting Learn more is deliberately ignored.
fm_tmux_safety_prompt_selection() {
  LC_ALL=C awk '
    BEGIN { stage = 0; choice = "" }
    /^[[:space:]]*Additional safety checks[[:space:]]*$/ {
      stage = 1; choice = ""; next
    }
    stage == 1 && /^[[:space:]]*>?[[:space:]]*1\.[[:space:]]+Retry with a faster model[[:space:]]*$/ {
      if ($0 ~ /^[[:space:]]*>/) choice = "retry"
      stage = 2; next
    }
    stage == 2 && /^[[:space:]]*>?[[:space:]]*2\.[[:space:]]+Keep waiting[[:space:]]*$/ {
      if ($0 ~ /^[[:space:]]*>/) choice = "waiting"
      stage = 3; next
    }
    stage == 3 && /^[[:space:]]*>?[[:space:]]*3\.[[:space:]]+Learn more[[:space:]]*$/ {
      if ($0 ~ /^[[:space:]]*>/) choice = "other"
      stage = 4; next
    }
    stage == 4 && /^[[:space:]]*Press enter to confirm or esc to go back[[:space:]]*$/ {
      if (choice == "retry" || choice == "waiting") {
        print choice
        found = 1
        exit 0
      }
      exit 1
    }
    stage == 1 { next }  # allow the explanatory copy before the options
    /^[[:space:]]*$/ { next }
    stage > 1 { stage = 0; choice = "" }
    END { if (!found) exit 1 }
  '
}

# fm_clear_safety_prompt: choose "Keep waiting" in Codex's additional-safety
# dialog for <target>. Returns 0 only when it sent the verified confirmation
# keys, 1 when no actionable dialog is present (or auto-clear is disabled/
# unreadable), and 2 when the menu matched but the clear could not be
# confirmed - keys may have been sent without effect (e.g. a pane in copy-mode
# absorbing them). Enter is sent only after a recapture confirms Keep waiting
# is selected: a Down dropped mid-redraw must not confirm "Retry with a faster
# model". Safe to call every poll: after Down but before a confirmed Enter, a
# subsequent call sees Keep waiting selected and submits it without moving to
# Learn more.
fm_clear_safety_prompt() {  # <target>
  local target=$1 tail20 selection
  [ "${FM_SAFETY_AUTOCLEAR:-1}" != "0" ] || return 1
  tail20=$(tmux capture-pane -p -t "$target" -S -20 2>/dev/null) || return 1
  selection=$(printf '%s\n' "$tail20" | fm_tmux_safety_prompt_selection) || return 1
  if [ "$selection" = retry ]; then
    tmux send-keys -t "$target" Down 2>/dev/null || return 2
    sleep "${FM_SAFETY_AUTOCLEAR_DELAY:-0.1}"
    tail20=$(tmux capture-pane -p -t "$target" -S -20 2>/dev/null) || return 2
    selection=$(printf '%s\n' "$tail20" | fm_tmux_safety_prompt_selection) || return 2
    [ "$selection" = waiting ] || return 2
  fi
  tmux send-keys -t "$target" Enter 2>/dev/null || return 2
  return 0
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final verdict on stdout (empty|pending|unknown|send-failed) so callers can
# pick their own success policy. Both current callers require "empty": every
# other state is retried with Enter only and remains unconfirmed if the bounded
# retry budget expires.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep>
  local target=$1 retries=$2 sleep_s=$3 i=0 state
  while :; do
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    [ "$state" = empty ] && { printf 'empty'; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf '%s' "$state"; return 0; }
  done
}

fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s"
}
