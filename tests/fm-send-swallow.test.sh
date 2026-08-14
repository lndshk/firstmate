#!/usr/bin/env bash
# fm-send submit verification regressions.
#
# A steer is delivered only when the shared composer reader confirms it empty.
# In particular, a busy footer can describe the PREVIOUS turn while a new steer
# remains unsubmitted in the composer; it must never turn a pending result into
# success.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEND="$ROOT/bin/fm-send.sh"
LIB="$ROOT/bin/fm-tmux-lib.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$LIB"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-send-tests.XXXXXX")
cleanup() {
  [ -n "${FAKE_AGENT_PID:-}" ] && kill "$FAKE_AGENT_PID" 2>/dev/null || true
  [ -n "${FAKE_AGENT_PID:-}" ] && wait "$FAKE_AGENT_PID" 2>/dev/null || true
  local pids pid
  pids=$(jobs -pr 2>/dev/null || true)
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# Fake tmux with a one-line composer. Literal text is typed once; Enter clears
# it only when FM_FAKE_SUBMIT=1. A fake busy footer is deliberately separate
# from the composer row, matching the damaging real race.
make_fake_tmux() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  node -e 'setTimeout(() => {}, 600000)' codex &
  printf '%s\n' "$!" > "$1/fake-agent.pid"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
composer=${FM_FAKE_COMPOSER_FILE:?FM_FAKE_COMPOSER_FILE unset}
emit_composer() {
  cat "$composer"
  if [ -n "${FM_FAKE_FOOTER:-}" ]; then
    if [ "${FM_FAKE_FOOTER_DIM:-0}" = 1 ]; then
      printf '\033[2m%s\033[0m\n' "$FM_FAKE_FOOTER"
    else
      printf '%s\n' "$FM_FAKE_FOOTER"
    fi
  fi
}
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '%s\n' "${FM_FAKE_CY:-0}"; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    [ "${FM_FAKE_UNREADABLE:-0}" = 1 ] && exit 1
    styled=0 start='' end='' prev=''
    for a in "$@"; do
      case "$prev" in -S) start=$a ;; -E) end=$a ;; esac
      [ "$a" = '-e' ] && styled=1
      prev=$a
    done
    if [ "$styled" = 1 ]; then
      # Honour -S/-E so a cursor_y-based reader really sees only that row.
      if [ -n "$start" ] && [ -n "$end" ]; then
        emit_composer | sed -n "$((start + 1)),$((end + 1))p"
      else
        emit_composer
      fi
    elif [ "${FM_FAKE_BUSY:-0}" = 1 ]; then
      printf '• Working (4s • esc to interrupt)\n'
    else
      printf 'idle pane\n'
    fi
    exit 0 ;;
  list-panes)
    printf '%s\n' "${FM_FAKE_PANE_PID:?FM_FAKE_PANE_PID unset}"
    exit 0 ;;
  send-keys)
    shift
    literal=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l) literal=1 ;;
        Enter)
          printf '[ENTER]\n' >> "${FM_FAKE_SENT:-/dev/null}"
          if [ "${FM_FAKE_BUSY_ON_ROW:-0}" = 1 ]; then
            printf '• Working (4s • esc to interrupt)\n' > "$composer"
          elif [ "${FM_FAKE_SUBMIT:-0}" = 1 ]; then
            printf '\033[1m›\033[0m \033[2mAny rendered Codex suggestion\033[0m\n' > "$composer"
          fi
          ;;
        *)
          if [ "$literal" = 1 ]; then
            printf '› %s\n' "$1" > "$composer"
            literal=0
          fi
          ;;
      esac
      shift
    done
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

make_fake_tmux "$TMP_ROOT" >/dev/null
FAKEBIN="$TMP_ROOT/fakebin"
FAKE_AGENT_PID=$(cat "$TMP_ROOT/fake-agent.pid")

composer_state() {  # <line>
  local file="$TMP_ROOT/composer-state"
  printf '%s\n' "$1" > "$file"
  PATH="$FAKEBIN:$PATH" FM_FAKE_COMPOSER_FILE="$file" fm_tmux_composer_state fake:pane
}

