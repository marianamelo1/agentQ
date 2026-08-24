#Requires -Version 5.1
<#
impact-index.ps1  -  agentQ Phase 1b / standalone /qa-impact: static blast-radius index.

Read-only, deterministic: extracts seeds from a branch diff (or takes them verbatim via
-Targets) and scans every registered repo (productRepos UNION testRepos) for textual
references. Never builds, boots, executes, or mutates anything -- a stricter contract
than /qa-review itself. Writes workspace/<repo>/<branch>/impact-index.json per
scripts/CONTRACTS.md.

Modes:
  -Manifest <run-manifest.json> -ConfigPath <qa-agent-config.jsonc>                 branch mode
  -Manifest <run-manifest.json> -ConfigPath <qa-agent-config.jsonc> -Targets "a,b"  target mode

Branch mode needs diff-set.json to already exist in the workspace (worktree.ps1 -DiffSet).
Target mode takes the given terms verbatim as seeds -- no diff needed, so it works before
any code exists.

Contract: exit 0 = the script ran (a diff with nothing indexable extracting 0 seeds is an
honest finding, not a failure); non-zero = the script itself broke. One summary line to
stdout.

WHY textual/regex extraction, not a real per-language parser: agentQ's product repos span
C#, TypeScript, and Ocelot JSON config across four codebases with no shared AST tooling
this script could realistically drive from PowerShell. This is a best-effort static scan,
by design -- CONTRACTS.md and the qa-impact skill both document every hit as a *candidate*,
never proof, and the report's closing line is always "no signal != not affected".
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Manifest,
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [string]$Targets = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# WHY: git/tool output on this host can be non-ASCII (route paths, migration names in
# other locales); consistent with every other script in this repo.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# ---------------------------------------------------------------------------------------
# Helpers (same conventions as worktree.ps1 / run-tests.ps1 / risk-score.ps1)
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

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Write-JsonFileNoBom {
    # WHY .NET WriteAllText, not Out-File: CONTRACTS.md requires UTF-8 without BOM: PS 5.1's
    # `Out-File -Encoding utf8` always emits one, which breaks non-PowerShell consumers.
    param($Object, [string]$Path)
    $json = $Object | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ProductAndTestRepos {
    # Minimal JSONC -> JSON: strips a '//' line comment only when it starts outside a
    # quoted string. Same pragmatic approach as worktree.ps1's Get-ProductReposFromConfig
    # (kept as an independent copy here, matching this codebase's convention of
    # self-contained scripts rather than a shared imported module).
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Config not found: $Path" }
    $stripped = foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $inString = $false
        $cut = -1
        for ($i = 0; $i -lt ($line.Length - 1); $i++) {
            $c = $line[$i]
            if ($c -eq '"' -and ($i -eq 0 -or $line[$i - 1] -ne '\')) { $inString = -not $inString }
            elseif ((-not $inString) -and $c -eq '/' -and $line[$i + 1] -eq '/') { $cut = $i; break }
        }
        if ($cut -ge 0) { $line.Substring(0, $cut) } else { $line }
    }
    $cfg = ($stripped -join "`n") | ConvertFrom-Json
    $product = [ordered]@{}
    if ($cfg.PSObject.Properties.Name -contains 'productRepos') {
        foreach ($p in $cfg.productRepos.PSObject.Properties) { $product[$p.Name] = $p.Value }
    }
    $testRepos = [ordered]@{}
    if ($cfg.PSObject.Properties.Name -contains 'testRepos') {
        foreach ($p in $cfg.testRepos.PSObject.Properties) { $testRepos[$p.Name] = $p.Value }
    }
    return [pscustomobject]@{ Product = $product; TestRepos = $testRepos }
}

function Get-DroppedReason {
    # Generic/low-signal identifiers: a match on these is noise, not impact evidence.
    # CONTRACTS.md's own example ("a match on Name is noise, not impact") is exactly this.
    param([string]$Value)
    $bare = $Value -replace '^[\w.]*\.', ''  # "Table.Column" -> "Column" for the genericity check
    if ($bare.Length -le 3) { return 'too short to match on reliably' }
    $generic = @(
        'Name', 'Id', 'Value', 'Data', 'Type', 'Status', 'Item', 'Items', 'List', 'Info',
        'Result', 'Response', 'Request', 'Model', 'Base', 'Common', 'Utils', 'Helper',
        'Index', 'Key', 'Code', 'Text', 'Date', 'Number', 'Count', 'Total', 'Params'
    )
    if ($generic -contains $bare) { return 'low-signal — too generic to match on' }
    return $null
}

# ---------------------------------------------------------------------------------------
# Seed extraction (branch mode)
# ---------------------------------------------------------------------------------------

function Get-SeedsFromFile {
    # Extracts candidate seeds from the CHANGED-LINE ranges of one file, given its current
    # (post-change) content and the diff-set hunk ranges for it. WHY re-read the file
    # instead of trusting diff-set.json: that artifact stores hunk line RANGES only, by
    # design (CONTRACTS.md) -- never line text -- so seed extraction needs real source.
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$RelPath,
        # WHY AllowEmptyCollection: a diff-set.json entry can legitimately have zero hunks
        # (e.g. a rename with no content change) -- that must not be a binding error.
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Hunks
    )
    $seeds = New-Object System.Collections.Generic.List[object]
    $full = Join-Path $RepoPath $RelPath
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $seeds }  # deleted file

    # --- Ocelot route config: the file itself IS the API surface (CLAUDE.md) -- every
    # route in it is seed-worthy, not just ones inside a reported hunk range. ---
    if ($RelPath -match '\.ocelot\.json$') {
        try {
            $ocelot = Get-Content -LiteralPath $full -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($route in @(Get-Prop $ocelot 'Routes' @())) {
                $upstream = [string](Get-Prop $route 'UpstreamPathTemplate' '')
                if (-not [string]::IsNullOrWhiteSpace($upstream)) {
                    $seeds.Add([ordered]@{ kind = 'endpoint'; value = $upstream; from = "$RelPath (Ocelot route config)" })
                }
            }
        } catch { }
        return $seeds
    }

    $lines = $null
    try { $lines = @(Get-Content -LiteralPath $full -Encoding UTF8) } catch { return $seeds }
    if ($null -eq $lines -or $lines.Count -eq 0) { return $seeds }

    foreach ($hunk in $Hunks) {
        $startLine = [int](Get-Prop $hunk 'newStart' 1)
        $count     = [int](Get-Prop $hunk 'newCount' 0)
        if ($count -le 0) { continue }  # pure deletion -- nothing new to extract a seed from
        # Pad 2 lines each side: an attribute/decorator commonly sits just above the line a
        # hunk reports as changed (e.g. [HttpGet] above the method signature it decorates).
        $from = [math]::Max(1, $startLine - 2)
        $to   = [math]::Min($lines.Count, $startLine + $count - 1 + 2)
        for ($ln = $from; $ln -le $to; $ln++) {
            $text = $lines[$ln - 1]

            # Endpoints -- C# attribute routing
            if ($text -match '\[Http(Get|Post|Put|Delete|Patch)\(\s*"([^"]+)"\s*\)\]') {
                $seeds.Add([ordered]@{ kind = 'endpoint'; value = "$($Matches[1].ToUpperInvariant()) $($Matches[2])"; from = "$RelPath`:$ln" })
            }
            if ($text -match '\[Route\(\s*"([^"]+)"\s*\)\]') {
                $seeds.Add([ordered]@{ kind = 'endpoint'; value = $Matches[1]; from = "$RelPath`:$ln" })
            }
            # Endpoints -- ASP.NET minimal API
            if ($text -match '\.Map(Get|Post|Put|Delete|Patch)\s*\(\s*"([^"]+)"') {
                $seeds.Add([ordered]@{ kind = 'endpoint'; value = "$($Matches[1].ToUpperInvariant()) $($Matches[2])"; from = "$RelPath`:$ln" })
            }
            # Endpoints -- Express/Nest-style JS routers
            if ($text -match '\b(?:router|app)\.(get|post|put|delete|patch)\s*\(\s*[''"]([^''"]+)[''"]') {
                $seeds.Add([ordered]@{ kind = 'endpoint'; value = "$($Matches[1].ToUpperInvariant()) $($Matches[2])"; from = "$RelPath`:$ln" })
            }

            # Symbols -- a type or top-level function/const declaration touched by this diff
            if ($text -match '(?:^|[\s;{}])(?:public|private|internal|protected)?\s*(?:static\s+)?(?:partial\s+)?(?:class|interface|record|struct|enum)\s+(\w+)') {
                $seeds.Add([ordered]@{ kind = 'symbol'; value = $Matches[1]; from = "$RelPath`:$ln" })
            }
            if ($text -match '^\s*export\s+(?:default\s+)?(?:async\s+)?(?:function|class)\s+(\w+)') {
                $seeds.Add([ordered]@{ kind = 'symbol'; value = $Matches[1]; from = "$RelPath`:$ln" })
            }
            if ($text -match '^\s*export\s+(?:const|function)\s+(\w+)') {
                $seeds.Add([ordered]@{ kind = 'symbol'; value = $Matches[1]; from = "$RelPath`:$ln" })
            }
        }
    }

    # Tables/columns -- EF Core migration files (best-effort: matches the Fluent-API shape
    # `.AddColumn<T>(name: "X", table: "Y", ...)` / `.CreateTable(name: "Y", ...)`).
    if ($RelPath -match '(?i)[\\/]Migrations?[\\/]' -and $RelPath -match '(?i)\.cs$') {
        $joined = $lines -join "`n"
        $seenTables = New-Object System.Collections.Generic.HashSet[string]
        foreach ($m in [regex]::Matches($joined, '\bname:\s*"([^"]+)"[^)]*?\btable:\s*"([^"]+)"')) {
            $seeds.Add([ordered]@{ kind = 'column'; value = "$($m.Groups[2].Value).$($m.Groups[1].Value)"; from = "$RelPath (migration)" })
            $null = $seenTables.Add($m.Groups[2].Value)
        }
        foreach ($m in [regex]::Matches($joined, '\btable:\s*"([^"]+)"')) {
            if ($seenTables.Add($m.Groups[1].Value)) {
                $seeds.Add([ordered]@{ kind = 'table'; value = $m.Groups[1].Value; from = "$RelPath (migration)" })
            }
        }
    }

    # DTOs -- file naming convention; seed = the type name from the filename
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($RelPath)
    if ($baseName -match '(Dto|Request|Response|ViewModel)$' -or $RelPath -match '(?i)\.dto\.ts$') {
        $seeds.Add([ordered]@{ kind = 'dto'; value = $baseName; from = $RelPath })
    }

    return $seeds
}

