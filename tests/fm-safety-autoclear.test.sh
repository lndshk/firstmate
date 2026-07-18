#!/usr/bin/env bash
# Hermetic tests for Codex's `safety-buffering-prompt` auto-clear path.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/bin/fm-tmux-lib.sh"
WATCH="$ROOT/bin/fm-watch.sh"

# shellcheck source=bin/fm-tmux-lib.sh
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
  send-keys) exit 0 ;;
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

run_clear() {  # <fakebin> <capture> <log>
  local fb=$1 capture=$2 log=$3
  : > "$log"
  FM_SAFETY_AUTOCLEAR_DELAY=0 FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_LOG="$log" PATH="$fb:$PATH" fm_clear_safety_prompt 'crew:fm-task'
}

test_active_prompt_selects_keep_waiting() {
  local dir fb capture log expected
  dir="$TMP_ROOT/active"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; log="$dir/tmux.log"
  write_prompt "$capture" 1
  run_clear "$fb" "$capture" "$log" || fail "active safety prompt was not cleared"
  expected=$(printf '%s\n' \
    'capture-pane -p -t crew:fm-task -S -20' \
    'send-keys -t crew:fm-task Down' \
    'send-keys -t crew:fm-task Enter')
  [ "$(cat "$log")" = "$expected" ] || fail "auto-clear sent unexpected tmux commands"
  pass "active prompt sends Down then Enter to choose Keep waiting"
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

test_watcher_clears_only_recorded_window() {
  local dir fb capture log state out expected
  dir="$TMP_ROOT/watcher"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; log="$dir/tmux.log"; state="$dir/state"; out="$dir/out"
  mkdir -p "$state"
  write_prompt "$capture" 1
  printf '%s\n' 'window=crew:fm-recorded' 'kind=ship' > "$state/task.meta"
  : > "$log"
  FM_STATE_OVERRIDE="$state" FM_WATCH_KEEPALIVE=0 FM_CHECK_INTERVAL=9999999 \
    FM_HEARTBEAT=0 FM_SAFETY_AUTOCLEAR_DELAY=0 FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_LOG="$log" PATH="$fb:$PATH" "$WATCH" > "$out" \
    || fail "watcher exited non-zero"
  grep -Fx 'heartbeat' "$out" >/dev/null || fail "watcher did not complete its poll"
  expected=$(printf '%s\n' \
    'capture-pane -p -t crew:fm-recorded -S -20' \
    'send-keys -t crew:fm-recorded Down' \
    'send-keys -t crew:fm-recorded Enter')
  [ "$(cat "$log")" = "$expected" ] || fail "watcher touched a pane outside recorded metadata"
  pass "watcher clears the recorded crewmate before stale classification"
}

test_active_prompt_selects_keep_waiting
test_selected_keep_waiting_is_confirmed_without_moving
test_non_menu_content_does_not_trigger
test_disabled_does_not_capture_or_send
test_watcher_clears_only_recorded_window
printf 'all safety auto-clear tests passed\n'
