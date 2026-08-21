<#
.SYNOPSIS
    render-artifacts.ps1 - template-render HUMAN artifacts (Postman collection + Hurl file)
    from the framework-neutral scenario IR (workspace scenarios/scenario-*.json).

.DESCRIPTION
    Reads run-manifest.json (path via -Manifest), collects every
    <workspaceDir>\scenarios\scenario-*.json that carries an "http" block, and renders:

      1. <workspaceDir>\artifacts\agentq-<ticketKey>.postman_collection.json  (Collection v2.1.0)
      2. <workspaceDir>\artifacts\agentq-<ticketKey>.hurl

    WHY templates and not an LLM: these are byte-stable template renders - zero tokens,
    same input bytes -> same output bytes, reproducible on every re-run. They are HUMAN
    artifacts (import into Postman / run with `hurl --test` against a consented local
    instance) and NEVER contribute to a verdict; nothing in the pipeline reads them back.

    Exit code 0 = the script ran (skipped/malformed scenarios are warnings, not failures).
    Non-zero = the script itself failed (bad manifest, write outside workspace, ...).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Manifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-Prop {
    param($Object, [string]$Name)
    # WHY: Set-StrictMode -Version Latest turns a read of a missing property on a
    # PSCustomObject into a terminating error. Scenario IR fields are optional by
    # contract, so every access goes through this null-safe lookup.
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    # WHY the comma: function output goes through the pipeline, which unrolls a
    # one-element array value (e.g. an http.body of `[ {...} ]`) into its element.
    # The wrapping array is unrolled once instead, delivering the value unchanged.
    return , $p.Value
}

function ConvertTo-JsonLiteral {
    param($Value)
    # WHY: a JSON literal is also a valid JavaScript expression (for Postman pm.expect)
    # and - for scalars - a valid Hurl predicate literal. ConvertTo-Json gives us
    # invariant-culture numbers, lowercase true/false, and correct string escaping.
    # ConvertTo-Json -InputObject $null throws on PS 5.1, hence the explicit branch.
    if ($null -eq $Value) { return 'null' }
    return (ConvertTo-Json -InputObject $Value -Compress -Depth 12)
}

function Test-IsComplexValue {
    param($Value)
    # Objects and arrays cannot be compared with Hurl's `==` (it takes literals only),
    # so callers downgrade those to an `exists` assert.
    if ($null -eq $Value) { return $false }
    if ($Value -is [System.Collections.IDictionary]) { return $true }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return $true }
    if ($Value -is [System.Array]) { return $true }
    return $false
}

function Get-JsonPathForKey {
    param([string]$Key)
    # WHY bracket form for non-identifier keys: a dot/space/dash inside a key would
    # silently change the meaning of the dotted jsonpath.
    if ($Key -match '^[A-Za-z_][A-Za-z0-9_]*$') { return ('$.' + $Key) }
    $escaped = $Key.Replace('\', '\\').Replace("'", "\'")
    return ("`$['" + $escaped + "']")
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    # WHY not Out-File: on Windows PowerShell 5.1 `-Encoding utf8` writes a BOM.
    # CONTRACTS.md mandates UTF-8 *without* BOM, and hurl rejects a BOM-prefixed file,
    # so we write through .NET with an explicit BOM-less encoder.
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

# Header names whose values must never be copied verbatim into a rendered artifact.
# WHY: the IR should never carry credentials, but if a scenario ever does, the render
# must still be safe to commit/share - placeholders only, NEVER a live value.
$script:SensitiveHeaderNames = @(
    'authorization', 'proxy-authorization', 'x-api-key', 'api-key', 'apikey',
    'x-auth-token', 'cookie', 'set-cookie', 'x-functions-key'
)

function Get-RequestHeaders {
    param($Http, [bool]$HasBody)
    # Returns an ordered list of @{ key; value } pairs for one scenario request.
    $headers = New-Object System.Collections.Generic.List[object]
    if ($HasBody) {
        $headers.Add([ordered]@{ key = 'Content-Type'; value = 'application/json' })
    }
    $sawAuth = $false
    # Defensive: the contract's http block has no "headers" field today, but tolerate
    # one so a future IR extension cannot silently leak a credential into a render.
    $irHeaders = Get-Prop $Http 'headers'
    if ($null -ne $irHeaders -and $irHeaders -is [System.Management.Automation.PSCustomObject]) {
        foreach ($h in $irHeaders.PSObject.Properties) {
            if ($h.Name -ieq 'content-type' -and $HasBody) { continue }  # already emitted
            $value = [string]$h.Value
            if ($script:SensitiveHeaderNames -contains $h.Name.ToLowerInvariant()) {
                # Scrub: keep the header so the request shape is visible, but the value
                # becomes the {{token}} placeholder the human fills in locally.
                $value = '{{token}}'
                if ($h.Name -ieq 'authorization') { $sawAuth = $true; $value = 'Bearer {{token}}' }
            }
            $headers.Add([ordered]@{ key = $h.Name; value = $value })
        }
    }
    if (-not $sawAuth) {
        # WHY always add Authorization: the IR carries no auth info, so every request
        # gets the placeholder form. Humans delete it on anonymous endpoints; the
        # invariant we guarantee is that no artifact ever embeds a live token.
        $headers.Add([ordered]@{ key = 'Authorization'; value = 'Bearer {{token}}' })
    }
    # WHY the comma: pipeline unrolling would flatten a single-header list into a bare
    # object, and Postman's "header" must always be an array to import cleanly.
    return , $headers
}

# ---------------------------------------------------------------------------
# Load + validate manifest
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Manifest)) {
    throw "Manifest not found: $Manifest"
}
# NOTE: the parsed object must NOT be assigned to a variable named $manifest -
# PowerShell variables are case-insensitive and the [string]-typed $Manifest parameter
# would silently coerce the PSCustomObject back into a string.
$runManifest = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json