# ---------------------------------------------------------------------------------------
# Repo scanning
# ---------------------------------------------------------------------------------------

$SourceFileRx = '(?i)\.(cs|ts|tsx|js|jsx|razor|cshtml|json)$'
$ExcludeDirRx = '(?i)[\\/](\.git|bin|obj|node_modules|dist|coverage)([\\/]|$)'

function Get-MatchKindForSeedKind {
    param([string]$SeedKind)
    switch ($SeedKind) {
        'endpoint' { return 'endpoint-reference' }
        'table'    { return 'table-reference' }
        'column'   { return 'table-reference' }
        'dto'      { return 'dto-reference' }
        default    { return 'symbol-reference' }
    }
}

function Get-SeedSearchValue {
    # An endpoint seed's `value` is "VERB /path" for human-readable reporting (matches
    # CONTRACTS.md's example), but real consumer code almost never writes the verb as a
    # literal string next to the URL -- `fetch('api/entries')`, `axios.post(url, data)` --
    # so matching on the combined string produces false negatives (verified live: a
    # deliberately planted `fetch('api/entries')` reference was missed entirely). Strip the
    # verb (and a leading slash, so "api/entries" also matches "/api/entries") for the
    # string actually searched for; `value` itself is untouched for display/reporting.
    param($Seed)
    $v = [string]$Seed.value
    if ([string]$Seed.kind -eq 'endpoint' -and $v -match '^(?:GET|POST|PUT|DELETE|PATCH)\s+(.+)$') {
        $v = $Matches[1]
    }
    return $v.TrimStart('/')
}

