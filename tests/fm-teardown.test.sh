#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's unpushed-work safety check.
#
# Covers the local-only fork-remote fix: a local-only-registered project whose
# task pushes its work to a fork (upstream-contribution PRs) must be teardown-
# eligible because a fork IS a remote. The pre-fix code short-circuited to a
# strict local-main check and false-refused legitimate fork-pushed work.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (the fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes  + HEAD on origin remote-tracking branch   -> ALLOW  (no regression)
#   (e) no-mistakes  + truly unpushed work                     -> REFUSE (no regression)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
#
# The merged-PR evidence path (squash merge + delete_branch_on_merge deletes the
# remote branch, so landed work stops being reachable from a remote-tracking ref).
# It must accept ONLY a positive "merged" answer whose head sha is this worktree's
# HEAD, and only about COMMITTED work. "This PR merged" is not "these commits
# merged", so the head sha is what ties the evidence to the work being discarded:
#   (g) unpushed + clean + merged, head sha = HEAD             -> ALLOW  (the fix)
#   (h) unpushed + clean + PR still open                       -> REFUSE (fail safe)
#   (i) unpushed + clean + gh-axi errors                       -> REFUSE (fail safe)
#   (j) unpushed + clean + gh-axi absent from PATH             -> REFUSE (fail safe)
#   (k) unpushed + DIRTY  + merged, head sha = HEAD            -> REFUSE (committed work only)
#   (l) unpushed + clean + merged, quoted merged/sha values    -> ALLOW  (parser portability)
#   (m) unpushed + clean + merged, head sha != HEAD            -> REFUSE, naming BOTH shas
#   (n) unpushed + clean + merged but no head sha reported     -> REFUSE (fail safe)
#   (o) unpushed + clean + gh-axi 404 body with exit status 0  -> REFUSE (fail safe)
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
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

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-teardown-tests.XXXXXX")

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

# Install a logging `no-mistakes` mock. Every invocation appends a line to
# $case_dir/nm.log recording its args, cwd, and the git branch at that cwd, so
# tests can assert whether/where/on-which-branch `axi abort` ran. Args: case_dir
add_logging_no_mistakes() {
  local case_dir=$1 log="$case_dir/nm.log"
  : > "$log"
  cat > "$case_dir/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
branch=\$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo NO-GIT)
printf 'ARGS=[%s] CWD=%s BRANCH=%s\n' "\$*" "\$(pwd)" "\$branch" >> "$log"
exit 0
SH
  chmod +x "$case_dir/fakebin/no-mistakes"
}

# Install a `no-mistakes` mock that fails (non-zero) to prove teardown's abort
# step is best-effort. Args: case_dir
add_failing_no_mistakes() {
  local case_dir=$1
  cat > "$case_dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
echo "no active run" >&2
exit 3
SH
  chmod +x "$case_dir/fakebin/no-mistakes"
}

