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
#   pwsh tests/run_corpus.ps1 -Driver tests/probe_force.lua
#   pwsh tests/run_corpus.ps1 -Driver tests/probe_force.lua -Filter ttrapdown_coff_h44 -Out s:\tmp\rc.txt
#   pwsh tests/run_corpus.ps1 -Driver tests/solve_problem.lua -Collect '<<HIT'
#   pwsh tests/run_corpus.ps1 -Driver tests/probe_tilt.lua -Collect '^# stop'
#
# The throttle pool below is the same shape as tests/sweep_fanout.ps1's
# Invoke-LuaPool and explore_chains.ps1's solve pool (PS 5.1: no
# ForEach-Object -Parallel). Kept self-contained so this launcher has no
# cross-dependency; if a fourth caller appears, lift the pool into a shared
# tests/worker_pool.ps1 and have all three use it.

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
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

# Resolve the driver to an absolute path lua can load. The worker runs with CWD at
# the repo root (-WorkingDirectory below), so the driver's own `require "tests/..."`
# resolves regardless of how its script path was given. Accept relative or full.
# (Path.GetRelativePath is .NET Core only -- absent in Windows PowerShell 5.1 -- so
# we just hand lua the absolute path rather than computing a repo-relative one.)
$driverArg = if ([System.IO.Path]::IsPathRooted($Driver)) { $Driver } else { Join-Path $repoRoot.Path $Driver }
if (-not (Test-Path $driverArg)) { Write-Error "driver not found: $Driver"; exit 2 }

# Resolve the Lua interpreter (LuaJIT preferred, then stock lua; same as explore_chains.ps1).
if (-not $LuaExe) {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs/LuaJIT/bin/luajit.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs/Lua/bin/lua.exe')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { $LuaExe = $c; break } }
    if (-not $LuaExe) {
        $onPath = Get-Command luajit -ErrorAction SilentlyContinue
        if (-not $onPath) { $onPath = Get-Command lua -ErrorAction SilentlyContinue }
        if ($onPath) { $LuaExe = $onPath.Source }
    }
}
if (-not $LuaExe -or -not (Test-Path $LuaExe)) {
    Write-Error "lua interpreter not found (looked for -LuaExe, LuaJIT/lua under $env:LOCALAPPDATA\Programs, and on PATH)."
    exit 2
}
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

# Throttled pool: at most $Workers `lua <driver> <file>` at once; collect the
# matching stdout lines as each worker exits. (Same shape as sweep_fanout's pool.)
$queue = New-Object System.Collections.Queue
foreach ($f in $files) { [void]$queue.Enqueue($f.FullName) }
$running = New-Object System.Collections.Generic.List[object]
$collected = New-Object System.Collections.Generic.List[string]
$done = 0; $total = $files.Count
while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($running.Count -lt $Workers -and $queue.Count -gt 0) {
        $file = [string]$queue.Dequeue()
        # NB: name this $tmpOut, not $out -- PowerShell variable names are
        # case-INSENSITIVE, so a loop-local $out would clobber the $Out parameter.
        $tmpOut = [System.IO.Path]::GetTempFileName()
        $p = Start-Process -FilePath $LuaExe -ArgumentList @($driverArg, $file) `
            -WorkingDirectory $repoRoot.Path -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut
        [void]$running.Add([PSCustomObject]@{ Proc = $p; Out = $tmpOut })
    }
    for ($i = $running.Count - 1; $i -ge 0; $i--) {
        $r = $running[$i]
        if ($r.Proc.HasExited) {
            $txt = Get-Content $r.Out -Raw -ErrorAction SilentlyContinue
            # HasExited can flip true a beat before the OS flushes the redirected
            # stdout file; re-read once after a short wait so a fast worker's output
            # is not silently dropped.
            if (-not $txt) { Start-Sleep -Milliseconds 40; $txt = Get-Content $r.Out -Raw -ErrorAction SilentlyContinue }
            Remove-Item $r.Out -Force -ErrorAction SilentlyContinue
            $running.RemoveAt($i); $done++
            if ($txt) {
                foreach ($ln in ($txt -split "`r?`n")) {
                    if ($ln -match $Collect) { [void]$collected.Add($ln.Trim()) }
                }
            }
        }
    }
    Write-Host -NoNewline "`r  running $($done)/$total ...   "
    if ($running.Count -ge $Workers -or ($queue.Count -eq 0 -and $running.Count -gt 0)) {
        Start-Sleep -Milliseconds 20
    }
}
Write-Host ""

foreach ($ln in $collected) { Write-Output $ln }
if ($Out) {
    $collected | Out-File -FilePath $Out -Encoding utf8
    Write-Host "run_corpus: $($collected.Count) line(s) -> $Out" -ForegroundColor Green
} else {
    Write-Host "run_corpus: $($collected.Count) line(s) collected" -ForegroundColor Green
}
