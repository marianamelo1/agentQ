<#
.SYNOPSIS
    render-report.ps1 - deterministically render the agentQ MAIN report
    (templates/report/report-template.md) from workspace JSON artifacts.
    Zero model calls. Also writes report-selection.json (mechanical).

.DESCRIPTION
    There is no report-writing agent. The plain-language judgment comes from
    the agents that already hold the context, produced during the OVERLAPPED
    phase of the run (qa-analyst writes findings[].plain / plainQuestion /
    mergeRiskPlain / whatsGoodBullets into analyst-brief.json; qa-scenario-writer
    writes scenarios' plainTitle; qa-mutation-author writes
    suggestedFix.plainOneLiner), and this script assembles the report from
    those fields VERBATIM in ~1-2s. Same principle as render-evidence.ps1:
    identical input bytes produce identical output bytes, every honesty rule
    (SKIPPED never reads as a pass, evidence-qualified AC claims, fixed icon
    set) is enforced by construction, and the verdict is a reproducible
    mechanical rule instead of a per-run judgment call.

    Verdict rule (the ONLY decision this script makes, and it is mechanical):
    RED "Not ready yet" if ANY of: a failed test in test-results.json; an
    acAlignment grade starting "NOT MET"; a breaking entry in a non-skipped
    contract-report.json; a non-null hardOverride in risk-score.json.
    Otherwise GREEN "Ready to open".

    Plain-language fallbacks: a brief missing the plain fields still renders -
    technical title/detail stand in, honestly, rather than the script
    inventing prose. suggestedFix without plainOneLiner falls back to a fixed
    sentence around its businessRule text; a scenario without plainTitle
    falls back to its title.

    Exit code 0 = the script ran. Non-zero = the script itself could not do
    its job (bad manifest, missing analyst-brief.json, write outside
    reports/). A missing OPTIONAL artifact is honest degraded content in the
    rendered file, never a failure.

.PARAMETER Manifest
    Path to run-manifest.json (workspaceDir, repoSlug, branch, ticketKey).

.PARAMETER ReportPath
    The main-report .md path to write (under reports/). The evidence file the
    footer links to is the same name with "-evidence" before ".md" - written
    separately by render-evidence.ps1.

.PARAMETER BranchSummary
    The mandatory one-sentence plain-language "what this branch does" line -
    intake judgment the orchestrator holds in-conversation; no artifact
    carries it.

.PARAMETER Quick
    The run was --quick (static lanes only) - named in the report header, per
    CLAUDE.md's quick-mode honesty rule.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Manifest,

    [Parameter(Mandatory = $true)]
    [string]$ReportPath,

    [Parameter(Mandatory = $true)]
    [string]$BranchSummary,

    [switch]$Quick
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# -----------------------------------------------------------------------------
# Helpers (same conventions as render-evidence.ps1: Get-Prop returns plainly,
# call sites normalize with @(); no shared module by this codebase's convention)
# -----------------------------------------------------------------------------

