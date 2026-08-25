<#
.SYNOPSIS
    adapter-cache.ps1 - repo-level, branch-agnostic cache for adapter-profiles.json,
    modeled on stryker-run.ps1's mutation-cache (Get-MutationCacheKey).

.DESCRIPTION
    qa-intake's adapter-profile derivation (per-test-project framework/runner/
    dialect/placement/sutProjects resolution) is a DETERMINISTIC function of
    two things only: WHICH FILES the diff touches, and the repo's own
    structural config (global.json, the CI workflow files that define the
    test-project inventory / placement allow-list for this repo). It does NOT
    depend on what changed INSIDE those files. So two runs - same branch
    re-invoked, or even two different diffs that happen to touch the identical
    set of paths - with the same structural config produce byte-identical
    adapter-profiles.json, and the second one can skip derivation entirely.

    WHY key on diff PATHS rather than "the affected test projects' .csproj
    content" (a tempting alternative): determining which test projects are
    affected IS what derivation computes - keying on it would need the answer
    before the question. Diff paths are known before derivation (qa-intake's
    own task 1) and are provably sufficient, since they're the only diff-side
    input the derivation logic reads at all.

    Modes:
      -Probe   Compute the key from workspaceDir's diff-set.json; a cache hit
               copies the cached profiles to <workspaceDir>/adapter-profiles.json
               (with fromCache:true) and exits 0. A miss changes nothing on
               disk and exits 0 - qa-intake derives fresh, same as today.
      -Store   Compute the same key, then cache the just-derived
               <workspaceDir>/adapter-profiles.json verbatim (fromCache
               stripped - the cache holds the canonical derived form) plus a
               .meta.json sidecar for debuggability.

    Cache dir: workspace/<repoSlug>/adapter-profile-cache/ (repo-level,
    branch-agnostic - same placement convention as .../mutation-cache/).

    Exit code 0 = the script ran (a miss is a normal outcome, not a failure).
    Non-zero = the script itself broke (bad manifest, missing diff-set.json on
    -Probe, missing adapter-profiles.json on -Store).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Manifest,

    [Parameter(Mandatory = $true, ParameterSetName = 'Probe')]
    [switch]$Probe,

    [Parameter(Mandatory = $true, ParameterSetName = 'Store')]
    [switch]$Store
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# -----------------------------------------------------------------------------
# Helpers (self-contained, no shared module - this codebase's convention)
# -----------------------------------------------------------------------------

function Get-Prop {
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

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Write-JsonFileNoBom {
    param($Object, [string]$Path)
    $json = ConvertTo-Json -InputObject $Object -Depth 12
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $enc)
}

# The repo-structural files that determine adapter-profile derivation RULES
# for a repo (test-project inventory, placement allow-lists) independent of
# which specific files a given diff touches - qa-intake task 3 names these
# per repo (payroll-poc's pr-build-backend.yml test_placement job; e-conomic's
# unit_tests.yml + integration_tests.yml CI matrices).
$script:StructuralRelPaths = @(
    'global.json',
    ('.github', 'workflows', 'pr-build-backend.yml') -join '/',
    ('.github', 'workflows', 'unit_tests.yml') -join '/',
    ('.github', 'workflows', 'integration_tests.yml') -join '/'
)

function Get-AdapterCacheKey {
    param($DiffSet, [string]$RepoPath)
    $sb = New-Object System.Text.StringBuilder
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-Prop $DiffSet 'files' @())) {
        $p = ([string](Get-Prop $f 'path' '')) -replace '\\', '/'
        $status = [string](Get-Prop $f 'status' '')
        if ($p) { $paths.Add("$p|$status") }
    }
    foreach ($u in @(Get-Prop $DiffSet 'untracked' @())) {
        $p = ([string]$u) -replace '\\', '/'
        if ($p) { $paths.Add("$p|U") }
    }
    foreach ($p in @($paths | Sort-Object)) { $null = $sb.AppendLine("path=$p") }

    foreach ($rel in @($script:StructuralRelPaths | Sort-Object)) {
        $abs = Join-Path $RepoPath ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        $h = ''
        if (Test-Path -LiteralPath $abs -PathType Leaf) {
            $h = (Get-FileHash -LiteralPath $abs -Algorithm SHA256).Hash
        }
        $null = $sb.AppendLine("struct=$rel=$h")
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 32).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

