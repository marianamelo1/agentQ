#Requires -Version 5.1
# =============================================================================
# stryker-run.ps1  -  agentQ Phase 5, mechanical mutation tier (Stryker.NET + StrykerJS)
#
# Inputs (shapes in scripts/CONTRACTS.md):
#   -Manifest                 run-manifest.json (workspaceDir, worktreeDir)
#   <workspace>/diff-set.json         changed files + hunks (+ untracked)
#   <workspace>/diff-coverage.json    zero-coverage changed lines (optional; may be refused)
#   <workspace>/adapter-profiles.json affected test projects + their SUT projects
#
# Output:
#   <workspace>/stryker/summary.json
#     { projects: [ { project, reportPath, partial, testedMutants, totalMutants,
#                     killed, survived, noCoverage, timeout, skipped, reason } ] }
#   `skipped`/`reason` are additive to the task's field list: the spec requires
#   recording skip/partial reasons (e.g. the JS lane), and a reasonless skip would
#   violate "a skipped stage can never read as a pass". All spec-named fields are
#   emitted verbatim; unknown counts are null, never fabricated zeros.
#
# Exit code 0 = the script ran (findings live in the artifact); non-zero = the
# script itself failed. Exactly one summary line is printed to stdout.
#
# Guardrails encoded here (each verified  -  see comments at the site of use):
#   * pinned local dotnet-stryker in the WORKTREE only, never the product repo
#   * NEVER --since (triple-broken; the documented 7-8h incident)
#   * -m span globs use CHARACTER offsets, not line numbers; padded + merged;
#     whole-file fallback when spans yield 0 mutants (span grammar is undocumented)
#   * config-file-only options written to stryker-config.json in the test project dir
#   * -O output dir pre-created (Stryker validates it exists)
#   * wall-clock anti-hang valve: kill process tree, restore *.stryker-unchanged
#     DLL backups (Stryker's Restore() is not in a finally), record partial=true
# =============================================================================
[CmdletBinding()]
param(
    # Path to run-manifest.json for this run (see scripts/CONTRACTS.md).
    [Parameter(Mandatory = $true)]
    [string]$Manifest,

    # Opt-in thorough mode: mutation-level Standard, whole changed files,
    # no span scoping and no uncovered-region subtraction.
    [switch]$Deep,

    # Generous anti-hang safety valve, NOT an SLA. Stryker has no time-limit
    # option and a wedged testhost can hang forever; nothing in this script
    # treats time as a budget. Tripping the valve kills the process tree,
    # restores DLL backups, and records partial=true  -  it never reads as a pass.
    [int]$TimeoutMinutes = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------

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
    # BOM" for every artifact, and PS 5.1's Out-File -Encoding utf8 always emits a
    # BOM. An explicit BOM-less UTF8Encoding is the only 5.1-safe way to comply.
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $json = ConvertTo-Json -InputObject $Object -Depth 12
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $enc)
}

function Stop-ProcessTree {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    # WHY taskkill /T: Stryker spawns testhost/vstest child processes; killing only
    # the parent orphans them mid-mutation and they keep the mutated DLLs locked,
    # which would break the backup restore below.
    # WHY via cmd with >nul 2>&1: under $ErrorActionPreference='Stop', PS 5.1 turns
    # redirected native stderr into a terminating NativeCommandError  -  cmd swallows
    # taskkill's output (including the benign "not found" race when the process
    # exited between the timeout check and the kill).
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & cmd.exe /d /c "taskkill /PID $ProcessId /T /F >nul 2>&1" | Out-Null } catch { }
    $ErrorActionPreference = $prev
}

function Invoke-Native {
    # Runs one native command with cwd + wall-clock timeout, output to log files.
    # WHY Start-Process + log files (not `& cmd 2>&1`): keeps stdout clean (the
    # contract is exactly ONE final summary line), avoids PS 5.1's NativeCommandError
    # trap on redirected stderr, and gives us a real wall clock + tree kill.
    # $LASTEXITCODE does not apply to Start-Process  -  the returned ExitCode is the
    # explicit per-call exit check the coding rules require.
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$LogBase,
        [int]$TimeoutMs = 0
    )
    $outLog = "$LogBase.out.log"
    $errLog = "$LogBase.err.log"
    Write-Verbose ("exec: {0} {1}  (cwd={2})" -f $FilePath, $Arguments, $WorkingDirectory)
    $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments `
        -WorkingDirectory $WorkingDirectory -PassThru -NoNewWindow `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $timedOut = $false
    if ($TimeoutMs -gt 0) {
        if (-not $proc.WaitForExit($TimeoutMs)) {
            $timedOut = $true
            Stop-ProcessTree -ProcessId $proc.Id
            $null = $proc.WaitForExit(15000)   # give the tree kill time to land
        }
    }
    else {
        $proc.WaitForExit()
    }
    $exitCode = -1
    if (-not $timedOut) { $exitCode = $proc.ExitCode }
    return @{ ExitCode = $exitCode; TimedOut = $timedOut; OutLog = $outLog; ErrLog = $errLog }
}

function Restore-StrykerBackup {
    # WHY: Stryker's Restore() is NOT in a finally block (verified)  -  a killed or
    # crashed run leaves *.dll.stryker-unchanged backups beside the mutated DLLs.
    # Copy each backup back over its sibling and delete the backup, or the next
    # build/test run executes mutated code.
    param([Parameter(Mandatory = $true)][string]$Root)
    $suffix = '.stryker-unchanged'
    $backups = @(Get-ChildItem -Path $Root -Recurse -Filter "*$suffix" -File -ErrorAction SilentlyContinue)
    foreach ($b in $backups) {
        $orig = $b.FullName.Substring(0, $b.FullName.Length - $suffix.Length)
        Copy-Item -LiteralPath $b.FullName -Destination $orig -Force
        Remove-Item -LiteralPath $b.FullName -Force
    }
    return $backups.Count
}