function Get-Prop {
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

# -----------------------------------------------------------------------------
# Load + validate manifest, jail the report path to reports/
# -----------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { throw "Manifest not found: $Manifest" }
$man = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json

$workspaceDir = [string](Get-Prop $man 'workspaceDir' '')
if ([string]::IsNullOrWhiteSpace($workspaceDir)) { throw "run-manifest.json has no 'workspaceDir'." }
$workspaceDir = [System.IO.Path]::GetFullPath($workspaceDir)
if (-not (Test-Path -LiteralPath $workspaceDir)) { throw "Manifest workspaceDir does not exist: $workspaceDir" }

$repoSlug  = [string](Get-Prop $man 'repoSlug' '')
$branch    = [string](Get-Prop $man 'branch' '')
$ticketKey = [string](Get-Prop $man 'ticketKey' '')
$repoShort = if ($repoSlug -match '/') { $repoSlug.Split('/')[-1] } else { $repoSlug }

$repoRoot    = Split-Path -Parent $PSScriptRoot
$reportsRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'reports'))
$sep = [System.IO.Path]::DirectorySeparatorChar
$reportPathFull = [System.IO.Path]::GetFullPath($ReportPath)
if (-not $reportPathFull.StartsWith($reportsRoot + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to write: -ReportPath '$reportPathFull' is outside '$reportsRoot'."
}
if (-not $reportPathFull.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "-ReportPath must end in .md (got: $reportPathFull)"
}
$reportName   = [System.IO.Path]::GetFileNameWithoutExtension($reportPathFull)
$evidenceName = "$reportName-evidence.md"

# Date from the report filename's own timestamp (idempotency: same input bytes
# -> same output bytes; live Get-Date only as a fallback for ad hoc names) -
# same rule as render-evidence.ps1.
$renderedAt = Get-Date
$nameMatch = [regex]::Match((Split-Path -Leaf $reportPathFull), '-(\d{4}-\d{2}-\d{2}-\d{4})\.md$')
if ($nameMatch.Success) {
    try {
        $renderedAt = [DateTime]::ParseExact($nameMatch.Groups[1].Value, 'yyyy-MM-dd-HHmm', [System.Globalization.CultureInfo]::InvariantCulture)
    } catch { }
}
$dateStr = $renderedAt.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)

# -----------------------------------------------------------------------------
# Load artifacts (analyst-brief is REQUIRED; everything else degrades honestly)
# -----------------------------------------------------------------------------

function WsPath { param([string]$RelPath) return (Join-Path $workspaceDir $RelPath) }

$brief = Read-JsonOrNull (WsPath 'analyst-brief.json')
if ($null -eq $brief) { throw "analyst-brief.json not found or unreadable in $workspaceDir - the main report cannot be rendered without qa-analyst's brief." }

# Header ticket key: manifest first; fall back to jira-ticket.json's issueKey
# (a manifest written before the ticket key was known has an empty ticketKey
# even when the Jira fetch later succeeded); branch as the last resort.
if ([string]::IsNullOrWhiteSpace($ticketKey)) {
    $jiraForKey = Read-JsonOrNull (WsPath 'jira-ticket.json')
    if ($null -ne $jiraForKey) { $ticketKey = [string](Get-Prop $jiraForKey 'issueKey' '') }
}
$headKey = if ([string]::IsNullOrWhiteSpace($ticketKey)) { $branch } else { $ticketKey }

$riskScore      = Read-JsonOrNull (WsPath 'risk-score.json')
$testResults    = Read-JsonOrNull (WsPath 'test-results.json')
$diffCoverage   = Read-JsonOrNull (WsPath 'diff-coverage.json')
$contractReport = Read-JsonOrNull (WsPath 'contract-report.json')
$impactIndex    = Read-JsonOrNull (WsPath 'impact-index.json')
$manualTests    = Read-JsonOrNull (WsPath 'manual-test-candidates.json')
$mutants        = Read-JsonOrNull (WsPath 'mutants.json')
$strykerSummary = Read-JsonOrNull (WsPath (Join-Path 'stryker' 'summary.json'))
$diffSet        = Read-JsonOrNull (WsPath 'diff-set.json')

$scenarioFiles = @()
$scenariosDir = WsPath 'scenarios'
if (Test-Path -LiteralPath $scenariosDir) {
    $scenarioFiles = @(Get-ChildItem -LiteralPath $scenariosDir -Filter 'scenario-*.json' -File | Sort-Object Name | ForEach-Object {
        Read-JsonOrNull $_.FullName
    }) | Where-Object { $null -ne $_ }
}

