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
#   <workspace>/cov/*.cobertura.xml  or <trx-results>/**/coverage.cobertura.xml
#   <workspace>/calibration.json    merged plainRunSeconds / coverageMultiplier
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
#   * RunConfiguration.TreatNoTestsAsError=true on every invocation  -  a filter
#     matching zero tests otherwise exits 0 and would read as a pass
#   * coverage is a WRAPPER around the test run (dotnet-coverage collect, or the
#     XPlat collector when coverlet.collector is already referenced)  -  never a
#     csproj edit; wrapped runs carry an anti-hang wall-clock kill because
#     coverage instrumentation has documented 4x-47x pathological blowups, and a
#     tripped valve DEGRADES (re-run without coverage) rather than hanging
#   * flaky repeats only fire when the first affected-subset pass was fast, so a
#     slow suite is never rerun 3x for a habit-forming tool
#   * -GeneratedOnly targets the WORKTREE and the profile's categoryFilter, never
#     the affected-subset heuristic  -  Phase 7's generated tests are the exact set
# =============================================================================
[CmdletBinding()]
param(
    # Path to run-manifest.json for this run (see scripts/CONTRACTS.md).
    [Parameter(Mandatory = $true)]
    [string]$Manifest,

    # Phase 7 mode: run only the profile's agentQ-generated category, in the
    # worktree, instead of the Phase 2 affected-subset heuristic in the repo.
    [switch]$GeneratedOnly,

    # Skip coverage collection entirely (e.g. a Phase-7 re-run where Phase 2
    # already produced the diff-coverage numbers this run doesn't need again).
    [switch]$SkipCoverage,

    # 0 disables flaky-repeat detection. Only applies in affected-subset mode.
    [int]$FlakyRepeats = 3
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
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
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

function Get-JestSummaryCounts {
    # Parses jest's own "Tests:       X failed, Y skipped, Z passed, N total" console summary
    # line(s) -- used for `nx affected --target=test`, which fans out to many projects' own
    # jest reporters with no single machine-readable file this script controls. Two things
    # verified live and both handled here:
    #  1) nx runs each affected project as its OWN jest invocation, so there is one "Tests:"
    #     line PER PROJECT (e.g. "app" and "payroll" separately) -- every match is summed,
    #     not just the first, or a multi-project run would silently report only one project's
    #     counts.
    #  2) under piped/non-tty width detection, nx/jest can hard-wrap this line mid-clause
    #     (confirmed live: "...1703 " ends one array element, "total" starts the next) --
    #     when the line doesn't yet contain a complete "<N> total" clause, the immediately
    #     following line is appended before parsing.
    # Jest also OMITS a zero-count category entirely (no "0 failed," when nothing failed)
    # rather than always printing all four, so clauses are parsed by content, not position.
    param([string[]]$Lines)
    $result = [ordered]@{ Failed = 0; Skipped = 0; Passed = 0; Total = 0 }
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        # WHY strip ANSI first: nx/jest emit SGR color/bold escape codes around the
        # numbers and label even under --output-style=static (verified live) -- matching
        # against the raw string would miss the line or split a number from its label.
        $line = $Lines[$i] -replace "`e\[[0-9;]*m", ''
        if ($line -match '^\s*Tests:\s*(.+)$') {
            $rest = $Matches[1]
            if ($rest -notmatch '\d+\s*total\s*$' -and ($i + 1) -lt $Lines.Count) {
                $next = $Lines[$i + 1] -replace "`e\[[0-9;]*m", ''
                $rest = "$rest $($next.Trim())"
            }
            foreach ($part in ($rest -split ',')) {
                $part = $part.Trim()
                if     ($part -match '^(\d+)\s+failed$')  { $result.Failed  += [int]$Matches[1] }
                elseif ($part -match '^(\d+)\s+skipped$') { $result.Skipped += [int]$Matches[1] }
                elseif ($part -match '^(\d+)\s+passed$')  { $result.Passed  += [int]$Matches[1] }
                elseif ($part -match '^(\d+)\s+total$')   { $result.Total   += [int]$Matches[1] }
            }
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

function Get-AffectedTestClasses {
    # Heuristic bridge from "these SUT files changed" to "these test classes cover
    # them", since .NET (unlike Jest) has no built-in file-level reverse-dependency
    # flag. <ClassName>Tests / <ClassName>Test is the dominant convention across
    # all four target repos' *.Tests / *.UnitTests projects; profiles with no match
    # fall back to an unfiltered project run rather than silently testing nothing.
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)]$DiffSet
    )
    $sutSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($s in @(Get-Prop $Profile 'sutProjects' @())) {
        $null = $sutSet.Add((([string]$s) -replace '\\', '/').ToLowerInvariant())
    }
    if ($sutSet.Count -eq 0) { return @() }

    $classes = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-Prop $DiffSet 'files' @())) {
        $path = ([string](Get-Prop $f 'path' '')) -replace '\\', '/'
        if ($path -notmatch '\.cs$') { continue }
        # Cheap containment check: does this changed file live under one of the
        # profile's SUT project directories? (project dir = parent of the .csproj)
        $covered = $false
        foreach ($sut in $sutSet) {
            $sutDir = $sut -replace '/[^/]+\.csproj$', ''
            if ($path.ToLowerInvariant().StartsWith("$sutDir/")) { $covered = $true; break }
        }
        if (-not $covered) { continue }
        $base = [System.IO.Path]::GetFileNameWithoutExtension($path)
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $null = $classes.Add("${base}Tests")
        $null = $classes.Add("${base}Test")
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
    $result = [ordered]@{ ExitCode = -1; CoverageDegraded = $false; TimedOut = $false; CoverageXml = $null }

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
    $proc = [System.Diagnostics.Process]::Start($psi)
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

    if ($profiles.Count -eq 0) {
        Write-Output 'run-tests: no affected test projects in adapter-profiles.json  -  nothing to run'
        $empty = [ordered]@{ runs = @(); flaky = [ordered]@{ repeats = $FlakyRepeats; flipped = @(); skippedReason = 'no affected test projects' } }
        Write-JsonFileNoBom -Object $empty -Path (Join-Path $workspaceDir 'test-results.json')
        exit 0
    }

    # $GeneratedOnly targets the persistent worktree exclusively; the branch's own
    # tree is never the execution root for Phase 7 (product repos stay read-only).
    $execRoot = if ($GeneratedOnly) { $worktreeDir } else { $repoPath }
    if ($GeneratedOnly -and -not (Test-Path -LiteralPath $worktreeDir)) {
        throw "worktree not found: $worktreeDir (run worktree.ps1 -Ensure first)"
    }

    $covDir = Join-Path $workspaceDir 'cov'
    if (-not (Test-Path -LiteralPath $covDir)) { New-Item -ItemType Directory -Force -Path $covDir | Out-Null }
    $trxDir = Join-Path $workspaceDir 'trx'
    if (-not (Test-Path -LiteralPath $trxDir)) { New-Item -ItemType Directory -Force -Path $trxDir | Out-Null }

    $cores = Get-LogicalCoreCount
    $runs = New-Object System.Collections.Generic.List[object]
    $builtProjects = New-Object 'System.Collections.Generic.HashSet[string]'
    $plainRunSecondsTotal = 0.0
    $coverageSecondsTotal = 0.0
    $firstPassSeconds = 0.0

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

            # Filter: generated-only uses the profile's category filter; affected
            # mode derives test classes from the diff, falling back to an
            # unfiltered run rather than a filter guaranteed to match nothing.
            if ($GeneratedOnly) {
                $filter = Get-DotnetTestFilter -Framework $framework -GeneratedCategory
            }
            else {
                $classes = Get-AffectedTestClasses -Profile $prof -DiffSet $diffSet
                $filter = Get-DotnetTestFilter -Framework $framework -TestClasses $classes
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
            $exitCode = 0

            $wantCoverage = (-not $SkipCoverage) -and (-not $GeneratedOnly)
            if ($wantCoverage) {
                $mechanism = [string](Get-Prop $prof 'coverageMechanism' 'collector')
                $covOut = Join-Path $covDir "$(([string](Get-Prop $prof 'projectPath' 'proj') -replace '[\\/:]', '_')).cobertura.xml"
                # Anti-hang budget: generous multiple of a calibrated plain run, or a
                # flat fallback on a repo agentQ hasn't seen yet. This degrades
                # ("re-run without coverage"), it never lets the run hang.
                $timeoutSec = 480
                $calibPath = Join-Path (Split-Path -Parent $workspaceDir) 'calibration.json'
                if (Test-Path -LiteralPath $calibPath) {
                    $calib = Read-JsonFile -Path $calibPath
                    $plain = [double](Get-Prop $calib 'plainRunSeconds' 0)
                    if ($plain -gt 0) { $timeoutSec = [Math]::Max(120, [int]($plain * 6)) }
                }
                $cr = Invoke-CoverageWrappedTest -Mechanism $mechanism -WorkDir $execRoot -DotnetArgs $testArgs -CoverageOutXml $covOut -TimeoutSeconds $timeoutSec
                if ($cr.TimedOut) {
                    $coverageDegraded = $true
                    # Fall through to a plain (uncovered) run below.
                }
                else {
                    $exitCode = $cr.ExitCode
                    if ($cr.CoverageDegraded) { $coverageDegraded = $true }
                }
            }

            if (-not $wantCoverage -or $coverageDegraded) {
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
                if ($firstPassSeconds -eq 0.0) { $firstPassSeconds = $durationSeconds }
            }

            $null = $runs.Add([ordered]@{
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
                failures         = @($trx.Failures)
                perTestDurations = @($trx.PerTestDurations)
                trxPath          = $trxPath
            })
            continue
        }

        if ($isJs) {
            $projRoot = ([string](Get-Prop $prof 'projectPath' '')) -replace '\\', '/'
            $runner = [string](Get-Prop $prof 'runner' '')
            $resultsFile = Join-Path $workspaceDir "jest-results-$(($projRoot -replace '[\\/:]', '_')).json"
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            if ($runner -eq 'nx') {
                $baseSha = [string](Get-Prop $man 'baseSha' '')
                $cmd = @('nx', 'affected', '--target=test', "--base=$baseSha", '--output-style=static')
                if (-not $SkipCoverage) { $cmd += '--coverage' }
                Push-Location $execRoot
                # WHY not `2>&1`: PS 5.1 wraps redirected native stderr lines in ErrorRecords,
                # which $ErrorActionPreference='Stop' promotes to a terminating error mid-run --
                # confirmed live: an entirely benign "npm notice run ..." line from npx crashed
                # this call. Same fix already used in contract-check.ps1/stryker-run.ps1: never
                # touch stream 2 at all, so it goes straight to the console, not the PS pipeline.
                # WHY capture stdout (not Out-Null): `nx affected` fans out to many projects'
                # own jest reporters with no single machine-readable file this script controls,
                # but jest's own "Tests: X failed, Y skipped, Z passed, N total" summary line is
                # real, parseable signal -- without it, a failing run reports 0 tests executed
                # and 0 recorded failures, which is INDISTINGUISHABLE from a build failure to
                # risk-score.ps1's build-failed heuristic (confirmed live: a real 2-of-1701-test
                # failure got misclassified as score=100/build-failed).
                # WHY CI=true FORCE_COLOR=0: without them, nx/jest emit ANSI color codes AND
                # (confirmed live, reproduced 3x) hard-wrap the "Tests:" line mid-clause under
                # piped/non-tty width detection -- "...1703 " on one captured line, "total" on
                # the next -- sometimes dropping the line's plain-text form entirely depending
                # on timing. Forcing CI mode gives the same clean, single-line, uncolored summary
                # every time; Get-JestSummaryCounts still defends against a wrap as a fallback.
                $prevCi = $env:CI; $prevForceColor = $env:FORCE_COLOR
                $env:CI = 'true'; $env:FORCE_COLOR = '0'
                try { $nxOutputLines = & npx @cmd; $exitCode = $LASTEXITCODE }
                finally { $env:CI = $prevCi; $env:FORCE_COLOR = $prevForceColor; Pop-Location }
                $jestSummary = Get-JestSummaryCounts -Lines $nxOutputLines
                $trx = [ordered]@{
                    Executed = $jestSummary.Total; Passed = $jestSummary.Passed
                    Failed   = $jestSummary.Failed; Skipped = $jestSummary.Skipped
                    Failures = @(); PerTestDurations = @()
                }
                # WHY Failures stays empty even though Failed > 0: nx's fan-out has no single
                # machine-readable per-test file this script controls, so which SPECIFIC tests
                # failed isn't captured here -- only the aggregate counts are. A non-zero Failed
                # with an empty Failures array is a deliberate, honest shape: qa-analyst reads
                # the console output (available in this run's log) for per-test detail, not a
                # fabricated Failures entry this script didn't actually observe.
                $zeroMatch = $false
            }
            else {
                $changedFiles = @()
                if ($null -ne $diffSet) {
                    foreach ($f in @(Get-Prop $diffSet 'files' @())) {
                        $p = [string](Get-Prop $f 'path' '')
                        if ($p -match '\.(js|jsx|ts|tsx)$') { $changedFiles += (Join-Path $repoPath ($p -replace '/', '\')) }
                    }
                }
                $cmd = @('jest', '--ci', '--silent', '--passWithNoTests', '--json', "--outputFile=$resultsFile")
                if ($changedFiles.Count -gt 0) { $cmd += @('--findRelatedTests') + $changedFiles }
                if (-not $SkipCoverage) { $cmd += @('--coverage', '--coverageReporters=json-summary') }
                Push-Location $execRoot
                # WHY not `2>&1`: see the -eq 'nx' branch above -- same crash, same fix.
                try { & npx @cmd | Out-Null; $exitCode = $LASTEXITCODE } finally { Pop-Location }

                $trx = [ordered]@{ Executed = 0; Passed = 0; Failed = 0; Skipped = 0; Failures = @(); PerTestDurations = @() }
                $zeroMatch = $false
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
            }
            $sw.Stop()
            $durationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 3)

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
                durationSeconds  = $durationSeconds
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

    # ---------------- flaky repeats (affected mode only, subset was fast) --------
    $flaky = [ordered]@{ repeats = $FlakyRepeats; flipped = @(); skippedReason = $null }
    if ($GeneratedOnly -or $FlakyRepeats -le 0) {
        $flaky.skippedReason = if ($GeneratedOnly) { 'not applicable in -GeneratedOnly mode' } else { 'disabled (-FlakyRepeats 0)' }
    }
    elseif ($firstPassSeconds -gt 30.0) {
        $flaky.skippedReason = "affected subset took ${firstPassSeconds}s on the first pass (>30s threshold)"
    }
    else {
        $baselineOutcomes = @{}
        foreach ($r in $runs) {
            foreach ($ptd in @(Get-Prop $r 'perTestDurations' @())) {
                $fqn = [string](Get-Prop $ptd 'fqn' '')
                if ($fqn) { $baselineOutcomes[$fqn] = ($r.failures.fqn -notcontains $fqn) }
            }
        }
        $flippedSet = New-Object 'System.Collections.Generic.HashSet[string]'
        for ($i = 2; $i -le $FlakyRepeats; $i++) {
            foreach ($prof in $profiles) {
                $framework = [string](Get-Prop $prof 'framework' '')
                if (-not (@('xunit', 'nunit3', 'nunit4') -contains $framework)) { continue }
                $projRel = ([string](Get-Prop $prof 'projectPath' '')) -replace '\\', '/'
                $projAbs = Join-Path $execRoot ($projRel -replace '/', '\')
                if (-not (Test-Path -LiteralPath $projAbs)) { continue }
                $classes = Get-AffectedTestClasses -Profile $prof -DiffSet $diffSet
                $filter = Get-DotnetTestFilter -Framework $framework -TestClasses $classes
                if (-not $filter) { continue }
                $trxNameRepeat = "$(($projRel -replace '[\\/:]', '_'))-run$i.trx"
                $trxPathRepeat = Join-Path $trxDir $trxNameRepeat
                $repeatArgs = @($projAbs, '--no-build', '--no-restore', '--filter', $filter,
                    '--logger', "trx;LogFileName=$trxNameRepeat", '--results-directory', $trxDir,
                    '--', "RunConfiguration.MaxCpuCount=$cores", 'RunConfiguration.TreatNoTestsAsError=true')
                & dotnet test @repeatArgs | Out-Null   # WHY not 2>&1: same crash as above
                $trxRepeat = Read-TrxResult -TrxPath $trxPathRepeat
                foreach ($ptd in $trxRepeat.PerTestDurations) {
                    $fqn = [string](Get-Prop $ptd 'fqn' '')
                    $passedNow = ($trxRepeat.Failures.fqn -notcontains $fqn)
                    if ($baselineOutcomes.ContainsKey($fqn) -and $baselineOutcomes[$fqn] -ne $passedNow) {
                        $null = $flippedSet.Add($fqn)
                    }
                }
            }
        }
        $flaky.flipped = @($flippedSet)
    }

    Write-JsonFileNoBom -Object ([ordered]@{ runs = @($runs.ToArray()); flaky = $flaky }) -Path (Join-Path $workspaceDir 'test-results.json')

    # ---------------- calibration (merge, never clobber unrelated keys) ---------
    if (-not $GeneratedOnly -and $plainRunSecondsTotal -gt 0) {
        $calibPath = Join-Path (Split-Path -Parent $workspaceDir) 'calibration.json'
        $calib = if (Test-Path -LiteralPath $calibPath) { Read-JsonFile -Path $calibPath } else { [pscustomobject]@{} }
        $calibHash = [ordered]@{}
        foreach ($p in $calib.PSObject.Properties) { $calibHash[$p.Name] = $p.Value }
        $calibHash['plainRunSeconds'] = $plainRunSecondsTotal
        Write-JsonFileNoBom -Object $calibHash -Path $calibPath
    }

    $totalExecuted = 0; $totalPassed = 0; $totalFailed = 0; $anyZeroMatch = $false
    foreach ($r in $runs) {
        $totalExecuted += [int](Get-Prop $r 'testsExecuted' 0)
        $totalPassed += [int](Get-Prop $r 'passed' 0)
        $totalFailed += [int](Get-Prop $r 'failed' 0)
        if ([bool](Get-Prop $r 'zeroMatchError' $false)) { $anyZeroMatch = $true }
    }
    $mode = if ($GeneratedOnly) { 'generated' } else { 'affected' }
    Write-Output ("run-tests ({0}): {1} project run(s)  -  {2}/{3} passed{4}" -f $mode, $runs.Count, $totalPassed, $totalExecuted, $(if ($anyZeroMatch) { '  -  WARNING: at least one zero-match filter' } else { '' }))
    exit 0
}
catch {
    [Console]::Error.WriteLine("run-tests.ps1 FAILED: $($_.Exception.Message)")
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    exit 1
}
