#!/usr/bin/env bash
# Send one line of literal text to a crewmate window, then Enter.
# Usage: fm-send.sh <window> <text...>
#   <window> may be a bare firstmate window name (fm-xyz), resolved through
#   this home's state/<id>.meta, or explicit session:window.
# Special keys instead of text: fm-send.sh <window> --key Escape   (or Enter, C-c, ...)
#
# Text submission is verified: the line is typed ONCE, then Enter is sent and
# retried (Enter only, never retyped) until the composer is confirmed empty. An
# empty composer is the only acknowledgement that this specific steer landed:
# a busy footer can belong to the previous turn, and changed composer text is
# not evidence that our message submitted. Any unconfirmed result exits
# non-zero so callers can preserve and retry their steer. The composer/submit
# logic is shared with the away-mode daemon via bin/fm-tmux-lib.sh. Tune with
# FM_SEND_RETRIES (default 3) / FM_SEND_SLEEP (0.4).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

resolve() {
  case "$1" in
    *:*) echo "$1" ;;
    fm-*)
      meta="$STATE/${1#fm-}.meta"
      if [ ! -f "$meta" ]; then
        echo "error: no metadata for $1 in $STATE; pass session:window to target a window outside this firstmate home" >&2
        exit 1
      fi
      window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ -n "$window" ] || { echo "error: no window recorded in $meta" >&2; exit 1; }
      echo "$window"
      ;;
    *) tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$1\$" \
         || { echo "error: no window named $1" >&2; exit 1; } ;;
  esac
}

T=$(resolve "$1")
TARGET_ARG="$1"
shift

# A lane that never writes status is invisible to every status-based check (see
# fm-stall-check.sh check_silent_lanes). Only the fm-brief.sh scaffold carries
# the reporting contract, so follow-up work sent straight into a live lane
# arrived without it and lanes ran silent for hours (2026-08-18).
#
# Attach the contract to the FIRST steer a lane receives and no later: once its
# status file exists it has demonstrably learned to report, so every subsequent
# steer stays a clean one-liner. Set FM_SEND_NO_CONTRACT=1 to suppress.
status_contract_suffix() {
  local id status
  case "$TARGET_ARG" in
    fm-*) id="${TARGET_ARG#fm-}" ;;
    *) return 0 ;;
  esac
  [ -n "${FM_SEND_NO_CONTRACT:-}" ] && return 0
  status="$STATE/$id.status"
  [ -f "$status" ] && return 0
  [ -f "$STATE/$id.meta" ] || return 0
  printf ' -- Report status by appending one line for each supervisor-actionable phase change and for needs-decision/blocked/done/failed: printf %s\\t%s\\n "{state}: {one short line}" "$(date +%%s)" >> %s' \
    '%s' '%s' "$status"
}

agent_state=$(fm_pane_agent_state "$T")
if [ "$agent_state" = dead ]; then
  pane_command=$(fm_pane_current_command "$T" || true)
  [ -n "$pane_command" ] || pane_command=unknown
  echo "error: refusing to send to $T: no live agent process (pane at $pane_command)" >&2
  exit 1
elif [ "$agent_state" = unknown ]; then
  echo "warning: could not verify a live agent process in $T; continuing because pane process state is unreadable" >&2
fi

if [ "${1:-}" = "--key" ]; then
  tmux send-keys -t "$T" "$2"
else
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing. Give popups time to settle.
  case "$*" in /*) settle=1.2 ;; *) settle=0.3 ;; esac
  MSG="$*$(status_contract_suffix)"
  retries=${FM_SEND_RETRIES:-3}
  sleep_s=${FM_SEND_SLEEP:-0.4}
  # Type once, submit, verify. Success means the shared composer reader confirms
  # empty; retry Enter only for every other state, never retype the instruction.
  verdict=$(fm_tmux_submit_core "$T" "$MSG" "$retries" "$sleep_s" "$settle")
  case "$verdict" in
    empty)
      ;;
    pending)
      echo "error: text not submitted to $T (composer still has pending input after $retries Enter retries)" >&2
      exit 1
      ;;
    unknown)
      echo "error: submit to $T could not be verified (composer not confirmed empty after $retries Enter retries; unreadable or still busy)" >&2
      exit 1
      ;;
    send-failed)
      echo "error: text not sent to $T (tmux send-keys failed)" >&2
      exit 1
      ;;
    *)
      echo "error: submit to $T returned unexpected verification state: $verdict" >&2
      exit 1
      ;;
  esac
fi
