<#
.SYNOPSIS
    merge-mutation-reports.ps1 -- union Stryker mechanical mutants and agentQ semantic
    (business-rule) mutants into ONE mutation-testing-elements JSON (schema v2).

.DESCRIPTION
    Inputs (under <workspaceDir> from run-manifest.json):
      stryker/summary.json  -- per-project pointers (reportPath) to each Stryker
                              mutation-report.json (schemaVersion 2: files{}, testFiles{})
      mutants.json          -- semantic mutants authored by qa-mutation-author and
                              executed by semantic-mutant-driver.ps1

    Output:
      mutation-report.json  -- schemaVersion "2", thresholds {high:80, low:60},
                              projectRoot = manifest.repoPath, files{} = the union.

    REMINDER FOR CONSUMERS (qa-analyst / qa-report-synthesizer): SUPPRESS mutants with
    status NoCoverage from mutation findings -- they are coverage gaps already reported
    by diff-coverage.json. One tier per changed line, no double counting. Report
    absolute survivors only, never a percentage (a scoped score compares to nothing).

    Exit 0 = the merge ran (findings live in the artifact); non-zero = the script failed.
    Idempotent: re-running overwrites mutation-report.json from the current inputs.
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
    # StrictMode-safe property/key read that works for both PSCustomObject
    # (ConvertFrom-Json output) and the hashtables this script builds -- under
    # Set-StrictMode Latest a plain $obj.MissingProp on a PSCustomObject throws.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $Default
}

function ConvertTo-ForwardSlash {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    return ($Path.Trim() -replace '\\', '/').TrimEnd('/')
}

function Test-Rooted {
    # IsPathRooted throws ArgumentException on illegal path chars in .NET Framework;
    # a malformed key should degrade to "treat as relative", not kill the merge.
    param([string]$Path)
    try { return [System.IO.Path]::IsPathRooted($Path) } catch { return $false }
}

function ConvertTo-RepoRelative {
    # Make a path repo-relative with forward slashes so it matches git paths --
    # diff-set.json / diff-coverage.json carry git-style paths and downstream
    # hunk-overlap checks only line up if the merged report keys use the same form.
    param([string]$Path, [string[]]$Prefixes)
    $p = ($Path -replace '\\', '/')
    foreach ($prefix in $Prefixes) {
        if ([string]::IsNullOrEmpty($prefix)) { continue }
        # OrdinalIgnoreCase: Windows paths drift in casing between tools.
        if ($p.Length -gt ($prefix.Length + 1) -and
            $p.StartsWith($prefix + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $p.Substring($prefix.Length + 1)
        }
    }
    return $p
}

function Get-StatusRank {
    # Used when the same mutant id for the same file arrives from two Stryker reports
    # (two test projects sharing the SUT source each mutate it). Union semantics: a
    # mutant is dead if ANY project's tests kill it, so the detected family outranks
    # Survived, which outranks the not-really-tested family.
    param([string]$Status)
    switch ($Status) {
        'Killed'       { return 6 }
        'Timeout'      { return 5 }  # Timeout counts as detected in Stryker's own scoring
        'Survived'     { return 4 }
        'NoCoverage'   { return 3 }
        'CompileError' { return 2 }
        'Ignored'      { return 1 }
        default        { return 0 }
    }
}

function Get-MutantStartLine {
    param($Mutant)
    $loc   = Get-Prop $Mutant 'location'
    $start = Get-Prop $loc 'start'
    return [int](Get-Prop $start 'line' 0)
}

# ---------------------------------------------------------------------------
# Load manifest, resolve paths
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Manifest)) { throw "Manifest not found: $Manifest" }
$manifestObj  = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $Manifest -Raw)

