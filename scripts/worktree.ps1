#Requires -Version 5.1
<#
worktree.ps1  -  agentQ git workspace/worktree lifecycle (deterministic mechanics; agents never do this).

Modes (exactly one switch per invocation):
  -DetectRepo      -ConfigPath <qa-agent-config.jsonc> [-Hint <ticket-or-branch text>]
                   [-RepoFilter <exact productRepos key>] [-WorktreePath <path>]
                                                     Phase 0 repo auto-detect, runs before -Heal/any
                                                     manifest exists: scans EVERY WORKTREE of every
                                                     `productRepos` entry (not just its registered
                                                     path  -  a dev's own `git worktree add` siblings
                                                     are found too); with -Hint, matches each worktree's
                                                     branch name or last 5 commit subjects. -RepoFilter
                                                     narrows the scan to one already-known repo (the
                                                     orchestrator resolves a fragment like "payroll" to
                                                     the exact key itself -  it already has the config
                                                     loaded). -WorktreePath is a direct override: skips
                                                     all matching, just confirms the given path is a
                                                     worktree of a registered repo and returns it as the
                                                     sole candidate. EXCEPTION to the stdout contract
                                                     below: prints ONE line of compact JSON, not prose  -
                                                     see CONTRACTS.md.
  -Heal            -RepoPath <repo>                  Phase 0 crash recovery (runs before any manifest exists).
  -EnsureWorkspace -RepoSlug <cfgKey> -Branch <b> -RepoPath <repo> [-TicketKey <k>] [-Manifest <out>]
                                                     Creates workspace/<repoSlug>/<branchSlug>/, pins baseSha,
                                                     writes run-manifest.json (CONTRACTS.md).
  -DiffSet         -Manifest <run-manifest.json>     Writes diff-set.json (merge-base diff ∪ untracked).
  -Ensure          -Manifest <run-manifest.json>     Persistent detached worktree mirroring the dev's tree
                                                     (committed tip + uncommitted diff + untracked files).
  -FlipToBase      -Manifest <run-manifest.json>     Worktree tracked state -> pure baseSha (anti-vacuity).
  -FlipToBranch    -Manifest <run-manifest.json>     Worktree back to full branch state after anti-vacuity.
  -Verify          -Manifest <run-manifest.json>     Phase 9 cleanup assertions. Writes nothing.

Contract: exit 0 = the script ran (findings live in the printed summary / JSON artifacts);
non-zero = the script itself failed. Exactly one summary line is printed to stdout
(-DetectRepo's one line IS its JSON payload  -  see above; every other mode prints prose).
Writes are fenced to workspace/ and the run's worktree; the only product-repo writes are
git's own sanctioned metadata ops (`fetch`, `worktree add/prune`) that CLAUDE.md Phase 0/5 call for.
#>
[CmdletBinding()]
param(
    [switch]$DetectRepo,
    [switch]$Heal,
    [switch]$EnsureWorkspace,
    [switch]$DiffSet,
    [switch]$Ensure,
    [switch]$FlipToBase,
    [switch]$FlipToBranch,
    [switch]$Verify,

    # Common params
    [string]$RepoPath,      # -Heal (before a manifest exists) and -EnsureWorkspace
    [string]$Manifest,      # path to run-manifest.json; required by every mode except -Heal/-DetectRepo
                            # (-EnsureWorkspace treats it as an optional explicit OUTPUT path)

    # -EnsureWorkspace only
    [string]$RepoSlug,      # the productRepos config key, may contain '/' (e.g. "e-conomic/payroll-poc")
    [string]$Branch,
    [string]$TicketKey = '',

    # -DetectRepo only
    [string]$ConfigPath,      # path to qa-agent-config.jsonc
    [string]$Hint = '',       # ticket key or branch-name fragment the developer mentioned; '' = no hint
    [string]$RepoFilter = '', # exact productRepos key to restrict the scan to; '' = scan all
    [string]$WorktreePath = ''# explicit worktree path override; '' = no override, do the normal scan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# WHY: git emits UTF-8 on stdout, but Windows PowerShell 5.1 decodes native output with the
# OEM codepage by default  -  non-ASCII file names in diff/ls-files output would be mangled and
# then fail to round-trip into worktree copies. Best-effort: some hosts refuse the assignment.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# Derive the agentQ root from the script location instead of hardcoding C:\agentQ, so the
# write-fence (workspace/) follows the repo wherever it is checked out.
$script:AgentQRoot    = Split-Path -Parent $PSScriptRoot
$script:WorkspaceRoot = Join-Path $script:AgentQRoot 'workspace'
$script:LastGitExit   = 0

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

function Invoke-Git {
    # Runs `git -C <dir> <args>`; returns stdout lines as an array (never $null).
    # Throws on non-zero exit unless -AllowFail; callers inspect $script:LastGitExit after -AllowFail.
    # stdout is captured (keeps our one-summary-line stdout contract); git's stderr passes through.
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)][string[]]$GitArgs,
        [switch]$AllowFail
    )
    # WHY -c core.longpaths=true on every call: agentQ nests worktrees under its own
    # workspace/<repoSlug>/<branchSlug>/ path, which adds enough depth that a repo with
    # long auto-generated filenames (verified: e-conomic/client has NSwag-generated
    # schema files whose names alone run ~190 chars) blows past Windows' 260-char
    # MAX_PATH during `worktree add`/`checkout` -- "Filename too long", a hard git
    # failure, not a PowerShell bug. Harmless to pass when paths are already short.
    $out = & git -c core.longpaths=true -C $Dir @GitArgs
    $script:LastGitExit = $LASTEXITCODE
    if ($script:LastGitExit -ne 0 -and -not $AllowFail) {
        throw "git -C `"$Dir`" $($GitArgs -join ' ') failed (exit $script:LastGitExit)"
    }
    if ($null -eq $out) { return ,@() }
    # WHY the comma operator: PS unrolls a returned array  -  a single-line result would come back
    # as a bare string, breaking callers' [0] indexing and .Count under StrictMode.
    return ,@($out)
}

function Write-JsonFile {
    # WHY .NET WriteAllText instead of Out-File: CONTRACTS.md requires UTF-8 *without* BOM,
    # and PS 5.1's `Out-File -Encoding utf8` always emits a BOM (which breaks non-PowerShell
    # consumers of these artifacts, e.g. JS tooling reading diff-set.json).
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $json = $Object | ConvertTo-Json -Depth 12
    $enc  = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $enc)
}

function Test-PathSafe {
    # WHY not a bare Test-Path: a malformed config VALUE (illegal characters like '<'/'>'
    # left over from an unfilled placeholder, a too-long path, ...) makes Test-Path itself
    # throw rather than return $false -  and -DetectRepo scans every registered repo in one
    # pass, so one bad entry must not crash the scan for every OTHER repo. Report false instead.
    param([Parameter(Mandatory = $true)][string]$Path)
    try { return (Test-Path -LiteralPath $Path -PathType Container) }
    catch { return $false }
}

function Get-NormalizedPath {
    # Canonical form for path-identity comparisons (git mixes / and \ on Windows; casing varies).
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    return $full.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
}

function Read-RunManifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'This mode requires -Manifest <path to run-manifest.json>' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Manifest not found: $Path (run -EnsureWorkspace first)"
    }
    $m = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($field in @('repoSlug', 'repoPath', 'branch', 'baseRef', 'baseSha', 'workspaceDir', 'worktreeDir')) {
        if (-not ($m.PSObject.Properties.Name -contains $field)) {
            throw "Manifest missing required field '$field': $Path"
        }
    }
    return $m
}

function Get-DevUntrackedFiles {
    # WHY -z: NUL-separated output avoids git's C-style quoting, so names with spaces or
    # non-ASCII characters round-trip. PowerShell may split captured output on newlines;
    # -join '' reassembles before splitting on NUL (filenames cannot contain NUL).
    param([Parameter(Mandatory = $true)][string]$Repo)
    $raw = (& git -C $Repo ls-files --others --exclude-standard -z) -join ''
    if ($LASTEXITCODE -ne 0) { throw "git ls-files failed in $Repo (exit $LASTEXITCODE)" }
    return ,@($raw -split "`0" | Where-Object { $_ -ne '' })
}

