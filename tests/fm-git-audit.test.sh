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

test_stale_origin_ref_is_not_a_remote_copy
test_stale_non_origin_ref_is_not_a_remote_copy
printf '%s\n' 'all git audit tests passed'