function Convert-LinesToRanges {
    # sorted unique line numbers -> contiguous @{Start;End} line ranges
    param([int[]]$Lines)
    $ranges = @()
    $sorted = @($Lines | Sort-Object -Unique)
    $start = $null
    $prev = $null
    foreach ($ln in $sorted) {
        if ($null -eq $start) { $start = $ln; $prev = $ln; continue }
        if ($ln -eq ($prev + 1)) { $prev = $ln; continue }
        $ranges += , @{ Start = $start; End = $prev }
        $start = $ln
        $prev = $ln
    }
    if ($null -ne $start) { $ranges += , @{ Start = $start; End = $prev } }
    return , $ranges
}

function Get-CharSpans {
    # WHY character offsets: Stryker's -m "path{start..end}" suffix takes Roslyn
    # TextSpan CHARACTER offsets, NOT line numbers (verified). We compute them by
    # reading the worktree file and mapping line numbers -> char offsets.
    param(
        [Parameter(Mandatory = $true)][string]$AbsPath,
        [Parameter(Mandatory = $true)]$LineRanges,   # @{Start;End} 1-based line ranges
        [int]$Pad = 200
    )
    $text = [System.IO.File]::ReadAllText($AbsPath)
    if ($text.Length -eq 0) { return , @() }
    # line-start offsets: line N (1-based) starts at $lineStarts[N-1]
    $lineStarts = New-Object 'System.Collections.Generic.List[int]'
    $lineStarts.Add(0)
    $idx = $text.IndexOf("`n")
    while ($idx -ge 0) {
        $lineStarts.Add($idx + 1)
        $idx = $text.IndexOf("`n", $idx + 1)
    }
    $lineCount = $lineStarts.Count
    $spans = @()
    foreach ($r in @($LineRanges)) {
        $a = [Math]::Max(1, [int]$r.Start)
        $b = [Math]::Min($lineCount, [int]$r.End)
        if ($a -gt $lineCount -or $b -lt $a) { continue }
        $s = $lineStarts[$a - 1]
        $e = $text.Length
        if ($b -lt $lineCount) { $e = $lineStarts[$b] }
        # WHY ±200 chars padding: hunk boundaries clip statements/expressions mid-way;
        # padding keeps the whole surrounding construct mutable so boundary mutants
        # aren't silently missed. Clamp to the file, then merge overlaps below.
        $s = [Math]::Max(0, $s - $Pad)
        $e = [Math]::Min($text.Length, $e + $Pad)
        $spans += , @{ Start = $s; End = $e }
    }
    # merge overlapping/adjacent spans  -  Stryker gets one clean glob per region
    $merged = @()
    foreach ($sp in @($spans | Sort-Object { $_.Start })) {
        if ($merged.Count -gt 0 -and $sp.Start -le $merged[-1].End) {
            if ($sp.End -gt $merged[-1].End) { $merged[-1].End = $sp.End }
        }
        else {
            $merged += , @{ Start = $sp.Start; End = $sp.End }
        }
    }
    return , $merged
}

function Get-FileMutateGlobs {
    # One changed file -> mutate glob(s). Normal mode: char-span globs over changed
    # hunks MINUS zero-coverage lines. -Deep or untracked: whole-file glob.
    param(
        $File,                       # @{ Path; Hunks; Untracked }
        [string]$RelPath,            # path relative to the SUT project dir (fwd slashes)
        $UncoveredLines,             # HashSet[int] of zero-coverage changed lines, or $null
        [bool]$SpanScope,            # $false under -Deep
        [string]$AbsPath             # the file inside the worktree
    )
    $wholeGlob = '**/' + $RelPath
    if (-not $SpanScope) {
        # -Deep: whole files, no scoping  -  the opt-in thorough mode
        return @{ Globs = @($wholeGlob); UsedSpans = $false; DroppedByCoverage = $false }
    }
    if ($File.Untracked -or $null -eq $File.Hunks -or @($File.Hunks).Count -eq 0) {
        # Untracked files have no hunks to span  -  mutate the whole file. Any
        # zero-coverage regions inside become NoCoverage mutants, which perTest
        # coverage-analysis shortcuts cheaply and the report consumer suppresses.
        return @{ Globs = @($wholeGlob); UsedSpans = $false; DroppedByCoverage = $false }
    }
    $lines = @()
    foreach ($h in @($File.Hunks)) {
        $ns = [int](Get-Prop $h 'newStart' 0)
        $nc = [int](Get-Prop $h 'newCount' 0)
        if ($nc -le 0 -or $ns -le 0) { continue }   # pure-deletion hunk: nothing on the new side to mutate
        $lines += $ns..($ns + $nc - 1)
    }
    if ($lines.Count -eq 0) {
        return @{ Globs = @(); UsedSpans = $false; DroppedByCoverage = $false }
    }
    if ($null -ne $UncoveredLines) {
        # MINUS zero-coverage regions: mutants there can only be NoCoverage  -  pure
        # waste, and they would double-count findings the coverage lane already owns.
        $lines = @($lines | Where-Object { -not $UncoveredLines.Contains([int]$_) })
        if ($lines.Count -eq 0) {
            return @{ Globs = @(); UsedSpans = $false; DroppedByCoverage = $true }
        }
    }
    if (-not (Test-Path -LiteralPath $AbsPath)) {
        # worktree drift (should not happen)  -  a whole-file glob beats a silent skip
        return @{ Globs = @($wholeGlob); UsedSpans = $false; DroppedByCoverage = $false }
    }
    $ranges = Convert-LinesToRanges -Lines $lines
    $spans = Get-CharSpans -AbsPath $AbsPath -LineRanges $ranges -Pad 200
    $globs = @()
    foreach ($sp in @($spans)) {
        $globs += ('**/{0}{{{1}..{2}}}' -f $RelPath, $sp.Start, $sp.End)
    }
    if ($globs.Count -eq 0) {
        return @{ Globs = @($wholeGlob); UsedSpans = $false; DroppedByCoverage = $false }
    }
    return @{ Globs = $globs; UsedSpans = $true; DroppedByCoverage = $false }
}