$workspaceDir = [string](Get-Prop $manifestObj 'workspaceDir')
$repoPath     = [string](Get-Prop $manifestObj 'repoPath')
$worktreeDir  = [string](Get-Prop $manifestObj 'worktreeDir')
if ([string]::IsNullOrWhiteSpace($workspaceDir)) { throw 'run-manifest.json has no workspaceDir' }
if ([string]::IsNullOrWhiteSpace($repoPath))     { throw 'run-manifest.json has no repoPath' }
if (-not (Test-Path -LiteralPath $workspaceDir)) { throw "workspaceDir does not exist: $workspaceDir" }

# Prefixes stripped from absolute paths to get repo-relative ones. Worktree FIRST:
# Stryker runs in the worktree (never the developer's tree), so its absolute paths
# point there, and the worktree mirrors the repo layout 1:1 -- worktree-relative IS
# repo-relative. repoPath is the fallback for anything recorded against the real repo.
$stripPrefixes = @(
    (ConvertTo-ForwardSlash $worktreeDir),
    (ConvertTo-ForwardSlash $repoPath)
) | Where-Object { -not [string]::IsNullOrEmpty($_) }

$strykerSummaryPath = Join-Path $workspaceDir 'stryker/summary.json'
$mutantsPath        = Join-Path $workspaceDir 'mutants.json'
$outPath            = Join-Path $workspaceDir 'mutation-report.json'

$haveStryker = Test-Path -LiteralPath $strykerSummaryPath
$haveMutants = Test-Path -LiteralPath $mutantsPath
if (-not $haveStryker -and -not $haveMutants) {
    # Neither tier produced anything -- that's an orchestration error (this script runs
    # after stryker-run.ps1 / semantic-mutant-driver.ps1), not a finding. Fail loudly
    # rather than write an empty report that could read as "0 survivors = all good".
    throw "Nothing to merge: neither $strykerSummaryPath nor $mutantsPath exists (run stryker-run.ps1 and/or semantic-mutant-driver.ps1 first)."
}

# ---------------------------------------------------------------------------
# Merge containers
# ---------------------------------------------------------------------------

# fileKey -> @{ language; source; hasSource; mutants = Dictionary[id -> mutant] }
# Keys compare OrdinalIgnoreCase: Windows tooling drifts on path casing between
# reports and merging case-insensitively prevents the same file appearing twice
# (first-seen casing wins in the output).
$mergedFiles = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
$mergedTests = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)

function Add-MutantToFile {
    # $Mutant may be $null to just ensure the file entry exists (a Stryker file entry
    # can legitimately carry zero mutants after scoping).
    param([string]$FileKey, $Mutant, [string]$Language, $Source, [bool]$HasSource)
    if (-not $mergedFiles.ContainsKey($FileKey)) {
        $holder = @{
            language  = $Language
            source    = $Source
            hasSource = $HasSource
            mutants   = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
        }
        $mergedFiles[$FileKey] = $holder
    }
    else {
        $holder = $mergedFiles[$FileKey]
        # Prefer real source text over none if a later report supplies one.
        if (-not $holder.hasSource -and $HasSource) { $holder.source = $Source; $holder.hasSource = $true }
    }
    if ($null -eq $Mutant) { return }
    $id = [string](Get-Prop $Mutant 'id')
    if ($holder.mutants.ContainsKey($id)) {
        # Duplicate id for the same file across reports: keep the higher-ranked status
        # (see Get-StatusRank -- killed by any project means killed).
        $existing = $holder.mutants[$id]
        $newRank = Get-StatusRank ([string](Get-Prop $Mutant   'status' ''))
        $oldRank = Get-StatusRank ([string](Get-Prop $existing 'status' ''))
        if ($newRank -gt $oldRank) { $holder.mutants[$id] = $Mutant }
    }
    else {
        $holder.mutants.Add($id, $Mutant)
    }
}

# ---------------------------------------------------------------------------
# 1) Load all Stryker reports and union files{} / testFiles{}
# ---------------------------------------------------------------------------

