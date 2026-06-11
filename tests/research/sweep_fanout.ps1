# Fan tests/research/sweep_cost.lua --measure / --ablate across every dumped problem AND
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
#   pwsh tests/research/sweep_fanout.ps1 -Mode measure
#   pwsh tests/research/sweep_fanout.ps1 -Mode ablate -Jobs 14 -Chunk 32 > ablate.tsv
#   pwsh tests/research/sweep_fanout.ps1 -Mode measure -DumpDir D:\some\dir
# For -Mode measure, isolate the table (one header+base survives per file already):
#   pwsh tests/research/sweep_fanout.ps1 -Mode measure | Select-String "`t" | ...
#
# This shares no code with the RCON launchers (rcon_lib.ps1) -- it boots no
# Factorio and speaks no RCON; it only fans the headless `lua` worker out via
# Resolve-LuaExe / Invoke-LuaPool from ps_lib.ps1 (shared with run_corpus.ps1 and
# collect_corpus.ps1; same throttle shape as explore_chains.ps1's solve pool).

[CmdletBinding()]
param(
    # Which sweep_cost.lua mode to fan out. Both do leave-one-out per target, so
    # both benefit from target-range sharding. Accepts the bare word or the flag.
    [ValidateSet('measure', 'ablate', '--measure', '--ablate')]
    [string] $Mode = 'measure',
    # Directory of explorer-dumped problem files: the canonical research corpus.
    # No baked-in default -- defaults to the FS_CORPUS_DIR environment variable
    # (like the other research launchers) and errors when neither is provided.
    [string] $DumpDir = $env:FS_CORPUS_DIR,
    # Concurrent `lua` workers. Defaults to every logical core.
    [int] $Jobs = ([Environment]::ProcessorCount),
    # Target-count granularity per work item. Smaller = finer load balance but more
    # per-item base-build overhead; larger = coarser. 32 is a reasonable middle.
    [int] $Chunk = 32,
    # Standalone Lua interpreter. Defaults to `lua` on PATH, then the known install.
    [string] $LuaExe = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ps_lib.ps1"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')

# Normalise the mode to the flag sweep_cost.lua expects.
$modeFlag = if ($Mode -like '--*') { $Mode } else { "--$Mode" }

# Resolve the Lua interpreter (LuaJIT preferred, then stock lua; see ps_lib.ps1).
$LuaExe = Resolve-LuaExe $LuaExe
if ($Jobs -lt 1) { $Jobs = 1 }

if (-not $DumpDir) {
    Write-Error "no corpus directory: set the FS_CORPUS_DIR environment variable or pass -DumpDir (see tests/research/README.md)"
    exit 2
}
$files = @(Get-ChildItem (Join-Path $DumpDir '*.lua') -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) {
    Write-Error "no dump files in $DumpDir"
    exit 2
}

Write-Host "sweep_fanout: mode=$modeFlag files=$($files.Count) jobs=$Jobs chunk=$Chunk" -ForegroundColor Cyan

# Phase 1: count each file's leave-one-out targets (solve-free --list-units), so we
# know how to carve it. Run through the same pool -- it is fast but 300+ builds add
# up, so parallelise it too.
$listItems = foreach ($f in $files) {
    @{ ArgList = @('tests/research/sweep_cost.lua', $f.FullName, '--list-units'); Tag = $f.FullName }
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
                ArgList = @('tests/research/sweep_cost.lua', $f.FullName, $modeFlag, '--units', "$lo-$hi")
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