add_compatible_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.1'
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# Install a `gh-axi` mock that answers `api repos/<owner>/<repo>/pulls/<n>` with a
# response shaped like the real one (verified against lndshk/firstmate PRs 15 and
# 17), and which logs every invocation to $case_dir/gh-axi.log. Both fields are
# injected verbatim so a caller can pass the bare forms real gh-axi emits
# (`true`, a bare sha) or the quoted variants the parsers also tolerate; an empty
# sha omits the head sha line entirely. Note the decoys the parsers must not pick
# up: merge_commit_sha and merged_at at column 0, and base.sha in its own block.
# Args: case_dir merged_value head_sha
add_gh_axi_pr() {
  local case_dir=$1 merged=$2 sha=$3 body="$case_dir/gh-axi-body.txt"
  {
    printf 'number: 7\n'
    printf 'state: closed\n'
    printf 'merged_at: "2026-07-26T23:29:39Z"\n'
    printf 'merge_commit_sha: 1111111111111111111111111111111111111111\n'
    printf 'head:\n'
    printf '  label: "example:fm/task-x1"\n'
    printf '  ref: fm/task-x1\n'
    [ -n "$sha" ] && printf '  sha: %s\n' "$sha"
    printf '  user: example\n'
    printf '  repo:\n'
    printf '    full_name: example/repo\n'
    printf '    default_branch: main\n'
    printf 'base:\n'
    printf '  ref: main\n'
    printf '  sha: 2222222222222222222222222222222222222222\n'
    printf 'merged: %s\n' "$merged"
    printf 'merged_by:\n'
    printf '  login: example\n'
  } > "$body"
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/gh-axi.log"
cat "$body"
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

# The worktree's current HEAD sha, which a merged PR must name to count as
# evidence about these commits. Args: case_dir
wt_head_sha() {
  git -C "$1/wt" rev-parse HEAD
}

# Install a `gh-axi` mock that fails, standing in for an auth problem or a network
# error. Args: case_dir
add_failing_gh_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/gh-axi.log"
echo "gh: authentication required" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

# Install a `gh-axi` mock reproducing the real 404 shape: an error body on stdout
# and exit status 0 (verified live against a nonexistent PR). Nothing in
# pr_is_merged may key off the exit status, so this must still refuse. Args: case_dir
add_notfound_gh_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/gh-axi.log"
printf 'error: "gh: Not Found (HTTP 404)"\ncode: NOT_FOUND\n'
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

# True when any entry of the given PATH string provides an executable <tool>.
# Deterministic by construction (no hash table, no builtin lookup rules), and it
# mirrors how path_without_gh_axi decides which entries to drop.
# Args: path_string tool
path_provides() {
  local pathstr=$1 tool=$2 entry IFS=:
  for entry in $pathstr; do
    [ -n "$entry" ] || continue
    [ -x "$entry/$tool" ] && return 0
  done
  return 1
}

# Echo \$PATH with every entry that provides a real `gh-axi` removed, so the
# "tool absent" case is deterministic on a machine that has gh-axi installed.
path_without_gh_axi() {
  local entry out= IFS=:
  for entry in $PATH; do
    [ -n "$entry" ] || continue
    [ -x "$entry/gh-axi" ] && continue
    out="${out:+$out:}$entry"
  done
  printf '%s\n' "$out"
}

# Dropping whole PATH entries takes everything else in those directories with it.
# On a layout where gh-axi shares a bin dir with git (an npm prefix of /usr/local,
# or an asdf/Nix shim dir), the gh-axi-absent case would quietly become a
# git-absent case: `dirty` and `unpushed` both come back empty, no branch fires,
# and the assertion fails with no hint of the real cause. These tools are not
# mocked in fakebin, so name the ones teardown needs and report the real reason.
# A tool missing from the unfiltered PATH too was never available and is not the
# filter's doing, so it is skipped rather than blamed. Args: filtered_path
assert_path_keeps_teardown_tools() {
  local filtered=$1 tool
  for tool in bash git perl grep sed awk cut head tr; do
    path_provides "$PATH" "$tool" || continue
    path_provides "$filtered" "$tool" && continue
    fail "cannot express the gh-axi-absent case on this PATH layout: removing gh-axi's directory also removes $tool"
  done
}

# Write a meta file for the task. Args: case_dir mode kind
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  cat > "$case_dir/state/task-x1.meta" <<EOF
window=fm-task-x1
worktree=$case_dir/wt
project=$case_dir/project
kind=$kind
mode=$mode
generation=test-task-x1
EOF
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
# Set FM_TEST_BASE_PATH to replace the inherited PATH the mocks are prepended to
# (used to prove behavior when a tool is genuinely absent).
run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:${FM_TEST_BASE_PATH:-$PATH}" \
    "$TEARDOWN" task-x1 "$@"
}

# Exit code expectation. Args: expected actual label
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

assert_queued_dispatch_checks() {
  local out=$1 label=$2
  printf '%s\n' "$out" | grep -F 'apply secondmate routing' >/dev/null \
    || fail "$label: teardown reminder omitted secondmate routing: $out"
  printf '%s\n' "$out" | grep -F 'advisory three-active-ordinary-report limit before every dispatch' >/dev/null \
    || fail "$label: teardown reminder omitted advisory capacity check: $out"
  printf '%s\n' "$out" | grep -F 'unless the captain explicitly overrides that dispatch' >/dev/null \
    || fail "$label: teardown reminder omitted explicit captain override: $out"
  printf '%s\n' "$out" | grep -F 'never kill, interrupt, or discard existing work to make room' >/dev/null \
    || fail "$label: teardown reminder could displace existing work: $out"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  pass "local-only worktree with HEAD on a fork remote is torn down (fix holds)"
}

