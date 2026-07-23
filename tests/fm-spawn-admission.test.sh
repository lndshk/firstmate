#!/usr/bin/env bash
# Focused behavior tests for ordinary direct-report admission and generated
# brief validation. All tmux operations are faked; refusal paths assert that no
# window, worktree command, metadata, or agent launch side effect occurs.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-admission.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

make_fake_tmux() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "${1:-}" in
  has-session|new-session|new-window|send-keys)
    exit 0
    ;;
  list-windows)
    all=false
    for arg in "$@"; do
      [ "$arg" = -a ] && all=true
    done
    if "$all"; then
      cat "$FM_FAKE_TMUX_ACTIVE"
    else
      sed 's/^[^:]*://' "$FM_FAKE_TMUX_ACTIVE"
    fi
    exit 0
    ;;
  display-message)
    printf '%s\n' "$FM_FAKE_WORKTREE"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/data" "$dir/state" "$dir/projects/demo" "$dir/pool/.treehouse/task-wt"
  git -C "$dir/pool/.treehouse/task-wt" init -q
  printf 'fixture\n' > "$dir/pool/.treehouse/task-wt/README.md"
  git -C "$dir/pool/.treehouse/task-wt" add README.md
  git -C "$dir/pool/.treehouse/task-wt" \
    -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial
  printf '%s\n' '- demo [local-only] - fixture (added 2026-07-23)' > "$dir/data/projects.md"
  : > "$dir/active-windows"
  : > "$dir/tmux.log"
  fakebin=$(make_fake_tmux "$dir")
  printf '%s\n' "$dir|$fakebin"
}

write_filled_brief() {
  local dir=$1 id=$2
  mkdir -p "$dir/data/$id"
  cat > "$dir/data/$id/brief.md" <<'EOF'
# Objective
Exercise admission behavior.

# Observable success evidence
The spawn result and metadata are observable.

# Review / deadline trigger
Review when the command exits.
EOF
}

write_meta() {
  local dir=$1 id=$2 kind=${3:-ship} target=${4:-firstmate:fm-$2}
  cat > "$dir/state/$id.meta" <<EOF
window=$target
worktree=/tmp/example
project=$dir/projects/demo
harness=codex
kind=$kind
mode=local-only
yolo=off
EOF
}

run_spawn() {
  local dir=$1 fakebin=$2 id=$3
  shift 3
  PATH="$fakebin:$PATH" \
    FM_HOME="$dir" \
    FM_PROJECTS_OVERRIDE="$dir/projects" \
    FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" \
    FM_FAKE_TMUX_ACTIVE="$dir/active-windows" \
    FM_FAKE_WORKTREE="$dir/pool/.treehouse/task-wt" \
    "$SPAWN" "$id" projects/demo codex "$@" 2>&1
}

assert_no_launch_side_effects() {
  local dir=$1 id=$2
  if grep -Eq '^(new-session|new-window|send-keys)' "$dir/tmux.log"; then
    fail "refusal for $id created a tmux/worktree/launch side effect"
  fi
  [ ! -e "$dir/state/$id.meta" ] || fail "refusal for $id wrote metadata"
}

