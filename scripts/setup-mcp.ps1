#Requires -Version 5.1
<#
setup-mcp.ps1  -  one-time developer setup for agentQ, end to end.
Works on Windows (PowerShell 5.1+) and macOS/Linux (pwsh 7+ - on macOS:
`brew install --cask powershell`, then `pwsh ./scripts/setup-mcp.ps1`).

Does the whole setup in one run:
  1. checks every tool agentQ's scripts need - git, Node 18+, npm, the .NET SDK,
     the claude CLI - and offers to install anything missing (winget on Windows,
     Homebrew on macOS, the official installer for claude). Docker is optional
     (only the consented Testcontainers paths use it) - reported, never
     installed here.
  2. downloads and verifies the pinned lane tools so no review ever pauses to
     install anything: oasdiff (contract lane, checksum-verified into tools/),
     dotnet-stryker (mutation lane, machine-shared under tools/stryker),
     dotnet-coverage (coverage lane, global dotnet tool), and Playwright
     browsers for every registered repo that declares @playwright/test.
     (coverlet.console - the coverage FALLBACK for a machine where
     dotnet-coverage's native profiler never attaches, a documented gap on
     osx-arm64 - is deliberately NOT installed here: run-tests.ps1 installs
     it itself, lazily, only once dotnet-coverage has already been proven
     broken on that machine. Pre-installing it for every developer would pay
     a real download cost the overwhelming majority of machines never need.)
     The version pins live in contract-check.ps1 / stryker-run.ps1 - this
     script just invokes their -EnsureTool modes. Cross-platform (Windows +
     macOS).
  3. persists the environment variables agentQ needs, opening the token pages
     in your browser so you only have to paste:
       JIRA_PERSONAL_ACCESS_TOKEN  required - used by scripts/jira.ps1 (a direct
                                   REST call to the Jira gateway; NOT an MCP);
                                   created at jira.visma.com -> Profile ->
                                   Personal Access Tokens
       TESTOMATIO_API_TOKEN        optional - the Testomatio MCP server in
                                   .mcp.json; app.testomat.io -> Account -> tokens
  4. offers to connect the Figma claude.ai connector (browser login with your
     Visma account) if it isn't already
  5. ends with check-mcp.ps1: every MCP server's status, the lane tools, the
     env vars, and a LIVE Jira connectivity probe - so you see immediately
     whether it all works.

The Jira MCP (mcp-visma-jira) is retired: agentQ calls the gateway directly via
scripts/jira.ps1. No clone, no MCP_VISMA_JIRA_PATH - if that variable is still
set from an old setup, this script tells you and you can clear it with -Reset.
The gateway URL is generic (same for everyone) and defaulted inside jira.ps1;
JIRA_INTEGRATION_HUB_URL exists only as an optional override.

Run this yourself in a normal terminal (NOT through Claude Code - it prompts
interactively, which Claude Code's own shell tools can't answer). Safe to
re-run: anything already installed/set is left alone and reported, never
silently overwritten. No token value is ever written to a repo file or echoed.

Where values persist:
  Windows      User-scope environment variables (HKCU\Environment)
  macOS/Linux  export lines in your shell profile (~/.zshrc, ~/.bashrc, or
               ~/.profile - User-scope env vars don't exist on Unix)
Either way they also land in this process, so the final check works right away;
any already-open Claude Code still needs a full restart to see them.

Usage:
  .\scripts\setup-mcp.ps1                    full setup, skips anything already done
  .\scripts\setup-mcp.ps1 -Reset <VarName>   clears one variable so it can be re-entered
  (macOS: pwsh ./scripts/setup-mcp.ps1)
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')]
    [string]$Reset
)

$ErrorActionPreference = 'Stop'

# $IsWindows doesn't exist on Windows PowerShell 5.1 (which is Windows-only).
$IsWin = if ($null -ne $IsWindows) { $IsWindows } else { $true }

# Unix persistence target: the profile of the user's login shell.
$ProfileFile = if ($IsWin) { $null }
    elseif ($env:SHELL -match 'zsh')  { Join-Path $HOME '.zshrc' }
    elseif ($env:SHELL -match 'bash') { Join-Path $HOME '.bashrc' }
    else                              { Join-Path $HOME '.profile' }

$JiraTokenPage     = 'https://jira.visma.com/secure/ViewProfile.jspa'
$TestomatTokenPage = 'https://app.testomat.io/account/access_tokens'
$ClaudeInstallCmd  = if ($IsWin) { 'irm https://claude.ai/install.ps1 | iex' }
                     else        { 'curl -fsSL https://claude.ai/install.sh | bash' }
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

