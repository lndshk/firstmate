#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh         print own harness: claude|codex|opencode|pi|unknown
#        fm-harness.sh crew    print the effective crewmate harness
#                              (config/crew-harness; "default" resolves to own)
#        fm-harness.sh agent-in-tree <root-pid>
#                             succeed when that process tree has a live agent
# Detection layers: verified environment markers first, then process ancestry.
# Record each newly verified env marker here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# Recognizes exactly the four VERIFIED harnesses (section 4: "never dispatch a
# crewmate on an unverified adapter"). A process tree matching none of these is
# treated as agent-dead by agent_in_tree/fm_pane_agent_state - intentionally:
# under that policy every real crewmate runs one of these four, so a tree with
# none of them means either the agent genuinely exited or the pane is running
# something firstmate never dispatched. The one deliberate exception is the
# raw-launch-command escape hatch used only to verify a brand-new adapter
# (section 4), where firstmate is already peeking the pane directly and a
# transient false-dead reading there is low-risk, unlike a long-lived trusted
# pane silently misreporting healthy.
harness_for_process() { # <comm> <args>
  local comm=${1##*/} args=${2:-}
  case "$comm" in
    *claude*) echo claude; return 0 ;;
    *codex*) echo codex; return 0 ;;
    *opencode*) echo opencode; return 0 ;;
    pi) echo pi; return 0 ;;
    node*|python*)
      case "$args" in
        *claude*) echo claude; return 0 ;;
        *codex*) echo codex; return 0 ;;
        *opencode*) echo opencode; return 0 ;;
        *" pi "*|*/pi) echo pi; return 0 ;;
      esac
      ;;
  esac
  return 1
}

detect_own() {
  # Layer 1: environment markers for verified harnesses.
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  [ "${PI_CODING_AGENT:-}" = "true" ] && { echo pi; return; }
  # Layer 2: walk the parent chain and match the command name.
  local pid=$$ comm args harness
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null || true)
    harness=$(harness_for_process "$comm" "$args" || true)
    [ -z "$harness" ] || { echo "$harness"; return; }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
      break
    fi
  done
  echo unknown
}

agent_in_tree() { # <root-pid>
  local root=${1:-} snapshot tree changed pid ppid stat comm args
  case "$root" in ''|*[!0-9]*) return 2 ;; esac
  snapshot=$(ps -axww -o pid=,ppid=,stat=,comm=,args= 2>/dev/null) || return 2
  tree=" $root "

  changed=1
  while [ "$changed" = 1 ]; do
    changed=0
    while read -r pid ppid stat comm args; do
      case "$pid:$ppid" in *[!0-9:]*|:) continue ;; esac
      case "$tree" in *" $ppid "*) ;; *) continue ;; esac
      case "$tree" in
        *" $pid "*) ;;
        *) tree="$tree$pid "; changed=1 ;;
      esac
    done <<EOF
$snapshot
EOF
  done

  while read -r pid ppid stat comm args; do
    case "$tree" in *" $pid "*) ;; *) continue ;; esac
    case "$stat" in *Z*) continue ;; esac
    harness_for_process "$comm" "$args" >/dev/null 2>&1 && return 0
  done <<EOF
$snapshot
EOF
  return 1
}

case "${1:-}" in
  crew)
    crew=
    [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
    if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
    ;;
  agent-in-tree)
    agent_in_tree "${2:-}"
    ;;
  *)
    detect_own
    ;;
esac
