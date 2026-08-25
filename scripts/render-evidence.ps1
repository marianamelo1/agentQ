<#
.SYNOPSIS
    render-evidence.ps1 - deterministically render the agentQ EVIDENCE file
    (templates/report/evidence-template.md) from workspace JSON artifacts.

.DESCRIPTION
    Phase 8 (second half): qa-report-synthesizer writes the plain-language main
    report + analyst-brief.json's selection (report-selection.json); this script
    then renders the technical -evidence.md companion straight from the raw
    artifacts, with ZERO model calls. WHY: most of the evidence file is either
    pure data (risk-score.json's ledger, test-results.json's counts) or a FIXED
    phrasing already specified in CLAUDE.md/CONTRACTS.md (contract ERR/WARN text,
    mutation absolute-survivor wording, diff-coverage refusal wording) - spending
    an LLM call on formatting JSON is pure waste, and a script guarantees the
    same input bytes produce the same output bytes every time (unlike an agent).

    The only genuine JUDGMENT this file needs (regression-risk findings, AC
    grades, the gap lattice, static flaky-smell hits, Socratic questions,
    manual-test framing) comes from analyst-brief.json, written by qa-analyst -
    this script renders that content verbatim, it never invents or re-derives it.
    Which <=3 findings/questions made the MAIN report (so the evidence file's
    "Finding detail" section shares the exact same numbering) comes from
    report-selection.json, written by qa-report-synthesizer.

    Known simplifications (documented here rather than silently guessed at):
      - Component vs API+Contract rows both read test-results-generated-*.json's
        OVERALL pass/fail counts when ANY scenario of that level exists this run
        (the artifact doesn't tag individual results by scenario level) - the
        row is SKIPPED when no scenario of that level was generated, never a
        fabricated per-level split.
      - E2E / Design conformance have no persisted result artifact in
        scripts/CONTRACTS.md today (qa-e2e-author's findings are narrative-only
        per CLAUDE.md Phase 7c) - -E2EPending lets the orchestrator flag
        background authoring; otherwise these rows render SKIPPED honestly from
        whatever IS on disk (a linked Figma design, any e2e-level scenario).

    Exit code 0 = the script ran (a missing/degraded artifact is a finding in
    the rendered file, not a script failure). Non-zero = the script itself
    could not do its job (bad manifest, write outside reports/, ...).

.PARAMETER Manifest
    Path to run-manifest.json (workspaceDir, repoPath, branch, baseSha, ticketKey).

.PARAMETER ReportPath
    The exact main-report .md path qa-report-synthesizer was given/wrote to
    (under reports/). The evidence file is the same name with "-evidence"
    inserted before ".md", written alongside it.

.PARAMETER E2EPending
    Orchestrator-known live state: qa-e2e-author is still authoring new E2E
    specs / running design conformance in the background. No artifact captures
    this fact today, so it must be passed in explicitly when true.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Manifest,

    [Parameter(Mandatory = $true)]
    [string]$ReportPath,

    [switch]$E2EPending
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# -----------------------------------------------------------------------------
# Helpers (Get-Prop / Write-Utf8NoBom copied verbatim from render-artifacts.ps1 -
# self-contained scripts, no shared module, per this codebase's convention)
# -----------------------------------------------------------------------------

function Get-Prop {
    # WHY plain `return $p.Value` (NOT the comma-wrapped `return , $p.Value`
    # some other agentQ scripts use for a single scalar-preserving need):
    # every call site in THIS script wraps the result in `@(...)` itself to
    # normalize it into a real array (matching risk-score.ps1/run-tests.ps1's
    # own Get-Prop + call-site convention) - combining that with an
    # ALREADY-array-preserving comma-return double-wraps (verified live: an
    # array-valued property came back as a 1-element array containing the
    # original array, e.g. "agentsCalled" rendering as the literal text
    # "System.Object[]"). Pick ONE convention per Get-Prop; this script's is
    # "the call site normalizes with @()".
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Read-JsonOrNull {
    # A missing or unparseable artifact becomes $null uniformly - every renderer
    # below treats $null as "this lane didn't produce evidence" and degrades
    # honestly, never throws for a run that simply skipped a phase.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Format-Seconds {
    param([double]$Seconds)
    $total = [int][math]::Round($Seconds)
    $m = [int]([math]::Floor($total / 60))
    $s = $total - ($m * 60)
    if ($m -gt 0) { return "{0}m {1}s" -f $m, $s }
    return "{0}s" -f $s
}

function Join-NonEmpty {
    param([string[]]$Parts, [string]$Sep)
    return (@($Parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join $Sep)
}

# -----------------------------------------------------------------------------
# Load + validate manifest, resolve + jail the evidence path
# -----------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { throw "Manifest not found: $Manifest" }
$man = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json

$workspaceDir = [string](Get-Prop $man 'workspaceDir' '')
if ([string]::IsNullOrWhiteSpace($workspaceDir)) { throw "run-manifest.json has no 'workspaceDir'." }
$workspaceDir = [System.IO.Path]::GetFullPath($workspaceDir)
if (-not (Test-Path -LiteralPath $workspaceDir)) { throw "Manifest workspaceDir does not exist: $workspaceDir" }

$repoRoot   = Split-Path -Parent $PSScriptRoot
$reportsRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'reports'))
$sep = [System.IO.Path]::DirectorySeparatorChar
$reportPathFull = [System.IO.Path]::GetFullPath($ReportPath)
if (-not $reportPathFull.StartsWith($reportsRoot + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to write: -ReportPath '$reportPathFull' is outside '$reportsRoot'."
}
if (-not $reportPathFull.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "-ReportPath must end in .md (got: $reportPathFull)"
}
$evidencePath = $reportPathFull.Substring(0, $reportPathFull.Length - 3) + '-evidence.md'

# WHY derive "now" from the report's OWN filename timestamp (<...>-YYYY-MM-DD-HHmm.md)
# rather than live Get-Date: this script's exit-code contract promises "same
# input bytes -> same output bytes" (matching render-artifacts.ps1's own
# idempotency contract) - a live wall-clock read would make the Date/fetch-age
# fields drift every time the evidence file is regenerated (e.g. after a
# report fix) even though nothing about the underlying run changed. Falls back
# to the live clock only when the report path doesn't follow the naming
# convention (verified live: a report path without it, e.g. an ad hoc test
# file, must still render something rather than throw).
$renderedAt = Get-Date
$nameMatch = [regex]::Match((Split-Path -Leaf $reportPathFull), '-(\d{4}-\d{2}-\d{2}-\d{4})\.md$')
if ($nameMatch.Success) {
    try {
        $renderedAt = [DateTime]::ParseExact($nameMatch.Groups[1].Value, 'yyyy-MM-dd-HHmm', [System.Globalization.CultureInfo]::InvariantCulture)
    } catch { }
}

$repoSlug  = [string](Get-Prop $man 'repoSlug' '')
$repoShort = ($repoSlug -split '/')[-1]
$branch    = [string](Get-Prop $man 'branch' '')
$baseSha   = [string](Get-Prop $man 'baseSha' '')
$baseShaShort = if ($baseSha.Length -ge 12) { $baseSha.Substring(0, 12) } else { $baseSha }
$fetchedAtRaw = [string](Get-Prop $man 'fetchedAt' '')
$ticketKey = [string](Get-Prop $man 'ticketKey' '')
$ticketKeyOrBranch = if ($ticketKey) { $ticketKey } else { $branch }

$fetchAge = 'unknown'
if ($fetchedAtRaw) {
    try {
        $fetchedAt = [DateTime]::Parse($fetchedAtRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $ageMin = [int][math]::Round(($renderedAt.ToUniversalTime() - $fetchedAt.ToUniversalTime()).TotalMinutes)
        $fetchAge = if ($ageMin -le 0) { 'just now' } else { "$ageMin min ago" }
    } catch { $fetchAge = $fetchedAtRaw }
}

# -----------------------------------------------------------------------------
# Load every artifact (all optional - a $null one degrades its own section only)
# -----------------------------------------------------------------------------

$diffSet          = Read-JsonOrNull (Join-Path $workspaceDir 'diff-set.json')
$jiraTicket       = Read-JsonOrNull (Join-Path $workspaceDir 'jira-ticket.json')
$testResults      = Read-JsonOrNull (Join-Path $workspaceDir 'test-results.json')
$testResultsGenBranch = Read-JsonOrNull (Join-Path $workspaceDir 'test-results-generated-branch.json')
$testResultsGenBase   = Read-JsonOrNull (Join-Path $workspaceDir 'test-results-generated-base.json')
$diffCoverage     = Read-JsonOrNull (Join-Path $workspaceDir 'diff-coverage.json')
$mutationReport   = Read-JsonOrNull (Join-Path $workspaceDir 'mutation-report.json')
$mutants          = Read-JsonOrNull (Join-Path $workspaceDir 'mutants.json')
$strykerSummary   = Read-JsonOrNull (Join-Path (Join-Path $workspaceDir 'stryker') 'summary.json')
$contractReport   = Read-JsonOrNull (Join-Path $workspaceDir 'contract-report.json')
$riskScore        = Read-JsonOrNull (Join-Path $workspaceDir 'risk-score.json')
$timeLedger       = Read-JsonOrNull (Join-Path $workspaceDir 'time-ledger.json')
$impactIndex      = Read-JsonOrNull (Join-Path $workspaceDir 'impact-index.json')
$testomatCand     = Read-JsonOrNull (Join-Path $workspaceDir 'testomat-candidates.json')
$manualTestCand   = Read-JsonOrNull (Join-Path $workspaceDir 'manual-test-candidates.json')
$analystBrief     = Read-JsonOrNull (Join-Path $workspaceDir 'analyst-brief.json')
$reportSelection  = Read-JsonOrNull (Join-Path $workspaceDir 'report-selection.json')

$configPath = Join-Path (Join-Path $repoRoot '.claude') 'qa-agent-config.jsonc'
$skipQaImpactConfigured = $false
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
        # .jsonc: strip // line comments before parsing (this repo's config never
        # uses "//" inside a string value, so a line-anchored strip is safe here).
        $raw = (Get-Content -LiteralPath $configPath -Raw) -replace '(?m)^\s*//.*$', ''
        $cfg = $raw | ConvertFrom-Json
        $toggles = Get-Prop $cfg 'toggles' $null
        $skipQaImpactConfigured = [bool](Get-Prop $toggles 'skipQaImpact' $false)
    } catch { }
}

$scenariosDir = Join-Path $workspaceDir 'scenarios'
$scenarios = New-Object System.Collections.Generic.List[object]
if (Test-Path -LiteralPath $scenariosDir) {
    foreach ($f in (Get-ChildItem -LiteralPath $scenariosDir -Filter 'scenario-*.json' -File | Sort-Object Name)) {
        $s = Read-JsonOrNull $f.FullName
        if ($null -ne $s) { $scenarios.Add($s) }
    }
}

# -----------------------------------------------------------------------------
# Section builders
# -----------------------------------------------------------------------------

function Build-RunSummary {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Run summary')
    $lines.Add('')
    if ($null -eq $timeLedger) {
        $lines.Add('_No time-ledger.json this run - phase timings unavailable._')
        return ($lines -join "`n")
    }
    $agents = @(Get-Prop $timeLedger 'agentsCalled' @())
    $agentsText = if (@($agents).Count -gt 0) { ($agents -join ' · ') } else { '— none (all cached / skipped) —' }
    $lines.Add("**Agents called:** $agentsText")
    $lines.Add('')
    $lines.Add('| Phase | Actor | Seconds | Outcome |')
    $lines.Add('|---|---|---|---|')
    foreach ($p in @(Get-Prop $timeLedger 'phases' @())) {
        $name = [string](Get-Prop $p 'name' '')
        $actor = [string](Get-Prop $p 'actor' '')
        $secs = Get-Prop $p 'seconds' 0
        $outcome = [string](Get-Prop $p 'outcome' 'RAN')
        $lines.Add("| $name | $actor | $secs | $outcome |")
    }
    $lines.Add('')
    $total = [double](Get-Prop $timeLedger 'totalSeconds' 0)
    $lines.Add("**Total wall-clock: $(Format-Seconds $total)** (phases marked ""overlapped"" run concurrently — this is measured elapsed time, not the column sum)")
    return ($lines -join "`n")
}

function Build-FindingDetail {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Finding detail')
    $lines.Add('')
    $findings = @(Get-Prop $analystBrief 'findings' @())
    $selectedIds = @(Get-Prop $reportSelection 'selectedFindingIds' @())
    if ($null -eq $analystBrief -or @($findings).Count -eq 0) {
        $lines.Add('_No findings this run (analyst-brief.json absent or empty)._')
        return ($lines -join "`n")
    }
    if (@($selectedIds).Count -eq 0) {
        $lines.Add('No findings rose to the main report this run.')
        return ($lines -join "`n")
    }
    $n = 0
    foreach ($id in $selectedIds) {
        $f = $findings | Where-Object { (Get-Prop $_ 'id' $null) -eq $id } | Select-Object -First 1
        if ($null -eq $f) { continue }
        $n++
        $title = [string](Get-Prop $f 'title' '')
        $file = [string](Get-Prop $f 'file' '')
        $line = Get-Prop $f 'line' $null
        $detail = [string](Get-Prop $f 'detail' '')
        $impactNote = [string](Get-Prop $f 'impactNote' '')
        $lines.Add("### $n. $title")
        $lines.Add('')
        $loc = if ($file) { if ($null -ne $line) { "``${file}:${line}``" } else { "``$file``" } } else { '' }
        $lines.Add((Join-NonEmpty @($loc, $detail) ' — '))
        if ($impactNote) { $lines.Add(''); $lines.Add($impactNote) }
        $lines.Add('')
    }
    return ($lines -join "`n").TrimEnd()
}

function Build-AcceptanceCriteria {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Acceptance criteria')
    $lines.Add('')
    $acs = @(Get-Prop $analystBrief 'acAlignment' @())
    if ($null -eq $analystBrief -or @($acs).Count -eq 0) {
        $lines.Add('| AC | Grade | Evidence |')
        $lines.Add('|---|---|---|')
        $lines.Add('| — | UNVERIFIABLE — no analyst brief this run | — |')
        return ($lines -join "`n")
    }
    $lines.Add('| AC | Grade | Evidence |')
    $lines.Add('|---|---|---|')
    foreach ($a in $acs) {
        $ac = [string](Get-Prop $a 'ac' '')
        $grade = [string](Get-Prop $a 'grade' '')
        $evidence = [string](Get-Prop $a 'evidence' '')
        $lines.Add("| $ac | $grade | $evidence |")
    }
    return ($lines -join "`n")
}

function Get-UnitLevelState {
    # Returns @{ State; Result } for the Capability matrix Unit row, and is
    # reused verbatim by the Unit level section below (single source of truth).
    if ($null -eq $testResults) {
        return @{ State = 'SKIPPED — no test-results.json this run (quick mode, or unit phase not run)'; Result = '—' }
    }
    $runs = @(Get-Prop $testResults 'runs' @())
    $buildFailures = @($runs | Where-Object {
        $fails = @(Get-Prop $_ 'failures' @())
        (@($fails | Where-Object { (Get-Prop $_ 'fqn' '') -eq '<build>' })).Count -gt 0
    })
    if (@($buildFailures).Count -gt 0) {
        $msg = [string](Get-Prop (Get-Prop $buildFailures[0] 'failures')[0] 'message' '')
        $short = if ($msg.Length -gt 200) { $msg.Substring(0, 200) + ' …' } else { $msg }
        return @{ State = "DEGRADED — build/restore failed: $short"; Result = '0 tests executed' }
    }
    $passed = 0; $total = 0
    foreach ($r in $runs) {
        if (Get-Prop $r 'skippedReason' $null) { continue }
        $passed += [int](Get-Prop $r 'passed' 0)
        $total += [int](Get-Prop $r 'testsExecuted' 0)
    }
    $degradedNote = ''
    if ($null -ne $diffCoverage -and [bool](Get-Prop $diffCoverage 'refused' $false)) {
        $degradedNote = " (coverage: DEGRADED — $([string](Get-Prop $diffCoverage 'refusalReason' 'refused')))"
    }
    return @{ State = 'RAN'; Result = "$passed/$total affected tests passed$degradedNote" }
}

function Get-MutationTally {
    # { Killed; Survived; NoCoverage; Timeout; Tested } across the merged report's files{}.
    $tally = @{ Killed = 0; Survived = 0; NoCoverage = 0; Timeout = 0; Ignored = 0; CompileError = 0 }
    if ($null -eq $mutationReport) { return $tally }
    $files = Get-Prop $mutationReport 'files' $null
    if ($null -eq $files) { return $tally }
    foreach ($fileKey in $files.PSObject.Properties.Name) {
        $f = $files.$fileKey
        foreach ($m in @(Get-Prop $f 'mutants' @())) {
            $status = [string](Get-Prop $m 'status' '')
            if ($tally.ContainsKey($status)) { $tally[$status] = $tally[$status] + 1 }
        }
    }
    return $tally
}

function Get-MutationLevelState {
    $tally = Get-MutationTally
    if ($null -eq $mutationReport) {
        return @{ State = 'SKIPPED — mutation not run this run (consent denied, or build/restore failure upstream)'; Result = '—' }
    }
    $tested = $tally.Killed + $tally.Survived + $tally.Timeout
    $note = ''
    if ($null -ne $strykerSummary) {
        $anyFilter = @(@(Get-Prop $strykerSummary 'projects' @()) | Where-Object { Get-Prop $_ 'testCaseFilter' $null })
        if ($anyFilter.Count -gt 0) { $note = ' (scoped to diff-related test classes)' }
    }
    return @{ State = 'RAN'; Result = "$($tally.Survived) survivor(s), $($tally.Killed) killed of $tested tested$note" }
}

function Get-ScenariosByLevel {
    # WHY the leading comma: a bare `return @(pipeline)` ENUMERATES the array
    # when writing it to the output stream - zero matches emits zero pipeline
    # objects, so the caller's `$x = Get-...` captures $null instead of an
    # empty array (verified live: `.Count` on that $null threw under
    # Set-StrictMode). `return , @(pipeline)` fixes this correctly on its own
    # (verified live for 0/1/N matches via plain assignment `$x = Get-...`) -
    # the two-step assign-then-comma form here is equivalent, not required.
    # The REAL trap is at the CALL SITE, not in here: wrapping an ALREADY
    # comma-wrapped function's call in another `@()` - e.g. `@(Get-ScenariosByLevel ...)`
    # - double-wraps a zero-match result into a 1-element array containing the
    # empty array (verified live). Callers of this function must assign its
    # result directly (`$x = Get-ScenariosByLevel ...`), never `@(...)` it again.
    param([string]$Level)
    $filtered = @($scenarios | Where-Object { [string](Get-Prop $_ 'level' '') -eq $Level })
    return , $filtered
}

function Get-GeneratedRunTotals {
    param($Artifact)
    $passed = 0; $total = 0; $failed = 0
    if ($null -eq $Artifact) { return @{ Passed = 0; Total = 0; Failed = 0 } }
    foreach ($r in @(Get-Prop $Artifact 'runs' @())) {
        $passed += [int](Get-Prop $r 'passed' 0)
        $total += [int](Get-Prop $r 'testsExecuted' 0)
        $failed += [int](Get-Prop $r 'failed' 0)
    }
    return @{ Passed = $passed; Total = $total; Failed = $failed }
}

function Get-LevelRowState {
    param([string]$Level, [string]$LabelForNone)
    $ofLevel = Get-ScenariosByLevel -Level $Level
    if (@($ofLevel).Count -eq 0) { return @{ State = "SKIPPED — $LabelForNone"; Result = '—' } }
    $totals = Get-GeneratedRunTotals -Artifact $testResultsGenBranch
    if ($totals.Total -eq 0) {
        return @{ State = 'GENERATED, NOT EXECUTED — execution not run this run'; Result = "$(@($ofLevel).Count) scenario(s) generated" }
    }
    return @{ State = 'RAN'; Result = "$($totals.Passed)/$($totals.Total) generated tests passed (overall - not split per level, see note above)" }
}

function Build-CapabilityMatrix {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Capability matrix')
    $lines.Add('')
    $lines.Add('| Level | State | Result |')
    $lines.Add('|---|---|---|')

    $unit = Get-UnitLevelState
    $lines.Add("| Unit | $($unit.State) | $($unit.Result) |")

    $mut = Get-MutationLevelState
    $lines.Add("| Mutation | $($mut.State) | $($mut.Result) |")

    $comp = Get-LevelRowState -Level 'component' -LabelForNone 'no component-level scenarios generated this run'
    $lines.Add("| Component | $($comp.State) | $($comp.Result) |")

    $api = Get-LevelRowState -Level 'api' -LabelForNone 'no API-level scenarios generated this run'
    if ($null -ne $contractReport) {
        $breaking = @(Get-Prop $contractReport 'breaking' @())
        $skipped = [bool](Get-Prop $contractReport 'skipped' $false)
        if ($skipped) {
            $api.State = 'SKIPPED — ' + [string](Get-Prop $contractReport 'skipReason' 'no spec change')
        } elseif (@($breaking).Count -gt 0) {
            $api.State = 'RAN'
            $api.Result = (Join-NonEmpty @($api.Result, "$(@($breaking).Count) breaking contract change(s) — see API + Contract level") ' · ')
        } else {
            $api.State = 'RAN'
            $api.Result = (Join-NonEmpty @($api.Result, 'no breaking contract changes') ' · ')
        }
    } elseif ((Get-ScenariosByLevel -Level 'api').Count -eq 0) {
        $api.State = 'SKIPPED — no API surface touched (contract gate closed at intake)'
    }
    $lines.Add("| API + Contract | $($api.State) | $($api.Result) |")

    $e2eScenarios = Get-ScenariosByLevel -Level 'e2e'
    if ($E2EPending) {
        $lines.Add('| E2E | PENDING — authoring in background; next run includes it | — |')
    } elseif (@($e2eScenarios).Count -eq 0) {
        $frontend = [bool](Get-Prop (Get-Prop $diffSet 'levels' $null) 'frontend' $false)
        $reason = if ($frontend) { 'no cached E2E specs ran this run' } else { 'backend-only diff, no frontend changes' }
        $lines.Add("| E2E | SKIPPED — $reason | — |")
    } else {
        $lines.Add("| E2E | RAN | $(@($e2eScenarios).Count) scenario(s) — see E2E section |")
    }

    $figmaLinks = @(Get-Prop $jiraTicket 'figmaLinks' @())
    if ($E2EPending -and @($figmaLinks).Count -gt 0) {
        $lines.Add('| Design conformance | PENDING — authoring in background; next run includes it | — |')
    } elseif (@($figmaLinks).Count -eq 0) {
        $lines.Add('| Design conformance | SKIPPED — no design linked in ticket | — |')
    } else {
        $lines.Add('| Design conformance | SKIPPED — no design-conformance artifact produced this run | — |')
    }

    if ($null -eq $impactIndex) {
        $reason = if ($skipQaImpactConfigured) { 'disabled by config' } else { 'not run this run' }
        $lines.Add("| Impact | SKIPPED — $reason | — |")
    } else {
        $matches = @(Get-Prop $impactIndex 'matches' @())
        $repoCount = @($matches | ForEach-Object { [string](Get-Prop $_ 'repoSlug' '') } | Select-Object -Unique).Count
        $lines.Add("| Impact | RAN | $(@($matches).Count) ref(s) across $repoCount repo(s); see Impact map |")
    }
    return ($lines -join "`n")
}

function Build-ImpactMap {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Impact map')
    $lines.Add('')
    if ($null -eq $impactIndex) {
        $lines.Add('_Impact phase did not run this run (see Capability matrix)._')
        return ($lines -join "`n")
    }
    $matches = @(Get-Prop $impactIndex 'matches' @())
    if (@($matches).Count -eq 0) {
        $lines.Add('No matches found in any scanned repo for this diff''s seeds.')
    } else {
        $byRepo = $matches | Group-Object { [string](Get-Prop $_ 'repoSlug' '') }
        foreach ($g in $byRepo) {
            $lines.Add("**$($g.Name)** ($($g.Count) match(es)):")
            $shown = @($g.Group | Select-Object -First 3)
            foreach ($m in $shown) {
                $indexOnly = [bool](Get-Prop $m 'indexOnly' $false)
                $tag = if ($indexOnly) { ' *(candidate — keyword match)*' } else { '' }
                $lines.Add("- ``$([string](Get-Prop $m 'file' '')):$(Get-Prop $m 'line' '')`` — $([string](Get-Prop $m 'context' ''))$tag")
            }
            if ($g.Count -gt 3) { $lines.Add("- +$($g.Count - 3) more — see impact-index.json") }
        }
    }
    $testomatStatus = if ($null -ne $testomatCand) { [string](Get-Prop $testomatCand 'status' 'RAN') } else { 'SKIPPED — impact phase did not run' }
    $lines.Add('')
    $lines.Add("**Testomat:** $testomatStatus")
    if ($testomatStatus -eq 'RAN') {
        $cands = @(Get-Prop $testomatCand 'candidates' @())
        if (@($cands).Count -eq 0) { $lines.Add('0 candidates found.') }
        else {
            foreach ($c in (@($cands) | Select-Object -First 3)) {
                $lines.Add("- $([string](Get-Prop $c 'title' '')) (suite: $([string](Get-Prop $c 'suite' ''))) *(candidate — keyword match)*")
            }
            if (@($cands).Count -gt 3) { $lines.Add("- +$(@($cands).Count - 3) more — see testomat-candidates.json") }
        }
    }
    $lines.Add('')
    $lines.Add('No signal ≠ not affected — this is a keyword/reference scan, not a proof of independence.')
    return ($lines -join "`n")
}

function Build-ManualTesting {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Manual testing')
    $lines.Add('')
    if ($null -eq $manualTestCand) {
        $lines.Add('_Manual-test phase did not run this run._')
        return ($lines -join "`n")
    }
    $status = [string](Get-Prop $manualTestCand 'status' 'RAN')
    $lines.Add("Status: $status")
    if ($status -eq 'RAN') {
        $cands = @(Get-Prop $manualTestCand 'candidates' @())
        $analystFraming = @{}
        foreach ($m in @(Get-Prop $analystBrief 'manualTesting' @())) {
            $mid = [string](Get-Prop $m 'id' '')
            if ($mid) { $analystFraming[$mid] = [string](Get-Prop $m 'why' '') }
        }
        $ordered = @($cands | Sort-Object { if ([string](Get-Prop $_ 'matchedBy' '') -eq 'diff-seed') { 0 } else { 1 } })
        $shown = @($ordered | Select-Object -First 5)
        foreach ($c in $shown) {
            $cid = [string](Get-Prop $c 'id' '')
            $title = [string](Get-Prop $c 'title' '')
            $matchedBy = [string](Get-Prop $c 'matchedBy' '')
            $why = if ($analystFraming.ContainsKey($cid)) { $analystFraming[$cid] } else { '' }
            $lines.Add("- **$title** (``$matchedBy``, candidate — keyword/ticket match)$(if ($why) { " — $why" })")
        }
        if (@($ordered).Count -gt 5) { $lines.Add("- +$(@($ordered).Count - 5) more — see manual-test-candidates.json") }
        if (@($ordered).Count -eq 0) { $lines.Add('0 candidates found.') }
    }
    return ($lines -join "`n")
}

function Build-UnitLevel {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Unit level')
    $lines.Add('')
    $unit = Get-UnitLevelState
    $lines.Add("$($unit.State) — $($unit.Result)")
    $lines.Add('')
    if ($null -ne $diffCoverage) {
        if ([bool](Get-Prop $diffCoverage 'refused' $false)) {
            $lines.Add("Diff coverage: DEGRADED — $([string](Get-Prop $diffCoverage 'refusalReason' ''))")
        } else {
            $lineCov = [double](Get-Prop $diffCoverage 'lineDiffCoverage' 0)
            $branchCov = [double](Get-Prop $diffCoverage 'branchDiffCoverage' 0)
            # WHY manual percent math instead of the "{0:P0}" format specifier: the
            # bare `-f` operator formats using the THREAD'S CURRENT CULTURE (e.g.
            # en-US renders "54%"), so a machine on a different locale could render
            # a different byte sequence for the same input numbers - and even
            # InvariantCulture doesn't fix this: verified live that .NET's invariant
            # "P0" format inserts a space before the sign ("54 %"), which would
            # silently change this line's rendering on every machine (including this
            # one) relative to what it looked like before. Computing the integer and
            # appending a literal "%" is culture-independent by construction.
            $linePct = [int][math]::Round($lineCov * 100)
            $branchPct = [int][math]::Round($branchCov * 100)
            $lines.Add("Of the lines you changed, ${linePct}% ran under tests related to this branch (branch coverage ${branchPct}%).")
        }
    } else {
        $lines.Add('Diff coverage: SKIPPED — no diff-coverage.json this run.')
    }
    $lines.Add('')
    $lines.Add('**Most likely to catch a regression here** (from risk-score.json''s own ranking):')
    foreach ($t in @(Get-Prop $riskScore 'topTests' @())) {
        $lines.Add("- ``$([string](Get-Prop $t 'fqn' ''))`` — $([string](Get-Prop $t 'reason' ''))")
        $rc = [string](Get-Prop $t 'runCommand' '')
        if ($rc) { $lines.Add("  ``$rc``") }
    }
    if (@(Get-Prop $riskScore 'topTests' @()).Count -eq 0) { $lines.Add('_none ranked this run_') }
    $lines.Add('')
    $lines.Add('**Flaky-risk smells (static):**')
    $smells = @(Get-Prop (Get-Prop $analystBrief 'flakyInterpretation' $null) 'staticSmells' @())
    if (@($smells).Count -eq 0) { $lines.Add('None found.') }
    else { foreach ($sm in $smells) { $lines.Add("- ``$([string](Get-Prop $sm 'file' '')):$(Get-Prop $sm 'line' '')`` — $([string](Get-Prop $sm 'smell' '')) — $([string](Get-Prop $sm 'note' ''))") } }
    $lines.Add('')
    $lines.Add('**Might be flaky (failed this run — rerun command provided; confirm outside agentQ):**')
    $mbf = @(Get-Prop (Get-Prop $testResults 'flaky' $null) 'mightBeFlaky' @())
    if (@($mbf).Count -eq 0) { $lines.Add('None this run.') }
    else { foreach ($f in $mbf) { $lines.Add("- ``$([string](Get-Prop $f 'fqn' ''))`` — ``$([string](Get-Prop $f 'rerunCommand' ''))``") } }
    $unitScenarios = Get-ScenariosByLevel -Level 'unit'
    foreach ($sc in $unitScenarios) {
        $lines.Add("🧪 Generated: ``$([string](Get-Prop $sc 'id' ''))`` — $([string](Get-Prop $sc 'title' '')). See 'Generated scenarios' below.")
    }
    return ($lines -join "`n")
}

function Build-MutationLevel {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Mutation level')
    $lines.Add('')
    if ($null -eq $mutationReport) {
        $lines.Add('SKIPPED — mutation not run this run.')
        return ($lines -join "`n")
    }
    $fromCache = $false
    if ($null -ne $strykerSummary) {
        $fromCache = @(Get-Prop $strykerSummary 'projects' @()) | Where-Object { [bool](Get-Prop $_ 'fromCache' $false) } | Select-Object -First 1
        $fromCache = [bool]$fromCache
    }
    if ($fromCache) { $lines.Add('_Verdicts for the mechanical tier were reused from an identical prior run (fromCache: true) — not re-executed this run._'); $lines.Add('') }
    $scoped = $null -ne $strykerSummary -and @(@(Get-Prop $strykerSummary 'projects' @()) | Where-Object { Get-Prop $_ 'testCaseFilter' $null }).Count -gt 0
    $files = Get-Prop $mutationReport 'files' $null
    $anySurvivor = $false
    if ($null -ne $files) {
        foreach ($fileKey in $files.PSObject.Properties.Name) {
            $f = $files.$fileKey
            foreach ($m in @(Get-Prop $f 'mutants' @())) {
                if ([string](Get-Prop $m 'status' '') -ne 'Survived') { continue }
                $anySurvivor = $true
                $mutatorName = [string](Get-Prop $m 'mutatorName' '')
                $desc = [string](Get-Prop $m 'description' '')
                if ([string]::IsNullOrWhiteSpace($desc)) {
                    # Stryker's own mechanical mutants frequently leave description empty -
                    # fall back to the mutated replacement code, which is always populated
                    # (mutation-testing-elements has no "original" field - the source file
                    # + location already identifies it).
                    $repl = [string](Get-Prop $m 'replacement' '')
                    $desc = if ($repl) { "mutated to: ``$repl``" } else { '(no description available)' }
                }
                $startLine = Get-Prop (Get-Prop $m 'location' $null) 'start' $null
                $lineNum = if ($null -ne $startLine) { Get-Prop $startLine 'line' '?' } else { '?' }
                $killScope = if ($scoped) { 'no test related to this change kills it' } else { 'no test in the project kills it' }
                $lines.Add("- **${fileKey}:${lineNum}** ($mutatorName) — $desc — $killScope.")
                $sf = Get-Prop $m 'suggestedFix' $null
                if ($null -ne $sf) {
                    $lines.Add("  🧪 Generated fix: strengthens ``$([string](Get-Prop $sf 'testFile' ''))``. See 'Generated scenarios' below.")
                }
            }
        }
    }
    foreach ($m in @(Get-Prop $mutants 'mutants' @())) {
        if ([string](Get-Prop $m 'status' '') -ne 'Survived') { continue }
        $anySurvivor = $true
        $desc = [string](Get-Prop $m 'businessRule' '')
        $killScope = if ($scoped) { 'no test related to this change kills it' } else { 'no test in the project kills it' }
        $lines.Add("- **$([string](Get-Prop $m 'file' '')):$(Get-Prop $m 'line' '')** (agentq-$([string](Get-Prop $m 'id' ''))) — $desc — $killScope.")
        $sf = Get-Prop $m 'suggestedFix' $null
        if ($null -ne $sf) {
            $lines.Add("  🧪 Generated fix: strengthens ``$([string](Get-Prop $sf 'testFile' ''))``. See 'Generated scenarios' below.")
        }
    }
    if (-not $anySurvivor) { $lines.Add('No absolute survivors this run — every mutant tested was killed.') }
    return ($lines -join "`n")
}

function Build-ComponentLevel {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Component level')
    $lines.Add('')
    $ofLevel = Get-ScenariosByLevel -Level 'component'
    if (@($ofLevel).Count -eq 0) { $lines.Add('No component-level scenarios generated this run.'); return ($lines -join "`n") }
    foreach ($sc in $ofLevel) {
        $state = [string](Get-Prop $sc 'executionState' 'GENERATED, NOT EXECUTED — not yet run')
        $lines.Add("- $([string](Get-Prop $sc 'id' '')) — $([string](Get-Prop $sc 'title' '')): $state")
        $lines.Add("  🧪 Generated: ``$([string](Get-Prop $sc 'id' ''))`` — $([string](Get-Prop $sc 'title' '')). See 'Generated scenarios' below.")
    }
    return ($lines -join "`n")
}

function Build-ApiContractLevel {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## API + Contract level')
    $lines.Add('')
    if ($null -eq $contractReport) {
        $lines.Add('SKIPPED — no API surface touched, or contract lane not run this run.')
    } elseif ([bool](Get-Prop $contractReport 'skipped' $false)) {
        $lines.Add("SKIPPED — $([string](Get-Prop $contractReport 'skipReason' ''))")
    } else {
        foreach ($b in @(Get-Prop $contractReport 'breaking' @())) {
            $lines.Add("- ❌ breaking change to the documented API contract (rule $([string](Get-Prop $b 'ruleId' ''))) — any consumer relying on this shape will break. $([string](Get-Prop $b 'text' '')) (``$([string](Get-Prop $b 'path' ''))``)")
        }
        foreach ($w in @(Get-Prop $contractReport 'warnings' @())) {
            $lines.Add("- ⚠️ potentially breaking — needs human judgment. $([string](Get-Prop $w 'text' '')) (``$([string](Get-Prop $w 'path' ''))``)")
        }
        $pact = Get-Prop $contractReport 'pact' $null
        if ($null -ne $pact) {
            foreach ($c in @(Get-Prop $pact 'failed' @())) { $lines.Add("- ❌ Pact: consumer ``$c`` failed verification.") }
            foreach ($c in @(Get-Prop $pact 'unverifiable' @())) { $lines.Add("- Pact: consumer ``$c`` unverifiable, not failed (unknown provider state).") }
        }
        if (@(Get-Prop $contractReport 'breaking' @()).Count -eq 0 -and @(Get-Prop $contractReport 'warnings' @()).Count -eq 0) {
            $lines.Add('No breaking or warning-level contract changes.')
        }
    }
    $ofLevel = Get-ScenariosByLevel -Level 'api'
    foreach ($sc in $ofLevel) {
        $lines.Add("🧪 Generated: ``$([string](Get-Prop $sc 'id' ''))`` — $([string](Get-Prop $sc 'title' '')). See 'Generated scenarios' below.")
    }
    return ($lines -join "`n")
}

function Build-E2ELevel {
    $lines = New-Object System.Collections.Generic.List[string]
    $figmaLinks = @(Get-Prop $jiraTicket 'figmaLinks' @())
    $heading = if (@($figmaLinks).Count -gt 0) { '## E2E + Design conformance' } else { '## E2E' }
    $lines.Add($heading)
    $lines.Add('')
    $ofLevel = Get-ScenariosByLevel -Level 'e2e'
    if (@($ofLevel).Count -eq 0) {
        if ($E2EPending) { $lines.Add('PENDING — authoring in background; next run includes it.') }
        else { $lines.Add('SKIPPED — no cached E2E specs this run.') }
    } else {
        foreach ($sc in $ofLevel) {
            $state = [string](Get-Prop $sc 'executionState' 'GENERATED, NOT EXECUTED — not yet run')
            $lines.Add("- $([string](Get-Prop $sc 'id' '')) — $([string](Get-Prop $sc 'title' '')): $state")
        }
    }
    if (@($figmaLinks).Count -eq 0) {
        $lines.Add(''); $lines.Add('Design conformance: SKIPPED — no design linked in ticket.')
    } else {
        $lines.Add(''); $lines.Add('Design conformance: SKIPPED — no design-conformance artifact produced this run.')
    }
    return ($lines -join "`n")
}

function Build-GeneratedScenarios {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Generated scenarios')
    $lines.Add('')
    $rows = New-Object System.Collections.Generic.List[object]
    $levelOrder = @{ unit = 0; mutation = 1; component = 2; api = 3; e2e = 4 }
    foreach ($sc in $scenarios) {
        $rows.Add([pscustomobject]@{
            Level = [string](Get-Prop $sc 'level' 'unit')
            Scenario = "$([string](Get-Prop $sc 'id' '')) — $([string](Get-Prop $sc 'title' ''))"
            Path = (@(Get-Prop $sc 'renderedTo' @()) -join '; ')
            State = [string](Get-Prop $sc 'executionState' 'GENERATED_NOT_EXECUTED')
            Vacuity = [string](Get-Prop $sc 'vacuityGrade' 'static_only')
            Keep = 'candidate'
        })
    }
    foreach ($m in @(Get-Prop $mutants 'mutants' @())) {
        $sf = Get-Prop $m 'suggestedFix' $null
        if ($null -eq $sf) { continue }
        $rows.Add([pscustomobject]@{
            Level = 'mutation'
            Scenario = "agentq-$([string](Get-Prop $m 'id' '')) — $([string](Get-Prop $m 'businessRule' ''))"
            Path = [string](Get-Prop $sf 'testFile' '')
            State = 'GENERATED_NOT_EXECUTED'
            Vacuity = 'static only'
            Keep = 'candidate'
        })
    }
    if ($rows.Count -eq 0) {
        $lines.Add('No scenarios generated this run.')
        return ($lines -join "`n")
    }
    $lines.Add('| Level | Scenario | Path | State | Vacuity grade | Keep? |')
    $lines.Add('|---|---|---|---|---|---|')
    foreach ($r in ($rows | Sort-Object { $levelOrder[$_.Level] })) {
        $lines.Add("| $($r.Level) | $($r.Scenario) | ``$($r.Path)`` | $($r.State) | $($r.Vacuity) | $($r.Keep) |")
    }
    return ($lines -join "`n")
}

function Build-SocraticQuestions {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Questions worth answering before the PR')
    $lines.Add('')
    $qs = @(Get-Prop $analystBrief 'socraticQuestions' @())
    if (@($qs).Count -eq 0) {
        $lines.Add('None — the existing tests already answer the questions this diff raises.')
        return ($lines -join "`n")
    }
    $n = 0
    foreach ($q in $qs) {
        $n++
        $lines.Add("$n. $([string](Get-Prop $q 'question' '')) *(evidence: ``$([string](Get-Prop $q 'evidence' ''))``)*")
    }
    return ($lines -join "`n")
}

function Build-RiskLedger {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Risk-score signal ledger')
    $lines.Add('')
    if ($null -eq $riskScore) {
        $lines.Add('_No risk-score.json this run._')
        return ($lines -join "`n")
    }
    $override = Get-Prop $riskScore 'hardOverride' $null
    if ($null -ne $override) {
        $lines.Add("**Hard override: $override** — the weighted ledger below is replaced by this override; nothing downstream of a build failure (or an affected-test failure) is evidence of anything.")
        $lines.Add('')
    }
    $lines.Add('| Signal | Value | Weight | Contribution | Available |')
    $lines.Add('|---|---|---|---|---|')
    foreach ($s in @(Get-Prop $riskScore 'signals' @())) {
        $lines.Add("| $([string](Get-Prop $s 'name' '')) | $(Get-Prop $s 'value') | $(Get-Prop $s 'weight') | $(Get-Prop $s 'contribution') | $(Get-Prop $s 'available') |")
    }
    $lines.Add('')
    if ([bool](Get-Prop $riskScore 'renormalized' $false)) {
        $missing = @(Get-Prop $riskScore 'missingSignals' @()) -join ', '
        $lines.Add("Missing signals: $missing — weights renormalized; confidence lowered to $([string](Get-Prop $riskScore 'confidence' '')).")
        $lines.Add('')
    }
    $lines.Add("Score: **$(Get-Prop $riskScore 'score')** → band **$([string](Get-Prop $riskScore 'band' ''))** · confidence **$([string](Get-Prop $riskScore 'confidence' ''))**")
    $lines.Add('')
    $lines.Add('Methodology: heuristic scored from this diff only; not calibrated against CI history.')
    return ($lines -join "`n")
}

function Build-CaptureProvenance {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Capture provenance')
    $lines.Add('')
    if ($null -eq $contractReport) {
        $lines.Add('_Not applicable — no contract lane ran this run._')
        return ($lines -join "`n")
    }
    $cp = Get-Prop $contractReport 'captureProvenance' $null
    if ($null -eq $cp) { $lines.Add('_No capture provenance recorded._') }
    else {
        $lines.Add("Base: $([string](Get-Prop $cp 'base' '')) · Rev: $([string](Get-Prop $cp 'rev' '')) · Route: ``$([string](Get-Prop $cp 'route' ''))`` · Mode: $([string](Get-Prop $contractReport 'mode' ''))")
    }
    return ($lines -join "`n")
}

function Build-CommandLog {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Command log')
    $lines.Add('')
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($r in @(Get-Prop $testResults 'runs' @())) {
        $t = [string](Get-Prop $r 'trxPath' '')
        if ($t) { $paths.Add($t) }
    }
    foreach ($name in @('test-results.json', 'test-results-generated-branch.json', 'test-results-generated-base.json', 'diff-coverage.json', 'mutation-report.json', 'risk-score.json', 'impact-index.json')) {
        $p = Join-Path $workspaceDir $name
        if (Test-Path -LiteralPath $p) { $paths.Add($p) }
    }
    if ($paths.Count -eq 0) { $lines.Add('_No command-log paths recorded this run._') }
    else { foreach ($p in $paths) { $lines.Add("- ``$p``") } }
    return ($lines -join "`n")
}

# -----------------------------------------------------------------------------
# Compose
# -----------------------------------------------------------------------------

$out = New-Object System.Collections.Generic.List[string]
$out.Add("# 📄 Evidence — $repoShort · $ticketKeyOrBranch")
$out.Add('')
$mainReportName = Split-Path -Leaf $reportPathFull
$out.Add("Companion to ``$mainReportName`` — technical detail only; the verdict and the plain-language summary live there.")
$out.Add('')
$out.Add('| Repo | Branch | Base | Ticket | Date |')
$out.Add('|---|---|---|---|---|')
$ticketDisplay = if ($ticketKey) { $ticketKey } else { '— none —' }
$out.Add("| $repoSlug | ``$branch`` | ``$baseShaShort`` (fetched $fetchAge) | $ticketDisplay | $($renderedAt.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)) |")
$out.Add('')
$out.Add((Build-RunSummary)); $out.Add('')
$out.Add((Build-FindingDetail)); $out.Add('')
$out.Add((Build-AcceptanceCriteria)); $out.Add('')
$out.Add((Build-CapabilityMatrix)); $out.Add('')
$out.Add((Build-ImpactMap)); $out.Add('')
$out.Add((Build-ManualTesting)); $out.Add('')
$out.Add((Build-UnitLevel)); $out.Add('')
$out.Add((Build-MutationLevel)); $out.Add('')
$out.Add((Build-ComponentLevel)); $out.Add('')
$out.Add((Build-ApiContractLevel)); $out.Add('')
$out.Add((Build-E2ELevel)); $out.Add('')
$out.Add((Build-GeneratedScenarios)); $out.Add('')
$out.Add((Build-SocraticQuestions)); $out.Add('')
$out.Add((Build-RiskLedger)); $out.Add('')
$out.Add((Build-CaptureProvenance)); $out.Add('')
$out.Add((Build-CommandLog))

$content = (($out -join "`n") -replace "`r`n", "`n") + "`n"
Write-Utf8NoBom -Path $evidencePath -Content $content

Write-Output "render-evidence: wrote $evidencePath"
exit 0
