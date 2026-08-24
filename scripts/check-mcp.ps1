#Requires -Version 5.1
<#
check-mcp.ps1  -  read-only status check of the MCP servers THIS project needs.

`/mcp` and `claude mcp list` count every server across every scope (including
claude.ai connectors). This shows only the servers declared in .mcp.json, plus
whether the env vars they substitute are set. Changes nothing; safe to run in
your own terminal or through Claude Code.

Usage:
  .\scripts\check-mcp.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claude) {
    $fallback = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path $fallback) { $claude = $fallback }
    else { throw "claude CLI not found on PATH or at $fallback" }
}

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

Write-Host ""
$vars = @(
    @{ Name = 'MCP_VISMA_JIRA_PATH';        Optional = $false },
    @{ Name = 'JIRA_INTEGRATION_HUB_URL';   Optional = $false },
    @{ Name = 'JIRA_PERSONAL_ACCESS_TOKEN'; Optional = $false },
    @{ Name = 'TESTOMATIO_API_TOKEN';       Optional = $true }
)
foreach ($v in $vars) {
    $suffix = if ($v.Optional) { ' (optional - impact/Testomat lane only)' } else { '' }
    $user = [Environment]::GetEnvironmentVariable($v.Name, 'User')
    if (-not $user) {
        $color = if ($v.Optional) { 'Yellow' } else { 'Red' }
        Write-Host "[missing] $($v.Name)$suffix - run .\scripts\setup-mcp.ps1" -ForegroundColor $color
    } elseif (-not [Environment]::GetEnvironmentVariable($v.Name, 'Process')) {
        Write-Host "[set] $($v.Name)$suffix - but not in this session; restart Claude Code / this terminal" -ForegroundColor Yellow
    } else {
        Write-Host "[set] $($v.Name)$suffix" -ForegroundColor Green
    }
}

Write-Host ""
$figma = (& $claude mcp get 'claude.ai Figma' 2>&1) -join "`n"
$figmaStatus = if ($figma -match 'Status:\s*(.+)') { $Matches[1].Trim() } else { 'not configured' }
Write-Host ("{0,-12} {1,-45} {2}" -f 'figma', $figmaStatus, 'claude.ai connector')
if ($figmaStatus -notmatch 'Connected') {
    Write-Host "  [info] only needed for frontend branches with a linked design - connect with: claude mcp login `"claude.ai Figma`" (or re-run setup-mcp.ps1)" -ForegroundColor Yellow
}