$strykerReportsLoaded = 0
if ($haveStryker) {
    $summary = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $strykerSummaryPath -Raw)

    # Tolerant summary parsing: {projects:[{reportPath,...}]} is the expected shape; a
    # bare array and a {reports:[...]} list are accepted too so a stryker-run.ps1
    # refactor can't silently produce a report with zero mechanical mutants.
    $entries = @()
    if ($summary -is [System.Array]) { $entries = $summary }
    else {
        $projects = Get-Prop $summary 'projects'
        if ($null -ne $projects) { $entries = @($projects) }
        else {
            $reports = Get-Prop $summary 'reports'
            if ($null -ne $reports) { $entries = @($reports) }
        }
    }

    $summaryDir  = Split-Path -Parent $strykerSummaryPath
    $reportPaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }
        if ($entry -is [string]) { $rp = $entry } else { $rp = [string](Get-Prop $entry 'reportPath' '') }
        if ([string]::IsNullOrWhiteSpace($rp)) {
            Write-Warning 'stryker/summary.json entry without a reportPath was skipped.'
            continue
        }
        # Relative reportPaths resolve against the summary's own directory -- the
        # summary is the only artifact that knows where stryker-run.ps1 put them.
        if (-not (Test-Rooted $rp)) { $rp = Join-Path $summaryDir $rp }
        $reportPaths.Add($rp)
    }

    foreach ($rp in $reportPaths) {
        if (-not (Test-Path -LiteralPath $rp)) {
            Write-Warning "Stryker report missing, skipped: $rp"
            continue
        }
        $report = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $rp -Raw)

        $sv = [string](Get-Prop $report 'schemaVersion' '')
        if ($sv -notlike '2*') {
            Write-Warning "Stryker report $rp has schemaVersion '$sv' (expected 2.x) -- merging anyway."
        }

        # Stryker emits file keys relative to the report's own projectRoot (absolute
        # keys also occur); resolve to absolute first, then strip down to repo-relative.
        $reportRoot = ConvertTo-ForwardSlash ([string](Get-Prop $report 'projectRoot' ''))

        $filesObj = Get-Prop $report 'files'
        if ($null -ne $filesObj) {
            foreach ($fileProp in $filesObj.PSObject.Properties) {
                $rawKey  = $fileProp.Name
                $keyNorm = $rawKey -replace '\\', '/'
                if (-not (Test-Rooted $rawKey) -and -not [string]::IsNullOrEmpty($reportRoot)) {
                    $keyNorm = $reportRoot + '/' + $keyNorm.TrimStart('/')
                }
                $fileKey = ConvertTo-RepoRelative -Path $keyNorm -Prefixes $stripPrefixes

                $fileVal  = $fileProp.Value
                $language = [string](Get-Prop $fileVal 'language' 'cs')
                $srcProp  = $fileVal.PSObject.Properties['source']
                $hasSource = ($null -ne $srcProp)
                $source = $null
                if ($hasSource) { $source = $srcProp.Value }

                # Ensure the entry exists even for zero mutants, then add each mutant.
                Add-MutantToFile -FileKey $fileKey -Mutant $null -Language $language -Source $source -HasSource $hasSource
                foreach ($m in @(Get-Prop $fileVal 'mutants' @())) {
                    if ($null -eq $m) { continue }
                    # Stryker ids pass through untouched (integers-as-strings): renaming
                    # would break traceability back to the per-project reports, and the
                    # "agentq-" namespace on semantic ids already guarantees the two
                    # id spaces can never collide.
                    Add-MutantToFile -FileKey $fileKey -Mutant $m -Language $language -Source $source -HasSource $hasSource
                }
            }
        }

        $testFilesObj = Get-Prop $report 'testFiles'
        if ($null -ne $testFilesObj) {
            foreach ($tfProp in $testFilesObj.PSObject.Properties) {
                $rawKey  = $tfProp.Name
                $keyNorm = $rawKey -replace '\\', '/'
                if (-not (Test-Rooted $rawKey) -and -not [string]::IsNullOrEmpty($reportRoot)) {
                    $keyNorm = $reportRoot + '/' + $keyNorm.TrimStart('/')
                }
                $tfKey = ConvertTo-RepoRelative -Path $keyNorm -Prefixes $stripPrefixes

                $tfVal = $tfProp.Value
                if (-not $mergedTests.ContainsKey($tfKey)) {
                    $tfHolder = @{
                        source    = $null
                        hasSource = $false
                        tests     = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
                    }
                    $mergedTests[$tfKey] = $tfHolder
                }
                else { $tfHolder = $mergedTests[$tfKey] }

                $tfSrcProp = $tfVal.PSObject.Properties['source']
                if (-not $tfHolder.hasSource -and $null -ne $tfSrcProp) {
                    $tfHolder.source = $tfSrcProp.Value
                    $tfHolder.hasSource = $true
                }
                foreach ($t in @(Get-Prop $tfVal 'tests' @())) {
                    if ($null -eq $t) { continue }
                    $tid = [string](Get-Prop $t 'id')
                    # Stryker.NET test ids are GUIDs -- a cross-report collision is
                    # negligible; first occurrence wins on the theoretical duplicate.
                    if (-not $tfHolder.tests.ContainsKey($tid)) { $tfHolder.tests.Add($tid, $t) }
                }
            }
        }

        $strykerReportsLoaded++
    }
}

