<#
.SYNOPSIS
Reclaims stale, firstmate-related Windows scratch directories without touching
anything referenced by a live Windows process.

.DESCRIPTION
The default scope is deliberately narrow: bridge build/test directories below
C:\temp and chrome-devtools-axi Chromium profiles below C:\tmp.  It never
removes either root itself, follows no reparse point, and only considers direct
children older than MinAgeDays.

Before each removal it obtains a fresh Win32_Process snapshot and skips the
candidate if its full path appears in any live process's ExecutablePath or
CommandLine.  Failure to enumerate that process data is fatal and leaves the
candidate alone.  A second, just-before-removal snapshot reduces the interval
between evidence and deletion; the Windows process table has no atomic
"delete if unreferenced" primitive, so the conservative scan is intentionally
repeated rather than cached.

.PARAMETER Root
An optional scratch root for a controlled test run.  Production runs use the
two fixed roots above.  Use Pattern with Root; arbitrary roots are never used
by firstmate's scheduled invocation.
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 3650)]
    [int] $MinAgeDays = 7,
    [switch] $DryRun,
    [string[]] $Root,
    [string] $Pattern = 'bridge-*'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LiveProcesses {
    try {
        @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, Name, ExecutablePath, CommandLine)
    }
    catch {
        throw "refusing cleanup because Win32_Process could not be enumerated: $($_.Exception.Message)"
    }
}

function Test-ReferencedByLiveProcess {
    param(
        [Parameter(Mandatory = $true)] [string] $Candidate,
        [Parameter(Mandatory = $true)] [object[]] $Processes
    )

    foreach ($process in $Processes) {
        foreach ($value in @($process.ExecutablePath, $process.CommandLine)) {
            if ($null -ne $value -and $value.IndexOf($Candidate, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $process
            }
        }
    }
    return $null
}

if ($Root) {
    $targets = foreach ($customRoot in $Root) {
        [pscustomobject]@{ Root = $customRoot; Pattern = $Pattern }
    }
}
else {
    # Known creators only.  Do not make C:\temp or C:\tmp a generic janitor:
    # they may also contain unrelated user or system-owned content.
    $targets = @(
        [pscustomobject]@{ Root = 'C:\temp'; Pattern = 'bridge-*' },
        [pscustomobject]@{ Root = 'C:\tmp'; Pattern = 'puppeteer_dev_chrome_profile-*' }
    )
}

$cutoff = (Get-Date).AddDays(-$MinAgeDays)
$considered = 0
$deleted = 0
$skippedLive = 0
$skippedYoung = 0
$skippedReparse = 0

foreach ($target in $targets) {
    if (-not (Test-Path -LiteralPath $target.Root -PathType Container)) {
        Write-Output "SKIP missing-root $($target.Root)"
        continue
    }

    $children = @(Get-ChildItem -LiteralPath $target.Root -Directory -Force |
        Where-Object { $_.Name -like $target.Pattern })
    foreach ($child in $children) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $skippedReparse++
            Write-Output "SKIP reparse-point $($child.FullName)"
            continue
        }
        if ($child.LastWriteTime -gt $cutoff) {
            $skippedYoung++
            continue
        }

        $considered++
        # Fetch immediately before the decision, rather than accepting a stale
        # global process snapshot for a long cleanup run.
        $owner = Test-ReferencedByLiveProcess -Candidate $child.FullName -Processes (Get-LiveProcesses)
        if ($null -ne $owner) {
            $skippedLive++
            Write-Output "SKIP live-process pid=$($owner.ProcessId) name=$($owner.Name) $($child.FullName)"
            continue
        }

        if ($DryRun) {
            Write-Output "DRY-RUN delete $($child.FullName)"
            continue
        }

        # Re-check after the dry-run branch and directly before the destructive
        # call so each deletion has its own current Win32_Process evidence.
        $owner = Test-ReferencedByLiveProcess -Candidate $child.FullName -Processes (Get-LiveProcesses)
        if ($null -ne $owner) {
            $skippedLive++
            Write-Output "SKIP live-process pid=$($owner.ProcessId) name=$($owner.Name) $($child.FullName)"
            continue
        }

        Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
        $deleted++
        Write-Output "DELETE $($child.FullName)"
    }
}

Write-Output "SUMMARY considered=$considered deleted=$deleted skipped-live=$skippedLive skipped-young=$skippedYoung skipped-reparse=$skippedReparse min-age-days=$MinAgeDays dry-run=$($DryRun.IsPresent)"
