#Requires -Version 5.1
<#
setup-mcp.ps1  -  one-time developer setup for agentQ's MCP servers, end to end.

Does the whole Jira MCP setup in one run:
  1. checks prerequisites (git, node >= 14, npm, claude CLI)
  2. clones https://github.com/e-conomic/mcp-visma-jira (or reuses an existing
     checkout) and runs npm install
  3. persists the OS environment variables Claude Code needs to launch the Jira
     and Testomatio MCP servers declared in .mcp.json - opening the token pages
     in your browser so you only have to paste:
       MCP_VISMA_JIRA_PATH         set automatically to <checkout>\index.js
       JIRA_INTEGRATION_HUB_URL    defaulted (Enter to accept)
       JIRA_PERSONAL_ACCESS_TOKEN  created at jira.visma.com -> Profile -> Personal Access Tokens
       TESTOMATIO_API_TOKEN        optional - app.testomat.io -> Account -> Access tokens
  4. offers to connect the Figma claude.ai connector (browser login with your
     Visma account) if it isn't already
  5. ends with check-mcp.ps1 so you see every server's status immediately

Run this yourself in a normal PowerShell terminal (NOT through Claude Code - it
prompts interactively, which Claude Code's own shell tools can't answer). Safe
to re-run: a variable that's already set is left alone and reported, never
silently overwritten. No token value is ever written to a file or echoed.

Vars are set at User scope (HKCU\Environment - persists across reboots and new
terminals) AND in this process, so the final check works right away; any
already-open Claude Code still needs a full restart to see them.

Playwright needs no setup (zero-config npx server); Figma is a separate one-time
claude.ai connector, unrelated to any of this.

Usage:
  .\scripts\setup-mcp.ps1                    full setup, skips anything already done
  .\scripts\setup-mcp.ps1 -Reset <VarName>   clears one variable so it can be re-entered
#>
[CmdletBinding()]
param(
    [string]$Reset
)

$ErrorActionPreference = 'Stop'

$JiraMcpRepoUrl   = 'https://github.com/e-conomic/mcp-visma-jira'
$JiraHubUrlDefault = 'https://prod.integration-hub.visma.com/jira_gateway'
$JiraTokenPage    = 'https://jira.visma.com/secure/ViewProfile.jspa'
$TestomatTokenPage = 'https://app.testomat.io/account/access_tokens'

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
    # User scope for persistence + Process scope so the final check-mcp run
    # (and any child process of this terminal) sees the value immediately.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    Write-Host "[set] $Name" -ForegroundColor Green
}

if ($Reset) {
    [Environment]::SetEnvironmentVariable($Reset, $null, 'User')
    [Environment]::SetEnvironmentVariable($Reset, $null, 'Process')
    Write-Host "[cleared] $Reset - re-run this script without -Reset to set it again."
    return
}

Write-Host "agentQ MCP setup"
Write-Host "Clones/installs the Jira MCP server, saves the environment variables the"
Write-Host ".mcp.json servers need (opening the token pages for you), and finishes"
Write-Host "with a status check. Nothing is written to any file in this repo."
Write-Host ""

# --- 1. prerequisites ---------------------------------------------------------

foreach ($tool in 'git', 'node', 'npm') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "'$tool' not found on PATH - install it and re-run."
    }
}
$nodeMajor = [int]((node --version) -replace '^v' -split '\.')[0]
if ($nodeMajor -lt 14) {
    throw "Node v14+ required (found v$nodeMajor) - upgrade Node and re-run."
}
$claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claude) {
    $fallback = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path $fallback) { $claude = $fallback }
    else { throw "claude CLI not found on PATH or at $fallback - install Claude Code first." }
}
Write-Host "[ok] prerequisites: git, node v$nodeMajor, npm, claude" -ForegroundColor Green

# --- 2. clone or reuse mcp-visma-jira ------------------------------------------

$existingPath = [Environment]::GetEnvironmentVariable('MCP_VISMA_JIRA_PATH', 'User')
if ($existingPath -and (Test-Path $existingPath)) {
    $checkout = Split-Path $existingPath -Parent
    Write-Host "[already set] MCP_VISMA_JIRA_PATH -> reusing checkout at $checkout" -ForegroundColor Green
} else {
    $dest = Read-Host -Prompt "Where should mcp-visma-jira live? (Enter for C:\mcp-visma-jira)"
    if ([string]::IsNullOrWhiteSpace($dest)) { $dest = 'C:\mcp-visma-jira' }

    if (Test-Path (Join-Path $dest 'index.js')) {
        Write-Host "[reusing] existing checkout at $dest" -ForegroundColor Green
    } elseif (Test-Path $dest) {
        throw "$dest exists but has no index.js - it doesn't look like mcp-visma-jira. Delete it or choose another path."
    } else {
        Write-Host "[cloning] $JiraMcpRepoUrl -> $dest (git may prompt for credentials)"
        git clone $JiraMcpRepoUrl $dest
        if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE) - check your GitHub access to e-conomic/mcp-visma-jira." }
    }
    $checkout = $dest
}

