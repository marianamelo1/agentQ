<#
.SYNOPSIS
    agentQ semantic-mutant driver  -  runs the AI-authored business-rule mutants.

.DESCRIPTION
    Reads <workspaceDir>/mutants.json (written by the qa-mutation-author agent).
    All mutant code is ALREADY injected in the worktree behind AGENTQ_MUTANT
    env-var switches, so the flow is:
      1. ONE build per distinct test project (all mutants share the same binaries
          -  the env-var switch selects the active mutant at runtime).
      2. Baseline sanity: every distinct (testProject, filter) pair must pass with
         NO mutant active.
      3. One fresh `dotnet test` process per mutant id with AGENTQ_MUTANT set.
      4. Update mutants.json in place with status/killedBy/testsCompleted/
         durationSeconds per mutant.
    Exit code 0 means the script ran (findings live in mutants.json); non-zero
    means the script itself failed. Prints exactly one summary line to stdout.

.PARAMETER Manifest
    Path to run-manifest.json (shape in scripts/CONTRACTS.md).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Manifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-Prop {
    # StrictMode-safe property access on PSCustomObjects from ConvertFrom-Json:
    # touching a missing property directly would throw under StrictMode.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Write-Utf8NoBom {
    # WHY: CONTRACTS.md mandates UTF-8 *without* BOM for every artifact, but
    # PowerShell 5.1's `Out-File -Encoding utf8` always emits a BOM. Writing
    # through .NET is the only way to satisfy the contract on 5.1.
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Invoke-Dotnet {
    # WHY the EAP dance: PS 5.1 wraps native stderr in ErrorRecords when
    # redirected; under $ErrorActionPreference = 'Stop' the first stderr line
    # from dotnet would abort the whole script even on a successful build.
    # EAP is dynamically scoped, so flipping it here affects this call only.
    param([string[]]$ArgumentList, [string]$WorkingDirectory)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Push-Location -LiteralPath $WorkingDirectory
        try {
            $lines = @(& dotnet @ArgumentList 2>&1 | ForEach-Object { $_.ToString() })
            $code = $LASTEXITCODE   # checked explicitly  -  never infer from $?
        }
        finally { Pop-Location }
    }
    finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{
        ExitCode = $code
        Output   = ($lines -join [Environment]::NewLine)
    }
}

function Read-TrxSummary {
    # Minimal TRX read: executed count + failed test names. GetElementsByTagName
    # sidesteps the TRX XML namespace, which varies across vstest versions.
    param([string]$TrxPath)
    $info = [pscustomobject]@{ Exists = $false; Executed = 0; FailedTestNames = @() }
    if (-not (Test-Path -LiteralPath $TrxPath)) { return $info }
    try { [xml]$trx = Get-Content -LiteralPath $TrxPath -Raw }
    catch { return $info }   # unreadable TRX == no evidence; caller treats as missing
    $info.Exists = $true
    $counters = $trx.GetElementsByTagName('Counters')
    if ($counters.Count -gt 0) {
        $executedAttr = $counters[0].GetAttribute('executed')
        if ($executedAttr) { $info.Executed = [int]$executedAttr }
    }
    $failed = @()
    foreach ($r in $trx.GetElementsByTagName('UnitTestResult')) {
        if ($r.GetAttribute('outcome') -eq 'Failed') { $failed += $r.GetAttribute('testName') }
    }
    $info.FailedTestNames = $failed
    return $info
}

function Set-MutantResult {
    # -Force everywhere: re-runs must overwrite prior verdicts (idempotency).
    param($Mutant, [string]$Status, [string[]]$KilledBy, [int]$TestsCompleted,
          [double]$DurationSeconds, $Reason)
    if ($null -eq $KilledBy) { $KilledBy = @() }
    $Mutant | Add-Member -NotePropertyName status          -NotePropertyValue $Status -Force
    $Mutant | Add-Member -NotePropertyName killedBy        -NotePropertyValue @($KilledBy) -Force
    $Mutant | Add-Member -NotePropertyName testsCompleted  -NotePropertyValue $TestsCompleted -Force
    $Mutant | Add-Member -NotePropertyName durationSeconds -NotePropertyValue ([math]::Round($DurationSeconds, 1)) -Force
    $Mutant | Add-Member -NotePropertyName statusReason    -NotePropertyValue $Reason -Force
}

