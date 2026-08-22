#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$ROOT/bin/fm-git-audit.sh"
TMP_ROOT=

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
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-git-audit-tests.XXXXXX")

assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')" ;;
    *) : ;;
  esac
}

new_repo() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  git init -q --bare "$w/origin.git"
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  git -C "$w/seed" switch -q -c main
  printf 'base\n' > "$w/seed/tracked.txt"
  git -C "$w/seed" add tracked.txt
  git -C "$w/seed" commit -qm baseline
  git -C "$w/seed" push -q -u origin main
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/repo"
  printf '%s\n' "$w"
}

branch_line() {
  printf '%s\n' "$1" | awk '$1 == "topic" { print; exit }'
}

classification_lines() {
  printf '%s\n' "$1" | awk '
    /^--- branches and detached HEADs / { in_section=1; next }
    /^--- stashes: / { exit }
    in_section { print }
  '
}

test_stale_origin_ref_is_not_a_remote_copy() {
  local w out line
  w=$(new_repo stale-origin)
  git -C "$w/repo" switch -q -c topic
  printf 'published\n' >> "$w/repo/tracked.txt"
  git -C "$w/repo" add tracked.txt
  git -C "$w/repo" commit -qm published
  git -C "$w/repo" push -q -u origin topic
  printf 'unpublished\n' >> "$w/repo/tracked.txt"
  git -C "$w/repo" add tracked.txt
  git -C "$w/repo" commit -qm unpublished

  out=$("$AUDIT" --no-fetch "$w/repo") || fail "audit failed: $out"
  assert_contains "$out" 'cached refs only; classification may be stale' \
    'no-fetch did not mark remote classifications as cached'
  line=$(branch_line "$out")
  assert_contains "$line" '** LOCAL ONLY - no remote copy **' \
    'stale origin branch was treated as a remote copy'
  pass 'stale origin ref does not count as a remote copy'
}

test_stale_non_origin_ref_is_not_a_remote_copy() {
  local w out line
  w=$(new_repo stale-backup)
  git init -q --bare "$w/backup.git"
  git -C "$w/repo" remote add backup "$w/backup.git"
  git -C "$w/repo" switch -q -c topic
  printf 'published\n' >> "$w/repo/tracked.txt"
  git -C "$w/repo" add tracked.txt
  git -C "$w/repo" commit -qm published
  git -C "$w/repo" push -q backup topic
  printf 'unpublished\n' >> "$w/repo/tracked.txt"
  git -C "$w/repo" add tracked.txt
  git -C "$w/repo" commit -qm unpublished

  out=$("$AUDIT" --no-fetch "$w/repo") || fail "audit failed: $out"
  line=$(branch_line "$out")
  assert_contains "$line" '** LOCAL ONLY - no remote copy **' \
    'stale non-origin branch was treated as a remote copy'

  git -C "$w/repo" push -q backup topic
  out=$("$AUDIT" --no-fetch "$w/repo") || fail "audit failed: $out"
  line=$(branch_line "$out")
  assert_contains "$line" 'backup only - NOT on origin' \
    'reachable non-origin branch was not classified as backed up outside origin'
  pass 'non-origin reachability determines backup status'
}

test_default_refreshes_all_remotes_and_prunes_stale_refs() {
  local w out line
  w=$(new_repo remote-snapshots)
  git init -q --bare "$w/backup.git"
  git -C "$w/repo" remote add backup "$w/backup.git"
  git -C "$w/repo" switch -q -c topic
  printf 'unlanded\n' >> "$w/repo/tracked.txt"
  git -C "$w/repo" add tracked.txt
  git -C "$w/repo" commit -qm unlanded

  git -C "$w/repo" push -q "$w/backup.git" topic:topic
  out=$("$AUDIT" "$w/repo") || fail "audit failed: $out"
  line=$(branch_line "$out")
  assert_contains "$line" 'backup only - NOT on origin' \
    'default audit did not refresh the backup remote'

  git -C "$w/repo" push -q "$w/origin.git" topic:topic
  out=$("$AUDIT" "$w/repo") || fail "audit failed: $out"
  line=$(branch_line "$out")
  assert_contains "$line" 'on origin' 'origin copy was not classified after refresh'

  git -C "$w/repo" push -q "$w/origin.git" --delete topic
  out=$("$AUDIT" "$w/repo") || fail "audit failed: $out"
  line=$(branch_line "$out")
  assert_contains "$line" 'backup only - NOT on origin' \
    'pruned origin ref still counted as a copy'

  git -C "$w/repo" push -q "$w/backup.git" --delete topic
  out=$("$AUDIT" "$w/repo") || fail "audit failed: $out"
  line=$(branch_line "$out")
  assert_contains "$line" '** LOCAL ONLY - no remote copy **' \
    'pruned backup ref still counted as a copy'
  pass 'default audit refreshes every remote and prunes stale refs'
}

test_detached_unlanded_head_is_classified_without_duplicate_branch_row() {
  local w out lines head
  w=$(new_repo detached-head)
  git -C "$w/repo" worktree add -q --detach "$w/detached" HEAD
  printf 'unlanded\n' >> "$w/detached/tracked.txt"
  git -C "$w/detached" add tracked.txt
  git -C "$w/detached" commit -qm unlanded

  out=$("$AUDIT" --no-fetch "$w/repo") || fail "audit failed: $out"
  lines=$(classification_lines "$out")
  assert_contains "$lines" '(detached:' 'detached unlanded head was not classified'
  assert_contains "$lines" '** LOCAL ONLY - no remote copy **' \
    'detached unlanded head did not receive backup classification'

  head=$(git -C "$w/detached" rev-parse HEAD)
  git -C "$w/repo" branch topic "$head"
  out=$("$AUDIT" --no-fetch "$w/repo") || fail "audit failed: $out"
  lines=$(classification_lines "$out")
  assert_contains "$lines" 'topic' 'branch carrying detached head was not classified'
  assert_not_contains "$lines" '(detached:' \
    'detached head was duplicated after a local branch referenced it'
  pass 'detached unlanded heads are classified once'
}

test_stale_origin_ref_is_not_a_remote_copy
test_stale_non_origin_ref_is_not_a_remote_copy
test_default_refreshes_all_remotes_and_prunes_stale_refs
test_detached_unlanded_head_is_classified_without_duplicate_branch_row
printf '%s\n' 'all git audit tests passed'
