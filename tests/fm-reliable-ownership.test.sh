#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIEF="$ROOT/bin/fm-brief.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-reliable-ownership.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

make_home() {
  local dir=$1
  mkdir -p "$dir/data" "$dir/state" "$dir/projects/demo"
  printf '%s\n' '- demo [local-only] - fixture (added 2026-07-23)' > "$dir/data/projects.md"
}

make_fake_tmux() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "${1:-}" in
  has-session)
    exit 0
    ;;
  list-windows)
    all=false
    for arg in "$@"; do
      [ "$arg" = -a ] && all=true
    done
    if [ -f "$FM_FAKE_TMUX_WINDOWS" ]; then
      if "$all"; then
        sed '/:/!s/^/firstmate:/' "$FM_FAKE_TMUX_WINDOWS"
      else
        sed 's/^[^:]*://' "$FM_FAKE_TMUX_WINDOWS"
      fi
    fi
    exit 0
    ;;
  new-window)
    exit 23
    ;;
  *)
    exit 0
    ;;
esac
SH
  chmod +x "$dir/tmux"
}

write_brief() {
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  printf '%s\n' 'Custom task brief may discuss the reserved token {OBJECTIVE} literally.' \
    > "$home/data/$id/brief.md"
}

write_meta() {
  local home=$1 id=$2 kind=$3 window=$4
  printf 'window=%s\nkind=%s\n' "$window" "$kind" > "$home/state/$id.meta"
}

run_spawn() {
  local home=$1 fakebin=$2 log=$3 windows=$4
  shift 4
  PATH="$fakebin:$PATH" \
    FM_HOME="$home" \
    FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TMUX_WINDOWS="$windows" \
    "$SPAWN" "$@"
}

assert_refused_without_spawn_side_effects() {
  local home=$1 log=$2 id=$3
  ! grep -F 'new-window' "$log" >/dev/null \
    || fail "$id refusal created a tmux window"
  [ ! -e "$home/state/$id.meta" ] \
    || fail "$id refusal wrote task metadata"
  [ ! -e "$home/state/.spawn-admission.lock" ] \
    || fail "$id refusal left an admission lock"
}

test_scaffolds_name_the_required_contract() {
  local dir id brief
  dir="$TMP_ROOT/scaffolds"
  make_home "$dir"
  FM_HOME="$dir" "$BRIEF" ship-contract demo >/dev/null
  FM_HOME="$dir" "$BRIEF" scout-contract demo --scout >/dev/null

  for id in ship-contract scout-contract; do
    brief="$dir/data/$id/brief.md"
    grep -Fx '<!-- firstmate-generated-ordinary-brief -->' "$brief" >/dev/null \
      || fail "$id scaffold omitted generated-brief provenance"
    grep -Fx '# Objective' "$brief" >/dev/null || fail "$id scaffold omitted Objective"
    grep -Fx '# Observable success evidence' "$brief" >/dev/null || fail "$id scaffold omitted success evidence"
    grep -Fx '# Review / deadline trigger' "$brief" >/dev/null || fail "$id scaffold omitted review/deadline trigger"
    grep -F 'A `working` line is only a status report' "$brief" >/dev/null \
      || fail "$id scaffold omitted working-is-not-proof guidance"
  done
  pass "ship and scout briefs carry the evidence contract"
}

test_secondmate_charter_keeps_existing_routing_model() {
  local dir charter
  dir="$TMP_ROOT/secondmate"
  make_home "$dir"
  FM_HOME="$dir" \
    FM_SECONDMATE_CHARTER='Own fixture work.' \
    FM_SECONDMATE_SCOPE='Fixture work.' \
    "$BRIEF" fixture-advisor --secondmate demo >/dev/null
  charter="$dir/data/fixture-advisor/brief.md"

  grep -F 'Act only on tasks the main firstmate routes to you.' "$charter" >/dev/null \
    || fail "secondmate charter omitted routed-work scope"
  if grep -Eq 'working: accepted|ownership missing|Queued -> spawn' "$charter"; then
    fail "secondmate charter retained acknowledgement transaction machinery"
  fi
  pass "secondmate charter keeps the existing routing model"
}