if ($strykerReportsLoaded -eq 0 -and -not $haveMutants) {
    throw "stryker/summary.json listed no readable reports and $mutantsPath does not exist -- nothing to merge."
}

# Test-name -> test-id lookup over the MERGED testFiles, so a semantic mutant killed
# by a test that any Stryker project knows about links to the same id viewers use.
$testNameToId = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($tfHolder in $mergedTests.Values) {
    foreach ($t in $tfHolder.tests.Values) {
        $tname = [string](Get-Prop $t 'name' '')
        $tid   = [string](Get-Prop $t 'id'   '')
        if ($tname -ne '' -and $tid -ne '' -and -not $testNameToId.ContainsKey($tname)) {
            $testNameToId.Add($tname, $tid)
        }
    }
}

# ---------------------------------------------------------------------------
# 2) Convert semantic mutants into the same per-mutant shape and insert
# ---------------------------------------------------------------------------

if ($haveMutants) {
    $mutantsDoc = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $mutantsPath -Raw)
    foreach ($sm in @(Get-Prop $mutantsDoc 'mutants' @())) {
        if ($null -eq $sm) { continue }
        $smId      = [string](Get-Prop $sm 'id' '')
        $smFile    = [string](Get-Prop $sm 'file' '')
        $smLineRaw = Get-Prop $sm 'line'
        if ($smId -eq '' -or $smFile -eq '' -or $null -eq $smLineRaw) {
            Write-Warning "mutants.json entry missing id/file/line was skipped (id='$smId', file='$smFile')."
            continue
        }

        # 1-BASED line as recorded by qa-mutation-author -- this aligns with git diff
        # hunk numbering (verified), so downstream "is this mutant inside a changed
        # hunk" checks need no off-by-one correction.
        $line    = [int]$smLineRaw
        $fileKey = ConvertTo-RepoRelative -Path $smFile -Prefixes $stripPrefixes

        # Status mapping from the semantic driver's vocabulary to the elements schema:
        #   Survived -> Survived, Killed -> Killed,
        #   BaselineBroken/Ignored -> Ignored + statusReason (the schema has no
        #   "baseline broke" status; Ignored-with-reason keeps it out of the score
        #   without letting it masquerade as tested).
        $rawStatus    = [string](Get-Prop $sm 'status' '')
        $driverReason = [string](Get-Prop $sm 'statusReason' '')
        $status  = 'Ignored'
        $reasons = New-Object 'System.Collections.Generic.List[string]'
        switch ($rawStatus) {
            'Survived' { $status = 'Survived' }
            'Killed'   { $status = 'Killed' }
            'TimedOut' {
                # Same convention as Stryker's own native Timeout status (Get-StatusRank
                # above ranks it as detected, between Killed and Survived): the driver's
                # anti-hang valve killed a wedged test process, so this is neither a
                # clean kill (no failing test to name) nor a clean survive (we never
                # got a green result) -- "detected via hang" is the honest middle ground.
                $status = 'Timeout'
                if ($driverReason -ne '') { $reasons.Add($driverReason) }
                else { $reasons.Add('semantic-mutant-driver anti-hang valve tripped') }
            }
            'BaselineBroken' {
                $status = 'Ignored'
                if ($driverReason -ne '') { $reasons.Add("BaselineBroken: $driverReason") }
                else { $reasons.Add('BaselineBroken: baseline test run failed before this mutant could be evaluated') }
            }
            'Ignored' {
                $status = 'Ignored'
                if ($driverReason -ne '') { $reasons.Add($driverReason) }
                else { $reasons.Add('Ignored by semantic-mutant-driver') }
            }
            default {
                # No/unknown status must read as "not evaluated", never as survived or
                # killed -- honesty over completeness.
                $status = 'Ignored'
                if ($rawStatus -eq '') { $reasons.Add('no execution status recorded by semantic-mutant-driver -- mutant not evaluated') }
                else { $reasons.Add("unrecognized semantic-driver status '$rawStatus'") }
            }
        }

        # killedBy: the driver records raw test names (vstest FQNs). Resolve each
        # against the merged testFiles map so viewers can cross-link; names with no
        # match stay human-readable in statusReason -- inventing ids would corrupt
        # viewers' cross-references.
        $killedByIds = New-Object 'System.Collections.Generic.List[string]'
        $rawKilled = @(Get-Prop $sm 'killedBy' @()) | Where-Object { $null -ne $_ -and [string]$_ -ne '' }
        if (@($rawKilled).Count -gt 0) {
            $unresolved = New-Object 'System.Collections.Generic.List[string]'
            foreach ($name in @($rawKilled)) {
                $n = [string]$name
                if ($testNameToId.ContainsKey($n)) { $killedByIds.Add($testNameToId[$n]) }
                else { $unresolved.Add($n) }
            }
            if ($unresolved.Count -gt 0) {
                $reasons.Add('killedBy (raw test names, no match in merged testFiles): ' + ($unresolved -join ', '))
            }
        }

        $mutantOut = [ordered]@{
            # "agentq-" namespace so a semantic id can never collide with Stryker's
            # plain integer ids in the shared files{} map.
            id          = 'agentq-' + $smId
            mutatorName = [string](Get-Prop $sm 'mutatorName' 'BusinessRule/Unknown')
            description = [string](Get-Prop $sm 'description' '')
            replacement = [string](Get-Prop $sm 'replacement' '')
            location    = [ordered]@{
                # Whole-line span (columns 1..1000, the contract's "1e3"): the
                # authoring agent records only the line, and line-level precision is
                # all the diff-hunk overlap math needs.
                start = [ordered]@{ line = $line; column = 1 }
                end   = [ordered]@{ line = $line; column = 1000 }
            }
            status      = $status
        }
        if ($reasons.Count -gt 0)     { $mutantOut['statusReason'] = ($reasons -join ' | ') }
        if ($killedByIds.Count -gt 0) { $mutantOut['killedBy']     = @($killedByIds) }

        # New file entries get language "cs" and NO source: the worktree may already
        # be reset when the merge runs, and the elements schema tolerates a missing
        # source for tooling use. Viewers that want code panes (the official HTML
        # report) may add source later from `git show <baseSha>:<path>`.
        Add-MutantToFile -FileKey $fileKey -Mutant $mutantOut -Language 'cs' -Source $null -HasSource $false
    }
}

