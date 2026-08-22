#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
# Source the daemon's pure classifiers once. The daemon's main loop is skipped
# under sourcing via its BASH_SOURCE guard, so only the testable functions
# (classify_*, housekeeping, escalate_*, stale_marker_*) become defined.
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$DAEMON"
fi
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-wake-tests.XXXXXX")
export FM_WATCH_KEEPALIVE=0

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-windows" ]; then
  if [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then
    printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
  fi
  exit 0
fi
if [ "${1:-}" = "capture-pane" ]; then
  if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ]; then
    cat "$FM_FAKE_TMUX_CAPTURE"
  fi
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

# Like make_case, but the fake tmux also covers the sub-supervisor daemon's
# surface (display-message pane probe, send-keys capture) so the daemon's
# injection + housekeeping paths can be exercised. Behavior is controlled via
# FM_FAKE_TMUX_* env vars set per test.
make_supercase() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-panes)
    # Pane presence is probed with list-panes, which fails for a gone target.
    [ "${FM_FAKE_TMUX_PANE_ALIVE:-1}" = "1" ] || { printf "can't find window\n" >&2; exit 1; }
    printf 'fakepane\n'
    exit 0 ;;
  display-message)
    # Real tmux answers display-message from the client's current pane even when
    # the target is gone, so this fake never fails - only list-panes above can.
    _print=0
    # Return cursor_y when the format asks for it (pane_input_pending).
    for _a in "$@"; do
      case "$_a" in *cursor_y*) printf '%s\n' "${FM_FAKE_TMUX_CURSOR_Y:-0}"; exit 0 ;; esac
      [ "$_a" = "-p" ] && _print=1
    done
    [ "$_print" = 1 ] && printf 'fakepane\n'
    exit 0 ;;
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    exit 0 ;;
  capture-pane)
    # Honor a single-line band capture (-S N -E M, both non-negative) the way the
    # composer reader now bounds its capture to the cursor row; otherwise (e.g.
    # fm_pane_is_busy's "-S -40" tail) return the whole capture. -e is accepted and
    # ignored: this fake emits plain text, which the dim-stripper passes through.
    _S=""; _E=""; shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -S) _S="${2:-}"; shift 2; continue ;;
        -E) _E="${2:-}"; shift 2; continue ;;
        *) shift ;;
      esac
    done
    [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] || exit 0
    if [ -n "$_S" ] && [ -n "$_E" ]; then
      case "$_S$_E" in
        *[!0-9]*) cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
        *) sed -n "$((_S + 1)),$((_E + 1))p" "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
      esac
    else
      cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null
    fi
    exit 0 ;;
  send-keys)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -l) shift; [ "$#" -gt 0 ] && {
          printf '%s\n' "$1" >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
          # Reflect sent text into capture so pane_input_pending sees it as
          # pending input (text in the composer).
          [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && printf '%s\n' "$1" >> "$FM_FAKE_TMUX_CAPTURE"
        } ;;
        Enter)
          # Optionally swallow Enter (file-based flag) to test the retry path.
          if [ -n "${FM_FAKE_TMUX_SWALLOW_FILE:-}" ] && [ -f "$FM_FAKE_TMUX_SWALLOW_FILE" ]; then
            rm -f "$FM_FAKE_TMUX_SWALLOW_FILE"
          else
            printf '[ENTER]\n' >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
            # Enter submits: clear the last line (the typed text) from the
            # capture, simulating the composer being cleared on submit.
            if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && [ -s "$FM_FAKE_TMUX_CAPTURE" ]; then
              _tmp=$(mktemp 2>/dev/null) || _tmp="${FM_FAKE_TMUX_CAPTURE}.tmp"
              sed '$d' "$FM_FAKE_TMUX_CAPTURE" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$FM_FAKE_TMUX_CAPTURE"
              rm -f "$_tmp" 2>/dev/null
            fi
          fi
          ;;
      esac
      shift
    done
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

test_daemon_state_root_uses_fm_home() {
  local dir home override out
  dir=$(make_supercase daemon-fm-home)
  home="$dir/firstmate-home"
  override="$dir/override-state"
  mkdir -p "$home" "$override"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE='' _state_root)
  [ "$out" = "$home/state" ] || fail "daemon state root ignored FM_HOME: $out"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$override" _state_root)
  [ "$out" = "$override" ] || fail "daemon state root ignored FM_STATE_OVERRIDE: $out"

  pass "supervise daemon state root is scoped by FM_HOME"
}

append_wake() {
  local state=$1 kind=$2 key=$3 payload=$4
  (
    export FM_STATE_OVERRIDE="$state"
    # shellcheck disable=SC1090
    . "$LIB"
    fm_wake_append "$kind" "$key" "$payload"
  )
}

wait_for_exit() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      return "$?"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}

is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in *Z*) return 1 ;; esac
  return 0
}

hash_text() {
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

test_concurrent_append_and_drain() {
  local dir state out1 out2 all pids i pid count unique malformed
  dir=$(make_case concurrent)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    append_wake "$state" signal "status-$i" "signal: $state/status-$i.status" &
    pids="$pids $!"
    i=$((i + 1))
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pids="$pids $!"
  for pid in $pids; do
    wait "$pid" || fail "concurrent append/drain subprocess failed"
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" || fail "final drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 40 ] || fail "expected 40 drained records, got $count"
  malformed=$(awk -F '\t' 'NF != 5 { bad++ } END { print bad + 0 }' "$all")
  [ "$malformed" -eq 0 ] || fail "drained records had malformed fields"
  unique=$(awk -F '\t' '{ keys[$4] = 1 } END { for (k in keys) count++; print count + 0 }' "$all")
  [ "$unique" -eq 40 ] || fail "expected 40 unique keys, got $unique"
  pass "concurrent append plus drain preserves queue records"
}

test_delayed_receipt_publication_does_not_lose_lock_ownership() {
  local dir state ready delayed_pid out count
  if ! command -v flock >/dev/null 2>&1; then
    pass "delayed receipt publication check skipped: no flock(1) on this host"
    return
  fi
  dir=$(make_case delayed-receipt)
  state="$dir/state"
  ready="$dir/receipt-opened"
  out="$dir/drain.out"

  (
    export FM_STATE_OVERRIDE="$state" FM_LOCK_STALE_AFTER=0
    # shellcheck disable=SC1090
    . "$LIB"
    # The pid file is opened before this function runs.  Delaying here
    # deterministically recreates the old mkdir-to-receipt handoff window.
    fm_current_pid() {
      : > "$ready"
      sleep 0.3
      printf '%s\n' "${BASHPID:-$$}"
    }
    fm_wake_append signal delayed "signal: delayed"
  ) &
  delayed_pid=$!
  while [ ! -e "$ready" ]; do sleep 0.01; done
  append_wake "$state" signal contender "signal: contender" \
    || fail "contender append failed while receipt publication was delayed"
  wait "$delayed_pid" || fail "delayed append lost lock ownership"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "delayed receipt drain failed"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 2 ] || fail "expected both delayed-receipt wakes, got $count"
  pass "delayed PID receipt publication retains exclusive wake ownership"
}

test_signal_catchup_without_running_watcher() {
  local dir state fakebin out drain_out status_file
  dir=$(make_case signal)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: first\n' > "$status_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for first signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print first signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after first signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "first signal was not queued"

  printf 'done: second\n' >> "$status_file"
  : > "$out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for second signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "signal written with no watcher was not caught"
  pass "signal written while no watcher runs is caught on next run"
}

test_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash
  dir=$(make_case stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stale"
  printf 'idle prompt' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stale.meta"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for stale pane"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not written"
  pass "stale wake is queued before suppressor state is advanced"
}

test_check_output_is_queued() {
  local dir state fakebin out drain_out check_file
  dir=$(make_case check)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/1\n'
SH
  chmod +x "$check_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for check output"
  grep -F "check: $check_file: merged: https://example.test/pr/1" "$out" >/dev/null || fail "watcher did not print check wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after check wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/1' >/dev/null || fail "check wake was not queued"
  [ -e "$state/.last-check" ] || fail "check cadence marker was not written after queue append"
  pass "check output is queued before cadence suppression"
}

test_singleton_start() {
  local dir state fakebin out1 out2 pid1 pid2 live
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/watch-one.out"
  out2="$dir/watch-two.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out1" &
  pid1=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out2" &
  pid2=$!
  sleep 0.5
  live=0
  is_live_non_zombie "$pid1" && live=$((live + 1))
  is_live_non_zombie "$pid2" && live=$((live + 1))
  [ "$live" -eq 1 ] || fail "expected exactly one live watcher, got $live"
  grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null || fail "second watcher did not report existing singleton"
  kill "$pid1" "$pid2" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  pass "simultaneous watcher starts leave exactly one live process"
}

test_atomic_double_drain() {
  local dir state out1 out2 all count leftover
  dir=$(make_case double-drain)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat append failed"
  append_wake "$state" signal task "signal: $state/task.status" || fail "signal append failed"
  append_wake "$state" stale 's:fm-task' 'stale: s:fm-task' || fail "stale append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pid1=$!
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" &
  pid2=$!
  wait "$pid1" || fail "first drain failed"
  wait "$pid2" || fail "second drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 3 ] || fail "two drains consumed records more than once or lost records; got $count"
  leftover=$(FM_STATE_OVERRIDE="$state" "$DRAIN" | awk 'NF { count++ } END { print count + 0 }')
  [ "$leftover" -eq 0 ] || fail "queue was not empty after double drain"
  pass "two atomic drains cannot consume the same records twice"
}