composer_state_with_footer() {  # <composer-line> <line below composer>
  local file="$TMP_ROOT/composer-state"
  printf '%s\n' "$1" > "$file"
  PATH="$FAKEBIN:$PATH" FM_FAKE_COMPOSER_FILE="$file" FM_FAKE_FOOTER="$2" \
    fm_tmux_composer_state fake:pane
}

# <composer-line> <footer> <footer-dim 0|1> <cursor_y>: the production shape,
# where cursor_y points at the footer instead of the composer above it.
composer_state_footer_at_cursor() {
  local file="$TMP_ROOT/composer-state"
  printf '%s\n' "$1" > "$file"
  PATH="$FAKEBIN:$PATH" FM_FAKE_COMPOSER_FILE="$file" FM_FAKE_FOOTER="$2" \
    FM_FAKE_FOOTER_DIM="$3" FM_FAKE_CY="$4" fm_tmux_composer_state fake:pane
}

pending_guard() {  # <line> -> "unsafe" when fm_pane_input_pending defers
  local file="$TMP_ROOT/composer-state"
  printf '%s\n' "$1" > "$file"
  if PATH="$FAKEBIN:$PATH" FM_FAKE_COMPOSER_FILE="$file" \
     fm_pane_input_pending fake:pane; then printf 'unsafe'; else printf 'safe'; fi
}

composer_state_c_locale() {  # <line>
  local file="$TMP_ROOT/composer-state"
  printf '%s\n' "$1" > "$file"
  LC_ALL=C LANG=C LC_CTYPE=C PATH="$FAKEBIN:$PATH" FM_FAKE_COMPOSER_FILE="$file" \
    fm_tmux_composer_state fake:pane
}

run_send() {  # <initial composer> <submit 0|1> <busy 0|1> <text...>
  local initial=$1 submit=$2 busy=$3 err="$TMP_ROOT/send.err" sent="$TMP_ROOT/sent.log"
  shift 3
  local composer="$TMP_ROOT/composer"
  printf '%s\n' "$initial" > "$composer"
  : > "$sent"
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/state" \
    FM_FAKE_COMPOSER_FILE="$composer" FM_FAKE_SENT="$sent" FM_FAKE_SUBMIT="$submit" \
    FM_FAKE_BUSY="$busy" FM_FAKE_FOOTER="${FM_TEST_FOOTER:-}" \
    FM_FAKE_FOOTER_DIM="${FM_TEST_FOOTER_DIM:-0}" FM_FAKE_CY="${FM_TEST_CY:-0}" \
    FM_FAKE_PANE_PID="$FAKE_AGENT_PID" FM_SEND_RETRIES=3 FM_SEND_SLEEP=0 \
    "$SEND" fake:pane "$@" >/dev/null 2>"$err"
  RC=$?
  ERR=$(cat "$err")
  ENTERS=$(grep -c '^\[ENTER\]$' "$sent" 2>/dev/null || true)
}

