#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARVEST="$ROOT/bin/fm-error-harvest.py"
TMP_ROOT=
PY=${PY:-python3}

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

command -v "$PY" >/dev/null 2>&1 || fail "no python3 on PATH"
[ -x "$HARVEST" ] || fail "fm-error-harvest.py missing or not executable"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-error-harvest-tests.XXXXXX")

# Transcript lines are compact JSON in real sessions, and the scanner gates on
# compact substrings before parsing - so fixtures must be compact too.
skill_miss() {
  local id=$1
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"%s","name":"Skill","input":{"skill":"axi"}}]},"timestamp":"2026-08-20T10:00:00Z"}\n' "$id"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"%s","is_error":true,"content":"<tool_use_error>Unknown skill: axi. Did you mean app?</tool_use_error>"}]},"timestamp":"2026-08-20T10:00:01Z"}\n' "$id"
}

run() { "$PY" "$HARVEST" --root "$1" "${@:2}"; }

# --- a scan that finds nothing to read must FAIL, not report health ------------
run "$TMP_ROOT/does-not-exist" >/dev/null 2>&1
[ $? -eq 2 ] || fail "missing root should exit 2"
pass "missing transcript root exits 2 rather than reporting clean"

mkdir -p "$TMP_ROOT/empty"
run "$TMP_ROOT/empty" >/dev/null 2>&1
[ $? -eq 2 ] || fail "empty root should exit 2"
pass "no transcripts in window exits 2 rather than reporting clean"

# --- recurrence threshold ------------------------------------------------------
mkdir -p "$TMP_ROOT/live/projA" "$TMP_ROOT/live/projB"
skill_miss t1 > "$TMP_ROOT/live/projA/sess1.jsonl"

out=$(run "$TMP_ROOT/live" --min-sessions 2 2>&1); rc=$?
[ $rc -eq 0 ] || fail "one session should not meet a 2-session threshold (rc=$rc)"
printf '%s' "$out" | grep -q 'Unknown skill' && fail "single-session error must not be reported"
pass "a one-off failure stays below the recurrence threshold"

# same failure, second session, different project
skill_miss t2 > "$TMP_ROOT/live/projB/sess2.jsonl"

out=$(run "$TMP_ROOT/live" --min-sessions 2 2>&1); rc=$?
[ $rc -eq 1 ] || fail "recurring failure should exit 1 (rc=$rc)"
printf '%s' "$out" | grep -q 'Unknown skill: axi' || fail "recurring failure not reported"
printf '%s' "$out" | grep -q '\[cli\]' || fail "CLI-stamped error not marked"
pass "the same failure across two sessions is reported and exits 1"

printf '%s' "$out" | grep -qE '^ +2 +2\*' || fail "cross-project marker (*) not set"
pass "a failure spanning two projects is flagged as structural"

# --- aborts are not denials ----------------------------------------------------
mkdir -p "$TMP_ROOT/aborts/projC"
{
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a1","name":"Bash","input":{"command":"git log --oneline"}}]},"timestamp":"2026-08-20T11:00:00Z"}\n'
  printf '{"type":"user","toolDenialKind":"interrupted","message":{"content":[{"type":"tool_result","tool_use_id":"a1"}]},"timestamp":"2026-08-20T11:00:01Z"}\n'
} > "$TMP_ROOT/aborts/projC/s1.jsonl"
cp "$TMP_ROOT/aborts/projC/s1.jsonl" "$TMP_ROOT/aborts/projC/s2.jsonl"

out=$(run "$TMP_ROOT/aborts" --min-sessions 2 2>&1); rc=$?
[ $rc -eq 0 ] || fail "interrupted aborts must not count as denials (rc=$rc)"
pass "interrupted/cancelled aborts are excluded from denials"

# --- hook timeouts count, user cancellations do not ----------------------------
mkdir -p "$TMP_ROOT/hooks/projD"
printf '{"type":"attachment","attachment":{"type":"hook_cancelled","hookName":"slowhook","hookEvent":"PreToolUse","durationMs":5000}}\n' \
  > "$TMP_ROOT/hooks/projD/s1.jsonl"
cp "$TMP_ROOT/hooks/projD/s1.jsonl" "$TMP_ROOT/hooks/projD/s2.jsonl"
out=$(run "$TMP_ROOT/hooks" --min-sessions 2 2>&1); rc=$?
[ $rc -eq 0 ] || fail "user-cancelled hooks must not be reported (rc=$rc)"
pass "a hook cancelled by the user is not counted as a hook failure"

printf '{"type":"attachment","attachment":{"type":"hook_cancelled","hookName":"slowhook","hookEvent":"PreToolUse","timedOut":true,"timeoutMs":5000,"durationMs":5000}}\n' \
  > "$TMP_ROOT/hooks/projD/s1.jsonl"
cp "$TMP_ROOT/hooks/projD/s1.jsonl" "$TMP_ROOT/hooks/projD/s2.jsonl"
out=$(run "$TMP_ROOT/hooks" --min-sessions 2 2>&1); rc=$?
[ $rc -eq 1 ] || fail "timed-out hooks should be reported (rc=$rc)"
printf '%s' "$out" | grep -q 'slowhook' || fail "timed-out hook not named"
pass "a hook that ran to its timeout is reported"

# --- signatures group across differing paths and ids ---------------------------
mkdir -p "$TMP_ROOT/sig/projE"
{
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"s1","name":"Bash","input":{"command":"cat x"}}]},"timestamp":"2026-08-20T12:00:00Z"}\n'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"s1","is_error":true,"content":"cannot open /home/rob/one/alpha.txt after 1234 tries"}]},"timestamp":"2026-08-20T12:00:01Z"}\n'
} > "$TMP_ROOT/sig/projE/s1.jsonl"
{
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"s2","name":"Bash","input":{"command":"cat y"}}]},"timestamp":"2026-08-20T12:00:00Z"}\n'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"s2","is_error":true,"content":"cannot open /home/rob/two/beta.txt after 9876 tries"}]},"timestamp":"2026-08-20T12:00:01Z"}\n'
} > "$TMP_ROOT/sig/projE/s2.jsonl"
out=$(run "$TMP_ROOT/sig" --min-sessions 2 2>&1); rc=$?
[ $rc -eq 1 ] || fail "differing paths/numbers should still group (rc=$rc)"
printf '%s' "$out" | grep -q '<PATH>' || fail "path not normalised in signature"
pass "the same fault with different paths and counts groups into one signature"

# --- JSON mode -----------------------------------------------------------------
run "$TMP_ROOT/live" --min-sessions 2 --json > "$TMP_ROOT/out.json" 2>/dev/null
"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d['scanned']['files']==2, d['scanned']
assert d['groups'] and d['groups'][0]['sessions']==2, d['groups'][:1]
" "$TMP_ROOT/out.json" || fail "--json output malformed"
pass "--json emits parseable output with scan coverage"

printf '\nall fm-error-harvest tests passed\n'
