#!/usr/bin/env bash
# Report work that is not landed on main, and the worktree scaffolding that has
# accumulated around it.
#
# Two questions this answers that `git status` cannot:
#
#   1. Which commits exist on some branch but not on main - and of those, which
#      exist ONLY on this machine. Work with no remote copy is one disk failure
#      or one over-eager teardown away from gone. fm-teardown.sh already refuses
#      to discard a worktree holding unlanded work, but nothing forces teardown
#      to be RUN: a crashed agent or a closed window leaves the worktree behind,
#      so unlanded branches accumulate silently in abandoned pool slots.
#
#   2. What the scaffolding costs. Audited 2026-08-22: ~/.treehouse held 223 GB,
#      201 GB of it Rust target/ dirs wrapping 2.9 MB of source, and 9 firstmate
#      branches carrying unlanded commits existed nowhere but this disk.
#
# Read-only. It fetches (unless --no-fetch) and otherwise only reads. It never
# deletes, pushes, commits, or checks anything out.
#
# Usage: fm-git-audit.sh [--no-fetch] [--disk] [repo ...]
#   Repos default to $FM_AUDIT_REPOS (colon-separated), else this repo root.
#   --disk adds a per-worktree size column; it is off by default because du over
#   a large pool is slow.

set -eu

FETCH=1
DISK=0
REPOS=()
for a in "$@"; do
  case "$a" in
    --no-fetch) FETCH=0 ;;
    --disk) DISK=1 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) REPOS+=("$a") ;;
  esac
done

if [ "${#REPOS[@]}" -eq 0 ]; then
  if [ -n "${FM_AUDIT_REPOS:-}" ]; then
    IFS=: read -r -a REPOS <<<"$FM_AUDIT_REPOS"
  else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPOS=("$(cd "$SCRIPT_DIR/.." && pwd)")
  fi
fi

short_path() {
  # A literal tilde for display only - never expanded, so it is built from a
  # variable rather than written inside quotes (shellcheck SC2088).
  home_mark='~'
  case "$1" in
    "$HOME"/*) printf '%s/%s' "$home_mark" "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

worktree_paths() {
  git -C "$1" worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}'
}

status=0
for R in "${REPOS[@]}"; do
  if ! git -C "$R" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'fm-git-audit.sh: not a git repository: %s\n' "$R" >&2
    status=1
    continue
  fi
  printf '===== %s\n' "$R"
  if [ "$FETCH" -eq 1 ]; then
    git -C "$R" fetch origin --quiet 2>/dev/null || true
  fi
  if git -C "$R" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    base=origin/main
  else
    base=main
  fi

  printf -- '--- worktrees (each is one rendering; HEAD is per-worktree) ---\n'
  while IFS= read -r wt; do
    if [ ! -d "$wt" ]; then
      printf '  %-50s MISSING DIRECTORY\n' "$(short_path "$wt")"
      continue
    fi
    ref=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || echo '(detached)')
    dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    ahead=$(git -C "$wt" rev-list --count "$base"..HEAD 2>/dev/null || echo '?')
    size=''
    if [ "$DISK" -eq 1 ]; then
      size=$(du -sh "$wt" 2>/dev/null | cut -f1)
    fi
    printf '  %-50s %-30s uncommitted=%-4s unlanded=%-5s %s\n' \
      "$(short_path "$wt")" "$ref" "$dirty" "$ahead" "$size"
  done < <(worktree_paths "$R")

  printf -- '--- branches with commits not on %s ---\n' "$base"
  found=0
  while IFS= read -r b; do
    n=$(git -C "$R" rev-list --count "$base".."$b" 2>/dev/null || echo 0)
    [ "$n" -eq 0 ] && continue
    found=1
    if git -C "$R" rev-parse --verify -q "origin/$b" >/dev/null 2>&1; then
      where='on origin'
    else
      where='** LOCAL ONLY - no remote copy **'
      while IFS= read -r rem; do
        [ "$rem" = origin ] && continue
        if git -C "$R" rev-parse --verify -q "$rem/$b" >/dev/null 2>&1; then
          where="$rem only - NOT on origin"
          break
        fi
      done < <(git -C "$R" remote)
    fi
    printf '  %-46s %4s commits  %s\n' "$b" "$n" "$where"
  done < <(git -C "$R" for-each-ref --format='%(refname:short)' refs/heads/)
  [ "$found" -eq 0 ] && printf '  (none - every branch is landed)\n' || true

  stashes=$(git -C "$R" stash list 2>/dev/null | wc -l | tr -d ' ')
  printf -- '--- stashes: %s (invisible to every command above) ---\n' "$stashes"
  if [ "$stashes" -gt 0 ]; then
    git -C "$R" stash list | sed 's/^/  /'
  fi
  printf '\n'
done
exit "$status"
