# Random-chain explorer launcher (research/stress harness, NOT a pass/fail gate).
#
# Boots Factorio as a dedicated server with the factory_solver/smoke_rcon
# scenario (control.lua registers BOTH the smoke driver and the chain explorer
# there), enables a pyanodon mod set, then drives tests/chain_explorer.lua over
# RCON: for each seed it builds a random connected recipe chain, pins the seed
# recipe, solves it through the real pre_solve -> create_problem -> IPM path, and
# reports whether the solution is "undesirable" (solver_state != finished, or a
# large fraction of recipe variables parked near zero).
#
# Two modes (Option A producer/consumer split):
#   * DEFAULT (parallel): phase 1 boots Factorio ONCE and dumps each generated
#     chain (generation + normalization only -- no solve) via remote.call
#     explore_emit into the run workspace's isolated script-output; phase 2
#     quits Factorio and solves the dumped problems with a pool of standalone
#     `lua` workers (tests/solve_problem.lua) in parallel across cores. The IPM
#     solve is the dominant cost and is Factorio-free, so this is much faster
#     than serial. After the pool drains, the dumps are PUBLISHED to
#     -ProblemDir (default tests/explore_problems/, gitignored), replacing the
#     previous run's snapshot there.
#   * -Serial: the original single-boot in-engine RCON solve sweep (remote.call
#     explore). Use when `lua` isn't available, or to cross-check that parallel
#     and in-engine produce identical result lines. Dumps nothing.
# Both produce the same status lines; "<<HIT" marks undesirable solutions, each
# reproducible by re-running its seed.
#
# The research-side canonical corpus (%APPDATA%/Factorio/script-output/
# explore_problems, the default read source of tests/research/*) is READ-ONLY
# for this launcher: promote a run into it by hand with
#   Copy-Item tests\explore_problems\*.lua "$env:APPDATA\Factorio\script-output\explore_problems\"
# so a branch's regenerated dumps can never silently overwrite it.
#
# This shares the RCON transport / launch / mod-list machinery with
# tests/smoke_rcon.ps1; it is a separate file so the smoke gate stays a clean
# pass/fail and this stays an open-ended explorer.
#
# Usage:
#   pwsh tests/explore_chains.ps1                 # 30 seeds, pyanodon, pipelined parallel
#   pwsh tests/explore_chains.ps1 -Workers 12     # cap the worker pool
#   pwsh tests/explore_chains.ps1 -ReuseProblems  # re-solve the last run's dumped chains (no Factorio boot)
#   pwsh tests/explore_chains.ps1 -Serial         # in-engine solve (no lua pool)
#   pwsh tests/explore_chains.ps1 -Seeds 100 -StartSeed 1 -Hops 16
#   pwsh tests/explore_chains.ps1 -Mods base,flib,factory_solver,space-age  # different mod set

