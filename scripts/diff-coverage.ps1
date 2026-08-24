#requires -Version 5.1
<#
diff-coverage.ps1 -- Cobertura coverage intersected with git diff -> diff-coverage.json

Reads : run-manifest.json (via -Manifest), <workspaceDir>\diff-set.json,
        Cobertura XML files (-CoverageFiles globs, or default discovery under
        <workspaceDir>\cov\*.cobertura.xml and <workspaceDir>\trx\**\coverage.cobertura.xml).
Writes: <workspaceDir>\diff-coverage.json -- shape per scripts/CONTRACTS.md.

Semantics (see CLAUDE.md Phase 2): the numbers answer "of the lines YOU changed on this
branch, which are tested?" -- never a global coverage percentage.

Exit 0 = script ran (a refusal or a 0% result is a finding, it lives in the JSON).
Non-zero = the script itself failed. Exactly one summary line goes to stdout.
Idempotent: safe to re-run, overwrites its own artifact only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Manifest,

    # Cobertura file paths/globs ('*' and '**' supported). Relative patterns resolve
    # against the run's workspaceDir. Empty -> default discovery (see below).
    [string[]]$CoverageFiles = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================== helpers ====================================

function Get-Prop {
    # StrictMode-safe property access on PSCustomObjects from ConvertFrom-Json --
    # under Set-StrictMode, touching a property JSON didn't include throws.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Get-NormPath {
    # Windows-normalized comparison key: forward slashes + lowercase, leading "./" stripped.
    # WHY: Cobertura filenames mix '\' vs '/' and drive-letter casing while git paths are
    # '/'-separated -- comparing raw strings is the #1 way diff coverage silently resolves
    # nothing and then reports a false 0%.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim() -replace '\\', '/'
    $p = $p -replace '^(\./)+', ''
    return $p.ToLowerInvariant()
}