function ConvertFrom-DiffPath {
    # Strips the a/|b/ prefix and undoes git's C-quoting on `+++ "b/..."` header paths.
    # Best-effort on exotic escapes (octal): a miss only costs that file its hunk list  - 
    # the file itself is still reported via --name-status.
    param([Parameter(Mandatory = $true)][string]$Raw)
    $p = $Raw.Trim()
    if ($p.StartsWith('"') -and $p.EndsWith('"') -and $p.Length -ge 2) {
        $p = $p.Substring(1, $p.Length - 2)
        $p = $p -replace '\\t', "`t"
        $p = $p -replace '\\n', "`n"
        $p = $p -replace '\\"', '"'
        $p = $p -replace '\\\\', '\'
    }
    if ($p -match '^[ab]/') { $p = $p.Substring(2) }
    return $p
}

function Restore-BranchState {
    # Brings the worktree to the dev's exact current state: branch tip (detached) +
    # uncommitted tracked diff + untracked files. Shared by -Ensure and -FlipToBranch.
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$WorktreeDir,
        [Parameter(Mandatory = $true)][string]$WorkspaceDir,
        # -Ensure (reuse) wants a full `clean -fd` before checkout; -FlipToBranch must NOT clean:
        # by then the worktree holds the generated tests (untracked, worktree-only) that Phase 8
        # offers the developer to keep  -  cleaning would destroy them.
        [switch]$CleanFirst
    )
    $tipSha = (Invoke-Git -Dir $Repo -GitArgs @('rev-parse', 'HEAD'))[0]

    if ($CleanFirst) {
        # WHY -fd and not -fdx: ignored bin/obj under the worktree are the warm build cache
        # we deliberately keep between runs (fast-by-construction principle).
        $null = Invoke-Git -Dir $WorktreeDir -GitArgs @('clean', '-fd')
    }
    # WHY --force: a crashed mutation run can leave mutated *tracked sources* behind
    # (semantic-mutant const->property promotion happens in the worktree copy). The worktree
    # is disposable by design; the dev's tree is the single source of truth.
    $null = Invoke-Git -Dir $WorktreeDir -GitArgs @('checkout', '--force', '--detach', $tipSha)

    # Re-apply the dev's uncommitted (tracked) changes.
    # WHY --output + a file (not a PowerShell pipe): PS 5.1 re-encodes and CRLF-mangles piped
    # native output, silently corrupting patches; git writes raw bytes itself. --binary covers
    # uncommitted binary edits. The path must be absolute: `git -C` runs from the repo root.
    $patchPath = Join-Path $WorkspaceDir 'uncommitted.patch'
    $null = Invoke-Git -Dir $Repo -GitArgs @('diff', 'HEAD', '--binary', "--output=$patchPath")
    $patchApplied = $false
    if ((Get-Item -LiteralPath $patchPath).Length -gt 0) {
        # WHY throw on failure (no fallback): the worktree just checked out the same tip the
        # patch was cut against, so a failed apply means real corruption  -  and a *partial*
        # branch state would silently poison mutation and anti-vacuity verdicts downstream.
        $null = Invoke-Git -Dir $WorktreeDir -GitArgs @('apply', '--index', '--whitespace=nowarn', $patchPath)
        $patchApplied = $true
    }

    # Copy untracked files in, preserving relative paths. CRITICAL: a brand-new class the dev
    # has not `git add`ed yet is exactly the code most in need of QA  -  plain diff misses it.
    $copied = 0
    foreach ($rel in (Get-DevUntrackedFiles -Repo $Repo)) {
        $relWin = $rel -replace '/', '\'
        $src = Join-Path $Repo $relWin
        $dst = Join-Path $WorktreeDir $relWin
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstDir)) {
            New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $copied++
    }

    return [pscustomobject]@{ TipSha = $tipSha; PatchApplied = $patchApplied; UntrackedCopied = $copied }
}