# ---------------------------------------------------------------------------
# 3) Compose and write mutation-report.json
# ---------------------------------------------------------------------------

# Ordinal-sorted keys and line/id-sorted mutants: deterministic output is part of the
# tool's credibility contract (same branch -> byte-identical artifact -> same verdict).
$fileKeys = @($mergedFiles.Keys)
[Array]::Sort($fileKeys, [System.StringComparer]::Ordinal)

$filesOut     = [ordered]@{}
$statusCounts = @{ Killed = 0; Survived = 0; Timeout = 0; NoCoverage = 0; Ignored = 0; CompileError = 0; Other = 0 }
$mechCount = 0
$semCount  = 0
foreach ($key in $fileKeys) {
    $holder = $mergedFiles[$key]
    $entry  = [ordered]@{ language = $holder.language }
    if ($holder.hasSource) { $entry['source'] = $holder.source }
    $sorted = @($holder.mutants.Values |
        Sort-Object -Property @{ Expression = { Get-MutantStartLine $_ } }, @{ Expression = { [string](Get-Prop $_ 'id') } })
    $entry['mutants'] = $sorted
    $filesOut[$key] = $entry

    foreach ($m in $sorted) {
        $s = [string](Get-Prop $m 'status' '')
        if ($statusCounts.ContainsKey($s)) { $statusCounts[$s]++ } else { $statusCounts['Other']++ }
        if (([string](Get-Prop $m 'id')).StartsWith('agentq-')) { $semCount++ } else { $mechCount++ }
    }
}