test_drain_reports_lock_release_failure() {
  local dir state fakebin out status
  dir=$(make_case drain-release-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/drain.out"
  cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  *".wake-queue.lock/pid") printf '2147483647\n'; exit 0 ;;
esac
exec /bin/cat "$@"
SH
  chmod +x "$fakebin/cat"
  append_wake "$state" heartbeat heartbeat heartbeat \
    || fail "release-failure wake append failed"
  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || status=$?
  [ "$status" -ne 0 ] || fail "drain hid queue lock release failure"
  grep "$(printf '\theartbeat\theartbeat\theartbeat')" "$out" >/dev/null \
    || fail "release-failure drain lost its emitted wake"
  pass "drain propagates queue lock release failure"
}

test_drain_dedupes_obvious_duplicates() {
  local dir state out count
  dir=$(make_case dedupe)
  state="$dir/state"
  out="$dir/drain.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "first heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "first signal append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "second heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status $state/task.turn-ended" || fail "second signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "dedupe drain failed"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 2 ] || fail "expected 2 deduped records, got $count"
  grep "$(printf '\theartbeat\theartbeat\theartbeat')" "$out" >/dev/null || fail "heartbeat was not preserved"
  grep "$(printf '\tsignal\ttask.status\t')" "$out" | grep -F "$state/task.turn-ended" >/dev/null || fail "latest signal payload was not preserved"
  pass "drain collapses obvious duplicate heartbeat and signal records"
}

test_stale_watch_lock_reclaimed() {
  local dir state fakebin out dead_pid pid live lock_pid
  dir=$(make_case stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  mkdir "$state/.watch.lock"
  printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  sleep 0.5
  live=0
  is_live_non_zombie "$pid" && live=1
  [ "$live" -eq 1 ] || fail "watcher did not reclaim stale lock and stay alive"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" != "$dead_pid" ] || fail "stale watch lock pid was not replaced"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "killed watcher stale lock is reclaimed"
}

test_live_stale_watch_lock_is_actionable() {
  local dir state fakebin out err status
  dir=$(make_case live-stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher silently no-opped behind a live stale holder"
  grep -F 'heartbeat is stale' "$err" >/dev/null || fail "watcher did not explain the stale live lock"
  pass "live watcher lock with stale heartbeat is actionable"
}

test_keepalive_rearms_stale_missing_watcher() {
  local dir state fakebin out pid watcher_pid beat_age
  dir=$(make_case keepalive-rearm)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/keepalive.out"
  printf 'project=x\n' > "$state/task.meta"
  touch -t 200001010000 "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_KEEPALIVE=1 FM_WATCH_KEEPALIVE_INTERVAL=1 \
    FM_WATCHER_STALE_GRACE=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$WATCH" --keepalive > "$out" &
  pid=$!
  sleep 2.5
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$watcher_pid" ] || fail "keepalive did not start a one-shot watcher"
  is_live_non_zombie "$watcher_pid" || fail "keepalive watcher pid is not live"
  # shellcheck disable=SC1090
  beat_age=$(FM_STATE_OVERRIDE="$state" . "$LIB"; fm_path_age "$state/.last-watcher-beat")
  [ "$beat_age" -lt 3 ] || fail "keepalive watcher did not refresh heartbeat (age=$beat_age)"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  is_live_non_zombie "$watcher_pid" && fail "keepalive did not clean up child watcher on exit"
  pass "watch keepalive re-arms a stale missing watcher"
}

test_keepalive_stops_when_fleet_empty() {
  local dir state fakebin out pid live
  dir=$(make_case keepalive-empty)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/keepalive.out"
  touch -t 200001010000 "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_KEEPALIVE=1 FM_WATCH_KEEPALIVE_INTERVAL=1 \
    FM_WATCHER_STALE_GRACE=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$WATCH" --keepalive > "$out" &
  pid=$!
  sleep 1.5
  live=0
  is_live_non_zombie "$pid" && live=1
  [ "$live" -eq 0 ] || { kill "$pid" 2>/dev/null || true; fail "keepalive kept running with no tasks in flight"; }
  [ -e "$state/.watch.lock/pid" ] && fail "keepalive armed a watcher with no tasks in flight"
  wait "$pid" 2>/dev/null || true
  pass "watch keepalive stops cleanly when the fleet is empty"
}

test_guard_warns_on_pending_queue() {
  local dir state err
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=999999 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  pass "guard warns when queued wakes are pending"
}

test_guard_rearms_after_draining_pending_queue() {
  local dir state err
  dir=$(make_case guard-order)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  grep -F 'After draining queued wakes, re-arm the watcher' "$err" >/dev/null || fail "guard did not order re-arm after drain"
  ! grep -F 'Restart it NOW, before anything else' "$err" >/dev/null || fail "guard still gave conflicting restart-first instruction"
  pass "guard orders watcher re-arm after queued wake drain"
}

test_classify_routine_signal_self() {
  local dir state out
  dir=$(make_supercase classify-routine)
  state="$dir/state"
  printf 'working: step 1\nworking: step 2\n' > "$state/foo-x1.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/foo-x1.status" "$state")
  case "$out" in self\|*) pass "routine signal self-handles" ;; *) fail "routine signal did not self-handle: $out" ;; esac
}

test_classify_terminal_signal_escalates() {
  local dir state kw out
  dir=$(make_supercase classify-terminal)
  state="$dir/state"
  for kw in "done: PR https://x/y/pull/1" "needs-decision: pick A" "blocked: no perms" \
            "failed: rc 2" "PR ready https://x/y/pull/2" "checks green" \
            "ready in branch fm/t1" "merged"; do
    printf 'working\n%s\n' "$kw" > "$state/t.status"
    out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/t.status" "$state")
    case "$out" in escalate\|*) ;; *) fail "captain verb did not escalate ($kw): $out" ;; esac
  done
  pass "captain-relevant status verbs escalate"
}

test_classify_check_and_unknown_escalate() {
  local out
  out=$(classify_check "check: /s/c.check.sh: merged: https://x")
  case "$out" in escalate\|*) ;; *) fail "check did not escalate: $out" ;; esac
  out=$(classify_unknown "frobnicate: weird")
  case "$out" in escalate\|*) ;; *) fail "unknown did not fail-safe escalate: $out" ;; esac
  out=$(classify_heartbeat)
  case "$out" in self\|*) ;; *) fail "heartbeat did not self-handle: $out" ;; esac
  pass "check + unknown escalate; heartbeat self-handles"
}

test_stale_transient_self_records_marker() {
  local dir state out key
  dir=$(make_supercase stale-transient)
  state="$dir/state"
  printf 'working: building\n' > "$state/qux-w4.status"
  stale_marker_record "sess:fm-qux-w4" "$state"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-qux-w4" "$state")
  case "$out" in self\|*) ;; *) fail "transient stale did not self-handle: $out" ;; esac
  key=$(printf '%s' "$(window_to_task "sess:fm-qux-w4")" | tr ':/.' '___')
  [ -e "$state/.subsuper-stale-$key" ] || fail "stale marker was not recorded"
  pass "transient stale self-handles and records a persistence marker"
}

test_stale_terminal_escalates() {
  local dir state out
  dir=$(make_supercase stale-terminal)
  state="$dir/state"
  printf 'done: ready in branch fm/t1\n' > "$state/fin-t5.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-fin-t5" "$state")
  case "$out" in escalate\|*) ;; *) fail "terminal stale did not escalate: $out" ;; esac
  pass "stale + terminal status escalates immediately"
}

test_housekeeping_persistent_stale_escalates() {
  local dir state fakebin win pane key
  dir=$(make_supercase stale-persistent)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:fm-pers-w5"
  pane="$dir/pane.txt"
  printf 'working\n' > "$state/pers-w5.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "pers-w5" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "persistent stale was not escalated"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "stale marker not cleared after escalation"
  pass "persistent stale escalates after threshold and clears its marker"
}

test_housekeeping_resumed_stale_cleared() {
  local dir state fakebin win pane key
  dir=$(make_supercase stale-resumed)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:fm-res-w6"
  pane="$dir/pane.txt"
  printf 'working\n' > "$state/res-w6.status"
  printf 'Working...\n' > "$pane"
  key=$(printf '%s' "res-w6" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -e "$state/.subsuper-stale-$key" ] && fail "resumed stale marker was not cleared"
  [ -s "$state/.subsuper-escalations" ] && fail "resumed stale was escalated"
  pass "resumed (busy) stale clears its marker without escalating"
}

test_escalate_batches_into_one_digest() {
  local dir state fakebin sent capture n
  dir=$(make_supercase batch)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  escalate_add "$state" "event A: done: PR 1"
  escalate_add "$state" "event B: done: PR 2"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed"
  grep -F "event A" "$sent" >/dev/null || fail "batch digest missing event A"
  grep -F "event B" "$sent" >/dev/null || fail "batch digest missing event B"
  grep -F 'event A: done: PR 1 | event B: done: PR 2' "$sent" >/dev/null \
    || fail "batch digest did not join events with literal ' | '"
  [ -s "$state/.subsuper-escalations" ] && fail "escalation buffer not cleared after flush"
  [ -e "$state/.subsuper-escalations.since" ] && fail "first-append sidecar not cleared after flush"
  n=$(grep -c '\[ENTER\]' "$sent")
  [ "$n" -eq 1 ] || fail "expected one injected digest, got $n send-keys submits"
  pass "multiple escalations flush as a single batched digest"
}