try {
    $man = Read-JsonFile -Path $Manifest
    if ($null -eq $man) { throw "Manifest not found or unparseable: $Manifest" }
    $workspaceDir = [string](Get-Prop $man 'workspaceDir' '')
    $repoPath = [string](Get-Prop $man 'repoPath' '')
    if ([string]::IsNullOrWhiteSpace($workspaceDir)) { throw 'run-manifest.json missing workspaceDir' }
    if ([string]::IsNullOrWhiteSpace($repoPath)) { throw 'run-manifest.json missing repoPath' }

    $cacheDir = Join-Path (Split-Path -Parent $workspaceDir) 'adapter-profile-cache'
    $diffSetPath = Join-Path $workspaceDir 'diff-set.json'
    $profilesPath = Join-Path $workspaceDir 'adapter-profiles.json'

    if ($Probe) {
        $diffSet = Read-JsonFile -Path $diffSetPath
        if ($null -eq $diffSet) {
            # Not an error: qa-intake's own task 1 derives diff-set.json if the
            # preflight pre-run didn't already - a probe before that exists
            # simply cannot key anything yet. qa-intake derives fresh, as today.
            Write-Output 'adapter-cache: MISS (no diff-set.json yet) - derive fresh, no -Store skipped either'
            exit 0
        }
        $key = Get-AdapterCacheKey -DiffSet $diffSet -RepoPath $repoPath
        $cachedPath = Join-Path $cacheDir "$key.json"
        if (Test-Path -LiteralPath $cachedPath -PathType Leaf) {
            $cached = Read-JsonFile -Path $cachedPath
            if ($null -ne $cached) {
                $projects = @(Get-Prop $cached 'projects' @())
                $out = [ordered]@{ projects = $projects; fromCache = $true }
                Write-JsonFileNoBom -Object $out -Path $profilesPath
                Write-Output "adapter-cache: HIT (key=$key) -> adapter-profiles.json ($($projects.Count) project(s))"
                exit 0
            }
            # Unreadable cached entry: never trust a husk - fall through to a
            # real derivation, same principle as the mutation cache.
        }
        Write-Output "adapter-cache: MISS (key=$key) - qa-intake will derive fresh"
        exit 0
    }

    if ($Store) {
        $diffSet = Read-JsonFile -Path $diffSetPath
        if ($null -eq $diffSet) { throw "diff-set.json not found at $diffSetPath - cannot compute a cache key to store under" }
        $derived = Read-JsonFile -Path $profilesPath
        if ($null -eq $derived) { throw "adapter-profiles.json not found at $profilesPath - nothing derived to store" }

        $key = Get-AdapterCacheKey -DiffSet $diffSet -RepoPath $repoPath
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

        # Store the CANONICAL derived form - never persist a fromCache:true
        # flag into the cache itself (that field only ever describes how THIS
        # run's own adapter-profiles.json was obtained).
        $toStore = [ordered]@{ projects = @(Get-Prop $derived 'projects' @()) }
        Write-JsonFileNoBom -Object $toStore -Path (Join-Path $cacheDir "$key.json")

        Write-JsonFileNoBom -Object ([ordered]@{
                createdAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
                repoSlug  = [string](Get-Prop $man 'repoSlug' '')
                branch    = [string](Get-Prop $man 'branch' '')
                key       = $key
            }) -Path (Join-Path $cacheDir "$key.meta.json")

        Write-Output "adapter-cache: stored (key=$key) -> adapter-profile-cache/$key.json"
        exit 0
    }

    throw 'Exactly one of -Probe or -Store is required.'
}
catch {
    Write-Error "adapter-cache.ps1: $($_.Exception.Message)"
    exit 1
}