[CmdletBinding()]
param(
    [int] $Seeds = 30,
    [int] $StartSeed = 1,
    [int] $Hops = 12,
    # Seconds to wait for the server to open RCON after launch. pyanodon's data
    # stage is heavy, so this is generous.
    [int] $RconStartupSeconds = 360,
    # Per-explore RCON read is blocking; the chain_explorer caps its own IPM
    # iterations, so a runaway solve can't hang forever, but a giant chain can
    # still take many seconds. No per-call deadline -- we wait for the response.
    [string[]] $Mods = @(),
    # 0 = pick a free port; empty password = a per-run random one.
    [int] $RconPort = 0,
    [string] $RconPassword = "",
    [string] $HitLog = "",
    # Where the run's dumped problem files are published (and where
    # -ReuseProblems reads them). Default: <repo>/tests/explore_problems.
    [string] $ProblemDir = "",
    # Where run workspaces live; empty = $env:FS_RUN_ROOT, else $env:TEMP\fs_runs.
    [string] $RunRoot = "",
    # Keep the run workspace (mods junction, write-data, logs) after a clean run.
    [switch] $KeepRun,
    # Quality recycling mode: enable the quality mod, fill machine module slots
    # with quality modules, and target a high-quality item (drives the
    # upgrade-and-recycle loop -- this mod's USP and the hardest case for the IPM).
    [switch] $Quality,
    # Default mode is the 2-phase producer/consumer split: phase 1 boots Factorio
    # once and dumps each generated chain to script-output as a loadable problem
    # file (generation + normalization only, no solve); phase 2 quits Factorio and
    # solves the dumped problems with a pool of standalone `lua` workers in
    # parallel across cores (the IPM solve is the dominant cost and is Factorio-
    # free). -Serial keeps the original single-boot in-engine RCON solve sweep
    # (useful when `lua` is not on PATH, or to cross-check parity with parallel).
    [switch] $Serial,
    # Parallel worker count for the solve pool. Defaults to every logical core.
    # Note the trade-off in the pipelined default mode: Factorio's single
    # generation thread runs concurrently with the workers, so maxing this out
    # oversubscribes the CPU and can slow generation (the serial bottleneck). It is
    # unambiguously best in -ReuseProblems mode, where no Factorio competes. Lower
    # it (e.g. cores-2) if generation throughput matters more than the solve tail.
    [int] $Workers = ([Environment]::ProcessorCount),
    # Standalone Lua interpreter that runs tests/solve_problem.lua. Defaults to the
    # known install location, falling back to whatever `lua` is on PATH.
    [string] $LuaExe = "",
    # Re-solve the problem files published to -ProblemDir by a previous run
    # WITHOUT booting Factorio or regenerating. The dumped chains are
    # deterministic for a (modset, seed, config) set, so this is the fast path
    # when iterating on the solver against a fixed problem set: it skips the
    # serial boot+generation floor (~the slow part) and runs only the parallel
    # solve. Mutually exclusive with -Serial. Errors if no cached problems exist
    # (run once without it first, or copy a corpus into -ProblemDir).
    [switch] $ReuseProblems
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

# Shared RCON transport / config resolution / run-workspace machinery (also
# used by tests/smoke_rcon.ps1 and tests/console.ps1).
. "$PSScriptRoot/rcon_lib.ps1"

try {
    $cfg = Resolve-FactorioConfig -RepoRoot $repoRoot.Path
} catch {
    Write-Error $_.Exception.Message
    exit 2
}
$factorio = $cfg.Factorio
$modsDir = $cfg.ModsDir
# Where the run's dumped problem files are published after the solve pool
# drains, and where -ReuseProblems reads them. Repo-local (per checkout /
# worktree) and gitignored; the canonical research corpus in %APPDATA% is
# never written by this launcher.
if (-not $ProblemDir) { $ProblemDir = Join-Path $repoRoot.Path "tests\explore_problems" }

if ($ReuseProblems -and $Serial) {
    Write-Error "-ReuseProblems and -Serial are mutually exclusive (reuse re-solves dumped files with the lua pool; serial solves in-engine)."
    exit 2
}

# Resolve the standalone Lua interpreter for the worker pool (any non-serial mode).
if (-not $Serial) {
    if (-not $LuaExe) {
        # Prefer LuaJIT: the solve worker is pure-Lua numeric code (CSR Cholesky /
        # substitutions) and LuaJIT runs the corpus ~2.7x faster than stock Lua
        # 5.4 with identical results. Fall back to stock Lua if LuaJIT is absent.
        # (This only affects the standalone research solve pool; the mod itself
        # always runs under Factorio's own Lua.)
        $candidates = @(
            (Join-Path $env:LOCALAPPDATA "Programs/LuaJIT/bin/luajit.exe"),
            (Join-Path $env:LOCALAPPDATA "Programs/Lua/bin/lua.exe")
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) { $LuaExe = $c; break }
        }
        if (-not $LuaExe) {
            $onPath = Get-Command luajit -ErrorAction SilentlyContinue
            if (-not $onPath) { $onPath = Get-Command lua -ErrorAction SilentlyContinue }
            if ($onPath) { $LuaExe = $onPath.Source }
        }
    }
    if (-not $LuaExe -or -not (Test-Path $LuaExe)) {
        Write-Error "Lua interpreter not found (looked for -LuaExe, $env:LOCALAPPDATA\Programs\Lua\bin\lua.exe, and 'lua' on PATH). Pass -LuaExe <path>, or use -Serial to solve in-engine."
        exit 2
    }
    if ($Workers -lt 1) { $Workers = 1 }
}

