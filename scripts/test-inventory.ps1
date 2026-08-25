<#
.SYNOPSIS
    test-inventory.ps1 - mechanical test-method-name inventory for the diff's
    affected test files, so qa-scenario-writer can judge per-AC coverage from
    NAMES alone before opening any whole test file.

.DESCRIPTION
    Reads run-manifest.json (via -Manifest), diff-set.json and
    adapter-profiles.json from the workspace dir. For every changed SUT file
    under a test project's sutProjects, finds the matching EXISTING test file
    by the same <Base>Tests/<Base>Test naming convention
    run-tests.ps1's Get-AffectedTestClasses already uses (never touches or
    builds anything - this is a pure filesystem + regex scan). For every
    changed file already under the test project's own directory, the file
    itself is scanned directly (it already IS a test file). Regex-extracts
    method names: .NET xUnit/NUnit attributes ([Fact]/[Theory]/[Test]/
    [TestCase], including stacked attribute lines before the method
    signature) and JS/TS `it(...)`/`test(...)` string titles.

    WHY a script, not part of qa-scenario-writer's own read: this is pure
    mechanical extraction (regex over files already on disk) - paying an LLM
    tool-call for what a script does deterministically and near-instantly
    would be exactly the wasted work the Phase 3 diet is removing.

    Output: <workspaceDir>/test-inventory.json (shape in scripts/CONTRACTS.md).
    Exit code 0 = the script ran (a SUT file with no matching test file found
    is an `unmatchedSutFiles` entry, not a failure). Non-zero = the script
    itself broke (bad manifest, missing required inputs).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Manifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# -----------------------------------------------------------------------------
# Helpers (kept byte-identical in spirit to the other scripts' conventions -
# self-contained, no shared module, per this codebase's convention)
# -----------------------------------------------------------------------------

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Write-JsonFileNoBom {
    param($Object, [string]$Path)
    $json = ConvertTo-Json -InputObject $Object -Depth 12
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $enc)
}

function Get-ChangedFilePaths {
    # Changed paths = diff files (non-deleted) UNION untracked, repo-relative
    # with forward slashes - same union rule run-tests.ps1's Get-ChangedCsPaths
    # applies (a developer's brand-new file is exactly what needs inventorying,
    # and diff-set.json's `files` list alone misses it).
    param($DiffSet)
    $paths = New-Object System.Collections.Generic.List[string]
    if ($null -eq $DiffSet) { return , $paths }
    foreach ($f in @(Get-Prop $DiffSet 'files' @())) {
        if ([string](Get-Prop $f 'status' '') -eq 'D') { continue }
        $p = ([string](Get-Prop $f 'path' '')) -replace '\\', '/'
        if ($p) { $paths.Add($p) }
    }
    foreach ($u in @(Get-Prop $DiffSet 'untracked' @())) {
        $p = ([string]$u) -replace '\\', '/'
        if ($p) { $paths.Add($p) }
    }
    return , @($paths | Select-Object -Unique)
}

# .NET: [Fact] / [Theory] / [Test] / [TestCase(...)], possibly several stacked
# attribute lines (e.g. [Theory] then multiple [InlineData(...)]), followed by
# the method signature line. Captures the method name.
$script:DotnetMethodPattern = [regex]'(?ms)^\s*\[(?:Fact|Theory|Test|TestCase)[^\]]*\]\s*(?:\r?\n\s*\[[^\]]*\]\s*)*\r?\n\s*(?:public|internal|private|protected)\s+(?:static\s+)?(?:async\s+)?(?:Task(?:<[^>]*>)?|void)\s+([A-Za-z_][A-Za-z0-9_]*)\s*\('

# JS/TS: it('title', ...) / test('title', ...) / it("title", ...) - single or
# double quotes, or a template literal with no ${} interpolation.
$script:JsMethodPattern = [regex]"(?m)\b(?:it|test)\s*\(\s*(['""`])((?:(?!\1).)*)\1"

function Get-DotnetMethodNames {
    param([string]$FilePath)
    try { $text = [System.IO.File]::ReadAllText($FilePath) } catch { return @() }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($m in $script:DotnetMethodPattern.Matches($text)) { $names.Add($m.Groups[1].Value) }
    return , @($names | Select-Object -Unique)
}

