---
name: firstmate-local
description: Tools and hazards that exist only in this fork of firstmate and nowhere upstream - the stall detector, transcript error harvester, unlanded-work audit, Codex safety-menu clearing, and the symlinked production checkout. Load when working in this firstmate home, when a bin/ script is not documented upstream, or before touching projects/quant-src.
---

# Local to this fork

Upstream ships none of the following and its documentation never mentions them.
Everything else in this repo is upstream's and is deliberately kept byte-identical,
so an upstream sync replaces it cleanly. Nothing here modifies an upstream file.

## Tools

- `bin/fm-stall-check.sh` - read-only sweep for work that is finished, dormant,
  unrelayed, or unlanded, where nothing changed so no wake will ever fire. This is
  a third hazard class that neither the wake queue nor watcher liveness can
  surface. Run it plain to see everything; `--fast` skips the pane/process checks.
- `bin/fm-error-harvest.py` - groups recurring tool errors, denials, and hook
  failures across Claude Code transcripts, ranked by how many SESSIONS each
  touches rather than raw hit count, so one noisy loop cannot outrank a fault
  hitting many lanes. Report text is untrusted transcript content printed as-is:
  do not paste raw reports anywhere public.
- `bin/fm-git-audit.sh` - audits unlanded work and stray worktrees.
- `bin/fm-codex-safety-lib.sh` - clears Codex's additional-safety menu on a
  crewmate pane so a crew does not stall there indefinitely. tmux-only by
  construction; callers must confirm the backend first. `FM_SAFETY_AUTOCLEAR=0`
  disables it. Upstream has no handling for this dialog at all - its own "safety"
  code is shell-glyph classification, an unrelated thing.

## Where the wiring lives

These tools are invoked from home-local `state/*.check.sh` scripts, not from
edits to upstream's `bin/`. `state/` is gitignored, so the wiring survives every
upstream sync untouched and adds no conflict surface. `bin/fm-watch.sh` discovers `state/*.check.sh` by glob but executes a custom check only when a matching private `state/<id>.check-trust` exists, bound to that file's exact bytes by `bin/fm-check-register.sh <id>`.
An unregistered check is rejected silently - it does not warn and does not run.
Registration binds to current bytes, so editing a check requires re-running `bin/fm-check-register.sh <id>` or it stops running.
Adopting upstream requires registering every existing home-local check once: `live-checkout-drift`, `merge-notify`, `open-pr`, `upstream-drift`, `stall-check`, and `codex-safety`.

That split is deliberate and worth preserving: LOGIC lives in additive files here
(so CI covers it), INVOCATION lives in the home (so the repo keeps zero divergence
from upstream). An earlier attempt grafted both into upstream's `fm-guard.sh`,
`fm-watch.sh`, `fm-tmux-lib.sh` and `fm-supervise-daemon.sh`; those four edits
conflicted at the sync and are gone.

## One hazard

`projects/quant-src` is a symlink to the live production checkout at
`/mnt/e/Quant/src`. Fleet-sync follows it correctly and
`tests/fm-fleet-sync-symlink.test.sh` guards that, but treat anything that writes
there as touching production. Merging is not deploying: a merged PR does not run
until that checkout is fast-forwarded.

## Keeping current with upstream

`bin/fm-update.sh` and `/updatefirstmate` fetch only `origin` - this fork. Neither
looks at `upstream`, so `/updatefirstmate` reports "up to date" while the fork
drifts arbitrarily far behind. That is how 390 commits accumulated unnoticed.
`state/upstream-drift.check.sh` watches that axis instead, reporting at most
weekly unless the drift crosses into a worse magnitude band.