test_teardown_prompts_tasks_axi_done_when_compatible() {
  local case_dir out
  case_dir=$(make_case tasks-axi-reminder)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with compatible tasks-axi"
  printf '%s\n' "$out" | grep -F 'tasks-axi done task-x1 --pr https://github.com/example/repo/pull/7' >/dev/null \
    || fail "teardown did not prompt tasks-axi done: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi ready' >/dev/null \
    || fail "teardown did not prompt tasks-axi ready: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  assert_queued_dispatch_checks "$out" "tasks-axi reminder"
  printf '%s\n' "$out" | grep -F 'keep Done to the 10 most recent' >/dev/null \
    && fail "teardown kept manual Done pruning in compatible tasks-axi prompt: $out"
  pass "teardown prompts tasks-axi backlog refresh when compatible"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  pass "local-only worktree with work merged into local main is torn down (no regression)"
}

test_no_mistakes_origin_remote_allows() {
  local case_dir rc
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  # Push the task branch to origin and fetch so the worktree sees it.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-origin: teardown should succeed when HEAD is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-origin: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-origin: teardown manual prompt did not preserve date-gate check"
  assert_queued_dispatch_checks "$(cat "$case_dir/stdout")" "manual reminder"
  pass "no-mistakes worktree with HEAD on origin is torn down (no regression)"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with truly unpushed work is refused (no regression)"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
}

# The zombie-run fix: a no-mistakes ship teardown must close the run by calling
# `no-mistakes axi abort` from inside the worktree while still on the task branch
# (before the detach), so an externally-merged run does not linger as "running".
test_no_mistakes_ship_aborts_run_on_task_branch() {
  local case_dir line
  case_dir=$(make_case abort-nm-ship)
  write_meta "$case_dir" no-mistakes ship
  add_logging_no_mistakes "$case_dir"

  run_teardown "$case_dir" >/dev/null 2>&1 || fail "abort-nm-ship: teardown failed"

  [ -s "$case_dir/nm.log" ] || fail "abort-nm-ship: no-mistakes was never invoked"
  line=$(cat "$case_dir/nm.log")
  printf '%s\n' "$line" | grep -qF 'ARGS=[axi abort]' \
    || fail "abort-nm-ship: expected 'axi abort', got: $line"
  printf '%s\n' "$line" | grep -qF "CWD=$case_dir/wt" \
    || fail "abort-nm-ship: abort did not run from inside the worktree: $line"
  printf '%s\n' "$line" | grep -qF 'BRANCH=fm/task-x1' \
    || fail "abort-nm-ship: abort did not run while on the task branch: $line"
  pass "no-mistakes ship teardown aborts the run from the worktree on the task branch"
}

# Guarded to KIND!=scout: a scout teardown must NOT abort a run.
test_scout_does_not_abort_run() {
  local case_dir
  case_dir=$(make_case abort-scout)
  write_meta "$case_dir" no-mistakes scout
  add_logging_no_mistakes "$case_dir"
  # Scout teardown needs a report to be eligible; point DATA at the case dir.
  mkdir -p "$case_dir/data/task-x1"
  echo findings > "$case_dir/data/task-x1/report.md"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 >/dev/null 2>&1 || fail "abort-scout: teardown failed"

  [ ! -s "$case_dir/nm.log" ] \
    || fail "abort-scout: scout teardown invoked no-mistakes: $(cat "$case_dir/nm.log")"
  pass "scout teardown does not abort a no-mistakes run (KIND!=scout guard holds)"
}

# Guarded to MODE=no-mistakes: a local-only teardown must NOT abort a run.
test_local_only_does_not_abort_run() {
  local case_dir
  case_dir=$(make_case abort-local-only)
  write_meta "$case_dir" local-only ship
  add_logging_no_mistakes "$case_dir"
  # Make it teardown-eligible: merge the (unchanged) HEAD is already on main.

  run_teardown "$case_dir" >/dev/null 2>&1 || fail "abort-local-only: teardown failed"

  [ ! -s "$case_dir/nm.log" ] \
    || fail "abort-local-only: local-only teardown invoked no-mistakes: $(cat "$case_dir/nm.log")"
  pass "local-only teardown does not abort a run (MODE=no-mistakes guard holds)"
}

