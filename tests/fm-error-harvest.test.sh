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

# --- scan-window inputs must be finite and positive ---------------------------
for days in nan inf -inf 0 -1; do
  out=$(run "$TMP_ROOT/empty" --days="$days" 2>&1); rc=$?
  [ $rc -eq 2 ] || fail "invalid --days $days must be rejected (rc=$rc)"
  printf '%s' "$out" | grep -Fq -- '--days must be a finite number > 0' || \
    fail "invalid --days $days error was unclear"
done
pass "non-finite and non-positive --days values are rejected before scanning"

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

case "$out" in
  *'<tool_use_error>'*) fail "default output retained disallowed transcript characters" ;;
esac
out=$(run "$TMP_ROOT/live" --min-sessions 2 --show-detail 2>&1); rc=$?
[ $rc -eq 1 ] || fail "detail mode should retain recurring findings (rc=$rc)"
printf '%s' "$out" | grep -Fq '<tool_use_error>' || fail "--show-detail did not expose full detail"
pass "detail mode is required for full transcript text"

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
printf '%s' "$out" | grep -q 'PATH' || fail "path not normalised in signature"
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
assert 'REDACTED' in g['display']['signature'], g
" "$TMP_ROOT/secrets.json" || fail "sensitive tool output leaked into JSON"
pass "tool-result secrets are redacted from bounded displays and grouping keys"

mkdir -p "$TMP_ROOT/cookie-secrets/projK"
for n in 1 2; do
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"k%s","name":"Bash","input":{"command":"false"}}]},"timestamp":"2026-08-20T12:00:00Z"}\n' "$n" \
    > "$TMP_ROOT/cookie-secrets/projK/s${n}.jsonl"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"k%s","is_error":true,"content":"request failed: Cookie: session=super-secret-%s"}]},"timestamp":"2026-08-20T12:00:01Z"}\n' \
    "$n" "$n" >> "$TMP_ROOT/cookie-secrets/projK/s${n}.jsonl"
done
run "$TMP_ROOT/cookie-secrets" --min-sessions 2 --json > "$TMP_ROOT/cookie-secrets.json" 2>/dev/null
[ $? -eq 1 ] || fail "cookie failures should be reported"
"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert len(d['groups']) == 1, d['groups']
g=d['groups'][0]
assert g['sessions'] == 2, g
assert 'super-secret' not in json.dumps(d), d
assert 'REDACTED' in g['display']['signature'], g
" "$TMP_ROOT/cookie-secrets.json" || fail "cookie secrets leaked or did not group"
pass "cookie session secrets are redacted and group across sessions"

mkdir -p "$TMP_ROOT/shared-name/projL" "$TMP_ROOT/shared-name/projM"
for project in projL projM; do
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"same-%s","name":"Bash","input":{"command":"false"}}]},"timestamp":"2026-08-20T12:00:00Z"}\n' "$project" \
    > "$TMP_ROOT/shared-name/$project/shared.jsonl"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"same-%s","is_error":true,"content":"shared transcript failure"}]},"timestamp":"2026-08-20T12:00:01Z"}\n' "$project" \
    >> "$TMP_ROOT/shared-name/$project/shared.jsonl"
done
run "$TMP_ROOT/shared-name" --min-sessions 2 --json > "$TMP_ROOT/shared-name.json" 2>/dev/null
[ $? -eq 1 ] || fail "same-basename sessions should meet threshold"
"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert len(d['groups']) == 1, d['groups']
assert d['groups'][0]['sessions'] == 2, d['groups']
" "$TMP_ROOT/shared-name.json" || fail "same-basename transcripts were not distinct sessions"
pass "same-basename transcripts in different projects count as two sessions"

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

