#Requires -Version 5.1
<#
watchdog-state.ps1  -  durable record of in-flight agent-dispatch watchdog timers
(SKILL.md's Background-agent & background-job watchdog section), so a stalled
dispatch is catchable even if the orchestrator never issued (or lost track of)
its paired background sleep/Start-Sleep timer for that dispatch.

WHY this exists: the watchdog described in SKILL.md is enforced entirely by the
orchestrator LLM remembering, in the SAME tool-call batch as every single Agent
dispatch, to also start a paired background timer -- nothing previously checked
whether that actually happened. Verified live (2026-08-26): a qa-intake dispatch
ran ~10 minutes (over 3x its 3-min ceiling) with none of the documented
nudge/re-dispatch/degrade behavior visible, consistent with the paired timer
call being narrated ("watchdog set at 3 min") but never actually issued. This
script makes the deadline a fact on disk instead of something held only in the
orchestrator's in-context memory for one turn -- ANY later re-invocation, for
ANY reason (the timer firing, the agent finishing, an unrelated notification),
can cheaply ask "is anything overdue?" and catch a stall even when its own
timer's own notification was skipped or lost.

Modes (exactly one switch per invocation):
  -Arm          -Manifest <path> -Label <key> -CeilingSeconds <n> [-Agent <name>]
                                                     Record/replace one in-flight
                                                     dispatch's deadline.
  -Clear        -Manifest <path> -Label <key>       Remove one entry (call on
                                                     normal completion or give-up).
  -CheckOverdue -Manifest <path>                    Read-only; no side effects.
                                                     Prints ONE line of compact
                                                     JSON (like -DetectRepo in
                                                     worktree.ps1) listing every
                                                     entry whose deadline has
                                                     passed.

-Label is the dispatch's own key (falls back to -Agent when omitted) -- pass an
explicit -Label when the SAME agent is dispatched more than once in a run (e.g.
qa-mutation-author's design dispatch vs its later suggestedFix dispatch), so the
two don't collide in the state file.

Storage: <workspaceDir>/watchdog-state.json -- workspace-fenced, never the
product repo. Contract: exit 0 = the script ran; non-zero = the script itself
failed. -Arm/-Clear print one prose summary line; -CheckOverdue's one line IS
its JSON payload (CONTRACTS.md).
#>
[CmdletBinding()]
param(
    [switch]$Arm,
    [switch]$Clear,
    [switch]$CheckOverdue,

    [Parameter(Mandatory = $true)][string]$Manifest,
    [string]$Label = '',
    [string]$Agent = '',
    [int]$CeilingSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See pathext-guard.ps1: harmless here (this script never resolves an external
# executable by name), kept for consistency with every other script in scripts/.
. (Join-Path $PSScriptRoot 'pathext-guard.ps1')

function Write-JsonFile {
    # Same UTF-8-no-BOM contract as every other script (CONTRACTS.md).
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $json = $Object | ConvertTo-Json -Depth 12
    $enc  = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $enc)
}

function Get-WorkspaceDir {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Manifest not found: $Path (run worktree.ps1 -EnsureWorkspace first)"
    }
    $m = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not ($m.PSObject.Properties.Name -contains 'workspaceDir')) {
        throw "Manifest missing required field 'workspaceDir': $Path"
    }
    return $m.workspaceDir
}

function Read-State {
    # A corrupt/half-written state file is never trusted -- start clean rather
    # than crash a run over a bookkeeping artifact (same discipline as
    # adapter-cache.ps1's "never trust a husk" rule).
    param([Parameter(Mandatory = $true)][string]$StatePath)
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return [ordered]@{ entries = @() }
    }
    try {
        $raw = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $entries = @()
        if ($raw.PSObject.Properties.Name -contains 'entries') { $entries = @($raw.entries) }
        return [ordered]@{ entries = $entries }
    }
    catch {
        return [ordered]@{ entries = @() }
    }
}

$modeCount = @(@($Arm, $Clear, $CheckOverdue) | Where-Object { $_ }).Count
if ($modeCount -ne 1) { throw 'Specify exactly one of -Arm, -Clear, -CheckOverdue' }

$workspaceDir = Get-WorkspaceDir -Path $Manifest
if (-not (Test-Path -LiteralPath $workspaceDir)) {
    New-Item -ItemType Directory -Force -Path $workspaceDir | Out-Null
}
$statePath = Join-Path $workspaceDir 'watchdog-state.json'

if ($Arm) {
    $key = $Label
    if ([string]::IsNullOrWhiteSpace($key)) { $key = $Agent }
    if ([string]::IsNullOrWhiteSpace($key)) { throw '-Arm requires -Label or -Agent' }
    if ($CeilingSeconds -le 0) { throw '-Arm requires -CeilingSeconds > 0' }

    $state = Read-State -StatePath $statePath
    $now = (Get-Date).ToUniversalTime()
    $deadline = $now.AddSeconds($CeilingSeconds)
    $remaining = New-Object System.Collections.Generic.List[object]
    foreach ($e in $state.entries) { if ($e.label -ne $key) { $remaining.Add($e) } }
    $remaining.Add([ordered]@{
        label          = $key
        agent          = $Agent
        dispatchedAt   = $now.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        ceilingSeconds = $CeilingSeconds
        deadlineAt     = $deadline.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    })
    Write-JsonFile -Object ([ordered]@{ entries = $remaining }) -Path $statePath
    Write-Output "Armed: '$key' ceiling ${CeilingSeconds}s, deadline $($deadline.ToString('HH:mm:ss'))Z -> $statePath"
}
elseif ($Clear) {
    $key = $Label
    if ([string]::IsNullOrWhiteSpace($key)) { $key = $Agent }
    if ([string]::IsNullOrWhiteSpace($key)) { throw '-Clear requires -Label or -Agent' }

    $state = Read-State -StatePath $statePath
    $remaining = New-Object System.Collections.Generic.List[object]
    $removed = 0
    foreach ($e in $state.entries) {
        if ($e.label -eq $key) { $removed++ } else { $remaining.Add($e) }
    }
    Write-JsonFile -Object ([ordered]@{ entries = $remaining }) -Path $statePath
    $plural = 'ies'; if ($removed -eq 1) { $plural = 'y' }
    Write-Output "Cleared: '$key' ($removed entr$plural removed) -> $statePath"
}
else {
    $state = Read-State -StatePath $statePath
    $now = (Get-Date).ToUniversalTime()
    $overdue = New-Object System.Collections.Generic.List[object]
    foreach ($e in $state.entries) {
        $deadline = [DateTime]::Parse($e.deadlineAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if ($deadline -lt $now) {
            $overdueSeconds = [Math]::Round(($now - $deadline).TotalSeconds, 1)
            $overdue.Add([ordered]@{
                label            = $e.label
                agent            = $e.agent
                dispatchedAt     = $e.dispatchedAt
                ceilingSeconds   = $e.ceilingSeconds
                deadlineAt       = $e.deadlineAt
                overdueBySeconds = $overdueSeconds
            })
        }
    }
    $result = [ordered]@{ overdue = $overdue }
    Write-Output ($result | ConvertTo-Json -Depth 6 -Compress)
}