function Get-ExtLower {
    # [IO.Path]::GetExtension throws ArgumentException on illegal path chars under
    # .NET Framework (PS 5.1) -- Cobertura filenames are untrusted input, so do it by hand.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $dot = $Path.LastIndexOf('.')
    $sep = [Math]::Max($Path.LastIndexOf('/'), $Path.LastIndexOf('\'))
    if ($dot -lt 0 -or $dot -lt $sep) { return '' }
    return $Path.Substring($dot).ToLowerInvariant()
}

# Executable-candidate source extensions per language family this pipeline covers
# (.NET repos + JS/TS repos -- see CLAUDE.md test levels). Anything else (.csproj,
# .json, .md, .config ...) can never appear in Cobertura and is ignored.
$DotnetExts = @('.cs', '.vb', '.fs', '.fsx')
$JsExts     = @('.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs')
$CodeExts   = $DotnetExts + $JsExts

function Get-LangGroup {
    param([string]$Ext)
    if ($DotnetExts -contains $Ext) { return 'dotnet' }
    if ($JsExts -contains $Ext) { return 'js' }
    return $null
}

function Test-IsTestOrGeneratedFile {
    # WHY: coverage runs exclude test assemblies/specs by design and coverlet excludes
    # generated code by default. Counting those files as "should have coverage data"
    # would fake a path-mapping failure and trip the 0.8 refusal gate on healthy runs.
    # Heuristic (rare false positives like 'latest.cs' only nudge the ratio denominator;
    # they never affect the coverage numbers themselves).
    param([string]$NormPath)
    if ($NormPath -match '(^|/)(tests?|__tests__|specs?|testing)/') { return $true }
    if ($NormPath -match '\.(tests?|specs?)\.')                     { return $true }  # foo.test.ts / foo.spec.ts
    if ($NormPath -match '(tests?|specs?)\.(cs|vb|fs)$')            { return $true }  # FooTests.cs
    if ($NormPath -match '(\.designer\.cs|\.g\.cs|\.g\.i\.cs|\.generated\.cs|assemblyinfo\.cs|\.min\.js)$') { return $true }
    return $false
}

function Format-MethodDisplay {
    # Best-effort pretty form of a Cobertura method for humans:
    #   name="Apply" signature="(Visma.Payroll.Order,System.Decimal)" -> "Apply(Order, decimal)".
    # Purely cosmetic -- consumers only display it, so lossy simplification is fine.
    param([string]$Name, [string]$Signature)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $short = ($Name -split '::')[-1]
    if ([string]::IsNullOrWhiteSpace($Signature)) { return $short }
    $inner = $Signature.Trim().TrimStart('(').TrimEnd(')')
    if ($inner -eq '') { return ($short + '()') }
    $primMap = @{
        'Int32' = 'int'; 'Int64' = 'long'; 'Int16' = 'short'; 'Byte' = 'byte'
        'UInt32' = 'uint'; 'UInt64' = 'ulong'; 'UInt16' = 'ushort'; 'SByte' = 'sbyte'
        'Boolean' = 'bool'; 'String' = 'string'; 'Char' = 'char'; 'Object' = 'object'
        'Decimal' = 'decimal'; 'Double' = 'double'; 'Single' = 'float'; 'Void' = 'void'
    }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($raw in ($inner -split ',')) {
        $t = $raw.Trim()
        # Strip namespace / nested-type qualifiers everywhere (works inside generics too).
        $t = $t -replace '([A-Za-z_][A-Za-z0-9_]*[\.\+/])+', ''
        $t = $t -replace '`\d+', ''   # drop generic arity markers (List`1 -> List)
        foreach ($kvp in $primMap.GetEnumerator()) {
            $t = $t -replace ('\b' + $kvp.Key + '\b'), $kvp.Value
        }
        $parts.Add($t)
    }
    return ('{0}({1})' -f $short, ($parts -join ', '))
}

# =========================== load inputs ====================================

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
    throw "Manifest not found: $Manifest"
}
$man = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
$workspaceDir = [string](Get-Prop $man 'workspaceDir')
if ([string]::IsNullOrWhiteSpace($workspaceDir)) { throw "run-manifest.json has no workspaceDir" }
$repoPath    = [string](Get-Prop $man 'repoPath')
$worktreeDir = [string](Get-Prop $man 'worktreeDir')

$diffSetPath = Join-Path $workspaceDir 'diff-set.json'
if (-not (Test-Path -LiteralPath $diffSetPath -PathType Leaf)) {
    throw "diff-set.json not found at $diffSetPath (run worktree.ps1 -DiffSet first)"
}
$diffSet = Get-Content -LiteralPath $diffSetPath -Raw -Encoding UTF8 | ConvertFrom-Json

# ==================== step 1 -- the changed-line set =========================
# changed := {(file, newLine)} on the NEW side of the merge-base diff, plus every
# line of untracked source files. Which of those lines are actually executable is
# decided later by intersecting with Cobertura's measured lines -- Cobertura only
# lists executable lines (braces/usings/comments never appear), so counting raw
# diff lines instead would make the metric a function of brace style.

$changedLines   = @{}   # norm path -> @{ [int]line -> $true }
$origCase       = @{}   # norm path -> repo-relative path as git reported it (for output)
$allChangedNorm = New-Object System.Collections.Generic.List[string]

function Add-ChangedFile {
    param([string]$RepoRelPath)
    $k = Get-NormPath $RepoRelPath
    if (-not $changedLines.ContainsKey($k)) {
        $changedLines[$k] = @{}
        $origCase[$k] = ($RepoRelPath -replace '\\', '/')
        $allChangedNorm.Add($k)
    }
    return $k
}

foreach ($f in @(Get-Prop $diffSet 'files' @())) {
    if ($null -eq $f) { continue }
    $path = [string](Get-Prop $f 'path')
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    $k = Add-ChangedFile $path
    foreach ($h in @(Get-Prop $f 'hunks' @())) {
        if ($null -eq $h) { continue }
        $start = [int](Get-Prop $h 'newStart' 0)
        $count = [int](Get-Prop $h 'newCount' 0)
        # newCount 0 = pure deletion on the new side (e.g. "@@ -5,3 +4,0 @@"):
        # nothing was added, so there is nothing to cover.
        if ($start -lt 1 -or $count -lt 1) { continue }
        for ($n = $start; $n -lt ($start + $count); $n++) { $changedLines[$k][$n] = $true }
    }
}

foreach ($u in @(Get-Prop $diffSet 'untracked' @())) {
    if ([string]::IsNullOrWhiteSpace([string]$u)) { continue }
    $ext = Get-ExtLower ([string]$u)
    if ($CodeExts -notcontains $ext) { continue }   # executable candidates only
    # WHY: an untracked file is 100% new code, but `git diff` emits no hunks for it --
    # a plain diff silently misses a developer's brand-new class (see CLAUDE.md Phase 1).
    # Every line counts as changed; the measured-line intersection prunes the rest.
    $abs = $null
    foreach ($root in @($repoPath, $worktreeDir)) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $cand = Join-Path $root ([string]$u)
            if (Test-Path -LiteralPath $cand -PathType Leaf) { $abs = $cand; break }
        }
    }
    if ($null -eq $abs) {
        Write-Verbose "untracked file listed in diff-set but not found on disk, skipped: $u"
        continue
    }
    $k = Add-ChangedFile ([string]$u)
    $total = ([System.IO.File]::ReadAllLines($abs)).Count
    for ($n = 1; $n -le $total; $n++) { $changedLines[$k][$n] = $true }
}