mkdir -p "$TMP_ROOT/control-denial-secrets/projI"
for n in 1 2; do
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"cd%s","name":"Bash","input":{"command":"env token=super\\u001bsecret"}}]}}\n' "$n" \
    > "$TMP_ROOT/control-denial-secrets/projI/s${n}.jsonl"
  printf '{"type":"user","toolDenialKind":"permission token=super\\u001bsecret","message":{"content":[{"type":"tool_result","tool_use_id":"cd%s"}]}}\n' "$n" \
    >> "$TMP_ROOT/control-denial-secrets/projI/s${n}.jsonl"
done
out=$(run "$TMP_ROOT/control-denial-secrets" --min-sessions 2 2>&1); rc=$?
[ $rc -eq 1 ] || fail "control-split denials should be reported (rc=$rc)"
case "$out" in *super*|*secret*) fail "control-split secret leaked into text report";; esac
run "$TMP_ROOT/control-denial-secrets" --min-sessions 2 --json > "$TMP_ROOT/control-denial-secrets.json" 2>/dev/null
[ $? -eq 1 ] || fail "control-split denials should be reported in JSON"
"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert len(d['groups']) == 1, d['groups']
encoded=json.dumps(d)
assert 'super' not in encoded and 'secret' not in encoded, d
g=d['groups'][0]
assert 'REDACTED' in g['display']['command'], g
assert 'REDACTED' in g['display']['kind'], g
" "$TMP_ROOT/control-denial-secrets.json" || fail "control-split secret leaked into JSON"
pass "denial labels redact control-split assignments before normalization"

mkdir -p "$TMP_ROOT/read-coverage/projA" "$TMP_ROOT/read-coverage/projB"
skill_miss coverage > "$TMP_ROOT/read-coverage/projA/readable.jsonl"
printf 'unreadable candidate\n' > "$TMP_ROOT/read-coverage/projB/unreadable.jsonl"
chmod 000 "$TMP_ROOT/read-coverage/projB/unreadable.jsonl"
run "$TMP_ROOT/read-coverage" --min-sessions 1 --json > "$TMP_ROOT/read-coverage.json" 2>/dev/null
[ $? -eq 1 ] || fail "readable transcript should still be reported with an unreadable candidate"
"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d['scanned']['files'] == 1, d['scanned']
assert d['scanned']['projects'] == 1, d['scanned']
assert d['scanned']['read_errors'] == 1, d['scanned']
" "$TMP_ROOT/read-coverage.json" || fail "coverage counted an unreadable project as scanned"
pass "coverage counts only projects with successfully opened transcripts"

# --- hook labels are untrusted transcript metadata and must be safe ------------
mkdir -p "$TMP_ROOT/hook-secrets/projN"
for n in 1 2; do
  printf '{"type":"attachment","attachment":{"type":"hook_error","hookName":"deploy token=super-secret-%s","hookEvent":"PreToolUse"}}\n' "$n" \
    > "$TMP_ROOT/hook-secrets/projN/s${n}.jsonl"
done
out=$(run "$TMP_ROOT/hook-secrets" --min-sessions 2 2>&1); rc=$?
[ $rc -eq 1 ] || fail "recurring hook errors should be reported (rc=$rc)"
case "$out" in *super-secret*) fail "sensitive hook label leaked into text report";; esac
printf '%s' "$out" | grep -Fq 'deploy token REDACTED' || fail "redacted hook label not reported"
run "$TMP_ROOT/hook-secrets" --min-sessions 2 --json > "$TMP_ROOT/hook-secrets.json" 2>/dev/null
[ $? -eq 1 ] || fail "recurring hook errors should be reported in JSON"
"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert len(d['groups']) == 1, d['groups']
g=d['groups'][0]
assert g['sessions'] == 2, g
assert len(g['key']) == 1 and len(g['key'][0]) == 64, g
assert 'super-secret' not in json.dumps(d), d
assert g['display']['hook'] == 'deploy token REDACTED', g
" "$TMP_ROOT/hook-secrets.json" || fail "sensitive hook label leaked or did not group"
pass "hook labels are redacted and group across sessions"