# vstest's wording when a --filter matches nothing (TreatNoTestsAsError makes
# this a non-zero exit, so text is how we tell "zero match" from "tests failed").
$ZeroMatchPattern = 'No test matches the given testcase filter|No test is available'

# ---------------------------------------------------------------------------
# Load manifest + mutants.json
# ---------------------------------------------------------------------------

$manifestPath = (Resolve-Path -LiteralPath $Manifest).Path
$run          = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$workspaceDir = Get-Prop $run 'workspaceDir'
$worktreeDir  = Get-Prop $run 'worktreeDir'
if (-not $workspaceDir -or -not (Test-Path -LiteralPath $workspaceDir)) {
    throw "run-manifest.json has no resolvable workspaceDir ('$workspaceDir')."
}
if (-not $worktreeDir -or -not (Test-Path -LiteralPath $worktreeDir)) {
    throw "run-manifest.json has no resolvable worktreeDir ('$worktreeDir')."
}

$mutantsPath = Join-Path $workspaceDir 'mutants.json'
if (-not (Test-Path -LiteralPath $mutantsPath)) {
    # Missing input is a script failure (the orchestrator only calls the driver
    # after qa-mutation-author wrote the file), not a finding.
    throw "mutants.json not found at $mutantsPath  -  qa-mutation-author must run first."
}
$doc     = Get-Content -LiteralPath $mutantsPath -Raw | ConvertFrom-Json
$mutants = @(Get-Prop $doc 'mutants' @())

if ($mutants.Count -eq 0) {
    Write-Output '0 survived / 0 killed / 0 skipped'
    exit 0
}

# WHY: an AGENTQ_MUTANT value inherited from a crashed prior run (or a curious
# shell) would silently activate a mutant during the build and the baseline,
# poisoning every verdict below. Clear it before anything runs.
if (Test-Path Env:\AGENTQ_MUTANT) { Remove-Item Env:\AGENTQ_MUTANT }

# All run evidence (TRX + tool logs) lives under workspace  -  never the product repo.
$evidenceDir = Join-Path $workspaceDir 'semantic-mutants'
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

function Resolve-TestProjectPath {
    param([string]$TestProject)
    if ([System.IO.Path]::IsPathRooted($TestProject)) { return $TestProject }
    return (Join-Path $worktreeDir $TestProject)
}

# ---------------------------------------------------------------------------
# Pre-pass: mutants that cannot be run at all (malformed entries)
# ---------------------------------------------------------------------------

$runnable = @()
foreach ($m in $mutants) {
    $proj   = Get-Prop $m 'testProject'
    $filter = Get-Prop $m 'filter'
    if (-not $proj -or -not $filter) {
        # WHY Ignored (not Survived): with no test project/filter there is zero
        # test evidence  -  claiming "your tests would not catch this" off zero
        # tests would be a false pass.
        Set-MutantResult -Mutant $m -Status 'Ignored' -KilledBy @() -TestsCompleted 0 `
            -DurationSeconds 0 -Reason 'mutants.json entry has no testProject/filter  -  cannot run any test against it'
        continue
    }
    $runnable += ,$m
}

# ---------------------------------------------------------------------------
# Step 1  -  ONE build per distinct test project
# WHY one build: every mutant is already injected behind its env-var switch, so
# a single set of binaries serves all of them; rebuilding per mutant would
# multiply the phase time for nothing.
# ---------------------------------------------------------------------------

$distinctProjects = @($runnable | ForEach-Object { Resolve-TestProjectPath (Get-Prop $_ 'testProject') } | Sort-Object -Unique)
$buildFailed = @{}

foreach ($proj in $distinctProjects) {
    Write-Verbose "Building $proj"
    $res = Invoke-Dotnet -ArgumentList @('build', $proj, '-c', 'Debug', '--no-restore') -WorkingDirectory $worktreeDir
    $logName = 'build-' + ([System.IO.Path]::GetFileNameWithoutExtension($proj) -replace '[^\w\-\.]', '_') + '.log'
    Write-Utf8NoBom -Path (Join-Path $evidenceDir $logName) -Content $res.Output
    if ($res.ExitCode -ne 0) { $buildFailed[$proj] = $res.ExitCode }
}

if ($buildFailed.Count -gt 0) {
    # Build failure is a FINDING (the injected mutant code does not compile),
    # not a script failure  -  mark, write results, exit 0 per the contract.
    foreach ($m in $runnable) {
        $proj = Resolve-TestProjectPath (Get-Prop $m 'testProject')
        if ($buildFailed.ContainsKey($proj)) {
            Set-MutantResult -Mutant $m -Status 'CompileError' -KilledBy @() -TestsCompleted 0 `
                -DurationSeconds 0 -Reason "dotnet build of $proj failed (exit $($buildFailed[$proj]))  -  injected mutant code does not compile; see $evidenceDir"
        }
    }
    $runnable = @($runnable | Where-Object { -not $buildFailed.ContainsKey((Resolve-TestProjectPath (Get-Prop $_ 'testProject'))) })
}