# ==================== discover coverage files ===============================

$covPaths = New-Object System.Collections.Generic.List[string]
$covSeen  = @{}
function Add-CovPath {
    param([string]$p)
    $fp = $p
    try { $fp = (Resolve-Path -LiteralPath $p -ErrorAction Stop).ProviderPath } catch { }
    $key = $fp.ToLowerInvariant()
    if (-not $covSeen.ContainsKey($key)) {
        $covSeen[$key] = $true
        $covPaths.Add($fp)
    }
}

if ($null -eq $CoverageFiles -or $CoverageFiles.Count -eq 0) {
    # Default discovery mirrors where run-tests.ps1 drops coverage: collector/converted
    # output under cov\, and coverlet TRX-attachment files under trx\**.
    $covDir = Join-Path $workspaceDir 'cov'
    if (Test-Path -LiteralPath $covDir -PathType Container) {
        foreach ($fi in @(Get-ChildItem -LiteralPath $covDir -Filter '*.cobertura.xml' -File -ErrorAction SilentlyContinue)) {
            Add-CovPath $fi.FullName
        }
    }
    $trxDir = Join-Path $workspaceDir 'trx'
    if (Test-Path -LiteralPath $trxDir -PathType Container) {
        foreach ($fi in @(Get-ChildItem -LiteralPath $trxDir -Recurse -Filter 'coverage.cobertura.xml' -File -ErrorAction SilentlyContinue)) {
            Add-CovPath $fi.FullName
        }
    }
} else {
    foreach ($pattern in $CoverageFiles) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $pat = $pattern
        if (-not [System.IO.Path]::IsPathRooted($pat)) { $pat = Join-Path $workspaceDir $pat }
        if ($pat -match '\*\*') {
            # PS 5.1 Get-ChildItem has no native '**' support: recurse from the segment
            # before the first '**' and match the leaf name. Intermediate segments after
            # '**' are ignored -- an approximation that can only over-match, never miss.
            $basePart = ($pat -split '\*\*', 2)[0].TrimEnd('\', '/')
            if ([string]::IsNullOrWhiteSpace($basePart)) { $basePart = $workspaceDir }
            $leaf = Split-Path -Path $pat -Leaf
            if (Test-Path -LiteralPath $basePart -PathType Container) {
                foreach ($fi in @(Get-ChildItem -LiteralPath $basePart -Recurse -Filter $leaf -File -ErrorAction SilentlyContinue)) {
                    Add-CovPath $fi.FullName
                }
            }
        } else {
            foreach ($fi in @(Get-ChildItem -Path $pat -File -ErrorAction SilentlyContinue)) {
                Add-CovPath $fi.FullName
            }
        }
    }
}

# ==================== steps 2+3 -- streaming parse + path resolution =========

# Roots to strip when mapping absolute Cobertura paths back to repo-relative git paths.
$repoRoots = New-Object System.Collections.Generic.List[string]
foreach ($root in @($repoPath, $worktreeDir, $workspaceDir)) {
    if (-not [string]::IsNullOrWhiteSpace($root)) {
        $nr = (Get-NormPath $root).TrimEnd('/')
        if ($nr -ne '' -and -not $repoRoots.Contains($nr)) { $repoRoots.Add($nr) }
    }
}