# --- hook labels are optional config fields and must stay safe ----------------
mkdir -p "$TMP_ROOT/hook-untyped/projO"
for n in 1 2; do
  printf '{"type":"attachment","attachment":{"type":"hook_error","hookName":null,"hookEvent":%s}}\n' "$n" \
    > "$TMP_ROOT/hook-untyped/projO/s${n}.jsonl"
done
out=$(run "$TMP_ROOT/hook-untyped" --min-sessions 2 2>&1); rc=$?
[ $rc -eq 1 ] || fail "untyped hook labels must not crash the scan (rc=$rc)"
printf '%s\n' "$out" | grep -Eq '[[:space:]]+/ hook_error' || fail "untyped hook labels were not normalized"
run "$TMP_ROOT/hook-untyped" --min-sessions 2 --json > "$TMP_ROOT/hook-untyped.json" 2>/dev/null
[ $? -eq 1 ] || fail "untyped hook labels should be reported in JSON"
"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert len(d['groups']) == 1, d['groups']
g=d['groups'][0]
assert g['sessions'] == 2, g
assert g['display'] == {'hook': '?', 'event': '?', 'type': 'hook_error'}, g
" "$TMP_ROOT/hook-untyped.json" || fail "untyped hook labels were not reported safely"
pass "untyped hook labels are normalized without crashing"

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

# --- timestamps must be strict, safe ISO datetimes ----------------------------
mkdir -p "$TMP_ROOT/invalid-timestamps/projP"
for n in 1 2; do
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"ts%s","name":"Bash","input":{"command":"false"}}]},"timestamp":"2026-08-20T00:00:00Z token=super-secret"}\n' "$n" \
    > "$TMP_ROOT/invalid-timestamps/projP/s${n}.jsonl"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"ts%s","is_error":true,"content":"invalid timestamp failure"}]},"timestamp":"2026-08-20T00:00:01Z token=super-secret"}\n' "$n" \
    >> "$TMP_ROOT/invalid-timestamps/projP/s${n}.jsonl"
done
run "$TMP_ROOT/invalid-timestamps" --min-sessions 2 --json > "$TMP_ROOT/invalid-timestamps.json" 2>/dev/null
[ $? -eq 1 ] || fail "failures with invalid timestamps should still be reported"
"$PY" -c "
import json,re,sys
d=json.load(open(sys.argv[1]))
assert 'super-secret' not in json.dumps(d), d
assert d['scanned']['oldest'] and d['scanned']['newest'], d['scanned']
assert re.fullmatch(r'\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z', d['scanned']['oldest']), d['scanned']
assert d['groups'][0]['first_seen'] is None and d['groups'][0]['last_seen'] is None, d['groups']
" "$TMP_ROOT/invalid-timestamps.json" || fail "invalid timestamps leaked or did not use mtime coverage"
pass "invalid timestamps are dropped while coverage uses file mtime"

# --- redact multiline headers before whitespace normalization ------------------
mkdir -p "$TMP_ROOT/multiline-header/projQ"
for n in 1 2; do
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"mh%s","name":"Bash","input":{"command":"false"}}]}}\n' "$n" \
    > "$TMP_ROOT/multiline-header/projQ/s${n}.jsonl"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"mh%s","is_error":true,"content":"Authorization: Bearer super-secret-%s\\nrequest failed: timeout"}]}}\n' "$n" "$n" \
    >> "$TMP_ROOT/multiline-header/projQ/s${n}.jsonl"
done
run "$TMP_ROOT/multiline-header" --min-sessions 2 --json > "$TMP_ROOT/multiline-header.json" 2>/dev/null
[ $? -eq 1 ] || fail "multiline header failures should be reported"
"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert len(d['groups']) == 1, d['groups']
sig=d['groups'][0]['display']['signature']
assert 'REDACTED' in sig and 'timeout' in sig, sig
assert 'super-secret' not in json.dumps(d), d
" "$TMP_ROOT/multiline-header.json" || fail "multiline header redaction lost failure detail"
pass "multiline header redaction preserves the failure detail"

