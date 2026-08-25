<#
.SYNOPSIS
    agentQ contract lane: OpenAPI schema diff, Ocelot route-config diff, and Pact
    verification environment prep. Writes contract-report.json per scripts/CONTRACTS.md.

.DESCRIPTION
    Modes:
      schema-diff  -- diff two OpenAPI documents with the pinned oasdiff binary.
                     Committed-spec path (the default): working tree vs
                     `git show <baseSha>:<path>` per spec  -  the path(s) come from
                     -SpecPath when given, otherwise auto-derived from the
                     workspace's diff-set.json (changed/untracked openapi*/swagger*
                     files; several specs are each diffed and merged; none changed
                     -> honest skip). With -BaseSpec/-RevSpec: boot-captured
                     documents produced by the orchestrator or test fixtures --
                     this script never boots the app itself.
      ocelot-diff  -- ApiGateway: its API surface IS its Ocelot route config, so the
                     contract diff is a structural JSON diff of changed
                     *.ocelot.json files (base = git show, rev = working tree).
      pact-verify  -- does NOT run PactNet (that lives in generated test code).
                     Emits the env-var names the orchestrator must STRIP from any
                     child `dotnet test` (publish-enabling vars -- pact results are
                     published from CI only, never a local run), probes broker
                     reachability read-only, and records the pact section of the
                     artifact from -PactResults if provided.

    -EnsureTool downloads the pinned oasdiff release only (no diff run).
    NOTE: the orchestrator asks the developer for consent BEFORE calling this
    script with -EnsureTool -- it is a network install (CLAUDE.md precondition 5:
    consented, never silent).

    Exit code 0 = the script ran (findings live in the JSON artifact, and breaking
    changes are findings, not failures). Non-zero = the script itself failed.
