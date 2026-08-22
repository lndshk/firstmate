#!/usr/bin/env bash
# Exercises the real Windows process-reference guard with a held-open file.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER="$ROOT/bin/fm-windows-scratch-sweep.ps1"
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  [ -z "${TMP_ROOT:-}" ] || rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

command -v powershell.exe >/dev/null 2>&1 || {
  printf 'ok - Windows scratch sweep skipped (powershell.exe unavailable)\n'
  exit 0
}
command -v wslpath >/dev/null 2>&1 || fail "wslpath is required when powershell.exe is available"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-windows-scratch-tests.XXXXXX") || exit 1
WIN_ROOT=$(wslpath -w "$TMP_ROOT") || fail "could not translate temporary test path"
PS_TEST="$TMP_ROOT/test-sweep.ps1"

printf '%s\n' '
param([string] $Worker, [string] $Root)
$ErrorActionPreference = "Stop"
$stale = Join-Path $Root "bridge-stale"
$live = Join-Path $Root "bridge-live"
New-Item -ItemType Directory -Path $stale, $live -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $stale "scratch.txt"), "stale")
$liveFile = Join-Path $live "held-open.txt"
[IO.File]::WriteAllText($liveFile, "live")
$old = (Get-Date).AddDays(-10)
[IO.Directory]::SetLastWriteTime($stale, $old)
[IO.Directory]::SetLastWriteTime($live, $old)
$holder = Join-Path $Root "hold-open.ps1"
[IO.File]::WriteAllText($holder, "param([string] `$Path) `$stream = [IO.File]::Open(`$Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read); Start-Sleep -Seconds 45; `$stream.Dispose()")
$process = Start-Process -FilePath powershell.exe -ArgumentList @("-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $holder, $liveFile) -PassThru
try {
  Start-Sleep -Milliseconds 750
  $dry = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Worker -Root $Root -Pattern "bridge-*" -MinAgeDays 0 -DryRun 2>&1
  if ($LASTEXITCODE -ne 0) { throw "dry run failed: $dry" }
  if (-not ($dry -match [regex]::Escape("DRY-RUN delete $stale"))) { throw "dry run did not identify stale directory: $dry" }
  if (-not ($dry -match [regex]::Escape("SKIP live-process") + ".*" + [regex]::Escape($live))) { throw "dry run did not protect live directory: $dry" }
  $real = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Worker -Root $Root -Pattern "bridge-*" -MinAgeDays 0 2>&1
  if ($LASTEXITCODE -ne 0) { throw "real run failed: $real" }
  if (Test-Path -LiteralPath $stale) { throw "real run did not remove stale directory: $real" }
  if (-not (Test-Path -LiteralPath $live)) { throw "real run removed directory referenced by live process: $real" }
}
finally {
  if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
  $process.WaitForExit()
}
' > "$PS_TEST"

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(wslpath -w "$PS_TEST")" \
  -Worker "$(wslpath -w "$WORKER")" -Root "$WIN_ROOT" \
  || fail "Windows scratch sweep process-reference guard failed"
pass "Windows scratch sweep skips a directory referenced by a live process"
