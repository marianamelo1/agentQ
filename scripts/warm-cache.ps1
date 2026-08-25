#Requires -Version 5.1
<#
warm-cache.ps1  -  optional pre-warmer so an interactive /qa-review starts hot.

For every registered product repo present on this machine: `git fetch origin`
(the only product-repo write agentQ ever makes, and a sanctioned one). Then, for
every existing workspace/<repoSlug>/<branchSlug>/ that already has a
run-manifest.json (i.e. branches someone actually reviews here): re-ensure both
persistent worktrees (branch + base) and pre-build the adapter-profiled test
projects in each, so the next review pays an incremental build instead of a cold
one.

Intended to run unattended (e.g. a scheduled nightly job or /schedule routine).
It never runs tests, never mutates, and touches nothing outside workspace/ and
git's own fetch metadata. NOTE: `dotnet build` performs an implicit NuGet
restore, so first-time package downloads can hit the network  -  acceptable for a
warm-up job, worth knowing for an offline machine.

Usage:
  pwsh -File scripts/warm-cache.ps1 -ConfigPath .claude/qa-agent-config.jsonc [-RepoFilter <exact productRepos key>] [-SkipBuild]

Contract: exit 0 = the script ran (per-item failures are reported lines, never a
crash  -  a warm-up must not fail the night over one broken branch workspace);
non-zero = the script itself broke. Summary lines to stdout (this script is a
human/cron-facing utility, not a phase artifact producer  -  no JSON contract).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    # Exact productRepos key to warm just one repo ('' = all registered repos).
    [string]$RepoFilter = '',
    # Fetch + worktree refresh only; skip the dotnet pre-builds.
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$script:AgentQRoot    = Split-Path -Parent $PSScriptRoot
$script:WorkspaceRoot = Join-Path $script:AgentQRoot 'workspace'
$script:WorktreePs1   = Join-Path $PSScriptRoot 'worktree.ps1'
# Child PowerShell for worktree.ps1 calls (it exits; running it in-process would
# kill this script). Prefer pwsh, fall back to Windows PowerShell 5.1.
$script:PsExe = 'powershell'
if ($null -ne (Get-Command pwsh -ErrorAction SilentlyContinue)) { $script:PsExe = 'pwsh' }

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Get-ProductReposFromConfig {
    # Minimal JSONC -> JSON, same pragmatic parser as worktree.ps1 (self-contained
    # scripts by convention  -  no shared module).
    param([Parameter(Mandatory = $true)][string]$Path)
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
    if (-not ($cfg.PSObject.Properties.Name -contains 'productRepos')) { throw "Config missing 'productRepos': $Path" }
    $map = [ordered]@{}
    foreach ($prop in $cfg.productRepos.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
    return $map
}

function Invoke-WorktreeMode {
    # One worktree.ps1 call; returns $true on success. Failures become report
    # lines, never a crash  -  see the contract note above.
    param([string]$Mode, [string]$ManifestPath)
    # WHY not `2>&1`: PS 5.1 wraps redirected native stderr in ErrorRecords, which
    # $ErrorActionPreference='Stop' promotes to terminating errors (same fix as
    # run-tests.ps1/contract-check.ps1)  -  stderr passes straight to the console.
    & $script:PsExe -NoProfile -File $script:WorktreePs1 $Mode -Manifest $ManifestPath | ForEach-Object { Write-Output "    $_" }
    return ($LASTEXITCODE -eq 0)
}

try {
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git not found on PATH' }
    $repos = Get-ProductReposFromConfig -Path $ConfigPath
    if (-not [string]::IsNullOrWhiteSpace($RepoFilter)) {
        if (-not $repos.Contains($RepoFilter)) { throw "-RepoFilter '$RepoFilter' is not a key in productRepos: $ConfigPath" }
        $only = [ordered]@{}
        $only[$RepoFilter] = $repos[$RepoFilter]
        $repos = $only
    }

    $fetched = 0
    $warmed = 0
    $failedItems = 0

    foreach ($slug in $repos.Keys) {
        $path = [string]$repos[$slug]
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Container)) {
            Write-Output "warm-cache: $slug  -  SKIPPED (path not found on this machine)"
            continue
        }
        & git -c core.longpaths=true -C $path fetch origin --quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Output "warm-cache: $slug  -  fetch FAILED (exit $LASTEXITCODE); worktree refresh skipped for this repo"
            $failedItems++
            continue
        }
        $fetched++
        Write-Output "warm-cache: $slug  -  fetched"

        $repoDirSlug = ($slug -replace '/', '__') -replace '[^A-Za-z0-9._-]', '-'
        $repoWorkspace = Join-Path $script:WorkspaceRoot $repoDirSlug
        if (-not (Test-Path -LiteralPath $repoWorkspace -PathType Container)) { continue }

        foreach ($branchDir in (Get-ChildItem -LiteralPath $repoWorkspace -Directory -ErrorAction SilentlyContinue)) {
            $manifestPath = Join-Path $branchDir.FullName 'run-manifest.json'
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
            Write-Output "  warming $($branchDir.Name):"
            $ok = Invoke-WorktreeMode -Mode '-Ensure' -ManifestPath $manifestPath
            $ok = (Invoke-WorktreeMode -Mode '-EnsureBase' -ManifestPath $manifestPath) -and $ok
            if (-not $ok) { $failedItems++; continue }

            if (-not $SkipBuild) {
                $man = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $profilesPath = Join-Path $branchDir.FullName 'adapter-profiles.json'
                if (Test-Path -LiteralPath $profilesPath -PathType Leaf) {
                    $profiles = @(Get-Prop (Get-Content -LiteralPath $profilesPath -Raw -Encoding UTF8 | ConvertFrom-Json) 'projects' @())
                    foreach ($root in @([string](Get-Prop $man 'worktreeDir' ''), (Join-Path ([string](Get-Prop $man 'workspaceDir' '')) 'worktree-base'))) {
                        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
                        foreach ($prof in $profiles) {
                            $framework = [string](Get-Prop $prof 'framework' '')
                            if (-not (@('xunit', 'nunit3', 'nunit4') -contains $framework)) { continue }
                            $projRel = ([string](Get-Prop $prof 'projectPath' '')) -replace '/', '\'
                            $projAbs = Join-Path $root $projRel
                            if (-not (Test-Path -LiteralPath $projAbs -PathType Leaf)) { continue }
                            & dotnet build $projAbs -c Debug -v:q --nologo | Out-Null
                            if ($LASTEXITCODE -ne 0) {
                                Write-Output "    build FAILED: $projRel in $root (exit $LASTEXITCODE)"
                                $failedItems++
                            }
                        }
                    }
                }
            }
            $warmed++
        }
    }

    Write-Output "warm-cache: done  -  $fetched repo(s) fetched, $warmed branch workspace(s) warmed, $failedItems failure(s)"
    exit 0
}
catch {
    [Console]::Error.WriteLine("warm-cache.ps1 FAILED: $($_.Exception.Message)")
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    exit 1
}
