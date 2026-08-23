#!/usr/bin/env bash
# Hermetic tests for Codex's `safety-buffering-prompt` auto-clear path.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/bin/fm-codex-safety-lib.sh"

# shellcheck source=bin/fm-codex-safety-lib.sh
. "$LIB"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-safety-autoclear-tests.XXXXXX")
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

make_fake_tmux() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
case "${1:-}" in
  capture-pane) cat "${FM_FAKE_TMUX_CAPTURE:?}"; exit 0 ;;
  send-keys)
    if [ "${!#}" = Down ] && [ -n "${FM_FAKE_TMUX_AFTER_DOWN:-}" ]; then
      cp "$FM_FAKE_TMUX_AFTER_DOWN" "$FM_FAKE_TMUX_CAPTURE"
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

write_prompt() {  # <path> [selected-option]
  local path=$1 selected=${2:-1} one='  1.' two='  2.' three='  3.'
  case "$selected" in
    1) one='> 1.' ;;
    2) two='> 2.' ;;
    3) three='> 3.' ;;
  esac
  {
    printf '%s\n' 'Additional safety checks'
    printf '%s\n' 'This request requires additional safety checks, which can take extra time.'
    printf '%s Retry with a faster model\n' "$one"
    printf '%s Keep waiting\n' "$two"
    printf '%s Learn more\n' "$three"
    printf '%s\n' 'Press enter to confirm or esc to go back'
  } > "$path"
}

run_clear() {  # <fakebin> <capture> <log> [after-down]
  local fb=$1 capture=$2 log=$3 after_down=${4:-}
  : > "$log"
  FM_SAFETY_AUTOCLEAR_DELAY=0 FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_AFTER_DOWN="$after_down" \
    FM_FAKE_TMUX_LOG="$log" PATH="$fb:$PATH" fm_clear_safety_prompt 'crew:fm-task'
}

test_active_prompt_selects_keep_waiting() {
  local dir fb capture after_down log expected
  dir="$TMP_ROOT/active"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; after_down="$dir/after-down"; log="$dir/tmux.log"
  write_prompt "$capture" 1
  write_prompt "$after_down" 2
  run_clear "$fb" "$capture" "$log" "$after_down" || fail "active safety prompt was not cleared"
  expected=$(printf '%s\n' \
    'capture-pane -p -t crew:fm-task -S -20' \
    'send-keys -t crew:fm-task Down' \
    'capture-pane -p -t crew:fm-task -S -20' \
    'send-keys -t crew:fm-task Enter')
  [ "$(cat "$log")" = "$expected" ] || fail "auto-clear sent unexpected tmux commands"
  pass "active prompt sends Down, verifies Keep waiting, then Enter"
}

test_dropped_down_does_not_confirm() {
  local dir fb capture log
  dir="$TMP_ROOT/dropped"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; log="$dir/tmux.log"
  write_prompt "$capture" 1
  if run_clear "$fb" "$capture" "$log"; then
    fail "a dropped Down still reported a clear"
  fi
  grep -q 'send-keys -t crew:fm-task Down' "$log" || fail "no Down was attempted"
  ! grep -q 'send-keys -t crew:fm-task Enter' "$log" \
    || fail "Enter was sent while Retry with a faster model stayed selected"
  pass "a Down that does not move the selection never confirms option 1"
}

test_selected_keep_waiting_is_confirmed_without_moving() {
  local dir fb capture log expected
  dir="$TMP_ROOT/waiting"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; log="$dir/tmux.log"
  write_prompt "$capture" 2
  run_clear "$fb" "$capture" "$log" || fail "selected Keep waiting was not confirmed"
  expected=$(printf '%s\n' \
    'capture-pane -p -t crew:fm-task -S -20' \
    'send-keys -t crew:fm-task Enter')
  [ "$(cat "$log")" = "$expected" ] || fail "selected Keep waiting was moved before confirmation"
  pass "a retry after Down confirms Keep waiting without selecting Learn more"
}

test_non_menu_content_does_not_trigger() {
  local dir fb capture log
  dir="$TMP_ROOT/not-menu"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; log="$dir/tmux.log"
  printf '%s\n' \
    'The output mentions Additional safety checks.' \
    'The correct choice is Keep waiting.' \
    'It also quotes Press enter to confirm.' > "$capture"
  if run_clear "$fb" "$capture" "$log"; then
    fail "prose mentioning the dialog triggered auto-clear"
  fi
  ! grep -q '^send-keys ' "$log" || fail "non-menu content received keypresses"
  pass "dialog words outside the complete menu do not trigger"
}

test_disabled_does_not_capture_or_send() {
  local dir fb capture log
  dir="$TMP_ROOT/disabled"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; log="$dir/tmux.log"
  write_prompt "$capture" 1
  : > "$log"
  if FM_SAFETY_AUTOCLEAR=0 FM_SAFETY_AUTOCLEAR_DELAY=0 \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_LOG="$log" \
    PATH="$fb:$PATH" fm_clear_safety_prompt 'crew:fm-task'; then
    fail "disabled auto-clear reported that it acted"
  fi
  [ ! -s "$log" ] || fail "disabled auto-clear touched tmux"
  pass "FM_SAFETY_AUTOCLEAR=0 disables capture and keypresses"
}