function Resolve-ChangedKey {
    # Path resolution -- THE #1 silently-wrong-diff-coverage cause (verified research).
    # Ordered strategy:
    #   1. Cobertura filename as-is,
    #   2. joined against each //sources/source prefix,
    #   3. segment-aligned suffix match against the git file list from diff-set.
    # Everything is compared normalized (separators + case) because this is Windows.
    param([string]$CoberturaFileName, [System.Collections.Generic.List[string]]$Sources)
    $fnNorm = Get-NormPath $CoberturaFileName
    if ($fnNorm -eq '') { return $null }
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($fnNorm)
    foreach ($src in $Sources) {
        $srcNorm = (Get-NormPath $src).TrimEnd('/')
        if ($srcNorm -ne '') { $candidates.Add($srcNorm + '/' + $fnNorm) }
    }
    foreach ($cand in $candidates) {
        if ($changedLines.ContainsKey($cand)) { return $cand }
        foreach ($root in $repoRoots) {
            if ($cand.StartsWith($root + '/')) {
                $rel = $cand.Substring($root.Length + 1)
                if ($changedLines.ContainsKey($rel)) { return $rel }
            }
        }
    }
    # Suffix match must be UNAMBIGUOUS: attributing coverage to the wrong file is worse
    # than not resolving at all (it manufactures both false gaps and false coverage).
    $suffixHits = New-Object System.Collections.Generic.List[string]
    foreach ($k in $allChangedNorm) {
        $isHit = $false
        foreach ($cand in $candidates) {
            if ($cand.EndsWith('/' + $k)) { $isHit = $true; break }
            if ($k.EndsWith('/' + $cand)) { $isHit = $true; break }
        }
        if ($isHit) { $suffixHits.Add($k) }
    }
    if ($suffixHits.Count -eq 1) { return $suffixHits[0] }
    if ($suffixHits.Count -gt 1) {
        Write-Verbose "ambiguous suffix match for '$CoberturaFileName' -> [$($suffixHits -join ', ')]; left unresolved"
    }
    return $null
}

$lineData        = @{}   # norm changed path -> @{ [int]line -> record }
$resolvedChanged = @{}   # norm changed path -> $true (some Cobertura <class> resolved to it)
$covLangGroups   = @{}   # 'dotnet'/'js' -> $true, from EVERY class filename seen (resolved or not)
$classesSeen     = 0

# Streaming XmlReader because coverage files can be huge (verified 4x-47x coverage
# blowups elsewhere in this pipeline -- never load these as a DOM).
$settings = New-Object System.Xml.XmlReaderSettings
# Cobertura files carry a <!DOCTYPE ... cobertura.sourceforge.net ...> declaration:
# DtdProcessing Prohibit would throw on it, and a live resolver would try to fetch the
# DTD over the network. Ignore + null resolver = offline, safe, and tolerant.
$settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
$settings.XmlResolver = $null
$settings.IgnoreComments = $true
$settings.IgnoreProcessingInstructions = $true
$settings.IgnoreWhitespace = $true
$settings.CloseInput = $true