test_default_boundary_counts_meta_and_recoverable_window() {
  local home fakebin log windows err
  home="$TMP_ROOT/default-boundary"
  fakebin="$TMP_ROOT/default-boundary-bin"
  log="$TMP_ROOT/default-boundary-tmux.log"
  windows="$TMP_ROOT/default-boundary-windows"
  err="$TMP_ROOT/default-boundary.err"
  make_home "$home"
  make_fake_tmux "$fakebin"
  : > "$log"
  write_brief "$home" live-a
  write_brief "$home" live-b
  write_brief "$home" recoverable
  write_brief "$home" refused
  write_meta "$home" live-a ship firstmate:fm-live-a
  write_meta "$home" live-b scout firstmate:fm-live-b
  printf '%s\n' fm-live-a fm-live-b recovery:fm-recoverable > "$windows"

  if run_spawn "$home" "$fakebin" "$log" "$windows" refused projects/demo codex \
    >/dev/null 2>"$err"; then
    fail "default boundary admitted a fourth ordinary report"
  fi
  grep -F '3 active (limit 3)' "$err" >/dev/null \
    || fail "default boundary refusal did not report the occupied limit"
  grep -F 'live-a (firstmate:fm-live-a)' "$err" >/dev/null \
    || fail "default boundary refusal omitted a metadata-backed report"
  grep -F 'recoverable (recovery:fm-recoverable)' "$err" >/dev/null \
    || fail "default boundary refusal omitted the cross-session recoverable report"
  grep -F 'task refused remains or should remain queued' "$err" >/dev/null \
    || fail "default boundary refusal omitted durable queued ownership"
  assert_refused_without_spawn_side_effects "$home" "$log" refused
  pass "default boundary counts live metadata and recoverable windows"
}

test_explicit_override_changes_boundary() {
  local home fakebin log windows err
  home="$TMP_ROOT/override-boundary"
  fakebin="$TMP_ROOT/override-boundary-bin"
  log="$TMP_ROOT/override-boundary-tmux.log"
  windows="$TMP_ROOT/override-boundary-windows"
  err="$TMP_ROOT/override-boundary.err"
  make_home "$home"
  make_fake_tmux "$fakebin"
  : > "$log"
  write_brief "$home" live-a
  write_brief "$home" live-b
  write_brief "$home" live-c
  write_brief "$home" admitted
  write_meta "$home" live-a ship firstmate:fm-live-a
  write_meta "$home" live-b ship firstmate:fm-live-b
  write_meta "$home" live-c scout firstmate:fm-live-c
  printf '%s\n' fm-live-a fm-live-b fm-live-c > "$windows"

  if FM_DIRECT_REPORT_LIMIT=4 \
    run_spawn "$home" "$fakebin" "$log" "$windows" admitted projects/demo codex \
      >/dev/null 2>"$err"; then
    fail "override fixture unexpectedly completed the fake spawn"
  fi
  grep -F 'new-window' "$log" >/dev/null \
    || fail "FM_DIRECT_REPORT_LIMIT=4 did not admit the fourth ordinary report"
  if grep -F 'direct-report admission refused' "$err" >/dev/null; then
    fail "explicit override retained the default boundary"
  fi
  [ ! -e "$home/state/.spawn-admission.lock" ] \
    || fail "override spawn failure left an admission lock"
  pass "explicit override changes the direct-report boundary"
}