$findings  = @(Get-Prop $brief 'findings' @())
$acs       = @(Get-Prop $brief 'acAlignment' @())
$questions = @(Get-Prop $brief 'socraticQuestions' @())
$manualFromBrief = @(Get-Prop $brief 'manualTesting' @())
$whatsGood = @(Get-Prop $brief 'whatsGoodBullets' @())
$mergeRiskPlain = [string](Get-Prop $brief 'mergeRiskPlain' '')

# -----------------------------------------------------------------------------
# Mechanical verdict
# -----------------------------------------------------------------------------

$anyTestFailed = $false
$testsPassed = 0; $testsExecuted = 0; $testsFailedCount = 0
if ($null -ne $testResults) {
    foreach ($r in @(Get-Prop $testResults 'runs' @())) {
        $testsPassed   += [int](Get-Prop $r 'passed' 0)
        $testsExecuted += [int](Get-Prop $r 'testsExecuted' 0)
        $testsFailedCount += [int](Get-Prop $r 'failed' 0)
    }
    $anyTestFailed = $testsFailedCount -gt 0
}
$anyAcNotMet = @($acs | Where-Object { ([string](Get-Prop $_ 'grade' '')) -like 'NOT MET*' }).Count -gt 0
$contractSkipped = ($null -eq $contractReport) -or [bool](Get-Prop $contractReport 'skipped' $false)
$breakingCount = 0
if (-not $contractSkipped) { $breakingCount = @(Get-Prop $contractReport 'breaking' @()).Count }
$anyBreaking = $breakingCount -gt 0
$hardOverride = ''
if ($null -ne $riskScore) { $hardOverride = [string](Get-Prop $riskScore 'hardOverride' '') }

$isRed = $anyTestFailed -or $anyAcNotMet -or $anyBreaking -or ($hardOverride -ne '')
$resultIcon = if ($isRed) { '🔴' } else { '🟢' }
$resultText = if ($isRed) { 'Not ready yet' } else { 'Ready to open' }

# -----------------------------------------------------------------------------
# AC rollup bullet (mechanical composition from the grades - the fixed
# phrasings in the template cover the pure cases; mixed cases compose)
# -----------------------------------------------------------------------------

$acTotal = @($acs).Count
$acMetExecuted = @($acs | Where-Object { ([string](Get-Prop $_ 'grade' '')) -like 'MET — verified by executed*' }).Count
$acMetStatic   = @($acs | Where-Object { ([string](Get-Prop $_ 'grade' '')) -like 'MET — verified (vacuity*' }).Count
$acAppears     = @($acs | Where-Object { ([string](Get-Prop $_ 'grade' '')) -like 'APPEARS MET*' }).Count
$acNotMet      = @($acs | Where-Object { ([string](Get-Prop $_ 'grade' '')) -like 'NOT MET*' }).Count
$acUnverifiable = @($acs | Where-Object { ([string](Get-Prop $_ 'grade' '')) -like 'UNVERIFIABLE*' }).Count
$acMet = $acMetExecuted + $acMetStatic

if ($acTotal -eq 0) {
    $acBullet = '⚠️ Couldn''t check the acceptance criteria — no ticket or pasted criteria were available this run.'
}
elseif ($acNotMet -gt 0) {
    $acBullet = "⚠️ $acNotMet of $acTotal acceptance criteria are not met — see the findings above."
}
else {
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if ($acMet -gt 0) {
        $metPhrase = "$acMet of $acTotal acceptance criteria are met — proven by tests that ran"
        if ($acMetExecuted -eq 0) { $metPhrase += ' (the tests'' independence from the change was judged by reading the code)' }
        $parts.Add($metPhrase)
    }
    if ($acAppears -gt 0) { $parts.Add("$acAppears more appear met from reading the code only, no test proved it") }
    if ($acUnverifiable -gt 0) { $parts.Add("$acUnverifiable couldn't be checked by this review") }
    $icon = if ($acMet -gt 0) { '✅' } else { '⚠️' }
    $acBullet = "$icon " + ($parts -join '; ') + '.'
}