# ---------------------------------------------------------------------------
# Step 2  -  baseline sanity: each distinct (testProject, filter) pair ONCE with
# no AGENTQ_MUTANT set.
# WHY: a "Survived" verdict means "your tests pass even with the rule broken"  - 
# that claim is only meaningful against a green baseline. If the tests already
# fail with NO mutant active, the injection itself broke behavior and every
# verdict on that filter would be noise.
# ---------------------------------------------------------------------------

$baseline = @{}   # "<proj>|<filter>" -> 'pass' | 'zero' | 'broken'
$baselineIndex = 0

foreach ($m in $runnable) {
    $proj   = Resolve-TestProjectPath (Get-Prop $m 'testProject')
    $filter = Get-Prop $m 'filter'
    $key    = "$proj|$filter"
    if ($baseline.ContainsKey($key)) { continue }

    $baselineIndex++
    $trxName = "agentq-baseline-$baselineIndex.trx"
    $trxPath = Join-Path $evidenceDir $trxName
    if (Test-Path -LiteralPath $trxPath) { Remove-Item -LiteralPath $trxPath -Force }

    Write-Verbose "Baseline: $filter ($proj)"
    $res = Invoke-Dotnet -WorkingDirectory $worktreeDir -ArgumentList @(
        'test', $proj, '--no-build', '-c', 'Debug',
        '--filter', $filter,
        '--logger', "trx;LogFileName=$trxName",
        '--results-directory', $evidenceDir,
        '--', 'RunConfiguration.TreatNoTestsAsError=true'
    )
    Write-Utf8NoBom -Path (Join-Path $evidenceDir "baseline-$baselineIndex.log") -Content $res.Output
    $trx = Read-TrxSummary -TrxPath $trxPath

    if ($res.Output -match $ZeroMatchPattern) {
        $baseline[$key] = 'zero'
    }
    elseif ($res.ExitCode -eq 0 -and $trx.Executed -gt 0) {
        $baseline[$key] = 'pass'
    }
    elseif ($res.ExitCode -eq 0) {
        # Exit 0 but nothing executed (runner ignored TreatNoTestsAsError, or
        # every match was skipped)  -  still zero evidence, so treat as zero-match.
        $baseline[$key] = 'zero'
    }
    else {
        $baseline[$key] = 'broken'
    }
}

# ---------------------------------------------------------------------------
# Step 3  -  one fresh test process per mutant id.
# WHY fresh process per id: the injected switches are read in static
# initializers / static readonly fields, which run once per process (verified)
#  -  reusing a process would freeze the first mutant's state for all later ids.
# ---------------------------------------------------------------------------