function Invoke-RepoScan {
    # WHY one combined regex via Select-String, not a per-seed-per-line loop: Select-String
    # runs a compiled .NET regex per file in one pass; a manual triple loop (files x lines x
    # seeds) over a 426-project repo would blow well past the "5-15s" budget this phase is
    # designed to fit inside.
    param(
        [Parameter(Mandatory = $true)][string]$Slug,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$IndexOnly,
        # WHY AllowEmptyCollection everywhere here: PowerShell's default parameter binding
        # rejects an EMPTY collection passed to a Mandatory collection-typed parameter as if
        # it were missing (verified live) -- these lists start empty (0 seeds extracted, 0
        # matches found so far) as a normal, honest state, not a caller error.
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Seeds,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$MatchList,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$ScannedList,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$SkippedList
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        $SkippedList.Add([ordered]@{ repoSlug = $Slug; reason = 'path not found on this machine' })
        return
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match $SourceFileRx -and $_.FullName -notmatch $ExcludeDirRx })

    if ($Seeds.Count -gt 0) {
        $seedByLowerValue = @{}
        foreach ($sd in $Seeds) {
            $lv = (Get-SeedSearchValue $sd).ToLowerInvariant()
            if (-not $seedByLowerValue.ContainsKey($lv)) { $seedByLowerValue[$lv] = $sd }
        }
        $alternatives = @($Seeds | ForEach-Object { [regex]::Escape((Get-SeedSearchValue $_)) } | Select-Object -Unique)
        $combinedPattern = $alternatives -join '|'

        foreach ($file in $files) {
            $lineHits = $null
            try { $lineHits = Select-String -LiteralPath $file.FullName -Pattern $combinedPattern -AllMatches -Encoding UTF8 -ErrorAction SilentlyContinue }
            catch { continue }
            if ($null -eq $lineHits) { continue }
            $relFile = ($file.FullName.Substring($Path.Length).TrimStart('\', '/')) -replace '\\', '/'
            foreach ($lh in @($lineHits)) {
                $seenOnLine = @{}
                foreach ($m in $lh.Matches) {
                    $mv = $m.Value.ToLowerInvariant()
                    if ($seenOnLine.ContainsKey($mv)) { continue }
                    $seenOnLine[$mv] = $true
                    $sd = $seedByLowerValue[$mv]
                    if ($null -eq $sd) { continue }
                    $MatchList.Add([ordered]@{
                        repoSlug  = $Slug
                        indexOnly = $IndexOnly
                        file      = $relFile
                        line      = $lh.LineNumber
                        seed      = [string]$sd.value
                        matchKind = (Get-MatchKindForSeedKind ([string]$sd.kind))
                        context   = $lh.Line.Trim()
                    })
                }
            }
        }
    }
    $sw.Stop()
    $ScannedList.Add([ordered]@{ repoSlug = $Slug; files = $files.Count; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 2) })
}