# --- hook identities retain distinct redacted labels ---------------------------
mkdir -p "$TMP_ROOT/distinct-hooks/projR"
for n in 1 2; do
  printf '{"type":"attachment","attachment":{"type":"hook_error","hookName":"./hooks/check-0%s.sh","hookEvent":"PreToolUse"}}\n' "$n" \
    > "$TMP_ROOT/distinct-hooks/projR/s${n}.jsonl"
done
run "$TMP_ROOT/distinct-hooks" --min-sessions 1 --json > "$TMP_ROOT/distinct-hooks.json" 2>/dev/null
[ $? -eq 1 ] || fail "distinct hooks should be reported"
"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert len(d['groups']) == 2, d['groups']
assert {g['display']['hook'] for g in d['groups']} == {'./hooks/check-01.sh', './hooks/check-02.sh'}, d['groups']
" "$TMP_ROOT/distinct-hooks.json" || fail "distinct hook labels were merged"
pass "distinct hook labels remain separate findings"

# --- transcript booleans must be literal JSON true -----------------------------
mkdir -p "$TMP_ROOT/strict-bools/projS"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"bf","name":"Bash","input":{"command":"false"}}]}}\n' \
  > "$TMP_ROOT/strict-bools/projS/false.jsonl"
printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"bf","is_error":"false","content":"should not count"}]}}\n' \
  >> "$TMP_ROOT/strict-bools/projS/false.jsonl"
out=$(run "$TMP_ROOT/strict-bools" --min-sessions 1 2>&1); rc=$?
[ $rc -eq 0 ] || fail "string false must not count as a tool error (rc=$rc)"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"bt","name":"Bash","input":{"command":"false"}}]}}\n' \
  > "$TMP_ROOT/strict-bools/projS/true.jsonl"
printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"bt","is_error":true,"content":"literal true counts"}]}}\n' \
  >> "$TMP_ROOT/strict-bools/projS/true.jsonl"
out=$(run "$TMP_ROOT/strict-bools" --min-sessions 1 2>&1); rc=$?
[ $rc -eq 1 ] || fail "literal true must count as a tool error (rc=$rc)"
printf '%s' "$out" | grep -q 'literal true counts' || fail "literal true failure was not reported"
pass "only literal JSON true counts as a failure"

mkdir -p "$TMP_ROOT/strict-timeout/projT"
for n in 1 2; do
  printf '{"type":"attachment","attachment":{"type":"hook_cancelled","hookName":"slowhook","hookEvent":"PreToolUse","timedOut":"false"}}\n' \
    > "$TMP_ROOT/strict-timeout/projT/s${n}.jsonl"
done
out=$(run "$TMP_ROOT/strict-timeout" --min-sessions 2 2>&1); rc=$?
[ $rc -eq 0 ] || fail "string false timeout must not count (rc=$rc)"
pass "only literal JSON true counts as a timeout"

# --- tool identity is lossless while its display stays bounded -----------------
mkdir -p "$TMP_ROOT/long-tool-names/projU"
tool_prefix=$(printf 'tool-%.0s' {1..14})
for suffix in alpha beta; do
  tool_name="${tool_prefix}${suffix}"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tn-%s","name":"%s","input":{"command":"false"}}]}}\n' \
    "$suffix" "$tool_name" > "$TMP_ROOT/long-tool-names/projU/${suffix}.jsonl"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tn-%s","is_error":true,"content":"shared long-tool failure"}]}}\n' \
    "$suffix" >> "$TMP_ROOT/long-tool-names/projU/${suffix}.jsonl"
