# Fan tests/sweep_cost.lua --measure / --ablate across every dumped problem AND
# across sub-ranges of each problem's leave-one-out targets, so one heavy problem
# (whose --ablate/--measure can run for minutes) spreads over many cores instead
# of pinning a single `lua` process.
#
# Why ranges, not whole files: the per-file cost is heavily tailed -- one big dump
# measured ~590s of --ablate while the whole 309-file --measure corpus finished in
# ~7s. File-level parallelism (one `lua` per file) cannot break that one big file
# across cores, so its single process becomes the makespan floor. Splitting each
# file into -Chunk-sized target ranges turns it into (file, range) work items that
# run on separate cores, collapsing the makespan toward (total_work / cores).
#
# The Lua worker stays a pure single-shot box: `sweep_cost.lua <file> <mode>
# --units m-n` solves only sorted-target indices m..n and prints those rows. All
# orchestration -- enumerate target counts, carve ranges, order (largest first),
# throttle the process pool -- lives here in the launcher; Lua manages no workers.
#
# Usage:
#   pwsh tests/sweep_fanout.ps1 -Mode measure
#   pwsh tests/sweep_fanout.ps1 -Mode ablate -Jobs 14 -Chunk 32 > ablate.tsv
#   pwsh tests/sweep_fanout.ps1 -Mode measure -DumpDir D:\some\dir
# For -Mode measure, isolate the table (one header+base survives per file already):
#   pwsh tests/sweep_fanout.ps1 -Mode measure | Select-String "`t" | ...
#
# This shares no code with the RCON launchers (rcon_lib.ps1) -- it boots no
# Factorio and speaks no RCON; it only fans the headless `lua` worker out. The
# worker pool below is the same throttle shape as explore_chains.ps1's solve pool;
# if a third caller ever needs it, lift it into a shared tests/worker_pool.ps1.