test_default_boundary_counts_meta_and_recoverable_window() {
  local fixture dir fakebin id out status
  fixture=$(make_case default-boundary)
  dir=${fixture%%|*}
  fakebin=${fixture#*|}
  id=new-default
  write_filled_brief "$dir" "$id"
  for active in one two three; do
    write_filled_brief "$dir" "$active"
  done
  write_meta "$dir" one
  write_meta "$dir" two
  cat > "$dir/active-windows" <<'EOF'
firstmate:fm-one
firstmate:fm-two
firstmate:fm-three
EOF

  out=$(run_spawn "$dir" "$fakebin" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "default limit admitted a fourth ordinary report"
  printf '%s\n' "$out" | grep -F '3 active (limit 3)' >/dev/null \
    || fail "default-limit refusal omitted the boundary: $out"
  for active in one two three; do
    printf '%s\n' "$out" | grep -F "$active (firstmate:fm-$active)" >/dev/null \
      || fail "default-limit refusal omitted active report $active: $out"
  done
  printf '%s\n' "$out" | grep -F 'task new-default remains or should remain queued' >/dev/null \
    || fail "default-limit refusal omitted queued ownership: $out"
  assert_no_launch_side_effects "$dir" "$id"
  pass "default boundary counts live meta plus a recoverable live window and refuses without side effects"
}

test_explicit_override_changes_boundary() {
  local fixture dir fakebin id out status
  fixture=$(make_case override-boundary)
  dir=${fixture%%|*}
  fakebin=${fixture#*|}
  id=new-override
  write_filled_brief "$dir" "$id"
  write_filled_brief "$dir" existing
  write_meta "$dir" existing
  printf '%s\n' 'firstmate:fm-existing' > "$dir/active-windows"

  out=$(FM_DIRECT_REPORT_LIMIT=1 run_spawn "$dir" "$fakebin" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "explicit limit admitted work at capacity"
  printf '%s\n' "$out" | grep -F '1 active (limit 1)' >/dev/null \
    || fail "explicit-limit refusal omitted override value: $out"
  assert_no_launch_side_effects "$dir" "$id"
  pass "FM_DIRECT_REPORT_LIMIT overrides the default admission boundary"
}

test_secondmates_do_not_consume_capacity() {
  local fixture dir fakebin id out
  fixture=$(make_case secondmates-excluded)
  dir=${fixture%%|*}
  fakebin=${fixture#*|}
  id=new-after-secondmates
  write_filled_brief "$dir" "$id"
  for active in ordinary-one ordinary-two second-meta second-reg; do
    write_filled_brief "$dir" "$active"
  done
  write_meta "$dir" ordinary-one
  write_meta "$dir" ordinary-two
  write_meta "$dir" second-meta secondmate
  printf '%s\n' "- second-reg - fixture (home: /tmp/second-reg; scope: fixture; projects: demo; added 2026-07-23)" \
    > "$dir/data/secondmates.md"
  cat > "$dir/active-windows" <<'EOF'
firstmate:fm-ordinary-one
firstmate:fm-ordinary-two
firstmate:fm-second-meta
firstmate:fm-second-reg
EOF

  out=$(run_spawn "$dir" "$fakebin" "$id") || fail "secondmates consumed ordinary capacity: $out"
  [ -f "$dir/state/$id.meta" ] || fail "admitted task did not write metadata"
  grep -F 'new-window' "$dir/tmux.log" >/dev/null || fail "admitted task did not create its window"
  pass "persistent secondmates are excluded from ordinary direct-report capacity"
}

test_dead_meta_does_not_hold_capacity() {
  local fixture dir fakebin id out
  fixture=$(make_case stale-meta)
  dir=${fixture%%|*}
  fakebin=${fixture#*|}
  id=new-after-stale
  write_filled_brief "$dir" "$id"
  for stale in stale-one stale-two stale-three stale-four; do
    write_meta "$dir" "$stale"
  done

  out=$(run_spawn "$dir" "$fakebin" "$id") || fail "dead metadata falsely held capacity: $out"
  [ -f "$dir/state/$id.meta" ] || fail "spawn after stale metadata did not complete"
  pass "dead meta records do not become a permanent false capacity claim"
}

test_unfilled_generated_brief_is_rejected() {
  local fixture dir fakebin id out status
  fixture=$(make_case unfilled-brief)
  dir=${fixture%%|*}
  fakebin=${fixture#*|}
  id=unfilled
  FM_HOME="$dir" "$BRIEF" "$id" demo >/dev/null

  out=$(run_spawn "$dir" "$fakebin" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an unfilled generated brief"
  printf '%s\n' "$out" | grep -F 'contains an unfilled generated contract placeholder' >/dev/null \
    || fail "unfilled-brief refusal was not actionable: $out"
  assert_no_launch_side_effects "$dir" "$id"
  pass "spawn rejects an unfilled generated contract before side effects"
}

test_scaffolds_name_the_required_contract() {
  local fixture dir fakebin
  fixture=$(make_case scaffold-contract)
  dir=${fixture%%|*}
  fakebin=${fixture#*|}
  : "$fakebin"
  FM_HOME="$dir" "$BRIEF" ship-contract demo >/dev/null
  FM_HOME="$dir" "$BRIEF" scout-contract demo --scout >/dev/null

  for id in ship-contract scout-contract; do
    brief="$dir/data/$id/brief.md"
    grep -Fx '# Objective' "$brief" >/dev/null || fail "$id scaffold omitted Objective"
    grep -Fx '# Observable success evidence' "$brief" >/dev/null || fail "$id scaffold omitted success evidence"
    grep -Fx '# Review / deadline trigger' "$brief" >/dev/null || fail "$id scaffold omitted review/deadline trigger"
    grep -F 'A `working` line is only a status report' "$brief" >/dev/null \
      || fail "$id scaffold omitted status honesty"
  done
  pass "ship and scout scaffolds name objective, evidence, trigger, and status honesty"
}

test_default_boundary_counts_meta_and_recoverable_window
test_explicit_override_changes_boundary
test_secondmates_do_not_consume_capacity
test_dead_meta_does_not_hold_capacity
test_unfilled_generated_brief_is_rejected
test_scaffolds_name_the_required_contract
