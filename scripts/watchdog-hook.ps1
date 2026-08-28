#Requires -Version 5.1
<#
watchdog-hook.ps1  -  enforces the qa-review watchdog procedure (CLAUDE.md /
SKILL.md "Background-agent & background-job watchdog") via two Claude Code
hooks instead of orchestrator prose alone.

GH issue #36: the pre-existing procedure worked ONLY if the orchestrating LLM
remembered, on some later turn, to (a) poll a deadline it had written to disk
and (b) sanity-check a subagent's final message before accepting it. Verified
live: an overdue dispatch sat uncleared for ~13-17 minutes past its 3-minute
ceiling with zero nudge/re-dispatch/degrade, because nothing forced a check.
This script is what a `Stop` hook and a `SubagentStop` hook (registered in
`.claude/skills/qa-review/SKILL.md` frontmatter) call on every turn-end, so
the check happens deterministically instead of depending on memory.

Modes (exactly one per invocation):
  -Arm      -Label <l> -Agent <a> -CeilingSeconds <n> [-TimerTaskId <id>]
            [-StatePath <p>]
                                    Upsert an entry (fresh dispatchedAt = now,
                                    deadlineAt = now + CeilingSeconds). Run in
                                    the SAME tool-call batch as a dispatch.
                                    -TimerTaskId records the paired background
                                    timer's own task id (from the Bash/
                                    PowerShell run_in_background result) so
                                    -Clear can hand it back later (GH issue
                                    #52 - see below).
  -Extend   -Label <l> -AdditionalSeconds <n> [-TimerTaskId <id>]
            [-StatePath <p>]
                                    Push an existing entry's deadlineAt out by
                                    N seconds (dispatchedAt untouched). No-op
                                    (warns to stderr, exits 0) if the label
                                    isn't armed - a bookkeeping mismatch here
                                    must never fail the orchestrator's turn.
                                    -TimerTaskId replaces the stored timer
                                    task id with the NEW extension timer's id
                                    (the original timer already fired - that's
                                    why this is an -Extend call at all).
  -Clear    -Label <l> [-StatePath <p>]
                                    Remove one entry (resolved, given up on,
                                    or about to be replaced by a fresh -Arm).
                                    No-op if the label isn't armed. If the
                                    entry carried a -TimerTaskId, it is printed
                                    back on stdout as an explicit instruction -
                                    the caller MUST TaskStop that id in this
                                    same turn (GH issue #52: clearing the state
                                    entry alone leaves the paired background
                                    timer running until it fires its own
                                    now-useless notification).
  -ClearAll [-StatePath <p>]       Reset to an empty ledger (Phase 0 preflight
                                    on a fresh run; Phase 9 cleanup).
  -List     [-StatePath <p>]       Print the current ledger as JSON (debugging).
  -Stop                            Claude Code `Stop` hook. Reads the hook's
                                    stdin JSON (or -StdinPath, for testing).
                                    Any entry past its deadline -> exit 2,
                                    reason on stderr (Stop hooks can't refuse
                                    via JSON output; exit 2 is the only lever -
                                    see code.claude.com/docs/en/hooks "Stop
                                    decision control"). An entry overdue by
                                    10+ minutes is treated as abandoned (a
                                    leftover from a crashed prior run, not a
                                    live stall in THIS session): it is cleared
                                    automatically as part of the SAME block,
                                    so the fix doesn't itself depend on a later
                                    turn remembering to clean it up.
  -SubagentStop                    Claude Code `SubagentStop` hook. Only acts
                                    on the four watched agent types (qa-intake,
                                    qa-analyst, qa-scenario-writer,
                                    qa-mutation-author) - qa-e2e-author and
                                    anything else pass through untouched, since
                                    it fires for every subagent for the rest of
                                    the session once the skill is invoked, not
                                    just qa-review dispatches. Blocks (exit 2)
                                    when the subagent's own last_assistant_message
                                    reads as a stall placeholder ("I'll wait
                                    for...", "still working on...", or simply
                                    too short to be a real result) rather than
                                    a completed/blocked status - this is the
                                    false-completion pattern from GH issue #32,
                                    caught here instead of by a manual nudge.

State file: <repo root>/workspace/watchdog-state.json (workspace/ is already
gitignored run-output space - never the product repo, never committed). A
single file scoped to this session: the Stop/SubagentStop hooks are only
registered for the rest of THIS session once /qa-review is invoked (skill
frontmatter scoping - see code.claude.com/docs/en/hooks "Hooks in skills and
agents"), so a stale entry can only be seen again by a session that actually
armed it, never by an unrelated future session.

Contract: -Arm/-Extend/-Clear/-ClearAll/-List always exit 0 (bookkeeping must
never fail the orchestrator's turn) and print one prose summary line (-Clear/
-ClearAll print a second line per still-live paired timer - see GH issue #52
below). -Stop/-SubagentStop exit 0 (no block) or 2 (block, reason on stderr) -
see above.

GH issue #52: -Clear/-ClearAll only ever removed the JSON entry: the paired
background timer started alongside it (SKILL.md step 1) kept running
regardless, so a dispatch that finished on time still produced a second, useless
"background command completed" notification once its timer separately expired -
observed live on every one of 7 dispatches in a full run. -Arm/-Extend now
accept -TimerTaskId to record that timer's own task id in the state file, and
-Clear/-ClearAll echo it straight back on stdout as an explicit "TaskStop this
now" instruction, so stopping the timer is a mechanical read of this script's
output rather than something the orchestrator has to remember across turns.
#>
[CmdletBinding()]
param(
    [switch]$Arm,
    [switch]$Extend,
    [switch]$Clear,
    [switch]$ClearAll,
    [switch]$List,
    [switch]$Stop,
    [switch]$SubagentStop,

    [string]$Label,
    [string]$Agent,
    [int]$CeilingSeconds,
    [int]$AdditionalSeconds,
    [string]$TimerTaskId, # -Arm/-Extend only: the paired background timer's task id (GH issue #52)

    [string]$StatePath,   # override for testing; default resolved below
    [string]$StdinPath    # -Stop/-SubagentStop testing: read this file instead of Console.In
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No $IsWindows branching needed in this script: every OS-sensitive operation
# (Join-Path, [DateTimeOffset], UTF8Encoding, ConvertTo/From-Json) already
# behaves identically on Windows PowerShell 5.1 and pwsh 7 - verified live
# against both during development.

$modeCount = @($Arm, $Extend, $Clear, $ClearAll, $List, $Stop, $SubagentStop) | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count
if ($modeCount -ne 1) {
    throw 'Specify exactly one mode: -Arm, -Extend, -Clear, -ClearAll, -List, -Stop, or -SubagentStop.'
}

# Resolved once, relative to this script's own location - never dependent on
# the caller's cwd or on an env var that may not reach a hook subprocess.
if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $workspaceDir = Join-Path $repoRoot 'workspace'
    if (-not (Test-Path -LiteralPath $workspaceDir)) {
        New-Item -ItemType Directory -Path $workspaceDir -Force | Out-Null
    }
    $StatePath = Join-Path $workspaceDir 'watchdog-state.json'
}

$ABANDONED_THRESHOLD_SECONDS = 600  # 10 min - see module header

function Write-StateFile {
    # WHY .NET WriteAllText instead of Out-File: CONTRACTS.md mandates UTF-8
    # *without* BOM; PS 5.1's `Out-File -Encoding utf8` always emits a BOM.
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Entries)
    $json = ConvertTo-Json -InputObject @($Entries) -Depth 6
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($StatePath, $json, $enc)
}

function Read-StateFile {
    # WHY the comma-wrap on every return path (not just the data path): a bare
    # `return @()` unrolls to ZERO pipeline items, so `$x = Read-StateFile`
    # leaves $x as $null, not an empty array - see Run-Git's identical
    # `return ,@()` pattern in worktree.ps1. CALLERS must settle this
    # function's result into a plain variable (`$entries = Read-StateFile`)
    # before doing anything else with it - wrapping the LIVE CALL itself in
    # `@(...)` (e.g. `@(Read-StateFile)`) corrupts ConvertTo-Json's output on
    # this PS 5.1 build into `{"value":[...],"Count":N}` instead of a flat
    # array (same documented gotcha as worktree.ps1's Get-DevUntrackedFiles,
    # see its callers' comments).
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return ,@() }
    $raw = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return ,@() }
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) { return ,@() }
    return ,@($parsed)
}