# Best-effort: a failing `no-mistakes axi abort` must not fail teardown.
test_abort_failure_does_not_fail_teardown() {
  local case_dir rc
  case_dir=$(make_case abort-fails)
  write_meta "$case_dir" no-mistakes ship
  add_failing_no_mistakes "$case_dir"

  set +e
  run_teardown "$case_dir" >/dev/null 2>&1
  rc=$?
  set -e

  expect_code 0 "$rc" "abort-fails: teardown must succeed despite a failing abort"
  [ ! -f "$case_dir/state/task-x1.meta" ] \
    || fail "abort-fails: teardown did not complete (meta still present)"
  pass "a failing no-mistakes abort does not fail teardown (best-effort |\\| true)"
}

test_legacy_meta_gets_generation_and_atomic_marker() {
  local case_dir marker
  case_dir=$(make_case legacy-generation)
  write_meta "$case_dir" local-only ship
  sed '/^generation=/d' "$case_dir/state/task-x1.meta" \
    > "$case_dir/state/task-x1.meta.legacy"
  mv "$case_dir/state/task-x1.meta.legacy" "$case_dir/state/task-x1.meta"

  run_teardown "$case_dir" >/dev/null \
    || fail "legacy-generation: teardown failed"

  marker="$case_dir/state/.firstmate-supervisor.teardown-task-x1"
  [ -f "$marker" ] || fail "legacy-generation: completion marker was not written"
  awk -F '\t' '
    $1 == "v1" && $2 ~ /^generation:[0-9]+-[0-9]+-[0-9]+$/ && $6 == "complete" {
      found=1
    }
    END { exit !found }
  ' "$marker" || fail "legacy-generation: marker lacked an explicit generated identity"
  [ ! -d "$case_dir/state/.firstmate-supervisor.teardown-locks" ] \
    || fail "legacy-generation: teardown created the obsolete marker-lock subsystem"
  pass "legacy metadata receives an explicit generation before teardown writes its marker"
}

test_duplicate_generation_is_rejected_unchanged() {
  local case_dir rc marker
  case_dir=$(make_case duplicate-generation)
  write_meta "$case_dir" local-only ship
  printf 'generation=duplicate-task-x1\n' >> "$case_dir/state/task-x1.meta"

  set +e
  run_teardown "$case_dir" >/dev/null 2>&1
  rc=$?
  set -e

  expect_code 1 "$rc" "duplicate-generation: teardown must reject ambiguous identity"
  [ "$(grep -c '^generation=' "$case_dir/state/task-x1.meta")" -eq 2 ] \
    || fail "duplicate-generation: teardown rewrote duplicate generation declarations"
  marker="$case_dir/state/.firstmate-supervisor.teardown-task-x1"
  [ ! -e "$marker" ] || fail "duplicate-generation: teardown wrote a marker for ambiguous identity"
  pass "teardown rejects duplicate generation declarations without rewriting metadata"
}

test_generation_change_preserves_reused_id_state() {
  local case_dir real_treehouse marker rc
  case_dir=$(make_case generation-recheck)
  write_meta "$case_dir" local-only ship
  printf 'working: new generation owns this receipt\n' > "$case_dir/state/task-x1.status"
  real_treehouse="$case_dir/fakebin/treehouse"
cat > "$real_treehouse" <<SH
#!/usr/bin/env bash
: > "$case_dir/treehouse.called"
sed 's/^generation=.*/generation=reused-task-x1/' \
  "$case_dir/state/task-x1.meta" > "$case_dir/state/task-x1.meta.new"
mv "$case_dir/state/task-x1.meta.new" "$case_dir/state/task-x1.meta"
exit 0
SH
  chmod +x "$real_treehouse"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "generation-recheck: generation replacement must stop same-id cleanup"
  [ -f "$case_dir/treehouse.called" ] \
    || fail "generation-recheck: external worktree cleanup was skipped"
  grep -Fx 'generation=reused-task-x1' "$case_dir/state/task-x1.meta" >/dev/null \
    || fail "generation-recheck: replacement metadata was removed"
  [ -f "$case_dir/state/task-x1.status" ] \
    || fail "generation-recheck: replacement status was removed"
  marker="$case_dir/state/.firstmate-supervisor.teardown-task-x1"
  awk -F '\t' '$6 == "failed" && $7 == "generation-changed" { found=1 } END { exit !found }' \
    "$marker" || fail "generation-recheck: mismatch was not recorded by teardown"
  [ ! -d "$case_dir/state/.firstmate-supervisor.teardown-locks" ] \
    || fail "generation-recheck: mismatch handling created marker locks"
  pass "explicit generation rechecks protect reused task ids without supervisor locks"
}

