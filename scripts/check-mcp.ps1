#Requires -Version 5.1
<#
check-mcp.ps1  -  read-only status check of everything THIS project depends on:
prerequisite tools, the pinned lane tools that setup-mcp.ps1 installs (oasdiff,
dotnet-stryker, dotnet-coverage, Playwright browsers - verified against the
pins in their owning scripts, never installed here), the MCP servers declared
in .mcp.json, the env vars, the Figma connector, and a LIVE Jira connectivity
probe (scripts/jira.ps1 -Probe - Jira is a direct REST lane, not an MCP).
Works on Windows (PowerShell 5.1+) and macOS/Linux (pwsh 7+).

`/mcp` and `claude mcp list` count every server across every scope (including
claude.ai connectors); this shows only what agentQ actually uses. Changes
nothing; safe to run in your own terminal or through Claude Code.

Usage:
  .\scripts\check-mcp.ps1          (macOS: pwsh ./scripts/check-mcp.ps1)
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# $IsWindows doesn't exist on Windows PowerShell 5.1 (which is Windows-only).
$IsWin = if ($null -ne $IsWindows) { $IsWindows } else { $true }

# Where setup-mcp.ps1 persists env vars on Unix (no User scope there).
$ProfileFile = if ($IsWin) { $null }
    elseif ($env:SHELL -match 'zsh')  { Join-Path $HOME '.zshrc' }
    elseif ($env:SHELL -match 'bash') { Join-Path $HOME '.bashrc' }
    else                              { Join-Path $HOME '.profile' }

# Platform-correct invocation shown in hint messages.
$SetupCmd = if ($IsWin) { '.\scripts\setup-mcp.ps1' } else { 'pwsh ./scripts/setup-mcp.ps1' }

function Test-PersistedEnvVar {
    # Persisted somewhere a NEW session would see it (User scope / profile line),
    # regardless of whether this process has it.
    param([Parameter(Mandatory)][string]$Name)
    if ($IsWin) { return [bool][Environment]::GetEnvironmentVariable($Name, 'User') }
    return (Test-Path $ProfileFile) -and
        (Select-String -Path $ProfileFile -Pattern "^\s*export\s+$Name=" -Quiet)
}

$claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claude) {
    $exe = if ($IsWin) { 'claude.exe' } else { 'claude' }
    $fallback = Join-Path $HOME (Join-Path '.local' (Join-Path 'bin' $exe))
    if (Test-Path $fallback) { $claude = $fallback }
    else { throw "claude CLI not found on PATH or at $fallback" }
}

# --- prerequisite tools -----------------------------------------------------------

$tools = @(
    @{ Command = 'git';    Optional = $false },
    @{ Command = 'node';   Optional = $false },
    @{ Command = 'npm';    Optional = $false },
    @{ Command = 'dotnet'; Optional = $false },
    @{ Command = 'docker'; Optional = $true }
)
foreach ($t in $tools) {
    if (Get-Command $t.Command -ErrorAction SilentlyContinue) {
        Write-Host ("[ok] {0}" -f $t.Command) -ForegroundColor Green
    } else {
        $suffix = if ($t.Optional) { ' (optional - consented Testcontainers paths only)' } else { " - run $SetupCmd" }
        Write-Host ("[missing] {0}{1}" -f $t.Command, $suffix) -ForegroundColor $(if ($t.Optional) { 'Yellow' } else { 'Red' })
    }
}

# --- lane tools (pinned; installed by setup-mcp.ps1 - verified here, never installed) --

Write-Host ""
$repoRoot = Split-Path $PSScriptRoot -Parent
$toolsDir = Join-Path $repoRoot 'tools'

function Get-PinnedVersion {
    # The version pins live in the owning runtime scripts (single source of
    # truth) - read them from there instead of duplicating the numbers here.
    param([Parameter(Mandatory)][string]$ScriptFile, [Parameter(Mandatory)][string]$Pattern)
    $hit = Select-String -Path (Join-Path $PSScriptRoot $ScriptFile) -Pattern $Pattern | Select-Object -First 1
    if ($hit) { return $hit.Matches[0].Groups[1].Value }
    return $null
}

function Test-PinnedBinary {
    # Present AND reporting the pinned version (a stale binary would change
    # verdicts between machines - same rule the runtime scripts enforce).
    param([Parameter(Mandatory)][string]$ExePath, [string]$Pin)
    if (-not (Test-Path -LiteralPath $ExePath)) { return 'missing' }
    if (-not $Pin) { return 'present' }   # pin unreadable: report presence only
    try {
        $ver = (& $ExePath --version) -join ' '
        if ($LASTEXITCODE -eq 0 -and $ver -match [regex]::Escape($Pin)) { return 'ok' }
    } catch { }
    return 'stale'
}

