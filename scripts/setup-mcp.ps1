#Requires -Version 5.1
<#
setup-mcp.ps1  -  one-time developer setup for agentQ, end to end.

Does the whole setup in one run:
  1. checks every tool agentQ's scripts need - git, Node 18+, npm, the .NET SDK,
     the claude CLI - and offers to install anything missing (winget for the
     tools, the official installer for claude). Docker is optional (only the
     consented Testcontainers paths use it) - reported, never installed here.
  2. persists the OS environment variables agentQ needs, opening the token pages
     in your browser so you only have to paste:
       JIRA_PERSONAL_ACCESS_TOKEN  required - used by scripts/jira.ps1 (a direct
                                   REST call to the Jira gateway; NOT an MCP);
                                   created at jira.visma.com -> Profile ->
                                   Personal Access Tokens
       TESTOMATIO_API_TOKEN        optional - the Testomatio MCP server in
                                   .mcp.json; app.testomat.io -> Account -> tokens
  3. offers to connect the Figma claude.ai connector (browser login with your
     Visma account) if it isn't already
  4. ends with check-mcp.ps1: every MCP server's status, the env vars, and a
     LIVE Jira connectivity probe - so you see immediately whether it all works.

The Jira MCP (mcp-visma-jira) is retired: agentQ calls the gateway directly via
scripts/jira.ps1. No clone, no MCP_VISMA_JIRA_PATH - if that variable is still
set from an old setup, this script tells you and you can clear it with -Reset.
The gateway URL is generic (same for everyone) and defaulted inside jira.ps1;
JIRA_INTEGRATION_HUB_URL exists only as an optional override.

Run this yourself in a normal PowerShell terminal (NOT through Claude Code - it
prompts interactively, which Claude Code's own shell tools can't answer). Safe
to re-run: anything already installed/set is left alone and reported, never
silently overwritten. No token value is ever written to a file or echoed.

Vars are set at User scope (HKCU\Environment - persists across reboots and new
terminals) AND in this process, so the final check works right away; any
already-open Claude Code still needs a full restart to see them.

Usage:
  .\scripts\setup-mcp.ps1                    full setup, skips anything already done
  .\scripts\setup-mcp.ps1 -Reset <VarName>   clears one variable so it can be re-entered
#>
[CmdletBinding()]
param(
    [string]$Reset
)

$ErrorActionPreference = 'Stop'

$JiraTokenPage     = 'https://jira.visma.com/secure/ViewProfile.jspa'
$TestomatTokenPage = 'https://app.testomat.io/account/access_tokens'
$ClaudeInstallCmd  = 'irm https://claude.ai/install.ps1 | iex'
$MinNodeMajor      = 18

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

function Update-ProcessPath {
    # Pick up PATH additions made by a winget install without reopening the terminal.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Install-IfMissing {
    # Returns $true when the tool is available by the time we return.
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$WingetId,
        [string]$ManualHint,
        [switch]$Optional
    )
    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-Host "[ok] $DisplayName" -ForegroundColor Green
        return $true
    }
    $level = if ($Optional) { 'optional' } else { 'required' }
    Write-Host "[missing] $DisplayName ($level)" -ForegroundColor $(if ($Optional) { 'Yellow' } else { 'Red' })
    if ($Optional) {
        if ($ManualHint) { Write-Host "  $ManualHint" -ForegroundColor Yellow }
        return $false
    }
    if ($WingetId -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        $answer = Read-Host -Prompt "  Install $DisplayName now via winget? (Enter = yes, n = skip)"
        if ($answer -notmatch '^n') {
            winget install --id $WingetId --accept-source-agreements --accept-package-agreements
            Update-ProcessPath
            if (Get-Command $Command -ErrorAction SilentlyContinue) {
                Write-Host "[installed] $DisplayName" -ForegroundColor Green
                return $true
            }
            Write-Host "  Installed, but '$Command' still isn't on PATH in this session - open a NEW terminal and re-run this script." -ForegroundColor Yellow
            return $false
        }
    } elseif ($WingetId) {
        Write-Host "  winget isn't available - install manually: winget id $WingetId" -ForegroundColor Yellow
    }
    if ($ManualHint) { Write-Host "  $ManualHint" -ForegroundColor Yellow }
    return $false
}

