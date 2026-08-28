#Requires -Version 5.1
<#
file-perf-issue.ps1  -  Phase 8 tail: if a run's real wall-clock exceeded the slow-run
threshold, file a GitHub issue in agentQ's OWN repo (never a product repo) with a
mechanical phase-by-phase breakdown and improvement suggestions.

Runs AFTER the report/evidence files are already written and NEVER blocks or delays
delivering them - every failure path here (gh missing, gh not authenticated, gh
issue create failing) degrades to a one-line reason in perf-issue.json and a single
extra chat line, never an error the developer has to deal with.

The threshold check is owned by THIS script, not the orchestrator: it always gets
called at the tail of Phase 8, and decides for itself whether the run was slow
enough to file - same "scripts decide mechanically" pattern as contract-check.ps1's
own gate logic.

The -ThresholdMinutes and -TargetRepo parameter defaults below are the single
source of truth for the threshold and destination - this is agentQ's own runtime
telemetry for the maintainer; docs reference these parameters, never literal
values. The parameters exist for tests (-DryRun) and maintainer overrides.

Uses the `gh` CLI - no MCP, no stored token; it borrows whatever `gh auth login`
already set up on this machine, same "never write a token value" rule as everywhere
else in this repo.

Output contract (scripts/CONTRACTS.md - perf-issue.json): the artifact at -OutPath is
written best-effort, and the one stdout line is compact JSON {checked, overThreshold,
filed, issueUrl, reason} - parse it, don't read it as prose. ALWAYS exits 0: this
script is telemetry, and no outcome of it (missing/unreadable inputs, gh missing,
not authenticated, repo not found, unexpected exception) may ever stop or fail the
run that called it - every such case becomes {checked:false or filed:false, reason}.

Usage:
  .\scripts\file-perf-issue.ps1 -TimeLedgerPath <workspaceDir>\time-ledger.json `
      -RunManifestPath <workspaceDir>\run-manifest.json -OutPath <workspaceDir>\perf-issue.json `
      [-RunKind qa-review] [-DryRun]   (threshold/repo: the -ThresholdMinutes/-TargetRepo defaults)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TimeLedgerPath,
    [Parameter(Mandatory)][string]$RunManifestPath,
    [Parameter(Mandatory)][string]$OutPath,
    [string]$TargetRepo = 'marianamelo1/agentQ',
    [double]$ThresholdMinutes = 20,
    [ValidateSet('qa-review', 'qa-impact')][string]$RunKind = 'qa-review',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Composed at runtime so this file stays pure ASCII (PS 5.1 reads BOM-less files as ANSI).
$EmDash = [char]0x2014

function Format-Duration {
    param([double]$Seconds)
    $total = [int][math]::Round($Seconds)
    $m = [int]([math]::Floor($total / 60))
    $s = $total - ($m * 60)
    if ($m -gt 0) { return "{0}m {1}s" -f $m, $s }
    return "{0}s" -f $s
}