$oasdiffPin = Get-PinnedVersion -ScriptFile 'contract-check.ps1' -Pattern "OasdiffVersion\s*=\s*'([^']+)'"
$oasdiffExe = Join-Path $toolsDir $(if ($IsWin) { 'oasdiff.exe' } else { 'oasdiff' })
switch (Test-PinnedBinary -ExePath $oasdiffExe -Pin $oasdiffPin) {
    'ok'      { Write-Host "[ok] oasdiff v$oasdiffPin (pinned - contract lane)" -ForegroundColor Green }
    'present' { Write-Host "[ok?] oasdiff present but pin unreadable from contract-check.ps1" -ForegroundColor Yellow }
    'stale'   { Write-Host "[stale] oasdiff present but not v$oasdiffPin - re-run .\scripts\setup-mcp.ps1" -ForegroundColor Yellow }
    'missing' { Write-Host "[missing] oasdiff (contract lane) - run .\scripts\setup-mcp.ps1" -ForegroundColor Red }
}

$strykerPin = Get-PinnedVersion -ScriptFile 'stryker-run.ps1' -Pattern "StrykerVersion\s*=\s*'([^']+)'"
$strykerDir = Join-Path $toolsDir 'stryker'
$strykerExe = Join-Path $strykerDir $(if ($IsWin) { 'dotnet-stryker.exe' } else { 'dotnet-stryker' })
# dotnet-stryker has no bare --version flag (verified live) - the tool-path
# install metadata is the reliable offline pin check.
$strykerState = 'missing'
if (Test-Path -LiteralPath $strykerExe) {
    if (-not $strykerPin) { $strykerState = 'present' }
    else {
        $strykerState = 'stale'
        if (Get-Command dotnet -ErrorAction SilentlyContinue) {
            try {
                $listOut = (& dotnet tool list --tool-path $strykerDir) -join "`n"
                if ($LASTEXITCODE -eq 0 -and $listOut -match ('(?im)^dotnet-stryker\s+' + [regex]::Escape($strykerPin))) { $strykerState = 'ok' }
            } catch { }
        }
    }
}
switch ($strykerState) {
    'ok'      { Write-Host "[ok] dotnet-stryker v$strykerPin (pinned - mutation lane; a repo's own tool-manifest pin wins at run time)" -ForegroundColor Green }
    'present' { Write-Host "[ok?] dotnet-stryker present but pin unreadable from stryker-run.ps1" -ForegroundColor Yellow }
    'stale'   { Write-Host "[stale] dotnet-stryker present but not v$strykerPin - re-run .\scripts\setup-mcp.ps1" -ForegroundColor Yellow }
    'missing' { Write-Host "[missing] dotnet-stryker (mutation lane) - run .\scripts\setup-mcp.ps1" -ForegroundColor Red }
}

if (Get-Command dotnet-coverage -ErrorAction SilentlyContinue) {
    Write-Host "[ok] dotnet-coverage (coverage lane)" -ForegroundColor Green
} elseif (Test-Path (Join-Path $HOME (Join-Path '.dotnet' (Join-Path 'tools' $(if ($IsWin) { 'dotnet-coverage.exe' } else { 'dotnet-coverage' }))))) {
    Write-Host "[ok] dotnet-coverage installed - not on PATH in this session; restart the terminal" -ForegroundColor Yellow
} else {
    Write-Host "[missing] dotnet-coverage (coverage lane) - run .\scripts\setup-mcp.ps1" -ForegroundColor Red
}

if (Get-Command coverlet -ErrorAction SilentlyContinue) {
    Write-Host "[ok] coverlet.console (coverage fallback - only used once dotnet-coverage is calibrated broken on this machine)" -ForegroundColor Green
} elseif (Test-Path (Join-Path $HOME (Join-Path '.dotnet' (Join-Path 'tools' $(if ($IsWin) { 'coverlet.exe' } else { 'coverlet' }))))) {
    Write-Host "[ok] coverlet.console installed - not on PATH in this session; restart the terminal" -ForegroundColor Yellow
} else {
    Write-Host "[not installed] coverlet.console (coverage fallback; expected on almost every machine - run-tests.ps1 installs it on demand only if dotnet-coverage turns out calibrated-broken here, e.g. the documented osx-arm64 gap; manual: dotnet tool install --global coverlet.console)" -ForegroundColor Yellow
}

