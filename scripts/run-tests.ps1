#Requires -Version 5.1
# =============================================================================
# run-tests.ps1  -  agentQ Phase 2 (unit level) and Phase 7 (generated-test execution)
#
# Inputs (shapes in scripts/CONTRACTS.md):
#   -Manifest                  run-manifest.json (workspaceDir, worktreeDir, repoPath)
#   <workspace>/diff-set.json          changed files + hunks (+ untracked), for the
#                                      affected-subset filter derivation
#   <workspace>/adapter-profiles.json  per-test-project framework/runner/filter/
#                                      coverage/placement facts (qa-intake's output)
#
# Output:
#   <workspace>/test-results.json   { runs: [...], flaky: {...} }  (CONTRACTS.md)
#     (-GeneratedOnly writes test-results-generated[-<ResultsLabel>].json instead)
#   <workspace>/cov/*.cobertura.xml  or <trx-results>/**/coverage.cobertura.xml
#   <workspace>/../calibration.json  merged plainRunSeconds + coverage capability
#     (coverage.dotnetCoverageWorks / coverage.collectorWorks  -  CONTRACTS.md)
#
# Exit code 0 = the script ran (failures/zero-match/timeouts are FINDINGS in the
# artifact); non-zero = the script itself broke. Exactly one summary line to stdout.
#
# Guardrails encoded here (each verified  -  see comments at the site of use):
#   * build the affected PROJECT GRAPH once, never a whole solution (e-conomic is
#     426 projects)  -  everything after the build is --no-build --no-restore
#   * filters are built PER TEST PROJECT from the adapter profile: xUnit has no
#     TestCategory (silently matches nothing  -  verified), it needs the trait form
#     Category=; NUnit uses TestCategory=. FullyQualifiedName~ (contains), never
#     "=" (parameterized test names are argument-decorated)
#   * affected-class derivation covers BOTH sides of the diff: SUT files map to
#     <Class>Tests/<Class>Test, and changed files under the TEST project's own dir
#     map to their own class names (verified live: without the test-side rule, a
#     branch touching only test-project files fell through to an unfiltered run)
#   * a profile marked suiteScope: "solution-wide" (arch/static-analysis suites
#     that scan the entire solution) is NEVER run unfiltered off the diff
#     heuristic  -  verified live: one such suite (371 tests, 5m19s) dominated a
#     whole review's wall-clock while contributing nothing diff-relevant. No
#     derived classes -> honest SKIPPED entry. There is NO local override: the PR
#     pipeline runs the full suite on every PR, so a local run-everything mode
#     buys nothing (removed by design, not omitted).
#   * RunConfiguration.TreatNoTestsAsError=true on every invocation  -  a filter
#     matching zero tests otherwise exits 0 and would read as a pass
#   * coverage is a WRAPPER around the test run (dotnet-coverage collect, or the
#     XPlat collector when coverlet.collector is already referenced)  -  never a
#     csproj edit; wrapped runs carry an anti-hang wall-clock kill because
#     coverage instrumentation has documented 4x-47x pathological blowups
#   * coverage degrade NEVER re-runs a completed suite: only a TIMED-OUT wrapped
#     run (no trustworthy TRX) re-runs plainly. A wrapped run that completed but
#     yielded no parseable class data keeps its real TRX results and records the
#     mechanism as broken in calibration.json (coverage.dotnetCoverageWorks /
#     coverage.collectorWorks), so the NEXT run skips instrumentation up front
#     (verified live: the old degrade path re-ran a 5m19s suite in full, twice)
#   * JS selection is file-granular, always: per-project `jest --findRelatedTests`
#     over the changed files, per-test JSON results, and cobertura coverage renamed
#     into cov\ so diff-coverage.ps1 can read the JS lane. Dependent projects are
#     NOT run locally  -  stated in the entry's selectionNote, never silently
#     implied covered; the PR pipeline runs the full suite plus ui-automation on
#     every PR, so no local run-everything mode exists (removed by design  -
#     verified live before removal: `nx affected` turned a 4-file leaf diff into
#     40 projects / 2504 tests / 13 min of load-flaky noise)
#   * NO flaky re-runs, by design: re-running the subset 3x multiplied wall-clock
#     for signal a developer can get themselves in seconds. Every failed test is
#     instead tagged MIGHT-BE-FLAKY in the artifact with a ready-to-run rerun
#     command  -  a pass on the developer's own re-run (outside agentQ) suggests
#     flaky; a repeat fail is a real failure. Never assert "flaky" from one run.
#   * -GeneratedOnly targets the WORKTREE and the profile's categoryFilter, never
#     the affected-subset heuristic  -  Phase 7's generated tests are the exact set.
#     It writes test-results-generated[-<label>].json, NEVER test-results.json  -
#     verified live: it used to clobber Phase 2's unit results
#   * cross-platform (Windows + macOS): a repo-relative path from diff-set.json/
#     adapter-profiles.json always uses git's '/' -- every join against it goes
#     through `-replace '/', [IO.Path]::DirectorySeparatorChar` (identity on
#     macOS/Linux, backslash on Windows as before), never a literal '\'
# =============================================================================
[CmdletBinding()]
param(
    # Path to run-manifest.json for this run (see scripts/CONTRACTS.md).
    [Parameter(Mandatory = $true)]
    [string]$Manifest,

    # Phase 7 mode: run only the profile's agentQ-generated category, in the
    # worktree, instead of the Phase 2 affected-subset heuristic in the repo.
    [switch]$GeneratedOnly,

    # -GeneratedOnly execution root override: point at the persistent BASE worktree
    # (worktree.ps1 -EnsureBase) for the anti-vacuity run instead of flipping the
    # main worktree back and forth (each flip cost a full checkout + rebuild).
    [string]$WorktreeRoot = '',

    # -GeneratedOnly artifact suffix: test-results-generated-<label>.json, so the
    # branch-side and base-side (anti-vacuity) runs never clobber each other.
    [string]$ResultsLabel = '',

    # Skip coverage collection entirely (e.g. a Phase-7 re-run where Phase 2
    # already produced the diff-coverage numbers this run doesn't need again).
    [switch]$SkipCoverage,

    # Re-probe a coverage mechanism that calibration.json recorded as broken on
    # this machine (coverage.dotnetCoverageWorks / coverage.collectorWorks = false).
    [switch]$ForceCoverage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Cross-platform (Windows + macOS/Linux): $IsWindows doesn't exist on Windows
# PowerShell 5.1, and StrictMode turns a bare reference into a terminating error.
# WHY this matters here specifically: this file's own test-run anti-hang valve
# (`$r.Proc.Kill($true)`, further down) relies on .NET's entire-process-tree
# Kill() overload, which Windows PowerShell 5.1's .NET Framework does NOT have --
# unlike stryker-run.ps1/semantic-mutant-driver.ps1, this file had no $IsWin probe
# at all before this fix. The probe is added now for the new coverlet-install
# timeout below; the pre-existing `.Kill($true)` call sites are a separate,
# already-shipped code path and are noted here, not changed, to keep this fix
# scoped to its own timeout gap.
$script:IsWin = $true
$__winVar = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
if ($null -ne $__winVar) { $script:IsWin = [bool]$__winVar.Value }

# WHY: git/dotnet emit UTF-8; PS 5.1's OEM-codepage console decoding would mangle
# non-ASCII test/file names before they round-trip into the JSON artifact.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# -----------------------------------------------------------------------------
# helpers  -  kept byte-identical to the other scripts' conventions on purpose
# -----------------------------------------------------------------------------

function Get-Prop {
    # StrictMode-safe property access on PSCustomObjects deserialized from JSON  -
    # a missing property must yield a default, not a terminating error.
    # WHY the IDictionary branch: this script's own in-memory run entries are
    # [ordered] dictionaries, and PSObject.Properties does NOT expose dictionary
    # KEYS (verified live on this build: the summary line read "0/0 passed" over
    # an artifact holding 2504 tests, and the flaky baseline silently came back
    # empty)  -  keys must be read via the dictionary API.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $Default
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-JsonFileNoBom {
    # WHY .NET WriteAllText instead of Out-File: CONTRACTS.md mandates "UTF-8, no
    # BOM"; PS 5.1's Out-File -Encoding utf8 always emits a BOM.
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $json = ConvertTo-Json -InputObject $Object -Depth 12
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $enc)
}

function Get-LogicalCoreCount {
    try { return [Environment]::ProcessorCount } catch { return 4 }
}

function Find-NearestNuGetConfig {
    # Mirrors NuGet's own directory walk-up (project dir -> ancestors, stopping at
    # the repo root) so we only act when normal `dotnet build` discovery would
    # ALREADY fail -- every repo whose layout already works (an ancestor
    # nuget.config) is left byte-for-byte unaffected by the fallback below.
    param([Parameter(Mandatory = $true)][string]$StartDir, [Parameter(Mandatory = $true)][string]$CeilingDir)
    $ceiling = ((Resolve-Path -LiteralPath $CeilingDir).Path).TrimEnd('\', '/')
    $dir = $StartDir
    while ($true) {
        $hit = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^nuget\.config$' }) | Select-Object -First 1
        if ($hit) { return $hit.FullName }
        if ($dir.TrimEnd('\', '/') -ieq $ceiling) { break }
        $parent = Split-Path -Parent $dir
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

$script:nugetConfigOverrideCache = @{}
function Get-RepoNuGetConfigOverride {
    # WHY: verified live on payroll-poc  -  its private feed is declared in
    # apps/backend/src/nuget.config, but a test project under apps/backend/tests/
    # is a SIBLING of src/, not a descendant, so NuGet's own directory walk-up
    # never finds it and restore falls back to nuget.org alone (NU1101 on an
    # internal package). Only kicks in when normal discovery would already fail;
    # only acts when the repo has exactly one such file so this never guesses
    # between competing configs -- an ambiguous or absent case is left to fail
    # exactly as honestly as it does today.
    param([Parameter(Mandatory = $true)][string]$ProjAbs, [Parameter(Mandatory = $true)][string]$RepoPath)
    $cacheKey = "$RepoPath|$ProjAbs"
    if ($script:nugetConfigOverrideCache.ContainsKey($cacheKey)) { return $script:nugetConfigOverrideCache[$cacheKey] }
    $projDir = Split-Path -Parent $ProjAbs
    $result = $null
    if (-not (Find-NearestNuGetConfig -StartDir $projDir -CeilingDir $RepoPath)) {
        $seen = @{}
        $all = New-Object System.Collections.Generic.List[string]
        foreach ($pattern in @('nuget.config', 'NuGet.Config')) {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($RepoPath, $pattern, [System.IO.SearchOption]::AllDirectories)) {
                if ($f -match '[\\/](bin|obj|node_modules|\.git)[\\/]') { continue }
                $key = $f.ToLowerInvariant()
                if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $all.Add($f) }
            }
        }
        if ($all.Count -eq 1) { $result = $all[0] }
    }
    $script:nugetConfigOverrideCache[$cacheKey] = $result
    return $result
}

function Invoke-JestRelatedRun {
    # File-granular JS selection: per-project `jest --findRelatedTests <changed
    # files>` with per-test JSON results.
    # WHY direct jest with the project's own config, not `nx test <proj>`: nx adds
    # graph-computation startup cost and another arg-quoting layer for zero gain
    # here  -  the config file carries the project context jest needs (verified live
    # on e-conomic/client: libs/<proj>/jest.config.ts runs standalone).
    param(
        [Parameter(Mandatory = $true)]$Prof,
        [Parameter(Mandatory = $true)][string]$ExecRoot,
        [Parameter(Mandatory = $true)][string]$WorkspaceDir,
        [Parameter(Mandatory = $true)][AllowNull()]$DiffSet,
        [Parameter(Mandatory = $true)][string]$CovDir,
        [bool]$WantCoverage = $false
    )
    $projRoot = (([string](Get-Prop $Prof 'projectPath' '')) -replace '\\', '/').TrimEnd('/')
    $projKey = $projRoot -replace '[\\/:]', '_'
    if ($projKey -eq '') { $projKey = 'root' }
    $result = @{ SkippedNoFiles = $false; RelatedFileCount = 0; Command = $null; ExitCode = 0
                 ZeroMatch = $false; ResultsFile = $null; CoverageWritten = $false
                 Trx = [ordered]@{ Executed = 0; Passed = 0; Failed = 0; Skipped = 0; Failures = @(); PerTestDurations = @() } }

    # Changed JS files (diff ∪ untracked, non-deleted, no .d.ts) under this project.
    $prefix = ''
    if ($projRoot -ne '') { $prefix = "$projRoot/" }
    $changedAbs = New-Object System.Collections.Generic.List[string]
    if ($null -ne $DiffSet) {
        $rels = New-Object System.Collections.Generic.List[string]
        foreach ($f in @(Get-Prop $DiffSet 'files' @())) {
            if ([string](Get-Prop $f 'status' '') -eq 'D') { continue }
            # WHY the extra parens: inside a method-call argument list, PS parses
            # `-replace 'a', 'b'` as TWO arguments (the comma splits) - verified.
            $rels.Add((([string](Get-Prop $f 'path' '')) -replace '\\', '/'))
        }
        foreach ($u in @(Get-Prop $DiffSet 'untracked' @())) { $rels.Add((([string]$u) -replace '\\', '/')) }
        foreach ($p in $rels) {
            if ($p -notmatch '\.(js|jsx|ts|tsx)$' -or $p -match '\.d\.ts$') { continue }
            if ($prefix -ne '' -and -not $p.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $abs = Join-Path $ExecRoot ($p -replace '/', [IO.Path]::DirectorySeparatorChar)
            if (Test-Path -LiteralPath $abs -PathType Leaf) { $changedAbs.Add($abs) }
        }
    }
    if ($changedAbs.Count -eq 0) { $result.SkippedNoFiles = $true; return $result }
    $result.RelatedFileCount = $changedAbs.Count

    $projDirAbs = $ExecRoot
    if ($projRoot -ne '') { $projDirAbs = Join-Path $ExecRoot ($projRoot -replace '/', [IO.Path]::DirectorySeparatorChar) }
    $jestCfg = $null
    foreach ($cand in @('jest.config.ts', 'jest.config.js', 'jest.config.cjs', 'jest.config.mjs')) {
        $p = Join-Path $projDirAbs $cand
        if (Test-Path -LiteralPath $p -PathType Leaf) { $jestCfg = $p; break }
    }

    $resultsFile = Join-Path $WorkspaceDir "jest-results-$projKey.json"
    $result.ResultsFile = $resultsFile
    # WHY --passWithNoTests: "no tests relate to these changed files" is a real
    # coverage signal, not a runner failure  -  the caller reads it off ZeroMatch
    # (Executed = 0), which can never render as a pass downstream.
    $cmd = @('jest', '--ci', '--silent', '--json', "--outputFile=$resultsFile", '--passWithNoTests')
    if ($null -ne $jestCfg) { $cmd += @('--config', $jestCfg) }
    $covOutDir = $null
    if ($WantCoverage) {
        # cobertura, because diff-coverage.ps1 parses cobertura only  -  the old
        # json-summary reporter produced nothing it could read (verified live:
        # the whole JS lane's changed-line coverage came back REFUSED).
        $covOutDir = Join-Path $CovDir "jest-$projKey"
        $cmd += @('--coverage', '--coverageReporters=cobertura', "--coverageDirectory=$covOutDir")
    }
    $cmd += @('--findRelatedTests') + @($changedAbs)
    $result.Command = "npx $($cmd -join ' ')"

    $prevCi = $env:CI; $prevForceColor = $env:FORCE_COLOR
    $env:CI = 'true'; $env:FORCE_COLOR = '0'
    Push-Location $(if ($null -ne $jestCfg) { $ExecRoot } else { $projDirAbs })
    # WHY not `2>&1`: PS 5.1 wraps redirected native stderr in ErrorRecords, which
    # $ErrorActionPreference='Stop' promotes to terminating errors (same fix as the
    # nx branch  -  a benign npm notice crashed a live run).
    try { & npx @cmd | Out-Null; $result.ExitCode = $LASTEXITCODE }
    finally { $env:CI = $prevCi; $env:FORCE_COLOR = $prevForceColor; Pop-Location }

    if (Test-Path -LiteralPath $resultsFile) {
        $jr = Read-JsonFile -Path $resultsFile
        $result.Trx.Executed = [int](Get-Prop $jr 'numTotalTests' 0)
        $result.Trx.Passed = [int](Get-Prop $jr 'numPassedTests' 0)
        $result.Trx.Failed = [int](Get-Prop $jr 'numFailedTests' 0)
        foreach ($tr in @(Get-Prop $jr 'testResults' @())) {
            # repo-relative test-file path, for the human-facing rerun command
            $trFile = ([string](Get-Prop $tr 'name' '')) -replace '\\', '/'
            $rootFwd = ($ExecRoot -replace '\\', '/').TrimEnd('/') + '/'
            if ($trFile.StartsWith($rootFwd, [System.StringComparison]::OrdinalIgnoreCase)) { $trFile = $trFile.Substring($rootFwd.Length) }
            foreach ($ar in @(Get-Prop $tr 'assertionResults' @())) {
                $status = [string](Get-Prop $ar 'status' '')
                $title = [string](Get-Prop $ar 'fullName' '')
                $dur = [double](Get-Prop $ar 'duration' 0) / 1000.0
                $result.Trx.PerTestDurations = @($result.Trx.PerTestDurations) + @(@{ fqn = $title; seconds = [math]::Round($dur, 3) })
                if ($status -eq 'failed') {
                    $msgs = @(Get-Prop $ar 'failureMessages' @()) -join "`n"
                    # Ready-to-run command for the developer's OWN re-run (outside
                    # agentQ)  -  -t takes a regex, so the test name is escaped.
                    $cfgRel = ''
                    if ($null -ne $jestCfg) { $cfgRel = "--config $projRoot/$([System.IO.Path]::GetFileName($jestCfg)) " }
                    $rerun = "npx jest $cfgRel`"$trFile`" -t `"$([regex]::Escape($title))`""
                    $result.Trx.Failures = @($result.Trx.Failures) + @(@{ fqn = $title; file = $trFile; message = $msgs; stack = ''; rerunCommand = $rerun })
                }
            }
        }
    }
    $result.ZeroMatch = ($result.Trx.Executed -eq 0)

    if ($WantCoverage -and $null -ne $covOutDir) {
        # istanbul's cobertura reporter writes a fixed 'cobertura-coverage.xml';
        # diff-coverage.ps1 discovers cov\*.cobertura.xml  -  copy under that name.
        $covXml = Join-Path $covOutDir 'cobertura-coverage.xml'
        if (Test-Path -LiteralPath $covXml) {
            Copy-Item -LiteralPath $covXml -Destination (Join-Path $CovDir "$projKey.cobertura.xml") -Force
            $result.CoverageWritten = $true
        }
    }
    return $result
}

# -----------------------------------------------------------------------------
# TRX parsing (VSTest logger output  -  shared by every .NET project regardless
# of xUnit/NUnit/adapter, since all of them run under the same `dotnet test`).
# -----------------------------------------------------------------------------

function Read-TrxResult {
    # Returns @{ Executed; Passed; Failed; Skipped; ZeroMatch; Failures[]; PerTestDurations[] }
    # ZeroMatch is derived, not read off a field: VSTest exits 0 on a filter that
    # matches nothing UNLESS TreatNoTestsAsError=true made it fail  -  either way,
    # "Executed=0" with no build/timeout error is itself the zero-match signal,
    # so callers must not need to special-case exit code to detect it.
    param([Parameter(Mandatory = $true)][string]$TrxPath)

    $result = [ordered]@{
        Executed          = 0
        Passed            = 0
        Failed            = 0
        Skipped           = 0
        Failures          = New-Object System.Collections.Generic.List[object]
        PerTestDurations  = New-Object System.Collections.Generic.List[object]
    }
    if (-not (Test-Path -LiteralPath $TrxPath -PathType Leaf)) { return $result }

    [xml]$trx = Get-Content -LiteralPath $TrxPath -Raw -Encoding UTF8
    # WHY XPath with a namespace manager: TRX declares a default xmlns, so
    # unqualified SelectNodes silently matches nothing under PS 5.1's XmlDocument.
    $nsMgr = New-Object System.Xml.XmlNamespaceManager($trx.NameTable)
    $nsMgr.AddNamespace('t', 'http://microsoft.com/schemas/VisualStudio/TeamTest/2010')

    $summary = $trx.SelectSingleNode('//t:ResultSummary/t:Counters', $nsMgr)
    if ($null -ne $summary) {
        $result.Executed = [int]$summary.executed
        $result.Passed = [int]$summary.passed
        $result.Failed = [int]$summary.failed
    }

    $unitResults = $trx.SelectNodes('//t:Results/t:UnitTestResult', $nsMgr)
    foreach ($ur in $unitResults) {
        $outcome = [string]$ur.outcome
        $name = [string]$ur.testName
        $durationRaw = [string]$ur.duration
        $seconds = 0.0
        if (-not [string]::IsNullOrWhiteSpace($durationRaw)) {
            try {
                $ts = [TimeSpan]::Parse($durationRaw)
                $seconds = [math]::Round($ts.TotalSeconds, 3)
            } catch { $seconds = 0.0 }
        }
        $null = $result.PerTestDurations.Add([ordered]@{ fqn = $name; seconds = $seconds })

        if ($outcome -eq 'NotExecuted' -or $outcome -eq 'Pending') { $result.Skipped++ }
        if ($outcome -eq 'Failed') {
            $errInfo = $ur.SelectSingleNode('.//t:Output/t:ErrorInfo', $nsMgr)
            $msg = ''
            $stack = ''
            if ($null -ne $errInfo) {
                $msgNode = $errInfo.SelectSingleNode('t:Message', $nsMgr)
                $stackNode = $errInfo.SelectSingleNode('t:StackTrace', $nsMgr)
                if ($null -ne $msgNode) { $msg = [string]$msgNode.InnerText }
                if ($null -ne $stackNode) { $stack = [string]$stackNode.InnerText }
            }
            $null = $result.Failures.Add([ordered]@{ fqn = $name; message = $msg; stack = $stack })
        }
    }
    return $result
}

# -----------------------------------------------------------------------------
# .NET filter construction  -  the framework trap this whole function exists for.
# -----------------------------------------------------------------------------

function Get-DotnetTestFilter {
    # Verified: on xUnit, "TestCategory=" matches nothing at all  -  categories are
    # traits, filtered as "Category=". NUnit uses "TestCategory=" (also accepts
    # "Category=" as an alias, but we emit the canonical form per framework so a
    # human reading the run command sees the right mental model).
    param(
        [Parameter(Mandatory = $true)][string]$Framework,     # xunit | nunit3 | nunit4
        [string[]]$TestClasses,                                # affected-subset mode
        [switch]$GeneratedCategory                             # Phase 7 mode
    )
    if ($GeneratedCategory) {
        if ($Framework -eq 'xunit') { return 'Category=agentQ-generated' }
        return 'TestCategory=agentQ-generated'
    }
    if (-not $TestClasses -or $TestClasses.Count -eq 0) { return $null }
    # "~" is contains, never "="  -  NUnit/xUnit both argument-decorate parameterized
    # test names, so an exact match on the bare class name would miss every case.
    $terms = @($TestClasses | ForEach-Object { "FullyQualifiedName~$_" })
    return ($terms -join '|')
}

function Get-ChangedCsPaths {
    # Changed .cs paths = diff files (non-deleted) UNION untracked. WHY the union:
    # a developer's brand-new, not-yet-git-added test or helper is exactly the code
    # most in need of scoping, and the diff's `files` list misses it (same rule the
    # mutation lane already applies in stryker-run.ps1).
    param([Parameter(Mandatory = $true)][AllowNull()]$DiffSet)
    $paths = New-Object System.Collections.Generic.List[string]
    if ($null -eq $DiffSet) { return ,@() }
    foreach ($f in @(Get-Prop $DiffSet 'files' @())) {
        if ([string](Get-Prop $f 'status' '') -eq 'D') { continue }
        $p = ([string](Get-Prop $f 'path' '')) -replace '\\', '/'
        if ($p -match '\.cs$') { $paths.Add($p) }
    }
    foreach ($u in @(Get-Prop $DiffSet 'untracked' @())) {
        $p = ([string]$u) -replace '\\', '/'
        if ($p -match '\.cs$') { $paths.Add($p) }
    }
    return ,@($paths | Select-Object -Unique)
}

function Get-AffectedTestClasses {
    # Heuristic bridge from "these files changed" to "these test classes cover
    # them", since .NET (unlike Jest) has no built-in file-level reverse-dependency
    # flag. Two derivations, unioned:
    #  * SUT-side: a changed file under a sutProjects dir -> <Base>Tests / <Base>Test
    #    (the dominant naming convention across all four target repos).
    #  * Test-side: a changed file under the TEST project's OWN dir is (or feeds) a
    #    test class -> its own basename, plus the suffixed forms when it isn't
    #    already Test/Tests-named. WHY this rule exists: verified live  -  a branch
    #    that touched only test-project files derived ZERO classes from the SUT-side
    #    rule, fell through to an unfiltered run, and dragged a 371-test
    #    solution-wide suite (5m19s) into the "affected subset" of a 30-file diff.
    # What an EMPTY result means is the caller's decision, per the profile's
    # suiteScope (diff-sensitive falls back to unfiltered; solution-wide skips).
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][AllowNull()]$DiffSet
    )
    if ($null -eq $DiffSet) { return @() }
    # WHY plain assignment, NOT @(...): Get-ChangedCsPaths returns via the ,@()
    # comma-wrap (survives the return boundary at 0/1/N items); wrapping that call
    # in @() NESTS the array (verified live: foreach then iterated ONE object[]
    # item, member enumeration turned .StartsWith into an always-truthy bool[],
    # and every profile derived classes from the wrong files).
    $changed = Get-ChangedCsPaths -DiffSet $DiffSet
    if (@($changed).Count -eq 0) { return @() }

    $sutDirs = @()
    foreach ($s in @(Get-Prop $Profile 'sutProjects' @())) {
        $sutDirs += ((([string]$s) -replace '\\', '/') -replace '/[^/]+\.csproj$', '').ToLowerInvariant()
    }
    $testProjDir = (((([string](Get-Prop $Profile 'projectPath' '')) -replace '\\', '/')) -replace '/[^/]+\.csproj$', '').ToLowerInvariant()

    $classes = New-Object System.Collections.Generic.List[string]
    foreach ($path in $changed) {
        $lower = $path.ToLowerInvariant()
        $base = [System.IO.Path]::GetFileNameWithoutExtension($path)
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $underSut = $false
        foreach ($d in $sutDirs) {
            if ($d -ne '' -and $lower.StartsWith("$d/")) { $underSut = $true; break }
        }
        if ($underSut) {
            $null = $classes.Add("${base}Tests")
            $null = $classes.Add("${base}Test")
            continue
        }
        if ($testProjDir -ne '' -and $lower.StartsWith("$testProjDir/")) {
            # The changed file may itself be the fixture (filter to its own class
            # name) or a helper named after its SUT (suffixed forms cover that).
            $null = $classes.Add($base)
            if ($base -notmatch '(Tests?|Fixture)$') {
                $null = $classes.Add("${base}Tests")
                $null = $classes.Add("${base}Test")
            }
        }
    }
    return @($classes | Select-Object -Unique)
}

# -----------------------------------------------------------------------------
# .NET execution engine  -  specs + bounded-concurrency scheduler.
# Each test project becomes ONE spec (plain, collector-wrapped, or
# dotnet-coverage-wrapped  -  the wrapper choice is baked into Exe/Args at
# schedule time). Specs that CANNOT boot a WebApplicationFactory run in a
# parallel lane (throttle 3, MaxCpuCount divided so total machine load stays
# ~constant); factory-booting projects run strictly one-at-a-time with all
# cores  -  the factory's non-configurable 5s host-build timeout is
# load-sensitive, and sharing the machine manufactures false reds (the exact
# failure mode measured in the 40-project parallel nx run).
# -----------------------------------------------------------------------------

function Test-BootsWebFactory {
    # TRUE when the test project can boot a WebApplicationFactory: its csproj
    # references Microsoft.AspNetCore.Mvc.Testing directly, or via ONE level of
    # ProjectReference (e-conomic hosts the factory infra in a shared
    # Tests.Common project). Unreadable csproj -> $true: the safe side is the
    # sequential lane, never a maybe-flaky parallel run.
    param([Parameter(Mandatory = $true)][string]$ProjAbs)
    try {
        if (Select-String -LiteralPath $ProjAbs -Pattern 'Microsoft\.AspNetCore\.Mvc\.Testing' -Quiet) { return $true }
        $projDir = Split-Path -Parent $ProjAbs
        $raw = [System.IO.File]::ReadAllText($ProjAbs)
        foreach ($m in [regex]::Matches($raw, '<ProjectReference\s+Include="([^"]+)"')) {
            $refAbs = [System.IO.Path]::GetFullPath((Join-Path $projDir ($m.Groups[1].Value -replace '/', [IO.Path]::DirectorySeparatorChar)))
            if ((Test-Path -LiteralPath $refAbs -PathType Leaf) -and
                (Select-String -LiteralPath $refAbs -Pattern 'Microsoft\.AspNetCore\.Mvc\.Testing' -Quiet)) { return $true }
        }
        return $false
    } catch { return $true }
}

function Start-SpecProcess {
    # Starts ONE spec's native process. No stream redirection  -  same as the old
    # coverage wrapper: child console noise is harmless (the script's stdout
    # contract is the single summary line), and PSI redirection without a drain
    # thread deadlocks on chatty children.
    # WHY try/catch on Start: the spec's exe may not exist on this machine
    # (verified live: dotnet-coverage missing -> Win32Exception killed the lane).
    param($Spec)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Spec.Exe
    foreach ($a in @($Spec.Args)) { $null = $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $Spec.WorkDir
    $psi.UseShellExecute = $false
    try { return @{ Proc = [System.Diagnostics.Process]::Start($psi); StartFailed = $false } }
    catch { return @{ Proc = $null; StartFailed = $true } }
}

function Invoke-SpecBatch {
    # Bounded-concurrency scheduler. Fills up to $Throttle slots, polls, refills.
    # Every spec carries its own anti-hang deadline; tripping it kills the whole
    # process tree and marks the spec TimedOut  -  identical valve semantics to
    # the old sequential path, now also covering PLAIN runs (a wedged testhost
    # used to hang the script forever). Results land in $spec.Result.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Specs,
        [Parameter(Mandatory = $true)][int]$Throttle
    )
    if (@($Specs).Count -eq 0) { return }
    $pending = New-Object 'System.Collections.Generic.Queue[object]'
    foreach ($s in @($Specs)) { $pending.Enqueue($s) }
    $running = New-Object 'System.Collections.Generic.List[object]'
    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
        while ($pending.Count -gt 0 -and $running.Count -lt $Throttle) {
            $spec = $pending.Dequeue()
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $st = Start-SpecProcess -Spec $spec
            if ($st.StartFailed) {
                $sw.Stop()
                $spec.Result = @{ ExitCode = -1; TimedOut = $false; StartFailed = $true; DurationSeconds = 0.0 }
                continue
            }
            $running.Add(@{ Spec = $spec; Proc = $st.Proc; Sw = $sw })
        }
        if ($running.Count -eq 0) { continue }
        Start-Sleep -Milliseconds 300
        for ($i = $running.Count - 1; $i -ge 0; $i--) {
            $r = $running[$i]
            if ($r.Proc.HasExited) {
                $r.Sw.Stop()
                $r.Spec.Result = @{ ExitCode = $r.Proc.ExitCode; TimedOut = $false; StartFailed = $false; DurationSeconds = [math]::Round($r.Sw.Elapsed.TotalSeconds, 3) }
                $running.RemoveAt($i)
            }
            elseif ($r.Sw.Elapsed.TotalSeconds -gt [double]$r.Spec.TimeoutSec) {
                # Kill the TREE: testhost children keep DLLs locked otherwise.
                # WHY Stop-ProcessTree, not a bare .Kill($true): FIXED 2026-08-25 --
                # .Kill($true)'s entire-process-tree overload does not exist on
                # Windows PowerShell 5.1 (.NET Framework); it silently failed there
                # (caught, swallowed), leaving orphaned testhost processes holding
                # DLL locks on exactly the machines most likely to hit this path.
                Stop-ProcessTree -ProcessId $r.Proc.Id
                $r.Sw.Stop()
                $r.Spec.Result = @{ ExitCode = -1; TimedOut = $true; StartFailed = $false; DurationSeconds = [math]::Round($r.Sw.Elapsed.TotalSeconds, 3) }
                $running.RemoveAt($i)
            }
        }
    }
}

function Set-SpecCommand {
    # Bakes Exe/Args/CommandString into a spec for its assigned core budget.
    # Called again (plain shape, full cores) when a wrapped run must re-run.
    param($Spec, [int]$AssignedCores, [bool]$AsPlain = $false)
    $ta = @($Spec.ProjAbs, '--no-build', '--no-restore', '--logger', "trx;LogFileName=$($Spec.TrxName)", '--results-directory', $Spec.TrxDir)
    if ($Spec.Filter) { $ta += @('--filter', $Spec.Filter) }
    # WHY TreatNoTestsAsError=true unconditionally: verified  -  VSTest exits 0
    # on a filter matching zero tests, which would otherwise read as a pass.
    $ta += @('--', "RunConfiguration.MaxCpuCount=$AssignedCores", 'RunConfiguration.TreatNoTestsAsError=true')
    $Spec.CommandString = "dotnet test $($ta -join ' ')"
    if ($Spec.WantCoverage -and -not $AsPlain) {
        if ($Spec.Mechanism -eq 'dotnet-coverage') {
            # WHY the inner command is a single quoted string: dotnet-coverage
            # collect <cmd> takes the wrapped invocation as one process spec.
            $inner = 'dotnet test ' + (($ta | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' ')
            $Spec.Exe = 'dotnet-coverage'
            $Spec.Args = @('collect', '-f', 'cobertura', '-o', $Spec.CovOut, $inner)
        }
        elseif ($Spec.Mechanism -eq 'coverlet-console') {
            # coverlet.console: `-t/--target` is the process to launch, `-a/
            # --targetargs` is ONE string of ITS arguments (coverlet's own
            # System.CommandLine parser splits it, same quoting rules as the
            # dotnet-coverage inner command above) -- so `test ...` here, never
            # `dotnet test ...` (dotnet is already the --target). Verified live:
            # pointing at the build output DIRECTORY (not a specific .dll) finds
            # the SUT + test assemblies without assuming AssemblyName == csproj
            # name, and produces real per-method Cobertura <class> data.
            $inner = 'test ' + (($ta | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' ')
            $Spec.Exe = 'coverlet'
            $Spec.Args = @($Spec.BinDir, '--target', 'dotnet', '--targetargs', $inner, '--format', 'cobertura', '--output', $Spec.CovOut)
        }
        else {
            $Spec.Exe = 'dotnet'
            $Spec.Args = @('test') + $ta + @('--collect:XPlat Code Coverage;Format=cobertura;SingleHit=true')
        }
    }
    else {
        $Spec.Exe = 'dotnet'
        $Spec.Args = @('test') + $ta
    }
}

function Stop-ProcessTree {
    # Same cross-platform tree-kill as stryker-run.ps1's Stop-ProcessTree.
    # Used by the coverlet-install timeout below AND (as of 2026-08-25) by the
    # test-run anti-hang valve's tree-kill, which used to call `.Kill($true)`
    # directly -- that overload doesn't exist on Windows PowerShell 5.1.
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    if ($script:IsWin) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & cmd.exe /d /c "taskkill /PID $ProcessId /T /F >nul 2>&1" | Out-Null } catch { }
        $ErrorActionPreference = $prev
    } else {
        try { [System.Diagnostics.Process]::GetProcessById($ProcessId).Kill($true) } catch { }
    }
}

function Install-CoverletConsoleOnDemand {
    # On-demand install of the coverlet.console global dotnet tool -- reached
    # ONLY from the dotnet-coverage-calibrated-broken escalation below.
    # setup-mcp.ps1 deliberately does NOT pre-install this: the overwhelming
    # majority of machines never need it (dotnet-coverage already works
    # there), so paying a network-install cost for everyone up front doesn't
    # make sense. This is the one call site that has actually earned the
    # cost -- a prior run already proved the primary mechanism dead HERE.
    # Same on-demand-safety-net shape as contract-check.ps1's Install-Oasdiff,
    # but for a NuGet global tool (dotnet tool update already handles package
    # integrity -- no checksum dance needed), and it must NEVER throw:
    # coverage is best-effort, unlike oasdiff which contract-check.ps1 cannot
    # function without.
    #
    # Cached for this script invocation only: the profile loop can reach this
    # branch once per affected .NET test project, and `dotnet tool update`
    # still hits the NuGet feed even when already installed.
    if ($null -ne $script:coverletConsoleAvailable) { return $script:coverletConsoleAvailable }

    if (Get-Command coverlet -ErrorAction SilentlyContinue) {
        $script:coverletConsoleAvailable = $true
        return $true
    }

    # Bare/unredirected when we have to install synchronously -- streams
    # NuGet's own output straight to the console (same transparency as the
    # `dotnet build` call above) and avoids `2>&1`, which under this script's
    # $ErrorActionPreference='Stop' can promote a harmless native stderr
    # write into a terminating error (see the dotnet build note above).
    $installExitCode = 1
    try {
        if ($null -ne $script:coverletInstallProc) {
            # Already kicked off by the pre-scan near the top of Main,
            # overlapped with this loop's own `dotnet build` calls -- by now
            # it has usually already finished; this just waits out whatever
            # is left. Bounded to 300s: a hung `dotnet tool update` (NuGet
            # feed/network stall) used to block the whole run indefinitely
            # right at the moment coverage tries to escalate.
            if ($script:coverletInstallProc.WaitForExit(300000)) {
                $installExitCode = $script:coverletInstallProc.ExitCode
            } else {
                Stop-ProcessTree -ProcessId $script:coverletInstallProc.Id
                $null = $script:coverletInstallProc.WaitForExit(15000)
                $installExitCode = 1
                $script:coverletInstallTimedOut = $true
            }
        } else {
            dotnet tool update --global coverlet.console
            $installExitCode = $LASTEXITCODE
        }
    } catch {
        $installExitCode = 1
    }

    # ~/.dotnet/tools may not be on THIS process's PATH yet even though the
    # tool is now on disk (same hazard setup-mcp.ps1 documents for
    # dotnet-coverage).
    $globalToolsBin = Join-Path $HOME (Join-Path '.dotnet' 'tools')
    if (($env:PATH -split [IO.Path]::PathSeparator) -notcontains $globalToolsBin) {
        $env:PATH += ([IO.Path]::PathSeparator + $globalToolsBin)
    }

    $script:coverletConsoleAvailable = [bool](
        $installExitCode -eq 0 -and (Get-Command coverlet -ErrorAction SilentlyContinue)
    )
    return $script:coverletConsoleAvailable
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------

try {
    if ($null -eq (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Write-Output 'run-tests: SKIPPED  -  dotnet SDK not found on PATH'
        exit 0
    }

    $man = Read-JsonFile -Path $Manifest
    $workspaceDir = [string](Get-Prop $man 'workspaceDir' '')
    $worktreeDir  = [string](Get-Prop $man 'worktreeDir' '')
    $repoPath     = [string](Get-Prop $man 'repoPath' '')
    if ([string]::IsNullOrWhiteSpace($workspaceDir)) { throw 'run-manifest.json missing workspaceDir' }

    $profilesPath = Join-Path $workspaceDir 'adapter-profiles.json'
    $diffSetPath  = Join-Path $workspaceDir 'diff-set.json'
    if (-not (Test-Path -LiteralPath $profilesPath)) { throw "adapter-profiles.json not found: $profilesPath (run qa-intake first)" }

    $profiles = @(Get-Prop (Read-JsonFile -Path $profilesPath) 'projects' @())
    $diffSet  = if (Test-Path -LiteralPath $diffSetPath) { Read-JsonFile -Path $diffSetPath } else { $null }

    # Artifact name: -GeneratedOnly must NEVER write test-results.json (verified
    # live: the anti-vacuity run used to clobber Phase 2's unit results, forcing a
    # manual restore). Branch/base generated runs are kept apart via -ResultsLabel.
    $resultsName = 'test-results.json'
    if ($GeneratedOnly) {
        $resultsName = 'test-results-generated.json'
        if (-not [string]::IsNullOrWhiteSpace($ResultsLabel)) {
            $safeLabel = $ResultsLabel -replace '[^A-Za-z0-9._-]', '-'
            $resultsName = "test-results-generated-$safeLabel.json"
        }
    }

    if ($profiles.Count -eq 0) {
        Write-Output 'run-tests: no affected test projects in adapter-profiles.json  -  nothing to run'
        $empty = [ordered]@{ runs = @(); flaky = [ordered]@{ policy = 'no-local-reruns'; note = 'no affected test projects'; mightBeFlaky = @() } }
        Write-JsonFileNoBom -Object $empty -Path (Join-Path $workspaceDir $resultsName)
        exit 0
    }

    # $GeneratedOnly targets a persistent worktree exclusively; the branch's own
    # tree is never the execution root for Phase 7 (product repos stay read-only).
    # -WorktreeRoot points the run at the BASE worktree for anti-vacuity.
    $execRoot = if ($GeneratedOnly) { $worktreeDir } else { $repoPath }
    if ($GeneratedOnly -and -not [string]::IsNullOrWhiteSpace($WorktreeRoot)) { $execRoot = $WorktreeRoot }
    if ($GeneratedOnly -and -not (Test-Path -LiteralPath $execRoot)) {
        throw "worktree not found: $execRoot (run worktree.ps1 -Ensure / -EnsureBase first)"
    }

    # Coverage capability calibration (machine-level, self-recorded by past runs):
    # a mechanism proven to yield no parseable class data on this machine is skipped
    # up front instead of paying the instrumentation cost for nothing.
    $calibPathShared = Join-Path (Split-Path -Parent $workspaceDir) 'calibration.json'
    $calibCoverage = $null
    if (Test-Path -LiteralPath $calibPathShared) {
        $calibCoverage = Get-Prop (Read-JsonFile -Path $calibPathShared) 'coverage' $null
    }

    # Pre-emptive background kickoff: if ANY .NET profile will need the
    # coverlet.console escalation (see Install-CoverletConsoleOnDemand below),
    # start installing it now (network I/O, non-blocking) so it overlaps with
    # this loop's own `dotnet build` calls instead of adding pure serial
    # latency right before the first wrapped run that needs it. Purely a
    # latency optimization -- correctness never depends on this firing or
    # finishing: Install-CoverletConsoleOnDemand still does its own
    # synchronous install if this didn't fire in time (or at all).
    $script:coverletInstallProc = $null
    $script:coverletInstallTimedOut = $false
    if ($null -ne $calibCoverage -and
        (Get-Prop $calibCoverage 'dotnetCoverageWorks' $null) -eq $false -and
        (Get-Prop $calibCoverage 'coverletConsoleWorks' $null) -ne $false -and
        (-not (Get-Command coverlet -ErrorAction SilentlyContinue))) {
        $needsCoverletFallback = @($profiles) | Where-Object {
            [string](Get-Prop $_ 'coverageMechanism' 'collector') -eq 'dotnet-coverage'
        }
        if (@($needsCoverletFallback).Count -gt 0) {
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = 'dotnet'
                foreach ($a in @('tool', 'update', '--global', 'coverlet.console')) { $null = $psi.ArgumentList.Add($a) }
                $psi.UseShellExecute = $false
                $script:coverletInstallProc = [System.Diagnostics.Process]::Start($psi)
            } catch { $script:coverletInstallProc = $null }
        }
    }

    $covSeenData  = @{}   # capKey -> $true when a run produced real class data
    $covSeenEmpty = @{}   # capKey -> $true when a completed run produced none
    $script:coverletConsoleAvailable = $null   # tri-state cache for Install-CoverletConsoleOnDemand

    $covDir = Join-Path $workspaceDir 'cov'
    if (-not (Test-Path -LiteralPath $covDir)) { New-Item -ItemType Directory -Force -Path $covDir | Out-Null }
    $trxDir = Join-Path $workspaceDir 'trx'
    if (-not (Test-Path -LiteralPath $trxDir)) { New-Item -ItemType Directory -Force -Path $trxDir | Out-Null }

    $cores = Get-LogicalCoreCount
    $runs = New-Object System.Collections.Generic.List[object]
    $builtProjects = New-Object 'System.Collections.Generic.HashSet[string]'
    $plainRunSecondsTotal = 0.0

    # .NET projects are SPEC'd in the profile loop (checks + build only) and
    # executed afterwards by the bounded scheduler  -  see the engine functions.
    $dotnetSpecs = New-Object System.Collections.Generic.List[object]
    # Anti-hang budget per spec: generous multiple of a calibrated run, or a flat
    # fallback on a repo agentQ hasn't seen yet. Now applies to PLAIN runs too
    # (a wedged testhost used to hang the script forever).
    $dotnetTimeoutSec = 480
    if (Test-Path -LiteralPath $calibPathShared) {
        $calibForTimeout = Read-JsonFile -Path $calibPathShared
        $plainCalib = [double](Get-Prop $calibForTimeout 'plainRunSeconds' 0)
        if ($plainCalib -gt 0) { $dotnetTimeoutSec = [Math]::Max(120, [int]($plainCalib * 6)) }
    }

    foreach ($prof in $profiles) {
        $framework = [string](Get-Prop $prof 'framework' '')
        $isDotnet  = @('xunit', 'nunit3', 'nunit4') -contains $framework
        $isJs      = @('jest', 'vitest') -contains $framework

        if ($isDotnet) {
            $projRel = ([string](Get-Prop $prof 'projectPath' '')) -replace '\\', '/'
            $projAbs = Join-Path $execRoot ($projRel -replace '/', [IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $projAbs)) {
                $null = $runs.Add([ordered]@{
                    projectPath = $projRel; command = $null; exitCode = -1
                    testsDiscovered = 0; testsExecuted = 0; passed = 0; failed = 0; skipped = 0
                    zeroMatchError = $false; durationSeconds = 0.0; failures = @(); perTestDurations = @()
                    trxPath = $null; skippedReason = "project not found at $projAbs"
                })
                continue
            }

            # Filter + suite scope FIRST (before any build  -  a skipped suite must
            # not cost a build either). Generated-only uses the profile's category
            # filter; affected mode derives test classes from the diff. What an
            # empty derivation means depends on suiteScope:
            #  * diff-sensitive (default): fall back to an unfiltered project run
            #    rather than a filter guaranteed to match nothing.
            #  * solution-wide (arch/static-analysis suites scanning the whole
            #    solution): NEVER run unfiltered off a diff heuristic  -  verified
            #    live, one such suite (371 tests, 5m19s) dominated a review's
            #    wall-clock with zero diff-relevant signal. Honest SKIPPED instead;
            #    the PR pipeline runs these suites on every PR, so there is no
            #    local override (removed by design, not omitted).
            $suiteScope = [string](Get-Prop $prof 'suiteScope' 'diff-sensitive')
            $solutionWide = ($suiteScope -eq 'solution-wide')
            if ($GeneratedOnly) {
                $filter = Get-DotnetTestFilter -Framework $framework -GeneratedCategory
            }
            else {
                $classes = Get-AffectedTestClasses -Profile $prof -DiffSet $diffSet
                $filter = Get-DotnetTestFilter -Framework $framework -TestClasses $classes
                if ($solutionWide -and -not $filter) {
                    $null = $runs.Add([ordered]@{
                        projectPath = $projRel; command = $null; exitCode = 0
                        testsDiscovered = 0; testsExecuted = 0; passed = 0; failed = 0; skipped = 0
                        zeroMatchError = $false; durationSeconds = 0.0; failures = @(); perTestDurations = @()
                        trxPath = $null
                        skippedReason = 'solution-wide suite (suiteScope) with no changed test classes  -  not diff-sensitive; skipped (the PR pipeline runs it on every PR)'
                    })
                    continue
                }
            }

            # Build once per distinct project graph. WHY the sut projects too: a
            # project reference change needs its dependents rebuilt, but the test
            # project's own build already pulls that in via MSBuild  -  building the
            # test project once is sufficient and is the ONLY thing we ever build
            # (never a .sln  -  e-conomic's is 426 projects).
            if (-not $builtProjects.Contains($projAbs)) {
                $buildArgs = @('build', $projAbs, '-c', 'Debug', '-v:m', '--nologo')
                $nugetConfigOverride = Get-RepoNuGetConfigOverride -ProjAbs $projAbs -RepoPath $execRoot
                if ($nugetConfigOverride) { $buildArgs += @('--configfile', $nugetConfigOverride) }
                # WHY Tee-Object (not `2>&1`): capture the real diagnostic text
                # for the artifact while still streaming to the console, without
                # touching stderr -- PS 5.1 wraps redirected native stderr in
                # ErrorRecords, which $ErrorActionPreference='Stop' can promote
                # to a terminating error (same hazard noted elsewhere in this
                # file). MSBuild writes its errors to stdout regardless of
                # verbosity, so stdout alone is sufficient.
                $buildOutputLines = @()
                & dotnet @buildArgs | Tee-Object -Variable buildOutputLines
                if ($LASTEXITCODE -ne 0) {
                    # Surface the ACTUAL compiler diagnostic (e.g. "error
                    # CS0234: X does not exist...") instead of an opaque
                    # placeholder: this is what lets a consumer (qa-analyst
                    # grading anti-vacuity) tell "this base build fails because
                    # the generated test references a branch-new symbol"
                    # (strong non-vacuity evidence) apart from a genuine,
                    # unrelated base-side breakage.
                    $errorLines = @($buildOutputLines) | Where-Object { $_ -match '\berror\b' }
                    $buildMessage = if ($errorLines.Count -gt 0) { ($errorLines | Select-Object -First 40) -join "`n" }
                                    else { (@($buildOutputLines) | Select-Object -Last 40) -join "`n" }
                    if ([string]::IsNullOrWhiteSpace($buildMessage)) { $buildMessage = 'dotnet build failed (no output captured)' }
                    if ($buildMessage.Length -gt 4000) { $buildMessage = $buildMessage.Substring(0, 4000) + ' ... (truncated)' }
                    $null = $runs.Add([ordered]@{
                        projectPath = $projRel; command = "dotnet $($buildArgs -join ' ')"; exitCode = $LASTEXITCODE
                        testsDiscovered = 0; testsExecuted = 0; passed = 0; failed = 0; skipped = 0
                        zeroMatchError = $false; durationSeconds = 0.0
                        failures = @(@{ fqn = '<build>'; message = $buildMessage; stack = '' })
                        perTestDurations = @(); trxPath = $null
                    })
                    continue
                }
                $null = $builtProjects.Add($projAbs)
            }

            # ---- spec only  -  execution happens in the bounded scheduler AFTER
            # this loop (parallel lane for factory-free projects, sequential lane
            # for anything that can boot a WebApplicationFactory).
            $projKey = ($projRel -replace '[\\/:]', '_')
            $specTrxDir = Join-Path $trxDir $projKey
            # WHY a per-project results dir: parallel collector runs would otherwise
            # drop their TestResults/<guid> attachments into one shared dir and the
            # newest-file pick could cross projects.
            New-Item -ItemType Directory -Force -Path $specTrxDir | Out-Null
            $trxName = "$projKey-run1.trx"
            $trxPath = Join-Path $specTrxDir $trxName
            if (Test-Path -LiteralPath $trxPath) { Remove-Item -LiteralPath $trxPath -Force }

            $coverageDegraded = $false
            $coverageNote = $null
            $wantCoverage = (-not $SkipCoverage) -and (-not $GeneratedOnly)
            $mechanism = [string](Get-Prop $prof 'coverageMechanism' 'collector')
            $capKey = 'collectorWorks'
            if ($mechanism -eq 'dotnet-coverage') { $capKey = 'dotnetCoverageWorks' }
            $binDirForFallback = $null
            # Capability gate: a mechanism a prior run proved broken on this machine
            # (profiler never attaches, no class data ever) is skipped up front  -
            # the instrumentation costs real time (documented 4x-47x blowups) and
            # produces nothing diff-coverage can parse. -ForceCoverage re-probes.
            if ($wantCoverage -and -not $ForceCoverage -and $null -ne $calibCoverage -and
                (Get-Prop $calibCoverage $capKey $null) -eq $false) {
                # dotnet-coverage has a documented gap on some machines (osx-arm64:
                # its native profiler never attaches, so class data is always empty,
                # forever -- not just once). Escalate to coverlet.console instead of
                # a bare skip: it instruments the already-built assemblies via IL
                # rewrite before the target process runs (verified live: no leftover
                # instrumented/backup DLLs after it finishes), never a profiler
                # attach on the child process -- a genuinely different mechanism,
                # not a retry of the one already proven broken here. Scoped to
                # dotnet-coverage only (the evidenced gap); needs coverlet.console
                # itself not already proven broken here, the tool present, and a
                # TFM to find the build output.
                $tfmForFallback = [string](Get-Prop $prof 'tfm' '')
                $coverletKnownBroken = ((Get-Prop $calibCoverage 'coverletConsoleWorks' $null) -eq $false)
                if ($mechanism -eq 'dotnet-coverage' -and -not $coverletKnownBroken -and $tfmForFallback -and
                    (Install-CoverletConsoleOnDemand)) {
                    $mechanism = 'coverlet-console'
                    $capKey = 'coverletConsoleWorks'
                    $binDirForFallback = Join-Path (Join-Path (Join-Path (Split-Path -Parent $projAbs) 'bin') 'Debug') $tfmForFallback
                    $coverageDegraded = $true
                    $coverageNote = 'coverage: dotnet-coverage is calibrated broken on this machine (calibration.coverage.dotnetCoverageWorks=false) -- falling back to coverlet.console (IL-rewrite, no profiler attach, no product .csproj change) instead of losing coverage entirely'
                }
                else {
                    $wantCoverage = $false
                    $coverageDegraded = $true
                    # Legible even in the worst case (CLAUDE.md: a DEGRADE must
                    # never read as a generic refusal) -- name exactly which
                    # fallback was or wasn't tried and why, not just "skipped".
                    $whyNoFallback = if ($mechanism -ne 'dotnet-coverage') { 'not applicable to this mechanism' }
                                      elseif ($coverletKnownBroken) { 'coverlet.console is ALSO calibrated broken on this machine (calibration.coverage.coverletConsoleWorks=false)' }
                                      elseif (-not $tfmForFallback) { 'adapter-profiles.json has no tfm for this project, so the build output directory cannot be located' }
                                      elseif ([bool]$script:coverletInstallTimedOut) { 'coverlet.console install (dotnet tool update --global coverlet.console) exceeded its 300s anti-hang valve and was killed -- likely a NuGet feed/network stall, not a real failure of the tool itself' }
                                      else { 'coverlet.console could not be installed on demand on this machine (dotnet tool update --global coverlet.console failed, or the tool is still unresolved on PATH after the attempt) -- retry manually with `dotnet tool install --global coverlet.console`, or check NuGet feed/network access' }
                    $coverageNote = "coverage skipped  -  calibration.coverage.$capKey=false on this machine (a prior run produced no parseable class data); coverlet.console fallback not used ($whyNoFallback); re-probe with -ForceCoverage"
                }
            }

            $null = $dotnetSpecs.Add(@{
                ProjRel = $projRel; ProjAbs = $projAbs; Filter = $filter
                SolutionWide = $solutionWide
                WantCoverage = $wantCoverage; Mechanism = $mechanism; CapKey = $capKey
                BinDir = $binDirForFallback
                CoverageDegraded = $coverageDegraded; CoverageNote = $coverageNote
                TrxDir = $specTrxDir; TrxName = $trxName; TrxPath = $trxPath
                CovOut = (Join-Path $covDir "$projKey.cobertura.xml")
                TimeoutSec = $dotnetTimeoutSec
                Boots = (Test-BootsWebFactory -ProjAbs $projAbs)
                WorkDir = $execRoot
                Exe = $null; Args = $null; CommandString = $null
                Result = $null; PriorSeconds = 0.0; RunNote = $null
            })
            continue
        }

        if ($isJs) {
            $projRoot = ([string](Get-Prop $prof 'projectPath' '')) -replace '\\', '/'
            $resultsFile = Join-Path $workspaceDir "jest-results-$(($projRoot -replace '[\\/:]', '_')).json"
            if ($GeneratedOnly -and -not [string]::IsNullOrWhiteSpace($ResultsLabel)) {
                $resultsFile = Join-Path $workspaceDir "jest-results-generated-$(($ResultsLabel -replace '[^A-Za-z0-9._-]', '-'))-$(($projRoot -replace '[\\/:]', '_')).json"
            }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            if ($GeneratedOnly) {
                # JS has no test-category trait, so Phase 7 selects generated tests by
                # the file-name convention instead: agents render *.agentq.test.ts(x)
                # (matches every Nx project's default testMatch AND is regex-selectable).
                # Direct jest with the project's own config — NOT `nx affected`: nx's
                # fan-out yields aggregate counts only, and anti-vacuity needs per-test
                # outcomes to prove it was the GENERATED tests that failed on base.
                $projDirAbs = Join-Path $execRoot ($projRoot -replace '/', [IO.Path]::DirectorySeparatorChar)
                $jestCfg = $null
                foreach ($cand in @('jest.config.ts', 'jest.config.js', 'jest.config.cjs', 'jest.config.mjs')) {
                    $p = Join-Path $projDirAbs $cand
                    if (Test-Path -LiteralPath $p -PathType Leaf) { $jestCfg = $p; break }
                }
                # WHY no --passWithNoTests: a zero-match generated run must be a
                # finding (same TreatNoTestsAsError rule as the dotnet lane) — jest
                # exits non-zero on "no tests found" and Executed stays 0 below.
                $cmd = @('jest', '--ci', '--silent', '--json', "--outputFile=$resultsFile", '--testPathPattern', '\.agentq\.')
                if ($null -ne $jestCfg) { $cmd += @('--config', $jestCfg) }
                $prevCi = $env:CI; $prevForceColor = $env:FORCE_COLOR
                $env:CI = 'true'; $env:FORCE_COLOR = '0'
                Push-Location $(if ($null -ne $jestCfg) { $execRoot } else { $projDirAbs })
                # WHY not `2>&1`: same PS 5.1 stderr-ErrorRecord crash as the nx branch below.
                try { & npx @cmd | Out-Null; $exitCode = $LASTEXITCODE }
                finally { $env:CI = $prevCi; $env:FORCE_COLOR = $prevForceColor; Pop-Location }

                $trx = [ordered]@{ Executed = 0; Passed = 0; Failed = 0; Skipped = 0; Failures = @(); PerTestDurations = @() }
                $zeroMatch = $true
                if (Test-Path -LiteralPath $resultsFile) {
                    $jr = Read-JsonFile -Path $resultsFile
                    $trx.Executed = [int](Get-Prop $jr 'numTotalTests' 0)
                    $trx.Passed = [int](Get-Prop $jr 'numPassedTests' 0)
                    $trx.Failed = [int](Get-Prop $jr 'numFailedTests' 0)
                    $zeroMatch = ($trx.Executed -eq 0)
                    foreach ($tr in @(Get-Prop $jr 'testResults' @())) {
                        foreach ($ar in @(Get-Prop $tr 'assertionResults' @())) {
                            $status = [string](Get-Prop $ar 'status' '')
                            $title = [string](Get-Prop $ar 'fullName' '')
                            $dur = [double](Get-Prop $ar 'duration' 0) / 1000.0
                            $null = $trx.PerTestDurations = @($trx.PerTestDurations) + @(@{ fqn = $title; seconds = [math]::Round($dur, 3) })
                            if ($status -eq 'failed') {
                                $msgs = @(Get-Prop $ar 'failureMessages' @()) -join "`n"
                                $null = $trx.Failures = @($trx.Failures) + @(@{ fqn = $title; message = $msgs; stack = '' })
                            }
                        }
                    }
                }
                $sw.Stop()
                $null = $runs.Add([ordered]@{
                    projectPath      = $projRoot
                    command          = "npx $($cmd -join ' ')"
                    exitCode         = $exitCode
                    testsDiscovered  = $trx.Executed
                    testsExecuted    = $trx.Executed
                    passed           = $trx.Passed
                    failed           = $trx.Failed
                    skipped          = $trx.Skipped
                    zeroMatchError   = $zeroMatch
                    durationSeconds  = [math]::Round($sw.Elapsed.TotalSeconds, 3)
                    failures         = @($trx.Failures)
                    perTestDurations = @($trx.PerTestDurations)
                    trxPath          = $resultsFile
                })
                continue
            }

            # File-granular related selection  -  the ONLY JS lane (every runner,
            # Nx included). There is deliberately no local run-everything mode:
            # the PR pipeline always runs the full suite plus ui-automation, so a
            # local project-granular fan-out buys nothing (verified live before
            # removal: nx affected turned a 4-file leaf diff into 40 projects /
            # 2504 tests / 13 min whose only signal was load-flaky failures in
            # unrelated modules).
            $rr = Invoke-JestRelatedRun -Prof $prof -ExecRoot $execRoot -WorkspaceDir $workspaceDir `
                -DiffSet $diffSet -CovDir $covDir -WantCoverage:(-not $SkipCoverage)
            if ($rr.SkippedNoFiles) {
                $sw.Stop()
                $null = $runs.Add([ordered]@{
                    projectPath = $projRoot; command = $null; exitCode = 0
                    testsDiscovered = 0; testsExecuted = 0; passed = 0; failed = 0; skipped = 0
                    zeroMatchError = $false; durationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 3)
                    failures = @(); perTestDurations = @(); trxPath = $null
                    selection = 'related-files'
                    skippedReason = 'no changed JS files under this project  -  nothing related to run'
                })
                continue
            }
            $selection = 'related-files'
            $selectionNote = "related-files selection: $($rr.RelatedFileCount) changed file(s) -> jest --findRelatedTests; dependent projects NOT run locally by design  -  the PR pipeline runs the full suite plus ui-automation on every PR"
            if ($rr.ZeroMatch) { $selectionNote += '; jest found NO tests related to the changed files  -  a coverage signal, never a pass' }
            if ((-not $SkipCoverage) -and -not $rr.CoverageWritten) { $selectionNote += '; coverage: no cobertura file was produced  -  coverage DEGRADED for this project' }
            $jsCommand = $rr.Command
            $exitCode = $rr.ExitCode
            $trx = $rr.Trx
            $zeroMatch = $rr.ZeroMatch
            $resultsFile = $rr.ResultsFile
            $sw.Stop()
            $durationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 3)

            # Calibration needs JS pass timings too.
            if (-not $GeneratedOnly) {
                $plainRunSecondsTotal += $durationSeconds
            }

            $null = $runs.Add([ordered]@{
                projectPath      = $projRoot
                command          = $jsCommand
                exitCode         = $exitCode
                testsDiscovered  = $trx.Executed
                testsExecuted    = $trx.Executed
                passed           = $trx.Passed
                failed           = $trx.Failed
                skipped          = $trx.Skipped
                zeroMatchError   = $zeroMatch
                durationSeconds  = $durationSeconds
                selection        = $selection
                selectionNote    = $selectionNote
                failures         = @($trx.Failures)
                perTestDurations = @($trx.PerTestDurations)
                trxPath          = $resultsFile
            })
            continue
        }

        # node:test or an unrecognized framework: no selective execution, no
        # mutation runner  -  degrade explicitly rather than silently skip.
        $null = $runs.Add([ordered]@{
            projectPath = [string](Get-Prop $prof 'projectPath' ''); command = $null; exitCode = -1
            testsDiscovered = 0; testsExecuted = 0; passed = 0; failed = 0; skipped = 0
            zeroMatchError = $false; durationSeconds = 0.0; failures = @(); perTestDurations = @()
            trxPath = $null; skippedReason = "no adapter for framework '$framework'"
        })
    }

    # ---------------- .NET execution: bounded-parallel scheduler -----------------
    # Two lanes: factory-free projects share the machine (throttle 3, each with
    # MaxCpuCount = cores/throttle so total load stays ~constant); anything that
    # can boot a WebApplicationFactory runs strictly one-at-a-time with all cores.
    # Phases still never overlap each other  -  this is WITHIN-phase parallelism
    # with a bounded core budget, not phase overlap.
    if ($dotnetSpecs.Count -gt 0) {
        $dotnetWall = [System.Diagnostics.Stopwatch]::StartNew()
        $parallelSpecs = @($dotnetSpecs | Where-Object { -not $_.Boots })
        $serialSpecs   = @($dotnetSpecs | Where-Object { $_.Boots })
        $throttle = [Math]::Min(3, [Math]::Max(1, $parallelSpecs.Count))
        $parallelCores = [int][Math]::Max(1, [Math]::Floor($cores / $throttle))
        foreach ($spec in $parallelSpecs) {
            Set-SpecCommand -Spec $spec -AssignedCores $parallelCores
            $spec.RunNote = "parallel lane (up to $throttle concurrent projects, MaxCpuCount=$parallelCores each)  -  no WebApplicationFactory reference, safe to share the machine"
        }
        foreach ($spec in $serialSpecs) {
            Set-SpecCommand -Spec $spec -AssignedCores $cores
            $spec.RunNote = "sequential lane  -  the test project references Microsoft.AspNetCore.Mvc.Testing (directly or via a test-common ProjectReference); WebApplicationFactory's 5s host-build timeout is load-sensitive, so it never shares the machine"
        }
        Invoke-SpecBatch -Specs $parallelSpecs -Throttle $throttle
        Invoke-SpecBatch -Specs $serialSpecs -Throttle 1

        # Wrapped runs that produced no trustworthy TRX (tool missing / valve
        # tripped) re-run PLAINLY, one at a time with all cores  -  identical
        # semantics to the old sequential degrade path.
        $rerunSpecs = New-Object System.Collections.Generic.List[object]
        foreach ($spec in $dotnetSpecs) {
            if (-not $spec.WantCoverage -or $null -eq $spec.Result) { continue }
            $res = $spec.Result
            if ($res.StartFailed) {
                $spec.CoverageDegraded = $true
                $spec.CoverageNote = "coverage tool for mechanism '$($spec.Mechanism)' could not start (not installed on this machine)  -  ran without coverage; recorded in calibration"
                $covSeenEmpty[$spec.CapKey] = $true
            }
            elseif ($res.TimedOut) {
                $spec.CoverageDegraded = $true
                $spec.CoverageNote = "coverage-wrapped run tripped the $($spec.TimeoutSec)s anti-hang valve  -  re-ran without coverage"
            }
            else { continue }
            $spec.PriorSeconds = [double]$spec.PriorSeconds + [double]$res.DurationSeconds
            if (Test-Path -LiteralPath $spec.TrxPath) { Remove-Item -LiteralPath $spec.TrxPath -Force }
            Set-SpecCommand -Spec $spec -AssignedCores $cores -AsPlain $true
            $spec.WantCoverage = $false
            $spec.Result = $null
            $null = $rerunSpecs.Add($spec)
        }
        Invoke-SpecBatch -Specs @($rerunSpecs.ToArray()) -Throttle 1
        $dotnetWall.Stop()
        # Calibration reads the PHASE wall-clock (what a developer actually waits),
        # not the per-project sum  -  parallel lanes make the sum exceed reality.
        if (-not $GeneratedOnly) { $plainRunSecondsTotal += [math]::Round($dotnetWall.Elapsed.TotalSeconds, 3) }

        # ---- parse every spec into its run entry (same shapes/rules as before) --
        foreach ($spec in $dotnetSpecs) {
            $res = $spec.Result
            $durationSeconds = [math]::Round(([double]$spec.PriorSeconds + [double]$res.DurationSeconds), 3)
            if ($res.TimedOut -or $res.StartFailed) {
                # A PLAIN run that hung or could not start: an honest failure entry,
                # never a silent hole (wrapped timeouts were already re-run above).
                $why = if ($res.TimedOut) { "test run exceeded the $($spec.TimeoutSec)s anti-hang valve and its process tree was killed" } else { 'test process could not start' }
                $null = $runs.Add([ordered]@{
                    projectPath = $spec.ProjRel; command = $spec.CommandString; exitCode = -1
                    testsDiscovered = 0; testsExecuted = 0; passed = 0; failed = 0; skipped = 0
                    zeroMatchError = $false; durationSeconds = $durationSeconds
                    coverageDegraded = $spec.CoverageDegraded; coverageNote = $spec.CoverageNote
                    runNote = $spec.RunNote
                    failures = @(@{ fqn = '<anti-hang>'; message = $why; stack = '' })
                    perTestDurations = @(); trxPath = $spec.TrxPath
                })
                continue
            }
            # Coverage validation for completed WRAPPED runs. The TEST results are
            # real regardless: NEVER re-run a completed suite over empty coverage
            # (verified live: the old degrade path re-ran a 5m19s suite in full).
            if ($spec.WantCoverage) {
                $covXml = $null
                if ($spec.Mechanism -eq 'dotnet-coverage' -or $spec.Mechanism -eq 'coverlet-console') {
                    # Both write directly to the exact -o/--output path we gave them.
                    if (Test-Path -LiteralPath $spec.CovOut) { $covXml = $spec.CovOut }
                }
                else {
                    # WHY glob for the newest file: the XPlat collector writes to
                    # TestResults/<random-guid>/coverage.cobertura.xml BY DESIGN;
                    # the per-project TrxDir keeps the pick safe under parallelism.
                    $found = Get-ChildItem -Path $spec.TrxDir -Recurse -Filter 'coverage.cobertura.xml' -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($null -ne $found) {
                        Copy-Item -LiteralPath $found.FullName -Destination $spec.CovOut -Force
                        $covXml = $spec.CovOut
                    }
                }
                $covHasData = $false
                if ($null -ne $covXml) { $covHasData = [bool](Select-String -LiteralPath $covXml -Pattern '<class' -Quiet) }
                if ($covHasData) {
                    $covSeenData[$spec.CapKey] = $true
                }
                else {
                    $spec.CoverageDegraded = $true
                    $spec.CoverageNote = 'coverage-wrapped run completed but produced no parseable class data  -  test results kept, coverage marked degraded (no duplicate run)'
                    $covSeenEmpty[$spec.CapKey] = $true
                }
            }
            $trx = Read-TrxResult -TrxPath $spec.TrxPath
            $zeroMatch = ($trx.Executed -eq 0)
            $entry = [ordered]@{
                projectPath      = $spec.ProjRel
                command          = $spec.CommandString
                exitCode         = $res.ExitCode
                testsDiscovered  = $trx.Executed
                testsExecuted    = $trx.Executed
                passed           = $trx.Passed
                failed           = $trx.Failed
                skipped          = $trx.Skipped
                zeroMatchError   = $zeroMatch
                durationSeconds  = $durationSeconds
                coverageDegraded = $spec.CoverageDegraded
                coverageNote     = $spec.CoverageNote
                runNote          = $spec.RunNote
                # WHY .ToArray(), not @(...): on this PS build `@(<List[object]>)`
                # throws "Argument types do not match" (the same empirically-
                # confirmed quirk documented in worktree.ps1); .ToArray() is safe.
                failures         = $trx.Failures.ToArray()
                perTestDurations = $trx.PerTestDurations.ToArray()
                trxPath          = $spec.TrxPath
            }
            if ($zeroMatch -and $spec.SolutionWide -and -not $GeneratedOnly) {
                # The derived classes matched nothing in this suite. For a
                # solution-wide suite that means "nothing here is diff-relevant"  -
                # an honest skip, never a zero-match red (exitCode forced to 0 so
                # risk-score's build-failed heuristic cannot misfire on it).
                $entry.exitCode = 0
                $entry.zeroMatchError = $false
                $entry.skippedReason = "solution-wide suite  -  affected-class filter matched no tests; treated as SKIPPED, not a zero-match failure"
            }
            $null = $runs.Add($entry)
        }
    }

    # ---------------- might-be-flaky tagging (NO local re-runs, by design) -------
    # agentQ used to re-run the affected subset 3x to catch outcome flips. Removed:
    # re-runs multiply the run's wall-clock, and one machine's re-run still cannot
    # prove stability. Instead every failed test is tagged MIGHT-BE-FLAKY with a
    # ready-to-run command the developer runs OUTSIDE agentQ  -  a pass on their
    # re-run suggests a flaky test; a repeat fail is a real failure.
    $mightBeFlaky = New-Object System.Collections.Generic.List[object]
    if (-not $GeneratedOnly) {
        foreach ($r in $runs) {
            $projPath = [string](Get-Prop $r 'projectPath' '')
            foreach ($fl in @(Get-Prop $r 'failures' @())) {
                $fqn = [string](Get-Prop $fl 'fqn' '')
                if (-not $fqn) { continue }
                $rerun = [string](Get-Prop $fl 'rerunCommand' '')
                if (-not $rerun) {
                    if ($projPath -match '\.csproj$') {
                        # strip parameterized-test arguments  -  '~' is a contains match
                        $clean = ($fqn -split '\(')[0].Trim()
                        $rerun = "dotnet test $projPath --filter `"FullyQualifiedName~$clean`""
                    }
                    else {
                        $rerun = "npx jest -t `"$([regex]::Escape($fqn))`""
                    }
                }
                $mightBeFlaky.Add([ordered]@{ fqn = $fqn; projectPath = $projPath; rerunCommand = $rerun })
            }
        }
    }
    $flakyNote = 'agentQ never re-runs tests to confirm flakiness (re-runs multiply the run time for signal you can get yourself in seconds). Every failed test is listed as MIGHT-BE-FLAKY with a ready-to-run command: re-run it outside agentQ  -  a pass on re-run suggests a flaky test, a repeat fail is a real failure.'
    if ($GeneratedOnly) { $flakyNote = 'not applicable in -GeneratedOnly mode (anti-vacuity failures on base are expected fix-detectors, never flaky candidates)' }
    $flaky = [ordered]@{
        policy       = 'no-local-reruns'
        note         = $flakyNote
        mightBeFlaky = @($mightBeFlaky.ToArray())
    }

    Write-JsonFileNoBom -Object ([ordered]@{ runs = @($runs.ToArray()); flaky = $flaky }) -Path (Join-Path $workspaceDir $resultsName)

    # ---------------- calibration (merge, never clobber unrelated keys) ---------
    if (-not $GeneratedOnly -and ($plainRunSecondsTotal -gt 0 -or $covSeenData.Count -gt 0 -or $covSeenEmpty.Count -gt 0)) {
        $calib = if (Test-Path -LiteralPath $calibPathShared) { Read-JsonFile -Path $calibPathShared } else { [pscustomobject]@{} }
        $calibHash = [ordered]@{}
        foreach ($p in $calib.PSObject.Properties) { $calibHash[$p.Name] = $p.Value }
        if ($plainRunSecondsTotal -gt 0) { $calibHash['plainRunSeconds'] = $plainRunSecondsTotal }
        # Coverage capability: "worked anywhere this run" wins over "empty somewhere"
        # (an empty result on one project with a working mechanism is an includes/
        # filter artifact, not a broken profiler  -  never lock coverage off for that).
        if ($covSeenData.Count -gt 0 -or $covSeenEmpty.Count -gt 0) {
            $covHash = [ordered]@{}
            if ($calibHash.Contains('coverage') -and $null -ne $calibHash['coverage']) {
                foreach ($p in $calibHash['coverage'].PSObject.Properties) { $covHash[$p.Name] = $p.Value }
            }
            foreach ($k in @($covSeenEmpty.Keys)) { $covHash[$k] = $false }
            foreach ($k in @($covSeenData.Keys))  { $covHash[$k] = $true }
            $covHash['probedAt'] = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            $calibHash['coverage'] = $covHash
        }
        Write-JsonFileNoBom -Object $calibHash -Path $calibPathShared
    }

    $totalExecuted = 0; $totalPassed = 0; $totalFailed = 0; $anyZeroMatch = $false; $totalSkippedRuns = 0
    foreach ($r in $runs) {
        $totalExecuted += [int](Get-Prop $r 'testsExecuted' 0)
        $totalPassed += [int](Get-Prop $r 'passed' 0)
        $totalFailed += [int](Get-Prop $r 'failed' 0)
        if ([bool](Get-Prop $r 'zeroMatchError' $false)) { $anyZeroMatch = $true }
        if ($null -ne (Get-Prop $r 'skippedReason' $null)) { $totalSkippedRuns++ }
    }
    $mode = if ($GeneratedOnly) { 'generated' } else { 'affected' }
    $skippedSuffix = ''
    if ($totalSkippedRuns -gt 0) { $skippedSuffix = "  -  $totalSkippedRuns project(s) skipped (see skippedReason)" }
    Write-Output ("run-tests ({0}): {1} project run(s)  -  {2}/{3} passed{4}{5} -> {6}" -f $mode, $runs.Count, $totalPassed, $totalExecuted, $(if ($anyZeroMatch) { '  -  WARNING: at least one zero-match filter' } else { '' }), $skippedSuffix, $resultsName)
    exit 0
}
catch {
    [Console]::Error.WriteLine("run-tests.ps1 FAILED: $($_.Exception.Message)")
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    exit 1
}