foreach ($m in $runnable) {
    $id     = [string](Get-Prop $m 'id')
    $proj   = Resolve-TestProjectPath (Get-Prop $m 'testProject')
    $filter = Get-Prop $m 'filter'
    $key    = "$proj|$filter"

    # if/elseif, NOT switch: in PowerShell `continue` inside a switch continues
    # the switch (it is a looping construct), not this foreach  -  skipped mutants
    # would fall through and run anyway.
    if ($baseline[$key] -eq 'zero') {
        # WHY Ignored: never a Survived claim off zero tests  -  a filter that
        # matches nothing proves nothing about detection.
        Set-MutantResult -Mutant $m -Status 'Ignored' -KilledBy @() -TestsCompleted 0 `
            -DurationSeconds 0 -Reason "filter '$filter' matched zero tests at baseline"
        continue
    }
    elseif ($baseline[$key] -eq 'broken') {
        # CompileError-equivalent: the injection broke green behavior, so no
        # verdict for this mutant can be trusted. Named status per spec.
        Set-MutantResult -Mutant $m -Status 'BaselineBroken' -KilledBy @() -TestsCompleted 0 `
            -DurationSeconds 0 -Reason "baseline run of '$filter' failed with no mutant active  -  injection broke behavior; a survived verdict is only meaningful against a green baseline"
        continue
    }

    $safeId  = ($id -replace '[^\w\-\.]', '_')
    $trxName = "agentq-$safeId.trx"
    $trxPath = Join-Path $evidenceDir $trxName
    if (Test-Path -LiteralPath $trxPath) { Remove-Item -LiteralPath $trxPath -Force }

    Write-Verbose "Mutant $id : $filter"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $env:AGENTQ_MUTANT = $id
        $res = Invoke-Dotnet -WorkingDirectory $worktreeDir -ArgumentList @(
            'test', $proj, '--no-build', '-c', 'Debug',
            '--filter', $filter,
            '--logger', "trx;LogFileName=$trxName",
            '--results-directory', $evidenceDir,
            '--', 'RunConfiguration.TreatNoTestsAsError=true'
        )
    }
    finally {
        # Always unset  -  a leaked value would activate this mutant in every
        # later run and in the baseline of any re-run.
        Remove-Item Env:\AGENTQ_MUTANT -ErrorAction SilentlyContinue
    }
    $sw.Stop()
    Write-Utf8NoBom -Path (Join-Path $evidenceDir "run-$safeId.log") -Content $res.Output
    $trx = Read-TrxSummary -TrxPath $trxPath
    $secs = $sw.Elapsed.TotalSeconds

    if ($res.Output -match $ZeroMatchPattern) {
        # WHY Ignored, never Survived: zero matched tests is zero evidence.
        Set-MutantResult -Mutant $m -Status 'Ignored' -KilledBy @() -TestsCompleted $trx.Executed `
            -DurationSeconds $secs -Reason "filter '$filter' matched zero tests"
    }
    elseif ($res.ExitCode -eq 0 -and $trx.Executed -gt 0) {
        # Green with the rule broken = the tests would not catch this.
        Set-MutantResult -Mutant $m -Status 'Survived' -KilledBy @() -TestsCompleted $trx.Executed `
            -DurationSeconds $secs -Reason $null
    }
    elseif ($res.ExitCode -eq 0) {
        # Exit 0 with zero executed tests (runner quirk)  -  same zero-evidence rule.
        Set-MutantResult -Mutant $m -Status 'Ignored' -KilledBy @() -TestsCompleted 0 `
            -DurationSeconds $secs -Reason 'test run exited 0 but executed zero tests  -  no evidence either way'
    }
    else {
        # Non-zero exit against a green baseline = the mutant was detected.
        $killedBy = @($trx.FailedTestNames)
        $reason = $null
        if ($killedBy.Count -eq 0) {
            # Non-zero exit but no failed tests in the TRX (or no TRX): the test
            # host crashed under the mutant. Still a detection  -  CI would go red
            # the same way  -  but say so instead of naming phantom tests.
            $reason = 'test process exited non-zero without failed tests in TRX (host crash under mutant  -  treated as detected)'
        }
        Set-MutantResult -Mutant $m -Status 'Killed' -KilledBy $killedBy -TestsCompleted $trx.Executed `
            -DurationSeconds $secs -Reason $reason
    }
}

# ---------------------------------------------------------------------------
# Step 4  -  write mutants.json back in place, print the one summary line
# ---------------------------------------------------------------------------

$json = $doc | ConvertTo-Json -Depth 12
Write-Utf8NoBom -Path $mutantsPath -Content $json

$survived = @($mutants | Where-Object { (Get-Prop $_ 'status') -eq 'Survived' }).Count
$killed   = @($mutants | Where-Object { (Get-Prop $_ 'status') -eq 'Killed' }).Count
$skipped  = $mutants.Count - $survived - $killed   # Ignored + CompileError + BaselineBroken

Write-Output "$survived survived / $killed killed / $skipped skipped"
exit 0