# A PR-based teardown passes project= back to fm-fleet-sync.sh explicitly.
# When that project path is a symlink, the canonical checkout must still catch
# up to origin after teardown. The git wrapper rejects the symlink as a -C path,
# proving fleet sync resolved it rather than relying on git to follow it.
test_teardown_syncs_symlink_project_target() {
  local case_dir canonical updater real_git out
  case_dir=$(make_case symlink-project-sync)
  canonical="$case_dir/canonical-project"
  updater="$case_dir/updater"

  mv "$case_dir/project" "$canonical"
  ln -s "$canonical" "$case_dir/project"
  write_meta "$case_dir" no-mistakes ship
  add_failing_no_mistakes "$case_dir"

  git clone -q "$case_dir/origin.git" "$updater"
  printf 'merged change\n' > "$updater/merged.txt"
  git -C "$updater" add merged.txt
  git -C "$updater" -c user.email=t@t -c user.name=t commit -qm "merged change"
  git -C "$updater" push -q origin main

  real_git=$(command -v git)
  cat > "$case_dir/fakebin/git" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -C ]; then
  printf '%s\n' "\${2:-}" >> "$case_dir/git-c.log"
  if [ -L "\${2:-}" ]; then
    printf 'test git wrapper refuses symlink -C path: %s\n' "\${2:-}" >&2
    exit 97
  fi
fi
exec "$real_git" "\$@"
SH
  chmod +x "$case_dir/fakebin/git"

  out=$(run_teardown "$case_dir") || fail "symlink-project-sync: teardown failed: $out"

  [ "$(git -C "$canonical" rev-parse HEAD)" = "$(git -C "$case_dir/origin.git" rev-parse main)" ] \
    || fail "symlink-project-sync: canonical checkout did not catch up to origin/main"
  printf '%s\n' "$out" | grep -F "$case_dir/project: synced " >/dev/null \
    || fail "symlink-project-sync: teardown did not report the symlink project sync: $out"
  if grep -Fx "$case_dir/project" "$case_dir/git-c.log" >/dev/null; then
    fail "symlink-project-sync: fleet sync passed the symlink path to git -C"
  fi
  grep -Fx "$canonical" "$case_dir/git-c.log" >/dev/null \
    || fail "symlink-project-sync: fleet sync did not operate on the canonical target"
  pass "PR-based teardown fast-forwards a symlink project's canonical target"
}

# (g) The merged-PR evidence path: a squash merge deleted the remote branch, so the
# commits are on no remote-tracking ref, but GitHub positively reports the PR merged
# AND names this worktree's HEAD as the head it merged.
test_merged_pr_allows_unpushed_teardown() {
  local case_dir rc head
  case_dir=$(make_case merged-pr-allow)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "work that was squash-merged"
  head=$(wt_head_sha "$case_dir")
  add_failing_no_mistakes "$case_dir"
  add_gh_axi_pr "$case_dir" true "$head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-pr-allow: teardown should succeed when the PR merged this HEAD"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-pr-allow: teardown printed a REFUSED line"
  grep -F "landed: https://github.com/example/repo/pull/7 merged this worktree's HEAD $head" "$case_dir/stderr" >/dev/null \
    || fail "merged-pr-allow: teardown did not report the merged-PR evidence: $(cat "$case_dir/stderr")"
  grep -F 'api repos/example/repo/pulls/7' "$case_dir/gh-axi.log" >/dev/null \
    || fail "merged-pr-allow: URL was not parsed into repo/number: $(cat "$case_dir/gh-axi.log")"
  pass "unpushed worktree whose PR merged this exact HEAD is torn down (the fix)"
}

