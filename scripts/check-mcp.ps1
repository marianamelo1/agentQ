#Requires -Version 5.1
<#
check-mcp.ps1  -  read-only status check of everything THIS project depends on:
prerequisite tools, the MCP servers declared in .mcp.json, the env vars, the
Figma connector, and a LIVE Jira connectivity probe (scripts/jira.ps1 -Probe -
Jira is a direct REST lane, not an MCP).
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
        $suffix = if ($t.Optional) { ' (optional - consented Testcontainers paths only)' } else { ' - run .\scripts\setup-mcp.ps1' }
        Write-Host ("[missing] {0}{1}" -f $t.Command, $suffix) -ForegroundColor $(if ($t.Optional) { 'Yellow' } else { 'Red' })
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
        Write-Host "[missing] $($v.Name)$($v.Suffix) - run .\scripts\setup-mcp.ps1" -ForegroundColor $color
    }
}
if ([Environment]::GetEnvironmentVariable('JIRA_INTEGRATION_HUB_URL', 'Process') -or (Test-PersistedEnvVar -Name 'JIRA_INTEGRATION_HUB_URL')) {
    Write-Host "[set] JIRA_INTEGRATION_HUB_URL (optional override - jira.ps1 defaults to the generic prod gateway)" -ForegroundColor Green
}
if ([Environment]::GetEnvironmentVariable('MCP_VISMA_JIRA_PATH', 'Process') -or (Test-PersistedEnvVar -Name 'MCP_VISMA_JIRA_PATH')) {
    Write-Host "[obsolete] MCP_VISMA_JIRA_PATH - the Jira MCP is retired; clear with: .\scripts\setup-mcp.ps1 -Reset MCP_VISMA_JIRA_PATH" -ForegroundColor Yellow
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
