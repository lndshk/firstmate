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
  if [ -n "${TMP_ROOT:-}" ]; then
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
  : > "$home/.fm-secondmate-home"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh"
}

test_bootstrap_starts_custom_main_home_supervisor() {
  local case_dir fakebin out pid
  case_dir="$TMP_ROOT/custom-main-home"
  mkdir -p "$case_dir/home" "$case_dir/board"
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_BOARD_DIR="$case_dir/board" "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "bootstrap reported problems for custom main home: $out"
  for _ in 1 2 3 4 5; do [ -s "$case_dir/home/state/.artifact-supervisor.pid" ] && break; sleep 1; done
  [ -s "$case_dir/home/state/.artifact-supervisor.pid" ] || fail "bootstrap did not start custom main-home supervisor"
  pid=$(cat "$case_dir/home/state/.artifact-supervisor.pid")
  kill "$pid" 2>/dev/null || true
  pass "bootstrap starts supervisor for custom main home"
}

test_bootstrap_skips_supervisor_without_tmux() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/no-tmux"
  mkdir -p "$case_dir/home" "$case_dir/board"
  fakebin=$(make_fake_toolchain "$case_dir")
  cat > "$case_dir/no-tmux-env" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = tmux ]; then
    return 1
  fi
  builtin command "$@"
}
SH

  out=$(BASH_ENV="$case_dir/no-tmux-env" FM_FAKE_TREEHOUSE_LEASE_HELP=1 PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_BOARD_DIR="$case_dir/board" "$ROOT/bin/fm-bootstrap.sh")
  printf '%s\n' "$out" | grep -F 'MISSING: tmux' >/dev/null || fail "bootstrap did not report missing tmux"
  [ ! -e "$case_dir/home/state/.artifact-supervisor.pid" ] || fail "bootstrap started supervisor without tmux"
  pass "bootstrap skips supervisor without tmux"
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
test_bootstrap_starts_custom_main_home_supervisor
test_bootstrap_skips_supervisor_without_tmux