[CmdletBinding()]
param(
    # Which sweep_cost.lua mode to fan out. Both do leave-one-out per target, so
    # both benefit from target-range sharding. Accepts the bare word or the flag.
    [ValidateSet('measure', 'ablate', '--measure', '--ablate')]
    [string] $Mode = 'measure',
    # Directory of explorer-dumped problem files (chain_explorer's explore_emit).
    [string] $DumpDir = (Join-Path $env:APPDATA 'Factorio/script-output/explore_problems'),
    # Concurrent `lua` workers. Defaults to every logical core.
    [int] $Jobs = ([Environment]::ProcessorCount),
    # Target-count granularity per work item. Smaller = finer load balance but more
    # per-item base-build overhead; larger = coarser. 32 is a reasonable middle.
    [int] $Chunk = 32,
    # Standalone Lua interpreter. Defaults to `lua` on PATH, then the known install.
    [string] $LuaExe = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

# Normalise the mode to the flag sweep_cost.lua expects.
$modeFlag = if ($Mode -like '--*') { $Mode } else { "--$Mode" }

# Resolve the Lua interpreter (same fallback order as explore_chains.ps1).
if (-not $LuaExe) {
    $onPath = Get-Command lua -ErrorAction SilentlyContinue
    if ($onPath) {
        $LuaExe = $onPath.Source
    } else {
        $def = Join-Path $env:LOCALAPPDATA 'Programs/Lua/bin/lua.exe'
        if (Test-Path $def) { $LuaExe = $def }
    }
}
if (-not $LuaExe -or -not (Test-Path $LuaExe)) {
    Write-Error "lua interpreter not found (looked for -LuaExe, 'lua' on PATH, $env:LOCALAPPDATA\Programs\Lua\bin\lua.exe)."
    exit 2
}
if ($Jobs -lt 1) { $Jobs = 1 }

$files = @(Get-ChildItem (Join-Path $DumpDir '*.lua') -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) {
    Write-Error "no dump files in $DumpDir"
    exit 2
}

# Throttled pool: run at most $Jobs `lua <ArgList>` processes at once, reaping the
# finished ones. Each item is @{ ArgList = @(...); Tag = <any> }. With -OnResult,
# its scriptblock is invoked (Tag, stdout-text) as each worker exits (streaming);
# without it, the (Tag, Output) pairs are collected and returned. Mirrors
# explore_chains.ps1's Step-SolvePool shape (PS 5.1: no ForEach-Object -Parallel).
function Invoke-LuaPool {
    param(
        [object[]] $Items,
        [int] $Jobs,
        [string] $LuaExe,
        [string] $WorkDir,
        [scriptblock] $OnResult
    )
    $queue = New-Object System.Collections.Queue
    foreach ($it in $Items) { [void]$queue.Enqueue($it) }
    $running = New-Object System.Collections.Generic.List[object]
    $collected = New-Object System.Collections.Generic.List[object]
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($running.Count -lt $Jobs -and $queue.Count -gt 0) {
            $it = $queue.Dequeue()
            $out = [System.IO.Path]::GetTempFileName()
            $p = Start-Process -FilePath $LuaExe -ArgumentList $it.ArgList `
                -WorkingDirectory $WorkDir -NoNewWindow -PassThru -RedirectStandardOutput $out
            [void]$running.Add([PSCustomObject]@{ Proc = $p; Out = $out; Tag = $it.Tag })
        }
        for ($i = $running.Count - 1; $i -ge 0; $i--) {
            $r = $running[$i]
            if ($r.Proc.HasExited) {
                $txt = Get-Content $r.Out -Raw -ErrorAction SilentlyContinue
                Remove-Item $r.Out -Force -ErrorAction SilentlyContinue
                $running.RemoveAt($i)
                if ($OnResult) { & $OnResult $r.Tag $txt }
                else { [void]$collected.Add([PSCustomObject]@{ Tag = $r.Tag; Output = $txt }) }
            }
        }
        if ($running.Count -ge $Jobs -or ($queue.Count -eq 0 -and $running.Count -gt 0)) {
            Start-Sleep -Milliseconds 20
        }
    }
    # In -OnResult (streaming) mode the rows were already emitted by the callback;
    # only the collect mode returns pairs.
    if (-not $OnResult) { return $collected }
}

Write-Host "sweep_fanout: mode=$modeFlag files=$($files.Count) jobs=$Jobs chunk=$Chunk" -ForegroundColor Cyan

# Phase 1: count each file's leave-one-out targets (solve-free --list-units), so we
# know how to carve it. Run through the same pool -- it is fast but 300+ builds add
# up, so parallelise it too.
$listItems = foreach ($f in $files) {
    @{ ArgList = @('tests/sweep_cost.lua', $f.FullName, '--list-units'); Tag = $f.FullName }
}
$counts = @{}
foreach ($r in (Invoke-LuaPool -Items $listItems -Jobs $Jobs -LuaExe $LuaExe -WorkDir $repoRoot.Path)) {
    $n = 0; [void][int]::TryParse(($r.Output -replace '\s', ''), [ref]$n)
    $counts[$r.Tag] = $n
}

# Phase 2: carve each file into -Chunk-sized index ranges -> a flat work list, one
# `lua sweep_cost.lua <file> <mode> --units lo-hi` item per chunk. Carry N so we can
# dispatch the largest files' chunks first (LPT) and keep the tail short.
$work = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $n = [int]$counts[$f.FullName]
    if ($n -lt 1) { continue }
    for ($lo = 1; $lo -le $n; $lo += $Chunk) {
        $hi = [Math]::Min($lo + $Chunk - 1, $n)
        [void]$work.Add([PSCustomObject]@{
                N       = $n
                ArgList = @('tests/sweep_cost.lua', $f.FullName, $modeFlag, '--units', "$lo-$hi")
                Tag     = $f.Name
            })
    }
}
$ordered = @($work | Sort-Object -Property N -Descending)
Write-Host "sweep_fanout: $($ordered.Count) work items (largest-first); draining..." -ForegroundColor Cyan

# Phase 3: drain. Each worker's stdout is streamed to our own stdout (Output
# stream, so `> file` / the pipeline captures it) as it lands -- order is
# completion order, which both modes tolerate (the consumer sorts / awks the rows).
Invoke-LuaPool -Items $ordered -Jobs $Jobs -LuaExe $LuaExe -WorkDir $repoRoot.Path -OnResult {
    param($tag, $txt)
    if ($txt) { Write-Output ($txt -replace '(\r?\n)+$', '') }
}