done
run "$TMP_ROOT/long-tool-names" --min-sessions 1 --json > "$TMP_ROOT/long-tool-names.json" 2>/dev/null
[ $? -eq 1 ] || fail "distinct long tool names should be reported"
"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert len(d['groups']) == 2, d['groups']
assert {g['key'][0] for g in d['groups']} and len({g['key'][0] for g in d['groups']}) == 2, d['groups']
assert len({g['key'][1] for g in d['groups']}) == 1, d['groups']
assert {g['sessions'] for g in d['groups']} == {1}, d['groups']
assert all(g['display']['tool'] == '${tool_prefix}'[:64] + '...' for g in d['groups']), d['groups']
" "$TMP_ROOT/long-tool-names.json" || fail "long tool identities were truncated before grouping"
pass "long tool names remain distinct behind bounded displays"

# --- display limits must be positive ------------------------------------------
out=$(run "$TMP_ROOT/live" --top -1 2>&1); rc=$?
[ $rc -eq 2 ] || fail "negative --top must be rejected (rc=$rc)"
printf '%s' "$out" | grep -Fq -- '--top must be >= 1' || fail "negative --top error was unclear"
pass "negative --top is rejected before reporting"


# --- control characters must not smuggle a secret past the redactor -----------------
# Regression for review-14 / review-20 / review-22: three rounds of one root cause. A
# control byte between key and separator, or inside the key itself, defeated every
# assignment pattern because \s does not match C0/C1 controls - the redactor declined and
# clean_text() then repaired the string into a readable secret. Verified leaking before
# the fix.
redaction_case() {  # <label> <python-repr-of-input> <needle-that-must-not-appear>
  local label=$1 src=$2 needle=$3 out
  out=$(PYTHONDONTWRITEBYTECODE=1 "$PY" - "$src" <<'PYEOF'
import importlib.util, sys
src = eval(sys.argv[1])          # read BEFORE argv is replaced for the module load
spec = importlib.util.spec_from_file_location("h", "bin/fm-error-harvest.py")
m = importlib.util.module_from_spec(spec)
sys.argv = ["h"]
try:
    spec.loader.exec_module(m)
except SystemExit:
    pass
print(m.untrusted_text(src))
PYEOF
) || fail "redaction probe failed for $label"
  case "$out" in
    *"$needle"*) fail "$label: secret survived redaction -> $out" ;;
  esac
  pass "$label"
}

redaction_case "plain assignment is redacted"        "'token=super-secret'"          "super-secret"
redaction_case "ESC before the separator"            "'token\x1b=super-secret'"      "super-secret"
redaction_case "NUL before the separator"            "'api_key\x00=super-secret'"    "super-secret"
redaction_case "control inside the key rejoins it"   "'pass\x7fword=super-secret'"   "super-secret"
redaction_case "control inside the value"            "'token=sup\x1ber-secret'"      "er-secret"
redaction_case "tab inside the value"                "'token=sup\ter-secret'"        "er-secret"
redaction_case "newline-folded value"                "'token=sup\n er-secret'"       "er-secret"
redaction_case "carriage-folded value"               "'token=sup\r er-secret'"       "er-secret"
redaction_case "newline-separated value"             "'token=sup\ner-secret'"        "er-secret"
redaction_case "carriage-separated value"            "'token=sup\rer-secret'"        "er-secret"
redaction_case "punctuation-separated value"         "'token=sup\n~er-secret'"       "er-secret"
redaction_case "brace-separated value"               "'token=sup\n{er-secret'"       "er-secret"
redaction_case "nonbreaking-space value"             "'token=sup\u00a0er-secret'"    "er-secret"
redaction_case "private-use key separator"           "'token\ue001=super-secret'"    "super-secret"
redaction_case "bearer token split by a control"     "'Authorization: Bearer abc\x1bdefghijkl'" "defghijkl"
redaction_case "folded header value"                 "'Authorization: Bearer abcdef\n ghijklmnop'" "ghijklmnop"
redaction_case "split bearer value"                  "'Bearer abcdefghijklmno\npqrstuvwxyz0123'" "pqrstuvwxyz0123"
redaction_case "split JWT"                           "'abcdefgh\nijkl.mnopqrst\nuvwx.yzABCDEF\nGHIJ'" "GHIJ"
redaction_case "split opaque value"                  "'ABCDEFGHIJKLMNOP\nQRSTUVWXYZ012345'" "QRSTUVWXYZ012345"