function Read-MutationCounts {
    # Parse a mutation-testing-elements report -> per-status counts. Returns $null
    # when the report is missing/unreadable (caller decides what that means).
    param([Parameter(Mandatory = $true)][string]$ReportPath)
    if (-not (Test-Path -LiteralPath $ReportPath)) { return $null }
    $report = $null
    try { $report = Read-JsonFile -Path $ReportPath } catch { return $null }
    $c = @{ Killed = 0; Survived = 0; NoCoverage = 0; Timeout = 0; Total = 0 }
    $files = Get-Prop $report 'files'
    if ($null -ne $files) {
        foreach ($fp in $files.PSObject.Properties) {
            foreach ($m in @(Get-Prop $fp.Value 'mutants' @())) {
                $c.Total++
                switch ([string](Get-Prop $m 'status' '')) {
                    'Killed' { $c.Killed++ }
                    'Survived' { $c.Survived++ }
                    'NoCoverage' { $c.NoCoverage++ }
                    'Timeout' { $c.Timeout++ }
                    default { }   # Ignored / CompileError / Pending count toward Total only
                }
            }
        }
    }
    return $c
}

function Read-ConsoleProgress {
    # Best-effort tested/total extraction from a killed run's console log  -  Stryker's
    # progress output carries "<tested> / <total>" counters. Used ONLY to qualify a
    # partial result ("tested X of Y mutants  -  no claims about the rest").
    param([Parameter(Mandatory = $true)][string]$LogPath)
    if (-not (Test-Path -LiteralPath $LogPath)) { return $null }
    $text = $null
    try { $text = Get-Content -LiteralPath $LogPath -Raw } catch { return $null }
    if ([string]::IsNullOrEmpty($text)) { return $null }
    $best = $null
    foreach ($m in [regex]::Matches($text, '[Tt]ested\s+(\d+)\s+of\s+(\d+)')) {
        $best = @{ Tested = [int]$m.Groups[1].Value; Total = [int]$m.Groups[2].Value }
    }
    if ($null -eq $best) {
        foreach ($m in [regex]::Matches($text, '(\d+)\s*/\s*(\d+)')) {
            $a = [int]$m.Groups[1].Value
            $b = [int]$m.Groups[2].Value
            if ($b -gt 0 -and $a -le $b) { $best = @{ Tested = $a; Total = $b } }
        }
    }
    return $best
}

function Test-HasDevDependency {
    param([string]$PkgJsonPath, [string]$Name)
    if (-not (Test-Path -LiteralPath $PkgJsonPath)) { return $false }
    $pkg = $null
    try { $pkg = Read-JsonFile -Path $PkgJsonPath } catch { return $false }
    $dev = Get-Prop $pkg 'devDependencies'
    if ($null -ne $dev -and $null -ne (Get-Prop $dev $Name)) { return $true }
    return $false
}

function New-ProjectEntry {
    # Summary entry. Field names/order per the task contract; skipped/reason are the
    # documented additive fields. Unknown counts stay $null  -  never fabricated zeros.
    param(
        $Project = $null,
        $ReportPath = $null,
        [bool]$Partial = $false,
        $Tested = $null,
        $Total = $null,
        $Killed = $null,
        $Survived = $null,
        $NoCoverage = $null,
        $TimeoutCount = $null,
        [bool]$Skipped = $false,
        $Reason = $null
    )
    return [ordered]@{
        project       = $Project
        reportPath    = $ReportPath
        partial       = $Partial
        testedMutants = $Tested
        totalMutants  = $Total
        killed        = $Killed
        survived      = $Survived
        noCoverage    = $NoCoverage
        timeout       = $TimeoutCount
        skipped       = $Skipped
        reason        = $Reason
    }
}

function New-TimeoutEntry {
    param($Project, $Prog, [int]$Minutes, [string]$Extra = '')
    $tested = $null
    $total = $null
    if ($null -ne $Prog) { $tested = $Prog.Tested; $total = $Prog.Total }
    $reason = ("anti-hang valve tripped after {0} min  -  process tree killed, stryker DLL backups restored; " +
        "tested/total parsed from the console log where possible; no claims are made about untested mutants") -f $Minutes
    if ($Extra -ne '') { $reason = "$Extra; $reason" }
    return (New-ProjectEntry -Project $Project -Partial $true -Tested $tested -Total $total -Reason $reason)
}

