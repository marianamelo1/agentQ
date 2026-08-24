#Requires -Version 5.1
<#
jira.ps1  -  read-only Jira ticket fetch over REST. No MCP involved.

Calls the Visma integration-hub Jira gateway directly (the same verb-style API the
retired mcp-visma-jira server wrapped):
  GET {hub}/get_issue?issueIdOrKey={key}   with   Authorization: Bearer {PAT}

Env:
  JIRA_PERSONAL_ACCESS_TOKEN   required (Jira -> Profile -> Personal Access Tokens;
                               set via scripts/setup-mcp.ps1). Never assumed present:
                               missing -> honest SKIPPED artifact, never a crash.
  JIRA_INTEGRATION_HUB_URL     optional override; the generic prod gateway is the
                               default below.

Output contract (scripts/CONTRACTS.md - jira-ticket.json): the artifact at -OutPath
is ALWAYS written (status carries the honesty when the fetch couldn't happen), and
the one stdout line is compact JSON {status, issueKey, artifact} - parse it, don't
read it as prose. Exit code is 0 for SKIPPED/DEGRADED outcomes (they are honest
results, not failures); non-zero only for unusable invocations.

The ticket text in the artifact is Jira WIKI MARKUP (h2., *bold*, {{code}}), not
Markdown. This script never prints or writes the token, and extracts figma.com
links mechanically so agents don't need to re-grep raw text.

Usage:
  .\scripts\jira.ps1 -IssueIdOrKey EC-1234 -OutPath <workspaceDir>\jira-ticket.json
  .\scripts\jira.ps1 -IssueIdOrKey https://jira.visma.com/browse/EC-1234 -OutPath ...
  .\scripts\jira.ps1 -Probe        connectivity/auth check only - no artifact
#>
[CmdletBinding()]
param(
    [string]$IssueIdOrKey,
    [string]$OutPath,
    [int]$TimeoutSec = 30,
    [switch]$Probe
)

$ErrorActionPreference = 'Stop'

# Composed at runtime so this file stays pure ASCII (PS 5.1 reads BOM-less files as ANSI).
$EmDash = [char]0x2014

$HubUrlDefault = 'https://prod.integration-hub.visma.com/jira_gateway'
$JiraBrowseUrl = 'https://jira.visma.com/browse'
$EpicLinkFieldId = 'customfield_13061'
$MaxComments = 10

function Get-EnvVarAnyScope {
    # Process first; User-scope fallback lets a token set moments ago by
    # setup-mcp.ps1 work without restarting the terminal.
    param([Parameter(Mandatory)][string]$Name)
    $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'User') }
    return $v
}

function Resolve-IssueKey {
    # Accepts a bare key, a /browse/KEY URL, or a /projects/*/issues/KEY URL.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    foreach ($pattern in @(
        '^(?<key>[A-Za-z][A-Za-z0-9]+-\d+)$',
        '/browse/(?<key>[A-Za-z][A-Za-z0-9]+-\d+)',
        '/projects/[^/]+/issues/(?<key>[A-Za-z][A-Za-z0-9]+-\d+)'
    )) {
        if ($t -match $pattern) { return $Matches['key'].ToUpperInvariant() }
    }
    return $null
}

function Get-HumanizedError {
    param([int]$Code, [string]$Fallback)
    switch ($Code) {
        401 { "authentication failed $EmDash the Jira personal access token may have expired (re-run scripts/setup-mcp.ps1 -Reset JIRA_PERSONAL_ACCESS_TOKEN, then setup again)" }
        403 { 'permission denied - no access to this issue or project' }
        404 { 'issue or project not found' }
        default { $Fallback }
    }
}

function Get-FigmaLinks {
    param([string[]]$Texts)
    $links = New-Object System.Collections.Generic.List[string]
    foreach ($text in $Texts) {
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        foreach ($m in [regex]::Matches($text, 'https://(?:www\.)?figma\.com/[^\s\]\|>"'')]+')) {
            if (-not $links.Contains($m.Value)) { [void]$links.Add($m.Value) }
        }
    }
    return @($links)
}