# WHY epoch seconds are the field actually used for arithmetic, with the
# ISO8601 strings kept only for a human glancing at the state file: verified
# live that PowerShell 7's `ConvertFrom-Json` auto-detects ISO8601-looking
# strings and silently deserializes them as [DateTime] (Windows PowerShell
# 5.1 does not), which then loses its 'Z'/UTC marker the moment anything
# touches it as a string again - re-parsing that with [DateTimeOffset]::Parse
# reinterprets it as LOCAL time and corrupts every deadline by the machine's
# UTC offset. A plain integer can't be date-coerced, so it round-trips
# identically on both PowerShell versions (confirmed live on 5.1 and 7.6.5).
function Get-NowEpoch {
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function ConvertTo-Iso8601FromEpoch {
    param([Parameter(Mandatory = $true)][int64]$EpochSeconds)
    return ([DateTimeOffset]::FromUnixTimeSeconds($EpochSeconds)).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Read-HookStdin {
    if (-not [string]::IsNullOrWhiteSpace($StdinPath)) {
        return (Get-Content -LiteralPath $StdinPath -Raw -Encoding UTF8)
    }
    return [Console]::In.ReadToEnd()
}

# --- bookkeeping modes: -Arm / -Extend / -Clear / -ClearAll / -List -------------

if ($Arm) {
    if ([string]::IsNullOrWhiteSpace($Label) -or [string]::IsNullOrWhiteSpace($Agent) -or $CeilingSeconds -le 0) {
        throw '-Arm requires -Label <l> -Agent <a> -CeilingSeconds <n (>0)>'
    }
    $allEntries = Read-StateFile
    $entries = @($allEntries | Where-Object { $_.label -ne $Label })
    $nowEpoch = Get-NowEpoch
    $deadlineEpoch = $nowEpoch + $CeilingSeconds
    $entry = [ordered]@{
        label             = $Label
        agent             = $Agent
        dispatchedAt      = ConvertTo-Iso8601FromEpoch $nowEpoch       # display only, never re-parsed
        dispatchedAtEpoch = $nowEpoch
        ceilingSeconds    = $CeilingSeconds
        deadlineAt        = ConvertTo-Iso8601FromEpoch $deadlineEpoch  # display only, never re-parsed
        deadlineAtEpoch   = $deadlineEpoch
        timerTaskId       = $(if ([string]::IsNullOrWhiteSpace($TimerTaskId)) { $null } else { $TimerTaskId })
    }
    Write-StateFile -Entries ($entries + [pscustomobject]$entry)
    Write-Output "Armed '$Label' ($Agent): ceiling ${CeilingSeconds}s, deadline $($entry.deadlineAt)"
    exit 0
}

if ($Extend) {
    if ([string]::IsNullOrWhiteSpace($Label) -or $AdditionalSeconds -le 0) {
        throw '-Extend requires -Label <l> -AdditionalSeconds <n (>0)>'
    }
    $entries = Read-StateFile
    $match = $entries | Where-Object { $_.label -eq $Label } | Select-Object -First 1
    if ($null -eq $match) {
        Write-Warning "Watchdog: -Extend found no armed entry for '$Label' - nothing to extend."
        exit 0
    }
    $newDeadlineEpoch = [int64]$match.deadlineAtEpoch + $AdditionalSeconds
    $match.deadlineAtEpoch = $newDeadlineEpoch
    $match.deadlineAt = ConvertTo-Iso8601FromEpoch $newDeadlineEpoch
    # The original timer already fired (that's why this is an -Extend call at
    # all) - a fresh extension timer was started alongside it, so its task id
    # replaces the stale one. Omitting -TimerTaskId leaves the old (already-
    # fired, harmless) id in place rather than guessing.
    if (-not [string]::IsNullOrWhiteSpace($TimerTaskId)) {
        $match.timerTaskId = $TimerTaskId
    }
    Write-StateFile -Entries $entries
    Write-Output "Extended '$Label' by ${AdditionalSeconds}s: new deadline $($match.deadlineAt)"
    exit 0
}

function Get-TimerTaskId {
    # $entries comes from ConvertFrom-Json - an entry armed before this fix (or
    # armed with no -TimerTaskId) may simply lack the property, so check via
    # PSObject rather than a bare property read (Set-StrictMode throws on the
    # latter for a missing NoteProperty).
    param($EntryObject)
    $prop = $EntryObject.PSObject.Properties['timerTaskId']
    if ($null -eq $prop) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$prop.Value)) { return $null }
    return [string]$prop.Value
}