run_watch() {  # <fakebin> <capture> <log> <state> <out> [after-down]
  local state=$4 status
  status="$state/task.status"
  # The production watcher stays alive after a quiet cycle.  Seed a terminal
  # status that its signal pass has already observed, so the heartbeat exits
  # normally after the cycle under test has completed.
  printf '%s\n' 'done: watcher test cycle complete' > "$status"
  printf '%s' "$(fm_wake_signal_sig "$status")" \
    > "$(fm_wake_signal_seen_path "$state" "$status")"
  FM_STATE_OVERRIDE="$4" FM_WATCH_KEEPALIVE=0 FM_CHECK_INTERVAL=9999999 \
    FM_HEARTBEAT=0 FM_SAFETY_AUTOCLEAR_DELAY=0 FM_FAKE_TMUX_CAPTURE="$2" \
    FM_FAKE_TMUX_AFTER_DOWN="${6:-}" \
    FM_FAKE_TMUX_LOG="$3" PATH="$1:$PATH" "$WATCH" > "$5"
}

# --- fm_codex_safety_sweep: the bounded-retry bookkeeping -------------------
# Previously exercised only through a full watcher run, because the counting
# lived inline in bin/fm-watch.sh. It now lives in the library, so these assert
# it directly and no longer depend on a watcher graft that no longer exists.

test_sweep_counts_and_caps_consecutive_clears() {
  local dir fb capture state key
  dir="$TMP_ROOT/sweep-cap"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; state="$dir/state"; mkdir -p "$state"
  write_prompt "$capture" 2
  key=crew_fm-recorded
  export FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_LOG="$dir/tmux.log"
  PATH="$fb:$PATH"
  : > "$dir/tmux.log"
  FM_SAFETY_AUTOCLEAR_MAX=2 fm_codex_safety_sweep "$state" crew:fm-recorded "$key" >/dev/null
  [ "$(cat "$state/.count-safety-$key")" = 1 ] || fail "first clear did not record a count"
  FM_SAFETY_AUTOCLEAR_MAX=2 fm_codex_safety_sweep "$state" crew:fm-recorded "$key" >/dev/null
  [ "$(cat "$state/.count-safety-$key")" = 2 ] || fail "second clear did not advance the count"
  : > "$dir/tmux.log"
  FM_SAFETY_AUTOCLEAR_MAX=2 fm_codex_safety_sweep "$state" crew:fm-recorded "$key" >/dev/null
  grep -q 'send-keys' "$dir/tmux.log" \
    && fail "a pane past FM_SAFETY_AUTOCLEAR_MAX must stop receiving keys"
  pass "consecutive clears are counted and capped at FM_SAFETY_AUTOCLEAR_MAX"
}

test_sweep_resets_count_when_menu_gone() {
  local dir fb capture state key
  dir="$TMP_ROOT/sweep-reset"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; state="$dir/state"; mkdir -p "$state"
  printf 'no menu here\n' > "$capture"
  key=crew_fm-recorded
  export FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_LOG="$dir/tmux.log"
  PATH="$fb:$PATH"
  echo 9 > "$state/.count-safety-$key"
  FM_SAFETY_AUTOCLEAR_MAX=2 fm_codex_safety_sweep "$state" crew:fm-recorded "$key" >/dev/null
  [ -e "$state/.count-safety-$key" ] \
    && fail "the count must reset once the menu is confirmed gone"
  pass "the consecutive-clear count resets only when the menu is confirmed gone"
}

test_sweep_invalid_cap_uses_default_bound() {
  local dir fb capture state key max
  dir="$TMP_ROOT/sweep-invalid-cap"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; state="$dir/state"; mkdir -p "$state"
  write_prompt "$capture" 2
  key=crew_fm-recorded
  export FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_LOG="$dir/tmux.log"
  PATH="$fb:$PATH"
  for _ in 1 2 3 4 5; do
    FM_SAFETY_AUTOCLEAR_MAX=5 fm_codex_safety_sweep "$state" crew:fm-recorded "$key" >/dev/null
  done
  for max in oops 9223372036854775808 999999999999999999999; do
    : > "$dir/tmux.log"
    FM_SAFETY_AUTOCLEAR_MAX="$max" fm_codex_safety_sweep "$state" crew:fm-recorded "$key" >/dev/null
    grep -q 'send-keys' "$dir/tmux.log" \
      && fail "an invalid FM_SAFETY_AUTOCLEAR_MAX must retain the default retry bound"
  done
  pass "malformed or unrepresentable retry caps fall back to the default bound"
}

test_sweep_accepts_signed_64_bit_maximum_cap() {
  local dir fb capture state key
  dir="$TMP_ROOT/sweep-maximum-cap"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; state="$dir/state"; mkdir -p "$state"
  write_prompt "$capture" 2
  key=crew_fm-recorded
  export FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_LOG="$dir/tmux.log"
  PATH="$fb:$PATH"
  echo 5 > "$state/.count-safety-$key"

  FM_SAFETY_AUTOCLEAR_MAX=9223372036854775807 \
    fm_codex_safety_sweep "$state" crew:fm-recorded "$key" >/dev/null
  grep -q 'send-keys' "$dir/tmux.log" \
    || fail "the signed 64-bit maximum retry cap must not fall back to the default bound"
  pass "the signed 64-bit maximum retry cap remains a valid budget"
}

test_active_prompt_selects_keep_waiting
test_dropped_down_does_not_confirm
test_selected_keep_waiting_is_confirmed_without_moving
test_non_menu_content_does_not_trigger
test_disabled_does_not_capture_or_send
test_sweep_counts_and_caps_consecutive_clears
test_sweep_resets_count_when_menu_gone
test_sweep_invalid_cap_uses_default_bound
test_sweep_accepts_signed_64_bit_maximum_cap