if ($Reset) {
    [Environment]::SetEnvironmentVariable($Reset, $null, 'User')
    [Environment]::SetEnvironmentVariable($Reset, $null, 'Process')
    Write-Host "[cleared] $Reset - re-run this script without -Reset to set it again."
    return
}

Write-Host "agentQ setup"
Write-Host "Checks/installs the tools every script needs, saves the environment"
Write-Host "variables (opening the token pages for you), and finishes with a status"
Write-Host "check that includes a live Jira probe. Nothing is written to any file in"
Write-Host "this repo."
Write-Host ""

# --- 1. prerequisites (install if missing) --------------------------------------

Write-Host "Prerequisites:"
$prereqsOk = $true

$prereqsOk = (Install-IfMissing -Command git -DisplayName 'git' -WingetId 'Git.Git') -and $prereqsOk

$nodeOk = Install-IfMissing -Command node -DisplayName "Node $MinNodeMajor+" -WingetId 'OpenJS.NodeJS.LTS'
if ($nodeOk) {
    $nodeMajor = [int]((node --version) -replace '^v' -split '\.')[0]
    if ($nodeMajor -lt $MinNodeMajor) {
        Write-Host "[outdated] Node v$nodeMajor found - v$MinNodeMajor+ required (Playwright/Testomatio MCP servers)." -ForegroundColor Red
        $answer = Read-Host -Prompt "  Upgrade via winget now? (Enter = yes, n = skip)"
        if ($answer -notmatch '^n' -and (Get-Command winget -ErrorAction SilentlyContinue)) {
            winget install --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
            Update-ProcessPath
            Write-Host "  Open a NEW terminal and re-run this script so the upgraded Node is picked up." -ForegroundColor Yellow
        }
        $nodeOk = $false
    } else {
        Write-Host "[ok] node v$nodeMajor" -ForegroundColor Green
    }
}
$prereqsOk = $nodeOk -and $prereqsOk

$prereqsOk = (Install-IfMissing -Command npm -DisplayName 'npm' -ManualHint 'npm ships with Node - fix the Node install above.') -and $prereqsOk
$prereqsOk = (Install-IfMissing -Command dotnet -DisplayName '.NET SDK' -WingetId 'Microsoft.DotNet.SDK.8') -and $prereqsOk

# claude CLI: not on winget - run the official installer ourselves. Note the
# '| iex' part is what executes it; a bare 'irm https://claude.ai/install.ps1'
# only downloads and PRINTS the script, installing nothing. The installer drops
# claude.exe into ~\.local\bin but doesn't reliably put that folder on PATH -
# so 'claude' can be "not recognized" while being perfectly installed (seen
# live on this project). Detect and fix that case instead of reinstalling.
$claudeExeFallback = Join-Path $env:USERPROFILE '.local\bin\claude.exe'

function Add-ClaudeBinToPath {
    $bin = Split-Path $claudeExeFallback -Parent
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $bin) {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $bin), 'User')
        Write-Host "[fixed] added $bin to your User PATH - new terminals will resolve 'claude'" -ForegroundColor Green
    }
    if (($env:Path -split ';') -notcontains $bin) { $env:Path += ";$bin" }
}