if ($Clear) {
    if ([string]::IsNullOrWhiteSpace($Label)) { throw '-Clear requires -Label <l>' }
    $entries = Read-StateFile
    $removed = @($entries | Where-Object { $_.label -eq $Label })
    $remaining = @($entries | Where-Object { $_.label -ne $Label })
    Write-StateFile -Entries $remaining
    Write-Output "Cleared '$Label' ($($removed.Count) entry removed)."
    foreach ($e in $removed) {
        # WHY $pairedTimerId, not $timerTaskId: PowerShell variable names are
        # case-insensitive, so `$timerTaskId` here would be the SAME PSVariable
        # as the script's own `[string]$TimerTaskId` parameter above - which
        # carries a [string] type constraint. Reusing that name silently
        # coerces Get-TimerTaskId's $null return into "" (empty string) on
        # assignment, defeating the "$null means no timer to stop" check below
        # (verified live: '-> ACTION REQUIRED ... TaskStop ''' printed for an
        # entry armed with no timer at all). A differently-named variable
        # avoids the collision entirely.
        $pairedTimerId = Get-TimerTaskId $e
        if ($null -ne $pairedTimerId) {
            Write-Output "  -> ACTION REQUIRED: its paired background timer is still running (task '$pairedTimerId') - call TaskStop '$pairedTimerId' now, in this same turn (GH issue #52)."
        }
    }
    exit 0
}