$reportOut = [ordered]@{
    schemaVersion = '2'
    thresholds    = [ordered]@{ high = 80; low = 60 }
    projectRoot   = $repoPath
    files         = $filesOut
}

if ($mergedTests.Count -gt 0) {
    $testKeys = @($mergedTests.Keys)
    [Array]::Sort($testKeys, [System.StringComparer]::Ordinal)
    $testFilesOut = [ordered]@{}
    foreach ($key in $testKeys) {
        $tfHolder = $mergedTests[$key]
        $tfEntry  = [ordered]@{}
        if ($tfHolder.hasSource) { $tfEntry['source'] = $tfHolder.source }
        $tfEntry['tests'] = @($tfHolder.tests.Values |
            Sort-Object -Property @{ Expression = { [string](Get-Prop $_ 'name') } }, @{ Expression = { [string](Get-Prop $_ 'id') } })
        $testFilesOut[$key] = $tfEntry
    }
    $reportOut['testFiles'] = $testFilesOut
}

$json = ConvertTo-Json -InputObject $reportOut -Depth 12
# BOM-less UTF-8 by hand: CONTRACTS.md mandates "UTF-8, no BOM", and Windows
# PowerShell 5.1's Out-File -Encoding utf8 always writes a BOM -- WriteAllText with
# UTF8Encoding(false) is the only 5.1-native way to honor the contract.
[System.IO.File]::WriteAllText($outPath, $json, (New-Object System.Text.UTF8Encoding($false)))

# Exactly one final summary line to stdout. NoCoverage reminder repeated here because
# this line is what lands in orchestrator logs.
$total = $mechCount + $semCount
Write-Output ("merge-mutation-reports: {0} mutants ({1} mechanical + {2} semantic) across {3} files -> {4} | Killed={5} Survived={6} Timeout={7} NoCoverage={8} Ignored={9} CompileError={10} (consumers: suppress NoCoverage from mutation findings -- coverage gaps, one tier per changed line)" -f `
    $total, $mechCount, $semCount, $filesOut.Count, $outPath,
    $statusCounts['Killed'], $statusCounts['Survived'], $statusCounts['Timeout'],
    $statusCounts['NoCoverage'], $statusCounts['Ignored'], $statusCounts['CompileError'])
exit 0