# ---------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------

try {
    if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { throw "Manifest not found: $Manifest" }
    $man = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    $workspaceDir = [string](Get-Prop $man 'workspaceDir' '')
    $repoPath     = [string](Get-Prop $man 'repoPath' '')
    if ([string]::IsNullOrWhiteSpace($workspaceDir) -or -not (Test-Path -LiteralPath $workspaceDir)) {
        throw "impact-index: workspaceDir missing or not found in manifest: '$workspaceDir'"
    }

    $repos = Get-ProductAndTestRepos -Path $ConfigPath

    $mode = 'branch'
    $rawSeeds = New-Object System.Collections.Generic.List[object]

    if (-not [string]::IsNullOrWhiteSpace($Targets)) {
        $mode = 'target'
        foreach ($t in ($Targets -split ',')) {
            $tt = $t.Trim()
            if ([string]::IsNullOrWhiteSpace($tt)) { continue }
            $kind = 'symbol'
            if ($tt -match '^(GET|POST|PUT|DELETE|PATCH)\s+/') { $kind = 'endpoint' }
            elseif ($tt -match '^/') { $kind = 'endpoint' }
            elseif ($tt -match '^[\w]+\.[\w]+$') { $kind = 'column' }
            elseif ($tt -match '[\\/]' -or $tt -match '\.\w+$') { $kind = 'file' }
            $rawSeeds.Add([ordered]@{ kind = $kind; value = $tt; from = '--target (given verbatim)' })
        }
    } else {
        $diffSet = Read-JsonFile (Join-Path $workspaceDir 'diff-set.json')
        if ($null -eq $diffSet) {
            throw 'impact-index: diff-set.json not found in workspace -- run worktree.ps1 -DiffSet first (branch mode needs the diff)'
        }
        foreach ($f in @(Get-Prop $diffSet 'files' @())) {
            $relPath = [string](Get-Prop $f 'path' '')
            if ([string]::IsNullOrWhiteSpace($relPath)) { continue }
            $hunks = @(Get-Prop $f 'hunks' @())
            foreach ($s in (Get-SeedsFromFile -RepoPath $repoPath -RelPath $relPath -Hunks $hunks)) { $rawSeeds.Add($s) }
        }
    }

    # Dedupe by (kind, value) case-insensitively; drop low-signal identifiers into
    # droppedSeeds instead of scanning every repo on noise.
    $seenSeeds = @{}
    $finalSeeds = New-Object System.Collections.Generic.List[object]
    $droppedSeeds = New-Object System.Collections.Generic.List[object]
    foreach ($s in $rawSeeds) {
        $k = "$($s.kind)::$($s.value)".ToLowerInvariant()
        if ($seenSeeds.ContainsKey($k)) { continue }
        $seenSeeds[$k] = $true
        $reason = Get-DroppedReason -Value ([string]$s.value)
        if ($null -ne $reason) {
            $droppedSeeds.Add([ordered]@{ value = $s.value; reason = $reason })
            continue
        }
        $finalSeeds.Add($s)
    }

    $matches  = New-Object System.Collections.Generic.List[object]
    $scanned  = New-Object System.Collections.Generic.List[object]
    $skipped  = New-Object System.Collections.Generic.List[object]

    foreach ($slug in $repos.Product.Keys) {
        Invoke-RepoScan -Slug $slug -Path $repos.Product[$slug] -IndexOnly $false -Seeds $finalSeeds `
            -MatchList $matches -ScannedList $scanned -SkippedList $skipped
    }
    foreach ($slug in $repos.TestRepos.Keys) {
        Invoke-RepoScan -Slug $slug -Path $repos.TestRepos[$slug] -IndexOnly $true -Seeds $finalSeeds `
            -MatchList $matches -ScannedList $scanned -SkippedList $skipped
    }

    # reverseCoverage: filled from a PRIOR /qa-review run's risk-score.json topTests if one
    # exists in this same workspace -- this script never generates coverage itself.
    $reverseCoverage = [ordered]@{ available = $false; reason = 'no coverage artifact for this branch'; tests = @() }
    $riskScoreObj = Read-JsonFile (Join-Path $workspaceDir 'risk-score.json')
    if ($null -ne $riskScoreObj) {
        $topTests = @(Get-Prop $riskScoreObj 'topTests' @())
        if ($topTests.Count -gt 0) {
            $testsOut = New-Object System.Collections.Generic.List[object]
            foreach ($tt in $topTests) {
                $reason = [string](Get-Prop $tt 'reason' '')
                $covers = 0
                if ($reason -match '(\d+)\s+changed\s+lines?') { $covers = [int]$Matches[1] }
                $testsOut.Add([ordered]@{ fqn = [string](Get-Prop $tt 'fqn' ''); coversChangedLines = $covers })
            }
            $reverseCoverage = [ordered]@{ available = $true; reason = $null; tests = @($testsOut) }
        }
    }

    $outObj = [ordered]@{
        mode            = $mode
        seeds           = $finalSeeds
        droppedSeeds    = $droppedSeeds
        matches         = $matches
        reverseCoverage = $reverseCoverage
        scanned         = $scanned
        skipped         = $skipped
    }
    $outPath = Join-Path $workspaceDir 'impact-index.json'
    Write-JsonFileNoBom -Object $outObj -Path $outPath

    $secondsTotal = 0.0
    foreach ($s in $scanned) { $secondsTotal += [double]$s.seconds }
    Write-Output "impact-index: indexed $($scanned.Count) repo(s) in $([math]::Round($secondsTotal, 1))s - $($matches.Count) reference(s) to $($finalSeeds.Count) seed(s) ($($droppedSeeds.Count) dropped as low-signal) -> $outPath"
    exit 0
}
catch {
    [Console]::Error.WriteLine("impact-index.ps1 FAILED: $($_.Exception.Message)")
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    exit 1
}