function Get-ProductReposFromConfig {
    # Minimal JSONC -> JSON: strips a '//' line comment only when it starts outside a quoted
    # string (tracked by counting unescaped '"' seen so far on the line). Good enough for this
    # hand-authored config -  none of its string values contain '//' -  a full JSONC parser would
    # be overkill for a file this constrained (same pragmatic-parsing spirit as ConvertFrom-DiffPath).
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config not found: $Path"
    }
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
    if (-not ($cfg.PSObject.Properties.Name -contains 'productRepos')) {
        throw "Config missing 'productRepos': $Path"
    }
    $map = [ordered]@{}
    foreach ($prop in $cfg.productRepos.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
    return $map
}

function Get-WorkspaceWorktreeDirs {
    # Enumerates workspace/<repoSlug>/<branchSlug>/worktree dirs (the only place worktrees live).
    $found = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $script:WorkspaceRoot -PathType Container) {
        foreach ($repoDir in (Get-ChildItem -LiteralPath $script:WorkspaceRoot -Directory -ErrorAction SilentlyContinue)) {
            foreach ($branchDir in (Get-ChildItem -LiteralPath $repoDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                $wt = Join-Path $branchDir.FullName 'worktree'
                if (Test-Path -LiteralPath $wt -PathType Container) { $found.Add($wt) }
            }
        }
    }
    return ,@($found)
}

