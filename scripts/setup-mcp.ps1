#Requires -Version 5.1
<#
setup-mcp.ps1  -  one-time developer setup for agentQ's MCP servers.

Persists the OS environment variables Claude Code needs to launch the Jira and
Testomatio MCP servers declared in .mcp.json, so nobody ever hand-edits that file
with a real secret. Run this yourself in a normal PowerShell terminal (NOT through
Claude Code - it prompts interactively, which Claude Code's own shell tools can't
answer). Safe to re-run: a variable that's already set is left alone and reported,
never silently overwritten.

Vars set (User scope - HKCU\Environment, persists across reboots and new terminals,
but NOT in any terminal/Claude Code session already open when you run this):
  MCP_VISMA_JIRA_PATH         path to your mcp-visma-jira checkout's index.js
  JIRA_INTEGRATION_HUB_URL    value is in mcp-visma-jira's own README
  JIRA_PERSONAL_ACCESS_TOKEN  Jira -> Profile -> Personal Access Tokens
  TESTOMATIO_API_TOKEN        optional - only the impact/Testomat lane uses it

Playwright needs no setup (zero-config npx server); Figma is a separate one-time
claude.ai connector, unrelated to any of this.

Usage:
  .\scripts\setup-mcp.ps1                    interactive setup, skips vars already set
  .\scripts\setup-mcp.ps1 -Reset <VarName>   clears one variable so it can be re-entered
#>
[CmdletBinding()]
param(
    [string]$Reset
)

$ErrorActionPreference = 'Stop'

function ConvertFrom-SecureStringPlain {
    param([Parameter(Mandatory)][System.Security.SecureString]$Secure)
    if ($Secure.Length -eq 0) { return '' }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Set-AgentQEnvVar {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$Secret,
        [switch]$Optional
    )

    $existing = [Environment]::GetEnvironmentVariable($Name, 'User')
    if ($existing) {
        Write-Host "[already set] $Name" -ForegroundColor Green
        return
    }

    $label = if ($Optional) { "$Prompt (optional - Enter to skip)" } else { $Prompt }
    if ($Secret) {
        $secure = Read-Host -Prompt $label -AsSecureString
        $value = ConvertFrom-SecureStringPlain -Secure $secure
    } else {
        $value = Read-Host -Prompt $label
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($Optional) {
            Write-Host "[skipped] $Name" -ForegroundColor Yellow
        } else {
            Write-Host "[skipped] $Name - required later; re-run this script, or set it yourself:" -ForegroundColor Yellow
            Write-Host "  [Environment]::SetEnvironmentVariable('$Name', '<value>', 'User')"
        }
        return
    }

    [Environment]::SetEnvironmentVariable($Name, $value, 'User')
    Write-Host "[set] $Name" -ForegroundColor Green
}

if ($Reset) {
    [Environment]::SetEnvironmentVariable($Reset, $null, 'User')
    Write-Host "[cleared] $Reset - re-run this script without -Reset to set it again."
    return
}

Write-Host "agentQ MCP setup"
Write-Host "Sets OS environment variables (User scope) so Claude Code can launch the"
Write-Host "Jira and Testomatio MCP servers declared in .mcp.json. Nothing is written"
Write-Host "to any file in this repo. Playwright needs no setup; Figma is a separate"
Write-Host "claude.ai connector."
Write-Host ""

Set-AgentQEnvVar -Name 'MCP_VISMA_JIRA_PATH' `
    -Prompt "Path to your mcp-visma-jira checkout's index.js (e.g. C:\mcp-visma-jira\index.js)"

Set-AgentQEnvVar -Name 'JIRA_INTEGRATION_HUB_URL' `
    -Prompt "Jira Integration Hub URL (see mcp-visma-jira's own README)"

Set-AgentQEnvVar -Name 'JIRA_PERSONAL_ACCESS_TOKEN' `
    -Prompt 'Jira Personal Access Token (Jira -> Profile -> Personal Access Tokens)' -Secret

Set-AgentQEnvVar -Name 'TESTOMATIO_API_TOKEN' `
    -Prompt 'Testomatio API token' -Secret -Optional

Write-Host ""
Write-Host "Done. Fully restart Claude Code - env vars only apply to new sessions -" -ForegroundColor Cyan
Write-Host "then approve the MCP prompt on first open. Verify with /mcp." -ForegroundColor Cyan
