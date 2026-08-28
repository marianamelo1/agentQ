<#
.SYNOPSIS
    Phase 6  -  deterministic merge-risk score. Writes risk-score.json per scripts/CONTRACTS.md.
    Also writes gap-lattice.json (GH issue #26): a second, unrelated-but-cheap output that
    reuses the diff-coverage.json/mutation-report.json/mutants.json this script already loads.

.DESCRIPTION
    WHY THIS IS A SCRIPT, NOT AN AGENT: an LLM computing a weighted sum returns different
    numbers on identical inputs  -  determinism is the tool's credibility. The same branch
    state must produce the same score twice, byte for byte.

    Inputs (all read from the run's workspaceDir; every one of them OPTIONAL):
      diff-set.json, diff-coverage.json, test-results.json, mutation-report.json,
      contract-report.json, adapter-profiles.json, impact-index.json,
      manual-test-candidates.json  -  plus git churn from the manifest's repoPath. Missing/
      unreadable inputs make their signals unavailable and the remaining weights
      RENORMALIZE. WHY never score a missing signal as 0: substituting zero fakes a
      low-risk verdict off absent evidence  -  the exact dishonesty this tool exists to
      prevent. Missing evidence lowers stated confidence instead.

    Blast-radius signals (crossRepoImpact, uiAutomationExposure, manualTestVolume) are
    blended into the SAME weighted score as correctness signals, not reported separately:
    a change that reaches further has more surface for a mistake to cause damage, which is
    a genuine merge-risk dimension in its own right. They read impact-index.json /
    manual-test-candidates.json (Phase 1b/1c artifacts, which run in every mode including
    --quick), so a quick review commonly has these plus testToSourceBalance/churn90d as its
    only available signals.

    GH issue #26: qa-analyst (Phase 4) used to compose analyst-brief.json's gapLattice from
    diff-coverage.json + mutation-report.json, but mutation-report.json is only written here,
    in Phase 5/6, strictly after qa-analyst's own dispatch window  -  so the "assertion too
    weak" tier came back empty on every live run. Since this script already loads both inputs
    for its own signals (s2 below) and only ever runs after the mutation merge, composing the
    lattice HERE instead makes it mechanical and timing-proof; see the gap-lattice.json section
    near the bottom of this file and scripts/CONTRACTS.md.

    Exit code 0 = the script ran (even if the score is terrible  -  findings live in the
    JSON artifact). Non-zero = the script itself could not do its job.

.PARAMETER Manifest
    Path to run-manifest.json (written by the orchestrator in Phase 0).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Manifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------

function Get-Prop {
    # Safe property access under StrictMode: ConvertFrom-Json yields PSCustomObject and
    # touching an absent property throws. Absent or null -> caller's default.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Read-JsonArtifact {
    # A missing artifact and an unparseable artifact are treated identically: the signals
    # built on it become unavailable, weights renormalize, confidence drops. WHY: guessing
    # a value for broken evidence would fabricate a verdict; aborting the whole score for
    # one bad artifact would throw away the signals we DO have.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        # -Encoding UTF8 explicitly: CONTRACTS.md artifacts are UTF-8 without BOM, and
        # PS 5.1 Get-Content without an encoding reads BOM-less UTF-8 as ANSI (mojibake
        # in test names would silently break FQN matching).
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Clamp01 {
    param([double]$v)
    if ($v -lt 0.0) { return 0.0 }
    if ($v -gt 1.0) { return 1.0 }
    return $v
}

function Round-Int {
    # AwayFromZero, not .NET's default banker's rounding  -  both are deterministic, but
    # AwayFromZero matches what a human recomputing the formula by hand expects.
    param([double]$v)
    return [int][math]::Round($v, [System.MidpointRounding]::AwayFromZero)
}

function Get-Band {
    param([int]$Score)
    if ($Score -le 20) { return 'Low' }
    if ($Score -le 45) { return 'Moderate' }
    if ($Score -le 70) { return 'Elevated' }
    return 'High'
}

# Code / test-file classification, used by s6 (test-vs-source balance) and topTests.
# Non-code files (json, md, csproj, yaml...) are deliberately NEITHER: a config-only
# change should not read as "source changed with no tests".
$CodeFileRegex = '(?i)\.(cs|vb|fs|fsx|ts|tsx|js|jsx|mjs|cjs)$'
function Test-IsTestFile {
    param([string]$Path)
    # Directory segments first (e-conomic keeps tests under apps/backend/tests/...),
    # then .NET naming (FooTests.cs / FooSpec.cs), then JS naming (foo.test.ts / foo.spec.ts).
    if ($Path -match '(?i)(^|[/\\])(tests?|__tests__)([/\\])') { return $true }
    if ($Path -match '(?i)(tests?|spec)\.(cs|vb|fs)$') { return $true }
    if ($Path -match '(?i)\.(test|spec)\.(ts|tsx|js|jsx|mjs|cjs)$') { return $true }
    return $false
}

# ---------------------------------------------------------------------------------------
# Load manifest + artifacts
# ---------------------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Manifest)) {
    throw "risk-score: manifest not found: $Manifest"
}
$man = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json

$workspaceDir = [string](Get-Prop $man 'workspaceDir' '')
if ([string]::IsNullOrWhiteSpace($workspaceDir) -or -not (Test-Path -LiteralPath $workspaceDir)) {
    # Without the workspace we can neither read artifacts nor write our own  -  that is an
    # orchestration failure, not a finding.
    throw "risk-score: workspaceDir missing or not found in manifest: '$workspaceDir'"
}
$repoPath = [string](Get-Prop $man 'repoPath' '')

$diffSet     = Read-JsonArtifact (Join-Path $workspaceDir 'diff-set.json')
$diffCov     = Read-JsonArtifact (Join-Path $workspaceDir 'diff-coverage.json')
$testResults = Read-JsonArtifact (Join-Path $workspaceDir 'test-results.json')
$mut         = Read-JsonArtifact (Join-Path $workspaceDir 'mutation-report.json')
$contract    = Read-JsonArtifact (Join-Path $workspaceDir 'contract-report.json')
$adapters    = Read-JsonArtifact (Join-Path $workspaceDir 'adapter-profiles.json')
$mutantsRaw  = Read-JsonArtifact (Join-Path $workspaceDir 'mutants.json')
$impactIdx   = Read-JsonArtifact (Join-Path $workspaceDir 'impact-index.json')
$manualCand  = Read-JsonArtifact (Join-Path $workspaceDir 'manual-test-candidates.json')
$reviewedRepoSlug = [string](Get-Prop $man 'repoSlug' '')

$adapterProjects = @(Get-Prop $adapters 'projects' @())

# WHY this counts toward testToSourceBalance (s6 below), not just informationally: a
# developer's diff having zero test-line changes isn't the whole truth when agentQ's own
# Phase 7 generated and PROVED (anti-vacuity: fails on base, passes on branch) a scenario
# closing exactly that gap -- see CONTRACTS.md "testToSourceBalance and generated
# scenarios". Only proven-non-vacuous evidence counts; GENERATED_NOT_EXECUTED or
# static_only earns nothing.
$verifiedGeneratedCount = 0
$scenariosDir = Join-Path $workspaceDir 'scenarios'
if (Test-Path -LiteralPath $scenariosDir -PathType Container) {
    foreach ($sf in (Get-ChildItem -LiteralPath $scenariosDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $sc = Read-JsonArtifact $sf.FullName
        if ($null -eq $sc) { continue }
        $execState = [string](Get-Prop $sc 'executionState' '')
        $vacuity   = [string](Get-Prop $sc 'vacuityGrade' '')
        if ($execState -eq 'EXECUTED_PASSED' -and $vacuity -eq 'verified_against_base') { $verifiedGeneratedCount++ }
    }
}
if ($null -ne $mutantsRaw) {
    foreach ($mEntry in @(Get-Prop $mutantsRaw 'mutants' @())) {
        if ($null -ne (Get-Prop $mEntry 'suggestedFix' $null)) { $verifiedGeneratedCount++ }
    }
}

# ---------------------------------------------------------------------------------------
# Changed-file table from diff-set (feeds s6, s7 and topTests)
# ---------------------------------------------------------------------------------------

$changedFiles = @()
if ($null -ne $diffSet) {
    foreach ($f in @(Get-Prop $diffSet 'files' @())) {
        $p = [string](Get-Prop $f 'path' '')
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $lines = 0
        foreach ($h in @(Get-Prop $f 'hunks' @())) { $lines += [int](Get-Prop $h 'newCount' 0) }
        $changedFiles += [pscustomobject]@{ Path = $p; ChangedLines = $lines; Untracked = $false }
    }
    foreach ($u in @(Get-Prop $diffSet 'untracked' @())) {
        $p = [string]$u
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        # Untracked files carry no hunk info. They still count as changed FILES for the
        # test-balance and churn signals, with 0 measurable lines. WHY not read the file
        # to count lines: Phase 6 must not depend on a worktree existing, and a raw line
        # count of a brand-new file is not "changed executable lines" anyway.
        $changedFiles += [pscustomobject]@{ Path = $p; ChangedLines = 0; Untracked = $true }
    }
}

# ---------------------------------------------------------------------------------------
# Test-results totals + hard overrides
# ---------------------------------------------------------------------------------------

$runs = @(Get-Prop $testResults 'runs' @())
$totalFailed = 0
$testsExecutedTotal = 0
$buildFailed = $false
foreach ($run in $runs) {
    $exit       = [int](Get-Prop $run 'exitCode' 0)
    $executed   = [int](Get-Prop $run 'testsExecuted' 0)
    $failedCnt  = [int](Get-Prop $run 'failed' 0)
    $zeroMatch  = [bool](Get-Prop $run 'zeroMatchError' $false)
    $failsArr   = @(Get-Prop $run 'failures' @())
    $testsExecutedTotal += $executed
    $totalFailed += $failedCnt
    # Build-failure detection: nonzero exit with ZERO tests executed means the process died
    # before any test ran (compile/restore error) - either with no recorded failure entry at
    # all, or (per CONTRACTS.md) a single synthesized entry carrying fqn "<build>" with the
    # real compiler/restore diagnostic. zeroMatchError is excluded on purpose  -
    # TreatNoTestsAsError makes a zero-match filter exit nonzero too, but that is a filter
    # problem, not a build failure.
    $isBuildFailureEntry = ($failsArr.Count -eq 0) -or (@($failsArr | Where-Object { (Get-Prop $_ 'fqn' '') -eq '<build>' }).Count -gt 0)
    if ($exit -ne 0 -and $executed -eq 0 -and $isBuildFailureEntry -and -not $zeroMatch) {
        $buildFailed = $true
    }
}

# ---------------------------------------------------------------------------------------
# Signals  -  computed in the documented order s1..s7 so the output ledger is stable.
# Each entry: Name, Weight (documented), Available, Value (natural metric for the report),
# S (the clamped [0,1] signal that actually enters the weighted sum).
# ---------------------------------------------------------------------------------------

$signals = New-Object 'System.Collections.Generic.List[object]'

# --- s1: 1 - branchDiffCoverage (0.2296)  -  only if coverage was not refused -------------
$covRefused = $true
if ($null -ne $diffCov) { $covRefused = [bool](Get-Prop $diffCov 'refused' $false) }
$bdc = Get-Prop $diffCov 'branchDiffCoverage'
if ($null -ne $diffCov -and -not $covRefused -and $null -ne $bdc) {
    $s1 = Clamp01 (1.0 - [double]$bdc)
    $signals.Add([pscustomobject]@{ Name = 'branchDiffCoverage'; Weight = 0.2296; Available = $true; Value = [math]::Round([double]$bdc, 4); S = $s1 })
} else {
    # refused:true means the numbers were built on broken path mapping  -  CONTRACTS.md
    # forbids reporting them, so they cannot feed a score either.
    $signals.Add([pscustomobject]@{ Name = 'branchDiffCoverage'; Weight = 0.2296; Available = $false; Value = $null; S = 0.0 })
}

# --- s2: surviving business-rule mutants / max(1, run) (0.164) --------------------------
$brRun = 0
$brSurvived = 0
$mutAvailable = $false
if ($null -ne $mut) {
    $filesMap = Get-Prop $mut 'files'
    if ($null -ne $filesMap) {
        foreach ($fp in $filesMap.PSObject.Properties) {
            foreach ($m in @(Get-Prop $fp.Value 'mutants' @())) {
                $mn = [string](Get-Prop $m 'mutatorName' '')
                # agentQ semantic mutants are merged in with mutatorName prefixed
                # 'BusinessRule/' (CONTRACTS.md)  -  only those feed this signal.
                if (-not $mn.StartsWith('BusinessRule/')) { continue }
                $st = [string](Get-Prop $m 'status' '')
                # "Run" = actually executed against tests: Killed, Survived, Timeout
                # (a Timeout is a detected mutant). NoCoverage never ran  -  those are
                # coverage findings per CONTRACTS.md, and Ignored/CompileError produced
                # no evidence either way.
                if ($st -eq 'Killed' -or $st -eq 'Survived' -or $st -eq 'Timeout') { $brRun++ }
                if ($st -eq 'Survived') { $brSurvived++ }
            }
        }
    }
}
# Available only when at least one business-rule mutant was actually evaluated
# (Killed/Survived/Timeout)  -  a files{} map full of Ignored/NoCoverage/CompileError
# is, evidentially, no different from a missing report (GH issue #42).
if ($brRun -gt 0) { $mutAvailable = $true }
if ($mutAvailable) {
    # max(1, run): a report with zero business-rule mutants scores 0 here  -  mutation DID
    # run and found no surviving rule mutants; that is genuine evidence, unlike a missing
    # report (which renormalizes instead).
    $s2 = Clamp01 ($brSurvived / [double]([math]::Max(1, $brRun)))
    $signals.Add([pscustomobject]@{ Name = 'survivingBusinessRuleMutants'; Weight = 0.164; Available = $true; Value = $brSurvived; S = $s2 })
} else {
    $signals.Add([pscustomobject]@{ Name = 'survivingBusinessRuleMutants'; Weight = 0.164; Available = $false; Value = $null; S = 0.0 })
}

# --- s3: clamp((maxMethodComplexity(changed) - 5) / 20) (0.1148) ------------------------
$complexities = @()
if ($null -ne $diffCov -and -not $covRefused) {
    foreach ($g in @(Get-Prop $diffCov 'gaps' @())) {
        $mc = Get-Prop $g 'methodComplexity'
        if ($null -ne $mc) { $complexities += [double]$mc }
    }
}
if ($complexities.Count -gt 0) {
    $maxC = 0.0
    foreach ($cx in $complexities) { if ($cx -gt $maxC) { $maxC = $cx } }
    $s3 = Clamp01 (($maxC - 5.0) / 20.0)
    $signals.Add([pscustomobject]@{ Name = 'changedMethodComplexity'; Weight = 0.1148; Available = $true; Value = [math]::Round($maxC, 2); S = $s3 })
} else {
    # Unavailable when coverage is missing/refused OR every gap has null complexity
    # (spec: "unavailable if all null"). A refused coverage report cannot lend us its
    # gap list either  -  same broken path mapping underneath.
    $signals.Add([pscustomobject]@{ Name = 'changedMethodComplexity'; Weight = 0.1148; Available = $false; Value = $null; S = 0.0 })
}

# --- s4: log10(1 + changedExecutableLines) / log10(501) (0.0984) ------------------------
$cel = Get-Prop $diffCov 'changedExecutableLines'
if ($null -ne $diffCov -and -not $covRefused -and $null -ne $cel) {
    # Log scale: the risk difference between 10 and 100 changed lines matters more than
    # between 400 and 500; saturates at 500 lines (log10(501) denominator -> s4 = 1).
    $s4 = Clamp01 ([math]::Log10(1.0 + [double]$cel) / [math]::Log10(501.0))
    $signals.Add([pscustomobject]@{ Name = 'changedExecutableLines'; Weight = 0.0984; Available = $true; Value = [int]$cel; S = $s4 })
} else {
    $signals.Add([pscustomobject]@{ Name = 'changedExecutableLines'; Weight = 0.0984; Available = $false; Value = $null; S = 0.0 })
}

# --- s5: contract findings  -  1.0 any ERR, 0.4 only WARN, 0 clean (0.0984) ---------------
$contractSkipped = $true
if ($null -ne $contract) { $contractSkipped = [bool](Get-Prop $contract 'skipped' $false) }
if ($null -ne $contract -and -not $contractSkipped) {
    $breaking = @(Get-Prop $contract 'breaking' @())
    $warnArr  = @(Get-Prop $contract 'warnings' @())
    $hasErr  = @($breaking | Where-Object { [string](Get-Prop $_ 'level' '') -eq 'ERR' }).Count -gt 0
    $hasWarn = (@($breaking | Where-Object { [string](Get-Prop $_ 'level' '') -eq 'WARN' }).Count -gt 0) -or ($warnArr.Count -gt 0)
    $s5 = 0.0
    if ($hasErr) { $s5 = 1.0 } elseif ($hasWarn) { $s5 = 0.4 }
    $signals.Add([pscustomobject]@{ Name = 'contractBreaking'; Weight = 0.0984; Available = $true; Value = $s5; S = $s5 })
} else {
    # Lane skipped (or no report): renormalize. WHY: "no contract lane ran" must never
    # read as "contract clean".
    $signals.Add([pscustomobject]@{ Name = 'contractBreaking'; Weight = 0.0984; Available = $false; Value = $null; S = 0.0 })
}

# --- s6: test-vs-source balance from diff-set paths (0.0738) ----------------------------
if ($null -ne $diffSet) {
    $srcFiles  = @()
    $testFiles = @()
    foreach ($cf in $changedFiles) {
        if ($cf.Path -notmatch $CodeFileRegex) { continue }
        if (Test-IsTestFile $cf.Path) { $testFiles += $cf } else { $srcFiles += $cf }
    }
    # Plain loops, not Measure-Object -Sum: under StrictMode + PS 5.1, empty pipeline
    # input makes the .Sum access throw instead of yielding 0.
    $srcLines = 0
    foreach ($sf in $srcFiles) { $srcLines += [int]$sf.ChangedLines }
    $testLines = 0
    foreach ($tf in $testFiles) { $testLines += [int]$tf.ChangedLines }
    if ($testFiles.Count -eq 0 -and $srcFiles.Count -ge 1) {
        # Source changed, not one test file touched  -  the maximum-signal case by spec.
        $s6 = 1.0
    } elseif ($srcFiles.Count -eq 0) {
        # Test-only or non-code change: nothing to balance against.
        $s6 = 0.0
    } elseif ($srcLines -le 0) {
        # Source files exist but all lines unmeasurable (untracked-only) AND tests were
        # touched: the ratio is uncomputable  -  do not punish on unknowns.
        $s6 = 0.0
    } else {
        # Expectation baked into the formula: test lines keep up with ~30% of source
        # lines; the shortfall below that scales the signal linearly.
        $s6 = Clamp01 (1.0 - ($testLines / (0.3 * [double]$srcLines)))
    }
    # Credit verified generated evidence against the diff-only penalty (see CONTRACTS.md
    # "testToSourceBalance and generated scenarios"): each proven-non-vacuous generated
    # scenario or mutation suggestedFix is worth 0.5 -- two of them fully offset a
    # maxed-out 1.0 penalty. Never pushes s6 negative; a diff that already has its own
    # tests is not penalized further for lacking generated ones.
    if ($verifiedGeneratedCount -gt 0) {
        $s6 = Clamp01 ($s6 - (0.5 * [double]$verifiedGeneratedCount))
    }
    $signals.Add([pscustomobject]@{ Name = 'testToSourceBalance'; Weight = 0.0738; Available = $true; Value = [math]::Round([double]$s6, 4); S = $s6 })
} else {
    $signals.Add([pscustomobject]@{ Name = 'testToSourceBalance'; Weight = 0.0738; Available = $false; Value = $null; S = 0.0 })
}

# --- s7: churn  -  clamp(distinct commits touching changed files in 90d / 40) (0.041) -----
$s7Available = $false
$churnCommits = 0
if ($null -ne $diffSet -and -not [string]::IsNullOrWhiteSpace($repoPath) -and (Test-Path -LiteralPath $repoPath)) {
    $allChangedPaths = @($changedFiles | ForEach-Object { $_.Path } | Sort-Object -Unique)
    if ($allChangedPaths.Count -eq 0) {
        # Empty diff: churn over "the changed files" is vacuously zero  -  real evidence.
        $s7Available = $true
    } else {
        $shaSet = New-Object 'System.Collections.Generic.HashSet[string]'
        $gitOk = $true
        $prevEap = $ErrorActionPreference
        try {
            # WHY the EAP juggling: under 'Stop', PS 5.1 turns any redirected native
            # stderr line into a terminating NativeCommandError. git may print advisory
            # noise to stderr; failure is judged by $LASTEXITCODE alone.
            $ErrorActionPreference = 'Continue'
            for ($i = 0; $i -lt $allChangedPaths.Count; $i += 100) {
                $end = [math]::Min($i + 99, $allChangedPaths.Count - 1)
                $batch = @($allChangedPaths[$i..$end])
                # WHY --pretty=format:%H instead of the --name-only blank-line-block form:
                # identical semantics (distinct commits in the window touching these
                # paths  -  git emits each commit once regardless of how many paths match),
                # but counting hashes is robust where parsing name-only blocks is not.
                # WHY batches of 100 paths: Windows command-line length limit (~32k chars).
                $out = & git -C $repoPath log '--since=90 days ago' '--pretty=format:%H' '--' @batch 2>$null
                if ($LASTEXITCODE -ne 0) { $gitOk = $false; break }
                foreach ($line in @($out)) {
                    if ($line -match '^[0-9a-fA-F]{40}$') { $null = $shaSet.Add(([string]$line).ToLowerInvariant()) }
                }
            }
        } catch {
            # git not on PATH (or similar)  -  degrade the signal honestly, never crash
            # the whole score over one input.
            $gitOk = $false
        } finally {
            $ErrorActionPreference = $prevEap
        }
        if ($gitOk) {
            $s7Available = $true
            $churnCommits = $shaSet.Count
        }
    }
}
if ($s7Available) {
    $s7 = Clamp01 ($churnCommits / 40.0)
    $signals.Add([pscustomobject]@{ Name = 'churn90d'; Weight = 0.041; Available = $true; Value = $churnCommits; S = $s7 })
} else {
    $signals.Add([pscustomobject]@{ Name = 'churn90d'; Weight = 0.041; Available = $false; Value = $null; S = 0.0 })
}

# --- s8/s9/s10: blast radius -- cross-repo / UI-automation / manual-test reach (0.18 total)
# WHY these belong in the SAME score as s1-s7, not a separate indicator: a change that
# reaches further has more surface for a mistake to cause damage, which is a genuine
# merge-risk dimension even when the diff itself reads as low-complexity. All three read
# impact-index.json / manual-test-candidates.json -- artifacts from Phase 1b/1c, which run
# in EVERY mode including --quick, so these three are commonly the only non-execution
# signals available on a quick review (alongside s6/s7 above and s5 when the contract gate
# opened on a committed-spec path). Availability is gated on "did the phase actually run",
# never on "0 matches" -- a real 0 is available evidence (S=0), same pattern as s2's
# mutAvailable. impact-index.ps1 always writes its file when invoked (even at 0 seeds), so
# file existence IS the phase-ran signal for s8/s9; manual-test-candidates.json additionally
# gates on status "RAN" (its own honest SKIPPED/DEGRADED strings must never masquerade as a
# real "0 candidates" reading -- see CONTRACTS.md).

# --- s8: distinct OTHER product repos with >=1 code-symbol match (0.06) -----------------
$crossRepoAvailable = $false
$distinctOtherRepos = 0
if ($null -ne $impactIdx) {
    $crossRepoAvailable = $true
    $otherRepoSlugs = New-Object System.Collections.Generic.HashSet[string]
    foreach ($mtc in @(Get-Prop $impactIdx 'matches' @())) {
        if ([bool](Get-Prop $mtc 'indexOnly' $false)) { continue }  # testRepos matches feed s9, not s8
        $rs = [string](Get-Prop $mtc 'repoSlug' '')
        if ($rs -and $rs -ne $reviewedRepoSlug) { $null = $otherRepoSlugs.Add($rs) }
    }
    $distinctOtherRepos = $otherRepoSlugs.Count
}
if ($crossRepoAvailable) {
    # 3+ distinct other product repos referencing this diff's own symbols maxes the signal.
    $s8 = Clamp01 ($distinctOtherRepos / 3.0)
    $signals.Add([pscustomobject]@{ Name = 'crossRepoImpact'; Weight = 0.06; Available = $true; Value = $distinctOtherRepos; S = $s8 })
} else {
    $signals.Add([pscustomobject]@{ Name = 'crossRepoImpact'; Weight = 0.06; Available = $false; Value = $null; S = 0.0 })
}

# --- s9: distinct UI-automation (testRepos) files with >=1 match (0.06) -----------------
$uiAutoAvailable = $false
$distinctUiFiles = 0
if ($null -ne $impactIdx) {
    $uiAutoAvailable = $true
    $uiFiles = New-Object System.Collections.Generic.HashSet[string]
    foreach ($mtc in @(Get-Prop $impactIdx 'matches' @())) {
        if (-not [bool](Get-Prop $mtc 'indexOnly' $false)) { continue }
        $rf = "$([string](Get-Prop $mtc 'repoSlug' ''))|$([string](Get-Prop $mtc 'file' ''))"
        $null = $uiFiles.Add($rf)
    }
    $distinctUiFiles = $uiFiles.Count
}
if ($uiAutoAvailable) {
    # 5+ distinct UI-automation spec files touching this diff's symbols maxes the signal.
    $s9 = Clamp01 ($distinctUiFiles / 5.0)
    $signals.Add([pscustomobject]@{ Name = 'uiAutomationExposure'; Weight = 0.06; Available = $true; Value = $distinctUiFiles; S = $s9 })
} else {
    $signals.Add([pscustomobject]@{ Name = 'uiAutomationExposure'; Weight = 0.06; Available = $false; Value = $null; S = 0.0 })
}

# --- s10: manual-test candidate volume (0.06) -------------------------------------------
$manualAvailable = $false
$manualCount = 0
if ($null -ne $manualCand) {
    $mStatus = [string](Get-Prop $manualCand 'status' '')
    if ($mStatus -eq 'RAN') {
        # SKIPPED/DEGRADED strings must never be read as "0 candidates" -- only a genuine
        # completed query counts as available evidence, per CONTRACTS.md.
        $manualAvailable = $true
        $manualCount = @(Get-Prop $manualCand 'candidates' @()).Count
    }
}
if ($manualAvailable) {
    # 5+ manual-test candidates maxes the signal.
    $s10 = Clamp01 ($manualCount / 5.0)
    $signals.Add([pscustomobject]@{ Name = 'manualTestVolume'; Weight = 0.06; Available = $true; Value = $manualCount; S = $s10 })
} else {
    $signals.Add([pscustomobject]@{ Name = 'manualTestVolume'; Weight = 0.06; Available = $false; Value = $null; S = 0.0 })
}

# ---------------------------------------------------------------------------------------
# Renormalize + score (hard overrides trump the weighted sum)
# ---------------------------------------------------------------------------------------

$availableSignals = @($signals | Where-Object { $_.Available })
$missing = @($signals | Where-Object { -not $_.Available } | ForEach-Object { $_.Name })
$W = 0.0
foreach ($a in $availableSignals) { $W += [double]$a.Weight }

$hardOverride = $null
if ($buildFailed) {
    # Build failure first: nothing downstream of a broken build is evidence of anything.
    $hardOverride = 'build-failed'
    $score = 100
} elseif ($totalFailed -gt 0) {
    $hardOverride = 'affected-test-failed'
    $score = 90 + [math]::Min(9, $totalFailed)
} else {
    if ($W -le 0.0) {
        # Zero available signals and no failure evidence: any number emitted here would
        # be fabricated from no evidence  -  the exact fake-low-risk verdict this design
        # forbids. That is an invocation-order failure, so the script fails loudly.
        throw 'risk-score: no input artifacts available - refusing to fabricate a score from zero evidence (run Phases 1-5 first)'
    }
    $rawFromAvailable = 0.0
    foreach ($a in $availableSignals) { $rawFromAvailable += ([double]$a.Weight / $W) * [double]$a.S }
    # WHY blend toward NEUTRAL_UNKNOWN by available weight-coverage (see CONTRACTS.md
    # "Sparse-evidence dampening"): pure renormalization treats whatever signals ARE
    # available as if they were the whole picture. Verified live: with only 14% of the
    # documented weight available, a single maxed-out signal (testToSourceBalance)
    # dragged a 3-line, anti-vacuity-verified fix to "Elevated". Full coverage (W=1)
    # reduces to the plain weighted sum, unchanged; sparse coverage pulls toward the
    # baseline instead of amplifying whatever little evidence exists.
    # WHY 0.35, not a dead-neutral 0.5: the band table is NOT symmetric around the
    # midpoint (Low 0-20 | Moderate 21-45 | Elevated 46-70 | High 71-100) -- a 0.5
    # "coin-flip" default for total absence of evidence lands at score 50, which is
    # Elevated by construction, the same band as genuine risk evidence. "we know
    # nothing" and "we know this is risky" must not read the same. 0.35 puts a
    # 100%-unknown case (W=0) comfortably in the middle of Moderate instead.
    $NEUTRAL_UNKNOWN = 0.35
    $raw = ($W * $rawFromAvailable) + ((1.0 - $W) * $NEUTRAL_UNKNOWN)
    $score = [math]::Max(0, [math]::Min(100, (Round-Int (100.0 * $raw))))
}
$score = [int]$score
$band = Get-Band $score

# Signal ledger rows. 'weight' and 'contribution' use each signal's ORIGINAL documented
# weight, never renormalized -- so contribution = round(100 * weight * s) is reproducible
# from the row AND every row's contribution (available signals + the synthetic
# unknownEvidence row below) sums to `score`, by construction of the dampened formula
# above. Unavailable rows keep the documented weight for transparency, contribute 0, and
# are named in missingSignals. Under a hard override the contributions remain
# informational  -  the score is the override, by design.
$signalRows = @()
foreach ($sg in $signals) {
    $effW = [math]::Round([double]$sg.Weight, 4)
    $contrib = 0
    if ($sg.Available) {
        $contrib = Round-Int (100.0 * [double]$sg.Weight * [double]$sg.S)
    }
    $signalRows += [ordered]@{
        name         = $sg.Name
        value        = $sg.Value
        weight       = $effW
        contribution = $contrib
        available    = [bool]$sg.Available
    }
}
if ($null -eq $hardOverride -and $missing.Count -gt 0) {
    # The neutral-baseline share of the score from the "Sparse-evidence dampening" blend
    # above, surfaced as its own ledger row so the table's contributions still sum to
    # `score` instead of silently falling short by whatever the missing signals would
    # have contributed.
    $unknownWeight = [math]::Round(1.0 - $W, 4)
    $signalRows += [ordered]@{
        name         = 'unknownEvidence'
        value        = $unknownWeight
        weight       = $unknownWeight
        contribution = Round-Int (100.0 * (1.0 - $W) * $NEUTRAL_UNKNOWN)
        available    = $true
    }
}

# Confidence. "Scenarios executed" has no dedicated artifact in CONTRACTS.md, so the
# closest deterministic evidence is: test-results.json exists and executed >0 tests.
# 0 missing signals WITHOUT executed evidence deliberately lands on 'moderate'  -  high
# confidence requires both complete signals and something having actually run.
$scenariosExecuted = ($null -ne $testResults -and $testsExecutedTotal -gt 0)
$confidence = 'low'
if ($missing.Count -eq 0 -and $scenariosExecuted) {
    $confidence = 'high'
} elseif ($missing.Count -le 2) {
    $confidence = 'moderate'
}

# ---------------------------------------------------------------------------------------
# topTests  -  tests most likely to catch a regression on the changed lines. Max 3.
# WHY name-matching: no artifact in CONTRACTS.md carries per-test line coverage, so the
# deterministic proxy for "test covers file" is the changed file's base name appearing in
# the test FQN (VatCalculator -> VatCalculatorTests.*). "Changed lines a test would
# cover" ~= changed lines minus known-uncovered gap lines for that file.
# ---------------------------------------------------------------------------------------

function Get-RunCommand {
    param([string]$ProjectPath, [string]$Fqn)
    # Strip parameterized-test arguments for .NET filters; FullyQualifiedName~ (never =)
    # because parameterized display names don't equal their declared FQN (CLAUDE.md).
    $fqnClean = $Fqn
    $paren = $fqnClean.IndexOf('(')
    if ($paren -gt 0) { $fqnClean = $fqnClean.Substring(0, $paren) }
    $runner = ''
    foreach ($p in $script:adapterProjects) {
        $a = ([string](Get-Prop $p 'projectPath' '')) -replace '\\', '/'
        $b = $ProjectPath -replace '\\', '/'
        if ($a -and ($a -eq $b)) { $runner = [string](Get-Prop $p 'runner' ''); break }
    }
    if ([string]::IsNullOrWhiteSpace($runner)) {
        # No adapter profile matched: infer from the project path so the developer still
        # gets a runnable command rather than a blank field.
        if ($ProjectPath -match '(?i)\.csproj$') { $runner = 'vstest' } else { $runner = 'jest-cli' }
    }
    $nameEsc = $Fqn -replace '"', '\"'
    switch ($runner) {
        'vstest' { return ('dotnet test "{0}" --no-build --filter "FullyQualifiedName~{1}"' -f $ProjectPath, $fqnClean) }
        'mtp' {
            # Microsoft.Testing.Platform has no vstest --filter; its selector is the
            # tree-node filter /Assembly/Namespace/Class/Method (namespace is one node,
            # dots included, hence the wildcards for the first two segments).
            $segs = $fqnClean.Split('.')
            $method = $segs[$segs.Count - 1]
            $class = '*'
            if ($segs.Count -ge 2) { $class = $segs[$segs.Count - 2] }
            return ('dotnet test "{0}" --no-build -- --treenode-filter "/*/*/{1}/{2}"' -f $ProjectPath, $class, $method)
        }
        'jest-cli' { return ('npx jest --ci -t "{0}"' -f $nameEsc) }
        'nx' { return ('npx nx test {0} -- -t "{1}"' -f $ProjectPath, $nameEsc) }
        default { return ('dotnet test "{0}" --no-build --filter "FullyQualifiedName~{1}"' -f $ProjectPath, $fqnClean) }
    }
}

$topTests = @()
if ($null -ne $testResults -and $null -ne $diffSet) {
    # Per-file uncovered-gap counts (only when coverage is trustworthy).
    $gapCounts = @{}
    if ($null -ne $diffCov -and -not $covRefused) {
        foreach ($g in @(Get-Prop $diffCov 'gaps' @())) {
            $gf = [string](Get-Prop $g 'file' '')
            if ($gf) {
                if ($gapCounts.ContainsKey($gf)) { $gapCounts[$gf]++ } else { $gapCounts[$gf] = 1 }
            }
        }
    }
    # Changed source files with a usable name proxy. Short/generic base names are
    # excluded  -  'index' or 'app' as a substring would credit nearly every test.
    $stopNames = @('index', 'main', 'app', 'core', 'base', 'util', 'utils', 'types', 'common', 'shared', 'program', 'startup', 'module', 'config', 'constants', 'helpers')
    $targets = @()
    foreach ($cf in $changedFiles) {
        if ($cf.Path -notmatch $CodeFileRegex) { continue }
        if (Test-IsTestFile $cf.Path) { continue }
        $bn = [System.IO.Path]::GetFileNameWithoutExtension($cf.Path)
        if ($bn.Length -lt 4) { continue }
        if ($stopNames -contains $bn.ToLowerInvariant()) { continue }
        $gc = 0
        if ($gapCounts.ContainsKey($cf.Path)) { $gc = [int]$gapCounts[$cf.Path] }
        $covered = [math]::Max(0, $cf.ChangedLines - $gc)
        # Untracked files have no line counts: floor at 1 so a test that names a
        # brand-new class still outranks tests matching nothing.
        if ($cf.Untracked -and $covered -le 0) { $covered = 1 }
        $targets += [pscustomobject]@{ Path = $cf.Path; Basename = $bn; Covered = $covered; Matchers = 0 }
    }

    # Flatten per-test durations across runs; first occurrence of an FQN wins (artifact
    # order is deterministic, so re-runs rank identically).
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $tests = @()
    foreach ($run in $runs) {
        $pp = [string](Get-Prop $run 'projectPath' '')
        foreach ($ptd in @(Get-Prop $run 'perTestDurations' @())) {
            $fqn = [string](Get-Prop $ptd 'fqn' '')
            if ([string]::IsNullOrWhiteSpace($fqn)) { continue }
            if (-not $seen.Add($fqn)) { continue }
            $tests += [pscustomobject]@{ Fqn = $fqn; Seconds = [double](Get-Prop $ptd 'seconds' 0.0); ProjectPath = $pp }
        }
    }

    # Pass 1: match tests to files and count matchers per file (for uniqueness credit).
    $cand = @()
    foreach ($t in $tests) {
        $matched = @($targets | Where-Object { $t.Fqn.IndexOf($_.Basename, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if ($matched.Count -eq 0) { continue }
        foreach ($m in $matched) { $m.Matchers++ }
        $cand += [pscustomobject]@{ Test = $t; Matched = $matched }
    }
    # Pass 2: score. "Unique first" = lines in files this test is the ONLY matcher for.
    $ranked = @()
    foreach ($c in $cand) {
        $uniq = 0
        $total = 0
        foreach ($m in $c.Matched) {
            $total += [int]$m.Covered
            if ($m.Matchers -eq 1) { $uniq += [int]$m.Covered }
        }
        if ($total -le 0) { continue }
        $ranked += [pscustomobject]@{
            Fqn = $c.Test.Fqn; Seconds = $c.Test.Seconds; ProjectPath = $c.Test.ProjectPath
            Uniq = $uniq; Total = $total; MatchedCount = $c.Matched.Count
        }
    }
    # Final FQN tie-break keeps the ordering total, hence byte-stable across runs.
    $ranked = @($ranked | Sort-Object -Property `
        @{ Expression = 'Uniq'; Descending = $true }, `
        @{ Expression = 'Total'; Descending = $true }, `
        @{ Expression = 'Seconds'; Descending = $false }, `
        @{ Expression = 'Fqn'; Descending = $false })
    foreach ($r in @($ranked | Select-Object -First 3)) {
        $reason = if ($r.Uniq -gt 0) {
            'unique cover of {0} changed lines' -f $r.Uniq
        } else {
            'covers {0} changed lines across {1} changed file(s)' -f $r.Total, $r.MatchedCount
        }
        $topTests += [ordered]@{
            fqn        = $r.Fqn
            reason     = $reason
            runCommand = (Get-RunCommand $r.ProjectPath $r.Fqn)
        }
    }
}

# ---------------------------------------------------------------------------------------
# Write risk-score.json (idempotent overwrite) + single summary line
# ---------------------------------------------------------------------------------------

$doc = [ordered]@{
    score          = $score
    band           = $band
    hardOverride   = $hardOverride
    signals        = @($signalRows)
    renormalized   = ($missing.Count -gt 0)
    missingSignals = @($missing)
    confidence     = $confidence
    topTests       = @($topTests)
}

$outPath = Join-Path $workspaceDir 'risk-score.json'
$json = ConvertTo-Json -InputObject $doc -Depth 12
# WHY WriteAllText instead of Out-File -Encoding utf8: CONTRACTS.md mandates UTF-8
# WITHOUT BOM for every artifact, and PS 5.1's utf8 encoding always writes a BOM.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outPath, $json, $utf8NoBom)

$overrideText = 'none'
if ($null -ne $hardOverride) { $overrideText = $hardOverride }
Write-Output ("risk-score: score={0} band={1} override={2} confidence={3} missingSignals={4} -> {5}" -f $score, $band, $overrideText, $confidence, $missing.Count, $outPath)

# ---------------------------------------------------------------------------------------
# Write gap-lattice.json (GH issue #26) -- reuses $diffCov / $mut / $mutantsRaw already
# loaded above for the score's own signals. One tier per changed line, no double counting:
#   diff-coverage "uncovered"      -> "missing test"
#   diff-coverage "partial-branch" -> "missing case"
#   mutation-report Survived mutant (never NoCoverage -- that's a coverage finding, per
#   merge-mutation-reports.ps1's own header rule) -> "assertion too weak", which SUPERSEDES
#   any tier-1 entry already recorded at the same file:line (mutation is scoped to
#   changed-but-covered regions, so a real collision should be rare, but the merge still
#   enforces "supersedes, never both" rather than assuming that).
# ---------------------------------------------------------------------------------------

$latticeByKey = @{}   # "file|line" -> entry (PSCustomObject); re-sorted into an array below

$diffCoverageStatus = 'SKIPPED — no diff-coverage.json this run'
if ($null -ne $diffCov) {
    if ([bool](Get-Prop $diffCov 'refused' $false)) {
        $diffCoverageStatus = 'DEGRADED — ' + [string](Get-Prop $diffCov 'refusalReason' '')
    } else {
        $diffCoverageStatus = 'OK'
        foreach ($gap in @(Get-Prop $diffCov 'gaps' @())) {
            $gFile = [string](Get-Prop $gap 'file' '')
            $gLineRaw = Get-Prop $gap 'line' $null
            if ([string]::IsNullOrWhiteSpace($gFile) -or $null -eq $gLineRaw) { continue }
            $gKind = [string](Get-Prop $gap 'kind' '')
            $key = "$gFile|$gLineRaw"
            if ($gKind -eq 'uncovered') {
                $latticeByKey[$key] = [pscustomobject]@{
                    kind = 'missing test'; file = $gFile; line = [int]$gLineRaw
                    detail = 'no test currently covers this changed line'
                    coveringTest = $null
                }
            } elseif ($gKind -eq 'partial-branch') {
                $cc = [string](Get-Prop $gap 'conditionCoverage' '')
                $method = [string](Get-Prop $gap 'enclosingMethod' '')
                $detail = if ($method) { "branch coverage $cc in $method — one arm never runs under test" }
                          else { "branch coverage $cc — one arm never runs under test" }
                $latticeByKey[$key] = [pscustomobject]@{
                    kind = 'missing case'; file = $gFile; line = [int]$gLineRaw
                    detail = $detail
                    coveringTest = $null
                }
            }
        }
    }
}

$mutationStatus = 'SKIPPED — mutation not run this run'
if ($null -ne $mut) {
    $mutationStatus = 'OK'

    # testId -> name, from mutation-report.json's own testFiles{} -- the inverse of the
    # name -> id map merge-mutation-reports.ps1 builds while merging.
    $testIdToName = @{}
    $testFilesMapForLattice = Get-Prop $mut 'testFiles'
    if ($null -ne $testFilesMapForLattice) {
        foreach ($tfProp in $testFilesMapForLattice.PSObject.Properties) {
            foreach ($t in @(Get-Prop $tfProp.Value 'tests' @())) {
                $tid = [string](Get-Prop $t 'id' '')
                $tname = [string](Get-Prop $t 'name' '')
                if ($tid -ne '' -and $tname -ne '' -and -not $testIdToName.ContainsKey($tid)) {
                    $testIdToName[$tid] = $tname
                }
            }
        }
    }

    # bare numeric id (no "agentq-" prefix) -> filter, from mutants.json -- the only
    # covering-test signal a semantic mutant carries once merged, since
    # merge-mutation-reports.ps1 does not copy coveredBy over for them.
    $semanticFilterById = @{}
    if ($null -ne $mutantsRaw) {
        foreach ($sm in @(Get-Prop $mutantsRaw 'mutants' @())) {
            $smId = [string](Get-Prop $sm 'id' '')
            $smFilter = [string](Get-Prop $sm 'filter' '')
            if ($smId -ne '' -and $smFilter -ne '') { $semanticFilterById[$smId] = $smFilter }
        }
    }

    $filesMapForLattice = Get-Prop $mut 'files'
    if ($null -ne $filesMapForLattice) {
        foreach ($fp in $filesMapForLattice.PSObject.Properties) {
            $fFile = $fp.Name
            foreach ($m in @(Get-Prop $fp.Value 'mutants' @())) {
                # Every Survived mutant counts here -- mechanical and semantic alike --
                # unlike s2 above, which only tracks BusinessRule/-prefixed ones for the
                # score. NoCoverage is suppressed: it never ran, so it is a coverage
                # finding (tier 1 above), not a mutation finding.
                if ([string](Get-Prop $m 'status' '') -ne 'Survived') { continue }
                $loc = Get-Prop $m 'location'
                $start = Get-Prop $loc 'start'
                $mLineRaw = Get-Prop $start 'line' $null
                if ($null -eq $mLineRaw) { continue }

                $coveringTest = $null
                $coveredBy = @(Get-Prop $m 'coveredBy' @())
                if (@($coveredBy).Count -gt 0) {
                    $names = @($coveredBy | ForEach-Object { $testIdToName[[string]$_] } | Where-Object { $_ } | Select-Object -Unique)
                    if (@($names).Count -gt 0) { $coveringTest = ($names -join ', ') }
                }
                $mId = [string](Get-Prop $m 'id' '')
                if ($null -eq $coveringTest -and $mId.StartsWith('agentq-')) {
                    $bareId = $mId.Substring(7)
                    if ($semanticFilterById.ContainsKey($bareId)) {
                        # Plain text, no markdown -- this is a JSON data artifact, not a
                        # rendered string; render-evidence.ps1 wraps it in backticks itself.
                        $coveringTest = "test class matching $($semanticFilterById[$bareId])"
                    }
                }

                $mutatorName = [string](Get-Prop $m 'mutatorName' '')
                $desc = [string](Get-Prop $m 'description' '')
                if ([string]::IsNullOrWhiteSpace($desc)) {
                    # Stryker's own mechanical mutants frequently leave description empty --
                    # fall back to the mutated replacement code, same convention
                    # render-evidence.ps1's Build-MutationLevel already uses.
                    $repl = [string](Get-Prop $m 'replacement' '')
                    $desc = if ($repl) { "mutated to: ``$repl``" } else { '(no description available)' }
                }
                $detail = if ($mutatorName) { "$mutatorName — $desc" } else { $desc }

                $key = "$fFile|$mLineRaw"
                $latticeByKey[$key] = [pscustomobject]@{
                    kind = 'assertion too weak'; file = $fFile; line = [int]$mLineRaw
                    detail = $detail
                    coveringTest = $coveringTest
                }
            }
        }
    }
}

# Ordinal file/line sort -- same "byte-identical artifact" determinism contract every
# script in this repo follows.
$latticeEntries = @($latticeByKey.Values | Sort-Object -Property 'file', 'line')

$latticeDoc = [ordered]@{
    diffCoverageStatus = $diffCoverageStatus
    mutationStatus     = $mutationStatus
    entries            = $latticeEntries
}

$latticeOutPath = Join-Path $workspaceDir 'gap-lattice.json'
$latticeJson = ConvertTo-Json -InputObject $latticeDoc -Depth 12
[System.IO.File]::WriteAllText($latticeOutPath, $latticeJson, $utf8NoBom)

$latticeCounts = @{ 'missing test' = 0; 'missing case' = 0; 'assertion too weak' = 0 }
foreach ($e in $latticeEntries) {
    $k = [string]$e.kind
    if ($latticeCounts.ContainsKey($k)) { $latticeCounts[$k]++ }
}
Write-Output ("gap-lattice: {0} missing test + {1} missing case + {2} assertion too weak (diffCoverage={3}, mutation={4}) -> {5}" -f `
    $latticeCounts['missing test'], $latticeCounts['missing case'], $latticeCounts['assertion too weak'], $diffCoverageStatus, $mutationStatus, $latticeOutPath)
