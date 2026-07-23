#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIEF="$ROOT/bin/fm-brief.sh"
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

test_scaffolds_name_the_required_contract() {
  local dir id brief
  dir="$TMP_ROOT/scaffolds"
  make_home "$dir"
  FM_HOME="$dir" "$BRIEF" ship-contract demo >/dev/null
  FM_HOME="$dir" "$BRIEF" scout-contract demo --scout >/dev/null

  for id in ship-contract scout-contract; do
    brief="$dir/data/$id/brief.md"
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

test_documented_lifecycle_is_advisory_and_durable() {
  grep -F 'Three is an advisory default for direct ship/scout crewmates, not a hard spawn gate' "$ROOT/AGENTS.md" >/dev/null \
    || fail "direct-report guidance is not advisory"
  grep -F 'The sequence is always Queued -> dispatch -> In flight' "$ROOT/AGENTS.md" >/dev/null \
    || fail "lifecycle omitted durable record-first ordering"
  grep -F 'Firstmate owns every accepted request through a verified terminal outcome' "$ROOT/AGENTS.md" >/dev/null \
    || fail "lifecycle omitted interruption and restart ownership"
  grep -F 'live metadata and pane evidence together show that the launch command was submitted or the agent started' "$ROOT/AGENTS.md" >/dev/null \
    || fail "recovery accepts metadata without launch evidence"
  grep -F 'mechanical exception alarm' "$ROOT/AGENTS.md" >/dev/null \
    || fail "watcher guidance stopped being a thin exception alarm"
  grep -F 'reconcile that claim against the brief'\''s named success evidence' "$ROOT/AGENTS.md" >/dev/null \
    || fail "done reconciliation omitted named evidence"
  if grep -Eq 'FM_DIRECT_REPORT_LIMIT|spawn-admission|brief_has_unfilled_contract|@fm_home' \
      "$ROOT/AGENTS.md" "$ROOT/README.md" "$ROOT/bin/fm-spawn.sh"; then
    fail "removed enforcement or brief-schema machinery remains"
  fi
  pass "documentation preserves advisory capacity and durable ownership"
}

test_scaffolds_name_the_required_contract
test_secondmate_charter_keeps_existing_routing_model
test_documented_lifecycle_is_advisory_and_durable
