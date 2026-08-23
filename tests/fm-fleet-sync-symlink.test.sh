#!/usr/bin/env bash
# Guards ONE behavior: a projects/ entry that is a symlink must be synced through
# to its target checkout, not treated as a plain directory or skipped.
#
# WHY THIS EXISTS: this fork's projects/quant-src is a symlink to the live
# production checkout at /mnt/e/Quant/src. If fleet-sync ever stops following it,
# the production checkout silently stops being refreshed while fleet-sync still
# reports success - a failure that looks like everything is fine.
#
# Upstream handles this correctly today (verified behaviorally, not by reading
# the source), and upstream has no test covering it. This suite is the guard, not
# a re-implementation: it asserts the OUTCOME (the target checkout advanced), and
# deliberately does not assert label text or any other output wording, so an
# upstream cosmetic change cannot fail it.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT/bin/fm-fleet-sync.sh"
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
  [ -n "$TMP_ROOT" ] && rm -rf "$TMP_ROOT"
  return 0
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-sync-symlink.XXXXXX")

# A seed repo, a bare "origin" cloned from it, then two working clones: one
# reached through a symlink, one a real directory as the control.
seed="$TMP_ROOT/seed"
git init -q -b main "$seed"
printf 'one\n' > "$seed/f"
git -C "$seed" add -A
git -C "$seed" commit -qm one

git clone -q --bare "$seed" "$TMP_ROOT/origin.git"
git clone -q "$TMP_ROOT/origin.git" "$TMP_ROOT/target"
git clone -q "$TMP_ROOT/origin.git" "$TMP_ROOT/projects-control"

mkdir -p "$TMP_ROOT/projects"
ln -s "$TMP_ROOT/target" "$TMP_ROOT/projects/linked"
mv "$TMP_ROOT/projects-control" "$TMP_ROOT/projects/control"

[ -L "$TMP_ROOT/projects/linked" ] || fail "fixture is not a symlink"

before=$(git -C "$TMP_ROOT/target" rev-parse HEAD)

# Advance origin WITHOUT pushing: a bare repo can fetch from the seed.
printf 'two\n' > "$seed/g"
git -C "$seed" add -A
git -C "$seed" commit -qm two
git -C "$TMP_ROOT/origin.git" fetch -q "$seed" main:main
want=$(git -C "$TMP_ROOT/origin.git" rev-parse main)

[ "$before" != "$want" ] || fail "fixture did not create a behind state"

FM_HOME="$TMP_ROOT" FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects" \
  "$SYNC" > "$TMP_ROOT/out" 2>&1 \
  || fail "fleet-sync exited non-zero: $(cat "$TMP_ROOT/out")"

# The assertion that matters: the TARGET advanced. Reading it from the target
# path rather than through the symlink is the point - it proves the git work
# landed on the canonical checkout.
after=$(git -C "$TMP_ROOT/target" rev-parse HEAD)
[ "$after" = "$want" ] \
  || fail "symlinked project did not sync its target checkout: target at $after, expected $want"

control_after=$(git -C "$TMP_ROOT/projects/control" rev-parse HEAD)
[ "$control_after" = "$want" ] \
  || fail "control (real directory) did not sync: at $control_after, expected $want"

pass "a symlinked projects/ entry syncs through to its target checkout"