function Write-Artifact {
    param([Parameter(Mandatory)]$Object)
    if (-not $OutPath) { return }
    $dir = Split-Path $OutPath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $Object | ConvertTo-Json -Depth 10
    # UTF-8 without BOM, per CONTRACTS.md.
    [System.IO.File]::WriteAllText($OutPath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Complete-Run {
    # The single contractual stdout line.
    param([Parameter(Mandatory)][string]$Status, [string]$IssueKey)
    $line = [ordered]@{
        status   = $Status
        issueKey = if ($IssueKey) { $IssueKey } else { $null }
        artifact = if ($OutPath) { $OutPath } else { $null }
    }
    Write-Output ($line | ConvertTo-Json -Compress)
}

function New-DegradedArtifact {
    param([Parameter(Mandatory)][string]$Status, [string]$IssueKey)
    return [ordered]@{
        status                = $Status
        issueKey              = if ($IssueKey) { $IssueKey } else { $null }
        browseUrl             = if ($IssueKey) { "$JiraBrowseUrl/$IssueKey" } else { $null }
        summary               = $null
        descriptionWikiMarkup = $null
        issueType             = $null
        issueStatus           = $null
        labels                = @()
        parentKey             = $null
        epicKey               = $null
        figmaLinks            = @()
        comments              = @()
        fetchedAt             = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

# --- resolve inputs -------------------------------------------------------------

if (-not $Probe -and -not $IssueIdOrKey) {
    throw '-IssueIdOrKey is required (or use -Probe for a connectivity check).'
}

$token = Get-EnvVarAnyScope -Name 'JIRA_PERSONAL_ACCESS_TOKEN'
$hubUrl = Get-EnvVarAnyScope -Name 'JIRA_INTEGRATION_HUB_URL'
if ([string]::IsNullOrWhiteSpace($hubUrl)) { $hubUrl = $HubUrlDefault }
$hubUrl = $hubUrl.TrimEnd('/')

if ([string]::IsNullOrWhiteSpace($token)) {
    $status = "SKIPPED $EmDash Jira not configured (JIRA_PERSONAL_ACCESS_TOKEN not set; run scripts/setup-mcp.ps1)"
    if (-not $Probe) { Write-Artifact (New-DegradedArtifact -Status $status -IssueKey (Resolve-IssueKey $IssueIdOrKey)) }
    Complete-Run -Status $status
    return
}

if ($Probe) {
    # Auth/reachability check against a deliberately nonexistent issue:
    # 200/400/404 -> the gateway answered and accepted the token; 401 -> bad token.
    $probeKey = 'AGENTQ-0'
    try {
        Invoke-RestMethod -Method Get -TimeoutSec $TimeoutSec `
            -Uri "$hubUrl/get_issue?issueIdOrKey=$probeKey" `
            -Headers @{ Authorization = "Bearer $token"; Accept = 'application/json' } | Out-Null
        Complete-Run -Status "OK $EmDash Jira gateway reachable, token accepted"
    } catch {
        $code = 0
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 400 -or $code -eq 404) {
            Complete-Run -Status "OK $EmDash Jira gateway reachable, token accepted"
        } elseif ($code -gt 0) {
            Complete-Run -Status "DEGRADED $EmDash $(Get-HumanizedError -Code $code -Fallback "gateway returned HTTP $code")"
        } elseif ($_.Exception.Message -match '(?i)time.?out') {
            Complete-Run -Status "DEGRADED $EmDash request timed out after ${TimeoutSec}s"
        } else {
            Complete-Run -Status "DEGRADED $EmDash gateway unreachable: $($_.Exception.Message)"
        }
    }
    return
}

$key = Resolve-IssueKey $IssueIdOrKey
if (-not $key) {
    $status = "DEGRADED $EmDash unrecognized issue key or URL: $IssueIdOrKey"
    Write-Artifact (New-DegradedArtifact -Status $status)
    Complete-Run -Status $status
    return
}

# --- fetch -----------------------------------------------------------------------

try {
    $issue = Invoke-RestMethod -Method Get -TimeoutSec $TimeoutSec `
        -Uri "$hubUrl/get_issue?issueIdOrKey=$key" `
        -Headers @{ Authorization = "Bearer $token"; Accept = 'application/json' }
} catch {
    $code = 0
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $code = [int]$_.Exception.Response.StatusCode }
    $reason = if ($code -gt 0) {
        Get-HumanizedError -Code $code -Fallback "gateway returned HTTP $code"
    } elseif ($_.Exception.Message -match '(?i)time.?out') {
        "request timed out after ${TimeoutSec}s"
    } else {
        "request failed: $($_.Exception.Message)"
    }
    $status = "DEGRADED $EmDash $reason"
    Write-Artifact (New-DegradedArtifact -Status $status -IssueKey $key)
    Complete-Run -Status $status -IssueKey $key
    return
}

# --- shape the artifact ------------------------------------------------------------

$f = $issue.fields

$rawComments = @()
if ($f.comment) {
    if ($f.comment.comments) { $rawComments = @($f.comment.comments) }
    elseif ($f.comment -is [System.Array]) { $rawComments = @($f.comment) }
}
$comments = @()
foreach ($c in ($rawComments | Select-Object -Last $MaxComments)) {
    $comments += [ordered]@{
        author         = [string]$c.author.displayName
        created        = [string]$c.created
        bodyWikiMarkup = [string]$c.body
    }
}

$commentBodies = @($comments | ForEach-Object { $_.bodyWikiMarkup })
$figmaLinks = Get-FigmaLinks -Texts (@([string]$f.summary, [string]$f.description) + $commentBodies)

$resolvedKey = if ($issue.key) { [string]$issue.key } else { $key }
$artifact = [ordered]@{
    status                = 'OK'
    issueKey              = $resolvedKey
    browseUrl             = "$JiraBrowseUrl/$resolvedKey"
    summary               = [string]$f.summary
    descriptionWikiMarkup = [string]$f.description
    issueType             = [string]$f.issuetype.name
    issueStatus           = [string]$f.status.name
    labels                = @($f.labels | ForEach-Object { [string]$_ })
    parentKey             = $(if ($f.parent -and $f.parent.key) { [string]$f.parent.key } else { $null })
    epicKey               = $(if ($f.$EpicLinkFieldId) { [string]$f.$EpicLinkFieldId } else { $null })
    figmaLinks            = $figmaLinks
    comments              = $comments
    fetchedAt             = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

Write-Artifact $artifact
Complete-Run -Status 'OK' -IssueKey $resolvedKey