# --- 3. npm install -------------------------------------------------------------

if (Test-Path (Join-Path $checkout 'node_modules')) {
    Write-Host "[already installed] node_modules present in $checkout" -ForegroundColor Green
} else {
    Write-Host "[installing] npm install in $checkout"
    Push-Location $checkout
    try {
        npm install
        if ($LASTEXITCODE -ne 0) { throw "npm install failed (exit $LASTEXITCODE) - see output above." }
    } finally {
        Pop-Location
    }
}

# --- 4. environment variables ----------------------------------------------------

if (-not $existingPath -or -not (Test-Path $existingPath)) {
    Set-AgentQEnvVar -Name 'MCP_VISMA_JIRA_PATH' -Value (Join-Path $checkout 'index.js')
}

if ([Environment]::GetEnvironmentVariable('JIRA_INTEGRATION_HUB_URL', 'User')) {
    Write-Host "[already set] JIRA_INTEGRATION_HUB_URL" -ForegroundColor Green
} else {
    $url = Read-Host -Prompt "Jira Integration Hub URL (Enter for $JiraHubUrlDefault)"
    if ([string]::IsNullOrWhiteSpace($url)) { $url = $JiraHubUrlDefault }
    Set-AgentQEnvVar -Name 'JIRA_INTEGRATION_HUB_URL' -Value $url
}

if ([Environment]::GetEnvironmentVariable('JIRA_PERSONAL_ACCESS_TOKEN', 'User')) {
    Write-Host "[already set] JIRA_PERSONAL_ACCESS_TOKEN" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Opening $JiraTokenPage ..."
    Write-Host "There: Personal Access Tokens (left menu) -> Create token -> copy it."
    Start-Process $JiraTokenPage
    $secure = Read-Host -Prompt 'Paste your Jira Personal Access Token' -AsSecureString
    $value = ConvertFrom-SecureStringPlain -Secure $secure
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Host "[skipped] JIRA_PERSONAL_ACCESS_TOKEN - the Jira MCP won't work without it; re-run this script." -ForegroundColor Yellow
    } else {
        Set-AgentQEnvVar -Name 'JIRA_PERSONAL_ACCESS_TOKEN' -Value $value
    }
}

if ([Environment]::GetEnvironmentVariable('TESTOMATIO_API_TOKEN', 'User')) {
    Write-Host "[already set] TESTOMATIO_API_TOKEN" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Testomatio token is optional - only the impact/Testomat lane uses it."
    $answer = Read-Host -Prompt 'Set it now? (y = open the token page, Enter = skip)'
    if ($answer -match '^y') {
        Write-Host "Opening $TestomatTokenPage ..."
        Start-Process $TestomatTokenPage
        $secure = Read-Host -Prompt 'Paste your Testomatio API token' -AsSecureString
        $value = ConvertFrom-SecureStringPlain -Secure $secure
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Host "[skipped] TESTOMATIO_API_TOKEN" -ForegroundColor Yellow
        } else {
            Set-AgentQEnvVar -Name 'TESTOMATIO_API_TOKEN' -Value $value
        }
    } else {
        Write-Host "[skipped] TESTOMATIO_API_TOKEN - the impact/Testomat lane will report SKIPPED." -ForegroundColor Yellow
    }
}

# --- 5. Figma claude.ai connector ---------------------------------------------------

$figma = (& $claude mcp get 'claude.ai Figma' 2>&1) -join "`n"
if ($figma -match 'Status:\s*.*Connected') {
    Write-Host "[already connected] Figma (claude.ai connector)" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Figma is only needed for frontend branches with a linked design."
    $answer = Read-Host -Prompt 'Connect Figma now? (y = browser login with your Visma account, Enter = skip)'
    if ($answer -match '^y') {
        & $claude mcp login 'claude.ai Figma'
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[failed] Figma login - enable the Figma connector in your claude.ai settings, then re-run, or use /mcp inside Claude Code." -ForegroundColor Yellow
        }
    } else {
        Write-Host "[skipped] Figma - design-conformance checks will report SKIPPED. Connect later with: claude mcp login `"claude.ai Figma`"" -ForegroundColor Yellow
    }
}

# --- 6. status check --------------------------------------------------------------

Write-Host ""
Write-Host "Checking MCP status..."
& (Join-Path $PSScriptRoot 'check-mcp.ps1')

Write-Host ""
Write-Host "Done. Fully restart Claude Code - env vars only apply to new sessions -" -ForegroundColor Cyan
Write-Host "then approve the MCP prompt on first open ('Pending approval' above is" -ForegroundColor Cyan
Write-Host "expected until you do). Verify with /mcp." -ForegroundColor Cyan
