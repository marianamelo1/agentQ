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
            $abs = Join-Path $ExecRoot ($p -replace '/', '\')
            if (Test-Path -LiteralPath $abs -PathType Leaf) { $changedAbs.Add($abs) }
        }
    }
    if ($changedAbs.Count -eq 0) { $result.SkippedNoFiles = $true; return $result }
    $result.RelatedFileCount = $changedAbs.Count

    $projDirAbs = $ExecRoot
    if ($projRoot -ne '') { $projDirAbs = Join-Path $ExecRoot ($projRoot -replace '/', '\') }
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
# Coverage wrapper  -  dotnet-coverage (preferred: zero csproj changes needed) or
# the XPlat collector (only when coverlet.collector is already referenced).
# Runs the WHOLE dotnet test invocation as a job so the anti-hang valve can kill
# it without killing this script (documented 4x-47x coverage blowups exist).
# -----------------------------------------------------------------------------

function Invoke-CoverageWrappedTest {
    param(
        [Parameter(Mandatory = $true)][string]$Mechanism,     # collector | dotnet-coverage
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [Parameter(Mandatory = $true)][string[]]$DotnetArgs,   # args to `dotnet test ...` (no leading "test")
        [Parameter(Mandatory = $true)][string]$CoverageOutXml,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $result = [ordered]@{ ExitCode = -1; CoverageDegraded = $false; TimedOut = $false; StartFailed = $false; CoverageXml = $null }

    if ($Mechanism -eq 'dotnet-coverage') {
        # WHY the inner command is a single quoted string: dotnet-coverage collect
        # <cmd> <args> takes the wrapped invocation as one process specification.
        $inner = 'dotnet test ' + (($DotnetArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' ')
        $args = @('collect', '-f', 'cobertura', '-o', $CoverageOutXml, $inner)
        $exe = 'dotnet-coverage'
    }
    else {
        $args = @('test') + $DotnetArgs + @('--collect:XPlat Code Coverage;Format=cobertura;SingleHit=true')
        $exe = 'dotnet'
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    foreach ($a in $args) { $null = $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    # WHY try/catch on Start: the mechanism's exe may simply not exist on this
    # machine (verified live: dotnet-coverage not installed -> Win32Exception ->
    # the WHOLE unit lane died with exit 1). A missing coverage tool is a
    # coverage degrade, never a run failure  -  the caller re-runs plainly and
    # records the mechanism as broken in calibration.json.
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        $result.StartFailed = $true
        $result.CoverageDegraded = $true
        return $result
    }
    $finished = $proc.WaitForExit($TimeoutSeconds * 1000)

    if (-not $finished) {
        $result.TimedOut = $true
        $result.CoverageDegraded = $true
        try { $proc.Kill($true) } catch { }
        # WHY -CoverageDegraded rather than re-running here: the caller already has
        # the un-wrapped filter/args and re-invokes plainly, so this function's job
        # ends at "coverage collection hung" without duplicating the plain-run path.
        return $result
    }
    $result.ExitCode = $proc.ExitCode

    if ($Mechanism -eq 'dotnet-coverage') {
        if (Test-Path -LiteralPath $CoverageOutXml) { $result.CoverageXml = $CoverageOutXml }
        else { $result.CoverageDegraded = $true }
    }
    else {
        # WHY glob for the newest file: --collect:"XPlat Code Coverage" writes to
        # TestResults/<random-guid>/coverage.cobertura.xml BY DESIGN  -  a
        # results-directory switch does not remove the GUID subfolder, so a
        # hardcoded path is the single most common breakage in scripted pipelines.
        $found = Get-ChildItem -Path $WorkDir -Recurse -Filter 'coverage.cobertura.xml' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $found) {
            Copy-Item -LiteralPath $found.FullName -Destination $CoverageOutXml -Force
            $result.CoverageXml = $CoverageOutXml
        }
        else { $result.CoverageDegraded = $true }
    }
    return $result
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
    $covSeenData  = @{}   # capKey -> $true when a run produced real class data
    $covSeenEmpty = @{}   # capKey -> $true when a completed run produced none

    $covDir = Join-Path $workspaceDir 'cov'
    if (-not (Test-Path -LiteralPath $covDir)) { New-Item -ItemType Directory -Force -Path $covDir | Out-Null }
    $trxDir = Join-Path $workspaceDir 'trx'
    if (-not (Test-Path -LiteralPath $trxDir)) { New-Item -ItemType Directory -Force -Path $trxDir | Out-Null }

    $cores = Get-LogicalCoreCount
    $runs = New-Object System.Collections.Generic.List[object]
    $builtProjects = New-Object 'System.Collections.Generic.HashSet[string]'
    $plainRunSecondsTotal = 0.0
    $coverageSecondsTotal = 0.0

    foreach ($prof in $profiles) {
        $framework = [string](Get-Prop $prof 'framework' '')
        $isDotnet  = @('xunit', 'nunit3', 'nunit4') -contains $framework
        $isJs      = @('jest', 'vitest') -contains $framework

        if ($isDotnet) {
            $projRel = ([string](Get-Prop $prof 'projectPath' '')) -replace '\\', '/'
            $projAbs = Join-Path $execRoot ($projRel -replace '/', '\')
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
                & dotnet @buildArgs
                if ($LASTEXITCODE -ne 0) {
                    $null = $runs.Add([ordered]@{
                        projectPath = $projRel; command = "dotnet $($buildArgs -join ' ')"; exitCode = $LASTEXITCODE
                        testsDiscovered = 0; testsExecuted = 0; passed = 0; failed = 0; skipped = 0
                        zeroMatchError = $false; durationSeconds = 0.0
                        failures = @(@{ fqn = '<build>'; message = 'dotnet build failed'; stack = '' })
                        perTestDurations = @(); trxPath = $null
                    })
                    continue
                }
                $null = $builtProjects.Add($projAbs)
            }

            $trxName = "$(([string](Get-Prop $prof 'projectPath' 'proj') -replace '[\\/:]', '_'))-run1.trx"
            $trxPath = Join-Path $trxDir $trxName

            $testArgs = @($projAbs, '--no-build', '--no-restore', '--logger', "trx;LogFileName=$trxName", '--results-directory', $trxDir)
            if ($filter) { $testArgs += @('--filter', $filter) }
            # WHY TreatNoTestsAsError=true unconditionally: verified  -  VSTest exits 0
            # on a filter matching zero tests, which would otherwise read as a pass.
            $testArgs += @('--', "RunConfiguration.MaxCpuCount=$cores", 'RunConfiguration.TreatNoTestsAsError=true')

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $coverageDegraded = $false
            $coverageNote = $null
            $exitCode = 0
            $ranTests = $false

            $wantCoverage = (-not $SkipCoverage) -and (-not $GeneratedOnly)
            $mechanism = [string](Get-Prop $prof 'coverageMechanism' 'collector')
            $capKey = 'collectorWorks'
            if ($mechanism -eq 'dotnet-coverage') { $capKey = 'dotnetCoverageWorks' }

            # Capability gate: a mechanism a prior run proved broken on this machine
            # (profiler never attaches, no class data ever) is skipped up front  -
            # the instrumentation costs real time (documented 4x-47x blowups) and
            # produces nothing diff-coverage can parse. -ForceCoverage re-probes.
            if ($wantCoverage -and -not $ForceCoverage -and $null -ne $calibCoverage) {
                if ((Get-Prop $calibCoverage $capKey $null) -eq $false) {
                    $wantCoverage = $false
                    $coverageDegraded = $true
                    $coverageNote = "coverage skipped  -  calibration.coverage.$capKey=false on this machine (a prior run produced no parseable class data); re-probe with -ForceCoverage"
                }
            }

            if ($wantCoverage) {
                $covOut = Join-Path $covDir "$(([string](Get-Prop $prof 'projectPath' 'proj') -replace '[\\/:]', '_')).cobertura.xml"
                # Anti-hang budget: generous multiple of a calibrated plain run, or a
                # flat fallback on a repo agentQ hasn't seen yet. This degrades
                # ("re-run without coverage"), it never lets the run hang.
                $timeoutSec = 480
                if (Test-Path -LiteralPath $calibPathShared) {
                    $calib = Read-JsonFile -Path $calibPathShared
                    $plain = [double](Get-Prop $calib 'plainRunSeconds' 0)
                    if ($plain -gt 0) { $timeoutSec = [Math]::Max(120, [int]($plain * 6)) }
                }
                $cr = Invoke-CoverageWrappedTest -Mechanism $mechanism -WorkDir $execRoot -DotnetArgs $testArgs -CoverageOutXml $covOut -TimeoutSeconds $timeoutSec
                if ($cr.StartFailed) {
                    # The mechanism's exe isn't on this machine at all  -  no tests
                    # ran (plain run below), and calibration records the mechanism
                    # broken so the next run skips the attempt up front.
                    $coverageDegraded = $true
                    $coverageNote = "coverage tool for mechanism '$mechanism' could not start (not installed on this machine)  -  ran without coverage; recorded in calibration"
                    $covSeenEmpty[$capKey] = $true
                }
                elseif ($cr.TimedOut) {
                    # The killed run left no trustworthy TRX  -  this is the ONLY
                    # degrade path that re-runs the tests (plainly, below).
                    $coverageDegraded = $true
                    $coverageNote = "coverage-wrapped run tripped the ${timeoutSec}s anti-hang valve  -  re-ran without coverage"
                }
                else {
                    $exitCode = $cr.ExitCode
                    $ranTests = $true
                    # Validate the XML actually carries class data: a wrapped run can
                    # complete fine while the profiler never attached (verified live:
                    # "No code coverage data available. Profiler was not initialized"
                    #  -  the file exists, holds zero <class> elements, and
                    # diff-coverage refuses later). The TEST results are still real:
                    # NEVER re-run a completed suite just because coverage is empty
                    # (the old degrade path re-ran a 5m19s suite in full).
                    $covHasData = $false
                    if (-not $cr.CoverageDegraded -and $null -ne $cr.CoverageXml -and (Test-Path -LiteralPath $cr.CoverageXml)) {
                        $covHasData = [bool](Select-String -LiteralPath $cr.CoverageXml -Pattern '<class' -Quiet)
                    }
                    if ($covHasData) {
                        $covSeenData[$capKey] = $true
                    }
                    else {
                        $coverageDegraded = $true
                        $coverageNote = 'coverage-wrapped run completed but produced no parseable class data  -  test results kept, coverage marked degraded (no duplicate run)'
                        $covSeenEmpty[$capKey] = $true
                    }
                }
            }

            if (-not $ranTests) {
                # WHY not `2>&1`: see the nx branch below -- dotnet's own MSBuild/NuGet
                # warnings on stderr are just as capable of triggering the same crash.
                & dotnet test @testArgs --no-build | Out-Null
                $exitCode = $LASTEXITCODE
            }
            $sw.Stop()
            $durationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 3)

            $trx = Read-TrxResult -TrxPath $trxPath
            $zeroMatch = ($trx.Executed -eq 0)

            if (-not $GeneratedOnly -and $builtProjects.Count -le $profiles.Count) {
                $plainRunSecondsTotal += $durationSeconds
            }

            $entry = [ordered]@{
                projectPath      = $projRel
                command          = "dotnet test $($testArgs -join ' ')"
                exitCode         = $exitCode
                testsDiscovered  = $trx.Executed
                testsExecuted    = $trx.Executed
                passed           = $trx.Passed
                failed           = $trx.Failed
                skipped          = $trx.Skipped
                zeroMatchError   = $zeroMatch
                durationSeconds  = $durationSeconds
                coverageDegraded = $coverageDegraded
                coverageNote     = $coverageNote
                # WHY .ToArray(), not @(...): on this PS build `@(<List[object]>)`
                # throws "Argument types do not match" (the same empirically-
                # confirmed quirk documented in worktree.ps1); .ToArray() is safe.
                failures         = $trx.Failures.ToArray()
                perTestDurations = $trx.PerTestDurations.ToArray()
                trxPath          = $trxPath
            }
            if ($zeroMatch -and $solutionWide -and -not $GeneratedOnly) {
                # The derived classes matched nothing in this suite. For a
                # solution-wide suite that means "nothing here is diff-relevant"  -
                # an honest skip, never a zero-match red (exitCode forced to 0 so
                # risk-score's build-failed heuristic cannot misfire on it).
                $entry.exitCode = 0
                $entry.zeroMatchError = $false
                $entry.skippedReason = "solution-wide suite  -  affected-class filter matched no tests; treated as SKIPPED, not a zero-match failure"
            }
            $null = $runs.Add($entry)
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
                $projDirAbs = Join-Path $execRoot ($projRoot -replace '/', '\')
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