$pwCache = if ($IsWin) { Join-Path $env:LOCALAPPDATA 'ms-playwright' }
           elseif ($null -ne $IsMacOS -and $IsMacOS) { Join-Path $HOME (Join-Path 'Library' (Join-Path 'Caches' 'ms-playwright')) }
           else { Join-Path $HOME (Join-Path '.cache' 'ms-playwright') }
if ((Test-Path $pwCache) -and @(Get-ChildItem $pwCache -Directory -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Host "[ok] Playwright browsers ($pwCache)" -ForegroundColor Green
} else {
    Write-Host "[missing] Playwright browsers - E2E lane (frontend repos) only; setup-mcp.ps1 installs them when a registered repo declares @playwright/test" -ForegroundColor Yellow
}

# --- static lint: @(List[object]) double-wrap crash (GH issue #30) -----------------
# On this project's PowerShell builds (verified on both 5.1 and 7.6.5), wrapping
# a New-Object-constructed List[object] variable directly in @() throws
# "ArgumentException: Argument types do not match" - reproduced multiple times
# live (impact-index.ps1:467, fixed in GH #31; audited project-wide in GH #30).
# The trigger is narrow and confirmed empirically: New-Object + the [object]
# type argument specifically (List[string] etc. via New-Object is fine, and
# piping a List[object] through Where-Object/ForEach-Object before @() is also
# fine - only a BARE @($sameVar) on the New-Object-constructed variable itself
# is dangerous). This is why the check below is a co-occurrence check (does
# the SAME variable get both New-Object-constructed as List[object] AND later
# @()-wrapped bare in this file), not a blanket ban on the idiom itself - plain
# New-Object List[object] with no @() wrap is this repo's normal, accepted
# list-building convention (CLAUDE.md) and must not be flagged.
Write-Host ""
$scriptsDirForLint = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'
$listObjectDeclPattern = '\$(?<var>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*New-Object\s+[\x27"]?System\.Collections\.Generic\.List\[object\][\x27"]?'
$listObjectViolations = New-Object System.Collections.Generic.List[object]
foreach ($lintFile in (Get-ChildItem -Path $scriptsDirForLint -Filter '*.ps1' -File)) {
    $lintRaw = Get-Content -LiteralPath $lintFile.FullName -Raw
    if ([string]::IsNullOrEmpty($lintRaw)) { continue }
    # Blank out comment text (line AND block comments) before matching -
    # otherwise a comment merely DESCRIBING the bug (this repo has several,
    # e.g. test-inventory.ps1's "WHY $entries directly, NOT @($entries)")
    # reads as a live violation. Newlines are preserved so line numbers below
    # stay accurate; [ref]$null discards parse errors - a script with a real
    # syntax error still gets scanned on a best-effort token set.
    $lintChars = $lintRaw.ToCharArray()
    $lintTokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($lintFile.FullName, [ref]$lintTokens, [ref]$null)
    foreach ($tok in $lintTokens) {
        if ($tok.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment) {
            for ($i = $tok.Extent.StartOffset; $i -lt $tok.Extent.EndOffset -and $i -lt $lintChars.Length; $i++) {
                if ($lintChars[$i] -ne "`n") { $lintChars[$i] = ' ' }
            }
        }
    }
    $lintText = -join $lintChars
    foreach ($declMatch in [regex]::Matches($lintText, $listObjectDeclPattern)) {
        $varName = $declMatch.Groups['var'].Value
        $wrapPattern = '@\(\s*\$' + [regex]::Escape($varName) + '\s*\)'
        if ([regex]::IsMatch($lintText, $wrapPattern)) {
            $declLine = ($lintText.Substring(0, $declMatch.Index) -split "`n").Length
            $listObjectViolations.Add([pscustomobject]@{ File = $lintFile.Name; Variable = $varName; DeclLine = $declLine })
        }
    }
}
if ($listObjectViolations.Count -eq 0) {
    Write-Host "[ok] no @(<New-Object List[object]>) direct-wrap crash pattern in scripts/*.ps1 (GH issue #30)" -ForegroundColor Green
} else {
    foreach ($violation in $listObjectViolations) {
        Write-Host ('[fail] {0}:{1} - ${2} is a New-Object List[object] later wrapped directly in @(${2}) - throws ArgumentException on this PS build (GH issue #30). Use .ToArray() or a leading comma (,${2}) instead.' -f $violation.File, $violation.DeclLine, $violation.Variable) -ForegroundColor Red
    }
}

# --- MCP servers declared in .mcp.json ---------------------------------------------

Write-Host ""
$mcpJson = Join-Path (Split-Path $PSScriptRoot -Parent) '.mcp.json'
$servers = (Get-Content $mcpJson -Raw | ConvertFrom-Json).mcpServers.PSObject.Properties.Name

foreach ($name in $servers) {
    $out = (& $claude mcp get $name 2>&1) -join "`n"
    $status = if ($out -match 'Status:\s*(.+)') { $Matches[1].Trim() } else { 'not found in any scope' }
    $scope  = if ($out -match 'Scope:\s*(.+)')  { ($Matches[1] -split '\(')[0].Trim() } else { '-' }
    Write-Host ("{0,-12} {1,-45} {2}" -f $name, $status, $scope)
    if ($scope -ne '-' -and $scope -notmatch '^Project config') {
        Write-Host ("  [warn] '{0}' resolves from {1}, which shadows .mcp.json - remove it with: claude mcp remove {0}" -f $name, $scope) -ForegroundColor Yellow
    }
}

# --- env vars (never their values) --------------------------------------------------

Write-Host ""
$vars = @(
    @{ Name = 'JIRA_PERSONAL_ACCESS_TOKEN'; Optional = $false; Suffix = ' (Jira REST lane - scripts/jira.ps1, not an MCP)' },
    @{ Name = 'TESTOMATIO_API_TOKEN';       Optional = $true;  Suffix = ' (optional - impact/Testomat lane only)' }
)
foreach ($v in $vars) {
    $process = [Environment]::GetEnvironmentVariable($v.Name, 'Process')
    $persisted = Test-PersistedEnvVar -Name $v.Name
    if ($process) {
        Write-Host "[set] $($v.Name)$($v.Suffix)" -ForegroundColor Green
    } elseif ($persisted) {
        Write-Host "[set] $($v.Name)$($v.Suffix) - but not in this session; restart Claude Code / this terminal" -ForegroundColor Yellow
    } else {
        $color = if ($v.Optional) { 'Yellow' } else { 'Red' }
        Write-Host "[missing] $($v.Name)$($v.Suffix) - run $SetupCmd" -ForegroundColor $color
    }
}
if ([Environment]::GetEnvironmentVariable('JIRA_INTEGRATION_HUB_URL', 'Process') -or (Test-PersistedEnvVar -Name 'JIRA_INTEGRATION_HUB_URL')) {
    Write-Host "[set] JIRA_INTEGRATION_HUB_URL (optional override - jira.ps1 defaults to the generic prod gateway)" -ForegroundColor Green
}
if ([Environment]::GetEnvironmentVariable('MCP_VISMA_JIRA_PATH', 'Process') -or (Test-PersistedEnvVar -Name 'MCP_VISMA_JIRA_PATH')) {
    Write-Host "[obsolete] MCP_VISMA_JIRA_PATH - the Jira MCP is retired; clear with: $SetupCmd -Reset MCP_VISMA_JIRA_PATH" -ForegroundColor Yellow
}

# --- live Jira probe (REST lane, not an MCP) -----------------------------------------

Write-Host ""
$probeRaw = & (Join-Path $PSScriptRoot 'jira.ps1') -Probe
$probeStatus = try { ($probeRaw | ConvertFrom-Json).status } catch { "DEGRADED - unreadable probe output: $probeRaw" }
$probeColor = if ($probeStatus -like 'OK*') { 'Green' } elseif ($probeStatus -like 'SKIPPED*') { 'Yellow' } else { 'Red' }
Write-Host ("{0,-12} {1,-45} {2}" -f 'jira', $probeStatus, 'REST (scripts/jira.ps1)') -ForegroundColor $probeColor

# --- Figma claude.ai connector --------------------------------------------------------

Write-Host ""
$figma = (& $claude mcp get 'claude.ai Figma' 2>&1) -join "`n"
$figmaStatus = if ($figma -match 'Status:\s*(.+)') { $Matches[1].Trim() } else { 'not configured' }
Write-Host ("{0,-12} {1,-45} {2}" -f 'figma', $figmaStatus, 'claude.ai connector')
if ($figmaStatus -notmatch 'Connected') {
    Write-Host "  [info] only needed for frontend branches with a linked design - connect with: claude mcp login `"claude.ai Figma`" (or re-run setup-mcp.ps1)" -ForegroundColor Yellow
}
