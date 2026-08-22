#!/usr/bin/env bash
# LOCAL-ONLY compatibility shims. Not an upstream file - do not send it upstream.
#
# The 2026-08-21 upstream sync generalised the tmux pane helpers into a backend-dispatched
# API (tmux / herdr / zellij / cmux / orca), so fm_pane_exists, fm_pane_agent_state and
# fm_pane_current_command disappeared from bin/fm-tmux-lib.sh. Three LOCAL-ONLY scripts still
# call them - bin/fm-supervisor.sh and bin/fm-stall-check.sh - and nothing upstream would ever
# notice them breaking, because upstream does not have those scripts.
#
# This fleet is tmux-only, so the shims bind the backend and keep the old one-argument shape.
# Verified semantics rather than assumed: the old fm_pane_agent_state returned exactly
# alive|dead|unknown, and fm_backend_agent_alive returns exactly alive|dead|unknown, so
# bin/fm-stall-check.sh:342's `= dead` comparison keeps working unchanged.
#
# This lives in its own file on purpose. Putting it inside fm-tmux-lib.sh would guarantee a
# conflict on every future upstream sync of that file; here, future syncs never touch it.
#
# Retire this by porting the local scripts to the backend API directly.

fm_pane_exists() {  # <target>
  [ -n "${1:-}" ] || return 1
  fm_backend_target_exists tmux "$1"
}

fm_pane_agent_state() {  # <target> -> alive|dead|unknown
  fm_backend_agent_alive tmux "$1"
}

fm_pane_current_command() {  # <target>
  # No backend-API equivalent upstream; this was always a direct tmux read.
  tmux list-panes -t "$1" -F '#{pane_current_command}' 2>/dev/null | head -n1
}

# fm_tmux_composer_escape_probe: LOCAL-ONLY, restored during the 2026-08-21 sync.
#
# Upstream deleted this from fm-tmux-lib.sh, having superseded the probe approach with
# backend-aware composer classification. But bin/fm-supervise-daemon.sh still carries the
# local max_defer_escape_recover() safety net that calls it - a bounded, idle-only recovery
# for the narrow case where the composer guard itself is stuck false-positive. That path was
# verified empirically on a disposable real Claude Code v2.1.224 pane: normal typed,
# unsubmitted text stayed pending and byte-for-byte visible after one Escape, so a remaining
# pending/unknown state is fail-closed and nothing is ever typed or clobbered.
#
# Restored rather than removed because deleting a verified safety net is the riskier
# direction, and this keeps it out of upstream files so future syncs do not conflict.
#
# KNOWN INCONSISTENCY FOR THE CAPTAIN: .agents/skills/afk/SKILL.md now carries UPSTREAM's
# text, which no longer documents this probe. Doc and code therefore disagree. Resolve it
# deliberately - either drop max_defer_escape_recover() and this shim to match upstream's
# design, or re-add a paragraph to the skill. Do not leave it silently split.
fm_tmux_composer_escape_probe() {  # <target> [settle-seconds] -> empty|pending|unknown
  local target=$1 settle=${2:-0.1} state
  state=$(fm_tmux_composer_state "$target")
  [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
  tmux send-keys -t "$target" Escape 2>/dev/null || { printf 'unknown'; return 0; }
  sleep "$settle"
  fm_tmux_composer_state "$target"
}