test_secondmates_do_not_consume_capacity() {
  local home fakebin log windows err
  home="$TMP_ROOT/secondmate-capacity"
  fakebin="$TMP_ROOT/secondmate-capacity-bin"
  log="$TMP_ROOT/secondmate-capacity-tmux.log"
  windows="$TMP_ROOT/secondmate-capacity-windows"
  err="$TMP_ROOT/secondmate-capacity.err"
  make_home "$home"
  make_fake_tmux "$fakebin"
  : > "$log"
  write_brief "$home" advisor-a
  write_brief "$home" advisor-b
  write_brief "$home" advisor-c
  write_brief "$home" admitted
  write_meta "$home" advisor-a secondmate firstmate:fm-advisor-a
  write_meta "$home" advisor-b secondmate firstmate:fm-advisor-b
  write_meta "$home" advisor-c secondmate firstmate:fm-advisor-c
  printf '%s\n' fm-advisor-a fm-advisor-b fm-advisor-c > "$windows"

  if run_spawn "$home" "$fakebin" "$log" "$windows" admitted projects/demo codex \
    >/dev/null 2>"$err"; then
    fail "secondmate exclusion fixture unexpectedly completed the fake spawn"
  fi
  grep -F 'new-window' "$log" >/dev/null \
    || fail "live secondmates consumed ordinary direct-report capacity"
  if grep -F 'direct-report admission refused' "$err" >/dev/null; then
    fail "secondmates triggered ordinary admission refusal"
  fi
  pass "persistent secondmates do not consume ordinary capacity"
}

test_dead_meta_does_not_hold_capacity() {
  local home fakebin log windows err
  home="$TMP_ROOT/dead-meta"
  fakebin="$TMP_ROOT/dead-meta-bin"
  log="$TMP_ROOT/dead-meta-tmux.log"
  windows="$TMP_ROOT/dead-meta-windows"
  err="$TMP_ROOT/dead-meta.err"
  make_home "$home"
  make_fake_tmux "$fakebin"
  : > "$log"
  : > "$windows"
  write_brief "$home" dead-a
  write_brief "$home" dead-b
  write_brief "$home" dead-c
  write_brief "$home" admitted
  write_meta "$home" dead-a ship firstmate:fm-dead-a
  write_meta "$home" dead-b scout firstmate:fm-dead-b
  write_meta "$home" dead-c ship firstmate:fm-dead-c

  if run_spawn "$home" "$fakebin" "$log" "$windows" admitted projects/demo codex \
    >/dev/null 2>"$err"; then
    fail "dead-meta fixture unexpectedly completed the fake spawn"
  fi
  grep -F 'new-window' "$log" >/dev/null \
    || fail "dead metadata held ordinary direct-report capacity"
  if grep -F 'direct-report admission refused' "$err" >/dev/null; then
    fail "dead metadata triggered admission refusal"
  fi
  pass "dead metadata does not hold capacity"
}

test_unrelated_windows_do_not_consume_capacity() {
  local home fakebin log windows err
  home="$TMP_ROOT/unrelated-window"
  fakebin="$TMP_ROOT/unrelated-window-bin"
  log="$TMP_ROOT/unrelated-window-tmux.log"
  windows="$TMP_ROOT/unrelated-window-windows"
  err="$TMP_ROOT/unrelated-window.err"
  make_home "$home"
  make_fake_tmux "$fakebin"
  : > "$log"
  write_brief "$home" live-a
  write_brief "$home" live-b
  write_brief "$home" admitted
  write_meta "$home" live-a ship firstmate:fm-live-a
  write_meta "$home" live-b scout firstmate:fm-live-b
  printf '%s\n' fm-live-a fm-live-b foreign:fm-unrelated-home > "$windows"

  if run_spawn "$home" "$fakebin" "$log" "$windows" admitted projects/demo codex \
    >/dev/null 2>"$err"; then
    fail "unrelated-window fixture unexpectedly completed the fake spawn"
  fi
  grep -F 'new-window' "$log" >/dev/null \
    || fail "an unrelated home window consumed this home's capacity"
  if grep -F 'direct-report admission refused' "$err" >/dev/null; then
    fail "unrelated fm-* window was treated as this home's recoverable work"
  fi
  pass "unrelated firstmate windows do not consume this home's capacity"
}

