#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
#   - A main-home fast-forward activates the newly updated deterministic
#     supervisor; activation failures are reported and secondmate homes skip it.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE="$ROOT/bin/fm-update.sh"
TMP_ROOT=

# Deterministic, isolated git identity and config for fixture commits.
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.com
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.com

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

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-update-tests.XXXXXX")

assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, a skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  cat > "$w/seed/bin/fm-supervisor.sh" <<'SH'
#!/usr/bin/env bash
printf 'v1 %s\n' "${1:-}" > "$FM_HOME/state/update-supervisor-start"
if [ "${FM_TEST_SUPERVISOR_FAIL:-0}" = 1 ]; then
  printf 'fixture activation failed\n' >&2
  exit 1
fi
printf 'supervisor fixture active\n'
SH
  chmod +x "$w/seed/bin/fm-supervisor.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    sed 's/v1 %s/v2 %s/' "$w/seed/bin/fm-supervisor.sh" \
      > "$w/seed/bin/fm-supervisor.sh.new"
    mv "$w/seed/bin/fm-supervisor.sh.new" "$w/seed/bin/fm-supervisor.sh"
    chmod +x "$w/seed/bin/fm-supervisor.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# --- T1: main + secondmate behind, instruction change ----------------------
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "supervisor: active: supervisor fixture active" "updated supervisor activated"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-secondmates: main:fm-sm1" "updated secondmate is nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  grep -Fx 'v2 start' "$w/home/state/update-supervisor-start" >/dev/null \
    || fail "self-update did not activate the newly updated supervisor script"
  pass "T1 main + secondmate fast-forward, reread + nudge signalled"
}

# --- T2: FF only, never a merge commit -------------------------------------
test_fast_forward_not_merge() {
  local w
  w=$(new_world t2)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null

  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T2 advance is a fast-forward, not a merge commit"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: main:fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both
  rm -f "$w/home/state/update-supervisor-start"

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "supervisor: active: supervisor fixture active" \
    "current main did not recover supervisor activation"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  grep -Fx 'v2 start' "$w/home/state/update-supervisor-start" >/dev/null \
    || fail "current main did not activate its supervisor"
  pass "T6 current update safely reasserts supervisor activation"
}

# --- T7: registry backstop (secondmates.md, no live meta) ------------------
test_registry_backstop() {
  local w out
  w=$(new_world t7)
  # A secondmate worktree with NO meta, registered only in data/secondmates.md.
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' \
    "$w" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "nudge-secondmates: none" "registry-only secondmate is not nudged without live metadata"
  pass "T7 secondmate resolved from registry without inventing a window"
}

# --- T8: dedup across meta + registry, never re-process the firstmate repo --
test_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t8)
  add_sm "$w" sm1
  # Same home also listed in the registry -> must process sm1 exactly once.
  printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' \
    "$w" > "$w/home/data/secondmates.md"
  # A bogus registry line pointing the firstmate repo at itself as a secondmate.
  printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' \
    "$w" >> "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  pass "T8 deduped homes and excluded the firstmate repo itself"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

test_supervisor_activation_failure_is_actionable() {
  local w out status
  w=$(new_world t12)
  bump_origin "$w" instr

  status=0
  out=$(FM_TEST_SUPERVISOR_FAIL=1 FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" 2>&1) || status=$?

  [ "$status" -ne 0 ] || fail "supervisor activation failure did not fail the update command"
  assert_contains "$out" "firstmate: updated " "main fast-forward was not reported before activation failure"
  assert_contains "$out" "supervisor: activation failed: fixture activation failed" \
    "supervisor activation failure was not surfaced"
  assert_contains "$out" "reread-firstmate: yes" "activation failure suppressed caller action summary"
  pass "T12 supervisor activation failure is actionable"
}

test_secondmate_home_skips_supervisor_activation() {
  local w out
  w=$(new_world t13)
  printf 'sm-active\n' > "$w/home/.fm-secondmate-home"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "secondmate-context fixture did not fast-forward"
  assert_contains "$out" "supervisor: skipped: secondmate home" "secondmate context did not skip supervisor"
  [ ! -e "$w/home/state/update-supervisor-start" ] \
    || fail "secondmate home activated a deterministic supervisor owner"
  pass "T13 secondmate home skips supervisor activation"
}

test_legacy_update_activation_bridge() {
  local w out before
  w=$(new_world t14)
  bump_origin "$w" instr
  git -C "$w/main" fetch -q origin
  git -C "$w/main" merge -q --ff-only origin/main
  before=$(git -C "$w/main" rev-parse HEAD)
  rm -f "$w/home/state/update-supervisor-start"

  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --activate-supervisor 2>&1)

  assert_contains "$out" "supervisor: active: supervisor fixture active" \
    "legacy-update compatibility action did not activate the current supervisor"
  grep -Fx 'v2 start' "$w/home/state/update-supervisor-start" >/dev/null \
    || fail "legacy-update compatibility action did not use the post-update supervisor"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "activation-only compatibility action changed repository HEAD"
  # The bridge instruction lives in the skill; AGENTS.md must route the post-update
  # re-read to it, so assert both halves of that chain rather than one file's wording.
  grep -F '.agents/skills/updatefirstmate/SKILL.md' "$ROOT/AGENTS.md" >/dev/null \
    && grep -F 'legacy-updater compatibility step' "$ROOT/AGENTS.md" >/dev/null \
    || fail "post-update AGENTS re-read does not route legacy updater output to the skill"
  grep -F 'Run `bin/fm-update.sh --activate-supervisor` once and surface any failure before continuing.' \
    "$ROOT/.agents/skills/updatefirstmate/SKILL.md" >/dev/null \
    || fail "the updatefirstmate skill does not route legacy updater output to the bridge"
  pass "T14 legacy updater rollout activates the post-update supervisor"
}

test_updates_main_and_secondmate
test_fast_forward_not_merge
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop
test_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_supervisor_activation_failure_is_actionable
test_secondmate_home_skips_supervisor_activation
test_legacy_update_activation_bridge

echo "# all fm-update tests passed"
