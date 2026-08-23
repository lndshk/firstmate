#!/usr/bin/env bash
# fm-codex-safety-lib.sh - clear Codex's additional-safety menu on a crewmate pane.
#
# WHY THIS IS ITS OWN FILE. Codex blocks mid-turn on an approval menu; without
# clearing it a crewmate stalls there indefinitely and the pause reads as
# staleness. Upstream ships no handling for this dialog (its own "safety" code is
# shell-glyph classification, an unrelated thing), so this is fork-local.
#
# It lives in a NEW file rather than appended to bin/fm-tmux-lib.sh deliberately:
# a new file never conflicts at an upstream sync, while an edit to a shared file
# conflicts at every one. The fork previously carried this as an append to
# fm-tmux-lib.sh plus a graft into fm-watch.sh; both were shared-file edits and
# both are gone. Invocation now lives in a home-local state/*.check.sh, so the
# repo keeps zero divergence from upstream.
#
# tmux-specific by construction. Callers MUST confirm the target's backend is
# tmux before calling; upstream is backend-abstracted and these primitives are not.
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


# fm_codex_safety_sweep: clear the menu on ONE recorded pane, with the bounded
# retry bookkeeping that stops a pane being offered keypresses forever.
#
# The counting lives here, not in the caller, so CI covers it. The fork
# previously kept this inline in bin/fm-watch.sh, which made it a shared-file
# graft AND left it testable only through a full watcher run.
#
# Returns 0 when a clear was confirmed (caller should skip further classification
# of this pane this cycle), 1 otherwise. Never fails the caller.
fm_codex_safety_sweep() {  # <state-dir> <window> <key>
  local state=$1 win=$2 key=$3 clearf cleared max max_remaining limit_remaining max_digit limit_digit
  max=${FM_SAFETY_AUTOCLEAR_MAX:-5}
  if ! [[ "$max" =~ ^[0-9]+$ ]] || [ "${#max}" -gt 19 ]; then
    max=5
  elif [ "${#max}" -eq 19 ]; then
    # Compare one digit at a time so the upper-bound validation never relies
    # on shell arithmetic overflowing at the signed 64-bit limit.
    max_remaining=$max
    limit_remaining=9223372036854775807
    while [ -n "$max_remaining" ]; do
      max_digit=${max_remaining%"${max_remaining#?}"}
      limit_digit=${limit_remaining%"${limit_remaining#?}"}
      if [ "$max_digit" -gt "$limit_digit" ]; then
        max=5
        break
      elif [ "$max_digit" -lt "$limit_digit" ]; then
        break
      fi
      max_remaining=${max_remaining#?}
      limit_remaining=${limit_remaining#?}
    done
  fi
  clearf="$state/.count-safety-$key"
  cleared=$(cat "$clearf" 2>/dev/null || echo 0)
  case "$cleared" in ''|*[!0-9]*) cleared=0 ;; esac

  if [ "$cleared" -ge "$max" ]; then
    # Budget spent. Reset ONLY once the menu is confirmed gone, so a pane that is
    # genuinely wedged on the dialog stops receiving keys and falls through to
    # ordinary stale classification instead.
    if ! tmux capture-pane -p -t "$win" -S -20 2>/dev/null \
      | fm_tmux_safety_prompt_selection >/dev/null; then
      rm -f "$clearf" 2>/dev/null || true
    fi
    return 1
  fi

  fm_clear_safety_prompt "$win"
  case $? in
    0) echo $(( cleared + 1 )) > "$clearf"; return 0 ;;
    # An unverified attempt still advances the count: keys may have been absorbed
    # (copy-mode, lookalike content), and an attempt that cannot be confirmed must
    # not be free, or a pane could be poked forever.
    2) echo $(( cleared + 1 )) > "$clearf"; return 1 ;;
    *) rm -f "$clearf" 2>/dev/null || true; return 1 ;;
  esac
}
