#!/usr/bin/env bash
# Focused contract tests for the advisory ownership policy and ordinary
# ship/scout brief templates. There is deliberately no spawn-time admission or
# brief-schema enforcement in this test surface.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIEF="$ROOT/bin/fm-brief.sh"
AGENTS="$ROOT/AGENTS.md"
README="$ROOT/README.md"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-brief-contract.XXXXXX") || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

assert_line() {
  local file=$1 line=$2 message=$3
  grep -Fx "$line" "$file" >/dev/null || fail "$message"
}

assert_before() {
  local file=$1 first=$2 second=$3 message=$4 first_line second_line
  first_line=$(grep -nF "$first" "$file" | head -n 1 | cut -d: -f1)
  second_line=$(grep -nF "$second" "$file" | head -n 1 | cut -d: -f1)
  [ -n "$first_line" ] && [ -n "$second_line" ] && [ "$first_line" -lt "$second_line" ] \
    || fail "$message"
}

test_ship_and_scout_templates_name_evidence_contract() {
  local home id brief
  home="$TMP_ROOT/home"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' '- demo [local-only] - fixture (added 2026-07-23)' > "$home/data/projects.md"

  FM_HOME="$home" "$BRIEF" ship-contract demo >/dev/null
  FM_HOME="$home" "$BRIEF" scout-contract demo --scout >/dev/null

  for id in ship-contract scout-contract; do
    brief="$home/data/$id/brief.md"
    assert_line "$brief" '# Objective' "$id scaffold omitted Objective"
    assert_line "$brief" '{OBJECTIVE}' "$id scaffold omitted objective placeholder"
    assert_line "$brief" '# Observable success evidence' "$id scaffold omitted success evidence"
    assert_line "$brief" '{SUCCESS_EVIDENCE}' "$id scaffold omitted success-evidence placeholder"
    assert_line "$brief" '# Review / deadline trigger' "$id scaffold omitted review/deadline trigger"
    assert_line "$brief" '{REVIEW_OR_DEADLINE_TRIGGER}' "$id scaffold omitted review/deadline placeholder"
    grep -F 'A `working` line is only a status report, never proof of progress or completion.' "$brief" >/dev/null \
      || fail "$id scaffold omitted working-status honesty"
    grep -F 'Report `done` only when the observable success evidence above exists.' "$brief" >/dev/null \
      || fail "$id scaffold omitted done-evidence requirement"
  done

  pass "ship and scout templates name objective, evidence, trigger, and status honesty"
}

test_documentation_keeps_advisory_ownership_boundary() {
  grep -F 'Every incoming work request becomes a durable Queued record before any clarification question, dispatch, or routing message.' "$AGENTS" >/dev/null \
    || fail "AGENTS.md omitted record-first durable ownership"
  assert_before "$AGENTS" \
    'Every incoming work request becomes a durable Queued record before any clarification question, dispatch, or routing message.' \
    '5. More than one plausible match, or none: ask a one-line question after the provisional Queued record exists.' \
    "AGENTS.md asks for clarification before durable intake"
  grep -F 'Three is the default working limit, not a spawn-time lock' "$AGENTS" >/dev/null \
    || fail "AGENTS.md omitted advisory three-report boundary"
  grep -F 'the captain may explicitly override it for a particular dispatch' "$AGENTS" >/dev/null \
    || fail "AGENTS.md omitted explicit captain override"
  grep -F 'It is a mechanical exception alarm, not another manager and not an interpreter of task semantics.' "$AGENTS" >/dev/null \
    || fail "AGENTS.md omitted thin watcher boundary"
  grep -F 'Treat `done` as a completion claim.' "$AGENTS" >/dev/null \
    || fail "AGENTS.md omitted done reconciliation"
  grep -F '`fm-spawn.sh` does not enforce a hard cap.' "$README" >/dev/null \
    || fail "README omitted advisory-only spawn behavior"
  assert_line "$AGENTS" \
    'Re-evaluate the queue and apply the Queued dispatch checks above before dispatching each eligible item.' \
    "ship teardown bypasses queued dispatch checks"
  grep -F 'then re-evaluate the queue and apply the Queued dispatch checks above before dispatching each eligible item.' "$AGENTS" >/dev/null \
    || fail "scout completion bypasses queued dispatch checks"
  grep -F 'treat queued items whose blockers or date gates have cleared as candidates and apply the Queued dispatch checks before dispatch' "$AGENTS" >/dev/null \
    || fail "stall handling bypasses queued dispatch checks"
  assert_line "$AGENTS" \
    'Re-evaluate Queued on every teardown and every heartbeat, then apply the Queued dispatch checks before dispatching each eligible item.' \
    "heartbeat sweep bypasses queued dispatch checks"

  pass "documentation pins record-first ownership and an advisory three-report boundary"
}

test_ship_and_scout_templates_name_evidence_contract
test_documentation_keeps_advisory_ownership_boundary
