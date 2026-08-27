<#
.SYNOPSIS
    report-pack.ps1 - deterministically assemble the inline evidence pack for
    an agentQ agent dispatch (qa-report-synthesizer by default, or qa-analyst).

.DESCRIPTION
    Phase D2 of the run-time reduction work: composing the report-writer's
    dispatch prompt by hand was one of the longest single orchestrator turns
    in a run (the prompt is ~2 pages of curated content pulled from 5+
    artifacts). This script does that assembly mechanically instead - same
    "deterministic script does the mechanical part" principle as
    render-evidence.ps1, just aimed at a dispatch PROMPT instead of the
    evidence FILE. Emits one ready-to-paste markdown block to stdout.

    -For report (default): everything qa-report-synthesizer needs except the
    handful of things only the orchestrator knows at dispatch time (the
    branch's one-sentence summary, consent outcomes, anything that happened
    mid-run) - those stay a short manual addition to the dispatch prompt.

    -For analyst: diff hunks (real `git diff` text against baseSha, not just
    line ranges - diff-set.json only carries hunk line numbers) + the
    adapter-profile one-line summary + the impact/manual lane results
    (impact-index.json, testomat-candidates.json, manual-test-candidates.json -
    all written before Phase 4's dispatch, so inlining them removes 3 reads
    from the agent's budget) + the workspace dir path. Deliberately does NOT
    include test-results.json/diff-coverage.json/mutation-report.json (they
    don't exist yet at dispatch time - the agent overlaps the test run and
    reads them lazily) nor AC text or intake's citations - those are
    qa-intake's OWN judgment, produced in conversation, not a JSON artifact
    this script can read; the orchestrator appends them from intake's brief,
    per SKILL.md.

    Every artifact is optional - a run under --quick, a denied mutation
    consent, or a skipped Phase 1b/1c lane all produce a missing file, which
    this script reflects as an honest "not available this run" line, never a
    silent omission or a fabricated value.

    Exit code 0 = the script ran (a missing artifact is reflected in the pack,
    not a script failure). Non-zero = the manifest itself couldn't be read.

.PARAMETER Manifest
    Path to run-manifest.json (repoSlug, branch, ticketKey, workspaceDir, ...).

.PARAMETER For
    'report' (default) or 'analyst' - which dispatch this pack is for.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Manifest,

    [ValidateSet('report', 'analyst')]
    [string]$For = 'report'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# -----------------------------------------------------------------------------
# Helpers (Get-Prop / Read-JsonOrNull copied verbatim from render-evidence.ps1 -
# self-contained scripts, no shared module, per this codebase's convention)
# -----------------------------------------------------------------------------

function Get-Prop {
    # WHY plain `return $p.Value`, not a comma-wrapped return: every call site
    # in THIS script wraps the result in @() itself when it needs an array -
    # combining that with an already-array-preserving comma-return double-wraps
    # (see render-evidence.ps1's own note on this exact trap).
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
    # A missing or unparseable artifact becomes $null uniformly - every
    # section builder below treats $null as "not available this run" and
    # renders that honestly, never throws for a run that skipped a phase.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Format-Pct {
    # Manual integer-math percentage, not {0:P0} - verified elsewhere in this
    # project that P0 is culture-dependent even under InvariantCulture (emits
    # "54 %" with a space on some locales, not "54%").
    param([double]$Fraction)
    return "$([int][math]::Round($Fraction * 100))%"
}

function Join-NonEmpty {
    param([string[]]$Parts, [string]$Sep = "`n")
    return (@($Parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join $Sep)
}

# -----------------------------------------------------------------------------
# Load manifest
# -----------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { throw "Manifest not found: $Manifest" }
$man = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json

$workspaceDir = [string](Get-Prop $man 'workspaceDir' '')
if ([string]::IsNullOrWhiteSpace($workspaceDir)) { throw "run-manifest.json has no 'workspaceDir'." }
$repoSlug  = [string](Get-Prop $man 'repoSlug' '')
$branch    = [string](Get-Prop $man 'branch' '')
$ticketKey = [string](Get-Prop $man 'ticketKey' '')
$repoPath  = [string](Get-Prop $man 'repoPath' '')
$baseSha   = [string](Get-Prop $man 'baseSha' '')

function WsPath { param([string]$RelPath) return (Join-Path $workspaceDir $RelPath) }

$lines = New-Object 'System.Collections.Generic.List[string]'
function Add-Line { param([string]$Text = '') $lines.Add($Text) | Out-Null }

# =============================================================================
# -For analyst: diff hunks + adapter-profile summary + workspace path only.
# =============================================================================
if ($For -eq 'analyst') {
    Add-Line "## Workspace"
    Add-Line "- workspaceDir: $workspaceDir"
    Add-Line "- repo: $repoSlug - branch: $branch$(if ($ticketKey) { " - ticket: $ticketKey" })"
    Add-Line ''

    $diffSet = Read-JsonOrNull (WsPath 'diff-set.json')
    # Collected while walking the diff below; emitted as its own section after it.
    # WHY (GH issue #32): qa-mutation-author must promote any `const` in scope to a
    # static property before it can host an AGENTQ_MUTANT switch -- pre-listing the
    # sites here means the agent holds less un-written state before its first
    # mutants.json checkpoint, instead of re-deriving the promotion surgery itself.
    $constSites = New-Object 'System.Collections.Generic.List[string]'
    Add-Line "## Diff hunks (git diff against baseSha $baseSha)"
    if ($null -eq $diffSet) {
        Add-Line "NOT AVAILABLE - diff-set.json not found in workspace."
    } else {
        $changedFiles = @(Get-Prop $diffSet 'files' @()) | ForEach-Object { [string](Get-Prop $_ 'path' '') } | Where-Object { $_ -ne '' }
        $untracked = @(Get-Prop $diffSet 'untracked' @()) | ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' }
        if (@($changedFiles).Count -eq 0 -and @($untracked).Count -eq 0) {
            Add-Line "No changed or untracked files in diff-set.json."
        }
        foreach ($f in $changedFiles) {
            Add-Line ''
            Add-Line "### $f (changed)"
            if ([string]::IsNullOrWhiteSpace($repoPath) -or -not (Test-Path -LiteralPath $repoPath)) {
                Add-Line '```diff'
                Add-Line "(repoPath not available - cannot run git diff for this file)"
                Add-Line '```'
                continue
            }
            $diffText = ''
            try {
                $diffText = (& git -C $repoPath diff --unified=2 "$baseSha" -- "$f" 2>&1 | Out-String)
            } catch { $diffText = '' }
            Add-Line '```diff'
            if ([string]::IsNullOrWhiteSpace($diffText)) { Add-Line '(no diff text produced - file may be binary or the path may have moved)' }
            else { Add-Line $diffText.TrimEnd() }
            Add-Line '```'
            if ($f -like '*.cs' -and -not [string]::IsNullOrWhiteSpace($diffText)) {
                foreach ($dl in ($diffText -split "`n")) {
                    # Added lines only ('+' but not the '+++' file header): a const
                    # the diff itself introduces or touches is exactly the site the
                    # mutation agent may need to promote.
                    if ($dl -match '^\+(?!\+\+)' -and $dl -match '\bconst\s+\w') {
                        $constSites.Add("- $f : ``$($dl.Substring(1).Trim())``") | Out-Null
                    }
                }
            }
        }
        foreach ($f in $untracked) {
            Add-Line ''
            Add-Line "### $f (untracked - new file)"
            $fullPath = Join-Path $repoPath $f
            if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                $content = ''
                try { $content = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8 } catch { $content = '' }
                $ext = [System.IO.Path]::GetExtension($f).TrimStart('.')
                Add-Line ('```' + $ext)
                Add-Line $content.TrimEnd()
                Add-Line '```'
                if ($f -like '*.cs' -and -not [string]::IsNullOrWhiteSpace($content)) {
                    $lineNo = 0
                    foreach ($cl in ($content -split "`n")) {
                        $lineNo++
                        if ($cl -match '\bconst\s+\w') {
                            $constSites.Add("- $f`:$lineNo : ``$($cl.Trim())``") | Out-Null
                        }
                    }
                }
            } else {
                Add-Line '(file not found on disk)'
            }
        }
    }
    Add-Line ''

    # For the qa-mutation-author dispatch (same pack, per SKILL.md step 4);
    # qa-analyst/qa-scenario-writer can ignore this section.
    Add-Line "## Const declarations in the diff (mutation-injection mechanics)"
    if ($constSites.Count -eq 0) {
        Add-Line "None found in the changed/untracked C# lines - no const -> static-property promotion needed for AGENTQ_MUTANT switches."
    } else {
        Add-Line "A ``const`` cannot host an AGENTQ_MUTANT env-var switch - each site below needs promoting to a static property (worktree copy only, use sites updated) if it hosts a mutant:"
        foreach ($cs in $constSites) { Add-Line $cs }
    }
    Add-Line ''

    $adapterProfiles = Read-JsonOrNull (WsPath 'adapter-profiles.json')
    Add-Line "## Adapter profile summary"
    if ($null -eq $adapterProfiles) {
        Add-Line "NOT AVAILABLE - adapter-profiles.json not found (intake may not have completed)."
    } else {
        $fromCache = [bool](Get-Prop $adapterProfiles 'fromCache' $false)
        foreach ($p in @(Get-Prop $adapterProfiles 'projects' @())) {
            $proj = [string](Get-Prop $p 'projectPath' '')
            $fw = [string](Get-Prop $p 'framework' '')
            $runner = [string](Get-Prop $p 'runner' '')
            $dialect = [string](Get-Prop $p 'assertionDialect' '')
            $scope = [string](Get-Prop $p 'suiteScope' 'diff-sensitive')
            Add-Line "- $proj - $fw/$runner, $dialect$(if ($scope -ne 'diff-sensitive') { " ($scope)" })"
        }
        if ($fromCache) { Add-Line "(adapter-profile cache HIT this run)" }
    }
    Add-Line ''

    # Impact/manual lanes - written by Phase 1b/1c BEFORE this dispatch, so
    # inlining them here removes 3 reads from the agent's budget. The lazy-read
    # trio (test-results/diff-coverage/mutation-report) stays out on purpose:
    # those don't exist yet at dispatch time (the agent overlaps the test run).
    $impactIndex = Read-JsonOrNull (WsPath 'impact-index.json')
    Add-Line "## Impact index (Phase 1b - inline, do not re-read impact-index.json)"
    if ($null -eq $impactIndex) {
        Add-Line "NOT AVAILABLE - impact-index.json not found (phase disabled by config, or intake incomplete)."
    } else {
        $seeds = @(Get-Prop $impactIndex 'seeds' @())
        Add-Line "- Seeds: $(@($seeds | ForEach-Object { [string](Get-Prop $_ 'value' '') } | Where-Object { $_ -ne '' }) -join ', ')"
        $scanned = @(Get-Prop $impactIndex 'scanned' @()) | ForEach-Object {
            # entries are objects ({repoSlug, files, seconds}) in current runs; keep a
            # plain-string fallback for any older artifact shape
            if ($_ -is [string]) { $_ } else { [string](Get-Prop $_ 'repoSlug' '') }
        } | Where-Object { $_ -ne '' }
        if (@($scanned).Count -gt 0) { Add-Line "- Repos scanned: $($scanned -join ', ')" }
        $allMatches = @(Get-Prop $impactIndex 'matches' @())
        if (@($allMatches).Count -eq 0) {
            Add-Line "- Matches: none - no reference to the changed code found in any scanned repo (no signal != not affected)."
        } else {
            foreach ($grp in ($allMatches | Group-Object { [string](Get-Prop $_ 'repoSlug' '') } | Sort-Object Name)) {
                Add-Line "- $($grp.Name): $($grp.Count) match(es) (candidates - keyword evidence, never verified impact)"
                $shown = @($grp.Group | Select-Object -First 5)
                foreach ($m in $shown) {
                    Add-Line "  - $([string](Get-Prop $m 'file' '')):$(Get-Prop $m 'line' '?') - $([string](Get-Prop $m 'context' '')) [seed: $([string](Get-Prop $m 'seed' ''))]"
                }
                if ($grp.Count -gt 5) { Add-Line "  - +$($grp.Count - 5) more in impact-index.json" }
            }
        }
    }
    Add-Line ''

    $testomat = Read-JsonOrNull (WsPath 'testomat-candidates.json')
    Add-Line "## Testomat candidates (inline, do not re-read testomat-candidates.json)"
    if ($null -eq $testomat) {
        Add-Line "NOT AVAILABLE - testomat-candidates.json not found (impact phase disabled by config)."
    } else {
        $tStatus = [string](Get-Prop $testomat 'status' '')
        $tCands = @(Get-Prop $testomat 'candidates' @())
        if ($tStatus -and $tStatus -ne 'RAN') { Add-Line "- Status: $tStatus" }
        elseif (@($tCands).Count -eq 0) { Add-Line "- No candidates matched the seeds/ticket." }
        else {
            foreach ($c in @($tCands | Select-Object -First 5)) {
                Add-Line "- $([string](Get-Prop $c 'title' '')) (matched by: $([string](Get-Prop $c 'matchedBy' '')))"
            }
            if (@($tCands).Count -gt 5) { Add-Line "- +$(@($tCands).Count - 5) more in testomat-candidates.json" }
        }
    }
    Add-Line ''

    $manualTests = Read-JsonOrNull (WsPath 'manual-test-candidates.json')
    Add-Line "## Manual-test candidates (Phase 1c - inline, do not re-read manual-test-candidates.json)"
    if ($null -eq $manualTests) {
        Add-Line "NOT AVAILABLE - manual-test-candidates.json not found (phase disabled by config)."
    } else {
        $mStatus = [string](Get-Prop $manualTests 'status' '')
        $mCands = @(Get-Prop $manualTests 'candidates' @())
        if ($mStatus -and $mStatus -ne 'RAN') { Add-Line "- Status: $mStatus" }
        elseif (@($mCands).Count -eq 0) { Add-Line "- No manual-test candidates matched the seeds/ticket." }
        else {
            foreach ($c in @($mCands | Select-Object -First 5)) {
                Add-Line "- $([string](Get-Prop $c 'title' '')) (matched by: $([string](Get-Prop $c 'matchedBy' '')))"
            }
            if (@($mCands).Count -gt 5) { Add-Line "- +$(@($mCands).Count - 5) more in manual-test-candidates.json" }
        }
    }
    Add-Line ''

    Add-Line "## Reminder for the orchestrator (not mechanical - add before dispatch)"
    Add-Line "- AC text verbatim (from qa-intake's own brief - not a JSON artifact)"
    Add-Line "- Intake's already-cited file:line evidence"

    Write-Output (Join-NonEmpty -Parts @($lines.ToArray()) -Sep "`n")
    exit 0
}

# =============================================================================
# -For report (default): the full pack for qa-report-synthesizer.
# =============================================================================

$analystBrief   = Read-JsonOrNull (WsPath 'analyst-brief.json')
$riskScore      = Read-JsonOrNull (WsPath 'risk-score.json')
$jiraTicket     = Read-JsonOrNull (WsPath 'jira-ticket.json')
$jiraParent     = Read-JsonOrNull (WsPath 'jira-ticket-parent.json')
$mutants        = Read-JsonOrNull (WsPath 'mutants.json')
$strykerSummary = Read-JsonOrNull (WsPath (Join-Path 'stryker' 'summary.json'))
$testResults    = Read-JsonOrNull (WsPath 'test-results.json')
$diffCoverage   = Read-JsonOrNull (WsPath 'diff-coverage.json')
$contractReport = Read-JsonOrNull (WsPath 'contract-report.json')
$impactIndex    = Read-JsonOrNull (WsPath 'impact-index.json')
$testomat       = Read-JsonOrNull (WsPath 'testomat-candidates.json')
$manualTests    = Read-JsonOrNull (WsPath 'manual-test-candidates.json')

$scenarioFiles = @()
$scenariosDir = WsPath 'scenarios'
if (Test-Path -LiteralPath $scenariosDir) {
    $scenarioFiles = @(Get-ChildItem -LiteralPath $scenariosDir -Filter 'scenario-*.json' -File | ForEach-Object {
        Read-JsonOrNull $_.FullName
    }) | Where-Object { $null -ne $_ }
}

# ---- Run identity -----------------------------------------------------------
Add-Line "## Run identity"
$ticketSummary = [string](Get-Prop $jiraTicket 'summary' '')
$identityLine = "- Repo: $repoSlug - Branch: $branch"
if ($ticketKey) {
    $identityLine += " - Ticket: $ticketKey"
    if ($ticketSummary) { $identityLine += ' -- "' + $ticketSummary + '"' }
}
Add-Line $identityLine
Add-Line "- (Orchestrator adds: one-sentence 'what this branch does', in plain language)"
Add-Line ''

# ---- Execution summary -------------------------------------------------------
Add-Line "## Execution summary"

if ($null -eq $testResults) {
    Add-Line "- Unit tests: NOT RUN this run (quick mode, or Phase 2 skipped)."
} else {
    $runs = @(Get-Prop $testResults 'runs' @())
    $totalPassed = 0; $totalExecuted = 0; $totalFailed = 0
    foreach ($r in $runs) {
        $totalPassed += [int](Get-Prop $r 'passed' 0)
        $totalExecuted += [int](Get-Prop $r 'testsExecuted' 0)
        $totalFailed += [int](Get-Prop $r 'failed' 0)
    }
    $projCount = @($runs).Count
    Add-Line "- Unit tests: $totalPassed/$totalExecuted passed across $projCount test project(s)$(if ($totalFailed -gt 0) { " - **$totalFailed FAILED**" })."
    $flaky = @(Get-Prop (Get-Prop $testResults 'flaky' $null) 'mightBeFlaky' @())
    if (@($flaky).Count -gt 0) {
        foreach ($f in $flaky) {
            Add-Line "  - FAILED, might be flaky: $([string](Get-Prop $f 'fqn' '')) - rerun: ``$([string](Get-Prop $f 'rerunCommand' ''))``"
        }
    }
}

if ($null -eq $diffCoverage) {
    Add-Line "- Diff coverage: NOT AVAILABLE this run."
} elseif ([bool](Get-Prop $diffCoverage 'refused' $false)) {
    Add-Line "- Diff coverage: REFUSED - $([string](Get-Prop $diffCoverage 'refusalReason' 'low file-resolution ratio'))."
} else {
    $lineCov = [double](Get-Prop $diffCoverage 'lineDiffCoverage' 0)
    $branchCov = [double](Get-Prop $diffCoverage 'branchDiffCoverage' 0)
    Add-Line "- Diff coverage: $(Format-Pct $lineCov) of changed lines run under a related test (branch coverage $(Format-Pct $branchCov))."
}

if ($null -eq $mutants -and $null -eq $strykerSummary) {
    Add-Line "- Mutation testing: NOT RUN this run (consent denied, or nothing worth mutating)."
} else {
    $semKilled = 0; $semSurvived = 0; $semSurvivedWithFix = 0
    if ($null -ne $mutants) {
        foreach ($m in @(Get-Prop $mutants 'mutants' @())) {
            $st = [string](Get-Prop $m 'status' '')
            if ($st -eq 'Killed') { $semKilled++ }
            elseif ($st -eq 'Survived') {
                $semSurvived++
                if ($null -ne (Get-Prop $m 'suggestedFix' $null)) { $semSurvivedWithFix++ }
            }
        }
        Add-Line "- Mutation testing (AI business-rule tier): $semKilled killed / $semSurvived survived$(if ($semSurvivedWithFix -gt 0) { " ($semSurvivedWithFix with a drafted suggestedFix already in mutants.json)" })."
    }
    if ($null -ne $strykerSummary) {
        $mechKilled = 0; $mechSurvived = 0; $mechTimeout = 0; $mechTested = 0; $mechTotal = 0
        foreach ($p in @(Get-Prop $strykerSummary 'projects' @())) {
            if ([bool](Get-Prop $p 'skipped' $false)) { continue }
            $mechKilled += [int](Get-Prop $p 'killed' 0)
            $mechSurvived += [int](Get-Prop $p 'survived' 0)
            $mechTimeout += [int](Get-Prop $p 'timeout' 0)
            $mechTested += [int](Get-Prop $p 'testedMutants' 0)
            $mechTotal += [int](Get-Prop $p 'totalMutants' 0)
        }
        Add-Line "- Mutation testing (Stryker mechanical tier): $mechKilled killed / $mechSurvived survived / $mechTimeout timeout ($mechTested of $mechTotal mutants tested - scoped to diff-related tests, per testCaseFilter)."
    }
}

$scenariosByLevel = @{}
foreach ($s in $scenarioFiles) {
    $lvl = [string](Get-Prop $s 'level' 'unit')
    if (-not $scenariosByLevel.ContainsKey($lvl)) { $scenariosByLevel[$lvl] = 0 }
    $scenariosByLevel[$lvl]++
}
if (@($scenarioFiles).Count -eq 0) {
    Add-Line "- Generated tests: none this run (scenario cache was warm, or no gap found)."
} else {
    $execPassed = @($scenarioFiles | Where-Object { [string](Get-Prop $_ 'executionState' '') -eq 'EXECUTED_PASSED' }).Count
    $vacProven = @($scenarioFiles | Where-Object { [string](Get-Prop $_ 'vacuityGrade' '') -eq 'verified_non_compiling_on_base' -or [string](Get-Prop $_ 'vacuityGrade' '') -eq 'verified_against_base' }).Count
    Add-Line "- Generated tests: $(@($scenarioFiles).Count) scenario(s) ($($scenariosByLevel.Keys -join ', ')) - $execPassed executed and passed, $vacProven proven non-vacuous against base."
}

if ($null -eq $contractReport) {
    Add-Line "- Contract lane: SKIPPED - diff does not touch API surface, or not a service repo."
} elseif ([bool](Get-Prop $contractReport 'skipped' $false)) {
    Add-Line "- Contract lane: SKIPPED - $([string](Get-Prop $contractReport 'skipReason' ''))."
} else {
    $breaking = @(Get-Prop $contractReport 'breaking' @())
    Add-Line "- Contract lane: $(@($breaking).Count) breaking change(s) to the documented API contract."
}

if ($null -ne $impactIndex) {
    $matches = @(Get-Prop $impactIndex 'matches' @())
    Add-Line "- Impact: $(@($matches).Count) cross-repo/same-repo reference(s) found (candidates, not verified impact)."
} else {
    Add-Line "- Impact: not run this run (disabled by config, or no manual-test analysis needed either)."
}

if ($null -ne $manualTests) {
    $status = [string](Get-Prop $manualTests 'status' '')
    if ($status) { Add-Line "- Manual testing candidates: $status." }
    else {
        $cands = @(Get-Prop $manualTests 'candidates' @())
        Add-Line "- Manual testing candidates: $(@($cands).Count) found."
    }
}

if ($null -eq $riskScore) {
    Add-Line "- Risk score: NOT COMPUTED this run."
} else {
    $score = [int](Get-Prop $riskScore 'score' 0)
    $band = [string](Get-Prop $riskScore 'band' '')
    $conf = [string](Get-Prop $riskScore 'confidence' '')
    $override = Get-Prop $riskScore 'hardOverride' $null
    $missing = @(Get-Prop $riskScore 'missingSignals' @())
    $overrideNote = if ($null -ne $override -and $override -ne '') { " (hard override: $override)" } else { '' }
    Add-Line "- Risk score: $score/100, band `"$band`"$overrideNote, confidence $conf$(if (@($missing).Count -gt 0) { " ($(@($missing).Count) signal(s) unavailable: $($missing -join ', '))" })."
}
Add-Line ''

# ---- Findings -----------------------------------------------------------
Add-Line "## Findings (qa-analyst, ranked - pick up to 3 for the report)"
if ($null -eq $analystBrief) {
    Add-Line "NOT AVAILABLE - analyst-brief.json not found (qa-analyst may not have completed)."
} else {
    $findings = @(Get-Prop $analystBrief 'findings' @())
    if (@($findings).Count -eq 0) {
        Add-Line "None - qa-analyst found nothing to flag this run."
    }
    foreach ($f in $findings) {
        $id = Get-Prop $f 'id' 0
        $sev = [string](Get-Prop $f 'severity' '')
        $title = [string](Get-Prop $f 'title' '')
        $file = [string](Get-Prop $f 'file' '')
        $line = Get-Prop $f 'line' $null
        $detail = [string](Get-Prop $f 'detail' '')
        $impactNote = Get-Prop $f 'impactNote' $null
        Add-Line "$id. **[$sev]** $title"
        Add-Line "   $file$(if ($null -ne $line) { ":$line" })"
        Add-Line "   $detail"
        if ($null -ne $impactNote -and $impactNote -ne '') { Add-Line "   Impact: $impactNote" }
        Add-Line ''
    }
}

# ---- Acceptance criteria -----------------------------------------------------
Add-Line "## Acceptance criteria (verbatim grades from qa-analyst - use as-is, do not re-derive)"
if ($null -eq $analystBrief) {
    Add-Line "NOT AVAILABLE."
} else {
    $acs = @(Get-Prop $analystBrief 'acAlignment' @())
    if (@($acs).Count -eq 0) {
        Add-Line "No ACs graded this run (no ticket/AC source, or AC-alignment UNVERIFIABLE)."
    }
    foreach ($ac in $acs) {
        $acId = [string](Get-Prop $ac 'ac' '')
        $text = [string](Get-Prop $ac 'text' '')
        $grade = [string](Get-Prop $ac 'grade' '')
        $evidence = [string](Get-Prop $ac 'evidence' '')
        Add-Line "- $acId ($text): $grade -- $evidence"
    }
    $sc = Get-Prop $analystBrief 'summaryCounts' $null
    if ($null -ne $sc) {
        $acMet = Get-Prop $sc 'acMet' 0
        $acTotal = Get-Prop $sc 'acTotal' 0
        $acStatic = Get-Prop $sc 'acStaticOnly' 0
        $acUnverifiable = Get-Prop $sc 'acUnverifiable' 0
        Add-Line "- Summary: $acMet/$acTotal MET, $acStatic static-only, $acUnverifiable unverifiable."
        $fanIn = Get-Prop $sc 'crossRepoFanIn' $null
        if ($null -ne $fanIn -and $fanIn -ne '') { Add-Line "- Cross-repo fan-in: $fanIn" }
    }
}
Add-Line ''

# ---- Questions for the team -----------------------------------------------------
Add-Line "## Questions for the team (qa-analyst's Socratic questions - pick up to 3)"
if ($null -eq $analystBrief) {
    Add-Line "NOT AVAILABLE."
} else {
    $questions = @(Get-Prop $analystBrief 'socraticQuestions' @())
    if (@($questions).Count -eq 0) {
        Add-Line "None raised this run."
    }
    foreach ($q in $questions) {
        $qId = Get-Prop $q 'id' 0
        $qText = [string](Get-Prop $q 'question' '')
        $qEvidence = [string](Get-Prop $q 'evidence' '')
        Add-Line "$qId. $qText"
        Add-Line "   Evidence: $qEvidence"
    }
}
Add-Line ''

# ---- Manual testing (when present) -----------------------------------------------------
if ($null -ne $manualTests -and $null -eq (Get-Prop $manualTests 'status' $null)) {
    $cands = @(Get-Prop $manualTests 'candidates' @())
    if (@($cands).Count -gt 0) {
        Add-Line "## Manual-test candidates (Phase 1c - keyword/ticket match, never asserted as fact)"
        foreach ($c in $cands) {
            Add-Line "- $([string](Get-Prop $c 'title' '')) (matched by: $([string](Get-Prop $c 'matchedBy' '')))"
        }
        Add-Line ''
    }
}

# ---- Ready-made tests to keep -----------------------------------------------------
Add-Line "## Ready-made tests to keep (drafted fixes + generated scenarios)"
$readyCount = 0
if ($null -ne $mutants) {
    foreach ($m in @(Get-Prop $mutants 'mutants' @())) {
        $fix = Get-Prop $m 'suggestedFix' $null
        if ($null -ne $fix -and [string](Get-Prop $m 'status' '') -eq 'Survived') {
            $readyCount++
            Add-Line "$readyCount. Strengthened-assertion fix for mutant id $([string](Get-Prop $m 'id' '')) - $([string](Get-Prop $fix 'rationale' ''))"
        }
    }
}
foreach ($s in $scenarioFiles) {
    $readyCount++
    $title = [string](Get-Prop $s 'title' '')
    $req = [string](Get-Prop $s 'requirement' (Get-Prop $s 'requirementId' ''))
    Add-Line "$readyCount. [$req] $title"
}
if ($readyCount -eq 0) { Add-Line "None this run." }
Add-Line ''

# ---- What was checked -----------------------------------------------------
Add-Line "## What was checked (checklist for the report table)"
Add-Line "- Unit tests: $(if ($null -eq $testResults) { 'SKIPPED' } else { 'RAN' })"
Add-Line "- Diff coverage: $(if ($null -eq $diffCoverage) { 'SKIPPED' } elseif ([bool](Get-Prop $diffCoverage 'refused' $false)) { 'REFUSED' } else { 'RAN' })"
Add-Line "- Mutation testing: $(if ($null -eq $mutants -and $null -eq $strykerSummary) { 'SKIPPED' } else { 'RAN' })"
Add-Line "- Contract/API: $(if ($null -eq $contractReport -or [bool](Get-Prop $contractReport 'skipped' $false)) { 'SKIPPED' } else { 'RAN' })"
Add-Line "- Acceptance criteria: $(if ($null -eq $analystBrief) { 'SKIPPED' } else { 'RAN' })"
Add-Line "- Impact (cross-repo): $(if ($null -eq $impactIndex) { 'SKIPPED' } else { 'RAN' })"
Add-Line "- Manual testing candidates: $(if ($null -eq $manualTests) { 'SKIPPED' } else { 'RAN' })"
Add-Line ''

# ---- Result -----------------------------------------------------
$anyAcNotMet = $false
if ($null -ne $analystBrief) {
    $anyAcNotMet = @(Get-Prop $analystBrief 'acAlignment' @() | Where-Object { [string](Get-Prop $_ 'grade' '') -like 'NOT MET*' }).Count -gt 0
}
$anyTestFailed = $false
if ($null -ne $testResults) {
    $anyTestFailed = @(Get-Prop $testResults 'runs' @() | Where-Object { [int](Get-Prop $_ 'failed' 0) -gt 0 }).Count -gt 0
}
$anyBreaking = ($null -ne $contractReport -and -not [bool](Get-Prop $contractReport 'skipped' $false) -and @(Get-Prop $contractReport 'breaking' @()).Count -gt 0)
$hardOverride = if ($null -ne $riskScore) { Get-Prop $riskScore 'hardOverride' $null } else { $null }

Add-Line "## Result (mechanical suggestion - qa-report-synthesizer makes the final call)"
if ($anyAcNotMet -or $anyTestFailed -or $anyBreaking -or ($null -ne $hardOverride -and $hardOverride -ne '')) {
    Add-Line "Suggested: RED Not ready yet - $(Join-NonEmpty -Parts @(
        $(if ($anyTestFailed) { 'a unit test failed' }),
        $(if ($anyBreaking) { 'a breaking API change was found' }),
        $(if ($anyAcNotMet) { 'an acceptance criterion is NOT MET' }),
        $(if ($null -ne $hardOverride -and $hardOverride -ne '') { "risk-score hard override: $hardOverride" })
    ) -Sep '; ')."
} else {
    Add-Line "Suggested: GREEN Ready to open - no AC is NOT MET, no test failed, no breaking contract change found."
}
if ($null -ne $riskScore) {
    Add-Line "Merge risk band (verbatim from risk-score.json): $([string](Get-Prop $riskScore 'band' ''))."
}

Write-Output (Join-NonEmpty -Parts @($lines.ToArray()) -Sep "`n")