function Get-Prop {
    param($Object, [string]$Name, $Default)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Write-Artifact {
    # Best-effort: an unwritable OutPath must not turn telemetry into a run failure.
    param([Parameter(Mandatory)]$Object)
    try {
        $dir = Split-Path $OutPath -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $json = $Object | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($OutPath, $json, [System.Text.UTF8Encoding]::new($false))
    } catch { }
}

function Complete-Run {
    # The single contractual stdout line, then ALWAYS exit 0: this script is
    # telemetry - no outcome of it (missing inputs, no gh, no auth, no repo,
    # unexpected exception) may ever stop or fail the run that called it.
    param([Parameter(Mandatory)]$Result)
    $line = [ordered]@{
        checked       = $Result.checked
        overThreshold = $Result.overThreshold
        filed         = $Result.filed
        issueUrl      = $Result.issueUrl
        reason        = $Result.reason
    }
    Write-Output ($line | ConvertTo-Json -Compress)
    exit 0
}

$thresholdSeconds = $ThresholdMinutes * 60
$result = [ordered]@{
    checked          = $false
    thresholdSeconds = $thresholdSeconds
    totalSeconds     = 0.0
    overThreshold    = $false
    filed            = $false
    issueUrl         = $null
    issueNumber      = $null
    reason           = $null
}

# Everything below runs inside this trap: ANY unexpected error degrades to a
# reason in the artifact/stdout line and exit 0 - never a thrown error the
# calling run could trip on.
trap {
    $result.reason = "unexpected error: $($_.Exception.Message)"
    Write-Artifact -Object $result
    Complete-Run -Result $result
}

if (-not (Test-Path -LiteralPath $TimeLedgerPath -PathType Leaf)) {
    $result.reason = "time-ledger not found: $TimeLedgerPath - nothing checked"
    Write-Artifact -Object $result
    Complete-Run -Result $result
}
if (-not (Test-Path -LiteralPath $RunManifestPath -PathType Leaf)) {
    $result.reason = "run-manifest.json not found: $RunManifestPath - nothing checked"
    Write-Artifact -Object $result
    Complete-Run -Result $result
}

$ledger = Get-Content -LiteralPath $TimeLedgerPath -Raw | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $RunManifestPath -Raw | ConvertFrom-Json
$result.checked = $true

$runStartedAt = Get-Prop $ledger 'runStartedAt' $null
$runEndedAt   = Get-Prop $ledger 'runEndedAt' $null
$totalSeconds = [double](Get-Prop $ledger 'totalSeconds' 0)
if ($runStartedAt -and $runEndedAt) {
    # Trust the two timestamps over a possibly-stale totalSeconds field - this is the
    # literal "first message to final answer" number, computed the same way every time.
    try {
        $derived = ([datetime]$runEndedAt - [datetime]$runStartedAt).TotalSeconds
        if ($derived -gt 0) { $totalSeconds = $derived }
    } catch { }
}

$result.totalSeconds = $totalSeconds
$result.overThreshold = $totalSeconds -gt $thresholdSeconds
$overThreshold = $result.overThreshold

if (-not $overThreshold) {
    $result.reason = 'under threshold - nothing filed'
    Write-Artifact -Object $result
    Complete-Run -Result $result
}

# -----------------------------------------------------------------------------
# Build the issue title + body mechanically from time-ledger.json's phases[]
# -----------------------------------------------------------------------------

$repoSlug   = [string](Get-Prop $manifest 'repoSlug' 'unknown-repo')
$repoShort  = ($repoSlug -split '/')[-1]
$branch     = [string](Get-Prop $manifest 'branch' 'unknown-branch')
$ticketKey  = [string](Get-Prop $manifest 'ticketKey' '')
$ticketOrBranch = if ($ticketKey) { $ticketKey } else { $branch }
$phases = @(Get-Prop $ledger 'phases' @())

$machinePhases = @($phases | Where-Object { [string](Get-Prop $_ 'name' '') -ne 'consent-wait' })
$waitPhases    = @($phases | Where-Object { [string](Get-Prop $_ 'name' '') -eq 'consent-wait' })
$machineSeconds = ($machinePhases | ForEach-Object { [double](Get-Prop $_ 'seconds' 0) } | Measure-Object -Sum).Sum
$waitSeconds    = ($waitPhases    | ForEach-Object { [double](Get-Prop $_ 'seconds' 0) } | Measure-Object -Sum).Sum

$title = "Slow $RunKind run: $repoShort $ticketOrBranch $EmDash $(Format-Duration $totalSeconds) (target ${ThresholdMinutes}m)"

$body = New-Object System.Collections.Generic.List[string]
$body.Add("Auto-filed by ``scripts/file-perf-issue.ps1`` (CLAUDE.md Phase 8) $EmDash a $RunKind run took longer than the ${ThresholdMinutes}-minute target.")
$body.Add('')
$body.Add('| Repo | Branch | Ticket | Real duration | Started | Ended |')
$body.Add('|---|---|---|---|---|---|')
$body.Add("| $repoSlug | ``$branch`` | $(if ($ticketKey) { $ticketKey } else { '-- none --' }) | $(Format-Duration $totalSeconds) | $runStartedAt | $runEndedAt |")
$body.Add('')
$body.Add('## Phase breakdown (sorted by seconds, slowest first)')
$body.Add('')
$body.Add('| Phase | Actor | Seconds | Outcome |')
$body.Add('|---|---|---|---|')
foreach ($p in ($phases | Sort-Object { -[double](Get-Prop $_ 'seconds' 0) })) {
    $name = [string](Get-Prop $p 'name' '')
    $actor = [string](Get-Prop $p 'actor' '')
    $secs = [double](Get-Prop $p 'seconds' 0)
    $outcome = [string](Get-Prop $p 'outcome' 'RAN') -replace '\|', '/'
    $body.Add("| $name | $actor | $([math]::Round($secs, 1)) | $outcome |")
}
$body.Add('')
$machinePct = if ($totalSeconds -gt 0) { [math]::Round(($machineSeconds / $totalSeconds) * 100) } else { 0 }
$waitPct = if ($totalSeconds -gt 0) { [math]::Round(($waitSeconds / $totalSeconds) * 100) } else { 0 }
$body.Add("**Machine time:** $(Format-Duration $machineSeconds) ($machinePct%) $EmDash **Developer answer-latency (consent-wait):** $(Format-Duration $waitSeconds) ($waitPct%)")
$body.Add('')

$body.Add('## What likely drove the overrun')
$body.Add('')
$causes = New-Object System.Collections.Generic.List[string]
foreach ($p in $machinePhases) {
    $stall = Get-Prop $p 'stall' $null
    if ($null -ne $stall -and [bool](Get-Prop $stall 'watchdogFired' $false)) {
        $name = [string](Get-Prop $p 'name' '')
        $retried = [bool](Get-Prop $stall 'retried' $false)
        $retrySucceeded = [bool](Get-Prop $stall 'retrySucceeded' $false)
        $detail = if ($retried -and $retrySucceeded) { 'watchdog fired, retried, succeeded on retry' }
                  elseif ($retried) { 'watchdog fired, retried, still failed' }
                  else { 'watchdog fired, not retried (run-budget exhausted)' }
        $causes.Add("- **$name** stalled $EmDash $detail (see ``workspace/watchdog-state.json`` history for this run).")
    }
}
if ($machinePhases.Count -gt 0) {
    $dominant = $machinePhases | Sort-Object { -[double](Get-Prop $_ 'seconds' 0) } | Select-Object -First 1
    $dominantSecs = [double](Get-Prop $dominant 'seconds' 0)
    $dominantPct = if ($totalSeconds -gt 0) { [math]::Round(($dominantSecs / $totalSeconds) * 100) } else { 0 }
    if ($dominantPct -ge 30) {
        $causes.Add("- **$([string](Get-Prop $dominant 'name' ''))** alone was $dominantPct% of total wall-clock ($(Format-Duration $dominantSecs)).")
    }
}
if ($waitPct -ge 30) {
    $causes.Add("- $waitPct% of the run was spent waiting on the developer's consent answers, not on agentQ itself.")
}
if ($causes.Count -eq 0) {
    $causes.Add('- No single phase or stall dominates; the overrun looks like broad, evenly-spread slowness rather than one bottleneck.')
}
$causes | ForEach-Object { $body.Add($_) }
$body.Add('')

$body.Add('## Suggested improvements')
$body.Add('')
$suggestions = New-Object System.Collections.Generic.List[string]
foreach ($p in $machinePhases) {
    $stall = Get-Prop $p 'stall' $null
    if ($null -ne $stall -and [bool](Get-Prop $stall 'watchdogFired' $false)) {
        $suggestions.Add("- Investigate why **$([string](Get-Prop $p 'name' ''))**'s dispatch stalled $EmDash check the transcript around $([string](Get-Prop $p 'startedAt' '?')) for a session-level stream stall (GH issue #36 pattern).")
    }
}
if ($machinePhases.Count -gt 0) {
    $dominant = $machinePhases | Sort-Object { -[double](Get-Prop $_ 'seconds' 0) } | Select-Object -First 1
    $dominantSecs = [double](Get-Prop $dominant 'seconds' 0)
    $dominantPct = if ($totalSeconds -gt 0) { [math]::Round(($dominantSecs / $totalSeconds) * 100) } else { 0 }
    if ($dominantPct -ge 30) {
        $suggestions.Add("- Look at scoping down or caching **$([string](Get-Prop $dominant 'name' ''))** ($dominantPct% of total) $EmDash check ``calibration.json`` for whether this was a cold first run on this repo.")
    }
}
if ($waitPct -ge 30) {
    $suggestions.Add("- Most of the overrun was developer think-time, not code $EmDash no code action indicated. Consider whether the combined consent message (CLAUDE.md Phase 1) surfaces calibrated estimates clearly enough to speed up the decision.")
}
$suggestions.Add("- Full phase-by-phase evidence: ``workspace/$(($repoSlug -replace '/', '__'))/*/time-ledger.json`` and this run's ``-evidence.md`` Run timeline section.")
$suggestions | ForEach-Object { $body.Add($_) }

$bodyText = ($body -join "`n")

# -----------------------------------------------------------------------------
# File it via `gh` - borrows the developer's own `gh auth login`, never a stored token.
# -----------------------------------------------------------------------------

if ($DryRun) {
    $result.reason = 'dry run - not filed'
    # $result is an [ordered] hashtable, not a PSCustomObject - index-assign new keys
    # directly rather than Add-Member (inconsistent across PS versions on Hashtable/OrderedDictionary).
    $result['dryRunTitle'] = $title
    $result['dryRunBody'] = $bodyText
    Write-Artifact -Object $result
    Complete-Run -Result $result
}

$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCmd) {
    $result.reason = 'gh CLI not found on this machine'
    Write-Artifact -Object $result
    Complete-Run -Result $result
}

$null = & gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    $result.reason = 'gh not authenticated (run: gh auth login)'
    Write-Artifact -Object $result
    Complete-Run -Result $result
}

$tmpBody = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($tmpBody, $bodyText, [System.Text.UTF8Encoding]::new($false))
    $createOutput = & gh issue create --repo $TargetRepo --title $title --body-file $tmpBody 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errText = ($createOutput -join ' ')
        if ($errText.Length -gt 300) { $errText = $errText.Substring(0, 300) + '...' }
        $result.reason = "gh issue create failed: $errText"
        Write-Artifact -Object $result
        Complete-Run -Result $result
    }
    $issueUrl = ($createOutput | Select-Object -Last 1).ToString().Trim()
    $result.filed = $true
    $result.issueUrl = $issueUrl
    if ($issueUrl -match '/issues/(?<num>\d+)\s*$') {
        $result.issueNumber = [int]$Matches['num']
    }
} finally {
    if (Test-Path -LiteralPath $tmpBody) { Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue }
}

Write-Artifact -Object $result
Complete-Run -Result $result