# -----------------------------------------------------------------------------
# Keep-list (mutation suggestedFix entries first, then scenarios by level)
# -----------------------------------------------------------------------------

$keepList = New-Object 'System.Collections.Generic.List[string]'
if ($null -ne $mutants) {
    foreach ($m in @(Get-Prop $mutants 'mutants' @())) {
        if (([string](Get-Prop $m 'status' '')) -ne 'Survived') { continue }
        $fix = Get-Prop $m 'suggestedFix' $null
        if ($null -eq $fix) { continue }
        $line = [string](Get-Prop $fix 'plainOneLiner' '')
        if ($line -eq '') {
            # Pre-Phase-F fix entry: honest fixed-sentence fallback around the
            # mutant's own businessRule text (may read technical; never invented).
            $rule = [string](Get-Prop $m 'businessRule' 'a business rule in the changed code')
            $line = "Strengthens an existing test so this rule can no longer break unnoticed: $rule"
        }
        $keepList.Add($line)
    }
}
$levelOrder = @{ 'unit' = 0; 'component' = 1; 'api' = 2; 'e2e' = 3 }
$sortedScenarios = @($scenarioFiles | Sort-Object { $lv = [string](Get-Prop $_ 'level' 'unit'); if ($levelOrder.ContainsKey($lv)) { $levelOrder[$lv] } else { 9 } })
foreach ($s in $sortedScenarios) {
    $line = [string](Get-Prop $s 'plainTitle' '')
    if ($line -eq '') { $line = [string](Get-Prop $s 'title' 'Generated test (no title recorded)') }
    # GH issue #37: a scenario that was never proven to compile/pass (e.g. its
    # rendered file landed outside every test project and silently never ran)
    # used to list identically to one that actually executed and passed --
    # a developer accepting "keep all" could ship a test that has never even
    # built. EXECUTED_PASSED is the only state that reads as verified; every
    # other value (EXECUTED_FAILED, GENERATED_NOT_EXECUTED, null/missing --
    # e.g. --quick mode or denied execution consent) gets an honest, plain
    # marker instead of silence. Never surfaces executionNote's raw text here
    # (that field is written for the evidence file, not this plain-language one).
    $state = [string](Get-Prop $s 'executionState' '')
    if ($state -ne 'EXECUTED_PASSED') {
        $line += if ($state -eq 'EXECUTED_FAILED') { ' (⚠️ failed when tested — needs a fix before keeping)' }
                 else { ' (⚠️ not proven to work yet this run)' }
    }
    $keepList.Add($line)
}

# -----------------------------------------------------------------------------
# 🔍 What was checked rows (never an omitted row; skipped reads as couldn't check)
# -----------------------------------------------------------------------------

$rowTests = if ($null -eq $testResults) {
    if ($Quick) { '⚠️ couldn''t check — quick review, tests were not run' } else { '⚠️ couldn''t check — the test run produced no results this run' }
} elseif ($anyTestFailed) { "❌ $testsFailedCount of $testsExecuted fail" }
else { "✅ $testsPassed of $testsExecuted pass" }

$mutTested = 0; $mutCaught = 0; $mutSurvived = 0
if ($null -ne $mutants) {
    foreach ($m in @(Get-Prop $mutants 'mutants' @())) {
        $st = [string](Get-Prop $m 'status' '')
        if ($st -eq 'Killed' -or $st -eq 'TimedOut') { $mutCaught++; $mutTested++ }
        elseif ($st -eq 'Survived') { $mutSurvived++; $mutTested++ }
    }
}
if ($null -ne $strykerSummary) {
    foreach ($p in @(Get-Prop $strykerSummary 'projects' @())) {
        if ([bool](Get-Prop $p 'skipped' $false)) { continue }
        $mutCaught += [int](Get-Prop $p 'killed' 0) + [int](Get-Prop $p 'timeout' 0)
        $mutSurvived += [int](Get-Prop $p 'survived' 0)
        $mutTested += [int](Get-Prop $p 'testedMutants' 0)
    }
}
$rowMutation = if ($mutTested -eq 0) {
    if ($Quick) { '⚠️ couldn''t check — quick review, no rules were deliberately broken' } else { '⚠️ couldn''t check — mutation testing didn''t run this run' }
} elseif ($mutSurvived -eq 0) { "✅ yes — all $mutCaught deliberate breaks were caught by a test" }
else { "⚠️ mostly — $mutCaught of $mutTested deliberate breaks were caught; $mutSurvived were not (see the findings)" }