#>
[CmdletBinding()]
param(
    # Path to run-manifest.json (written by the orchestrator at Phase 0).
    [Parameter(Mandatory = $true)]
    [string]$Manifest,

    [ValidateSet('schema-diff', 'ocelot-diff', 'pact-verify')]
    [string]$Mode = 'schema-diff',

    # Explicit paths to boot-captured OpenAPI docs (schema-diff without -SpecPath).
    [string]$BaseSpec,
    [string]$RevSpec,

    # Repo-relative path of a committed OpenAPI spec (schema-diff shortcut).
    [string]$SpecPath,

    # ocelot-diff: which config files constitute the API surface.
    [string]$OcelotGlob = 'config/routes/*.ocelot.json',

    # pact-verify: JSON file with { consumers, failed, unverifiable } produced by
    # the verifier test run; copied verbatim into the artifact's pact section.
    [string]$PactResults,

    # Download/verify the pinned oasdiff binary into tools/ and exit.
    [switch]$EnsureTool
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# WHY: Invoke-WebRequest's progress rendering slows large downloads dramatically
# on Windows PowerShell 5.1; silencing it is the standard mitigation.
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Constants -- the oasdiff version is PINNED: rule ids and level classifications
# differ across oasdiff releases, and a floating binary would let the same
# branch produce different verdicts on different machines (credibility rule:
# same branch, same verdict, twice).
# ---------------------------------------------------------------------------
$script:OasdiffVersion = '1.29.1'
$script:RepoRoot       = Split-Path -Parent $PSScriptRoot
$script:ToolsDir       = Join-Path $script:RepoRoot 'tools'
$script:OasdiffExe     = Join-Path $script:ToolsDir 'oasdiff.exe'
$script:TempDir        = $null   # set after the manifest is read (lives under workspaceDir)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-Prop {
    # StrictMode-safe property access on PSCustomObjects from ConvertFrom-Json --
    # a missing property must yield the default, not a terminating error.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]   # lookup is case-insensitive
    if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function ConvertTo-CompactJson {
    # Canonical single-line JSON for structural comparison of config fragments.
    param($Value)
    if ($null -eq $Value) { return 'null' }
    return (ConvertTo-Json -InputObject $Value -Depth 12 -Compress)
}

function ConvertTo-LevelName {
    # oasdiff has emitted `level` both as a number (ERR=3/WARN=2/INFO=1) and as a
    # string across releases; normalize defensively so a formatter change in the
    # tool can never silently misclassify a breaking change.
    param($Level)
    if ($null -eq $Level) { return 'INFO' }
    $s = ("$Level").Trim().ToUpperInvariant()
    switch ($s) {
        '3'       { return 'ERR' }
        'ERR'     { return 'ERR' }
        'ERROR'   { return 'ERR' }
        '2'       { return 'WARN' }
        'WARN'    { return 'WARN' }
        'WARNING' { return 'WARN' }
        '1'       { return 'INFO' }
        'INFO'    { return 'INFO' }
        # Unknown level: err on the side of human review, never silence.
        default   { return 'WARN' }
    }
}

function Invoke-Native {
    # Run a native exe capturing stdout/stderr via file redirection.
    # WHY not `& exe 2>&1`: PS 5.1 wraps redirected native stderr lines in
    # ErrorRecords, which $ErrorActionPreference='Stop' can promote to terminating
    # errors mid-run; Start-Process file redirection is byte-faithful (matters for
    # UTF-8 spec content -- PowerShell string capture re-decodes with the console
    # codepage and can mangle non-ASCII) and has no error-stream side effects.
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$StdOutFile   # when given, stdout goes straight to this file and is not read back
    )
    $readBack = [string]::IsNullOrEmpty($StdOutFile)
    if ($readBack) {
        $outFile = Join-Path $script:TempDir ('native-out-' + [guid]::NewGuid().ToString('N') + '.txt')
    } else {
        $outFile = $StdOutFile
    }
    $errFile = Join-Path $script:TempDir ('native-err-' + [guid]::NewGuid().ToString('N') + '.txt')

    # Minimal Win32 arg quoting: quote when whitespace/quotes present, escape
    # embedded quotes. Start-Process passes the line to CreateProcess (no shell),
    # so glob characters reach git untouched and git does its own pathspec match.
    $argLine = ($Arguments | ForEach-Object {
        if ($_ -eq '') { '""' }
        elseif ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' }
        else { $_ }
    }) -join ' '

    $p = Start-Process -FilePath $Exe -ArgumentList $argLine -Wait -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $stdout = $null
    if ($readBack) {
        $stdout = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8)
        try { Remove-Item -LiteralPath $outFile -Force -Confirm:$false } catch { }
    }
    $stderr = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8)
    try { Remove-Item -LiteralPath $errFile -Force -Confirm:$false } catch { }

    return [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

function Install-Oasdiff {
    # Idempotent: returns 'already-present' or 'installed'.
    # NOTE: this is a network install. The orchestrator obtains user consent
    # BEFORE calling with -EnsureTool. The on-demand call from schema-diff is a
    # safety net for direct/manual invocation with the tool missing.
    if (Test-Path -LiteralPath $script:OasdiffExe) {
        # Verify the pin, not just presence -- a stale binary from an older setup
        # would change rule ids/levels between machines.
        try {
            $verOut = (& $script:OasdiffExe --version) -join ' '
            if ($LASTEXITCODE -eq 0 -and $verOut -match [regex]::Escape($script:OasdiffVersion)) {
                return 'already-present'
            }
        } catch { }
        # Wrong/corrupt binary: replace it with the pinned release.
        Remove-Item -LiteralPath $script:OasdiffExe -Force -Confirm:$false
    }

    New-Item -ItemType Directory -Force -Path $script:ToolsDir | Out-Null

    # WHY: PS 5.1 does not enable TLS 1.2 by default and github.com requires it.
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

    $asset     = "oasdiff_$($script:OasdiffVersion)_windows_amd64.tar.gz"
    $baseUrl   = "https://github.com/oasdiff/oasdiff/releases/download/v$($script:OasdiffVersion)"
    $archive   = Join-Path $script:ToolsDir $asset
    $checksums = Join-Path $script:ToolsDir 'oasdiff-checksums.txt'

    Invoke-WebRequest -Uri "$baseUrl/$asset" -OutFile $archive -UseBasicParsing
    Invoke-WebRequest -Uri "$baseUrl/checksums.txt" -OutFile $checksums -UseBasicParsing

    # sha256 gate -- fail hard on any mismatch. WHY: supply-chain hygiene for a
    # binary we execute; a tampered or truncated download must never run.
    $expected = $null
    foreach ($line in (Get-Content -LiteralPath $checksums)) {
        if ($line -match ('^\s*([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($asset) + '\s*$')) {
            $expected = $Matches[1]
            break
        }
    }
    if (-not $expected) {
        Remove-Item -LiteralPath $archive, $checksums -Force -Confirm:$false
        throw "checksums.txt from the v$($script:OasdiffVersion) release has no entry for $asset -- refusing to install"
    }
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ($actual -ne $expected) {   # -ne is case-insensitive: hex case differs between tools
        Remove-Item -LiteralPath $archive, $checksums -Force -Confirm:$false
        throw "sha256 mismatch for $asset (expected $expected, got $actual) -- refusing to install"
    }

    # Extract into a scratch dir and move only the exe, keeping tools/ tidy.
    # tar.exe ships with Windows 10+ and handles .tar.gz natively.
    $extractDir = Join-Path $script:ToolsDir 'oasdiff-extract'
    if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force -Confirm:$false }
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
    & tar.exe -xzf $archive -C $extractDir
    if ($LASTEXITCODE -ne 0) { throw "tar.exe failed (exit $LASTEXITCODE) extracting $asset" }

    $exe = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'oasdiff.exe' | Select-Object -First 1
    if ($null -eq $exe) { throw "oasdiff.exe not found inside $asset" }
    Move-Item -LiteralPath $exe.FullName -Destination $script:OasdiffExe -Force

    Remove-Item -LiteralPath $archive, $checksums -Force -Confirm:$false
    Remove-Item -LiteralPath $extractDir -Recurse -Force -Confirm:$false
    return 'installed'
}

function ConvertFrom-OasdiffOutput {
    # Returns @{ Ok = bool; Entries = array }.
    # Success is defined by parseable JSON on stdout -- NEVER by the exit code:
    # oasdiff's docs are inconsistent about default exit behavior (verified), and
    # non-zero exits are EXPECTED when breaking changes exist.
    param($NativeResult)
    $text = $NativeResult.StdOut
    if ($null -ne $text -and $text -match '\S') {
        $t = $text.Trim()
        if ($t -eq 'null') { return @{ Ok = $true; Entries = @() } }
        try {
            $obj = ConvertFrom-Json -InputObject $t
            if ($null -eq $obj) { return @{ Ok = $true; Entries = @() } }
            return @{ Ok = $true; Entries = @($obj) }
        } catch {
            return @{ Ok = $false; Entries = @() }
        }
    }
    # Empty stdout is only a valid "no changes" when the run was otherwise clean;
    # empty stdout + stderr noise/non-zero exit must degrade, never read green.
    if ($NativeResult.ExitCode -eq 0 -and -not ($NativeResult.StdErr -match '\S')) {
        return @{ Ok = $true; Entries = @() }
    }
    return @{ Ok = $false; Entries = @() }
}

function Get-SpecVersionHint {
    # Best-effort extraction of the offending spec version from oasdiff
    # diagnostics, so skipReason can NAME the version (contract requirement).
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $m = [regex]::Match($Text, '(?i)(openapi|swagger)["\s:]*([0-9]+\.[0-9]+(\.[0-9]+)?)')
    if ($m.Success) {
        return ('{0} {1}' -f $m.Groups[1].Value.ToLowerInvariant(), $m.Groups[2].Value)
    }
    return $null
}

function Invoke-OasdiffDiff {
    # Runs `breaking` + `changelog`, returns @{ breaking; warnings; info; skipped; skipReason }.
    param([string]$BaseFile, [string]$RevFile)

    $result = @{ breaking = @(); warnings = @(); info = @(); skipped = $false; skipReason = $null }

    $br = Invoke-Native -Exe $script:OasdiffExe -Arguments @('breaking', $BaseFile, $RevFile, '--format', 'json')
    $parsed = ConvertFrom-OasdiffOutput $br
    if (-not $parsed.Ok) {
        # Parse failure (e.g. unsupported spec version): honest skip, naming the
        # version when it can be extracted from the diagnostics.
        $result.skipped = $true
        $hint = Get-SpecVersionHint ("$($br.StdOut)`n$($br.StdErr)")
        if ($hint) {
            $result.skipReason = "oasdiff could not parse the spec -- unsupported spec version: $hint"
        } else {
            $firstLine = @(($br.StdErr -split "`r?`n") | Where-Object { $_ -match '\S' }) | Select-Object -First 1
            if (-not $firstLine) { $firstLine = "exit code $($br.ExitCode), no diagnostics on stderr" }
            if ($firstLine.Length -gt 300) { $firstLine = $firstLine.Substring(0, 300) }
            $result.skipReason = "oasdiff failed to parse the spec: $firstLine"
        }
        return $result
    }

    # Classification comes from each entry's `level` field, never the exit code.
    foreach ($e in $parsed.Entries) {
        $lvl  = ConvertTo-LevelName (Get-Prop $e 'level')
        $item = [ordered]@{
            ruleId = Get-Prop $e 'id'
            level  = $lvl
            text   = Get-Prop $e 'text'
            path   = Get-Prop $e 'path'
        }
        if ($lvl -eq 'ERR')      { $result.breaking += , $item }
        elseif ($lvl -eq 'WARN') { $result.warnings += , $item }
        else                     { $result.info     += , $item }
    }

    # Info tail from `changelog`. Only INFO-level entries are taken: ERR/WARN
    # already came from `breaking` above -- filtering avoids double-reporting.
    $cl = Invoke-Native -Exe $script:OasdiffExe -Arguments @('changelog', $BaseFile, $RevFile, '--format', 'json')
    $clParsed = ConvertFrom-OasdiffOutput $cl
    if ($clParsed.Ok) {
        foreach ($e in $clParsed.Entries) {
            if ((ConvertTo-LevelName (Get-Prop $e 'level')) -eq 'INFO') {
                $result.info += , [ordered]@{
                    ruleId = Get-Prop $e 'id'
                    level  = 'INFO'
                    text   = Get-Prop $e 'text'
                    path   = Get-Prop $e 'path'
                }
            }
        }
    }
    # A changelog parse failure is deliberately non-fatal: the breaking
    # classification (the part the verdict depends on) already succeeded; the
    # info tail just stays empty.
    return $result
}

function ConvertFrom-OcelotConfig {
    param([string]$JsonText)
    if ([string]::IsNullOrWhiteSpace($JsonText)) { return $null }
    try { return (ConvertFrom-Json -InputObject $JsonText) } catch { return $null }
}

function Get-OcelotRouteMap {
    # Route identity = UpstreamPathTemplate + UpstreamHttpMethod pair: that pair
    # is what a consumer calls, so it is the unit that can "break".
    param($ConfigObject)
    $map = @{}
    foreach ($r in @(Get-Prop $ConfigObject 'Routes' @())) {
        $tpl = Get-Prop $r 'UpstreamPathTemplate' ''
        if ([string]::IsNullOrEmpty($tpl)) { continue }
        $methods = @(Get-Prop $r 'UpstreamHttpMethod' @())
        # Ocelot semantics: an empty/missing method list matches every verb.
        if ($methods.Count -eq 0) { $methods = @('*') }
        foreach ($m in $methods) {
            $key = ('{0} {1}' -f ("$m").ToUpperInvariant(), $tpl)
            if (-not $map.ContainsKey($key)) { $map[$key] = $r }
        }
    }
    return $map
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    if (-not (Test-Path -LiteralPath $Manifest)) { throw "run manifest not found: $Manifest" }
    $man          = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
    $repoPath     = Get-Prop $man 'repoPath'
    $baseSha      = Get-Prop $man 'baseSha'
    $workspaceDir = Get-Prop $man 'workspaceDir'

    if ($EnsureTool) {
        # Tool bootstrap only -- no diff, no artifact. Consent was collected by the
        # orchestrator before this call (network install).
        $status = Install-Oasdiff
        Write-Output ("contract-check: oasdiff v{0} {1} at {2} (sha256 verified against release checksums.txt)" -f `
            $script:OasdiffVersion, $status, $script:OasdiffExe)
        exit 0
    }

    if (-not $workspaceDir) { throw "manifest is missing workspaceDir" }
    New-Item -ItemType Directory -Force -Path $workspaceDir | Out-Null
    $script:TempDir = Join-Path $workspaceDir 'contract-tmp'
    New-Item -ItemType Directory -Force -Path $script:TempDir | Out-Null
    $artifactPath = Join-Path $workspaceDir 'contract-report.json'

    # Artifact skeleton (CONTRACTS.md shape -- every field always present).
    $artifactMode = $Mode
    $breaking     = @()
    $warnings     = @()
    $info         = @()
    $skipped      = $false
    $skipReason   = $null
    $prov         = [ordered]@{ base = $null; rev = $null; route = $null }
    $pactSection  = [ordered]@{ consumers = @(); failed = @(); unverifiable = @() }
    $summary      = $null

    if ($Mode -eq 'schema-diff') {
        # On-demand safety net; normally the orchestrator ran -EnsureTool (with
        # user consent) long before this point.
        Install-Oasdiff | Out-Null

        if ($BaseSpec -or $RevSpec) {
            if (-not $BaseSpec -or -not $RevSpec) {
                throw 'schema-diff with boot-captured docs requires BOTH -BaseSpec and -RevSpec'
            }
            if (-not (Test-Path -LiteralPath $BaseSpec)) { throw "base spec not found: $BaseSpec" }
            if (-not (Test-Path -LiteralPath $RevSpec))  { throw "rev spec not found: $RevSpec" }
            $prov.base = 'boot'
            $prov.rev  = 'boot'
            # The capture route (e.g. /openapi/v1.json) is owned by whoever booted
            # the app and captured the docs; this script cannot know it -- null,
            # never a guess.
            $prov.route = $null
            $diff = Invoke-OasdiffDiff -BaseFile $BaseSpec -RevFile $RevSpec
            $breaking   = $diff.breaking
            $warnings   = $diff.warnings
            $info       = $diff.info
            $skipped    = $diff.skipped
            $skipReason = $diff.skipReason
        }
        else {
            # Committed-spec shortcut. WHY: the working-tree file captures
            # uncommitted spec edits on the rev side; `git show <baseSha>:<path>`
            # is the exact merge-base contract on the base side; zero app boots.
            # -SpecPath is optional: without it the changed spec file(s) are
            # auto-derived from diff-set.json (files UNION untracked)  -  verified
            # live: requiring the caller to hunt the path added a failed call +
            # a manual grep to every run for information the diff already holds.
            if (-not $repoPath -or -not $baseSha) { throw "manifest is missing repoPath/baseSha (required for the committed-spec path)" }
            $specRx = '(?i)(^|/)(openapi|swagger)[^/]*\.(json|yaml|yml)$'
            $specPaths = @()
            if ($SpecPath) {
                $specPaths = @($SpecPath)
            }
            else {
                $diffSet = $null
                $diffSetPath = Join-Path $workspaceDir 'diff-set.json'
                if (Test-Path -LiteralPath $diffSetPath) {
                    $diffSet = Get-Content -LiteralPath $diffSetPath -Raw -Encoding UTF8 | ConvertFrom-Json
                }
                $found = @()
                if ($null -ne $diffSet) {
                    foreach ($f in @(Get-Prop $diffSet 'files' @())) {
                        if ([string](Get-Prop $f 'status' '') -eq 'D') { continue }
                        $p = ([string](Get-Prop $f 'path' '')) -replace '\\', '/'
                        if ($p -match $specRx) { $found += $p }
                    }
                    foreach ($u in @(Get-Prop $diffSet 'untracked' @())) {
                        $p = ([string]$u) -replace '\\', '/'
                        if ($p -match $specRx) { $found += $p }
                    }
                }
                # Sorted for byte-stable artifacts (same branch, same report, twice).
                $specPaths = @($found | Sort-Object -Unique)
            }

            if ($specPaths.Count -eq 0) {
                # An unchanged committed spec means an unchanged documented
                # contract on this capture path  -  honest skip, never "0 breaking".
                $skipped    = $true
                $skipReason = 'no committed OpenAPI spec changed in this diff (auto-detected from diff-set.json) -- nothing to diff on the committed-spec path; pass -SpecPath or -BaseSpec/-RevSpec to override'
            }
            else {
                $prov.base  = 'committed-spec'
                $prov.rev   = 'committed-spec'
                $prov.route = (@($specPaths | ForEach-Object { $_ -replace '\\', '/' }) -join '; ')
                $specSkipNotes = @()
                $ranAny = $false
                $specIdx = 0
                foreach ($sp in $specPaths) {
                    $specIdx++
                    $specGit = $sp -replace '\\', '/'
                    $revFile = Join-Path $repoPath $sp
                    if (-not (Test-Path -LiteralPath $revFile)) {
                        $specSkipNotes += "working-tree spec missing at $revFile -- nothing to diff on the rev side"
                        continue
                    }
                    # Keep the original extension: oasdiff uses it to pick the
                    # JSON/YAML loader.
                    $ext = [System.IO.Path]::GetExtension($sp)
                    if ([string]::IsNullOrEmpty($ext)) { $ext = '.json' }
                    $baseFile = Join-Path $script:TempDir ("base-spec-$specIdx$ext")
                    $git = Invoke-Native -Exe 'git' -Arguments @('-C', $repoPath, 'show', "$($baseSha):$specGit") -StdOutFile $baseFile
                    if ($git.ExitCode -ne 0) {
                        # A spec that did not exist at the merge base has no baseline
                        # contract; skipping (not "0 breaking") keeps the claim honest.
                        $specSkipNotes += "spec $specGit does not exist at base SHA $baseSha -- no baseline contract to diff against"
                        continue
                    }
                    $diff = Invoke-OasdiffDiff -BaseFile $baseFile -RevFile $revFile
                    if ($diff.skipped) {
                        $specSkipNotes += "$specGit`: $($diff.skipReason)"
                        continue
                    }
                    $ranAny = $true
                    $breaking += @($diff.breaking)
                    $warnings += @($diff.warnings)
                    $info     += @($diff.info)
                }
                if (-not $ranAny) {
                    $skipped    = $true
                    $skipReason = ($specSkipNotes -join ' | ')
                }
                else {
                    # Some specs diffed, some couldn't: the artifact must carry both
                    # truths  -  the diff results AND the per-spec skip reasons.
                    foreach ($n in $specSkipNotes) {
                        $info += , [ordered]@{ ruleId = 'spec-skipped'; level = 'INFO'; text = $n; path = $null }
                    }
                }
            }
        }

        $summary = "contract-check: schema-diff breaking=$($breaking.Count) warnings=$($warnings.Count) info=$($info.Count) skipped=$skipped -> $artifactPath"
        if ($skipped) { $summary = "contract-check: schema-diff SKIPPED ($skipReason) -> $artifactPath" }
    }
    elseif ($Mode -eq 'ocelot-diff') {
        if (-not $repoPath -or -not $baseSha) { throw 'manifest is missing repoPath/baseSha (required for ocelot-diff)' }
        # Both sides are config files, not boot captures.
        $prov.base  = 'committed-spec'
        $prov.rev   = 'committed-spec'
        $prov.route = $OcelotGlob

        # Changed files = merge-base diff UNION untracked (CLAUDE.md Phase 1 rule:
        # plain diff silently misses a brand-new config file).
        $diffRes = Invoke-Native -Exe 'git' -Arguments @('-C', $repoPath, 'diff', '--name-only', $baseSha, '--', $OcelotGlob)
        if ($diffRes.ExitCode -ne 0) { throw "git diff failed (exit $($diffRes.ExitCode)): $($diffRes.StdErr)" }
        $untrRes = Invoke-Native -Exe 'git' -Arguments @('-C', $repoPath, 'ls-files', '--others', '--exclude-standard', '--', $OcelotGlob)
        if ($untrRes.ExitCode -ne 0) { throw "git ls-files failed (exit $($untrRes.ExitCode)): $($untrRes.StdErr)" }

        # Sorted for byte-stable artifacts -- same branch must produce the same
        # report twice (hashtable/enumeration order is not deterministic).
        $files = @(((("$($diffRes.StdOut)`n$($untrRes.StdOut)") -split "`r?`n") | Where-Object { $_ -match '\S' }) | Sort-Object -Unique)

        foreach ($f in $files) {
            $baseMap = @{}
            $revMap  = @{}
            $comparable = $true

            $baseRes = Invoke-Native -Exe 'git' -Arguments @('-C', $repoPath, 'show', "$($baseSha):$f")
            if ($baseRes.ExitCode -eq 0) {
                $cfg = ConvertFrom-OcelotConfig $baseRes.StdOut
                if ($null -eq $cfg) {
                    # Unparseable side => do NOT compare this file: pretending it
                    # was empty would fabricate "removed route" findings.
                    $warnings  += , [ordered]@{ ruleId = 'ocelot-config-unparseable'; level = 'WARN'; text = "base version of $f is not valid JSON -- file skipped, routes not compared"; path = $f }
                    $comparable = $false
                } else {
                    $baseMap = Get-OcelotRouteMap $cfg
                }
            }
            # else: file is new at rev -- base map stays empty, additions are not breaking.

            $revPath = Join-Path $repoPath $f
            if ($comparable -and (Test-Path -LiteralPath $revPath)) {
                $cfg = ConvertFrom-OcelotConfig (Get-Content -LiteralPath $revPath -Raw -Encoding UTF8)
                if ($null -eq $cfg) {
                    $warnings  += , [ordered]@{ ruleId = 'ocelot-config-unparseable'; level = 'WARN'; text = "working-tree version of $f is not valid JSON -- file skipped, routes not compared"; path = $f }
                    $comparable = $false
                } else {
                    $revMap = Get-OcelotRouteMap $cfg
                }
            }
            # else: file deleted at rev -- rev map stays empty, every base route
            # correctly reads as removed.

            if (-not $comparable) { continue }

            foreach ($key in @($baseMap.Keys | Sort-Object)) {
                $upstream = ($key -split ' ', 2)[1]
                if (-not $revMap.ContainsKey($key)) {
                    # Removal: level ERR -- a consumer calling this upstream now
                    # 404s, deterministically. No judgment needed.
                    $breaking += , [ordered]@{
                        ruleId = 'ocelot-route-removed'
                        level  = 'ERR'
                        text   = "Upstream route removed: $key (in $f) -- any consumer calling it will break"
                        path   = $upstream
                    }
                } else {
                    $b = $baseMap[$key]
                    $r = $revMap[$key]
                    $deltas = @()
                    # Case-sensitive compares: URL templates and auth config are
                    # case-significant to the gateway.
                    $bd = Get-Prop $b 'DownstreamPathTemplate' ''
                    $rd = Get-Prop $r 'DownstreamPathTemplate' ''
                    if ($bd -cne $rd) { $deltas += "DownstreamPathTemplate '$bd' -> '$rd'" }
                    $ba = ConvertTo-CompactJson (Get-Prop $b 'AuthenticationOptions')
                    $ra = ConvertTo-CompactJson (Get-Prop $r 'AuthenticationOptions')
                    if ($ba -cne $ra) { $deltas += "AuthenticationOptions $ba -> $ra" }
                    if ($deltas.Count -gt 0) {
                        # Change: level WARN -- rerouting/auth changes MAY break
                        # consumers but need human judgment (the downstream may be
                        # an equivalent implementation). Removals are ERR because
                        # they break deterministically.
                        $breaking += , [ordered]@{
                            ruleId = 'ocelot-route-changed'
                            level  = 'WARN'
                            text   = ("Route changed: $key (in $f): " + ($deltas -join '; '))
                            path   = $upstream
                        }
                    }
                }
            }
        }

        $removedCount = @($breaking | Where-Object { $_['ruleId'] -eq 'ocelot-route-removed' }).Count
        $changedCount = @($breaking | Where-Object { $_['ruleId'] -eq 'ocelot-route-changed' }).Count
        $summary = "contract-check: ocelot-diff files=$($files.Count) removedRoutes=$removedCount changedRoutes=$changedCount -> $artifactPath"
    }
    else {
        # pact-verify. CONTRACTS.md names this mode 'pact' in the artifact.
        $artifactMode = 'pact'
        # captureProvenance stays null -- this mode captures no API document.

        # 1) Emit the env vars the orchestrator must STRIP from any child
        #    `dotnet test`. WHY: pact verification results are published from CI
        #    only, never from a local run (safety rule) -- a developer machine with
        #    publish vars set must not be able to poison the broker. Names only;
        #    values are never printed (secrets rule).
        $strip = @('PACT_BROKER_PUBLISH_VERIFICATION_RESULTS')
        foreach ($ev in (Get-ChildItem env:)) {
            if ($ev.Name -like 'PACT_PUBLISH_*') { $strip += $ev.Name }
        }
        $strip = @($strip | Sort-Object -Unique)
        foreach ($n in $strip) { Write-Output ("STRIP_ENV: {0}" -f $n) }

        # 2) Broker reachability -- one read-only GET of the broker index. The
        #    token goes into the Authorization header only; it is never echoed,
        #    and any userinfo embedded in the URL is stripped before reporting.
        $brokerUrl = $env:PACT_BROKER_BASE_URL
        if (-not $brokerUrl) { $brokerUrl = $env:PACT_BROKER_URL }
        if ($brokerUrl) {
            $safeUrl = $brokerUrl -replace '(?<=://)[^@/]+@', ''
            $iwr = @{ Uri = $brokerUrl; Method = 'Get'; UseBasicParsing = $true; TimeoutSec = 15 }
            if ($env:PACT_BROKER_TOKEN) { $iwr['Headers'] = @{ Authorization = "Bearer $($env:PACT_BROKER_TOKEN)" } }
            $brokerStatus = $null
            try {
                $resp = Invoke-WebRequest @iwr
                $brokerStatus = "reachable (HTTP $([int]$resp.StatusCode))"
            } catch [System.Net.WebException] {
                $r = $_.Exception.Response
                if ($null -ne $r) {
                    # 401/403 still proves the broker is reachable -- auth issues
                    # are reported as such, not as network failures.
                    $brokerStatus = "reachable (HTTP $([int]$r.StatusCode))"
                } else {
                    $brokerStatus = "unreachable ($($_.Exception.Status))"
                }
            } catch {
                $brokerStatus = 'unreachable'
            }
            $info += , [ordered]@{ ruleId = 'pact-broker-reachability'; level = 'INFO'; text = "Pact broker $safeUrl is $brokerStatus (read-only GET)"; path = $null }
        } else {
            $brokerStatus = 'not-configured'
            $info += , [ordered]@{ ruleId = 'pact-broker-reachability'; level = 'INFO'; text = 'no Pact broker configured (PACT_BROKER_BASE_URL / PACT_BROKER_URL unset) -- verifier limited to directory pacts'; path = $null }
        }

        # 3) Record verifier results if the generated test run produced them.
        $resultsRecorded = $false
        if ($PactResults) {
            if (-not (Test-Path -LiteralPath $PactResults)) { throw "-PactResults file not found: $PactResults" }
            $pr = Get-Content -LiteralPath $PactResults -Raw | ConvertFrom-Json
            $pactSection.consumers    = @(Get-Prop $pr 'consumers' @())
            $pactSection.failed       = @(Get-Prop $pr 'failed' @())
            $pactSection.unverifiable = @(Get-Prop $pr 'unverifiable' @())
            $resultsRecorded = $true
        }

        $summary = "contract-check: pact broker=$brokerStatus stripVars=$($strip.Count) resultsRecorded=$resultsRecorded -> $artifactPath"
    }

    # -----------------------------------------------------------------------
    # Write the artifact (idempotent overwrite).
    # -----------------------------------------------------------------------
    $report = [ordered]@{
        mode              = $artifactMode
        captureProvenance = $prov
        breaking          = @($breaking)
        warnings          = @($warnings)
        info              = @($info)
        pact              = $pactSection
        skipped           = [bool]$skipped
        skipReason        = $skipReason
    }
    $json = ConvertTo-Json -InputObject $report -Depth 12
    # WHY WriteAllText instead of Out-File -Encoding utf8: on PS 5.1 that encoding
    # writes a BOM, and CONTRACTS.md mandates UTF-8 without BOM for all artifacts.
    [System.IO.File]::WriteAllText($artifactPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    # Exactly one final summary line; findings live in the artifact, so breaking
    # changes still exit 0 -- non-zero means this script itself failed.
    Write-Output $summary
    exit 0
}
catch {
    # Write-Error would re-throw under $ErrorActionPreference='Stop'; write the
    # failure to stderr directly and signal script failure via the exit code.
    [Console]::Error.WriteLine("contract-check failed: $($_.Exception.Message)")
    exit 1
}