# Default mod set: base + flib + factory_solver + every pyanodon mod on disk
# (graphics packs included; they are dependencies of the content mods).
# PyBlock is a separate game mode, not part of the base pyanodon set, so exclude it.
if (-not $Mods -or $Mods.Count -eq 0) {
    if ($Quality) {
        # Quality recycling exploration: base + quality only (light, certain).
        # The recycler entity and 230+ recycling recipes ship with the quality
        # mod; pyanodon is space-age-incompatible and not needed to stress the
        # quality-decomposition + recycling loop.
        $Mods = @('base', 'flib', 'factory_solver', 'quality')
    } else {
        $pyMods = @(Get-ChildItem $modsDir -Filter 'py*.zip' -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.BaseName -match '^(.+)_\d+\.\d+\.\d+$') { $Matches[1] }
        } | Where-Object { $_ -and $_ -ne 'PyBlock' } | Sort-Object -Unique)
        $Mods = @('base', 'flib', 'factory_solver') + $pyMods
    }
} else {
    $Mods = @($Mods | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

if (-not $HitLog) { $HitLog = Join-Path $repoRoot.Path "tests\explore_hits.log" }
if (-not [System.IO.Path]::IsPathRooted($HitLog)) { $HitLog = Join-Path (Get-Location).Path $HitLog }
$HitLog = [System.IO.Path]::GetFullPath($HitLog)

Write-Host "explore: factorio = $factorio"
Write-Host "explore: mods     = $modsDir (linked into the run workspace)"
Write-Host "explore: seeds    = $StartSeed .. $($StartSeed + $Seeds - 1)  (hops=$Hops)"
Write-Host "explore: mod set  = $($Mods -join ', ')"
Write-Host "explore: hit log  = $HitLog"
Write-Host "explore: problems = $ProblemDir"

# --- Result classification (shared by serial sweep and parallel phase 2) ------
# A status line is one of: <<HIT (undesirable solution, any subclass), ERROR,
# ~park (note only), or a clean finished/other line. Mirrors the original inline
# block so both paths colour, log, and tally identically.
function Add-Result {
    param(
        [string] $Line,
        [System.Collections.Generic.List[string]] $Hits,
        [ref] $Errors,
        [ref] $Finished,
        [string] $HitLog
    )
    if ($Line -match '<<HIT') {
        Write-Host "  $Line" -ForegroundColor Yellow
        $Hits.Add($Line); $Line | Out-File -FilePath $HitLog -Append -Encoding utf8
    } elseif ($Line -match '^ERROR') {
        Write-Host "  $Line" -ForegroundColor Red
        $Errors.Value++; $Line | Out-File -FilePath $HitLog -Append -Encoding utf8
    } elseif ($Line -match '~park') {
        Write-Host "  $Line" -ForegroundColor DarkYellow
        $Line | Out-File -FilePath $HitLog -Append -Encoding utf8
    } else {
        Write-Host "  $Line"
        if ($Line -match 'state=finished') { $Finished.Value++ }
    }
}

# --- Worker pool primitives ---------------------------------------------------
# Solve each dumped problem file in its own `lua tests/solve_problem.lua <file>`
# process, keeping at most $Workers running at once (PS 5.1-compatible: a simple
# Start-Process throttle, no ForEach-Object -Parallel). A pool is a small state
# bag so the SAME engine serves two callers: the pipelined default feeds it one
# file at a time while Factorio keeps generating (overlap), and Invoke-WorkerPool
# / reuse mode feed it a whole batch. Each worker prints one status line captured
# to a temp file.
function New-SolvePool {
    param([string] $LuaExe, [string] $WorkDir, [int] $Workers)
    [PSCustomObject]@{
        LuaExe  = $LuaExe
        WorkDir = $WorkDir
        Workers = $Workers
        Queue   = (New-Object System.Collections.Queue)
        Running = (New-Object System.Collections.Generic.List[object])
        Done    = 0
    }
}

# One non-blocking tick: launch queued files up to the worker cap, reap any that
# finished, and RETURN their status lines (so the caller can classify them as
# they complete). Returns an empty list when nothing finished this tick.
function Step-SolvePool {
    param([PSCustomObject] $Pool)
    $new = New-Object System.Collections.Generic.List[string]
    while ($Pool.Running.Count -lt $Pool.Workers -and $Pool.Queue.Count -gt 0) {
        $f = [string]$Pool.Queue.Dequeue()
        $outFile = [System.IO.Path]::GetTempFileName()
        $p = Start-Process -FilePath $Pool.LuaExe `
            -ArgumentList @('tests/solve_problem.lua', $f) `
            -WorkingDirectory $Pool.WorkDir -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile
        [void]$Pool.Running.Add([PSCustomObject]@{ Proc = $p; Out = $outFile })
    }
    for ($i = $Pool.Running.Count - 1; $i -ge 0; $i--) {
        $r = $Pool.Running[$i]
        if ($r.Proc.HasExited) {
            $txt = Get-Content $r.Out -Raw -ErrorAction SilentlyContinue
            if ($txt) {
                foreach ($ln in ($txt -split "`r?`n")) {
                    if ($ln.Trim()) { [void]$new.Add($ln.Trim()) }
                }
            }
            Remove-Item $r.Out -Force -ErrorAction SilentlyContinue
            $Pool.Running.RemoveAt($i)
            $Pool.Done++
        }
    }
    return , $new
}

# Batch driver: enqueue every file, drain to completion, return all status lines.
# Used by reuse mode (and any all-at-once caller).
function Invoke-WorkerPool {
    param([string[]] $Files, [string] $LuaExe, [string] $WorkDir, [int] $Workers)
    $pool = New-SolvePool -LuaExe $LuaExe -WorkDir $WorkDir -Workers $Workers
    foreach ($f in $Files) { [void]$pool.Queue.Enqueue($f) }
    $results = New-Object System.Collections.Generic.List[string]
    $total = $Files.Count
    while ($pool.Queue.Count -gt 0 -or $pool.Running.Count -gt 0) {
        $lines = Step-SolvePool -Pool $pool
        foreach ($ln in $lines) { [void]$results.Add($ln) }
        if ($lines.Count -eq 0) { Start-Sleep -Milliseconds 50 }
        Write-Host -NoNewline "`r  solving $($pool.Done)/$total ...   "
    }
    Write-Host ""
    return , $results
}

# --- Reuse mode: re-solve the last run's dumped problems, no Factorio ----------
# The problem files are deterministic for a (modset, seed, config) set, so once a
# normal run has dumped them, the solver can be re-run against that exact set
# without booting Factorio or regenerating -- skipping the serial boot+generation
# floor and leaving only the parallel solve. This is the iterate-on-the-solver
# fast path. It exits before any Factorio / run-workspace machinery is touched.
if ($ReuseProblems) {
    $problemFiles = @(Get-ChildItem (Join-Path $ProblemDir '*.lua') -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
    if ($problemFiles.Count -eq 0) {
        Write-Error ("no cached problem files in $ProblemDir -- run once without -ReuseProblems to generate them, " +
            "or seed it from the canonical research corpus: " +
            "Copy-Item `"`$env:APPDATA\Factorio\script-output\explore_problems\*.lua`" `"$ProblemDir`"")
        exit 2
    }
    Write-Host "explore: reuse mode -- re-solving $($problemFiles.Count) cached problems with $Workers workers (no Factorio boot)"
    "# explore reuse run $(Get-Date -Format o)  cached=$($problemFiles.Count)" | Out-File -FilePath $HitLog -Append -Encoding utf8
    $hits = New-Object System.Collections.Generic.List[string]
    $errors = 0; $finished = 0
    $lines = Invoke-WorkerPool -Files $problemFiles -LuaExe $LuaExe -WorkDir $repoRoot.Path -Workers $Workers
    foreach ($ln in $lines) {
        Add-Result -Line $ln -Hits $hits -Errors ([ref]$errors) -Finished ([ref]$finished) -HitLog $HitLog
    }
    Write-Host "`nexplore: reuse done. $($hits.Count) HIT, $errors ERROR, $finished clean-finished of $($problemFiles.Count) solved"
    if ($hits.Count -gt 0) {
        Write-Host "explore: HITs (reproduce with the same seed):"
        foreach ($h in $hits) { Write-Host "  $h" }
    }
    Write-Host "explore: full log appended to $HitLog"
    exit 0
}

# --- Launch (run workspace; mirrors smoke_rcon.ps1) ---------------------------
if ($RconPort -eq 0) { $RconPort = Get-FreeTcpPort }
if (-not $RconPassword) { $RconPassword = [guid]::NewGuid().ToString('N') }
$runRoot = Resolve-RunRoot -RunRoot $RunRoot

$ws = $null
try {
    Invoke-RunRootGc -RunRoot $runRoot
    $ws = New-RunWorkspace -Tag "explore" -ServerName "factory_solver_explore" -RunRoot $runRoot
    Initialize-ScratchMods -Workspace $ws -SourceModsDir $modsDir -RepoRoot $repoRoot.Path -Mods $Mods
} catch {
    Write-Error $_.Exception.Message
    Remove-RunWorkspace -Workspace $ws
    exit 2
}
# The producer (explore_emit) writes via helpers.write_file("explore_problems/
# <tag>.lua"), which lands under the run workspace's isolated script-output;
# phase 2 feeds those files to the lua worker pool, then publishes them to
# $ProblemDir.
$dumpDir = Join-Path $ws.ScriptOutputDir "explore_problems"
$logFile = $ws.LogFile
Write-Host "explore: run dir  = $($ws.Dir)"
Write-Host "explore: rcon     = 127.0.0.1:$RconPort"

$arguments = New-FactorioArgumentList -Workspace $ws -Scenario "factory_solver/smoke_rcon" `
    -RconPort $RconPort -RconPassword $RconPassword
$env:SteamAppId = "427520"

$proc = Start-Process -FilePath $factorio -ArgumentList $arguments -PassThru -NoNewWindow
$client = $null; $stream = $null; $exitCode = 1
$hits = New-Object System.Collections.Generic.List[string]
$errors = 0; $finished = 0

try {
    $rcon = Connect-Rcon -Port $RconPort -Password $RconPassword -TimeoutSeconds $RconStartupSeconds -Proc $proc
    $client = $rcon.Client
    $stream = $rcon.Stream
    Write-Host "explore: RCON authenticated, sweeping configs x $Seeds seeds`n"

    "# explore run $(Get-Date -Format o)  mods=$($Mods -join ',')  hops=$Hops" | Out-File -FilePath $HitLog -Append -Encoding utf8

    $iface = "factory_solver_explore"
    # Sweep generation variants in ONE boot: direction (both/up/down) x void
    # (include/exclude pyanodon waste recipes) x depth (hops, scaled off -Hops so
    # a single knob controls overall depth). Each config runs $Seeds seeds.
    if ($Quality) {
        # Quality recycling loops: quality modules on every line + a high-quality
        # item target force the upgrade-and-recycle loop. cycle mode pulls in the
        # recycling recipes (they reconnect to already-selected materials).
        $configs = @(
            @{mode = 'cycle'; void = 'in'; nosrc = 'in'; pins = 1; qual = 'on'; hops = ($Hops * 2) },
            @{mode = 'cycle'; void = 'in'; nosrc = 'in'; pins = 1; qual = 'on'; hops = ($Hops * 4) },
            @{mode = 'both'; void = 'in'; nosrc = 'in'; pins = 1; qual = 'on'; hops = ($Hops * 2) },
            @{mode = 'cycle'; void = 'in'; nosrc = 'in'; pins = 1; qual = 'off'; hops = ($Hops * 2) } # control: same chains, no quality
        )
    } else {
        $configs = @(
            @{mode = 'cycle'; void = 'ex'; nosrc = 'ex'; pins = 1; qual = 'off'; hops = ($Hops * 2) }, # loop-biased closed chain
            @{mode = 'cycle'; void = 'in'; nosrc = 'in'; pins = 1; qual = 'off'; hops = ($Hops * 2) }, # loops WITH source/sink
            @{mode = 'cycle'; void = 'ex'; nosrc = 'ex'; pins = 1; qual = 'off'; hops = ($Hops * 4) }, # deeper loops
            # net-negative target: aim the constraint at a TRAPPED (produced-but-
            # unreachable) item, provoking the degenerate shortage solution (target
            # fabricated, nothing built -- lines tagged DEGEN). closure=off keeps
            # the chain's natural traps. nosrc=ex forces a CLOSED transformation
            # chain (no source/sink short-circuit), which leaves fewer reachable
            # seeds and so is the most likely to strand a produced item inside a
            # mass-losing loop -- the only shape that yields a trapped target.
            @{mode = 'cycle'; void = 'ex'; nosrc = 'ex'; pins = 1; qual = 'off'; hops = ($Hops * 2); target = 'netneg'; closure = 'off' },
            @{mode = 'cycle'; void = 'ex'; nosrc = 'ex'; pins = 1; qual = 'off'; hops = ($Hops * 4); target = 'netneg'; closure = 'off' },
            # trap-downstream target: aim at a pure-final item whose recipe consumes
            # a trapped material, so the chain RUNS and demands the trap (partial-
            # shortage HIT), as opposed to netneg's fabricate-and-build-nothing
            # DEGEN. Same closure=off so the traps survive to be consumed.
            @{mode = 'cycle'; void = 'ex'; nosrc = 'ex'; pins = 1; qual = 'off'; hops = ($Hops * 2); target = 'trapdown'; closure = 'off' },
            @{mode = 'cycle'; void = 'ex'; nosrc = 'ex'; pins = 1; qual = 'off'; hops = ($Hops * 4); target = 'trapdown'; closure = 'off' },
            # SCC-seeded: plant a whole cyclic material SCC up front (random growth
            # almost never closes a catalyst loop), then demand it from downstream
            # (trapdown) or directly (netneg). closure=off so the loop's own
            # catalyst stays trapped instead of being bootstrapped away. This is
            # the generation half of the catalyst-loop probe.
            @{mode = 'cycle'; init = 'scc'; void = 'ex'; nosrc = 'ex'; pins = 1; qual = 'off'; hops = ($Hops * 2); target = 'trapdown'; closure = 'off' },
            @{mode = 'cycle'; init = 'scc'; void = 'ex'; nosrc = 'ex'; pins = 1; qual = 'off'; hops = ($Hops * 2); target = 'netneg'; closure = 'off' },
            # Downstream-first catalyst probe: seed a known end product and grow
            # UP, pulling its whole producer chain (incl. a net-zero catalyst loop
            # like antimony purex) in behind it; closure=off keeps the catalyst
            # trapped, trapdown re-targets the end product so the run demands the
            # trapped downstream material. seedrecipe is mod-specific.
            @{mode = 'up'; seedrecipe = 'nuclear-sample'; void = 'ex'; nosrc = 'ex'; pins = 1; qual = 'off'; hops = ($Hops * 8); target = 'trapdown'; closure = 'off' },
            # Cycle-only chain: grow generously (init=scc guarantees a loop is
            # present; mode=cycle biases growth toward pulling more loops in), then
            # post-prune to recipes that lie on a cycle only -- every recipe is a
            # cycle edge and several distinct cycles typically survive (richer than
            # a single seeded SCC). closure=on lets a closure producer complete an
            # open loop before the prune. Pin the seed cycle recipe so the whole
            # loop structure must run; the cycles' external inputs become LP imports.
            # The hardest "all loops, no acyclic escape" shape for the IPM.
            @{mode = 'cycle'; init = 'scc'; void = 'ex'; nosrc = 'ex'; pins = 1; qual = 'off'; hops = ($Hops * 6); closure = 'on'; cycleonly = 'on' },
            @{mode = 'both'; void = 'in'; nosrc = 'in'; pins = 1; qual = 'off'; hops = $Hops }         # control
        )
    }
    # Default (pipelined parallel): explore_emit dumps one problem file per chain
    # while the solve pool chews through already-dumped files concurrently --
    # generation (Factorio, ~1 core) and solving (the workers) overlap, so the
    # solve hides under the serial generation instead of running after it. -Serial
    # solves in-engine via explore. The dump dir is inside this run's fresh
    # workspace, so there are no stale files to clear.
    if (-not $Serial) {
        New-Item -ItemType Directory -Force -Path $dumpDir | Out-Null
    }
    $remoteFn = if ($Serial) { 'explore' } else { 'explore_emit' }
    $pool = if ($Serial) { $null } else { New-SolvePool -LuaExe $LuaExe -WorkDir $repoRoot.Path -Workers $Workers }
    $emitted = 0

    foreach ($cfg in $configs) {
        $tgt = if ($cfg.target) { $cfg.target } else { 'recipe' }
        $cls = if ($cfg.closure) { $cfg.closure } else { 'on' }
        $ini = if ($cfg.init) { $cfg.init } else { 'recipe' }
        $sr = if ($cfg.seedrecipe) { $cfg.seedrecipe } else { '' }
        $co = if ($cfg.cycleonly) { $cfg.cycleonly } else { 'off' }
        $banner = "config mode=$($cfg.mode) init=$ini seedrecipe=$sr void=$($cfg.void) nosrc=$($cfg.nosrc) pins=$($cfg.pins) qual=$($cfg.qual) target=$tgt closure=$cls cycleonly=$co hops=$($cfg.hops)"
        Write-Host "`n--- $banner ---"
        "## $banner" | Out-File -FilePath $HitLog -Append -Encoding utf8
        for ($i = 0; $i -lt $Seeds; $i++) {
            $s = $StartSeed + $i
            if ($proc.HasExited) { throw "factorio exited mid-run" }
            # Thread-budget gate (pipelined mode): treat Factorio's generation as
            # one of the $Workers concurrent compute slots. When the solve pool is
            # full, PAUSE emitting and reap until a worker frees a slot, then resume
            # -- so the generation thread only ever runs against at most $Workers-1
            # solves and the total never oversubscribes the CPU, yet a freed slot is
            # reused immediately. This is what makes a full-core $Workers safe in
            # pipelined mode. (Generation rate-limits anyway, so this seldom blocks;
            # it mainly caps the transient peaks that would otherwise hit $Workers+1.)
            if (-not $Serial) {
                while ($pool.Running.Count -ge $Workers) {
                    foreach ($ln in (Step-SolvePool -Pool $pool)) {
                        Add-Result -Line $ln -Hits $hits -Errors ([ref]$errors) -Finished ([ref]$finished) -HitLog $HitLog
                    }
                    if ($pool.Running.Count -ge $Workers) { Start-Sleep -Milliseconds 20 }
                }
            }
            $exploreArgs = "seed=$s;hops=$($cfg.hops);mode=$($cfg.mode);init=$ini;void=$($cfg.void);nosrc=$($cfg.nosrc);pins=$($cfg.pins);qual=$($cfg.qual);target=$tgt;closure=$cls;cycleonly=$co"
            if ($sr) { $exploreArgs += ";seedrecipe=$sr" }
            $cmd = "/silent-command rcon.print(remote.call('$iface','$remoteFn','$exploreArgs'))"
            $r = Invoke-RconCommand -Stream $stream -Command $cmd
            if ($Serial) {
                Add-Result -Line $r -Hits $hits -Errors ([ref]$errors) -Finished ([ref]$finished) -HitLog $HitLog
            } else {
                # Generation ack: emit (file dumped -> enqueue for the pool), SKIPPED,
                # or ERROR. The latter two are terminal -- no file to solve. The emit
                # ack carries the tag, which is exactly the dumped file's stem.
                if ($r -match '^ERROR') {
                    Write-Host "  $r" -ForegroundColor Red
                    $errors++; $r | Out-File -FilePath $HitLog -Append -Encoding utf8
                } elseif ($r -match 'SKIPPED') {
                    Write-Host "  $r" -ForegroundColor DarkYellow
                    $r | Out-File -FilePath $HitLog -Append -Encoding utf8
                } elseif ($r -match 'tag=(\S+)') {
                    [void]$pool.Queue.Enqueue((Join-Path $dumpDir ($Matches[1] + '.lua')))
                    $emitted++
                    Write-Host "  $r"
                } else {
                    Write-Host "  $r"
                }
                # Overlap: dispatch queued solves and reap finished ones while the
                # next chain is being generated. Results print/tally as they land.
                foreach ($ln in (Step-SolvePool -Pool $pool)) {
                    Add-Result -Line $ln -Hits $hits -Errors ([ref]$errors) -Finished ([ref]$finished) -HitLog $HitLog
                }
            }
        }
    }

    if ($Serial) {
        Write-Host "`nexplore: done. $($hits.Count) HIT, $errors ERROR, $finished clean-finished of $($configs.Count * $Seeds) solves"
    } else {
        # Generation done -> quit Factorio so its core joins the solve tail, then
        # drain whatever the overlap hasn't finished (usually just the last few).
        Write-Host "`nexplore: generation done ($emitted dumped); quitting Factorio and draining solve pool"
        try { Send-RconPacket -Stream $stream -Id 3 -Type 2 -Body "/quit" } catch {}
        if ($client) { $client.Dispose(); $client = $null }
        $stream = $null
        $waited = 0
        while (-not $proc.HasExited -and $waited -lt 30) { Start-Sleep -Milliseconds 500; $waited++ }
        if (-not $proc.HasExited) { $proc.Kill() }

        while ($pool.Queue.Count -gt 0 -or $pool.Running.Count -gt 0) {
            $lines = Step-SolvePool -Pool $pool
            foreach ($ln in $lines) {
                Add-Result -Line $ln -Hits $hits -Errors ([ref]$errors) -Finished ([ref]$finished) -HitLog $HitLog
            }
            if ($lines.Count -eq 0) { Start-Sleep -Milliseconds 50 }
            Write-Host -NoNewline "`r  solving $($pool.Done)/$emitted ...   "
        }
        Write-Host ""
        $skipped = ($configs.Count * $Seeds) - $emitted
        Write-Host "`nexplore: done. $($hits.Count) HIT, $errors ERROR, $finished clean-finished of $emitted solved ($skipped skipped/errored)"

        # Publish this run's dumps to $ProblemDir as the new "last run" snapshot
        # (what -ReuseProblems re-solves), replacing the previous one. Only after
        # a complete run -- a thrown run keeps its workspace, dumps included.
        if ($emitted -gt 0) {
            New-Item -ItemType Directory -Force -Path $ProblemDir | Out-Null
            Remove-Item (Join-Path $ProblemDir '*.lua') -Force -ErrorAction SilentlyContinue
            Move-Item (Join-Path $dumpDir '*.lua') $ProblemDir
            Write-Host "explore: $emitted problem files published to $ProblemDir"
        }
    }
    if ($hits.Count -gt 0) {
        Write-Host "explore: HITs (reproduce with the same seed):"
        foreach ($h in $hits) { Write-Host "  $h" }
    }
    Write-Host "explore: full log appended to $HitLog"
    $exitCode = 0
}
catch {
    Write-Host "explore: FAILED: $($_.Exception.Message)"
    if (Test-Path $logFile) {
        Write-Host "explore: last 30 lines of the Factorio log:"
        Get-Content $logFile -Tail 30 | ForEach-Object { Write-Host "  $_" }
    }
    $exitCode = 2
}
finally {
    if ($stream) { try { Send-RconPacket -Stream $stream -Id 3 -Type 2 -Body "/quit" } catch {} }
    if ($client) { $client.Dispose() }
    Start-Sleep -Milliseconds 500
    if (-not $proc.HasExited) { $proc.Kill(); Start-Sleep -Milliseconds 500 }

    # The autosave, log, .lock and any unpublished dumps live in the run
    # workspace; remove it wholesale. Kept on -KeepRun, and on any non-zero
    # exit so a failed run's log and dumps survive for autopsy.
    Remove-RunWorkspace -Workspace $ws -Keep:($KeepRun -or $exitCode -ne 0)
}

exit $exitCode
