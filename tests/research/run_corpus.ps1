# Run ANY headless `lua` driver over every explorer-dumped problem in parallel and
# collect a tagged line per file. This is the generic version of the per-session
# `solve_all.ps1` that kept getting reinvented: point it at a driver
# (tests/probe_force.lua, tests/probe_tilt.lua, tests/solve_problem.lua, ...) and a
# dump directory, and it fans `lua <driver> <file>` across cores, gathering the
# lines you care about (default: the "RESULT\t..." summary line probe_force emits).
#
# The driver contract is the single-shot worker the rest of tests/ already use:
# `lua <driver> <dumpfile>` solves one problem and prints to stdout; this launcher
# manages all the parallelism. No Factorio, no RCON -- pure headless solve pool.
#
# Usage:
#   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_force.lua
#   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_force.lua -Filter ttrapdown_coff_h44 -Out s:\tmp\rc.txt
#   pwsh tests/research/run_corpus.ps1 -Driver tests/solve_problem.lua -Collect '<<HIT'
#   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_tilt.lua -Collect '^# stop'
#
# Resolve-LuaExe and the throttle pool (Invoke-LuaPool) are shared with
# sweep_fanout.ps1 / collect_corpus.ps1 via ps_lib.ps1; the explore_chains.ps1
# solve pool is the same shape (PS 5.1: no ForEach-Object -Parallel).

[CmdletBinding()]
param(
    # The lua driver to run per dump file (repo-relative path, e.g.
    # tests/probe_force.lua). Receives one dump file path as its only argument.
    [Parameter(Mandatory = $true)]
    [string] $Driver,
    # Directory of explorer-dumped problem files (chain_explorer's explore_emit).
    [string] $DumpDir = (Join-Path $env:APPDATA 'Factorio/script-output/explore_problems'),
    # Only run dumps whose file name contains this substring (e.g. a config tag like
    # 'ttrapdown_coff_h44'). Empty = every *.lua in the dir.
    [string] $Filter = '',
    # Regex selecting which of a driver's stdout lines to collect. Default grabs the
    # machine-readable RESULT line the probe drivers emit. Use '.' to keep all.
    [string] $Collect = '^RESULT',
    # Concurrent `lua` workers. Defaults to every logical core.
    [int] $Workers = ([Environment]::ProcessorCount),
    # Standalone Lua interpreter. Default prefers LuaJIT (≈2.7x on the solve corpus),
    # then stock lua -- same fallback order as explore_chains.ps1.
    [string] $LuaExe = '',
    # Optional file to write the collected lines to (utf8). Always also echoed.
    [string] $Out = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ps_lib.ps1"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')

# Resolve the driver to an absolute path lua can load. The worker runs with CWD at
# the repo root (-WorkingDirectory below), so the driver's own `require "tests/..."`
# resolves regardless of how its script path was given. Accept relative or full.
# (Path.GetRelativePath is .NET Core only -- absent in Windows PowerShell 5.1 -- so
# we just hand lua the absolute path rather than computing a repo-relative one.)
$driverArg = if ([System.IO.Path]::IsPathRooted($Driver)) { $Driver } else { Join-Path $repoRoot.Path $Driver }
if (-not (Test-Path $driverArg)) { Write-Error "driver not found: $Driver"; exit 2 }

# Resolve the Lua interpreter (LuaJIT preferred, then stock lua; see ps_lib.ps1).
$LuaExe = Resolve-LuaExe $LuaExe
if ($Workers -lt 1) { $Workers = 1 }

# Enumerate the dumps (optionally filtered by name substring).
$files = @(Get-ChildItem (Join-Path $DumpDir '*.lua') -ErrorAction SilentlyContinue |
    Where-Object { -not $Filter -or $_.Name -like "*$Filter*" })
if ($files.Count -eq 0) {
    Write-Error "no dump files in $DumpDir$(if ($Filter) { " matching '*$Filter*'" })"
    exit 2
}

Write-Host "run_corpus: driver=$(Split-Path $driverArg -Leaf) files=$($files.Count) workers=$Workers lua=$(Split-Path $LuaExe -Leaf)" -ForegroundColor Cyan
Write-Host "run_corpus: collecting lines matching /$Collect/" -ForegroundColor Cyan

# Throttled pool (ps_lib.ps1): at most $Workers `lua <driver> <file>` at once.
# Collect every worker's stdout, then keep the lines matching /$Collect/. The
# RESULT-shaped outputs are small, so collecting then filtering is cheap.
$items = foreach ($f in $files) { @{ ArgList = @($driverArg, $f.FullName); Tag = $f.Name } }
$results = Invoke-LuaPool -Items $items -Jobs $Workers -LuaExe $LuaExe -WorkDir $repoRoot.Path -ShowProgress
$collected = New-Object System.Collections.Generic.List[string]
foreach ($r in $results) {
    if ($r.Output) {
        foreach ($ln in ($r.Output -split "`r?`n")) {
            if ($ln -match $Collect) { [void]$collected.Add($ln.Trim()) }
        }
    }
}

foreach ($ln in $collected) { Write-Output $ln }
if ($Out) {
    $collected | Out-File -FilePath $Out -Encoding utf8
    Write-Host "run_corpus: $($collected.Count) line(s) -> $Out" -ForegroundColor Green
} else {
    Write-Host "run_corpus: $($collected.Count) line(s) collected" -ForegroundColor Green
}