out=$(PYTHONDONTWRITEBYTECODE=1 "$PY" - <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("h", "bin/fm-error-harvest.py")
m = importlib.util.module_from_spec(spec)
sys.argv = ["h"]
try:
    spec.loader.exec_module(m)
except SystemExit:
    pass
print(m.display(m.redact_secrets("Authorization: Bearer super$secret")))
PYEOF
)
case "$out" in
  *super*|*secret*) fail "default excerpt leaked an allowlist-external secret: $out" ;;
esac
pass "default excerpts exclude allowlist-external secret material"

out=$(PYTHONDONTWRITEBYTECODE=1 "$PY" - <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("h", "bin/fm-error-harvest.py")
m = importlib.util.module_from_spec(spec)
sys.argv = ["h"]
try:
    spec.loader.exec_module(m)
except SystemExit:
    pass
print(m.redact_secrets("gggggggggggg hhhhhhhhhhhh"))
PYEOF
)
[ "$out" = "gggggggggggg hhhhhhhhhhhh" ] || fail "low-entropy opaque text lost its boundary"
pass "low-entropy opaque text preserves its boundary"

out=$(PYTHONDONTWRITEBYTECODE=1 "$PY" - <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("h", "bin/fm-error-harvest.py")
m = importlib.util.module_from_spec(spec)
sys.argv = ["h"]
try:
    spec.loader.exec_module(m)
except SystemExit:
    pass
redacted = m.redact_secrets("token=sup\u00a0er-secret")
assert m.clean_text(redacted) == redacted, redacted
PYEOF
) || fail "redacted output was normalized again"
pass "redacted output is already canonical"

# A header must redact its value WITHOUT swallowing the line after it.
out=$(PYTHONDONTWRITEBYTECODE=1 "$PY" - <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("h", "bin/fm-error-harvest.py")
m = importlib.util.module_from_spec(spec)
sys.argv = ["h"]
try:
    spec.loader.exec_module(m)
except SystemExit:
    pass
print(m.untrusted_text("Authorization: Bearer abcdefghijklmnop\nrequest failed: timeout"))
PYEOF
)
case "$out" in
  *abcdefghijklmnop*) fail "header value leaked: $out" ;;
esac
case "$out" in
  *timeout*) pass "a redacted header does not swallow the failure text after it" ;;
  *) fail "header redaction swallowed the following error text: $out" ;;
esac

mkdir -p "$TMP_ROOT/folded-assignment/projV"
for n in 1 2; do
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"fa%s","name":"Bash","input":{"command":"false"}}]}}\n' "$n" \
    > "$TMP_ROOT/folded-assignment/projV/s${n}.jsonl"
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"fa'"$n"'","is_error":true,"content":"token=sup\ner-secret\nrequest failed: timeout"}]}}' \
    >> "$TMP_ROOT/folded-assignment/projV/s${n}.jsonl"
done
out=$(run "$TMP_ROOT/folded-assignment" --min-sessions 2 2>&1); rc=$?
[ $rc -eq 1 ] || fail "folded assignments should be reported (rc=$rc)"
case "$out" in
  *er-secret*) fail "folded assignment leaked into text report: $out" ;;
esac
printf '%s' "$out" | grep -Fq 'timeout' || fail "folded assignment swallowed the error detail"
run "$TMP_ROOT/folded-assignment" --min-sessions 2 --json > "$TMP_ROOT/folded-assignment.json" 2>/dev/null
[ $? -eq 1 ] || fail "folded assignments should be reported in JSON"
"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
encoded=json.dumps(d)
assert 'er-secret' not in encoded, d
assert 'timeout' in encoded, d
" "$TMP_ROOT/folded-assignment.json" || fail "folded assignment redaction was incomplete"
pass "folded assignments redact through the executable report interface"

printf '\nall fm-error-harvest tests passed\n'