# (h) Any non-merged state is not evidence; the refusal must stand.
test_open_pr_refuses_unpushed_teardown() {
  local case_dir rc head
  case_dir=$(make_case open-pr-refuse)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "work still in review"
  head=$(wt_head_sha "$case_dir")
  add_gh_axi_pr "$case_dir" false "$head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "open-pr-refuse: teardown should refuse an unmerged PR"
  grep -q REFUSED "$case_dir/stderr" || fail "open-pr-refuse: no REFUSED line in stderr"
  grep -F 'GitHub did not report it merged' "$case_dir/stderr" >/dev/null \
    || fail "open-pr-refuse: refusal did not explain the PR check: $(cat "$case_dir/stderr")"
  pass "unpushed worktree whose PR is still open is refused (fail safe)"
}

# (m) The correctness hole this guard exists to close: a stale, wrong, or copy-pasted
# pr=, or commits made after the PR merged, mean the merged head is NOT these commits.
# Refusing is correct, and the message must name both shas so it cannot read as a
# network failure.
test_merged_pr_with_other_head_refuses_teardown() {
  local case_dir rc head other
  case_dir=$(make_case merged-pr-other-head-refuse)
  other=5844d51984320907cbb062e41cf1324c5fed1246
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "work that was squash-merged"
  wt_commit "$case_dir" "further work committed after the merge, never pushed"
  head=$(wt_head_sha "$case_dir")
  add_gh_axi_pr "$case_dir" true "$other"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merged-pr-other-head-refuse: a PR that merged a different head is not evidence"
  grep -q REFUSED "$case_dir/stderr" || fail "merged-pr-other-head-refuse: no REFUSED line in stderr"
  grep -F "merged head $other" "$case_dir/stderr" >/dev/null \
    || fail "merged-pr-other-head-refuse: refusal did not name the PR head sha: $(cat "$case_dir/stderr")"
  grep -F "this worktree is at $head" "$case_dir/stderr" >/dev/null \
    || fail "merged-pr-other-head-refuse: refusal did not name the worktree HEAD: $(cat "$case_dir/stderr")"
  grep -F 'could not be reached' "$case_dir/stderr" >/dev/null \
    && fail "merged-pr-other-head-refuse: a sha mismatch was reported as a lookup failure"
  pass "a merged PR naming a different head refuses and names both shas (the hole closed)"
}

# (n) Merged, but no head sha to compare against: never assume, always refuse.
test_merged_pr_without_head_sha_refuses_teardown() {
  local case_dir rc
  case_dir=$(make_case merged-pr-no-head-sha)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "work whose PR head sha cannot be resolved"
  add_gh_axi_pr "$case_dir" true ""

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merged-pr-no-head-sha: an unresolvable head sha must refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "merged-pr-no-head-sha: no REFUSED line in stderr"
  grep -F 'did not report it merged with a head sha matching' "$case_dir/stderr" >/dev/null \
    || fail "merged-pr-no-head-sha: refusal did not explain the missing head sha: $(cat "$case_dir/stderr")"
  pass "a merged PR with no resolvable head sha is refused (fail safe)"
}

# (o) Real gh-axi exits 0 on a 404 and prints an error body, so a zero exit status is
# never evidence on its own.
test_notfound_gh_axi_refuses_unpushed_teardown() {
  local case_dir rc
  case_dir=$(make_case gh-axi-notfound-refuse)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "work whose PR does not exist"
  add_notfound_gh_axi "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-axi-notfound-refuse: a 404 body with exit 0 must still refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-axi-notfound-refuse: no REFUSED line in stderr"
  [ -s "$case_dir/gh-axi.log" ] || fail "gh-axi-notfound-refuse: the PR check never ran"
  pass "a 404 body with a zero exit status is refused (fail safe)"
}