test_escalate_batch_age_uses_first_append() {
  local dir state fakebin sent capture
  dir=$(make_supercase batch-age)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  escalate_add "$state" "event A: done: PR 1"
  escalate_add "$state" "event B: done: PR 2"
  echo $(( $(date +%s) - 100 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=90 FM_HOUSEKEEPING_TICK=0 \
    housekeeping "$state"
  grep -F 'event A: done: PR 1 | event B: done: PR 2' "$sent" >/dev/null \
    || fail "backdated batch did not flush as a joined digest (max-delay measured from last append)"
  [ -s "$state/.subsuper-escalations" ] && fail "escalation buffer not cleared after backdated flush"
  [ -e "$state/.subsuper-escalations.since" ] && fail "first-append sidecar not cleared after flush"
  pass "batch flush measures max-delay from the first append, not the last"
}

test_heartbeat_scan_dedup() {
  local dir state
  dir=$(make_supercase scan-dedup)
  state="$dir/state"
  printf 'done: ready\n' > "$state/dup-t6.status"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "catch-all scan did not escalate a terminal"
  : > "$state/.subsuper-escalations"
  echo $(( $(date +%s) - 99999 )) > "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] && fail "catch-all scan re-escalated the same terminal (dedup failed)"
  pass "catch-all scan escalates a missed terminal once, not twice"
}

test_handle_wake_routes_self_and_escalate() {
  local dir state
  dir=$(make_supercase handle)
  state="$dir/state"
  printf 'working\n' > "$state/h-routine.status"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/h-routine.status" "$state"
  [ -s "$state/.subsuper-escalations" ] && fail "routine signal was escalated by handle_wake"
  printf 'done: PR 1\n' > "$state/h-done.status"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/h-done.status" "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "captain signal was not buffered by handle_wake"
  pass "handle_wake routes routine->self and captain->escalate"
}

test_inject_skip_forces_self() {
  local dir state
  dir=$(make_supercase skip)
  state="$dir/state"
  printf 'done: PR 1\n' > "$state/s1.status"
  FM_STATE_OVERRIDE="$state" FM_INJECT_SKIP="signal" handle_wake "signal: $state/s1.status" "$state"
  [ -s "$state/.subsuper-escalations" ] && fail "INJECT_SKIP=signal did not force self-handle"
  pass "INJECT_SKIP forces self-handle, bypassing captain-relevant classification"
}

test_is_wake_reason_distinguishes_status_stdout() {
  # Real wake reasons are recognized; watcher status lines (singleton collision)
  # are not, so the main loop can idle them without flooding escalations.
  is_wake_reason "signal: /x/y.status" || fail "signal: not recognized as wake"
  is_wake_reason "stale: s:fm-x" || fail "stale: not recognized as wake"
  is_wake_reason "check: /s/c.sh: merged" || fail "check: not recognized as wake"
  is_wake_reason "heartbeat" || fail "heartbeat not recognized as wake"
  is_wake_reason "watcher: already running" && fail "singleton status line misclassified as wake"
  is_wake_reason "watcher: already running pid 123" && fail "singleton status (pid) misclassified as wake"
  pass "is_wake_reason distinguishes watcher wake reasons from singleton-status stdout"
}

test_terminal_stale_escalate_leaves_no_marker() {
  local dir state win key
  dir=$(make_supercase stale-terminal-nomarker)
  state="$dir/state"
  win="sess:fm-fin-n7"
  printf 'done: PR https://x/y/pull/7\n' > "$state/fin-n7.status"
  key=$(printf '%s' "fin-n7" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  FM_STATE_OVERRIDE="$state" handle_wake "stale: $win" "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "terminal stale was not escalated"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "terminal stale left a persistence marker (housekeeping would re-escalate)"
  : > "$state/.subsuper-escalations"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "housekeeping re-escalated a terminal stale as a wedge"
  pass "terminal-stale escalate removes its marker so housekeeping does not re-escalate"
}

# The watcher reports a process-tree death as "stale: <window> (no live agent
# process)". The trailing annotation must never be parsed as part of the window:
# doing so looks up the wrong status file (self-handle instead of escalate) and
# writes a marker key housekeeping can never map back to a window, so the one
# wake fm-watch fires per generation is discarded while the captain is away.
test_dead_agent_stale_wake_parses_window_and_escalates() {
  local dir state win out
  dir=$(make_supercase stale-dead-agent)
  state="$dir/state"
  win="sess:fm-gone-d3"
  printf 'working: mid-task\n' > "$state/gone-d3.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "$win" "$state" "(no live agent process)")
  [ "${out%%|*}" = escalate ] \
    || fail "dead-agent stale was not classified as escalate: $out"
  FM_STATE_OVERRIDE="$state" handle_wake "stale: $win (no live agent process)" "$state"
  grep -F "$win" "$state/.subsuper-escalations" >/dev/null \
    || fail "dead-agent stale wake was not escalated: $(cat "$state/.subsuper-escalations" 2>/dev/null)"
  grep -F 'no live agent process)' "$state/.subsuper-escalations" >/dev/null \
    && fail "the trailing annotation leaked into the escalated window name"
  ls "$state"/.subsuper-stale-* >/dev/null 2>&1 \
    && fail "dead-agent stale left a persistence marker housekeeping cannot map back"

  dir=$(make_supercase stale-dead-agent-terminal)
  state="$dir/state"
  win="sess:fm-fin-d4"
  printf 'done: PR https://x/y/pull/4\n' > "$state/fin-d4.status"
  FM_STATE_OVERRIDE="$state" handle_wake "stale: $win (no live agent process)" "$state"
  grep -F 'done: PR https://x/y/pull/4' "$state/.subsuper-escalations" >/dev/null \
    || fail "annotated stale did not read the recorded task's status file"
  [ -e "$state/.subsuper-seen-status-fin-d4" ] \
    || fail "seen marker was not keyed to the bare task id: $(ls "$state" | tr '\n' ' ')"

  dir=$(make_supercase stale-plain-transient)
  state="$dir/state"
  printf 'working: mid-task\n' > "$state/plain-d5.status"
  FM_STATE_OVERRIDE="$state" handle_wake "stale: sess:fm-plain-d5" "$state"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "plain transient stale was escalated: $(cat "$state/.subsuper-escalations")"
  [ -e "$state/.subsuper-stale-plain-d5" ] \
    || fail "plain transient stale did not record its persistence marker"
  pass "dead-agent stale wake parses the bare window, escalates, and leaves no garbled marker"
}

test_signal_escalate_marks_seen_no_catchall_refire() {
  local dir state key
  dir=$(make_supercase signal-seen)
  state="$dir/state"
  printf 'done: PR https://x/y/pull/8\n' > "$state/sig-t8.status"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/sig-t8.status" "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "captain signal was not escalated"
  key=$(printf '%s' "sig-t8" | tr ':/.' '___')
  [ "$(cat "$state/.subsuper-seen-status-$key" 2>/dev/null || true)" = "done: PR https://x/y/pull/8" ] \
    || fail "captain signal escalate did not write the seen-status marker"
  : > "$state/.subsuper-escalations"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "catch-all scan re-fired an already-escalated signal"
  pass "captain signal escalate marks seen so the catch-all scan does not re-fire"
}

test_timestamped_status_uses_raw_dedupe_and_clean_presentation() {
  local dir state fakebin sent capture raw1 raw2 raw3 key out
  dir=$(make_supercase timestamped-status)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"
  capture="$dir/pane.txt"
  : > "$sent"
  : > "$capture"
  raw1=$'done: PR https://x/y/pull/11\t1700000123'
  raw2=$'done: PR https://x/y/pull/11\t1700000456'
  raw3=$'needs-decision: choose release window\t1700000789'
  printf '%s\n' "$raw1" > "$state/stamped-s11.status"

  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/stamped-s11.status" "$state")
  case "$out" in
    escalate\|*"done: PR https://x/y/pull/11"*) ;;
    *) fail "timestamped signal did not present clean receipt text: $out" ;;
  esac
  case "$out" in *$'\t'*|*1700000123*) fail "timestamped signal leaked receipt metadata: $out" ;; esac

  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/stamped-s11.status" "$state"
  key=$(printf '%s' "stamped-s11" | tr ':/.' '___')
  [ "$(cat "$state/.subsuper-seen-status-$key" 2>/dev/null || true)" = "$raw1" ] \
    || fail "seen marker did not preserve the raw timestamped receipt"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/stamped-s11.status" "$state")
  case "$out" in self\|*) ;; *) fail "unchanged raw receipt was not deduped: $out" ;; esac

  printf '%s\n' "$raw2" >> "$state/stamped-s11.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/stamped-s11.status" "$state")
  case "$out" in
    escalate\|*"done: PR https://x/y/pull/11"*) ;;
    *) fail "new raw receipt version with identical text was incorrectly deduped: $out" ;;
  esac
  case "$out" in *$'\t'*|*1700000456*) fail "new receipt version leaked metadata: $out" ;; esac

  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-stamped-s11" "$state")
  case "$out" in escalate\|*"done: PR https://x/y/pull/11"*) ;; *) fail "stale presentation was not clean: $out" ;; esac
  case "$out" in *$'\t'*|*1700000456*) fail "stale presentation leaked receipt metadata: $out" ;; esac

  printf '%s\n' "$raw3" > "$state/scanned-s12.status"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  if grep -F $'\t' "$state/.subsuper-escalations" >/dev/null \
    || grep -E '1700000123|1700000456|1700000789' "$state/.subsuper-escalations" >/dev/null; then
    fail "escalation buffer leaked timestamp receipt metadata"
  fi

  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" escalate_flush "$state" \
    || fail "timestamped escalation digest did not inject"
  if grep -F $'\t' "$sent" >/dev/null \
    || grep -E '1700000123|1700000456|1700000789' "$sent" >/dev/null; then
    fail "injected digest leaked timestamp receipt metadata"
  fi
  pass "timestamped statuses retain raw dedupe and present clean text"
}

# ============================================================================
# /afk presence-gating + injection hardening
# ============================================================================

# The daemon's own injection target is guarded with the same list-panes probe as
# every other pane check: display-message answers from the client's current pane
# for a target that is gone, so a guard built on it can never fail and the daemon
# keeps treating a vanished firstmate pane as a live one.
test_inject_refuses_a_gone_target() {
  local dir state fakebin sent capture
  dir=$(make_supercase inject-gone-target)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  afk_enter "$state"
  escalate_add "$state" "done: PR https://x/y/pull/13"
  if PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=0 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state"; then
    fail "escalate_flush reported success with a gone injection target"
  fi
  [ ! -s "$sent" ] \
    || fail "the daemon typed into a pane after its own target vanished: $(cat "$sent")"
  [ -s "$state/.subsuper-escalations" ] \
    || fail "escalations were dropped instead of preserved for the next flush"
  pass "a gone injection target is detected: nothing is typed and the buffer survives"
}