$rowCoverage = if ($null -eq $diffCoverage) { '⚠️ couldn''t check — no coverage data this run' }
elseif ([bool](Get-Prop $diffCoverage 'refused' $false)) { '⚠️ couldn''t check — the coverage tool produced no usable data on this machine (the test results themselves are unaffected)' }
else {
    $lineCov = [double](Get-Prop $diffCoverage 'lineDiffCoverage' 0)
    $outOf10 = [int][math]::Round($lineCov * 10)
    "about $outOf10 in 10 changed lines run under a test related to this branch"
}

$rowContract = if ($contractSkipped) { '⏭️ not needed — this change doesn''t touch any API other systems call' }
elseif ($anyBreaking) { "❌ breaking — $breakingCount change(s) that break anyone already using this API (see the findings)" }
else { '✅ safe — no breaking change to the documented API' }

$rowAc = $acBullet

$fanIn = [string](Get-Prop (Get-Prop $brief 'summaryCounts' $null) 'crossRepoFanIn' '')
$manualCandCount = 0
$manualStatus = ''
if ($null -ne $manualTests) {
    $manualStatus = [string](Get-Prop $manualTests 'status' '')
    $manualCandCount = @(Get-Prop $manualTests 'candidates' @()).Count
}
$rowImpact = if ($null -eq $impactIndex -and $null -eq $manualTests) { '⚠️ couldn''t check — the impact and manual-test lanes didn''t run this run' }
else {
    $bits = New-Object 'System.Collections.Generic.List[string]'
    if ($fanIn -ne '') { $bits.Add($fanIn.TrimEnd('.')) } elseif ($null -ne $impactIndex) { $bits.Add('impact scan ran (candidates only — a search isn''t proof nothing else is affected)') }
    if ($null -ne $manualTests) {
        # Curated count (qa-analyst's manualTesting[], which already dropped any keyword hit
        # whose own scenario doesn't genuinely relate to this diff) - not the raw candidate
        # count, which can include matches the analyst judged not worth surfacing.
        $manualCuratedCount = @(Get-Prop $brief 'manualTesting' @()).Count
        if ($manualCuratedCount -gt 0) { $bits.Add("$manualCuratedCount manual test(s) look worth running by hand — see below") }
        elseif ($manualCandCount -gt 0) { $bits.Add("$manualCandCount manual test candidate(s) found, none judged directly relevant enough to run by hand — see evidence file") }
        elseif ($manualStatus -like 'SKIPPED*' -or $manualStatus -like 'DEGRADED*') { $bits.Add("manual-test lookup: $manualStatus") }
        else { $bits.Add('no manual-test suggestions came up') }
    }
    '✅ ' + ($bits -join '; ')
}

$frontendTouched = $false
if ($null -ne $diffSet) { $frontendTouched = [bool](Get-Prop (Get-Prop $diffSet 'levels' $null) 'frontend' $false) }
$rowUi = if (-not $frontendTouched) { '⏭️ not needed — no frontend code changed' }
else { '⚠️ couldn''t check in-run — frontend was touched; see the evidence file''s E2E section for what ran' }

# -----------------------------------------------------------------------------
# Compose the report
# -----------------------------------------------------------------------------