foreach ($covPath in $covPaths) {
    Write-Verbose "parsing coverage file: $covPath"
    $reader = $null
    try {
        $reader = [System.Xml.XmlReader]::Create($covPath, $settings)
        $sources      = New-Object System.Collections.Generic.List[string]
        $resolveCache = @{}     # per-document: <sources> differ between coverage files
        $currentKey   = $null   # resolved changed-file key of the enclosing <class>, else $null
        $mName = $null; $mSig = $null; $mComplexity = $null

        $more = $reader.Read()
        while ($more) {
            $skipCalled = $false
            if ($reader.NodeType -eq [System.Xml.XmlNodeType]::Element) {
                switch ($reader.LocalName) {
                    'source' {
                        # <source> text = path prefix candidates for relative class filenames.
                        if (-not $reader.IsEmptyElement) {
                            if ($reader.Read() -and ($reader.NodeType -eq [System.Xml.XmlNodeType]::Text -or $reader.NodeType -eq [System.Xml.XmlNodeType]::CDATA)) {
                                $src = $reader.Value.Trim()
                                if ($src -ne '') { $sources.Add($src) }
                            }
                        }
                    }
                    'class' {
                        $classesSeen++
                        $fn = $reader.GetAttribute('filename')
                        $currentKey = $null
                        if (-not [string]::IsNullOrWhiteSpace($fn)) {
                            $g = Get-LangGroup (Get-ExtLower $fn)
                            if ($null -ne $g) { $covLangGroups[$g] = $true }
                            if ($resolveCache.ContainsKey($fn)) {
                                $currentKey = $resolveCache[$fn]
                            } else {
                                $currentKey = Resolve-ChangedKey -CoberturaFileName $fn -Sources $sources
                                $resolveCache[$fn] = $currentKey
                            }
                            if ($null -ne $currentKey) { $resolvedChanged[$currentKey] = $true }
                        }
                        if ($null -eq $currentKey -and -not $reader.IsEmptyElement) {
                            # Perf: skip the whole subtree of classes in unchanged files --
                            # they are the overwhelming majority of a coverage report.
                            $reader.Skip()
                            $skipCalled = $true
                        }
                    }
                    'method' {
                        if ($null -ne $currentKey -and -not $reader.IsEmptyElement) {
                            $mName = $reader.GetAttribute('name')
                            $mSig  = $reader.GetAttribute('signature')
                            # Method-level complexity in Cobertura is unreliable (only class-level
                            # is trustworthy) -- take the attribute only if it exists, never derive.
                            $mComplexity = $reader.GetAttribute('complexity')
                        }
                    }
                    'line' {
                        if ($null -ne $currentKey) {
                            $n = 0
                            if ([int]::TryParse($reader.GetAttribute('number'), [ref]$n) -and $changedLines[$currentKey].ContainsKey($n)) {
                                $hits = [long]0
                                [void][long]::TryParse($reader.GetAttribute('hits'), [ref]$hits)
                                # -eq is case-insensitive in PowerShell -- exactly what's needed:
                                # coverlet emits branch="True", spec-compliant tools emit "true".
                                $isBranch = ($reader.GetAttribute('branch') -eq 'true')
                                $condCov = 0; $condTot = 0
                                if ($isBranch) {
                                    $cc = $reader.GetAttribute('condition-coverage')   # e.g. "50% (1/2)"
                                    if ($null -ne $cc -and $cc -match '\((\d+)/(\d+)\)') {
                                        $condCov = [int]$Matches[1]
                                        $condTot = [int]$Matches[2]
                                    }
                                }
                                if (-not $lineData.ContainsKey($currentKey)) { $lineData[$currentKey] = @{} }
                                $fileLines = $lineData[$currentKey]
                                if (-not $fileLines.ContainsKey($n)) {
                                    $fileLines[$n] = @{
                                        hits = $hits; condCov = $condCov; condTot = $condTot
                                        mName = $mName; mSig = $mSig; mComplexity = $mComplexity
                                    }
                                } else {
                                    # Union semantics across the method-level/class-level duplicate
                                    # <line> entries and across multiple coverage files: covered
                                    # anywhere = covered -- that's what "is this line tested" means.
                                    $rec = $fileLines[$n]
                                    if ($hits -gt $rec.hits) { $rec.hits = $hits }
                                    if ($condTot -gt 0) {
                                        # Best observed condition ratio wins (cross-multiplied to avoid
                                        # divide-by-zero). Limitation: two runs covering DIFFERENT branches
                                        # can't be unioned from ratios alone, so this understates -- never
                                        # overstates -- branch coverage.
                                        if ($rec.condTot -eq 0 -or (($condCov * $rec.condTot) -gt ($rec.condCov * $condTot))) {
                                            $rec.condCov = $condCov
                                            $rec.condTot = $condTot
                                        }
                                    }
                                    # Class-level duplicates carry no method context -- never let them
                                    # blank out method info captured from the method-level entry.
                                    if ($null -eq $rec.mName -and $null -ne $mName) {
                                        $rec.mName = $mName; $rec.mSig = $mSig; $rec.mComplexity = $mComplexity
                                    }
                                }
                            }
                        }
                    }
                }
            }
            elseif ($reader.NodeType -eq [System.Xml.XmlNodeType]::EndElement) {
                switch ($reader.LocalName) {
                    'method' { $mName = $null; $mSig = $null; $mComplexity = $null }
                    'class'  { $currentKey = $null; $mName = $null; $mSig = $null; $mComplexity = $null }
                }
            }
            if ($skipCalled) {
                # Skip() already advanced the reader to the next sibling; calling Read()
                # again here would silently drop one node (classic XmlReader bug).
                $more = ($reader.ReadState -eq [System.Xml.ReadState]::Interactive)
                continue
            }
            $more = $reader.Read()
        }
    }
    catch {
        # A malformed/truncated coverage file must not kill the run: skip it. The
        # resolvedFileRatio gate below turns "no usable coverage" into an honest
        # refusal instead of a crash or a fake 0%.
        Write-Verbose "failed to parse '$covPath': $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
    }
}