test_empty_composer_variants() {
  local esc
  esc=$(printf '\033')
  # Suggestions are detected from their dim rendering, not their mutable text.
  [ "$(composer_state "${esc}[1m›${esc}[0m ${esc}[2mImplement {feature}${esc}[0m")" = empty ] \
    || fail 'dim Codex Implement placeholder was not empty'
  [ "$(composer_state "${esc}[1m›${esc}[0m ${esc}[2mWrite tests for @filename${esc}[0m")" = empty ] \
    || fail 'new dim Codex suggestion was not empty'
  [ "$(composer_state '│ > │')" = empty ] \
    || fail 'Claude bordered composer was not empty'
  [ "$(composer_state '› [Pasted Content 42 chars]')" = pending ] \
    || fail 'Pasted Content composer was not pending'
  pass 'composer reader uses rendering for arbitrary Codex suggestions and keeps pasted content pending'
}

test_composer_selector_ignores_footer_below_input() {
  local footer='gpt-5.6-terra high · ~/.treehouse/example'
  # The reported production shape: cursor_y points at this footer, while the
  # actual composer directly above it has collapsed but unsubmitted input.
  [ "$(composer_state_with_footer '› [Pasted Content 1024 chars]' "$footer")" = pending ] \
    || fail 'composer selector read the footer below pasted Codex input'
  pass 'composer selector reads the prompt row above the Codex footer'
}

test_unlocatable_composer_is_never_empty_or_safe() {
  # 'empty' is the submit acknowledgement and the only safe-to-type-into state,
  # so a pane whose composer cannot be located must reach neither.
  [ "$(composer_state 'gpt-5.6-terra high · ~/.treehouse/example')" != empty ] \
    || fail 'a pane with no locatable composer was reported empty'
  [ "$(pending_guard 'gpt-5.6-terra high · ~/.treehouse/example')" = unsafe ] \
    || fail 'injection guard treated an unlocatable composer as safe to type into'
  [ "$(pending_guard 'human draft text')" = unsafe ] \
    || fail 'injection guard treated a human draft as safe to type into'
  pass 'an unlocatable composer is never empty and never safe to inject into'
}

test_unreadable_pane_is_unknown_and_unsafe() {
  local state guard
  state=$(PATH="$FAKEBIN:$PATH" FM_FAKE_COMPOSER_FILE="$TMP_ROOT/composer-state" \
    FM_FAKE_UNREADABLE=1 fm_tmux_composer_state fake:pane)
  [ "$state" = unknown ] || fail "unreadable pane was $state, expected unknown"
  if PATH="$FAKEBIN:$PATH" FM_FAKE_COMPOSER_FILE="$TMP_ROOT/composer-state" \
     FM_FAKE_UNREADABLE=1 fm_pane_input_pending fake:pane; then guard=unsafe; else guard=safe; fi
  [ "$guard" = unsafe ] || fail 'injection guard treated an unreadable pane as safe'
  pass 'an unreadable pane is unknown and never safe to inject into'
}

test_blank_and_ghost_only_composers_are_empty() {
  local esc
  esc=$(printf '\033')
  # A submit that landed must be acknowledgeable, or fm-send reports a delivered
  # steer as failed and the daemon re-injects the same digest.
  [ "$(composer_state '')" = empty ] \
    || fail 'a blank composer was not empty (submit could never be acknowledged)'
  [ "$(composer_state "│ ${esc}[2mtry the other approach instead${esc}[0m │")" = empty ] \
    || fail 'a bordered composer holding only dim ghost text was not empty'
  pass 'blank and dim-ghost-only composers are empty, so a real submit is acknowledged'
}

test_dim_footer_at_cursor_cannot_mask_pasted_composer() {
  local footer='gpt-5.6-terra high · ~/.treehouse/example'
  # The exact production shape: the composer holds a collapsed paste, Codex
  # draws its footer BELOW it, and cursor_y points at that footer. A cursor_y
  # reader captures only the dim footer, strips it to nothing, and calls the
  # composer empty - a false submit acknowledgement.
  [ "$(composer_state_footer_at_cursor '› [Pasted Content 1024 chars]' "$footer" 1 1)" = pending ] \
    || fail 'a dim footer on the cursor row masked a pasted composer'
  [ "$(composer_state_footer_at_cursor '│ > route this work │' "$footer" 1 1)" = pending ] \
    || fail 'a dim footer on the cursor row masked a bordered composer'
  pass 'a dim footer on the cursor row cannot mask unsubmitted composer input'
}

test_dim_paste_chip_is_still_pending() {
  local esc
  esc=$(printf '\033')
  # A paste chip is unsubmitted content, not a placeholder, so dim rendering
  # must not erase it the way it erases a suggestion.
  [ "$(composer_state "${esc}[1m›${esc}[0m ${esc}[2m[Pasted Content 1024 chars]${esc}[0m")" = pending ] \
    || fail 'a dim-rendered paste chip was erased and read as empty'
  [ "$(composer_state "│ ${esc}[2m[Pasted Content 42 chars]${esc}[0m │")" = pending ] \
    || fail 'a dim-rendered paste chip in a bordered composer was erased'
  pass 'a collapsed paste chip stays pending even when rendered dim'
}

test_composer_selector_is_locale_independent() {
  # Supervisors and daemons are nohup'd with no LANG, so the shell runs in the
  # C/POSIX locale where a glob wildcard matches one BYTE, not one character. A
  # multibyte composer border must still be recognized there, otherwise every
  # claude pane reads unknown: fm-send cannot confirm a delivered steer, and
  # unknown is not-pending, so the away-mode daemon types over a human's draft.
  [ "$(composer_state_c_locale '│ > │')" = empty ] \
    || fail 'Claude bordered composer was not empty in the C locale'
  [ "$(composer_state_c_locale '┃ > ┃')" = empty ] \
    || fail 'heavy-bordered composer was not empty in the C locale'
  [ "$(composer_state_c_locale '│ > route this work │')" = pending ] \
    || fail 'bordered composer with typed text was not pending in the C locale'
  [ "$(composer_state_c_locale '❯ ')" = empty ] \
    || fail 'multibyte bare prompt was not empty in the C locale'
  pass 'composer selector recognizes multibyte borders and prompts in the C locale'
}

test_bordered_alt_prompt_glyphs_are_composers() {
  [ "$(composer_state '│ ❯ │')" = empty ] \
    || fail 'bordered ❯ composer was not empty'
  [ "$(composer_state '│ › [Pasted Content 42 chars] │')" = pending ] \
    || fail 'bordered › composer with pasted content was not pending'
  pass 'bordered composers are recognized for every supported prompt glyph'
}

test_normal_submit_succeeds_without_submit_warning() {
  run_send '› Implement {feature}' 1 0 'route this work'
  [ "$RC" -eq 0 ] || fail "normal submit exited non-zero: $ERR"
  [ "$ENTERS" -eq 1 ] || fail "normal submit sent $ENTERS Enters, expected one"
  [ -z "$ERR" ] || fail "normal submit was not quiet: $ERR"
  pass 'fm-send confirms a normal empty-composer submit quietly'
}

test_swallowed_enter_fails_with_window_name() {
  run_send '› Implement {feature}' 0 0 'route this work'
  [ "$RC" -ne 0 ] || fail 'swallowed Enter was reported as delivered'
  case "$ERR" in
    *'not submitted to fake:pane'*) : ;;
    *) fail "swallowed Enter error did not name the window clearly: $ERR" ;;
  esac
  [ "$ENTERS" -eq 3 ] || fail "swallowed Enter retried $ENTERS times, expected three"
  pass 'fm-send exits non-zero and names the window when Enter is swallowed'
}

test_busy_previous_turn_is_not_delivery_proof() {
  # This is the exact regression: the agent is busy finishing its previous turn
  # while the newly typed steer still sits in the composer. Old fm-send returned
  # success solely because the busy footer was visible.
  run_send '› route this work' 0 1 'route this work'
  [ "$RC" -ne 0 ] || fail 'busy previous turn falsely reported the unsent steer delivered'
  case "$ERR" in
    *'not submitted to fake:pane'*) : ;;
    *) fail "busy-pane failure was unclear: $ERR" ;;
  esac
  case "$ERR" in *'treating as delivered'*) fail "busy pane used delivery fallback: $ERR" ;; esac
  [ "$ENTERS" -eq 3 ] || fail "busy pending steer retried $ENTERS times, expected three"
  pass 'busy previous turn cannot prove a pending steer submitted'
}

test_pasted_input_above_footer_fails_submit_verification() {
  local saved_footer=${FM_TEST_FOOTER:-} saved_dim=${FM_TEST_FOOTER_DIM:-} saved_cy=${FM_TEST_CY:-}
  # End to end through fm-send in the production shape: unsubmitted text in the
  # composer, a DIM Codex footer below it, and cursor_y pointing at that footer.
  # A cursor_y reader sees only the footer, strips its dim run to nothing, and
  # reports the steer delivered. fm-send must refuse instead.
  FM_TEST_FOOTER='gpt-5.6-terra high · ~/.treehouse/example'
  FM_TEST_FOOTER_DIM=1
  FM_TEST_CY=1
  run_send '› [Pasted Content 1024 chars]' 0 0 'route this work'
  FM_TEST_FOOTER=$saved_footer; FM_TEST_FOOTER_DIM=$saved_dim; FM_TEST_CY=$saved_cy
  [ "$RC" -ne 0 ] || fail 'pasted input above a footer was reported as delivered'
  case "$ERR" in
    *'not submitted to fake:pane'*) : ;;
    *) fail "pasted-input failure was unclear: $ERR" ;;
  esac
  [ "$ENTERS" -eq 3 ] || fail "pasted input retried $ENTERS Enters, expected three"
  pass 'fm-send rejects an unsubmitted pasted composer even with a footer below it'
}

test_busy_on_cursor_row_is_unverified_not_misreported() {
  # A busy footer can land directly ON the composer/cursor row (single-line
  # composer harnesses, where the working indicator replaces the prompt in
  # place). Whether that busy text predates our Enter (a stale previous turn)
  # or appears because our own submit just started a new turn, one composer
  # read cannot tell the difference, so it must stay unconfirmed — never a
  # false "delivered", and never a misleading "not submitted" that would
  # invite a caller to retype (and duplicate) an instruction that may have
  # already landed.
  local composer="$TMP_ROOT/composer" err="$TMP_ROOT/busyrow.err" sent="$TMP_ROOT/busyrow.sent"
  printf '› route this work\n' > "$composer"
  : > "$sent"
  if PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/state" \
    FM_FAKE_COMPOSER_FILE="$composer" FM_FAKE_SENT="$sent" FM_FAKE_BUSY_ON_ROW=1 \
    FM_FAKE_PANE_PID="$FAKE_AGENT_PID" FM_SEND_RETRIES=3 FM_SEND_SLEEP=0 \
    "$SEND" fake:pane 'route this work' >/dev/null 2>"$err"; then
    fail 'busy footer on the cursor row was reported as delivered'
  fi
  grep -F 'fake:pane could not be verified' "$err" >/dev/null \
    || fail "busy-on-row failure did not say unverified: $(cat "$err")"
  case "$(cat "$err")" in
    *'not submitted'*) fail "busy-on-row was misreported as a confirmed non-submission: $(cat "$err")" ;;
  esac
  entries=$(grep -c '^\[ENTER\]$' "$sent" 2>/dev/null || true)
  [ "$entries" -eq 3 ] || fail "busy-on-row retried $entries times, expected three"
  pass 'a busy footer on the composer row is unverified, not misreported as failed or delivered'
}

test_empty_composer_cannot_be_read_fails() {
  local composer="$TMP_ROOT/composer" err="$TMP_ROOT/unreadable.err"
  printf '› Implement {feature}\n' > "$composer"
  if PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/state" \
    FM_FAKE_COMPOSER_FILE="$composer" FM_FAKE_UNREADABLE=1 FM_FAKE_PANE_PID="$FAKE_AGENT_PID" \
    FM_SEND_RETRIES=2 FM_SEND_SLEEP=0 \
    "$SEND" fake:pane 'route this work' >/dev/null 2>"$err"; then
    fail 'unreadable composer was reported as delivered'
  fi
  grep -F 'fake:pane could not be verified' "$err" >/dev/null \
    || fail "unreadable composer failure did not name the window: $(cat "$err")"
  pass 'fm-send fails when it cannot confirm an empty composer'
}

test_empty_composer_variants
test_composer_selector_ignores_footer_below_input
test_unlocatable_composer_is_never_empty_or_safe
test_unreadable_pane_is_unknown_and_unsafe
test_blank_and_ghost_only_composers_are_empty
test_dim_footer_at_cursor_cannot_mask_pasted_composer
test_dim_paste_chip_is_still_pending
test_composer_selector_is_locale_independent
test_bordered_alt_prompt_glyphs_are_composers
test_normal_submit_succeeds_without_submit_warning
test_swallowed_enter_fails_with_window_name
test_busy_previous_turn_is_not_delivery_proof
test_pasted_input_above_footer_fails_submit_verification
test_busy_on_cursor_row_is_unverified_not_misreported
test_empty_composer_cannot_be_read_fails
printf 'all fm-send submit verification tests passed\n'