test_collapse_newlines_pure() {
  local out
  out=$(_collapse_newlines $'line one\nline two\nline three')
  [ "$out" = "line one - line two - line three" ] || fail "collapse failed: '$out'"
  out=$(_collapse_newlines "no newlines here")
  [ "$out" = "no newlines here" ] || fail "collapse changed no-newline text"
  out=$(_collapse_newlines $'a\nb')
  [ "$out" = "a - b" ] || fail "collapse two lines failed: '$out'"
  pass "_collapse_newlines replaces newlines with literal separator"
}

test_afk_absent_daemon_does_not_inject() {
  local dir state fakebin sent capture
  dir=$(make_supercase afk-off)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  escalate_add "$state" "done: PR 1"
  # afk flag deliberately NOT set
  if PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state"; then
    fail "escalate_flush succeeded while afk inactive"
  fi
  [ -s "$sent" ] && fail "daemon injected while afk inactive"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer not preserved when afk inactive"
  pass "afk flag absent: daemon does not inject, buffer preserved"
}

test_afk_present_injects_with_marker() {
  local dir state fakebin sent capture sent_line
  dir=$(make_supercase afk-on)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  escalate_add "$state" "done: PR 1"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed with afk active"
  [ -s "$sent" ] || fail "no injection sent with afk active"
  sent_line=$(grep -v '\[ENTER\]' "$sent" | head -1)
  message_is_injection "$sent_line" || fail "injection not prefixed with sentinel marker"
  pass "afk flag present: daemon injects with sentinel marker prefix"
}

test_inject_digest_is_single_line() {
  local dir state fakebin sent capture non_enter
  dir=$(make_supercase single-line)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  escalate_add "$state" "done: PR https://x/y/pull/1"
  escalate_add "$state" "needs-decision: pick A"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed"
  # The sent log is: <digest-line>\n[ENTER]\n. The digest must be exactly one
  # line (no embedded newlines that would fragment submission).
  non_enter=$(grep -cv '\[ENTER\]' "$sent")
  [ "$non_enter" -eq 1 ] || fail "expected 1 digest line, got $non_enter (embedded newlines?)"
  grep -v '\[ENTER\]' "$sent" | grep -qF 'done: PR https://x/y/pull/1' \
    || fail "digest missing first event"
  grep -v '\[ENTER\]' "$sent" | grep -qF 'needs-decision: pick A' \
    || fail "digest missing second event"
  pass "injected digest is single-line (no embedded newlines)"
}

test_busy_guard_defers_when_supervisor_busy() {
  local dir state fakebin sent capture
  dir=$(make_supercase busy-guard)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"
  # pane shows a busy signature (firstmate mid-turn)
  printf 'esc to interrupt\n' > "$capture"
  escalate_add "$state" "done: PR 1"
  afk_enter "$state"
  if PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state"; then
    fail "escalate_flush should defer when supervisor pane busy"
  fi
  [ -s "$sent" ] && fail "daemon injected into a busy pane"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer not preserved when deferred"
  pass "busy-guard defers injection when supervisor pane is busy"
}

test_marker_detection() {
  # message_is_injection: marker present -> injection; absent -> real message
  message_is_injection "${FM_INJECT_MARK}Supervisor escalate: done" \
    || fail "marker-prefixed message not detected as injection"
  message_is_injection "how's it going?" \
    && fail "plain message misdetected as injection"
  message_is_injection "" && fail "empty message misdetected as injection"
  # should_exit_afk: the full afk-exit contract
  local dir state
  dir=$(make_supercase marker-detect)
  state="$dir/state"
  afk_enter "$state"
  should_exit_afk "$state" "${FM_INJECT_MARK}escalate" \
    && fail "marker message should not exit afk (internal escalation)"
  should_exit_afk "$state" "status update please" \
    || fail "plain message should exit afk (captain is back)"
  pass "marker detection: marker -> stay afk, no marker -> exit afk"
}

test_afk_turn_exemption() {
  local dir state
  dir=$(make_supercase afk-exempt)
  state="$dir/state"
  afk_enter "$state"
  # /afk while already away must NOT self-cancel (re-entering/extending)
  should_exit_afk "$state" "/afk" \
    && fail "bare /afk should not exit afk"
  should_exit_afk "$state" "/afk back in an hour" \
    && fail "/afk with args should not exit afk"
  # a non-/afk skill invocation DOES exit (the captain is actively working)
  should_exit_afk "$state" "/no-mistakes" \
    || fail "non-afk skill should exit afk"
  pass "/afk invocation is exempt from afk exit (no self-cancel)"
}

test_should_exit_afk_when_afk_inactive() {
  local dir state
  dir=$(make_supercase no-afk)
  state="$dir/state"
  # afk flag absent: should never signal exit (nothing to exit)
  should_exit_afk "$state" "hello" \
    && fail "should_exit_afk true when afk inactive"
  should_exit_afk "$state" "${FM_INJECT_MARK}test" \
    && fail "should_exit_afk true when afk inactive (marker)"
  pass "should_exit_afk returns false when afk is not active"
}

# ============================================================================
# Injection hardening: composer guard, type-once submit, strip marker, dedupe
# ============================================================================

test_strip_injection_marker() {
  local stripped
  stripped=$(strip_injection_marker "${FM_INJECT_MARK}Supervisor escalate: done")
  [ "$stripped" = "Supervisor escalate: done" ] \
    || fail "marker not stripped: '$stripped'"
  # No marker → unchanged.
  stripped=$(strip_injection_marker "no marker here")
  [ "$stripped" = "no marker here" ] \
    || fail "non-marker text changed: '$stripped'"
  # Empty → empty.
  stripped=$(strip_injection_marker "")
  [ "$stripped" = "" ] || fail "empty text changed: '$stripped'"
  # Only marker → empty.
  stripped=$(strip_injection_marker "$FM_INJECT_MARK")
  [ "$stripped" = "" ] || fail "bare marker not stripped: '$stripped'"
  pass "strip_injection_marker removes the sentinel marker cleanly"
}

test_pane_input_pending_detects_partial_input() {
  local dir state fakebin capture
  dir=$(make_supercase pending-input)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  # Line 3 (cursor_y=2) has human's partial text (no Enter) → pending.
  printf 'line one\nline two\nhuman draft text\n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
    pane_input_pending "fakepane" \
    || fail "pane_input_pending should detect non-empty composer (human text)"
  pass "pane_input_pending detects partial input on the cursor line"
}

test_pane_input_pending_blank_is_not_pending() {
  local dir state fakebin capture
  dir=$(make_supercase pending-blank)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  # Cursor line (line 3, cursor_y=2) is blank → not pending.
  printf 'some output\nmore output\n\n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
    pane_input_pending "fakepane" \
    && fail "blank composer line falsely detected as pending"
  pass "pane_input_pending: blank cursor line is not pending"
}

test_pane_input_pending_idle_prompt_not_pending() {
  local dir state fakebin capture
  dir=$(make_supercase pending-prompt)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  # Cursor line (line 3, cursor_y=2) is a bare prompt ($) → idle → not pending.
  printf 'output\noutput\n$ \n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
    pane_input_pending "fakepane" \
    && fail "bare prompt falsely detected as pending"
  # Bare > prompt also idle.
  printf 'output\noutput\n> \n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
    pane_input_pending "fakepane" \
    && fail "bare > prompt falsely detected as pending"
  pass "pane_input_pending: bare prompts are not pending (idle)"
}

test_pane_input_pending_honors_idle_override_after_border_strip() {
  local dir state fakebin capture
  dir=$(make_supercase pending-custom-idle)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  printf '│ custom idle> │\n' > "$capture"
  # Assert the positive state, not merely "not pending": unknown also satisfies
  # not-pending, so a dead override would pass that check vacuously.
  local got
  got=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    FM_COMPOSER_IDLE_RE='^custom idle>$' fm_tmux_composer_state "fakepane")
  [ "$got" = empty ] \
    || fail "FM_COMPOSER_IDLE_RE was not applied after border stripping (got $got)"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    FM_COMPOSER_IDLE_RE='^custom idle>$' pane_input_pending "fakepane" \
    && fail "an idle composer matching FM_COMPOSER_IDLE_RE was treated as pending"
  pass "pane_input_pending honors FM_COMPOSER_IDLE_RE after border stripping"
}

test_composer_guard_defers_on_partial_input() {
  local dir state fakebin sent capture
  dir=$(make_supercase composer-guard)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"
  # Cursor line has partial text (human mid-typing, no Enter).
  printf 'human draft text\n' > "$capture"
  escalate_add "$state" "done: PR 1"
  afk_enter "$state"
  if PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state"; then
    fail "escalate_flush should defer when composer has pending input"
  fi
  [ -s "$sent" ] && fail "daemon injected into a pane with pending input"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer not preserved when deferred"
  pass "composer guard defers injection when pane has pending input"
}

test_inject_types_once_retries_enter_only() {
  # Scenario: Enter is swallowed on the first attempt. The daemon must retry
  # Enter (NOT retype the digest) and succeed on the second Enter. Assert
  # exactly ONE digest was typed (no concatenation), and the digest was
  # eventually submitted.
  local dir state fakebin sent capture swallow_file
  dir=$(make_supercase swallow-enter)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  swallow_file="$dir/.swallow"
  touch "$swallow_file"
  escalate_add "$state" "done: PR 1"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_SWALLOW_FILE="$swallow_file" \
    FM_INJECT_CONFIRM_SLEEP=0.1 FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed despite Enter retry"
  # Exactly ONE digest line typed (send-keys -l called once). No retype.
  local digest_lines
  digest_lines=$(grep -cv '\[ENTER\]' "$sent")
  [ "$digest_lines" -eq 1 ] \
    || fail "expected 1 digest type, got $digest_lines (retype into uncleared composer?)"
  # Two Enters: first swallowed, second submitted.
  local enters
  enters=$(grep -c '\[ENTER\]' "$sent")
  [ "$enters" -eq 1 ] \
    || fail "expected 1 recorded Enter (second after swallow), got $enters"
  # Buffer cleared → success.
  [ -s "$state/.subsuper-escalations" ] && fail "buffer not cleared after successful inject"
  pass "swallowed Enter: type-once + Enter-retry, no concatenation"
}

