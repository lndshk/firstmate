#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  local pid_file pid
  if [ -n "${TMP_ROOT:-}" ]; then
    for pid_file in "$TMP_ROOT"/*/home/state/.firstmate-supervisor.pid; do
      [ -f "$pid_file" ] || continue
      pid=$(cat "$pid_file" 2>/dev/null || true)
      case "$pid" in ''|*[!0-9]*) ;; *) kill "$pid" 2>/dev/null || true ;; esac
    done
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-bootstrap-tests.XXXXXX")

make_fake_toolchain() {
  local dir=$1 fakebin tool
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  for tool in tmux node no-mistakes gh-axi chrome-devtools-axi lavish-axi; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  if [ "${FM_FAKE_TREEHOUSE_LEASE_HELP:-}" = 1 ]; then
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  else
    printf '%s\n' 'Usage: treehouse get'
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

run_bootstrap() {
  local home=$1 fakebin=$2
  # Most bootstrap tests exercise capability reporting, not main-home process
  # startup. Mark those isolated fixtures as secondmate homes.
  : > "$home/.fm-secondmate-home"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh"
}

test_bootstrap_starts_main_home_supervisor() {
  local case_dir fakebin out pid
  case_dir="$TMP_ROOT/main-home"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$case_dir/home" FM_BOARD_DIR="$case_dir/board" \
    "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "main-home bootstrap reported problems: $out"
  for _ in 1 2 3 4 5; do
    pid=$(cat "$case_dir/home/state/.firstmate-supervisor.pid" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) sleep 1 ;; *) break ;; esac
  done
  case "${pid:-}" in ''|*[!0-9]*) fail "bootstrap did not start main-home supervisor" ;; esac
  kill -0 "$pid" 2>/dev/null || fail "bootstrap supervisor PID receipt is not live"
  [ -s "$case_dir/home/state/.firstmate-supervisor.heartbeat" ] \
    || fail "bootstrap supervisor did not publish heartbeat"
  pass "bootstrap starts the main-home supervisor"
}

test_bootstrap_reports_supervisor_startup_failure() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/supervisor-startup-failure"
  mkdir -p "$case_dir/home/state/.firstmate-supervisor.control.lock"
  printf '%s\n' "$$" > "$case_dir/home/state/.firstmate-supervisor.control.lock/pid"
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$case_dir/home" FM_BOARD_DIR="$case_dir/board" \
    "$ROOT/bin/fm-bootstrap.sh")
  printf '%s\n' "$out" | grep -F \
    "SUPERVISOR: startup failed: supervisor control operation already in progress (pid $$)" >/dev/null \
    || fail "bootstrap suppressed supervisor startup failure: $out"
  pass "bootstrap reports supervisor startup failure"
}

test_bootstrap_reports_failed_initial_cycle() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/supervisor-initial-cycle-failure"
  mkdir -p "$case_dir/home"
  : > "$case_dir/board"
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$case_dir/home" FM_BOARD_DIR="$case_dir/board" \
    FM_SUPERVISOR_START_WAIT=2 "$ROOT/bin/fm-bootstrap.sh")
  printf '%s\n' "$out" | grep -F \
    'SUPERVISOR: startup failed: error: supervisor failed to publish a fresh heartbeat after its initial cycle' >/dev/null \
    || fail "bootstrap suppressed failed initial cycle: $out"
  [ ! -e "$case_dir/home/state/.firstmate-supervisor.heartbeat" ] \
    || fail "failed bootstrap activation published a readiness heartbeat"
  pass "bootstrap reports failed supervisor initial cycle"
}

test_bootstrap_accepts_treehouse_lease_support() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/lease-supported"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 run_bootstrap "$case_dir/home" "$fakebin")
  [ -z "$out" ] || fail "bootstrap reported problems despite treehouse lease support: $out"
  pass "bootstrap accepts treehouse get --lease support"
}

test_bootstrap_reports_treehouse_without_lease_support() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/lease-missing"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=0 run_bootstrap "$case_dir/home" "$fakebin")
  printf '%s\n' "$out" | grep -Fx 'MISSING: treehouse (install: curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh)' >/dev/null \
    || fail "bootstrap did not report treehouse upgrade instruction"
  printf '%s\n' "$out" | grep -F 'NEEDS_GH_AUTH' >/dev/null && fail "bootstrap reported gh auth despite fake authenticated gh"
  pass "bootstrap reports treehouse without get --lease support"
}

test_bootstrap_reports_tasks_axi_when_available() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/tasks-axi-available"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_toolchain "$case_dir")
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.1'
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 run_bootstrap "$case_dir/home" "$fakebin")
  [ "$out" = 'TASKS_AXI: available' ] || fail "bootstrap did not report tasks-axi availability: $out"
  pass "bootstrap reports compatible optional tasks-axi availability"
}

test_bootstrap_ignores_incompatible_tasks_axi() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/tasks-axi-incompatible"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_toolchain "$case_dir")
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.0'
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 run_bootstrap "$case_dir/home" "$fakebin")
  [ -z "$out" ] || fail "bootstrap reported incompatible tasks-axi as available: $out"
  pass "bootstrap ignores incompatible optional tasks-axi"
}

test_bootstrap_accepts_treehouse_lease_support
test_bootstrap_reports_treehouse_without_lease_support
test_bootstrap_reports_tasks_axi_when_available
test_bootstrap_ignores_incompatible_tasks_axi
test_bootstrap_starts_main_home_supervisor
test_bootstrap_reports_supervisor_startup_failure
test_bootstrap_reports_failed_initial_cycle