function Get-JsMethodNames {
    param([string]$FilePath)
    try { $text = [System.IO.File]::ReadAllText($FilePath) } catch { return @() }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($m in $script:JsMethodPattern.Matches($text)) { $names.Add($m.Groups[2].Value) }
    return , @($names | Select-Object -Unique)
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

try {
    $man = Read-JsonFile -Path $Manifest
    if ($null -eq $man) { throw "Manifest not found or unparseable: $Manifest" }
    $workspaceDir = [string](Get-Prop $man 'workspaceDir' '')
    $repoPath = [string](Get-Prop $man 'repoPath' '')
    if ([string]::IsNullOrWhiteSpace($workspaceDir)) { throw 'run-manifest.json missing workspaceDir' }
    if ([string]::IsNullOrWhiteSpace($repoPath)) { throw 'run-manifest.json missing repoPath' }

    $diffSetPath = Join-Path $workspaceDir 'diff-set.json'
    $profilesPath = Join-Path $workspaceDir 'adapter-profiles.json'
    $diffSet = Read-JsonFile -Path $diffSetPath
    $profiles = @(Get-Prop (Read-JsonFile -Path $profilesPath) 'projects' @())

    $outPath = Join-Path $workspaceDir 'test-inventory.json'
    if ($profiles.Count -eq 0 -or $null -eq $diffSet) {
        Write-JsonFileNoBom -Object ([ordered]@{ files = @(); unmatchedSutFiles = @() }) -Path $outPath
        Write-Output "test-inventory: no profiles/diff-set - nothing to inventory -> $outPath"
        exit 0
    }

    $changed = Get-ChangedFilePaths -DiffSet $diffSet
    $entries = New-Object System.Collections.Generic.List[object]
    $unmatched = New-Object System.Collections.Generic.List[string]
    $seenTestFiles = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($prof in $profiles) {
        $framework = [string](Get-Prop $prof 'framework' '')
        $isDotnet = @('xunit', 'nunit3', 'nunit4') -contains $framework
        $isJs = @('jest', 'vitest') -contains $framework

        $sutDirs = @()
        foreach ($s in @(Get-Prop $prof 'sutProjects' @())) {
            $sutDirs += ((([string]$s) -replace '\\', '/') -replace '/[^/]+\.(csproj|json)$', '').ToLowerInvariant()
        }
        $testProjRel = [string](Get-Prop $prof 'projectPath' '')
        $testProjDir = ((($testProjRel -replace '\\', '/')) -replace '/[^/]+\.(csproj|json)$', '').ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($testProjDir)) { continue }
        $testProjDirAbs = Join-Path $repoPath ($testProjDir -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $testProjDirAbs)) { continue }

        foreach ($path in $changed) {
            $lower = $path.ToLowerInvariant()
            $base = [System.IO.Path]::GetFileNameWithoutExtension($path)
            if ([string]::IsNullOrWhiteSpace($base)) { continue }

            $underSut = $false
            foreach ($d in $sutDirs) {
                if ($d -ne '' -and $lower.StartsWith("$d/")) { $underSut = $true; break }
            }
            $underTest = ($testProjDir -ne '' -and $lower.StartsWith("$testProjDir/"))
            if (-not $underSut -and -not $underTest) { continue }

            if ($underTest) {
                # The changed file already IS a test file - inventory it directly.
                $absPath = Join-Path $repoPath ($path -replace '/', [IO.Path]::DirectorySeparatorChar)
                if (-not (Test-Path -LiteralPath $absPath -PathType Leaf)) { continue }
                if (-not $seenTestFiles.Add($absPath)) { continue }
                $methods = if ($isDotnet) { Get-DotnetMethodNames -FilePath $absPath }
                           elseif ($isJs) { Get-JsMethodNames -FilePath $absPath }
                           else { @() }
                $entries.Add([ordered]@{
                    sutFile = $null
                    testFile = $path
                    testClass = $base
                    framework = $framework
                    methods = @($methods)
                })
                continue
            }

            # SUT-side: find the matching EXISTING test file under this test
            # project's tree by the same <Base>Tests/<Base>Test convention
            # run-tests.ps1's Get-AffectedTestClasses uses for filters - here
            # we need the physical FILE, not just the class name string.
            # WHY interpolation ("${base}Tests.cs"), NEVER "$base" + 'Tests.cs':
            # verified live that `@(expr1 + lit1, expr2 + lit2)` assigned from an
            # if/elseif/else expression collapses to a SINGLE space-joined STRING
            # instead of a 2-element array (the `+` appears to consume the whole
            # comma-separated tail as one operand, stringifying it via $OFS) -
            # completely silent, no error, `foreach` over the "array" then runs
            # once with a nonsense multi-name filter that matches nothing. Plain
            # string interpolation has no `+` operator for this to happen to.
            $candidateNames = if ($isDotnet) { @("${base}Tests.cs", "${base}Test.cs") }
                              elseif ($isJs) { @("$base.spec.ts", "$base.spec.tsx", "$base.test.ts", "$base.test.tsx", "$base.spec.js", "$base.test.js") }
                              else { @() }
            $found = $null
            foreach ($cand in $candidateNames) {
                $hit = Get-ChildItem -LiteralPath $testProjDirAbs -Recurse -File -Filter $cand -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($hit) { $found = $hit; break }
            }
            if ($null -eq $found) {
                $unmatched.Add($path)
                continue
            }
            if (-not $seenTestFiles.Add($found.FullName)) { continue }
            $testClass = [System.IO.Path]::GetFileNameWithoutExtension($found.Name)
            $testFileRel = ($found.FullName.Substring($repoPath.Length).TrimStart('\', '/')) -replace '\\', '/'
            $methods = if ($isDotnet) { Get-DotnetMethodNames -FilePath $found.FullName }
                       elseif ($isJs) { Get-JsMethodNames -FilePath $found.FullName }
                       else { @() }
            $entries.Add([ordered]@{
                sutFile = $path
                testFile = $testFileRel
                testClass = $testClass
                framework = $framework
                methods = @($methods)
            })
        }
    }

    # WHY $entries directly, NOT @($entries): verified live that wrapping an
    # already-List[object] variable in @() can throw "Argument types do not
    # match" (a PowerShell 7.6.5 PSToObjectArrayBinder bug) even OUTSIDE the
    # narrower "immediately followed by .Count" case this was first found in -
    # here it reproduced from simply using @(List) as a hashtable value. A
    # List[T] already supports ConvertTo-Json/foreach/.Count natively; @()
    # around one is never actually necessary, only risky on this build.
    $result = [ordered]@{
        files = $entries
        unmatchedSutFiles = @($unmatched | Select-Object -Unique)
    }
    Write-JsonFileNoBom -Object $result -Path $outPath

    $totalMethods = ($entries | ForEach-Object { $_.methods.Count } | Measure-Object -Sum).Sum
    Write-Output "test-inventory: $($entries.Count) test file(s), $totalMethods method name(s), $($unmatched.Count) SUT file(s) with no matching test found -> $outPath"
    exit 0
}
catch {
    Write-Error "test-inventory.ps1: $($_.Exception.Message)"
    exit 1
}