# ==================== step 3b -- resolvedFileRatio ===========================
# Denominator = changed code files that SHOULD have coverage data. Two exclusions:
#  - test/generated files (coverage excludes them by design -- see Test-IsTestOrGeneratedFile),
#  - files whose language the coverage run didn't touch at all: "assemblies the coverage
#    run included" approximated at language level -- a Cobertura file holding only .NET
#    classes can never resolve a changed .ts file, and that's not a mapping failure.
# When NO classes parsed at all, nothing is excluded by language -> ratio 0 -> refusal
# (coverage genuinely absent or unreadable).

$denomFiles = New-Object System.Collections.Generic.List[string]
foreach ($k in $allChangedNorm) {
    $ext = Get-ExtLower $k
    if ($CodeExts -notcontains $ext) { continue }
    if (Test-IsTestOrGeneratedFile $k) { continue }
    if ($classesSeen -gt 0 -and $covLangGroups.Count -gt 0) {
        $g = Get-LangGroup $ext
        if (-not $covLangGroups.ContainsKey($g)) { continue }
    }
    $denomFiles.Add($k)
}
$numResolved = 0
foreach ($k in $denomFiles) {
    if ($resolvedChanged.ContainsKey($k)) { $numResolved++ }
}
if ($denomFiles.Count -gt 0) {
    $resolvedFileRatio = [math]::Round($numResolved / $denomFiles.Count, 4)
} else {
    # Docs/config-only diff: nothing could have coverage data -> vacuously fully resolved.
    # (Refusal is reserved for broken path mapping; "nothing to measure" emits nulls below.)
    $resolvedFileRatio = 1.0
}

# ==================== step 4 -- refusal gate =================================
# WHY: reporting "0% of your changes are tested" off broken path mapping is a
# maximally-alarming false verdict. Below 0.8 resolution we refuse to emit numbers.

$refused = $false
$refusalReason = $null
if ($resolvedFileRatio -lt 0.8) {
    $refused = $true
    if ($covPaths.Count -eq 0) {
        $refusalReason = "No Cobertura coverage files found (looked for cov\*.cobertura.xml and trx\**\coverage.cobertura.xml under $workspaceDir, or the -CoverageFiles patterns matched nothing) -- cannot compute diff coverage."
    } elseif ($classesSeen -eq 0) {
        $refusalReason = "Coverage files were found but no <class> data could be parsed from them -- cannot compute diff coverage."
    } else {
        $refusalReason = "Only $numResolved of $($denomFiles.Count) changed code files resolved against the coverage report paths (ratio $resolvedFileRatio < 0.8) -- path mapping between Cobertura filenames and the git diff is broken, or coverage did not include the changed assemblies. Refusing to report numbers built on it."
    }
}

# ==================== steps 5+6 -- metrics and gaps ==========================

$lineDiffCoverage   = $null
$branchDiffCoverage = $null
$changedExecutable  = $null
$coveredChanged     = $null
$gaps = New-Object System.Collections.Generic.List[object]