test_inject_no_duplicate_on_success() {
  # Scenario: normal inject (Enter works first time). Exactly ONE digest typed,
  # ONE Enter, buffer cleared.
  local dir state fakebin sent capture
  dir=$(make_supercase normal-inject)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  escalate_add "$state" "done: PR 1"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_INJECT_CONFIRM_SLEEP=0.1 \
    FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed"
  local digest_lines enters
  digest_lines=$(grep -cv '\[ENTER\]' "$sent")
  [ "$digest_lines" -eq 1 ] || fail "expected 1 digest, got $digest_lines (duplicate?)"
  enters=$(grep -c '\[ENTER\]' "$sent")
  [ "$enters" -eq 1 ] || fail "expected 1 Enter, got $enters"
  [ -s "$state/.subsuper-escalations" ] && fail "buffer not cleared"
  pass "normal inject: exactly one digest, one Enter, no duplicates"
}

test_classify_signal_dedup_against_scan() {
  # If the catch-all scan already escalated a status (seen marker matches),
  # classify_signal must self-handle to avoid a duplicate in the digest.
  local dir state key out
  dir=$(make_supercase signal-dedup)
  state="$dir/state"
  printf 'done: PR https://x/y/pull/9\n' > "$state/dup-s9.status"
  # Simulate the catch-all scan having already escalated this status.
  key=$(printf '%s' "dup-s9" | tr ':/.' '___')
  printf 'done: PR https://x/y/pull/9' > "$state/.subsuper-seen-status-$key"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/dup-s9.status" "$state")
  case "$out" in self\|*) ;; *) fail "signal not deduped against scan: $out" ;; esac
  # Without the seen marker, it should escalate.
  rm -f "$state/.subsuper-seen-status-$key"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/dup-s9.status" "$state")
  case "$out" in escalate\|*) ;; *) fail "signal should escalate when not seen: $out" ;; esac
  pass "classify_signal dedupes against the catch-all scan seen marker"
}

test_classify_stale_dedup_against_signal() {
  # If the signal path already escalated a status (seen marker matches),
  # classify_stale must self-handle to avoid a duplicate in the digest.
  local dir state key out
  dir=$(make_supercase stale-dedup)
  state="$dir/state"
  printf 'done: PR https://x/y/pull/10\n' > "$state/dup-s10.status"
  key=$(printf '%s' "dup-s10" | tr ':/.' '___')
  printf 'done: PR https://x/y/pull/10' > "$state/.subsuper-seen-status-$key"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-dup-s10" "$state")
  case "$out" in self\|*) ;; *) fail "stale not deduped against signal: $out" ;; esac
  # Without the seen marker, it should escalate.
  rm -f "$state/.subsuper-seen-status-$key"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-dup-s10" "$state")
  case "$out" in escalate\|*) ;; *) fail "stale should escalate when not seen: $out" ;; esac
  pass "classify_stale dedupes against the signal path seen marker"
}

# ============================================================================
# afk-invx-i5 regressions: bordered-composer detection (RC1), submit-ACK on a
# bordered composer (RC2), and the max-defer escape (RC1b).
# ============================================================================

# Fake tmux simulating a claude-style BORDERED composer ("│ > … │"), the exact
# rendering the old detector misread as permanent pending input.
#   - display-message cursor_y -> 0 (composer is line 1)
#   - capture-pane          -> the current composer line from $FM_FAKE_COMPOSER
#   - send-keys -l <text>   -> composer becomes "│ > <text> │"  (typed, unsent)
#   - send-keys Enter       -> unless $FM_FAKE_SWALLOW exists, composer clears to
#                              "│ > │" (bordered-empty); a one-shot swallow
#                              deletes the flag, a persistent one keeps it.
# $FM_FAKE_SENT (optional) logs each typed line and each non-swallowed [ENTER].
make_bordered_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  printf '│ > │\n' > "$dir/composer"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?FM_FAKE_COMPOSER unset}"
case "${1:-}" in
  list-panes)
    # Pane presence is probed with list-panes, which fails for a gone target.
    [ "${FM_FAKE_TMUX_PANE_ALIVE:-1}" = "1" ] || { printf "can't find window\n" >&2; exit 1; }
    printf 'fakepane\n'
    exit 0 ;;
  display-message)
    print=0
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    for a in "$@"; do [ "$a" = "-p" ] && print=1; done
    [ "$print" = 1 ] && printf 'fakepane\n'
    exit 0 ;;
  capture-pane) cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    shift
    text=""; is_enter=0; is_escape=0; lit=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l) lit=1 ;;
        Enter) is_enter=1 ;;
        Escape) is_escape=1 ;;
        *) [ "$lit" = 1 ] && text="$1" ;;
      esac
      shift
    done
    if [ "$is_escape" = 1 ]; then
      [ -n "${FM_FAKE_SENT:-}" ] && printf '[ESCAPE]\n' >> "$FM_FAKE_SENT"
      if [ "${FM_FAKE_ESCAPE_CLEARS:-0}" = 1 ]; then
        printf '│ > │\n' > "$COMPOSER"
      fi
    elif [ "$is_enter" = 1 ]; then
      if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
      else
        [ -n "${FM_FAKE_SENT:-}" ] && printf '[ENTER]\n' >> "$FM_FAKE_SENT"
        if [ -n "${FM_FAKE_AFTER_ENTER_TEXT:-}" ]; then
          printf '│ > %s │\n' "$FM_FAKE_AFTER_ENTER_TEXT" > "$COMPOSER"
        else
          printf '│ > │\n' > "$COMPOSER"
        fi
      fi
    elif [ "$lit" = 1 ]; then
      [ "${FM_FAKE_SEND_FAIL:-0}" = 1 ] && exit 1
      [ -n "${FM_FAKE_SENT:-}" ] && printf '%s\n' "$text" >> "$FM_FAKE_SENT"
      printf '│ > %s │\n' "$text" > "$COMPOSER"
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

test_pane_input_pending_bordered_idle_not_pending() {
  # THE regression: an idle claude composer is a bordered box ("│ > … │"). The
  # old idle regex only matched a BARE prompt, so every idle claude pane read as
  # pending and the away-mode daemon deferred 100% of escalations for 9.5h.
  local dir state fakebin capture line
  dir=$(make_supercase pending-bordered-idle)
  state="$dir/state"; fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  for line in \
    "│ >                                            │" \
    "│ ❯                                            │" \
    "│ >  │" \
    "│                                              │"; do
    printf '%s\n' "$line" > "$capture"
    if PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
      pane_input_pending "fakepane"; then
      fail "bordered idle composer falsely detected as pending: <$line>"
    fi
  done
  pass "pane_input_pending: an idle bordered composer is NOT pending (afk-invx-i5)"
}

test_pane_input_pending_bordered_with_text_is_pending() {
  # Guard against over-broadening: real unsubmitted text inside the box must
  # still read as pending so the daemon defers (and the captain-return race is
  # still protected).
  local dir state fakebin capture
  dir=$(make_supercase pending-bordered-text)
  state="$dir/state"; fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  printf '%s\n' "│ > fix findings 1 and 3, skip 2               │" > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    pane_input_pending "fakepane" \
    || fail "real text inside a bordered composer was not detected as pending"
  pass "pane_input_pending: text inside a bordered composer is still pending"
}

test_submit_ack_confirms_on_bordered_empty_composer() {
  # RC2: the submit acknowledgement must recognize a bordered-EMPTY composer as
  # "submitted." The old ACK reused the broken check, so on claude it could never
  # confirm and always reported a false "Enter swallowed."
  local dir fakebin sent verdict
  dir=$(make_bordered_case ack-bordered)
  fakebin="$dir/fakebin"; sent="$dir/sent.log"; : > "$sent"
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    fm_tmux_submit_core "win" "the digest" 3 0.05 0.05)
  [ "$verdict" = empty ] || fail "submit-ACK did not confirm on a bordered-empty composer: $verdict"
  [ "$(grep -cv '\[ENTER\]' "$sent")" -eq 1 ] || fail "digest typed more than once (retype)"
  [ "$(grep -c '\[ENTER\]' "$sent")" -eq 1 ] || fail "expected exactly one submitted Enter"
  pass "submit-ACK confirms a submit when the composer returns to a bordered-empty box"
}

test_submit_ack_reports_pending_on_persistent_swallow() {
  # A genuinely swallowed Enter (text stays in the box across all retries) is
  # reported as "pending" — the daemon keeps the buffer, fm-send exits non-zero —
  # and the digest is typed ONCE (Enter-only retries, never a retype).
  local dir fakebin sent verdict
  dir=$(make_bordered_case ack-swallow)
  fakebin="$dir/fakebin"; sent="$dir/sent.log"; : > "$sent"
  touch "$dir/.swallow"
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    fm_tmux_submit_core "win" "the digest" 3 0.05 0.05)
  [ "$verdict" = pending ] || fail "persistent swallow not reported as pending: $verdict"
  [ "$(grep -cv '\[ENTER\]' "$sent")" -eq 1 ] || fail "digest retyped on swallow (expected type-once)"
  pass "submit-ACK reports pending on a persistently swallowed Enter (type-once)"
}

