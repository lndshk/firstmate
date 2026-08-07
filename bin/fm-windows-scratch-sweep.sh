#!/usr/bin/env bash
# Safely reclaim stale Windows scratch directories from WSL-firstmate hosts.
#
# Usage: fm-windows-scratch-sweep.sh [PowerShell sweep arguments]
#
# This is a no-op on hosts without Windows PowerShell.  The PowerShell worker
# owns the fixed production scope, age policy, and fail-closed live-process
# check; keep this wrapper deliberately small so it cannot bypass those guards.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="$SCRIPT_DIR/fm-windows-scratch-sweep.ps1"

command -v powershell.exe >/dev/null 2>&1 || exit 0
[ -f "$WORKER" ] || {
  echo "error: missing Windows scratch sweep worker: $WORKER" >&2
  exit 1
}

exec powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$WORKER" "$@"