if (-not $refused) {
    $measured = 0; $covered = 0
    $bTot = 0; $bCov = 0
    # Deterministic iteration order (file, then line) -- this repo's credibility rests on
    # the same branch producing byte-identical artifacts twice.
    foreach ($k in @($lineData.Keys | Sort-Object)) {
        $fileLines = $lineData[$k]
        foreach ($n in @($fileLines.Keys | Sort-Object)) {
            $rec = $fileLines[$n]
            $measured++
            $isCovered = ($rec.hits -gt 0)
            if ($isCovered) { $covered++ }
            $isPartial = ($rec.condTot -gt 0 -and $rec.condCov -lt $rec.condTot)
            if ($rec.condTot -gt 0) {
                $bTot += $rec.condTot
                $bCov += [Math]::Min($rec.condCov, $rec.condTot)
            }
            $kind = $null
            if (-not $isCovered) { $kind = 'uncovered' }
            elseif ($isPartial)  { $kind = 'partial-branch' }
            if ($null -ne $kind) {
                $cc = $null
                if ($rec.condTot -gt 0) { $cc = ('{0}/{1}' -f $rec.condCov, $rec.condTot) }
                $mc = $null
                if ($null -ne $rec.mComplexity -and ([string]$rec.mComplexity) -match '^\d+(\.\d+)?$') {
                    $mc = [int][double]$rec.mComplexity
                }
                $gaps.Add([pscustomobject][ordered]@{
                    file              = $origCase[$k]
                    line              = [int]$n
                    kind              = $kind
                    conditionCoverage = $cc
                    enclosingMethod   = (Format-MethodDisplay $rec.mName $rec.mSig)
                    methodComplexity  = $mc
                })
            }
        }
    }
    $changedExecutable = $measured
    $coveredChanged    = $covered
    # lineDiffCoverage = |changed AND covered| / |changed AND measured|.
    if ($measured -gt 0) { $lineDiffCoverage = [math]::Round($covered / $measured, 4) }
    # branchDiffCoverage from conditions on changed lines -- reported SEPARATELY because
    # a partially-covered branch is the most valuable pre-PR signal and line coverage
    # hides it (the line has hits, the else-path was never taken).
    # null when no changed line carries conditions: 0 would alarm, 1.0 would lie --
    # risk-score renormalizes missing signals instead (see CONTRACTS.md).
    if ($bTot -gt 0) { $branchDiffCoverage = [math]::Round($bCov / $bTot, 4) }
    # Note: lineDiffCoverage stays null when no changed line is measured (e.g. docs-only
    # diff) -- same honesty rule: no number is better than a fake one.
}

# ==================== write artifact + summary ==============================

$doc = [pscustomobject][ordered]@{
    resolvedFileRatio      = $resolvedFileRatio
    refused                = $refused
    refusalReason          = $refusalReason
    lineDiffCoverage       = $lineDiffCoverage
    branchDiffCoverage     = $branchDiffCoverage
    changedExecutableLines = $changedExecutable
    coveredChangedLines    = $coveredChanged
    gaps                   = $gaps.ToArray()
}

$outPath = Join-Path $workspaceDir 'diff-coverage.json'
$json = ConvertTo-Json -InputObject $doc -Depth 12
# CONTRACTS.md requires UTF-8 with NO BOM; PS 5.1's Out-File -Encoding utf8 always
# writes a BOM, so write through .NET with an explicitly BOM-less encoding.
[System.IO.File]::WriteAllText($outPath, $json, (New-Object System.Text.UTF8Encoding($false)))

if ($refused) {
    Write-Output "diff-coverage: REFUSED (resolvedFileRatio $resolvedFileRatio < 0.8; $numResolved/$($denomFiles.Count) changed code files resolved) -> $outPath"
} elseif ($null -eq $lineDiffCoverage) {
    Write-Output "diff-coverage: no changed executable lines to measure (resolvedFileRatio $resolvedFileRatio) -> $outPath"
} else {
    $linePct = "$([math]::Round($lineDiffCoverage * 100, 1))%"
    $branchPct = 'n/a'
    if ($null -ne $branchDiffCoverage) { $branchPct = "$([math]::Round($branchDiffCoverage * 100, 1))%" }
    Write-Output "diff-coverage: line=$linePct branch=$branchPct of changed lines ($coveredChanged/$changedExecutable covered), $($gaps.Count) gap(s), resolvedFileRatio=$resolvedFileRatio -> $outPath"
}
exit 0