test_max_defer_empty_swallow_types_once_and_alarms() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-stuck)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '│ > │\n' > "$dir/composer"
  touch "$dir/.swallow"
  escalate_add "$state" "needs-decision: pick A"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_INJECT_CONFIRM_SLEEP=0.05 \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 housekeeping "$state"
  [ "$(grep -c 'Supervisor escalate' "$sent" 2>/dev/null || true)" -eq 1 ] \
    || fail "max-defer typed the digest more than once"
  [ -s "$state/.subsuper-inject-wedged" ] \
    || fail "stuck max-defer inject did not raise a wedge alarm marker"
  [ -s "$state/.subsuper-escalations" ] \
    || fail "buffer lost after a failed max-defer inject (must be preserved)"
  pass "max-defer on an empty stuck pane types once, alarms, and preserves the buffer"
}

test_max_defer_flushes_empty_idle_pane() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-recover)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '│ > │\n' > "$dir/composer"
  escalate_add "$state" "done: PR https://x/y/pull/1"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after a recovered max-defer flush"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge alarm left behind after a successful max-defer flush"
  pass "max-defer flushes and clears the buffer on an empty bordered pane"
}

test_max_defer_escape_probe_recovers_false_pending() {
  # Reproduce the incident shape: an idle pane's renderer leaves a normal-text
  # artifact on the cursor row, so the shared guard reports pending forever.
  # The first normal flush defers; the max-defer escape probe dismisses only the
  # artifact, re-reads empty, and delivers in this same housekeeping cycle.
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-escape-recover)
  state="$dir/state"; fakebin="$dir/fakebin"; sent="$dir/sent.log"; : > "$sent"
  printf '│ > stale renderer artifact │\n' > "$dir/composer"
  escalate_add "$state" "advisor-idle?: rt-advisor"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_ESCAPE_CLEARS=1 FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 \
    FM_INJECT_CONFIRM_SLEEP=0.05 FM_INJECT_ESCAPE_SETTLE=0.01 housekeeping "$state"
  [ "$(grep -c '\[ESCAPE\]' "$sent" 2>/dev/null || true)" -eq 1 ] \
    || fail "max-defer did not make exactly one Escape recovery probe"
  [ "$(grep -c 'Supervisor escalate' "$sent" 2>/dev/null || true)" -eq 1 ] \
    || fail "max-defer did not deliver exactly one recovered digest"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "recovered false pending left escalation buffered"
  [ ! -e "$state/.subsuper-inject-wedged" ] \
    || fail "recovered false pending raised a wedge alarm"
  pass "max-defer Escape probe recovers a false pending composer within one cycle"
}

test_max_defer_pending_composer_alarms_without_typing() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-pending-digest)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '│ > human draft │\n' > "$dir/composer"
  escalate_add "$state" "needs-decision: pick B"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ "$(grep -c 'Supervisor escalate' "$sent" 2>/dev/null || true)" -eq 0 ] \
    || fail "max-defer typed into a pending composer"
  [ -s "$state/.subsuper-inject-wedged" ] || fail "pending composer did not raise a wedge alarm marker"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer lost while composer was pending"
  grep -F 'human draft' "$dir/composer" >/dev/null || fail "pending composer content changed"
  [ "$(grep -c '\[ESCAPE\]' "$sent" 2>/dev/null || true)" -eq 1 ] \
    || fail "max-defer did not make its bounded Escape probe"
  [ "$(grep -c 'Supervisor escalate' "$sent" 2>/dev/null || true)" -eq 0 ] \
    || fail "max-defer typed into a genuine pending composer after Escape"
  grep -F 'human draft' "$dir/composer" >/dev/null || fail "Escape clobbered genuine pending composer content"
  pass "max-defer preserves genuine pending composer text after Escape probe"
}

test_wedge_alarm_enqueues_durable_next_turn_wake() {
  local dir state fakebin drained
  dir=$(make_bordered_case wedge-next-turn-wake)
  state="$dir/state"; fakebin="$dir/fakebin"; drained="$dir/drained"
  printf 'needs-decision: retained escalation\n' > "$state/.subsuper-escalations"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_STATE_OVERRIDE="$state" \
    inject_wedge_alarm "$state" 600
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drained" || fail "could not drain wedge alarm wake"
  grep -F $'\tsignal\tsubsuper-inject-wedged\t' "$drained" >/dev/null \
    || fail "wedge alarm did not enqueue a durable next-turn signal: $(cat "$drained")"
  grep -F 'away-mode inject wedged 600s' "$drained" >/dev/null \
    || fail "wedge wake omitted its actionable reason"
  pass "wedge alarm enqueues a durable signal for Firstmate's next turn"
}

test_normal_flush_clears_stale_wedge_marker() {
  local dir state fakebin sent
  dir=$(make_bordered_case normal-clears-wedge)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf 'old wedge\n' > "$state/.subsuper-inject-wedged"
  escalate_add "$state" "done: PR https://x/y/pull/2"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_INJECT_CONFIRM_SLEEP=0.05 escalate_flush "$state" \
    || fail "normal escalate_flush failed"
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after normal flush"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge marker survived successful normal flush"
  pass "normal flush clears a stale wedge marker"
}

test_below_max_defer_does_nothing() {
  local dir state fakebin sent capture
  dir=$(make_supercase below-maxdefer)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; printf 'stuck junk line\n' > "$capture"
  escalate_add "$state" "needs-decision: pick A"
  date +%s > "$state/.subsuper-escalations.since"   # just now
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=300 housekeeping "$state"
  [ ! -s "$sent" ] || fail "injected before MAX_DEFER elapsed"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge alarm fired before MAX_DEFER"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer dropped below MAX_DEFER"
  pass "below MAX_DEFER: no inject, no alarm, buffer preserved"
}

test_max_defer_afk_inactive_does_not_flush_or_alarm() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-inactive)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  escalate_add "$state" "needs-decision: pick B"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ ! -s "$sent" ] || fail "injected while afk was inactive"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge alarm fired while afk was inactive"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer dropped while afk was inactive"
  pass "max-defer does not flush or alarm while afk is inactive"
}

test_fm_send_exits_nonzero_on_confirmed_swallow() {
  # fm-send.sh must exit NON-ZERO when a steer's Enter is positively swallowed
  # (text left in the composer), so firstmate learns the instruction did not land
  # — and exit ZERO on a clean submit.
  local dir fakebin err
  dir=$(make_bordered_case send-swallow)
  fakebin="$dir/fakebin"; err="$dir/send.err"
  # Clean submit -> exit 0.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_SEND_SLEEP=0.05 "$ROOT/bin/fm-send.sh" sess:win 'route this work' >/dev/null 2>"$err" \
    || fail "fm-send exited non-zero on a clean submit: $(cat "$err")"
  # Persistent swallow -> exit non-zero with a clear message.
  printf '│ > │\n' > "$dir/composer"
  touch "$dir/.swallow"
  if PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_SEND_SLEEP=0.05 \
    "$ROOT/bin/fm-send.sh" sess:win 'fix findings 1 and 3, skip 2' >/dev/null 2>"$err"; then
    fail "fm-send exited zero despite a swallowed Enter (silent unsubmitted instruction)"
  fi
  grep -F 'not submitted' "$err" >/dev/null || fail "fm-send did not explain the swallowed submit: $(cat "$err")"
  pass "fm-send exits non-zero on a confirmed swallow, zero on a clean submit"
}

test_fm_send_unconfirmed_pending_without_sent_text_fails() {
  local dir fakebin err
  dir=$(make_bordered_case send-ambiguous-pending)
  fakebin="$dir/fakebin"; err="$dir/send.err"
  if PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_FAKE_AFTER_ENTER_TEXT='windows bridge redraw' FM_SEND_SLEEP=0.05 \
    "$ROOT/bin/fm-send.sh" sess:win 'route this work' >/dev/null 2>"$err"; then
    fail "fm-send treated an unconfirmed composer as delivered"
  fi
  grep -F 'not submitted' "$err" >/dev/null \
    || fail "fm-send did not explain the unconfirmed submit: $(cat "$err")"
  pass "fm-send fails when the composer remains pending, even with different text"
}

test_fm_send_exits_nonzero_on_initial_send_failure() {
  local dir fakebin err
  dir=$(make_bordered_case send-type-failure)
  fakebin="$dir/fakebin"; err="$dir/send.err"
  if PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_FAKE_SEND_FAIL=1 FM_SEND_SLEEP=0.05 \
    "$ROOT/bin/fm-send.sh" sess:win 'route this work' >/dev/null 2>"$err"; then
    fail "fm-send exited zero despite initial tmux send-keys failure"
  fi
  grep -F 'text not sent' "$err" >/dev/null || fail "fm-send did not explain initial send failure: $(cat "$err")"
  pass "fm-send exits non-zero when initial text send fails"
}

# ============================================================================
# Stall-check integration (housekeeping job 4): the away-mode daemon must run
# bin/fm-stall-check.sh's full sweep so its secondmate-child-escalation and
# advisor-idle detectors also fire during afk, not just at present-mode
# heartbeats (the 2026-08-02 incident: three crewmates sat on needs-decision
# for ~2 hours across two secondmate homes with both advisors idle, and the
# daemon escalated none of it).
# ============================================================================

test_stallcheck_scan_escalates_unrelayed_secondmate_child() {
  # THE exact miss: a child parked on needs-decision: inside a SECONDMATE
  # home's own state dir, which the main state/*.status catch-all (job 3)
  # cannot see at all - it never reads inside a secondmate's home.
  local dir state fakebin sent capture home
  dir=$(make_supercase stallcheck-unrelayed)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"
  home="$dir/advisor-home"
  mkdir -p "$home/state"
  : > "$capture"

  cat > "$state/rt-advisor.meta" <<EOF
window=fm-rt-advisor
kind=secondmate
home=$home
EOF
  cat > "$home/state/rt-issue48.meta" <<'EOF'
window=fm-rt-issue48
kind=ship
EOF
  printf 'needs-decision: pick a rollout option\n' > "$home/state/rt-issue48.status"
  touch -d '2000-01-01 00:00:00' "$home/state/rt-issue48.status" 2>/dev/null \
    || touch -t 200001010000 "$home/state/rt-issue48.status"

  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 FM_STALL_CHECK_SCAN_SECS=0 \
    housekeeping "$state"

  grep -F 'unrelayed?: rt-advisor/rt-issue48' "$sent" >/dev/null \
    || fail "away-mode daemon did not escalate an unrelayed secondmate-child needs-decision: $(cat "$sent" 2>/dev/null)"
  pass "housekeeping escalates a needs-decision child inside a secondmate home while afk"
}