$L = New-Object 'System.Collections.Generic.List[string]'
function Add-Line { param([string]$Text = '') $L.Add($Text) | Out-Null }

$quickNote = if ($Quick) { ' · quick review (static checks only — no tests were executed)' } else { '' }
Add-Line "# 🧾 QA review — $repoShort · $headKey"
Add-Line ''
Add-Line ('`' + $branch + '`' + " · $dateStr$quickNote · **Result: $resultIcon $resultText**")
Add-Line ''
Add-Line "**🧭 What this branch does:** $BranchSummary"
Add-Line ''

$selFindings = @($findings | Select-Object -First 3)
if (@($selFindings).Count -eq 0) {
    Add-Line '## ✅ Nothing blocking found'
    Add-Line ''
} else {
    Add-Line "## ❌ $(@($selFindings).Count) things to fix first"
    Add-Line ''
    $n = 0
    foreach ($f in $selFindings) {
        $n++
        $plain = Get-Prop $f 'plain' $null
        $pTitle = ''; $pCons = ''; $pDo = ''
        if ($plain -is [string]) {
            # Off-spec shape: `plain` written as one free-text paragraph instead
            # of {title, consequence, doThis} - degrade honestly instead of
            # silently discarding real content: the whole string is genuine
            # analyst prose, just not split the way the template needs. Use its
            # first sentence as a title rather than inventing one or printing a
            # bare "(untitled finding)" that reads like an error.
            $sentenceEnd = $plain.IndexOf('. ')
            if ($sentenceEnd -gt 0 -and $sentenceEnd -lt 120) {
                $pTitle = $plain.Substring(0, $sentenceEnd)
                $pCons = $plain.Substring($sentenceEnd + 2)
            } else {
                $pCons = $plain
            }
        } else {
            $pTitle = [string](Get-Prop $plain 'title' '')
            $pCons  = [string](Get-Prop $plain 'consequence' '')
            $pDo    = [string](Get-Prop $plain 'doThis' '')
        }
        if ($pTitle -eq '') { $pTitle = [string](Get-Prop $f 'title' '') }
        if ($pTitle -eq '') { $pTitle = "Finding $n" }
        if ($pCons -eq '')  { $pCons  = [string](Get-Prop $f 'detail' '') }
        Add-Line "**$n. $pTitle**"
        Add-Line $pCons
        if ($pDo -ne '') {
            Add-Line ''
            Add-Line ('🛠️ **Do this:** ' + $pDo)
        }
        Add-Line ''
    }
}

Add-Line '## ✅ What''s good'
Add-Line ''
Add-Line "- $acBullet"
foreach ($b in $whatsGood) {
    $bt = [string]$b
    if ($bt -eq '') { continue }
    if ($bt.StartsWith('✅') -or $bt.StartsWith('⚠️')) { Add-Line "- $bt" } else { Add-Line "- ✅ $bt" }
}
Add-Line ''

if ($null -ne $riskScore) {
    $band = [string](Get-Prop $riskScore 'band' '')
    $why = $mergeRiskPlain
    if ($why -eq '') {
        $missing = @(Get-Prop $riskScore 'missingSignals' @())
        $why = 'scored from this diff''s own evidence'
        if (@($missing).Count -gt 0) { $why += " — and $(@($missing).Count) signal(s) couldn't be checked this run, so confidence is lower" }
        $why += '.'
    }
    Add-Line "**⚖️ Merge risk: $band** — $why"
} else {
    Add-Line '**⚖️ Merge risk: ⚠️ couldn''t check** — the risk score wasn''t computed this run.'
}
Add-Line ''

$selQuestions = @($questions | Select-Object -First 3)
if (@($selQuestions).Count -gt 0) {
    Add-Line '## ❓ Questions for the team'
    Add-Line ''
    $qn = 0
    foreach ($q in $selQuestions) {
        $qn++
        $pq = [string](Get-Prop $q 'plainQuestion' '')
        if ($pq -eq '') { $pq = [string](Get-Prop $q 'question' '') }
        Add-Line "$qn. $pq"
    }
    Add-Line ''
}