function Restore-StrykerBackups {
    # WHY: Stryker.NET backs each original assembly up as <name>.dll.stryker-unchanged and its
    # Restore() is NOT in a finally (verified)  -  a crash mid-run leaves the MUTATED dll live.
    # Restoring the backup over the sibling dll (then deleting the backup) guarantees a
    # warm-started worktree never executes tests against a stranded mutant.
    param([Parameter(Mandatory = $true)][string]$Root)
    $restored = 0
    foreach ($bak in (Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.dll.stryker-unchanged' -ErrorAction SilentlyContinue)) {
        $target = $bak.FullName.Substring(0, $bak.FullName.Length - '.stryker-unchanged'.Length)
        Copy-Item -LiteralPath $bak.FullName -Destination $target -Force
        Remove-Item -LiteralPath $bak.FullName -Force
        $restored++
    }
    return $restored
}

# ---------------------------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------------------------

function Get-GitWorktreeEntries {
    # Parses `git worktree list --porcelain` into {Path, Branch} entries. Branch is $null for a
    # detached entry  -  which is exactly what every one of agentQ's OWN worktrees under
    # workspace/ always is (-Ensure always leaves them detached), so they're naturally excluded
    # from -DetectRepo's candidates without needing a separate path-prefix filter.
    param([Parameter(Mandatory = $true)][string]$Dir)
    $lines = Invoke-Git -Dir $Dir -GitArgs @('worktree', 'list', '--porcelain')
    $entries = New-Object System.Collections.Generic.List[object]
    $cur = $null
    foreach ($line in $lines) {
        if ($line -match '^worktree (.+)$') {
            if ($null -ne $cur) { $entries.Add($cur) }
            $cur = [pscustomobject]@{ Path = $Matches[1]; Branch = $null }
        }
        elseif ($line -match '^branch refs/heads/(.+)$') {
            if ($null -ne $cur) { $cur.Branch = $Matches[1] }
        }
    }
    if ($null -ne $cur) { $entries.Add($cur) }
    return $entries
}

function Invoke-ModeDetectRepo {
    # WHY this exists: the precondition is "the branch is already checked out in one of the
    # registered repos" (CLAUDE.md), so the developer doesn't need to NAME the repo at all -
    # agentQ can find it by looking at what's actually checked out. Runs before -Heal/any
    # manifest -  there is no workspaceDir yet to write a file into, so the result IS the one
    # stdout line (compact JSON), not a file. See CONTRACTS.md.
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { throw '-DetectRepo requires -ConfigPath' }
    $repos = Get-ProductReposFromConfig -Path $ConfigPath

    # -RepoFilter narrows the scan to one already-known repo. It takes the EXACT productRepos
    # key, not a fragment: resolving "payroll" -> "e-conomic/payroll-poc" is the orchestrator's
    # job (it already has the config loaded to validate an explicit repo argument) -  duplicating
    # fragment-matching here would just be a second, divergeable copy of that logic.
    if (-not [string]::IsNullOrWhiteSpace($RepoFilter)) {
        if (-not ($repos.Contains($RepoFilter))) {
            throw "-RepoFilter '$RepoFilter' is not a key in productRepos: $ConfigPath"
        }
        $filtered = [ordered]@{}
        $filtered[$RepoFilter] = $repos[$RepoFilter]
        $repos = $filtered
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    $skipped    = New-Object System.Collections.Generic.List[object]

    # -WorktreePath is a direct override: the developer already knows exactly which directory
    # they mean, so skip branch/hint matching entirely -  just confirm it's really a worktree of
    # one of the (possibly -RepoFilter narrowed) registered repos, and hand it straight back.
    if (-not [string]::IsNullOrWhiteSpace($WorktreePath)) {
        if (-not (Test-PathSafe -Path $WorktreePath)) {
            throw "-WorktreePath does not exist: $WorktreePath"
        }
        $normalizedTarget = Get-NormalizedPath -Path $WorktreePath
        foreach ($slug in $repos.Keys) {
            $path = $repos[$slug]
            if (-not (Test-PathSafe -Path $path)) { continue }
            $null = Invoke-Git -Dir $path -GitArgs @('rev-parse', '--is-inside-work-tree') -AllowFail
            if ($script:LastGitExit -ne 0) { continue }
            foreach ($wtEntry in (Get-GitWorktreeEntries -Dir $path)) {
                if ((Get-NormalizedPath -Path $wtEntry.Path) -eq $normalizedTarget) {
                    $branchOut = $wtEntry.Branch
                    if ($null -eq $branchOut) { $branchOut = '(detached)' }
                    $candidates.Add([ordered]@{ repoSlug = $slug; repoPath = $wtEntry.Path; branch = $branchOut; matchedBy = 'explicit-worktree-path' })
                }
            }
        }
        if ($candidates.Count -eq 0) {
            $skipped.Add([ordered]@{ repoSlug = $null; repoPath = $WorktreePath; reason = 'not a worktree of any registered productRepos entry' })
        }
        $result = [ordered]@{ candidates = $candidates; skipped = $skipped }
        Write-Output ($result | ConvertTo-Json -Depth 6 -Compress)
        return
    }

    $defaultBranchRx = '^(main|master|develop)$'
    $hintGiven = -not [string]::IsNullOrWhiteSpace($Hint)

    foreach ($slug in $repos.Keys) {
        $path = $repos[$slug]
        if (-not (Test-PathSafe -Path $path)) {
            $skipped.Add([ordered]@{ repoSlug = $slug; repoPath = $path; reason = 'path not found on this machine' })
            continue
        }
        $null = Invoke-Git -Dir $path -GitArgs @('rev-parse', '--is-inside-work-tree') -AllowFail
        if ($script:LastGitExit -ne 0) {
            $skipped.Add([ordered]@{ repoSlug = $slug; repoPath = $path; reason = 'not a git repository' })
            continue
        }
        # WHY scan ALL of this repo's worktrees, not just $path's own HEAD: `git worktree list`
        # is repo-wide (shared .git admin dir) regardless of which worktree you run it from
        # (verified) -  so a developer who ran `git worktree add ../payroll-poc-EC-8876
        # feature/EC-8876` gets found even though only the ORIGINAL path is registered in
        # productRepos. Each matching worktree becomes its own candidate, carrying ITS OWN path
        # (not the registered one)  -  that's what -EnsureWorkspace needs to target the right
        # working directory.
        foreach ($wtEntry in (Get-GitWorktreeEntries -Dir $path)) {
            if ($null -eq $wtEntry.Branch) { continue }   # detached (incl. agentQ's own worktrees)
            $branch = $wtEntry.Branch
            $wtPath = $wtEntry.Path

            $matchedBy = $null
            if ($hintGiven) {
                if ($branch -match [regex]::Escape($Hint)) {
                    $matchedBy = 'hint-in-branch-name'
                }
                else {
                    # WHY basename, not the true git-internal worktree name (which porcelain output
                    # doesn't expose): git names a worktree's admin dir after the basename of the
                    # path given to `worktree add` by default, so this is right except on the rare
                    # collision-renamed case  -  which would still match via path/branch anyway.
                    # Lets a developer say "--worktree payroll-poc-EC-8876" instead of the full path.
                    $wtName = Split-Path -Leaf $wtPath
                    if ($wtName -match [regex]::Escape($Hint)) {
                        $matchedBy = 'hint-in-worktree-name'
                    }
                    else {
                        # WHY only 5: a cheap routing check, not intake's real ticket-key extraction
                        # (qa-intake does that properly in Phase 1, once the repo is already resolved).
                        $subjects = Invoke-Git -Dir $wtPath -GitArgs @('log', '-5', '--format=%s', 'HEAD') -AllowFail
                        if ($script:LastGitExit -eq 0 -and (($subjects -join "`n") -match [regex]::Escape($Hint))) {
                            $matchedBy = 'hint-in-recent-commit'
                        }
                    }
                }
                if ($null -eq $matchedBy) { continue }   # hint given but this worktree doesn't match
            }
            elseif ($branch -match $defaultBranchRx) {
                continue   # no hint given -  only a worktree sitting on a non-default (feature) branch counts
            }
            else {
                $matchedBy = 'non-default-branch-checked-out'
            }

            $candidates.Add([ordered]@{ repoSlug = $slug; repoPath = $wtPath; branch = $branch; matchedBy = $matchedBy })
        }
    }

    # WHY no @() wrap: on this machine/build, `@(<List[object] instance>)` throws
    # "Argument types do not match" (a narrow, empirically-confirmed PS 5.1 quirk  -  List[string]/
    # List[psobject]/ArrayList/.ToArray() are all unaffected). ConvertTo-Json renders a bare
    # List[object] as a correct JSON array at 0/1/N items regardless, so the wrap is unnecessary here.
    $result = [ordered]@{ candidates = $candidates; skipped = $skipped }
    Write-Output ($result | ConvertTo-Json -Depth 6 -Compress)
}

function Invoke-ModeEnsureWorkspace {
    if ([string]::IsNullOrWhiteSpace($RepoSlug)) { throw '-EnsureWorkspace requires -RepoSlug' }
    if ([string]::IsNullOrWhiteSpace($Branch))   { throw '-EnsureWorkspace requires -Branch' }
    if ([string]::IsNullOrWhiteSpace($RepoPath)) { throw '-EnsureWorkspace requires -RepoPath' }
    $repo = (Resolve-Path -LiteralPath $RepoPath).ProviderPath
    $null = Invoke-Git -Dir $repo -GitArgs @('rev-parse', '--is-inside-work-tree')

    # Slugs per CONTRACTS.md: config key '/'->'__'; branch: anything outside [A-Za-z0-9._-] -> '-'
    # (example: feature/EC-1234-vat-rounding -> feature-EC-1234-vat-rounding). The extra sweep on
    # the repo slug guards against config keys containing other filesystem-unsafe characters.
    $repoDirSlug   = ($RepoSlug -replace '/', '__') -replace '[^A-Za-z0-9._-]', '-'
    $branchDirSlug = $Branch -replace '[^A-Za-z0-9._-]', '-'
    $workspaceDir  = Join-Path (Join-Path $script:WorkspaceRoot $repoDirSlug) $branchDirSlug
    if (-not (Test-Path -LiteralPath $workspaceDir)) {
        New-Item -ItemType Directory -Force -Path $workspaceDir | Out-Null
    }

    # baseSha is pinned from HEAD, so if the checkout is on a different branch than the caller
    # believes, the whole run silently reviews the wrong code  -  warn loudly (stderr) but proceed:
    # agentQ reviews "whatever the local checkout has checked out" by design.
    $headRef = (Invoke-Git -Dir $repo -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD'))[0]
    if ($headRef -ne $Branch) {
        Write-Warning "Checkout at '$repo' is on '$headRef', not '$Branch'; baseSha will be pinned from HEAD."
    }

    # Fresh refs BEFORE pinning the merge-base. WHY fail-hard on fetch: proceeding with stale
    # refs can pin a wrong baseSha, which mis-scopes every diff-based phase silently  - 
    # honesty over completeness says fail loud instead.
    $null = Invoke-Git -Dir $repo -GitArgs @('fetch', 'origin')
    $fetchedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    # Base ref: origin/HEAD when the clone knows it; otherwise the first of main/master/develop
    # that actually exists (some clones never had `remote set-head` run).
    $baseRef = $null
    $symRef = Invoke-Git -Dir $repo -GitArgs @('symbolic-ref', 'refs/remotes/origin/HEAD') -AllowFail
    if ($script:LastGitExit -eq 0 -and $symRef.Count -gt 0) {
        $baseRef = $symRef[0] -replace '^refs/remotes/', ''
    }
    else {
        foreach ($candidate in @('origin/main', 'origin/master', 'origin/develop')) {
            $null = Invoke-Git -Dir $repo -GitArgs @('rev-parse', '--verify', '--quiet', $candidate) -AllowFail
            if ($script:LastGitExit -eq 0) { $baseRef = $candidate; break }
        }
    }
    if ($null -eq $baseRef) {
        throw "Could not resolve a base ref in $repo (origin/HEAD unset and none of origin/main|master|develop exist)"
    }

    # Pin ONCE; every later phase reads this value from the manifest and never re-resolves.
    $baseSha = (Invoke-Git -Dir $repo -GitArgs @('merge-base', 'HEAD', $baseRef))[0]
    if ($baseSha -notmatch '^[0-9a-f]{40}$') { throw "merge-base returned unexpected value '$baseSha'" }

    $worktreeDir = Join-Path $workspaceDir 'worktree'
    $manifestObj = [ordered]@{
        repoSlug     = $RepoSlug          # the config key verbatim (may contain '/'), per CONTRACTS.md
        repoPath     = $repo
        branch       = $Branch
        baseRef      = $baseRef
        baseSha      = $baseSha
        fetchedAt    = $fetchedAt
        workspaceDir = $workspaceDir
        worktreeDir  = $worktreeDir
        ticketKey    = $TicketKey
    }

    $manifestPath = Join-Path $workspaceDir 'run-manifest.json'
    if (-not [string]::IsNullOrWhiteSpace($Manifest)) {
        # Optional explicit output path  -  but our write-fence is workspace/, so refuse anything else.
        $requested = [System.IO.Path]::GetFullPath($Manifest)
        $fence = (Get-NormalizedPath -Path $script:WorkspaceRoot) + '\'
        if (-not (Get-NormalizedPath -Path $requested).StartsWith($fence)) {
            throw "-Manifest output for -EnsureWorkspace must live under $($script:WorkspaceRoot) (got: $Manifest)"
        }
        $manifestPath = $requested
        $mDir = Split-Path -Parent $manifestPath
        if (-not (Test-Path -LiteralPath $mDir)) { New-Item -ItemType Directory -Force -Path $mDir | Out-Null }
    }

    Write-JsonFile -Object $manifestObj -Path $manifestPath
    Write-Output "EnsureWorkspace: $manifestPath (branch $Branch, base $baseRef @ $($baseSha.Substring(0, 12)))"
}

function Invoke-ModeDiffSet {
    $m = Read-RunManifest -Path $Manifest
    $repo    = $m.repoPath
    $baseSha = $m.baseSha

    # Paths *under* these directories are never QA targets. Trailing '/' keeps a file literally
    # named 'dist' in scope. -match is case-insensitive by default (Bin/ vs bin/ on Windows).
    $excludeRx = '(^|/)(\.git|bin|obj|node_modules|dist)/'

    # --- statuses (rename-aware) --- -z gives NUL-separated, unquoted paths.
    $rawNs = (& git -C $repo diff --name-status --no-color -M --diff-filter=ACMR -z $baseSha) -join ''
    if ($LASTEXITCODE -ne 0) { throw "git diff --name-status failed in $repo (exit $LASTEXITCODE)" }
    $tokens = @($rawNs -split "`0" | Where-Object { $_ -ne '' })
    $entries = New-Object System.Collections.Generic.List[object]
    $i = 0
    while ($i -lt $tokens.Count) {
        $letter = $tokens[$i].Substring(0, 1)  # strip similarity score off R100 / C75
        if ($letter -eq 'R' -or $letter -eq 'C') {
            # rename/copy records are <status> NUL <old> NUL <new>; consumers only care about
            # the new-side path (hunks are reported against the new side too).
            $entries.Add([pscustomobject]@{ Path = $tokens[$i + 2]; Status = $letter })
            $i += 3
        }
        else {
            $entries.Add([pscustomobject]@{ Path = $tokens[$i + 1]; Status = $letter })
            $i += 2
        }
    }

    # --- hunks (new side) --- one -U0 pass; associate @@ headers with the current +++ path.
    $diffLines = Invoke-Git -Dir $repo -GitArgs @('diff', '--unified=0', '--no-color', '-M', '--diff-filter=ACMR', $baseSha)
    $hunksByPath = @{}
    $current = $null
    $prev = ''
    foreach ($line in $diffLines) {
        # WHY the prev-line guard: with -U0 an *added content line* whose text starts with
        # "++ " renders as "+++ ..." and would fake a file header, misattributing every
        # following hunk. Real headers always appear as a "--- " / "+++ " pair.
        if ($line -match '^\+\+\+ ' -and $prev -match '^--- ') {
            $rawPath = $line.Substring(4)
            if ($rawPath.Trim() -eq '/dev/null') {
                $current = $null   # cannot occur under --diff-filter=ACMR, but stay safe
            }
            else {
                $current = ConvertFrom-DiffPath -Raw $rawPath
                if (-not $hunksByPath.ContainsKey($current)) {
                    $hunksByPath[$current] = New-Object System.Collections.Generic.List[object]
                }
            }
        }
        elseif ($line -match '^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@') {
            if ($null -ne $current) {
                $newStart = [int]$Matches[1]
                $newCount = 1                                   # "+c" with no count means 1 line
                if ($Matches.ContainsKey(2)) { $newCount = [int]$Matches[2] }
                # newCount 0 (pure deletion points) is kept as parsed: consumers scope on the
                # new side and can ignore zero-width hunks themselves  -  dropping data here
                # would make the artifact lie about what the diff contained.
                $hunksByPath[$current].Add([ordered]@{ newStart = $newStart; newCount = $newCount })
            }
        }
        $prev = $line
    }

    $files = New-Object System.Collections.Generic.List[object]
    $hunkTotal = 0
    foreach ($e in $entries) {
        if ($e.Path -match $excludeRx) { continue }
        # WHY no @() wrap on the List[object] branch: see the note by $result in
        # Invoke-ModeDetectRepo  -  `@(<List[object]>)` throws on this PS 5.1 build.
        $hunks = @()
        if ($hunksByPath.ContainsKey($e.Path)) { $hunks = $hunksByPath[$e.Path] }
        $hunkTotal += $hunks.Count
        $files.Add([ordered]@{ path = $e.Path; status = $e.Status; hunks = $hunks })
    }

    # CRITICAL: plain `git diff` misses untracked files  -  a developer's brand-new class is
    # exactly the code most in need of QA, so it is reported explicitly.
    # WHY assign before filtering (not `@(Get-DevUntrackedFiles ... | Where-Object {...})` in one
    # statement): empirically confirmed on this PS 5.1 build, wrapping a LIVE call to a function
    # that returns via the ,@() comma-wrap (Get-DevUntrackedFiles does, to survive its own return
    # boundary) directly in `@(... | Where-Object ...)` corrupts ConvertTo-Json's output into
    # `{"value":[...],"Count":N}` instead of a flat array  -  a silent artifact-corrupting bug, not
    # a cosmetic one. Settling the call into a variable first avoids it; @() around that is fine.
    $allUntracked = Get-DevUntrackedFiles -Repo $repo
    $untracked = @($allUntracked | Where-Object { $_ -notmatch $excludeRx })

    $diffSet = [ordered]@{
        baseSha   = $baseSha
        files     = $files
        untracked = $untracked
        # Initialized all-false: classification is judgment work  -  qa-intake fills these in.
        # The script only guarantees the keys exist so consumers never null-check.
        levels    = [ordered]@{ backend = $false; frontend = $false; apiSurface = $false }
    }

    if (-not (Test-Path -LiteralPath $m.workspaceDir)) {
        New-Item -ItemType Directory -Force -Path $m.workspaceDir | Out-Null
    }
    $outPath = Join-Path $m.workspaceDir 'diff-set.json'
    Write-JsonFile -Object $diffSet -Path $outPath
    Write-Output "DiffSet: $($files.Count) changed file(s), $hunkTotal hunk(s), $($untracked.Count) untracked -> $outPath"
}

function Invoke-ModeEnsure {
    $m = Read-RunManifest -Path $Manifest
    $repo = $m.repoPath
    $wt   = $m.worktreeDir
    $ws   = $m.workspaceDir

    # WHY a worktree at all: mutation and anti-vacuity REWRITE sources and flip refs  -  that must
    # never touch the dev's tree. And Stryker's Restore() is not crash-safe (verified): a crash
    # strands mutated DLLs behind *.dll.stryker-unchanged backups, so the blast radius has to be
    # a disposable dir under workspace/, never the product repo.
    $reused = $false
    if (Test-Path -LiteralPath $wt -PathType Container) {
        $null = Invoke-Git -Dir $wt -GitArgs @('status', '--porcelain') -AllowFail
        if ($script:LastGitExit -eq 0) {
            $reused = $true
        }
        else {
            # Broken husk (admin dir gone, corrupt .git link)  -  remove and rebuild from scratch.
            Remove-Item -LiteralPath $wt -Recurse -Force
        }
    }
    if (-not $reused) {
        if (-not (Test-Path -LiteralPath $ws)) { New-Item -ItemType Directory -Force -Path $ws | Out-Null }
        # Prune first: git refuses to add a worktree at a path it still holds stale metadata for
        # (exactly the state a crashed prior run leaves behind).
        $null = Invoke-Git -Dir $repo -GitArgs @('worktree', 'prune')
        $null = Invoke-Git -Dir $repo -GitArgs @('worktree', 'add', '--detach', $wt, 'HEAD')
    }

    # WHY a junction, not a copy: node_modules is gitignored (never checked out into a new
    # worktree at all -- confirmed: `git worktree add` leaves it entirely absent, so `nx`/`jest`
    # fail outright with "Could not find Nx modules") and is commonly 1GB+ (verified: 1.3GB on
    # e-conomic/client) -- copying it per run would violate fast-by-construction. A junction needs
    # no admin/Developer-Mode elevation (unlike a symbolic link) and survives `git clean -fd`
    # (clean respects .gitignore by default, so an ignored dir is never swept). Shared, not
    # copied, so a branch that changes package.json/the lockfile would run against stale deps --
    # an accepted limitation for now, not silently wrong: dependency-changing branches are rare
    # and the risk is a false-green from an out-of-date install, not a crash.
    $repoNodeModules = Join-Path $repo 'node_modules'
    $wtNodeModules   = Join-Path $wt 'node_modules'
    if ((Test-Path -LiteralPath $repoNodeModules -PathType Container) -and
        -not (Test-Path -LiteralPath $wtNodeModules)) {
        $null = New-Item -ItemType Junction -Path $wtNodeModules -Target $repoNodeModules
    }

    # Reuse path cleans first (stale generated tests / mutation leftovers from the previous run);
    # a freshly-added worktree is already pristine.
    $state = Restore-BranchState -Repo $repo -WorktreeDir $wt -WorkspaceDir $ws -CleanFirst:$reused

    $mode = 'created'
    if ($reused) { $mode = 'reused' }
    $patch = 'none'
    if ($state.PatchApplied) { $patch = 'applied' }
    Write-Output "Ensure: worktree $mode at $wt @ $($state.TipSha.Substring(0, 12)); uncommitted diff $patch; $($state.UntrackedCopied) untracked file(s) copied"
}

function Invoke-ModeFlipToBase {
    $m = Read-RunManifest -Path $Manifest
    $wt = $m.worktreeDir
    if (-not (Test-Path -LiteralPath $wt -PathType Container)) {
        throw "-FlipToBase: worktree missing at $wt (run -Ensure first)"
    }

    # Anti-vacuity needs two things at once: tracked state == PURE base, and the generated tests
    # (untracked, written only into the worktree) still present so they can execute against base.
    #
    # Step 1  -  remove the DEV's untracked copies. They are branch state: SDK-style csproj globs
    # (*.cs) would otherwise compile a not-yet-added new class into the "base" build, letting a
    # generated test pass vacuously against base  -  the exact failure anti-vacuity exists to catch.
    $removed = 0
    foreach ($rel in (Get-DevUntrackedFiles -Repo $m.repoPath)) {
        $p = Join-Path $wt ($rel -replace '/', '\')
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            Remove-Item -LiteralPath $p -Force
            $removed++
        }
    }

    # Step 2  -  force tracked files (including files staged in by `apply --index`) to baseSha.
    # WHY --force and NOT `clean -fd`: --force discards tracked modifications and deletes
    # tracked-but-not-in-base files while leaving untracked files (the generated tests) alone;
    # clean -fd would delete the very tests anti-vacuity is about to run.
    $null = Invoke-Git -Dir $wt -GitArgs @('checkout', '--force', '--detach', $m.baseSha)

    Write-Output "FlipToBase: worktree at base $($m.baseSha.Substring(0, 12)); removed $removed branch-untracked file(s); generated tests preserved"
}

function Invoke-ModeFlipToBranch {
    $m = Read-RunManifest -Path $Manifest
    $wt = $m.worktreeDir
    if (-not (Test-Path -LiteralPath $wt -PathType Container)) {
        throw "-FlipToBranch: worktree missing at $wt (run -Ensure first)"
    }

    # Same restore sequence as -Ensure but WITHOUT `clean -fd`: at this point the worktree holds
    # the generated tests (untracked). Cleaning would destroy the files Phase 8 offers the
    # developer to keep, plus the warm state the next run starts from.
    $state = Restore-BranchState -Repo $m.repoPath -WorktreeDir $wt -WorkspaceDir $m.workspaceDir

    $patch = 'none'
    if ($state.PatchApplied) { $patch = 'applied' }
    Write-Output "FlipToBranch: worktree at branch tip $($state.TipSha.Substring(0, 12)); uncommitted diff $patch; $($state.UntrackedCopied) untracked file(s) copied"
}

function Invoke-ModeHeal {
    if ([string]::IsNullOrWhiteSpace($RepoPath)) { throw '-Heal requires -RepoPath' }
    $repo = (Resolve-Path -LiteralPath $RepoPath).ProviderPath
    $null = Invoke-Git -Dir $repo -GitArgs @('rev-parse', '--is-inside-work-tree')

    # 1) Drop the repo's stale worktree bookkeeping for dirs that no longer exist.
    $null = Invoke-Git -Dir $repo -GitArgs @('worktree', 'prune')

    # 2) Worktrees the repo still lists (post-prune), normalized for identity comparison.
    $registered = @{}
    foreach ($line in (Invoke-Git -Dir $repo -GitArgs @('worktree', 'list', '--porcelain'))) {
        if ($line -match '^worktree (.+)$') {
            $registered[(Get-NormalizedPath -Path $Matches[1])] = $true
        }
    }
    # WHY --git-common-dir (git >=2.31 for --path-format=absolute), not --absolute-git-dir: when
    # $repo is a LINKED worktree rather than the main one (a developer's own `git worktree add`
    # sibling  -  see -DetectRepo), --absolute-git-dir returns THAT worktree's own per-worktree
    # admin subdir (<main>/.git/worktrees/<name>), not the shared common .git where agentQ's OWN
    # worktrees for this repo actually live  -  every one of them would then look "foreign" and
    # never get healed. --git-common-dir is identical from every worktree of the repo (verified).
    $repoGitDir = Get-NormalizedPath -Path ((Invoke-Git -Dir $repo -GitArgs @('rev-parse', '--path-format=absolute', '--git-common-dir'))[0])

    # 3) Sweep every workspace/<repoSlug>/<branchSlug>/worktree dir. Ownership matters: the
    # workspace also holds OTHER product repos' worktrees, which this repo (correctly) does not
    # list  -  those must survive. Ownership is decided by the worktree's .git link
    # ("gitdir: <admin path inside the owning repo's .git>").
    $removedDirs = 0
    $survivors = New-Object System.Collections.Generic.List[string]
    foreach ($wt in (Get-WorkspaceWorktreeDirs)) {
        if ($registered.ContainsKey((Get-NormalizedPath -Path $wt))) {
            $survivors.Add($wt)   # healthy and ours
            continue
        }
        $gitdir = $null
        $dotGit = Join-Path $wt '.git'
        if (Test-Path -LiteralPath $dotGit -PathType Leaf) {
            $first = Get-Content -LiteralPath $dotGit -TotalCount 1
            if ($null -ne $first -and $first -match '^gitdir:\s*(.+)$') {
                $g = $Matches[1].Trim()
                if (-not [System.IO.Path]::IsPathRooted($g)) { $g = Join-Path $wt $g }
                $gitdir = Get-NormalizedPath -Path $g
            }
        }
        if ($null -ne $gitdir -and (Test-Path -LiteralPath $gitdir) -and -not $gitdir.StartsWith($repoGitDir + '\')) {
            # Live link into some OTHER repo's .git  -  another repo's healthy worktree; not ours to heal.
            $survivors.Add($wt)
            continue
        }
        # Orphan: linked to this repo but no longer registered, or its admin dir is gone, or the
        # .git link itself is missing  -  a crashed run's husk. Remove it; -Ensure rebuilds cheaply.
        Remove-Item -LiteralPath $wt -Recurse -Force
        $removedDirs++
    }

    # 4) Stryker crash-safety gap (see Restore-StrykerBackups): heal every surviving workspace
    # worktree, whichever repo owns it  -  a stranded mutant is poison regardless of owner.
    $restored = 0
    foreach ($wt in $survivors) {
        $restored += Restore-StrykerBackups -Root $wt
    }

    Write-Output "Heal: pruned stale worktree metadata; removed $removedDirs orphaned worktree dir(s); restored $restored stryker-unchanged backup(s)"
}

function Invoke-ModeVerify {
    $m = Read-RunManifest -Path $Manifest
    $wt = $m.worktreeDir
    $parts = New-Object System.Collections.Generic.List[string]
    $findings = 0

    if (Test-Path -LiteralPath $wt -PathType Container) {
        $status = Invoke-Git -Dir $wt -GitArgs @('status', '--porcelain')
        $untrackedN = @($status | Where-Object { $_ -match '^\?\?' }).Count
        $dirtyN = $status.Count - $untrackedN
        # Untracked lines are expected (generated tests + dev's untracked copies), and tracked-
        # dirty lines are expected while branch state is applied  -  so we report counts for the
        # orchestrator to eyeball instead of guessing intent and mislabeling a healthy state.
        $parts.Add("worktree status $($status.Count) line(s) [$dirtyN tracked-dirty, $untrackedN untracked]")

        $wtOrphans = @(Get-ChildItem -LiteralPath $wt -Recurse -File -Filter '*.stryker-unchanged' -ErrorAction SilentlyContinue).Count
        $findings += $wtOrphans
        $parts.Add("stryker-unchanged in worktree: $wtOrphans")
    }
    else {
        # Not a failure: the mutation lane may have been skipped/denied, so -Ensure never ran.
        $parts.Add('worktree absent (mutation lane never ran)')
    }

    # We never write into the product repo, so the only leftover we could conceivably have caused
    # there is a Stryker backup from an isolation violation  -  assert there are none, and hand the
    # orchestrator the repo's own status line count to eyeball (dev churn makes non-zero normal).
    $repoOrphans = @(Get-ChildItem -LiteralPath $m.repoPath -Recurse -File -Filter '*.stryker-unchanged' -ErrorAction SilentlyContinue).Count
    $findings += $repoOrphans
    $parts.Add("stryker-unchanged in product repo: $repoOrphans")
    $repoStatus = Invoke-Git -Dir $m.repoPath -GitArgs @('status', '--porcelain')
    $parts.Add("product repo status $($repoStatus.Count) line(s)")

    # Findings are reported in the summary line, not the exit code: exit 0 = script ran.
    $verdict = 'OK'
    if ($findings -gt 0) { $verdict = "FINDINGS ($findings)" }
    Write-Output ("Verify: $verdict - " + ($parts -join '; '))
}

# ---------------------------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------------------------

try {
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git not found on PATH' }

    $modes = @()
    if ($DetectRepo)      { $modes += 'DetectRepo' }
    if ($Heal)            { $modes += 'Heal' }
    if ($EnsureWorkspace) { $modes += 'EnsureWorkspace' }
    if ($DiffSet)         { $modes += 'DiffSet' }
    if ($Ensure)          { $modes += 'Ensure' }
    if ($FlipToBase)      { $modes += 'FlipToBase' }
    if ($FlipToBranch)    { $modes += 'FlipToBranch' }
    if ($Verify)          { $modes += 'Verify' }
    if ($modes.Count -ne 1) {
        throw "Exactly one mode switch is required: -DetectRepo | -Heal | -EnsureWorkspace | -DiffSet | -Ensure | -FlipToBase | -FlipToBranch | -Verify (got: $(if ($modes.Count -eq 0) { 'none' } else { $modes -join ', ' }))"
    }

    switch ($modes[0]) {
        'DetectRepo'      { Invoke-ModeDetectRepo }
        'Heal'            { Invoke-ModeHeal }
        'EnsureWorkspace' { Invoke-ModeEnsureWorkspace }
        'DiffSet'         { Invoke-ModeDiffSet }
        'Ensure'          { Invoke-ModeEnsure }
        'FlipToBase'      { Invoke-ModeFlipToBase }
        'FlipToBranch'    { Invoke-ModeFlipToBranch }
        'Verify'          { Invoke-ModeVerify }
    }
    exit 0
}
catch {
    # Write-Error would re-throw under $ErrorActionPreference='Stop'; write stderr directly.
    # The stack trace goes to stderr too  -  non-zero exit means the script itself broke, and
    # the orchestrator needs the location, not just the message.
    [Console]::Error.WriteLine("worktree.ps1 FAILED: $($_.Exception.Message)")
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    exit 1
}