# NEVER use --since. Verified triple-broken:
#   (1) it diffs against the base branch TIP, not the merge-base  -  unrelated upstream
#       churn lands in scope;
#   (2) branch matching is substring-based  -  feature/x also matches feature/x-2;
#   (3) a single non-.cs change under a test project escalates to mutating the FULL
#       repo (the documented 7-8h incident).
# All scoping is done here, deterministically, via explicit -m globs.
function Invoke-OneStryker {
    param(
        $Run,
        [string]$OutDir,
        [string]$LogBase,
        [int]$Cores,
        [int]$TimeoutMs,
        [string[]]$Globs
    )
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $parts.Add('stryker')
    # config file sits in the test project dir (= cwd), written just before this call
    $parts.Add('-f "stryker-config.json"')
    # WHY --project: a test project referencing several projects makes Stryker's
    # mutation target ambiguous; naming the SUT csproj removes the guesswork.
    $parts.Add(('--project "{0}"' -f $Run.SutName))
    foreach ($g in $Globs) { $parts.Add(('-m "{0}"' -f $g)) }
    # WHY logical core count: the scoped run is short and owns the machine during
    # this phase (CPU-heavy phases never overlap by design), so Stryker's default
    # of half the cores just doubles the wall clock.
    $parts.Add(('-c {0}' -f $Cores))
    $parts.Add('-r "json"')
    $parts.Add('-r "markdown"')
    # WHY -O: makes the report path deterministic (<O>/reports/mutation-report.json)
    # instead of Stryker's timestamped default folder.
    $parts.Add(('-O "{0}"' -f $OutDir))
    $argLine = ($parts -join ' ')
    return (Invoke-Native -FilePath 'dotnet' -Arguments $argLine `
            -WorkingDirectory $Run.TestProjDirAbs -LogBase $LogBase -TimeoutMs $TimeoutMs)
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
try {
    if ($TimeoutMinutes -lt 1) { throw "-TimeoutMinutes must be >= 1" }
    if (-not (Test-Path -LiteralPath $Manifest)) { throw "run-manifest not found: $Manifest" }
    $Manifest = (Resolve-Path -LiteralPath $Manifest).ProviderPath

    $runManifest = Read-JsonFile -Path $Manifest
    $workspaceDir = [string](Get-Prop $runManifest 'workspaceDir' '')
    $worktreeDir = [string](Get-Prop $runManifest 'worktreeDir' '')
    if ([string]::IsNullOrWhiteSpace($workspaceDir)) { throw 'run-manifest.json has no workspaceDir' }
    if ([string]::IsNullOrWhiteSpace($worktreeDir)) { throw 'run-manifest.json has no worktreeDir' }
    if (-not (Test-Path -LiteralPath $worktreeDir -PathType Container)) {
        throw "worktree missing ($worktreeDir)  -  run scripts/worktree.ps1 -Ensure first"
    }

    $diffSetPath = Join-Path $workspaceDir 'diff-set.json'
    $profilesPath = Join-Path $workspaceDir 'adapter-profiles.json'
    $diffCovPath = Join-Path $workspaceDir 'diff-coverage.json'
    if (-not (Test-Path -LiteralPath $diffSetPath)) { throw "diff-set.json not found: $diffSetPath" }
    if (-not (Test-Path -LiteralPath $profilesPath)) { throw "adapter-profiles.json not found: $profilesPath" }

    $diffSet = Read-JsonFile -Path $diffSetPath
    $profiles = @(Get-Prop (Read-JsonFile -Path $profilesPath) 'projects' @())
    # diff-coverage is optional: the coverage lane may have refused (path-mapping < 80%)
    # or not run. Without trustworthy coverage we skip the uncovered-region subtraction  - 
    # coverage-analysis perTest still shortcuts NoCoverage mutants cheaply inside Stryker,
    # and the report consumer suppresses them, so the waste is bounded and honest.
    $diffCov = $null
    if (Test-Path -LiteralPath $diffCovPath) { $diffCov = Read-JsonFile -Path $diffCovPath }

    $strykerRoot = Join-Path $workspaceDir 'stryker'
    $logsDir = Join-Path $strykerRoot 'logs'
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

    $timeoutMs = $TimeoutMinutes * 60 * 1000
    $cores = [Environment]::ProcessorCount   # logical cores, per spec
    $spanScope = -not $Deep.IsPresent
    $jsFrameworks = @('jest', 'vitest', 'nodetest')

    # ---------------- changed-file inventory (files ∪ untracked) ----------------
    # Untracked files matter: a plain diff silently misses a developer's brand-new class.
    $changedCs = @()      # @{ Path; Hunks; Untracked }
    $changedJsAll = @()   # repo-relative paths (strings)
    $jsExtRx = '\.(js|jsx|ts|tsx|mjs|cjs)$'
    $jsTestRx = '(\.(spec|test)\.[A-Za-z]+$)|((^|/)__tests__/)'
    foreach ($f in @(Get-Prop $diffSet 'files' @())) {
        if ([string](Get-Prop $f 'status' '') -eq 'D') { continue }   # deletions: nothing to mutate
        $p = ([string](Get-Prop $f 'path' '')) -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($p -match '\.cs$') {
            $changedCs += , @{ Path = $p; Hunks = @(Get-Prop $f 'hunks' @()); Untracked = $false }
        }
        elseif ($p -match $jsExtRx -and $p -notmatch '\.d\.ts$' -and $p -notmatch $jsTestRx) {
            $changedJsAll += $p
        }
    }
    foreach ($u in @(Get-Prop $diffSet 'untracked' @())) {
        $p = ([string]$u) -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($p -match '\.cs$') {
            $changedCs += , @{ Path = $p; Hunks = $null; Untracked = $true }
        }
        elseif ($p -match $jsExtRx -and $p -notmatch '\.d\.ts$' -and $p -notmatch $jsTestRx) {
            $changedJsAll += $p
        }
    }

    # ---------------- guard: semantic-mutant switches must be gone ----------------
    # WHY: verified live  -  running Stryker on a worktree that still carries the
    # AGENTQ_MUTANT env-var switches from the semantic tier makes Stryker mutate the
    # injected switch lines THEMSELVES, manufacturing artifact "survivors" that are
    # not product code. The orchestration order is: semantic tier -> driver ->
    # `worktree.ps1 -Ensure` (cheap reuse reset; generated tests re-staged) -> this
    # script. Fail fast and loud when that reset was skipped.
    $dirtyMutantFiles = @()
    foreach ($cf in $changedCs) {
        $abs = Join-Path $worktreeDir (([string]$cf.Path) -replace '/', '\')
        if ((Test-Path -LiteralPath $abs -PathType Leaf) -and
            (Select-String -LiteralPath $abs -Pattern 'AGENTQ_MUTANT' -Quiet)) {
            $dirtyMutantFiles += [string]$cf.Path
        }
    }
    if ($dirtyMutantFiles.Count -gt 0) {
        throw ("worktree still contains AGENTQ_MUTANT semantic-mutant switches in: {0}  -  run scripts/worktree.ps1 -Ensure to reset the worktree before the mechanical tier (Stryker would mutate the injected switches themselves and manufacture artifact survivors)" -f ($dirtyMutantFiles -join ', '))
    }

    # ---------------- zero-coverage line map from diff-coverage.json ----------------
    # Only 'uncovered' gap lines are subtracted; 'partial-branch' lines stay in scope  - 
    # mutants there are reachable and killable.
    $uncoveredMap = @{}   # lowercased fwd-slash path -> HashSet[int]
    if ($null -ne $diffCov -and -not [bool](Get-Prop $diffCov 'refused' $false)) {
        foreach ($g in @(Get-Prop $diffCov 'gaps' @())) {
            if ([string](Get-Prop $g 'kind' '') -ne 'uncovered') { continue }
            $key = (([string](Get-Prop $g 'file' '')) -replace '\\', '/').ToLowerInvariant()
            if ($key -eq '') { continue }
            if (-not $uncoveredMap.ContainsKey($key)) {
                $uncoveredMap[$key] = New-Object 'System.Collections.Generic.HashSet[int]'
            }
            $null = $uncoveredMap[$key].Add([int](Get-Prop $g 'line' 0))
        }
    }

    $entries = New-Object 'System.Collections.Generic.List[object]'
    $plannedRuns = New-Object 'System.Collections.Generic.List[object]'
    $usedKeys = @{}

    # ---------------- plan the .NET runs (scope per test project × SUT) ----------------
    foreach ($prof in $profiles) {
        $framework = [string](Get-Prop $prof 'framework' '')
        if ($jsFrameworks -contains $framework) { continue }   # JS lane handled below

        $testProjRel = ([string](Get-Prop $prof 'projectPath' '')) -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($testProjRel)) { continue }
        $li = $testProjRel.LastIndexOf('/')
        $testProjDirRel = ''
        if ($li -ge 0) { $testProjDirRel = $testProjRel.Substring(0, $li) }
        $testProjDirAbs = $worktreeDir
        if ($testProjDirRel -ne '') { $testProjDirAbs = Join-Path $worktreeDir ($testProjDirRel -replace '/', '\') }
        if (-not (Test-Path -LiteralPath $testProjDirAbs -PathType Container)) {
            $entries.Add((New-ProjectEntry -Project $testProjRel -Skipped $true `
                        -Reason 'test project directory not found in the worktree  -  re-run worktree.ps1 -Ensure'))
            continue
        }

        $suts = @()
        foreach ($s in @(Get-Prop $prof 'sutProjects' @())) {
            if (-not [string]::IsNullOrWhiteSpace([string]$s)) { $suts += (([string]$s) -replace '\\', '/') }
        }
        if ($suts.Count -eq 0) {
            $entries.Add((New-ProjectEntry -Project $testProjRel -Skipped $true `
                        -Reason 'adapter profile lists no sutProjects  -  cannot scope mutation to this test project'))
            continue
        }

        $testName = [System.IO.Path]::GetFileNameWithoutExtension($testProjRel)
        $candRuns = @()
        $filesSeen = 0
        $droppedByCov = 0
        foreach ($sutRel in $suts) {
            $li2 = $sutRel.LastIndexOf('/')
            $sutDir = ''
            if ($li2 -ge 0) { $sutDir = $sutRel.Substring(0, $li2) }
            $prefix = ''
            if ($sutDir -ne '') { $prefix = $sutDir + '/' }
            # changed .cs files under the SUT project directory only  -  test-project and
            # unrelated changes never widen the mutation scope
            $inScope = @($changedCs | Where-Object {
                    $prefix -eq '' -or ([string]$_.Path).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) })
            if ($inScope.Count -eq 0) { continue }
            $filesSeen += $inScope.Count

            $globs = @()
            $wholeGlobs = @()
            $usedSpans = $false
            foreach ($cf in $inScope) {
                $relPath = $cf.Path
                if ($prefix -ne '') { $relPath = $cf.Path.Substring($prefix.Length) }
                $uncov = $null
                $ck = $cf.Path.ToLowerInvariant()
                if ($uncoveredMap.ContainsKey($ck)) { $uncov = $uncoveredMap[$ck] }
                $absPath = Join-Path $worktreeDir ($cf.Path -replace '/', '\')
                $g = Get-FileMutateGlobs -File $cf -RelPath $relPath -UncoveredLines $uncov `
                    -SpanScope $spanScope -AbsPath $absPath
                if ($g.DroppedByCoverage) { $droppedByCov++; continue }
                if (@($g.Globs).Count -eq 0) { continue }
                $globs += @($g.Globs)
                $wholeGlobs += ('**/' + $relPath)   # kept for the zero-mutant fallback
                if ($g.UsedSpans) { $usedSpans = $true }
            }
            if ($globs.Count -eq 0) { continue }
            $sutName = $sutRel.Substring($sutRel.LastIndexOf('/') + 1)
            $candRuns += , @{ SutName = $sutName; Globs = $globs; WholeFileGlobs = $wholeGlobs; UsedSpans = $usedSpans }
        }

        if ($candRuns.Count -eq 0) {
            $reason = 'no changed C# files under the SUT project(s)  -  nothing to mutate'
            if ($filesSeen -gt 0) {
                if ($droppedByCov -gt 0) {
                    # a skipped stage must say WHY  -  this one is owned by the coverage findings
                    $reason = 'every changed region in scope has zero coverage  -  skipped: mutants there would all be NoCoverage (waste + double-count of the coverage findings)'
                }
                else {
                    $reason = 'changed files in scope contain no mutable new lines (deletions/renames only)'
                }
            }
            $entries.Add((New-ProjectEntry -Project $testProjRel -Skipped $true -Reason $reason))
            continue
        }

        foreach ($cr in $candRuns) {
            # deterministic -O key: test project name, disambiguated by SUT when a test
            # project covers several changed SUT projects (one Stryker run per SUT  - 
            # Stryker mutates exactly one project per invocation)
            $baseKey = ($testName -replace '[^A-Za-z0-9._-]', '_')
            if ($candRuns.Count -gt 1) {
                $baseKey = $baseKey + '__' + ((($cr.SutName) -replace '\.csproj$', '') -replace '[^A-Za-z0-9._-]', '_')
            }
            $key = $baseKey
            $n = 2
            while ($usedKeys.ContainsKey($key)) { $key = ('{0}-{1}' -f $baseKey, $n); $n++ }
            $usedKeys[$key] = $true
            $plannedRuns.Add(@{
                    TestProjPath   = $testProjRel
                    TestProjDirAbs = $testProjDirAbs
                    SutName        = $cr.SutName
                    Globs          = $cr.Globs
                    WholeFileGlobs = $cr.WholeFileGlobs
                    UsedSpans      = $cr.UsedSpans
                    Key            = $key
                })
        }
    }

    # ---------------- step 1: pinned local tool, WORKTREE only ----------------
    if ($plannedRuns.Count -gt 0) {
        $toolLogBase = Join-Path $logsDir 'tool'
        $toolsManifestPath = Join-Path $worktreeDir '.config\dotnet-tools.json'
        $hasStryker = $false
        if (Test-Path -LiteralPath $toolsManifestPath) {
            $tm = Read-JsonFile -Path $toolsManifestPath
            $tools = Get-Prop $tm 'tools'
            # If the repo pins its own dotnet-stryker version we respect that pin  - 
            # reproducibility of the repo's own setup beats our preferred version.
            if ($null -ne $tools -and $null -ne (Get-Prop $tools 'dotnet-stryker')) { $hasStryker = $true }
        }
        else {
            # WHY no --force: `dotnet new tool-manifest --force` would clobber a committed
            # manifest and its pinned tools  -  FORBIDDEN. Create only when absent, and only
            # under the worktree (the product repo is read-only, always).
            $r = Invoke-Native -FilePath 'dotnet' -Arguments 'new tool-manifest' `
                -WorkingDirectory $worktreeDir -LogBase "$toolLogBase-manifest" -TimeoutMs $timeoutMs
            if ($r.TimedOut -or $r.ExitCode -ne 0) {
                throw "dotnet new tool-manifest failed (exit $($r.ExitCode), timedOut=$($r.TimedOut))  -  see $($r.ErrLog)"
            }
        }
        if (-not $hasStryker) {
            # WHY the version pin: reproducible verdicts  -  the same branch must produce
            # the same mutants and the same verdict twice. A floating tool version can't.
            $r = Invoke-Native -FilePath 'dotnet' -Arguments 'tool install dotnet-stryker --version 4.16.0' `
                -WorkingDirectory $worktreeDir -LogBase "$toolLogBase-install" -TimeoutMs $timeoutMs
            if ($r.TimedOut -or $r.ExitCode -ne 0) {
                throw "dotnet tool install dotnet-stryker 4.16.0 failed (exit $($r.ExitCode), timedOut=$($r.TimedOut))  -  see $($r.ErrLog)"
            }
        }
        # always restore, so the pinned tool is materialized on this machine
        $r = Invoke-Native -FilePath 'dotnet' -Arguments 'tool restore' `
            -WorkingDirectory $worktreeDir -LogBase "$toolLogBase-restore" -TimeoutMs $timeoutMs
        if ($r.TimedOut -or $r.ExitCode -ne 0) {
            throw "dotnet tool restore failed (exit $($r.ExitCode), timedOut=$($r.TimedOut))  -  see $($r.ErrLog)"
        }
    }

    # ---------------- step 4: config-file-only options ----------------
    # WHY a config file at all: these options have NO CLI flags (verified)  -  they only
    # exist in stryker-config.json.
    $mutLevel = 'Basic'
    if ($Deep) { $mutLevel = 'Standard' }
    $strykerConfig = [ordered]@{
        'stryker-config' = [ordered]@{
            'coverage-analysis'             = 'perTest'   # skip test runs that cannot reach a mutant  -  the main scoped-run speedup
            'mutation-level'                = $mutLevel   # Basic normally; Standard only under -Deep
            'reporters'                     = @('json', 'markdown')
            'report-file-name'              = 'mutation-report'   # deterministic report path under -O
            # noise killers: mutants in these methods are unkillable-by-design or pure logging
            'ignore-methods'                = @('ToString', '*Logger.Log*', 'ConfigureAwait', '*Exception.ctor')
            # string/regex mutants are low-signal on business code and inflate run time
            'ignore-mutations'              = @('string', 'regex')
            'additional-timeout'            = 3000        # ms grace per test run  -  cold-start variance on Windows
            'break-on-initial-test-failure' = $true       # a red baseline makes every mutant verdict meaningless
        }
    }

    # ---------------- step 5: invoke per test project, sequentially ----------------
    # WHY sequential: CPU-heavy phases must never overlap  -  Stryker's Timeout verdicts
    # are load-sensitive; parallel runs manufacture false reds (CLAUDE.md).
    foreach ($run in $plannedRuns) {
        $outDir = Join-Path $strykerRoot $run.Key
        # WHY pre-create -O: Stryker validates the output dir exists and errors out
        # otherwise (verified)  -  it does not create it for you.
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null

        # config written into the WORKTREE copy of the test project dir  -  overwriting a
        # committed stryker-config.json here touches only the worktree, never the repo
        $cfgPath = Join-Path $run.TestProjDirAbs 'stryker-config.json'
        Write-JsonFileNoBom -Object $strykerConfig -Path $cfgPath

        $logBase = Join-Path $logsDir $run.Key
        $reportPath = Join-Path (Join-Path $outDir 'reports') 'mutation-report.json'
        # idempotency: a stale report from a previous run must never be read as this run's
        if (Test-Path -LiteralPath $reportPath) { Remove-Item -LiteralPath $reportPath -Force }

        $res = Invoke-OneStryker -Run $run -OutDir $outDir -LogBase $logBase `
            -Cores $cores -TimeoutMs $timeoutMs -Globs $run.Globs
        if ($res.TimedOut) {
            $null = Restore-StrykerBackup -Root $worktreeDir
            $entries.Add((New-TimeoutEntry -Project $run.TestProjPath `
                        -Prog (Read-ConsoleProgress -LogPath $res.OutLog) -Minutes $TimeoutMinutes))
            continue
        }

        $counts = Read-MutationCounts -ReportPath $reportPath
        $note = $null
        if ($run.UsedSpans -and ($null -eq $counts -or $counts.Total -eq 0)) {
            # WHY the fallback: the {start..end} span grammar is undocumented  -  pinning the
            # tool version protects today's behavior, and a 0-mutant result from span globs
            # means the spans missed (or the grammar drifted), NOT that the change is
            # mutant-free. Whole-file globs on the same files still produce a verdict.
            $note = 'span globs produced 0 mutants  -  fell back to whole-file globs'
            if (Test-Path -LiteralPath $reportPath) { Remove-Item -LiteralPath $reportPath -Force }
            $res = Invoke-OneStryker -Run $run -OutDir $outDir -LogBase "$logBase-fallback" `
                -Cores $cores -TimeoutMs $timeoutMs -Globs $run.WholeFileGlobs
            if ($res.TimedOut) {
                $null = Restore-StrykerBackup -Root $worktreeDir
                $entries.Add((New-TimeoutEntry -Project $run.TestProjPath `
                            -Prog (Read-ConsoleProgress -LogPath $res.OutLog) -Minutes $TimeoutMinutes -Extra $note))
                continue
            }
            $counts = Read-MutationCounts -ReportPath $reportPath
        }

        if ($null -eq $counts) {
            # No report at all: with break-on-initial-test-failure this usually means the
            # baseline test run was red. Recorded as an honest partial  -  never a silent pass.
            $entries.Add((New-ProjectEntry -Project $run.TestProjPath -Partial $true `
                        -Reason ("stryker exited {0} without a report (likely break-on-initial-test-failure or a startup error)  -  log: {1}" -f $res.ExitCode, $res.OutLog)))
            continue
        }

        # testedMutants = mutants that actually had tests executed against them;
        # NoCoverage/Ignored/CompileError never ran a test.
        $tested = $counts.Killed + $counts.Survived + $counts.Timeout
        $entries.Add((New-ProjectEntry -Project $run.TestProjPath -ReportPath $reportPath `
                    -Tested $tested -Total $counts.Total -Killed $counts.Killed -Survived $counts.Survived `
                    -NoCoverage $counts.NoCoverage -TimeoutCount $counts.Timeout -Reason $note))
    }

    # final sweep even on non-timeout paths: Restore() is not crash-safe, and a leftover
    # backup means the worktree's next build would run mutated code
    $null = Restore-StrykerBackup -Root $worktreeDir

    # ---------------- step 6 side note: StrykerJS for jest projects ----------------
    $jsSeen = @{}
    foreach ($prof in $profiles) {
        $framework = [string](Get-Prop $prof 'framework' '')
        if ($jsFrameworks -notcontains $framework) { continue }
        $pp = ([string](Get-Prop $prof 'projectPath' '')) -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($pp)) { continue }
        # resolve the project DIRECTORY: projectPath may be a dir, a package.json, or
        # an nx project file  -  StrykerJS must run from the package directory
        $ppTrim = $pp.TrimEnd('/')
        $projDirRel = $ppTrim
        $cand = Join-Path $worktreeDir ($ppTrim -replace '/', '\')
        if (-not (Test-Path -LiteralPath $cand -PathType Container)) {
            $li3 = $ppTrim.LastIndexOf('/')
            if ($li3 -ge 0) { $projDirRel = $ppTrim.Substring(0, $li3) } else { $projDirRel = '' }
        }
        $dedupe = $projDirRel.ToLowerInvariant()
        if ($jsSeen.ContainsKey($dedupe)) { continue }
        $jsSeen[$dedupe] = $true

        $prefix = ''
        if ($projDirRel -ne '') { $prefix = $projDirRel + '/' }
        $changed = @($changedJsAll | Where-Object {
                $prefix -eq '' -or ([string]$_).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($changed.Count -eq 0) { continue }   # jest project untouched by this branch

        if ($framework -ne 'jest') {
            $entries.Add((New-ProjectEntry -Project $pp -Skipped $true `
                        -Reason ("JS mutation lane is wired for jest only  -  {0} project not run" -f $framework)))
            continue
        }

        $projDirAbs = $worktreeDir
        if ($projDirRel -ne '') { $projDirAbs = Join-Path $worktreeDir ($projDirRel -replace '/', '\') }

        # WHY the devDependency gate: agentQ never adds packages to (or edits the
        # package.json of) a product repo, and a floating npx install would be exactly that.
        $hasCore = Test-HasDevDependency -PkgJsonPath (Join-Path $projDirAbs 'package.json') -Name '@stryker-mutator/core'
        if (-not $hasCore) {
            $hasCore = Test-HasDevDependency -PkgJsonPath (Join-Path $worktreeDir 'package.json') -Name '@stryker-mutator/core'
        }
        if (-not $hasCore) {
            $entries.Add((New-ProjectEntry -Project $pp -Skipped $true `
                        -Reason 'JS mutation skipped  -  @stryker-mutator/core is not a devDependency and agentQ never adds packages to a product repo'))
            continue
        }

        $relFiles = @()
        foreach ($c in $changed) {
            if ($prefix -eq '') { $relFiles += [string]$c } else { $relFiles += ([string]$c).Substring($prefix.Length) }
        }
        $mutateList = ($relFiles -join ',')

        $logKey = 'js-root'
        if ($projDirRel -ne '') { $logKey = 'js-' + ($projDirRel -replace '[^A-Za-z0-9._-]', '_') }
        $logBase = Join-Path $logsDir $logKey

        # idempotency: clear stale JS reports so a previous run's file is never re-read
        $jsReportCandidates = @('reports\mutation\mutation.json', 'reports\mutation\mutation-report.json')
        foreach ($candRel in $jsReportCandidates) {
            $p2 = Join-Path $projDirAbs $candRel
            if (Test-Path -LiteralPath $p2) { Remove-Item -LiteralPath $p2 -Force }
        }

        # --incremental: StrykerJS's own supported diff cache (unlike .NET's broken --since).
        # --reporters json,progress is added on top of the spec's command line because the
        # json report is the only machine-readable source for summary.json counts.
        # WHY cmd.exe: npx is a .cmd shim  -  cmd resolves it reliably under Start-Process.
        $jsArgLine = ('/d /c npx stryker run --mutate "{0}" --incremental --reporters json,progress' -f $mutateList)
        $res = Invoke-Native -FilePath 'cmd.exe' -Arguments $jsArgLine `
            -WorkingDirectory $projDirAbs -LogBase $logBase -TimeoutMs $timeoutMs
        if ($res.TimedOut) {
            $entries.Add((New-TimeoutEntry -Project $pp `
                        -Prog (Read-ConsoleProgress -LogPath $res.OutLog) -Minutes $TimeoutMinutes))
            continue
        }

        $jsReportPath = $null
        foreach ($candRel in $jsReportCandidates) {
            $p2 = Join-Path $projDirAbs $candRel
            if (Test-Path -LiteralPath $p2) { $jsReportPath = $p2; break }
        }
        $counts = $null
        if ($null -ne $jsReportPath) { $counts = Read-MutationCounts -ReportPath $jsReportPath }
        if ($null -eq $counts) {
            $entries.Add((New-ProjectEntry -Project $pp -Partial $true `
                        -Reason ("stryker (JS) exited {0} without a parseable json report  -  log: {1}" -f $res.ExitCode, $res.OutLog)))
            continue
        }
        $tested = $counts.Killed + $counts.Survived + $counts.Timeout
        $entries.Add((New-ProjectEntry -Project $pp -ReportPath $jsReportPath `
                    -Tested $tested -Total $counts.Total -Killed $counts.Killed -Survived $counts.Survived `
                    -NoCoverage $counts.NoCoverage -TimeoutCount $counts.Timeout))
    }

    # ---------------- write the artifact + the single summary line ----------------
    $summaryPath = Join-Path $strykerRoot 'summary.json'
    $summary = [ordered]@{ projects = @($entries.ToArray()) }
    Write-JsonFileNoBom -Object $summary -Path $summaryPath

    $nRan = 0; $nPartial = 0; $nSkipped = 0
    $sumKilled = 0; $sumSurvived = 0; $sumNoCov = 0; $sumTimeout = 0
    foreach ($e in $entries) {
        if ([bool]$e.skipped) { $nSkipped++; continue }
        $nRan++
        if ([bool]$e.partial) { $nPartial++ }
        if ($e.killed -is [int]) { $sumKilled += $e.killed }
        if ($e.survived -is [int]) { $sumSurvived += $e.survived }
        if ($e.noCoverage -is [int]) { $sumNoCov += $e.noCoverage }
        if ($e.timeout -is [int]) { $sumTimeout += $e.timeout }
    }
    Write-Output ("stryker-run: {0} run(s) ({1} partial), {2} skipped  -  killed {3}, survived {4}, noCoverage {5}, timeout {6}  -  summary: {7}" -f `
            $nRan, $nPartial, $nSkipped, $sumKilled, $sumSurvived, $sumNoCov, $sumTimeout, $summaryPath)
    exit 0
}
catch {
    $ErrorActionPreference = 'Continue'
    Write-Error ("stryker-run failed: {0}" -f $_.Exception.Message)
    exit 1
}