$workspaceDir = [string](Get-Prop $runManifest 'workspaceDir')
if (-not $workspaceDir) { throw "run-manifest.json has no 'workspaceDir'." }
$workspaceDir = [System.IO.Path]::GetFullPath($workspaceDir)

# Safety rule: this script may only write under <agentQ>\workspace. The manifest is an
# input we did not produce, so verify its workspaceDir actually lives there before
# creating anything. (scripts\ is a direct child of the repo root.)
$repoRoot      = Split-Path -Parent $PSScriptRoot
$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'workspace'))
$sep           = [System.IO.Path]::DirectorySeparatorChar
if (-not $workspaceDir.StartsWith($workspaceRoot + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to write: manifest workspaceDir '$workspaceDir' is outside '$workspaceRoot'."
}
if (-not (Test-Path -LiteralPath $workspaceDir)) {
    throw "Manifest workspaceDir does not exist: $workspaceDir"
}

$ticketKey = [string](Get-Prop $runManifest 'ticketKey')
if (-not $ticketKey) {
    # WHY fallback: intake may run without a resolvable Jira key (no key in branch,
    # no MCP). The artifacts must still render; the branch slug keeps names unique.
    $branch = [string](Get-Prop $runManifest 'branch')
    if (-not $branch) { throw "run-manifest.json has neither 'ticketKey' nor 'branch'." }
    $ticketKey = ($branch -replace '[^A-Za-z0-9._-]', '-')
}

$scenariosDir = Join-Path $workspaceDir 'scenarios'
$artifactsDir = Join-Path $workspaceDir 'artifacts'
$postmanPath  = Join-Path $artifactsDir ("agentq-{0}.postman_collection.json" -f $ticketKey)
$hurlPath     = Join-Path $artifactsDir ("agentq-{0}.hurl" -f $ticketKey)

# ---------------------------------------------------------------------------
# Collect scenarios
# ---------------------------------------------------------------------------

$scenarioFiles = @()
if (Test-Path -LiteralPath $scenariosDir) {
    # WHY sorted by name: a deterministic input order is what keeps the rendered
    # artifacts byte-stable across re-runs (idempotency is a stated contract).
    $scenarioFiles = @(Get-ChildItem -LiteralPath $scenariosDir -Filter 'scenario-*.json' -File |
        Sort-Object -Property Name)
}

$httpScenarios = New-Object System.Collections.Generic.List[object]
$skippedNoHttp = 0
$malformed     = 0

foreach ($file in $scenarioFiles) {
    $scenario = $null
    try {
        $scenario = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        # WHY warn-and-continue: a broken scenario file is a finding about the upstream
        # writer, not a reason to abort rendering the healthy scenarios (exit 0 = ran).
        Write-Warning ("Skipping malformed scenario JSON: {0} ({1})" -f $file.Name, $_.Exception.Message)
        $malformed++
        continue
    }

    $http = Get-Prop $scenario 'http'
    if ($null -eq $http -or -not ($http -is [System.Management.Automation.PSCustomObject])) {
        $skippedNoHttp++   # component/e2e scenarios without an http block are expected
        continue
    }

    $method       = [string](Get-Prop $http 'method')
    $path         = [string](Get-Prop $http 'path')
    $expectStatus = Get-Prop $http 'expectStatus'
    if (-not $method -or -not $path -or $null -eq $expectStatus) {
        Write-Warning ("Skipping {0}: http block missing method/path/expectStatus." -f $file.Name)
        $malformed++
        continue
    }

    $id    = [string](Get-Prop $scenario 'id')
    if (-not $id) { $id = [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
    $title = [string](Get-Prop $scenario 'title')
    if (-not $title) { $title = $id }
    $requirement = [string](Get-Prop $scenario 'requirement')
    if (-not $requirement) { $requirement = 'no AC' }
    if (-not $path.StartsWith('/')) { $path = '/' + $path }   # keep {{baseUrl}}<path> well-formed

    $httpScenarios.Add([pscustomobject]@{
        Id           = $id
        Title        = $title
        Requirement  = $requirement
        Method       = $method.ToUpperInvariant()
        Path         = $path
        Body         = Get-Prop $http 'body'
        ExpectStatus = [int]$expectStatus
        ExpectBody   = Get-Prop $http 'expectBody'
        Http         = $http
        Given        = [string](Get-Prop $scenario 'given')
        When         = [string](Get-Prop $scenario 'when')
        Then         = [string](Get-Prop $scenario 'then')
    })
}

# ---------------------------------------------------------------------------
# Nothing to render -> remove stale artifacts and stop (still exit 0: the script ran)
# ---------------------------------------------------------------------------

if ($httpScenarios.Count -eq 0) {
    # WHY delete instead of leaving old files: this script is idempotent and owns these
    # two paths. If a re-run finds no http scenarios, yesterday's collection would be a
    # misleading leftover that no longer matches the branch.
    foreach ($stale in @($postmanPath, $hurlPath)) {
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force -Confirm:$false }
    }
    Write-Output ("agentQ render-artifacts: 0 http scenarios under {0} ({1} without http block, {2} malformed) - nothing rendered, stale artifacts removed." -f $scenariosDir, $skippedNoHttp, $malformed)
    exit 0
}

if (-not (Test-Path -LiteralPath $artifactsDir)) {
    New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Render 1: Postman Collection v2.1.0
# ---------------------------------------------------------------------------

$items = New-Object System.Collections.Generic.List[object]

foreach ($s in $httpScenarios) {
    $hasBody = ($null -ne $s.Body)

    # --- url: raw keeps the full templated form; path/query are the split form Postman
    # uses for its UI. Query is separated out because Postman treats "path" strictly.
    $pathOnly  = $s.Path
    $queryPart = $null
    $qIdx = $s.Path.IndexOf('?')
    if ($qIdx -ge 0) {
        $pathOnly  = $s.Path.Substring(0, $qIdx)
        $queryPart = $s.Path.Substring($qIdx + 1)
    }
    $segments = @($pathOnly.TrimStart('/').Split('/') | Where-Object { $_ -ne '' })

    $url = [ordered]@{
        raw  = '{{baseUrl}}' + $s.Path
        host = @('{{baseUrl}}')
        path = $segments
    }
    if ($queryPart) {
        $queryItems = New-Object System.Collections.Generic.List[object]
        foreach ($pair in $queryPart.Split('&')) {
            if (-not $pair) { continue }
            $kv = $pair.Split('=', 2)
            $qi = [ordered]@{ key = $kv[0]; value = '' }
            if ($kv.Length -gt 1) { $qi['value'] = $kv[1] }
            $queryItems.Add($qi)
        }
        $url['query'] = $queryItems
    }

    # --- test script: the executable assertions a human gets for free on import.
    $exec = New-Object System.Collections.Generic.List[string]
    $exec.Add(('pm.test("status is {0}", function () {{' -f $s.ExpectStatus))
    $exec.Add(('    pm.expect(pm.response.code).to.eql({0});' -f $s.ExpectStatus))
    $exec.Add('});')
    $expectBody = $s.ExpectBody
    if ($null -ne $expectBody -and
        $expectBody -is [System.Management.Automation.PSCustomObject] -and
        @($expectBody.PSObject.Properties).Count -gt 0) {
        $exec.Add('pm.test("body matches expected keys", function () {')
        $exec.Add('    var body = pm.response.json();')
        foreach ($p in $expectBody.PSObject.Properties) {
            # bracket access + JSON-escaped key: safe for any key name.
            # to.eql = chai deep-equality, so object/array expectations work too.
            $keyLit = ConvertTo-Json -InputObject $p.Name -Compress
            $valLit = ConvertTo-JsonLiteral $p.Value
            $exec.Add(('    pm.expect(body[{0}]).to.eql({1});' -f $keyLit, $valLit))
        }
        $exec.Add('});')
    }

    $request = [ordered]@{
        method = $s.Method
        header = (Get-RequestHeaders -Http $s.Http -HasBody $hasBody)
        url    = $url
    }
    if ($hasBody) {
        # Normalize to LF so the artifact bytes do not depend on the host's newline style.
        $bodyJson = (ConvertTo-Json -InputObject $s.Body -Depth 12) -replace "`r`n", "`n"
        $request['body'] = [ordered]@{
            mode    = 'raw'
            raw     = $bodyJson
            options = [ordered]@{ raw = [ordered]@{ language = 'json' } }
        }
    }
    # Given/When/Then travels along as the request description - pure human context.
    if ($s.Given -or $s.When -or $s.Then) {
        $request['description'] = ("Given: {0}`nWhen: {1}`nThen: {2}`n(Requirement: {3})" -f $s.Given, $s.When, $s.Then, $s.Requirement)
    }

    $items.Add([ordered]@{
        name  = ('{0} {1}' -f $s.Id, $s.Title)
        event = @(
            [ordered]@{
                listen = 'test'
                script = [ordered]@{ type = 'text/javascript'; exec = $exec }
            }
        )
        request = $request
    })
}

$collection = [ordered]@{
    info = [ordered]@{
        name   = ('agentQ {0}' -f $ticketKey)
        schema = 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json'
    }
    item = $items
    # Placeholders only - the human fills these in a Postman environment.
    # NEVER a live value here: the artifact must always be safe to share.
    variable = @(
        [ordered]@{ key = 'baseUrl'; value = '' },
        [ordered]@{ key = 'token';   value = '' }
    )
}

# LF-normalized + trailing newline: byte-stable regardless of host newline settings.
$collectionJson = ((ConvertTo-Json -InputObject $collection -Depth 12) -replace "`r`n", "`n") + "`n"
Write-Utf8NoBom -Path $postmanPath -Content $collectionJson

# ---------------------------------------------------------------------------
# Render 2: Hurl file
# ---------------------------------------------------------------------------

$hurlLines = New-Object System.Collections.Generic.List[string]
$hurlLines.Add('# agentQ ' + $ticketKey + ' - rendered from scenario IR. HUMAN artifact, never part of a verdict.')
$hurlLines.Add('# Run: hurl --test --variable baseUrl=<url> --variable token=<token> against a CONSENTED LOCAL instance only.')

foreach ($s in $httpScenarios) {
    $hurlLines.Add('')
    $hurlLines.Add(('# {0} {1} ({2})' -f $s.Id, $s.Title, $s.Requirement))
    $hurlLines.Add(('{0} {{{{baseUrl}}}}{1}' -f $s.Method, $s.Path))

    $hasBody = ($null -ne $s.Body)
    foreach ($h in (Get-RequestHeaders -Http $s.Http -HasBody $hasBody)) {
        $hurlLines.Add(('{0}: {1}' -f $h['key'], $h['value']))
    }
    if ($hasBody) {
        $bodyJson = (ConvertTo-Json -InputObject $s.Body -Depth 12) -replace "`r`n", "`n"
        foreach ($line in $bodyJson.Split("`n")) { $hurlLines.Add($line) }
    }

    $hurlLines.Add('')
    $hurlLines.Add(('HTTP {0}' -f $s.ExpectStatus))

    $expectBody = $s.ExpectBody
    if ($null -ne $expectBody -and
        $expectBody -is [System.Management.Automation.PSCustomObject] -and
        @($expectBody.PSObject.Properties).Count -gt 0) {
        $hurlLines.Add('[Asserts]')
        foreach ($p in $expectBody.PSObject.Properties) {
            $jsonPath = Get-JsonPathForKey $p.Name
            if (Test-IsComplexValue $p.Value) {
                # WHY exists instead of ==: Hurl's == predicate takes scalar literals
                # only; an object/array expectation degrades to a presence check here
                # (the Postman render still deep-equals it via chai to.eql).
                $hurlLines.Add(('jsonpath "{0}" exists' -f $jsonPath))
            } else {
                $hurlLines.Add(('jsonpath "{0}" == {1}' -f $jsonPath, (ConvertTo-JsonLiteral $p.Value)))
            }
        }
    }
}

$hurlContent = ($hurlLines -join "`n") + "`n"
Write-Utf8NoBom -Path $hurlPath -Content $hurlContent

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

Write-Output $postmanPath
Write-Output $hurlPath
Write-Output ("agentQ render-artifacts: rendered {0} http scenario(s) ({1} without http block, {2} skipped/malformed) - HUMAN artifacts only: import the collection into Postman or run 'hurl --test' against a consented local instance; they never contribute to a verdict." -f $httpScenarios.Count, $skippedNoHttp, $malformed)
exit 0