# (i) A tool that errors (auth, network) is not a positive answer.
test_failing_gh_axi_refuses_unpushed_teardown() {
  local case_dir rc
  case_dir=$(make_case gh-axi-error-refuse)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "work with an unreachable PR"
  add_failing_gh_axi "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-axi-error-refuse: teardown should refuse when the PR check errors"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-axi-error-refuse: no REFUSED line in stderr"
  [ -s "$case_dir/gh-axi.log" ] || fail "gh-axi-error-refuse: the PR check never ran"
  pass "unpushed worktree is refused when the PR check errors (fail safe)"
}

# (j) No gh-axi on PATH at all: still a refusal, never an assumed merge.
test_missing_gh_axi_refuses_unpushed_teardown() {
  local case_dir rc filtered
  case_dir=$(make_case gh-axi-missing-refuse)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "work with no way to check the PR"

  # Assert outside a command substitution: fail's exit would only kill a subshell.
  filtered=$(path_without_gh_axi)
  assert_path_keeps_teardown_tools "$filtered"
  path_provides "$filtered" gh-axi \
    && fail "gh-axi-missing-refuse: gh-axi is still reachable, so the case is not being exercised"

  set +e
  FM_TEST_BASE_PATH="$filtered" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-axi-missing-refuse: teardown should refuse without gh-axi"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-axi-missing-refuse: no REFUSED line in stderr"
  pass "unpushed worktree is refused when gh-axi is absent (fail safe)"
}

# (k) A merged PR is evidence about COMMITTED work only; uncommitted changes still refuse,
# and the PR check must not even be consulted.
test_merged_pr_does_not_cover_dirty_worktree() {
  local case_dir rc
  case_dir=$(make_case merged-pr-dirty-refuse)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "work that was squash-merged"
  add_gh_axi_pr "$case_dir" true "$(wt_head_sha "$case_dir")"
  printf 'uncommitted\n' > "$case_dir/wt/scratch.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merged-pr-dirty-refuse: a merged PR must not cover uncommitted changes"
  grep -q REFUSED "$case_dir/stderr" || fail "merged-pr-dirty-refuse: no REFUSED line in stderr"
  grep -F 'evidence about committed work only' "$case_dir/stderr" >/dev/null \
    || fail "merged-pr-dirty-refuse: refusal blamed the PR check it never ran: $(cat "$case_dir/stderr")"
  [ ! -f "$case_dir/gh-axi.log" ] \
    || fail "merged-pr-dirty-refuse: the PR check ran despite uncommitted changes"
  pass "a merged PR does not license tearing down a dirty worktree (committed work only)"
}

# (l) Both parsers must also tolerate quoted values, using portable BRE/awk only.
test_quoted_merged_state_allows_unpushed_teardown() {
  local case_dir rc head
  case_dir=$(make_case merged-pr-quoted-allow)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "work that was squash-merged"
  head=$(wt_head_sha "$case_dir")
  add_failing_no_mistakes "$case_dir"
  add_gh_axi_pr "$case_dir" '"true"' "\"$head\""

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-pr-quoted-allow: quoted merged and sha values should be accepted"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-pr-quoted-allow: teardown printed a REFUSED line"
  pass "the PR merged/sha parsers accept quoted values (portable BRE and awk)"
}

test_local_only_fork_remote_allows
test_teardown_prompts_tasks_axi_done_when_compatible
test_no_mistakes_ship_aborts_run_on_task_branch
test_scout_does_not_abort_run
test_local_only_does_not_abort_run
test_abort_failure_does_not_fail_teardown
test_legacy_meta_gets_generation_and_atomic_marker
test_duplicate_generation_is_rejected_unchanged
test_generation_change_preserves_reused_id_state
test_teardown_syncs_symlink_project_target
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_origin_remote_allows
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
test_merged_pr_allows_unpushed_teardown
test_open_pr_refuses_unpushed_teardown
test_failing_gh_axi_refuses_unpushed_teardown
test_missing_gh_axi_refuses_unpushed_teardown
test_merged_pr_does_not_cover_dirty_worktree
test_quoted_merged_state_allows_unpushed_teardown
test_merged_pr_with_other_head_refuses_teardown
test_merged_pr_without_head_sha_refuses_teardown
test_notfound_gh_axi_refuses_unpushed_teardown
