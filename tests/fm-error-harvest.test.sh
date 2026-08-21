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

mkdir -p "$TMP_ROOT/unreadable/proj/bad.jsonl"
run "$TMP_ROOT/unreadable" >/dev/null 2>&1
[ $? -eq 2 ] || fail "unreadable transcript candidates should exit 2"
pass "an unreadable transcript candidate fails the scan"

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
printf '%s' "$out" | grep -q '\[cli\]' && fail "untrusted transcript tag must not claim CLI provenance"
pass "the same failure across two sessions is reported without forged provenance"

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

mkdir -p "$TMP_ROOT/long/projF"
long_prefix=$(printf 'x%.0s' {1..140})
for n in 1 2; do
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"l%s","name":"Bash","input":{"command":"false"}}]},"timestamp":"2026-08-20T12:00:00Z"}\n' "$n" \
    > "$TMP_ROOT/long/projF/s${n}.jsonl"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"l%s","is_error":true,"content":"failure %s tail-%s"}]},"timestamp":"2026-08-20T12:00:01Z"}\n' \
    "$n" "$long_prefix" "$n" >> "$TMP_ROOT/long/projF/s${n}.jsonl"
done
run "$TMP_ROOT/long" --min-sessions 1 --json > "$TMP_ROOT/long.json" 2>/dev/null
[ $? -eq 1 ] || fail "long distinct errors should be reported"
"$PY" -c "
import json,sys
groups=json.load(open(sys.argv[1]))['groups']
assert len(groups)==2, groups
assert len({g['key'][1] for g in groups}) == 2, groups
assert all(len(g['key'][1]) == 64 for g in groups), groups
assert all(len(g['display']['signature']) <= 133 for g in groups), groups
" "$TMP_ROOT/long.json" || fail "long errors sharing a prefix were collapsed"
pass "long errors retain distinct fixed-size grouping identities"

mkdir -p "$TMP_ROOT/control/projG"
for n in 1 2; do
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"c%s","name":"Bash","input":{"command":"false"}}]},"timestamp":"2026-08-20T12:00:00Z"}\n' "$n" \
    > "$TMP_ROOT/control/projG/s${n}.jsonl"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c%s","is_error":true,"content":"bad \\u001b[31mcontrol\\u001b[0m text"}]},"timestamp":"2026-08-20T12:00:01Z"}\n' "$n" \
    >> "$TMP_ROOT/control/projG/s${n}.jsonl"
done
out=$(run "$TMP_ROOT/control" --min-sessions 2 2>&1); rc=$?
[ $rc -eq 1 ] || fail "recurring control-byte error should be reported (rc=$rc)"
case "$out" in *$'\033'*) fail "report emitted a terminal control byte";; esac
printf '%s' "$out" | grep -q 'control' || fail "sanitized error text not reported"
pass "report strips terminal control bytes from transcript content"

# --- JSON mode -----------------------------------------------------------------
run "$TMP_ROOT/live" --min-sessions 2 --json > "$TMP_ROOT/out.json" 2>/dev/null
"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d['scanned']['files']==2, d['scanned']
assert d['groups'] and d['groups'][0]['sessions']==2, d['groups'][:1]
assert 'sample' not in d['groups'][0], d['groups'][0]
" "$TMP_ROOT/out.json" || fail "--json output malformed"
pass "--json emits parseable output without raw transcript samples"

# --- sensitive tool output must never become a report key or display -----------
mkdir -p "$TMP_ROOT/secrets/projH"
for n in 1 2; do
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"p%s","name":"Bash","input":{"command":"false"}}]},"timestamp":"2026-08-20T12:00:00Z"}\n' "$n" \
    > "$TMP_ROOT/secrets/projH/s${n}.jsonl"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"p%s","is_error":true,"content":"request failed: Authorization: Bearer super-secret-%s"}]},"timestamp":"2026-08-20T12:00:01Z"}\n' \
    "$n" "$n" >> "$TMP_ROOT/secrets/projH/s${n}.jsonl"
done
run "$TMP_ROOT/secrets" --min-sessions 1 --json > "$TMP_ROOT/secrets.json" 2>/dev/null
[ $? -eq 1 ] || fail "sensitive failures should be reported"
"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert len(d['groups']) == 1, d['groups']
g=d['groups'][0]
assert len(g['key'][1]) == 64, g
assert 'super-secret' not in json.dumps(d), d
assert '<REDACTED>' in g['display']['signature'], g
" "$TMP_ROOT/secrets.json" || fail "sensitive tool output leaked into JSON"
pass "tool-result secrets are redacted from bounded displays and grouping keys"

# --- denied command labels are also transcript-derived and must be safe --------
mkdir -p "$TMP_ROOT/denial-secrets/projI"
for n in 1 2; do
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"d%s","name":"Bash","input":{"command":"curl https://api.example/?token=super-secret-%s"}}]},"timestamp":"2026-08-20T12:00:00Z"}\n' "$n" "$n" \
    > "$TMP_ROOT/denial-secrets/projI/s${n}.jsonl"
  printf '{"type":"user","toolDenialKind":"permission","message":{"content":[{"type":"tool_result","tool_use_id":"d%s"}]},"timestamp":"2026-08-20T12:00:01Z"}\n' "$n" \
    >> "$TMP_ROOT/denial-secrets/projI/s${n}.jsonl"
done
out=$(run "$TMP_ROOT/denial-secrets" --min-sessions 1 2>&1); rc=$?
[ $rc -eq 1 ] || fail "denied commands should be reported"
case "$out" in *super-secret*) fail "sensitive denied command leaked into text report";; esac
run "$TMP_ROOT/denial-secrets" --min-sessions 1 --json > "$TMP_ROOT/denial-secrets.json" 2>/dev/null
[ $? -eq 1 ] || fail "sensitive denials should be reported in JSON"
"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert len(d['groups']) == 1, d['groups']
g=d['groups'][0]
assert len(g['key']) == 1 and len(g['key'][0]) == 64, g
assert 'super-secret' not in json.dumps(d), d
assert len(g['display']['command']) <= 133, g
" "$TMP_ROOT/denial-secrets.json" || fail "sensitive denied command leaked into JSON"
pass "denied command labels use redacted displays and opaque identities"

# --- valid JSON still needs the transcript record shapes we access -------------
mkdir -p "$TMP_ROOT/malformed/projJ"
{
  printf '"is_error"\n'
  printf '{"type":"user","message":"is_error"}\n'
  printf '{"type":"attachment","attachment":"hook_error"}\n'
} > "$TMP_ROOT/malformed/projJ/s1.jsonl"
out=$(run "$TMP_ROOT/malformed" --min-sessions 1 2>&1); rc=$?
[ $rc -eq 0 ] || fail "schema-invalid transcript records must not crash the scan (rc=$rc)"
printf '%s' "$out" | grep -q 'unparseable: 3' || fail "schema-invalid records were not counted as unparseable"
pass "schema-invalid transcript records are skipped without crashing"

printf '\nall fm-error-harvest tests passed\n'