if ($ClearAll) {
    $entries = Read-StateFile
    Write-StateFile -Entries @()
    Write-Output "Cleared all watchdog entries ($($entries.Count) removed)."
    foreach ($e in $entries) {
        $pairedTimerId = Get-TimerTaskId $e
        if ($null -ne $pairedTimerId) {
            Write-Output "  -> ACTION REQUIRED: '$($e.label)' had a paired background timer still tracked (task '$pairedTimerId') - call TaskStop '$pairedTimerId' now if it's still running (GH issue #52)."
        }
    }
    exit 0
}

if ($List) {
    $entries = Read-StateFile
    Write-Output (ConvertTo-Json -InputObject @($entries) -Depth 6)
    exit 0
}

# --- hook modes: -Stop / -SubagentStop -------------------------------------------

function Get-OverdueEntries {
    $nowEpoch = Get-NowEpoch
    $entries = Read-StateFile
    $overdue = New-Object System.Collections.Generic.List[object]
    foreach ($e in $entries) {
        $overdueSeconds = [int]($nowEpoch - [int64]$e.deadlineAtEpoch)
        if ($overdueSeconds -gt 0) {
            $overdue.Add([pscustomobject]@{
                label          = $e.label
                agent          = $e.agent
                ceilingSeconds = $e.ceilingSeconds
                deadlineAt     = ConvertTo-Iso8601FromEpoch ([int64]$e.deadlineAtEpoch)  # derived, not trusted from disk
                overdueSeconds = $overdueSeconds
                abandoned      = ($overdueSeconds -ge $ABANDONED_THRESHOLD_SECONDS)
            })
        }
    }
    # WHY no @() wrap: `@(<List[object]>)` throws "Argument types do not
    # match" on this PS 5.1 build (same documented gotcha as worktree.ps1's
    # $files branch) - the bare comma alone is enough to survive the return
    # boundary without unrolling.
    return ,$overdue
}

