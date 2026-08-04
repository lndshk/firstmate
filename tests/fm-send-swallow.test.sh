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
  [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

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
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    [ "${FM_FAKE_UNREADABLE:-0}" = 1 ] && exit 1
    styled=0
    for a in "$@"; do [ "$a" = '-e' ] && styled=1; done
    if [ "$styled" = 1 ]; then
      cat "$composer"
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
            printf '› Implement {feature}\n' > "$composer"
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

run_send() {  # <initial composer> <submit 0|1> <busy 0|1> <text...>
  local initial=$1 submit=$2 busy=$3 err="$TMP_ROOT/send.err" sent="$TMP_ROOT/sent.log"
  shift 3
  local composer="$TMP_ROOT/composer"
  printf '%s\n' "$initial" > "$composer"
  : > "$sent"
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/state" \
    FM_FAKE_COMPOSER_FILE="$composer" FM_FAKE_SENT="$sent" FM_FAKE_SUBMIT="$submit" \
    FM_FAKE_BUSY="$busy" FM_FAKE_PANE_PID="$FAKE_AGENT_PID" FM_SEND_RETRIES=3 FM_SEND_SLEEP=0 \
    "$SEND" fake:pane "$@" >/dev/null 2>"$err"
  RC=$?
  ERR=$(cat "$err")
  ENTERS=$(grep -c '^\[ENTER\]$' "$sent" 2>/dev/null || true)
}

test_empty_composer_variants() {
  [ "$(composer_state '› Implement {feature}')" = empty ] \
    || fail 'Codex Implement placeholder was not empty'
  [ "$(composer_state '› Run /review on my current changes')" = empty ] \
    || fail 'Codex review placeholder was not empty'
  [ "$(composer_state '│ > │')" = empty ] \
    || fail 'Claude bordered composer was not empty'
  [ "$(composer_state '[Pasted Content 42 chars]')" = pending ] \
    || fail 'Pasted Content composer was not pending'
  pass 'composer reader recognizes Codex and Claude empty states but keeps pasted content pending'
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
test_normal_submit_succeeds_without_submit_warning
test_swallowed_enter_fails_with_window_name
test_busy_previous_turn_is_not_delivery_proof
test_busy_on_cursor_row_is_unverified_not_misreported
test_empty_composer_cannot_be_read_fails
printf 'all fm-send submit verification tests passed\n'