$claudeOk = $false
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host "[ok] claude CLI (Claude Code)" -ForegroundColor Green
    $claudeOk = $true
} elseif (Test-Path $claudeExeFallback) {
    Write-Host "[installed, not on PATH] claude CLI found at $claudeExeFallback" -ForegroundColor Yellow
    Add-ClaudeBinToPath
    $claudeOk = $true
} else {
    Write-Host "[missing] claude CLI (Claude Code) (required)" -ForegroundColor Red
    $answer = Read-Host -Prompt "  Run the official installer now? (Enter = yes, n = skip)"
    if ($answer -notmatch '^n') {
        Invoke-RestMethod 'https://claude.ai/install.ps1' | Invoke-Expression
        Update-ProcessPath
        if (Test-Path $claudeExeFallback) { Add-ClaudeBinToPath }
        $claudeOk = [bool]((Get-Command claude -ErrorAction SilentlyContinue) -or (Test-Path $claudeExeFallback))
        if ($claudeOk) {
            Write-Host "[installed] claude CLI" -ForegroundColor Green
        } else {
            Write-Host "  Installer finished but 'claude' isn't visible yet - open a NEW terminal and re-run this script." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Install manually with the FULL command (irm alone only prints the script):" -ForegroundColor Yellow
        Write-Host "  $ClaudeInstallCmd" -ForegroundColor Yellow
    }
}
$prereqsOk = $claudeOk -and $prereqsOk

[void](Install-IfMissing -Command docker -DisplayName 'Docker' -Optional `
    -ManualHint 'Only the consented Testcontainers/compose paths use it - install Docker Desktop later if a run offers them.')

if (-not $prereqsOk) {
    Write-Host ""
    Write-Host "Some required tools are still missing - fix the red lines above (a new" -ForegroundColor Yellow
    Write-Host "terminal is usually enough after an install), then re-run this script." -ForegroundColor Yellow
}
Write-Host ""

# --- 2. environment variables -----------------------------------------------------

if ([Environment]::GetEnvironmentVariable('MCP_VISMA_JIRA_PATH', 'User')) {
    Write-Host "[obsolete] MCP_VISMA_JIRA_PATH is set but no longer used - the Jira MCP is" -ForegroundColor Yellow
    Write-Host "  retired (scripts/jira.ps1 calls the gateway directly). Clear it with:" -ForegroundColor Yellow
    Write-Host "  .\scripts\setup-mcp.ps1 -Reset MCP_VISMA_JIRA_PATH" -ForegroundColor Yellow
}

if ([Environment]::GetEnvironmentVariable('JIRA_PERSONAL_ACCESS_TOKEN', 'User')) {
    Write-Host "[already set] JIRA_PERSONAL_ACCESS_TOKEN" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Jira token - required. Used by scripts/jira.ps1 (direct REST, not an MCP)."
    Write-Host "Opening $JiraTokenPage ..."
    Write-Host "There: Personal Access Tokens (left menu) -> Create token -> copy it."
    Start-Process $JiraTokenPage
    $secure = Read-Host -Prompt 'Paste your Jira Personal Access Token' -AsSecureString
    $value = ConvertFrom-SecureStringPlain -Secure $secure
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Host "[skipped] JIRA_PERSONAL_ACCESS_TOKEN - the Jira lane will report SKIPPED until it's set; re-run this script." -ForegroundColor Yellow
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

# --- 3. Figma claude.ai connector ---------------------------------------------------

$claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claude) {
    $fallback = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path $fallback) { $claude = $fallback }
}
if ($claude) {
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
} else {
    Write-Host "[skipped] Figma connector check - claude CLI not available (see prerequisites above)." -ForegroundColor Yellow
}

# --- 4. status check: all MCPs + live Jira probe -------------------------------------

Write-Host ""
Write-Host "Checking MCP servers and Jira..."
& (Join-Path $PSScriptRoot 'check-mcp.ps1')

Write-Host ""
Write-Host "Done. Fully restart Claude Code - env vars only apply to new sessions -" -ForegroundColor Cyan
Write-Host "then approve the MCP prompt on first open ('Pending approval' above is" -ForegroundColor Cyan
Write-Host "expected until you do). Verify with /mcp." -ForegroundColor Cyan