if ($Stop) {
    $null = Read-HookStdin  # consumed for contract completeness; no field of Stop's input is needed here
    $overdue = Get-OverdueEntries
    if ($overdue.Count -eq 0) { exit 0 }

    $abandoned = @($overdue | Where-Object { $_.abandoned })
    if ($abandoned.Count -gt 0) {
        # Self-heal: clear now, in this same invocation, rather than leaving a
        # "please remember to clear this" step for a later turn - that's the
        # exact failure mode this fix exists to remove.
        $entries = Read-StateFile
        $labelsToClear = @($abandoned | ForEach-Object { $_.label })
        $remaining = @($entries | Where-Object { $labelsToClear -notcontains $_.label })
        Write-StateFile -Entries $remaining
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($e in $abandoned) {
        $lines.Add("  - '$($e.label)' ($($e.agent)) - overdue by $($e.overdueSeconds)s, looks abandoned (>=${ABANDONED_THRESHOLD_SECONDS}s past its $($e.ceilingSeconds)s ceiling) - cleared automatically, safe to ignore unless you're mid-run on this exact label")
    }
    foreach ($e in @($overdue | Where-Object { -not $_.abandoned })) {
        $lines.Add("  - '$($e.label)' ($($e.agent)) - overdue by $($e.overdueSeconds)s past its $($e.ceilingSeconds)s ceiling")
    }
    $reason = "Watchdog: before ending this turn, check the dispatch(es) below per SKILL.md's watchdog procedure (checkpoint artifact first, then nudge/salvage/degrade - never just wait again):`n" + ($lines -join "`n")
    [Console]::Error.WriteLine($reason)
    exit 2
}

if ($SubagentStop) {
    $stdinRaw = Read-HookStdin
    $payload = $null
    try { $payload = $stdinRaw | ConvertFrom-Json } catch { $payload = $null }
    if ($null -eq $payload) { exit 0 }  # malformed/empty input must never block a subagent

    $watchedAgents = @('qa-intake', 'qa-analyst', 'qa-scenario-writer', 'qa-mutation-author')
    $agentType = [string]$payload.agent_type
    if ($watchedAgents -notcontains $agentType) { exit 0 }  # includes qa-e2e-author and anything else

    $message = [string]$payload.last_assistant_message
    $trimmed = $message.Trim()

    $stallPhrases = @(
        "i'll wait for", 'i will wait for', 'still working on', 'let me know when',
        'waiting for', "i'll continue once", 'i will continue once', 'please wait',
        'in a moment', 'give me a moment'
    )
    $lower = $trimmed.ToLowerInvariant()
    $looksLikeStall = ($trimmed.Length -lt 15)
    if (-not $looksLikeStall) {
        foreach ($phrase in $stallPhrases) {
            if ($lower.Contains($phrase)) { $looksLikeStall = $true; break }
        }
    }

    if (-not $looksLikeStall) { exit 0 }

    $snippet = $trimmed
    if ($snippet.Length -gt 120) { $snippet = $snippet.Substring(0, 120) + '...' }
    $reason = "Watchdog: '$agentType''s final message reads like a stall placeholder, not a real result: `"$snippet`". Per GH issue #32, a reply like this can arrive having written zero bytes to disk. Write your checkpoint artifact now if you haven't, then finish with a concrete completed/blocked status - not a wait message."
    [Console]::Error.WriteLine($reason)
    exit 2
}