test_stallcheck_scan_escalates_idle_working_advisor() {
  # The other half of the incident: a secondmate advisor whose last status is
  # working: (not terminal) has no status-change wake to trigger on, so only
  # a time-based sweep like fm-stall-check.sh's advisor-idle check can catch it.
  local dir state fakebin sent capture home
  dir=$(make_supercase stallcheck-advisor-idle)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"
  home="$dir/advisor-home"
  mkdir -p "$home/state"
  : > "$capture"

  cat > "$state/rt-advisor.meta" <<EOF
window=fm-rt-advisor
kind=secondmate
home=$home
EOF
  printf 'working: still on task\n' > "$state/rt-advisor.status"
  touch -d '2000-01-01 00:00:00' "$state/rt-advisor.status" 2>/dev/null \
    || touch -t 200001010000 "$state/rt-advisor.status"

  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 FM_STALL_CHECK_SCAN_SECS=0 \
    housekeeping "$state"

  grep -F 'advisor-idle?: rt-advisor' "$sent" >/dev/null \
    || fail "away-mode daemon did not escalate an idle advisor whose last status is working:: $(cat "$sent" 2>/dev/null)"
  pass "housekeeping escalates an idle advisor (working: status) while afk"
}

test_stallcheck_scan_dedupes_repeated_finding() {
  # fm-stall-check.sh has no ack mechanism and re-fires a persisting finding
  # every sweep. One alarm, not a stream: the SAME finding must not escalate
  # again on a second tick, even though the underlying condition (and the
  # script's output) is unchanged and the scan is forced to re-run.
  local dir state fakebin sent capture home
  dir=$(make_supercase stallcheck-dedup)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"
  home="$dir/advisor-home"
  mkdir -p "$home/state"
  : > "$capture"

  cat > "$state/rt-advisor.meta" <<EOF
window=fm-rt-advisor
kind=secondmate
home=$home
EOF
  printf 'working: still on task\n' > "$state/rt-advisor.status"
  touch -d '2000-01-01 00:00:00' "$state/rt-advisor.status" 2>/dev/null \
    || touch -t 200001010000 "$state/rt-advisor.status"

  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 FM_STALL_CHECK_SCAN_SECS=0 \
    housekeeping "$state"
  grep -F 'advisor-idle?: rt-advisor' "$sent" >/dev/null \
    || fail "first tick did not escalate the idle advisor: $(cat "$sent" 2>/dev/null)"

  : > "$sent"
  # Force the scan to re-run (FM_STALL_CHECK_SCAN_SECS=0 bypasses the cadence
  # gate) so the underlying condition genuinely re-fires from fm-stall-check.sh
  # a second time; only the daemon's own dedup marker can prevent a repeat.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 FM_STALL_CHECK_SCAN_SECS=0 \
    housekeeping "$state"
  [ ! -s "$sent" ] \
    || fail "the same stall-check finding was re-escalated on a second tick: $(cat "$sent")"
  pass "stall-check scan escalates a persisting finding once, not on every tick"
}

test_stallcheck_scan_afk_inactive_does_not_inject() {
  # afk changes how aggressively the daemon surfaces things, not what it can
  # see. With afk inactive, detection must still run (so nothing is lost) but
  # nothing may be typed into the pane - the same contract every other
  # escalation source in this daemon already holds.
  local dir state fakebin sent capture home
  dir=$(make_supercase stallcheck-afk-off)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"
  home="$dir/advisor-home"
  mkdir -p "$home/state"
  : > "$capture"

  cat > "$state/rt-advisor.meta" <<EOF
window=fm-rt-advisor
kind=secondmate
home=$home
EOF
  printf 'working: still on task\n' > "$state/rt-advisor.status"
  touch -d '2000-01-01 00:00:00' "$state/rt-advisor.status" 2>/dev/null \
    || touch -t 200001010000 "$state/rt-advisor.status"

  # afk deliberately NOT entered.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 FM_STALL_CHECK_SCAN_SECS=0 \
    housekeeping "$state"

  [ ! -s "$sent" ] || fail "daemon injected a stall-check finding while afk was inactive: $(cat "$sent")"
  grep -F 'advisor-idle?: rt-advisor' "$state/.subsuper-escalations" >/dev/null 2>&1 \
    || fail "finding was not buffered while afk was inactive (would be lost instead of caught up later)"
  pass "stall-check scan buffers without injecting while afk is inactive"
}

test_stallcheck_scan_respects_cadence_gate() {
  # Cost control: the full sweep shells out to tmux per pane, so it must not
  # run on every 15s housekeeping tick. Confirm the cadence gate actually
  # blocks a due-but-not-yet-elapsed scan, and fires once it has elapsed.
  local dir state fakebin sent capture home
  dir=$(make_supercase stallcheck-cadence)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"
  home="$dir/advisor-home"
  mkdir -p "$home/state"
  : > "$capture"

  cat > "$state/rt-advisor.meta" <<EOF
window=fm-rt-advisor
kind=secondmate
home=$home
EOF
  printf 'working: still on task\n' > "$state/rt-advisor.status"
  touch -d '2000-01-01 00:00:00' "$state/rt-advisor.status" 2>/dev/null \
    || touch -t 200001010000 "$state/rt-advisor.status"
  afk_enter "$state"

  date +%s > "$state/.subsuper-last-stallcheck"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 FM_STALL_CHECK_SCAN_SECS=300 \
    housekeeping "$state"
  [ ! -s "$sent" ] || fail "stall-check scan ran before its cadence elapsed: $(cat "$sent")"

  # The cadence gate is mtime-based (_file_age), like the existing
  # .subsuper-last-scan marker - writing a backdated epoch as CONTENT does not
  # backdate the file, since the write itself sets mtime to now. Backdate the
  # mtime directly instead.
  touch -d '2000-01-01 00:00:00' "$state/.subsuper-last-stallcheck" 2>/dev/null \
    || touch -t 200001010000 "$state/.subsuper-last-stallcheck"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 FM_STALL_CHECK_SCAN_SECS=300 \
    housekeeping "$state"
  grep -F 'advisor-idle?: rt-advisor' "$sent" >/dev/null \
    || fail "stall-check scan did not run once its cadence elapsed: $(cat "$sent" 2>/dev/null)"
  pass "stall-check scan is gated by FM_STALL_CHECK_SCAN_SECS, not every housekeeping tick"
}

test_stallcheck_scan_failed_sweep_is_logged_not_silent() {
  # A sweep that cannot run at all prints nothing, which is byte-identical to
  # "all clear". Reading it as all-clear would restore the very blindness this
  # job exists to close AND wipe every dedup marker, so the whole set
  # re-escalates the moment the sweep recovers.
  local dir state fakebin sent capture logf marker miss key
  dir=$(make_supercase stallcheck-sweep-fails)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  logf="$dir/daemon.log"; : > "$logf"

  # FM_DAEMON_DIR resolves only the sweep binary once the daemon is sourced, so
  # pointing it at the fake bin substitutes a broken fm-stall-check.sh.
  cat > "$fakebin/fm-stall-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'fm-stall-check.sh: no server running on /tmp/tmux-1000/default\n' >&2
exit 3
SH
  chmod +x "$fakebin/fm-stall-check.sh"

  # Derive the marker names from the identity function rather than hardcoding
  # them, so these tests stay pinned to real key formatting.
  key=$(_stall_finding_key 'advisor-idle?: rt-advisor - idle 1900s')
  marker="$state/.subsuper-seen-stallcheck-$key"
  miss="$state/.subsuper-stallcheck-miss-$key"
  date +%s > "$marker"

  afk_enter "$state"
  LOG="$logf" FM_DAEMON_DIR="$fakebin" PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 \
    FM_FAKE_TMUX_SENT="$sent" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_ESCALATE_BATCH_SECS=0 FM_STALL_CHECK_SCAN_SECS=0 housekeeping "$state"
  unset LOG

  [ -e "$marker" ] \
    || fail "a failed stall-check sweep cleared its dedup markers, so every finding re-escalates once the sweep recovers"
  [ ! -s "$sent" ] \
    || fail "a failed stall-check sweep escalated something: $(cat "$sent")"
  grep -F 'ERROR: stall-check sweep failed (rc=3)' "$logf" >/dev/null \
    || fail "a failed stall-check sweep left no diagnostic in the daemon log: $(cat "$logf")"
  grep -F 'no server running' "$logf" >/dev/null \
    || fail "the failed sweep's stderr was discarded instead of logged: $(cat "$logf")"
  [ ! -e "$miss" ] \
    || fail "a failed stall-check sweep counted as an absence; a sweep that could not run is not evidence of resolution"
  pass "a failing stall-check sweep logs an ERROR and preserves its dedup markers"
}