function Get-PersistedEnvVar {
    # Windows: User scope. Unix: this process, else the export line in the profile.
    param([Parameter(Mandatory)][string]$Name)
    if ($IsWin) { return [Environment]::GetEnvironmentVariable($Name, 'User') }
    $process = [Environment]::GetEnvironmentVariable($Name)
    if ($process) { return $process }
    if (Test-Path $ProfileFile) {
        $line = Select-String -Path $ProfileFile -Pattern "^\s*export\s+$Name=" | Select-Object -Last 1
        if ($line) { return ($line.Line -replace "^\s*export\s+$Name=", '').Trim("'", '"') }
    }
    return $null
}

function Set-AgentQEnvVar {
    # Persist (User scope on Windows, shell profile on Unix) + Process scope so
    # the final check-mcp run (and any child of this terminal) sees the value
    # immediately.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    if ($IsWin) {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
        Write-Host "[set] $Name" -ForegroundColor Green
    } else {
        $escaped = $Value -replace "'", "'\''"
        Add-Content -Path $ProfileFile -Value "export $Name='$escaped'"
        Write-Host "[set] $Name -> $ProfileFile" -ForegroundColor Green
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function Open-Url {
    param([Parameter(Mandatory)][string]$Url)
    if ($IsWin)       { Start-Process $Url }
    elseif ($IsMacOS) { & open $Url }
    else              { & xdg-open $Url }
}

function Update-ProcessPath {
    # Pick up PATH additions made by a winget install without reopening the
    # terminal. Windows-only concept; brew's bin dirs are already on PATH.
    if (-not $IsWin) { return }
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Install-IfMissing {
    # Returns $true when the tool is available by the time we return.
    # WingetId installs on Windows; BrewFormula (+ -BrewCask) on macOS/Linux.
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$WingetId,
        [string]$BrewFormula,
        [switch]$BrewCask,
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
    if ($IsWin -and $WingetId -and (Get-Command winget -ErrorAction SilentlyContinue)) {
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
    } elseif (-not $IsWin -and $BrewFormula -and (Get-Command brew -ErrorAction SilentlyContinue)) {
        $answer = Read-Host -Prompt "  Install $DisplayName now via Homebrew? (Enter = yes, n = skip)"
        if ($answer -notmatch '^n') {
            if ($BrewCask) { brew install --cask $BrewFormula } else { brew install $BrewFormula }
            if (Get-Command $Command -ErrorAction SilentlyContinue) {
                Write-Host "[installed] $DisplayName" -ForegroundColor Green
                return $true
            }
            Write-Host "  Installed, but '$Command' still isn't on PATH in this session - open a NEW terminal and re-run this script." -ForegroundColor Yellow
            return $false
        }
    } elseif ($IsWin -and $WingetId) {
        Write-Host "  winget isn't available - install manually: winget id $WingetId" -ForegroundColor Yellow
    } elseif (-not $IsWin -and $BrewFormula) {
        $caskFlag = if ($BrewCask) { '--cask ' } else { '' }
        Write-Host "  Homebrew isn't available - install it from https://brew.sh, then: brew install $caskFlag$BrewFormula" -ForegroundColor Yellow
    }
    if ($ManualHint) { Write-Host "  $ManualHint" -ForegroundColor Yellow }
    return $false
}

if ($Reset) {
    if ($IsWin) {
        [Environment]::SetEnvironmentVariable($Reset, $null, 'User')
    } elseif (Test-Path $ProfileFile) {
        $kept = Get-Content $ProfileFile | Where-Object { $_ -notmatch "^\s*export\s+$Reset=" }
        Set-Content -Path $ProfileFile -Value $kept
    }
    [Environment]::SetEnvironmentVariable($Reset, $null, 'Process')
    Write-Host "[cleared] $Reset - re-run this script without -Reset to set it again."
    return
}

Write-Host "agentQ setup"
Write-Host "Checks/installs the tools every script needs, downloads the pinned lane"
Write-Host "tools (oasdiff, dotnet-stryker, dotnet-coverage,"
Write-Host "Playwright browsers) so"
Write-Host "no review ever pauses to install, saves the environment variables"
Write-Host "(opening the token pages for you), and finishes with a status check that"
Write-Host "includes a live Jira probe. Outside tools/, nothing is written to any"
Write-Host "file in this repo."
Write-Host ""

# --- 1. prerequisites (install if missing) --------------------------------------

Write-Host "Prerequisites:"
$prereqsOk = $true

$prereqsOk = (Install-IfMissing -Command git -DisplayName 'git' -WingetId 'Git.Git' -BrewFormula 'git') -and $prereqsOk

$nodeOk = Install-IfMissing -Command node -DisplayName "Node $MinNodeMajor+" -WingetId 'OpenJS.NodeJS.LTS' -BrewFormula 'node'
if ($nodeOk) {
    $nodeMajor = [int]((node --version) -replace '^v' -split '\.')[0]
    if ($nodeMajor -lt $MinNodeMajor) {
        Write-Host "[outdated] Node v$nodeMajor found - v$MinNodeMajor+ required (Playwright/Testomatio MCP servers)." -ForegroundColor Red
        if ($IsWin -and (Get-Command winget -ErrorAction SilentlyContinue)) {
            $answer = Read-Host -Prompt "  Upgrade via winget now? (Enter = yes, n = skip)"
            if ($answer -notmatch '^n') {
                winget install --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
                Update-ProcessPath
                Write-Host "  Open a NEW terminal and re-run this script so the upgraded Node is picked up." -ForegroundColor Yellow
            }
        } elseif (-not $IsWin -and (Get-Command brew -ErrorAction SilentlyContinue)) {
            $answer = Read-Host -Prompt "  Upgrade via Homebrew now? (Enter = yes, n = skip)"
            if ($answer -notmatch '^n') {
                brew install node
                Write-Host "  Open a NEW terminal and re-run this script so the upgraded Node is picked up." -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Upgrade Node manually (https://nodejs.org), then re-run this script." -ForegroundColor Yellow
        }
        $nodeOk = $false
    } else {
        Write-Host "[ok] node v$nodeMajor" -ForegroundColor Green
    }
}
$prereqsOk = $nodeOk -and $prereqsOk

$prereqsOk = (Install-IfMissing -Command npm -DisplayName 'npm' -ManualHint 'npm ships with Node - fix the Node install above.') -and $prereqsOk
$prereqsOk = (Install-IfMissing -Command dotnet -DisplayName '.NET SDK' -WingetId 'Microsoft.DotNet.SDK.8' -BrewFormula 'dotnet-sdk' -BrewCask) -and $prereqsOk

# claude CLI: not in winget/brew - run the official installer ourselves. Note
# the '| iex' / '| bash' part is what executes it; the bare download alone only
# PRINTS the script, installing nothing. The installer drops the binary into
# ~/.local/bin but doesn't reliably put that folder on PATH - so 'claude' can
# be "not recognized" while being perfectly installed (seen live on this
# project). Detect and fix that case instead of reinstalling.
$claudeExeName = if ($IsWin) { 'claude.exe' } else { 'claude' }
$claudeExeFallback = Join-Path $HOME (Join-Path '.local' (Join-Path 'bin' $claudeExeName))

function Add-ClaudeBinToPath {
    $bin = Split-Path $claudeExeFallback -Parent
    if ($IsWin) {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (($userPath -split ';') -notcontains $bin) {
            [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $bin), 'User')
            Write-Host "[fixed] added $bin to your User PATH - new terminals will resolve 'claude'" -ForegroundColor Green
        }
        if (($env:Path -split ';') -notcontains $bin) { $env:Path += ";$bin" }
    } else {
        if (-not (Test-Path $ProfileFile) -or -not (Select-String -Path $ProfileFile -Pattern '\.local/bin' -Quiet)) {
            Add-Content -Path $ProfileFile -Value 'export PATH="$HOME/.local/bin:$PATH"'
            Write-Host "[fixed] added $bin to PATH in $ProfileFile - new terminals will resolve 'claude'" -ForegroundColor Green
        }
        if (($env:PATH -split ':') -notcontains $bin) { $env:PATH = "$bin`:$env:PATH" }
    }
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
        if ($IsWin) {
            Invoke-RestMethod 'https://claude.ai/install.ps1' -TimeoutSec 120 | Invoke-Expression
            Update-ProcessPath
        } else {
            # WHY --max-time on curl: same anti-hang reasoning as the Windows branch's
            # -TimeoutSec -- a stalled connection here would otherwise block this
            # interactive setup script indefinitely with no feedback.
            & bash -c 'curl -fsSL --max-time 120 https://claude.ai/install.sh | bash'
        }
        if (Test-Path $claudeExeFallback) { Add-ClaudeBinToPath }
        $claudeOk = [bool]((Get-Command claude -ErrorAction SilentlyContinue) -or (Test-Path $claudeExeFallback))
        if ($claudeOk) {
            Write-Host "[installed] claude CLI" -ForegroundColor Green
        } else {
            Write-Host "  Installer finished but 'claude' isn't visible yet - open a NEW terminal and re-run this script." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Install manually with the FULL command (the download alone only prints the script):" -ForegroundColor Yellow
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

# --- 2. lane tools (downloaded & verified NOW - no run ever pauses to install) -----
# Version pins live in the owning runtime scripts (single source of truth);
# their -EnsureTool modes are invoked here. Running this script IS the consent
# for these network installs (CLAUDE.md precondition 5).

Write-Host "Lane tools (pinned versions - installed now so the first review never"
Write-Host "stops for a download):"

# oasdiff - contract lane (pin + sha256 checksum enforced by contract-check.ps1).
try {
    & (Join-Path $PSScriptRoot 'contract-check.ps1') -EnsureTool | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "contract-check.ps1 -EnsureTool exited $LASTEXITCODE" }
    Write-Host "[ok] oasdiff" -ForegroundColor Green
} catch {
    Write-Host "[failed] oasdiff - $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Safety net: the contract lane still installs it on first use." -ForegroundColor Yellow
}

if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    # dotnet-stryker - mutation lane (pin enforced by stryker-run.ps1; a repo's
    # own committed tool-manifest pin still wins at run time).
    try {
        & (Join-Path $PSScriptRoot 'stryker-run.ps1') -EnsureTool | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) { throw "stryker-run.ps1 -EnsureTool exited $LASTEXITCODE" }
        Write-Host "[ok] dotnet-stryker" -ForegroundColor Green
    } catch {
        Write-Host "[failed] dotnet-stryker - $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Safety net: the mutation lane still installs it on first use." -ForegroundColor Yellow
    }

    # dotnet-coverage - the coverage wrapper that needs zero csproj changes.
    if (Get-Command dotnet-coverage -ErrorAction SilentlyContinue) {
        Write-Host "[ok] dotnet-coverage" -ForegroundColor Green
    } else {
        try {
            # `tool update --global` installs when absent, upgrades when present.
            dotnet tool update --global dotnet-coverage
            Update-ProcessPath
            # Unix: ~/.dotnet/tools may not be on PATH in this session yet.
            $globalToolsBin = Join-Path $HOME (Join-Path '.dotnet' 'tools')
            if (-not (Get-Command dotnet-coverage -ErrorAction SilentlyContinue) -and
                (($env:PATH -split [IO.Path]::PathSeparator) -notcontains $globalToolsBin)) {
                $env:PATH += ([IO.Path]::PathSeparator + $globalToolsBin)
            }
            if (Get-Command dotnet-coverage -ErrorAction SilentlyContinue) {
                Write-Host "[installed] dotnet-coverage" -ForegroundColor Green
            } else {
                Write-Host "[installed] dotnet-coverage - not visible in this session; open a NEW terminal and re-run check-mcp.ps1" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "[failed] dotnet-coverage - $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # coverlet.console (the coverage fallback for a machine where
    # dotnet-coverage's native profiler never attaches) is deliberately NOT
    # installed here -- run-tests.ps1 installs it on demand, lazily, only
    # once calibration.json has already proven dotnet-coverage broken on
    # that machine. See CLAUDE.md precondition 5.
} else {
    Write-Host "[skipped] dotnet-stryker + dotnet-coverage - need the .NET SDK (see above), then re-run this script" -ForegroundColor Yellow
}

# Playwright browsers - E2E lane, for registered repos declaring @playwright/test.
# The install runs INSIDE the repo so npx resolves the repo's own pinned
# playwright (never a float-install); browsers land in one machine-level cache.
function Get-ProductRepoPathsFromConfig {
    # Minimal JSONC -> JSON, same pragmatic parser as worktree.ps1 (self-contained
    # scripts by convention - no shared module).
    param([Parameter(Mandatory)][string]$Path)
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
    $paths = @()
    if ($cfg.PSObject.Properties.Name -contains 'productRepos') {
        foreach ($prop in $cfg.productRepos.PSObject.Properties) { $paths += [string]$prop.Value }
    }
    return $paths
}

$configPath = Join-Path (Split-Path $PSScriptRoot -Parent) (Join-Path '.claude' 'qa-agent-config.jsonc')
if (-not (Test-Path $configPath)) {
    Write-Host "[skipped] Playwright browsers - no .claude/qa-agent-config.jsonc yet; copy the example config, then re-run this script" -ForegroundColor Yellow
} elseif (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
    Write-Host "[skipped] Playwright browsers - npx not available (fix Node above)" -ForegroundColor Yellow
} else {
    $pwInstalled = $false
    $pwDeclared = $false
    foreach ($repoPath in (Get-ProductRepoPathsFromConfig -Path $configPath)) {
        if ([string]::IsNullOrWhiteSpace($repoPath) -or -not (Test-Path -LiteralPath $repoPath)) { continue }
        $pkgJson = Join-Path $repoPath 'package.json'
        if (-not (Test-Path -LiteralPath $pkgJson)) { continue }
        if (-not (Select-String -Path $pkgJson -Pattern '@playwright/test' -Quiet)) { continue }
        $pwDeclared = $true
        $localPw = Join-Path $repoPath (Join-Path 'node_modules' (Join-Path '@playwright' 'test'))
        if (-not (Test-Path -LiteralPath $localPw)) {
            Write-Host "[skipped] Playwright browsers for $repoPath - run npm install there first, then re-run this script" -ForegroundColor Yellow
            continue
        }
        Write-Host "  Installing Playwright browsers (repo: $repoPath - one machine-level cache, safe to re-run)..."
        Push-Location $repoPath
        try {
            npx playwright install
            if ($LASTEXITCODE -eq 0) { $pwInstalled = $true }
            else { Write-Host "[failed] playwright install exited $LASTEXITCODE (repo: $repoPath)" -ForegroundColor Red }
        } finally { Pop-Location }
    }
    if ($pwInstalled) {
        Write-Host "[ok] Playwright browsers" -ForegroundColor Green
    } elseif (-not $pwDeclared) {
        Write-Host "[skipped] Playwright browsers - no registered repo declares @playwright/test (E2E lane is frontend-only)" -ForegroundColor Yellow
    }
}
Write-Host ""

# --- 3. environment variables -----------------------------------------------------

if (Get-PersistedEnvVar -Name 'MCP_VISMA_JIRA_PATH') {
    Write-Host "[obsolete] MCP_VISMA_JIRA_PATH is set but no longer used - the Jira MCP is" -ForegroundColor Yellow
    Write-Host "  retired (scripts/jira.ps1 calls the gateway directly). Clear it with:" -ForegroundColor Yellow
    Write-Host "  .\scripts\setup-mcp.ps1 -Reset MCP_VISMA_JIRA_PATH" -ForegroundColor Yellow
}

if (Get-PersistedEnvVar -Name 'JIRA_PERSONAL_ACCESS_TOKEN') {
    Write-Host "[already set] JIRA_PERSONAL_ACCESS_TOKEN" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Jira token - required. Used by scripts/jira.ps1 (direct REST, not an MCP)."
    Write-Host "Opening $JiraTokenPage ..."
    Write-Host "There: Personal Access Tokens (left menu) -> Create token -> copy it."
    Open-Url $JiraTokenPage
    $secure = Read-Host -Prompt 'Paste your Jira Personal Access Token' -AsSecureString
    $value = ConvertFrom-SecureStringPlain -Secure $secure
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Host "[skipped] JIRA_PERSONAL_ACCESS_TOKEN - the Jira lane will report SKIPPED until it's set; re-run this script." -ForegroundColor Yellow
    } else {
        Set-AgentQEnvVar -Name 'JIRA_PERSONAL_ACCESS_TOKEN' -Value $value
    }
}

if (Get-PersistedEnvVar -Name 'TESTOMATIO_API_TOKEN') {
    Write-Host "[already set] TESTOMATIO_API_TOKEN" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Testomatio token is optional - only the impact/Testomat lane uses it."
    $answer = Read-Host -Prompt 'Set it now? (y = open the token page, Enter = skip)'
    if ($answer -match '^y') {
        Write-Host "Opening $TestomatTokenPage ..."
        Open-Url $TestomatTokenPage
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

# --- 4. Figma claude.ai connector ---------------------------------------------------

$claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claude -and (Test-Path $claudeExeFallback)) { $claude = $claudeExeFallback }
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

# --- 5. status check: all MCPs + lane tools + live Jira probe ------------------------

Write-Host ""
Write-Host "Checking MCP servers and Jira..."
& (Join-Path $PSScriptRoot 'check-mcp.ps1')

Write-Host ""
Write-Host "Done. Fully restart Claude Code - env vars only apply to new sessions -" -ForegroundColor Cyan
Write-Host "then approve the MCP prompt on first open ('Pending approval' above is" -ForegroundColor Cyan
Write-Host "expected until you do). Verify with /mcp." -ForegroundColor Cyan