$manualUrlById = @{}
foreach ($mc in @(Get-Prop $manualTests 'candidates' @())) {
    $mcId = [string](Get-Prop $mc 'id' '')
    if ($mcId -ne '') { $manualUrlById[$mcId] = [string](Get-Prop $mc 'url' '') }
}
$manualShown = @($manualFromBrief | Select-Object -First 3)
if (@($manualShown).Count -gt 0) {
    Add-Line '## 🖐️ Worth checking by hand'
    Add-Line ''
    foreach ($mt in $manualShown) {
        $why = [string](Get-Prop $mt 'why' '')
        $title = [string](Get-Prop $mt 'title' '')
        $mtId = [string](Get-Prop $mt 'id' '')
        $line = if ($why -ne '') { $why } else { $title }
        $url = if ($manualUrlById.ContainsKey($mtId)) { $manualUrlById[$mtId] } else { '' }
        if ($url -ne '') {
            $line = "$($line.TrimEnd('.', ' ')). [Check this scenario]($url)."
        }
        Add-Line "- $line"
    }
    $moreCount = @($manualFromBrief).Count - @($manualShown).Count
    if ($manualCandCount -gt @($manualFromBrief).Count) { $moreCount = $manualCandCount - @($manualShown).Count }
    if ($moreCount -gt 0) { Add-Line "- +$moreCount more in the evidence file" }
    Add-Line ''
}

Add-Line '## 🔍 What was checked'
Add-Line ''
Add-Line '| Check | Result |'
Add-Line '|---|---|'
Add-Line "| Existing tests around this change | $rowTests |"
Add-Line "| Would tests catch a deliberately broken rule? | $rowMutation |"
Add-Line "| Changed code that runs under tests | $rowCoverage |"
Add-Line "| Public API compatibility | $rowContract |"
Add-Line "| Ticket acceptance criteria | $rowAc |"
Add-Line "| Other repos / suggested manual tests | $rowImpact |"
Add-Line "| UI tests | $rowUi |"
Add-Line ''

if ($keepList.Count -gt 0) {
    Add-Line "## 🧪 Ready-made tests ($($keepList.Count)) — keep them?"
    Add-Line ''
    Add-Line 'They only touch your repo if you say yes and review the diff.'
    Add-Line ''
    $kn = 0
    foreach ($k in $keepList) {
        $kn++
        Add-Line "$kn. $k"
    }
    Add-Line ''
    Add-Line 'Reply with the ones to keep, or "none".'
} else {
    Add-Line '## 🧪 Ready-made tests'
    Add-Line ''
    Add-Line 'No ready-made tests this run.'
}
Add-Line ''
Add-Line "📄 *Full technical detail (files, line numbers, timings, risk formula): [$evidenceName]($evidenceName)*"
Add-Line ''

Write-Utf8NoBom -Path $reportPathFull -Content (($L.ToArray()) -join "`n")

# -----------------------------------------------------------------------------
# report-selection.json (mechanical: analyst's own priority order, top <=3)
# -----------------------------------------------------------------------------

$selFindingIds = @($selFindings | ForEach-Object { Get-Prop $_ 'id' 0 })
$selQuestionIds = @($selQuestions | ForEach-Object { Get-Prop $_ 'id' 0 })
$selection = [ordered]@{
    resultIcon = $resultIcon
    resultText = $resultText
    selectedFindingIds = @($selFindingIds)
    questionIds = @($selQuestionIds)
}
Write-Utf8NoBom -Path (WsPath 'report-selection.json') -Content (ConvertTo-Json -InputObject $selection -Depth 4)

Write-Output ("render-report: wrote {0} (Result: {1} {2}) + report-selection.json" -f $reportPathFull, $resultIcon, $resultText)