test_stallcheck_scan_realarms_unresolved_finding() {
  # An escalation may be deduplicated, but never permanently suppressed by
  # anything other than the condition going away. Firstmate's answer to the
  # first alarm can fail to land (fm-send.sh refuses a dead pane), so a finding
  # the sweep keeps emitting must alarm again once FM_STALL_REALARM_SECS has
  # passed - not on the very next tick, and not never. The window is driven
  # from a low env value here and probed on BOTH sides of it, so the assertion
  # cannot pass merely because the ticks share a wall-clock second.
  local dir state fakebin sent capture marker window
  dir=$(make_supercase stallcheck-realarm)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  window=60

  cat > "$fakebin/fm-stall-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'advisor-idle?: rt-advisor - idle 1900s with no active child work; route its next program step\n'
exit 0
SH
  chmod +x "$fakebin/fm-stall-check.sh"
  marker="$state/.subsuper-seen-stallcheck-$(_stall_finding_key 'advisor-idle?: rt-advisor - idle 1900s')"

  tick() {
    FM_DAEMON_DIR="$fakebin" PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 \
      FM_FAKE_TMUX_SENT="$sent" FM_FAKE_TMUX_CAPTURE="$capture" \
      FM_ESCALATE_BATCH_SECS=0 FM_STALL_CHECK_SCAN_SECS=0 \
      FM_STALL_REALARM_SECS="${1:-$window}" housekeeping "$state"
  }

  afk_enter "$state"
  tick
  grep -F 'advisor-idle?: rt-advisor' "$sent" >/dev/null \
    || fail "first tick did not escalate the idle advisor: $(cat "$sent" 2>/dev/null)"

  : > "$sent"
  tick
  [ ! -s "$sent" ] \
    || fail "an unresolved finding re-alarmed on the very next tick instead of once per window: $(cat "$sent")"

  # The window is measured from the marker's CONTENT epoch (like the
  # .subsuper-stale-* markers), so backdate the content, not the mtime. Just
  # inside the window must stay quiet; just outside it must alarm.
  printf '%s\n' "$(( $(date +%s) - (window / 2) ))" > "$marker"
  tick
  [ ! -s "$sent" ] \
    || fail "a finding re-alarmed while still inside FM_STALL_REALARM_SECS: $(cat "$sent")"

  printf '%s\n' "$(( $(date +%s) - window - 10 ))" > "$marker"
  tick
  grep -F 'advisor-idle?: rt-advisor' "$sent" >/dev/null \
    || fail "a still-unresolved finding never re-alarmed after FM_STALL_REALARM_SECS; the lane is silently stalled again: $(cat "$sent" 2>/dev/null)"

  # <=0 follows the FM_ESCALATE_BATCH_SECS "immediate" idiom, never a disable:
  # a disable path would be exactly the permanent suppression the principle
  # forbids, so it must alarm even on a marker just stamped by the tick above.
  : > "$sent"
  tick 0
  grep -F 'advisor-idle?: rt-advisor' "$sent" >/dev/null \
    || fail "FM_STALL_REALARM_SECS=0 suppressed an unresolved finding instead of alarming every sweep: $(cat "$sent" 2>/dev/null)"
  unset -f tick
  pass "an unresolved stall-check finding re-alarms once per FM_STALL_REALARM_SECS window"
}

test_stallcheck_scan_single_absent_sweep_is_not_resolution() {
  # fm-stall-check.sh drops a finding for one sweep on ordinary flap (a
  # momentarily busy child pane short-circuits check_advisor_idle_stalls, a
  # bounded fm-peek.sh probe fails). One absence must therefore neither resolve
  # the finding nor make its return read as a fresh occurrence; only a
  # corroborated absence (STALL_CHECK_MISSES_TO_CLEAR = 2) clears the marker.
  local dir state fakebin sent capture marker miss out key
  dir=$(make_supercase stallcheck-flap)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  out="$dir/sweep-out.txt"

  cat > "$fakebin/fm-stall-check.sh" <<SH
#!/usr/bin/env bash
cat "$out" 2>/dev/null
exit 0
SH
  chmod +x "$fakebin/fm-stall-check.sh"
  key=$(_stall_finding_key 'advisor-idle?: rt-advisor - idle 1900s')
  marker="$state/.subsuper-seen-stallcheck-$key"
  miss="$state/.subsuper-stallcheck-miss-$key"

  # A wide re-alarm window keeps this test about the miss counter alone: the
  # flap absorption it asserts is only observable while the re-alarm window has
  # not elapsed, and a window at or below the sweep cadence would pre-empt it.
  tick() {
    FM_DAEMON_DIR="$fakebin" PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 \
      FM_FAKE_TMUX_SENT="$sent" FM_FAKE_TMUX_CAPTURE="$capture" \
      FM_ESCALATE_BATCH_SECS=0 FM_STALL_CHECK_SCAN_SECS=0 FM_STALL_REALARM_SECS=3600 \
      housekeeping "$state"
  }

  afk_enter "$state"
  printf 'advisor-idle?: rt-advisor - idle 1900s with no active child work\n' > "$out"
  tick
  grep -F 'advisor-idle?: rt-advisor' "$sent" >/dev/null \
    || fail "first tick did not escalate the idle advisor: $(cat "$sent" 2>/dev/null)"

  : > "$sent"; : > "$out"
  tick
  [ -e "$marker" ] \
    || fail "one absent sweep cleared the dedup marker; a single flap is not a resolution"
  [ "$(cat "$miss" 2>/dev/null)" = "1" ] \
    || fail "one absent sweep did not record a single consecutive miss: $(cat "$miss" 2>/dev/null)"

  printf 'advisor-idle?: rt-advisor - idle 2200s with no active child work\n' > "$out"
  tick
  [ ! -s "$sent" ] \
    || fail "a finding returning after one missed sweep re-escalated as a fresh occurrence: $(cat "$sent")"
  [ -e "$marker" ] || fail "the returning finding lost its dedup marker"
  [ ! -e "$miss" ] || fail "the returning finding did not reset its consecutive-miss counter"

  : > "$out"
  tick
  [ -e "$marker" ] || fail "the marker was cleared after only one absence again"
  tick
  [ ! -e "$marker" ] \
    || fail "two consecutive absent sweeps did not clear the marker, so a genuine recurrence would stay suppressed"
  [ ! -e "$miss" ] || fail "clearing the marker left its miss counter behind"
  unset -f tick
  pass "one absent sweep is a flap, two consecutive absences resolve the finding"
}

test_daemon_state_root_uses_fm_home
test_concurrent_append_and_drain
test_delayed_receipt_publication_does_not_lose_lock_ownership
test_signal_catchup_without_running_watcher
test_stale_enqueue_before_suppressor
test_check_output_is_queued
test_singleton_start
test_atomic_double_drain
test_drain_reports_lock_release_failure
test_drain_dedupes_obvious_duplicates
test_stale_watch_lock_reclaimed
test_live_stale_watch_lock_is_actionable
test_keepalive_rearms_stale_missing_watcher
test_keepalive_stops_when_fleet_empty
test_guard_warns_on_pending_queue
test_guard_rearms_after_draining_pending_queue
# Sub-supervisor (fm-supervise-daemon.sh) classifier + batching + housekeeping.
test_classify_routine_signal_self
test_classify_terminal_signal_escalates
test_classify_check_and_unknown_escalate
test_stale_transient_self_records_marker
test_stale_terminal_escalates
test_housekeeping_persistent_stale_escalates
test_housekeeping_resumed_stale_cleared
test_escalate_batches_into_one_digest
test_escalate_batch_age_uses_first_append
test_heartbeat_scan_dedup
test_handle_wake_routes_self_and_escalate
test_inject_skip_forces_self
test_is_wake_reason_distinguishes_status_stdout
test_terminal_stale_escalate_leaves_no_marker
test_dead_agent_stale_wake_parses_window_and_escalates
test_signal_escalate_marks_seen_no_catchall_refire
test_timestamped_status_uses_raw_dedupe_and_clean_presentation
# /afk presence-gating + injection hardening.
test_inject_refuses_a_gone_target
test_collapse_newlines_pure
test_afk_absent_daemon_does_not_inject
test_afk_present_injects_with_marker
test_inject_digest_is_single_line
test_busy_guard_defers_when_supervisor_busy
test_marker_detection
test_afk_turn_exemption
test_should_exit_afk_when_afk_inactive
# Injection hardening: composer guard, type-once submit, strip marker, dedupe.
test_strip_injection_marker
test_pane_input_pending_detects_partial_input
test_pane_input_pending_blank_is_not_pending
test_pane_input_pending_idle_prompt_not_pending
test_pane_input_pending_honors_idle_override_after_border_strip
test_composer_guard_defers_on_partial_input
test_inject_types_once_retries_enter_only
test_inject_no_duplicate_on_success
test_classify_signal_dedup_against_scan
test_classify_stale_dedup_against_signal
# afk-invx-i5 regressions: bordered-composer detection, submit-ACK, max-defer.
test_pane_input_pending_bordered_idle_not_pending
test_pane_input_pending_bordered_with_text_is_pending
test_submit_ack_confirms_on_bordered_empty_composer
test_submit_ack_reports_pending_on_persistent_swallow
test_max_defer_empty_swallow_types_once_and_alarms
test_max_defer_flushes_empty_idle_pane
test_max_defer_escape_probe_recovers_false_pending
test_max_defer_pending_composer_alarms_without_typing
test_wedge_alarm_enqueues_durable_next_turn_wake
test_normal_flush_clears_stale_wedge_marker
test_below_max_defer_does_nothing
test_max_defer_afk_inactive_does_not_flush_or_alarm
test_fm_send_exits_nonzero_on_confirmed_swallow
test_fm_send_unconfirmed_pending_without_sent_text_fails
test_fm_send_exits_nonzero_on_initial_send_failure
# Stall-check integration (housekeeping job 4).
test_stallcheck_scan_escalates_unrelayed_secondmate_child
test_stallcheck_scan_escalates_idle_working_advisor
test_stallcheck_scan_dedupes_repeated_finding
test_stallcheck_scan_afk_inactive_does_not_inject
test_stallcheck_scan_respects_cadence_gate
test_stallcheck_scan_failed_sweep_is_logged_not_silent
test_stallcheck_scan_realarms_unresolved_finding
test_stallcheck_scan_single_absent_sweep_is_not_resolution