test_unfilled_generated_brief_is_rejected() {
  local home fakebin log windows err
  home="$TMP_ROOT/unfilled-brief"
  fakebin="$TMP_ROOT/unfilled-brief-bin"
  log="$TMP_ROOT/unfilled-brief-tmux.log"
  windows="$TMP_ROOT/unfilled-brief-windows"
  err="$TMP_ROOT/unfilled-brief.err"
  make_home "$home"
  make_fake_tmux "$fakebin"
  : > "$log"
  : > "$windows"
  FM_HOME="$home" "$BRIEF" unfilled demo >/dev/null

  if run_spawn "$home" "$fakebin" "$log" "$windows" unfilled projects/demo codex \
    >/dev/null 2>"$err"; then
    fail "spawn accepted an unfilled generated brief"
  fi
  grep -F 'contains an unfilled generated contract placeholder' "$err" >/dev/null \
    || fail "unfilled generated brief refusal was not explained"
  assert_refused_without_spawn_side_effects "$home" "$log" unfilled
  pass "unfilled generated briefs are rejected before spawn side effects"
}

test_custom_briefs_remain_schema_free() {
  local home fakebin log windows err
  home="$TMP_ROOT/custom-brief"
  fakebin="$TMP_ROOT/custom-brief-bin"
  log="$TMP_ROOT/custom-brief-tmux.log"
  windows="$TMP_ROOT/custom-brief-windows"
  err="$TMP_ROOT/custom-brief.err"
  make_home "$home"
  make_fake_tmux "$fakebin"
  : > "$log"
  : > "$windows"
  write_brief "$home" custom

  if run_spawn "$home" "$fakebin" "$log" "$windows" custom projects/demo codex \
    >/dev/null 2>"$err"; then
    fail "custom-brief fixture unexpectedly completed the fake spawn"
  fi
  grep -F 'new-window' "$log" >/dev/null \
    || fail "schema-free custom brief was rejected before launch"
  if grep -F 'contains an unfilled generated contract placeholder' "$err" >/dev/null; then
    fail "custom brief was subjected to generated-brief schema validation"
  fi
  pass "custom briefs remain schema-free"
}

test_documented_lifecycle_is_bounded_and_durable() {
  grep -F 'admits at most three live direct ship/scout crewmates by default' "$ROOT/AGENTS.md" >/dev/null \
    || fail "direct-report boundary is not documented"
  grep -F 'set `FM_DIRECT_REPORT_LIMIT` to an explicit non-negative integer' "$ROOT/AGENTS.md" >/dev/null \
    || fail "direct-report override is not documented"
  grep -F 'The sequence is always Queued -> dispatch -> In flight' "$ROOT/AGENTS.md" >/dev/null \
    || fail "lifecycle omitted durable record-first ordering"
  grep -F 'Firstmate owns every accepted request through a verified terminal outcome' "$ROOT/AGENTS.md" >/dev/null \
    || fail "lifecycle omitted interruption and restart ownership"
  grep -F 'live metadata and pane evidence together show that the agent started and is processing the brief' "$ROOT/AGENTS.md" >/dev/null \
    || fail "recovery accepts metadata without launch evidence"
  grep -F 'leave the request Queued and reconcile the partial window before retrying' "$ROOT/AGENTS.md" >/dev/null \
    || fail "recovery omits partial-window reconciliation"
  grep -F 'mechanical exception alarm' "$ROOT/AGENTS.md" >/dev/null \
    || fail "watcher guidance stopped being a thin exception alarm"
  grep -F 'reconcile that claim against the brief'\''s named success evidence' "$ROOT/AGENTS.md" >/dev/null \
    || fail "done reconciliation omitted named evidence"
  pass "documentation preserves bounded capacity and durable ownership"
}

test_scaffolds_name_the_required_contract
test_secondmate_charter_keeps_existing_routing_model
test_default_boundary_counts_meta_and_recoverable_window
test_explicit_override_changes_boundary
test_secondmates_do_not_consume_capacity
test_dead_meta_does_not_hold_capacity
test_unrelated_windows_do_not_consume_capacity
test_unfilled_generated_brief_is_rejected
test_custom_briefs_remain_schema_free
test_documented_lifecycle_is_bounded_and_durable
