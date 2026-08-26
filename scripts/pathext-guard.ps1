#Requires -Version 5.1
<#
pathext-guard.ps1  -  defensive PATHEXT repair, dot-sourced near the top of every
script that resolves an executable by bare name (git, dotnet, npx, pwsh, ...) via
Get-Command or a direct `& git ...` call (PowerShell's own native-command lookup
honors PATHEXT too, not just Get-Command).

WHY this exists: verified live (2026-08-26) that a pwsh process spawned nested
under this VS Code extension's Bash tool can inherit a minimal PATHEXT (observed:
".CPL" only, instead of Windows' normal ".COM;.EXE;.BAT;.CMD;...") from its parent
shell. With PATHEXT that narrow, `Get-Command git -ErrorAction SilentlyContinue`
(and every bare `& git`/`& dotnet` call) silently fails to resolve the executable
even though it IS on PATH -- every guard written as
`if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { throw ... }`
then throws a misleading "git not found on PATH". A qa-intake run burned close to
10 minutes live-discovering this and hand-patching every subsequent pwsh
invocation with an inline PATHEXT fix before this guard existed (see CLAUDE.md's
cross-platform safety rule). Dot-source this once, before the first tool
resolution in the script -- idempotent (a no-op when PATHEXT is already correct)
and a no-op entirely on macOS/Linux, where PATHEXT is not a concept.
#>

$__pathextGuardIsWin  = $true
$__pathextGuardWinVar = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
if ($null -ne $__pathextGuardWinVar) { $__pathextGuardIsWin = [bool]$__pathextGuardWinVar.Value }

if ($__pathextGuardIsWin) {
    $__pathextRequired = @('.COM', '.EXE', '.BAT', '.CMD')
    $__pathextCurrent  = @()
    if ($env:PATHEXT) { $__pathextCurrent = @($env:PATHEXT -split ';' | Where-Object { $_ -ne '' }) }
    $__pathextMissing  = @($__pathextRequired | Where-Object { $__pathextCurrent -notcontains $_ })
    if ($__pathextMissing.Count -gt 0) {
        $env:PATHEXT = (@($__pathextCurrent + $__pathextMissing) -join ';')
    }
}

Remove-Variable -Name __pathextGuardIsWin, __pathextGuardWinVar, __pathextRequired, __pathextCurrent, __pathextMissing -ErrorAction SilentlyContinue
