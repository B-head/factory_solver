# RCON-driven in-game smoke test launcher.
#
# Boots Factorio as a dedicated server with the factory_solver/smoke_rcon
# scenario, connects over RCON, and drives one or more fixtures synchronously:
# for each fixture it asks the mod's remote interface to build a Solution, then
# polls solver_state until terminal. The verdict is decided here from the RCON
# responses -- no log-file grepping (contrast tests/smoke.ps1).
#
# The win over the log-marker variants: the expensive Factorio bootstrap is paid
# ONCE, then every fixture runs in the same booted server. Add a fixture to
# manage/smoke_rcon.lua and a name to $Fixtures below; no extra boot.
#
# The RCON transport (Source RCON binary framing over TCP) is implemented inline
# with .NET sockets -- no external dependency. It is intentionally isolated in
# the "RCON client" region below so a future cross-platform launcher could swap
# in mcrcon / a Python helper without touching the orchestration.
#
# Mod set: each run builds a throwaway "run workspace" (see rcon_lib.ps1) -- a
# scratch mods dir holding a junction to this checkout plus links to the
# requested mods (-Mods, default base+flib+factory_solver), with its own
# generated mod-list.json, and an isolated Factorio write-data via --config.
# The shared mods dir's mod-list.json and the user's %APPDATA%\Factorio are
# never touched, runs work from a git worktree (the checkout's folder name does
# not matter), and concurrent runs are safe (free RCON port + per-run random
# password). The shared mods dir comes from .vscode/launch.json's modsPath --
# the same value the factoriomod-debug extension uses -- read from this
# checkout's .vscode, else the main checkout's. A fixture that reads a mod's
# prototypes declares it in `requires` and is SKIPped (not failed) when that
# mod isn't in the set.
#
# Exit codes: 0 = all fixtures PASS (skips are not failures), 1 = a fixture
# FAILed (or no response), 2 = setup error (Factorio not found, RCON never came
# up, etc).
#
# Usage:
#   pwsh tests/smoke_rcon.ps1
#   pwsh tests/smoke_rcon.ps1 -Fixtures iron_plate -Mods base,flib,factory_solver,space-age,quality,elevated-rails
#   pwsh tests/smoke_rcon.ps1 -KeepRun   # keep the run workspace for inspection

[CmdletBinding()]
param(
    # Per-fixture deadline for the solver to reach a terminal state.
    [int] $TimeoutSeconds = 45,
    # Seconds to wait for the server to open its RCON port after launch.
    [int] $RconStartupSeconds = 90,
    [string[]] $Fixtures = @("iron_plate", "missing_prototype", "boiler_steam", "reactor_burnt_fuel",
        "catalyst_reclassify", "target_rescue",
        "migration_legacy_shape", "codec_solution_roundtrip", "codec_frozen_import",
        "codec_fp_roundtrip", "codec_helmod_roundtrip", "codec_helmod_import_order",
        "codec_yafc_roundtrip", "yafc_real_sample", "codec_yafc_virtual", "yafc_string_form",
        "yafc_real_reexport"),
    # Mods to enable for the run; everything else is explicitly disabled in the
    # workspace's generated mod-list.json. Default is the vanilla minimal set.
    # Pass @() to mirror the dev config (every shared mod linked, shared
    # mod-list.json copied verbatim).
    [string[]] $Mods = @("base", "flib", "factory_solver"),
    # 0 = pick a free port; a fixed port only matters for attaching from outside.
    [int] $RconPort = 0,
    # Empty = a per-run random password (fail-fast on cross-run misconnects).
    [string] $RconPassword = "",
    # Where run workspaces live; empty = $env:FS_RUN_ROOT, else $env:TEMP\fs_runs.
    [string] $RunRoot = "",
    # Keep the run workspace (mods junction, write-data, logs) after a green run.
    # Failing runs always keep it for autopsy.
    [switch] $KeepRun
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

# Shared RCON transport / config resolution / run-workspace machinery (also
# used by tests/explore_chains.ps1 and tests/console.ps1).
. "$PSScriptRoot/rcon_lib.ps1"

# Normalize -Mods / -Fixtures to clean string arrays. `powershell -File ... -Mods
# a,b,c` binds the comma list as a SINGLE string (no split) rather than an array,
# which would silently leave only base enabled (and make a comma'd -Fixtures one
# unknown fixture); splitting on commas here makes both comma- and
# space-separated forms work regardless of how -File bound them.
$Mods = @($Mods | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Fixtures = @($Fixtures | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# ---------------------------------------------------------------------------
# Settings / run workspace (shared with the other launchers via rcon_lib.ps1)
# ---------------------------------------------------------------------------
if ($RconPort -eq 0) { $RconPort = Get-FreeTcpPort }
if (-not $RconPassword) { $RconPassword = [guid]::NewGuid().ToString('N') }
$runRoot = Resolve-RunRoot -RunRoot $RunRoot

$ws = $null
try {
    Invoke-RunRootGc -RunRoot $runRoot
    $cfg = Resolve-FactorioConfig -RepoRoot $repoRoot.Path
    $ws = New-RunWorkspace -Tag "smoke" -ServerName "factory_solver_smoke_rcon" -RunRoot $runRoot
    Initialize-ScratchMods -Workspace $ws -SourceModsDir $cfg.ModsDir -RepoRoot $repoRoot.Path -Mods $Mods
} catch {
    Write-Error $_.Exception.Message
    Remove-RunWorkspace -Workspace $ws
    exit 2
}
$factorio = $cfg.Factorio

Write-Host "smoke_rcon: factorio = $factorio"
Write-Host "smoke_rcon: mods     = $($cfg.ModsDir) (linked into the run workspace)"
Write-Host "smoke_rcon: run dir  = $($ws.Dir)"
Write-Host "smoke_rcon: rcon     = 127.0.0.1:$RconPort"
Write-Host "smoke_rcon: fixtures = $($Fixtures -join ', ')"
Write-Host "smoke_rcon: mod set  = $(if ($Mods.Count) { $Mods -join ', ' } else { '(dev config mirrored)' })"

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------
$arguments = New-FactorioArgumentList -Workspace $ws -Scenario "factory_solver/smoke_rcon" `
    -RconPort $RconPort -RconPassword $RconPassword

# Steam-built factorio.exe relaunches itself via Steam unless it thinks Steam
# launched it; setting SteamAppId makes the SDK skip the relaunch (same trick as
# factoriomod-debug).
$env:SteamAppId = "427520"

$proc = Start-Process -FilePath $factorio -ArgumentList $arguments -PassThru -NoNewWindow

$client = $null
$stream = $null
$exitCode = 1

try {
    # --- Wait for RCON, connect, authenticate ------------------------------
    $rcon = Connect-Rcon -Port $RconPort -Password $RconPassword -TimeoutSeconds $RconStartupSeconds -Proc $proc
    $client = $rcon.Client
    $stream = $rcon.Stream
    Write-Host "smoke_rcon: RCON authenticated"

    # --- Drive each fixture ------------------------------------------------
    $iface = "factory_solver_smoke"
    $allPass = $true
    $skipCount = 0

    # Force/prototype-global cache invariants (manage/relation.lua,
    # manage/preset.lua) are solution-independent, so check them once up front
    # rather than per fixture. A failure here flips the whole run to FAIL.
    $caches = Invoke-RconCommand -Stream $stream `
        -Command "/silent-command rcon.print(remote.call('$iface','check_force_caches'))"
    if ($caches -eq "OK") {
        Write-Host "SMOKE PASS: [force_caches] relation + preset invariants"
    } else {
        Write-Host "SMOKE FAIL: [force_caches] $caches"
        $allPass = $false
    }

    # The tick-split relation build (build_relation_init + build_relation_step,
    # driven from on_tick) must reproduce the synchronous create_relation_to_recipes
    # field-for-field, including the one-recipe-per-step cursor reentry. Solution-
    # independent, so it runs once up front too.
    $relationSplit = Invoke-RconCommand -Stream $stream `
        -Command "/silent-command rcon.print(remote.call('$iface','check_relation_split'))"
    if ($relationSplit -eq "OK") {
        Write-Host "SMOKE PASS: [relation_split] tick-split build == synchronous build"
    } else {
        Write-Host "SMOKE FAIL: [relation_split] $relationSplit"
        $allPass = $false
    }

    # Fuel follows a machine change across every fuel mode (the on_make_fuel_table /
    # apply_machine_clipboard reconciliation). Solution-independent, driven off
    # data_test.lua machines, so it runs once up front too.
    $fuelReconcile = Invoke-RconCommand -Stream $stream `
        -Command "/silent-command rcon.print(remote.call('$iface','check_fuel_reconciliation'))"
    if ($fuelReconcile -eq "OK") {
        Write-Host "SMOKE PASS: [fuel_reconcile] fuel follows machine change (item/heat/fluid)"
    } else {
        Write-Host "SMOKE FAIL: [fuel_reconcile] $fuelReconcile"
        $allPass = $false
    }

    # The fuel-temperature picker options for burns_fluid=false machines (the
    # acceptance-range variant plus in-range single temperatures, clipped to
    # acceptance but not to the energy cap). Solution-independent, driven off
    # data_test.lua machines, so it runs once up front too.
    $fuelTemps = Invoke-RconCommand -Stream $stream `
        -Command "/silent-command rcon.print(remote.call('$iface','check_fluid_fuel_temperature_variants'))"
    if ($fuelTemps -eq "OK") {
        Write-Host "SMOKE PASS: [fuel_temps] picker offers acceptance range + in-range points"
    } else {
        Write-Host "SMOKE FAIL: [fuel_temps] $fuelTemps"
        $allPass = $false
    }

    # The engine fixed_recipe lock is honoured for ordinary crafting machines: a
    # machine locked to recipe A is offered for A only, B has no eligible machine,
    # and the fixed-only category exposes no general machine preset.
    # Solution-independent, driven off data_test.lua, so it runs once up front too.
    $fixedRecipe = Invoke-RconCommand -Stream $stream `
        -Command "/silent-command rcon.print(remote.call('$iface','check_fixed_recipe_machine'))"
    if ($fixedRecipe -eq "OK") {
        Write-Host "SMOKE PASS: [fixed_recipe] machine offered only for its locked recipe"
    } else {
        Write-Host "SMOKE FAIL: [fixed_recipe] $fixedRecipe"
        $allPass = $false
    }

    # A machine's ingredient_count caps the item ingredients it can craft (fluids
    # exempt): the capped machine drops out of over-cap recipes' pickers, and the
    # category splits into per-cap machine-preset tiers.
    # Solution-independent, driven off data_test.lua, so it runs once up front too.
    $ingredientCount = Invoke-RconCommand -Stream $stream `
        -Command "/silent-command rcon.print(remote.call('$iface','check_ingredient_count_machine'))"
    if ($ingredientCount -eq "OK") {
        Write-Host "SMOKE PASS: [ingredient_count] capped machine excluded; preset tiers split"
    } else {
        Write-Host "SMOKE FAIL: [ingredient_count] $ingredientCount"
        $allPass = $false
    }

    # A recipe craftable only by >=2 fixed_recipe machines has no general machine to
    # anchor a category preset, so it gets a recipe-keyed fixed_recipe preset that
    # persists the machine choice across new lines.
    # Solution-independent, driven off data_test.lua, so it runs once up front too.
    $sharedFixed = Invoke-RconCommand -Stream $stream `
        -Command "/silent-command rcon.print(remote.call('$iface','check_shared_fixed_recipe_machine'))"
    if ($sharedFixed -eq "OK") {
        Write-Host "SMOKE PASS: [shared_fixed_recipe] recipe-keyed preset persists machine choice"
    } else {
        Write-Host "SMOKE FAIL: [shared_fixed_recipe] $sharedFixed"
        $allPass = $false
    }

    # A mining drill's required_fluid is consumed once per mining cycle, so the
    # mining virtual recipe must divide it by mining_time like the products (2x
    # over-count regression on vanilla uranium-ore otherwise).
    # Solution-independent, driven off vanilla uranium-ore, so it runs once up front.
    $requiredFluid = Invoke-RconCommand -Stream $stream `
        -Command "/silent-command rcon.print(remote.call('$iface','check_required_fluid_mining'))"
    if ($requiredFluid -eq "OK") {
        Write-Host "SMOKE PASS: [required_fluid] mining fluid normalized by mining_time"
    } else {
        Write-Host "SMOKE FAIL: [required_fluid] $requiredFluid"
        $allPass = $false
    }

    # Quality-scaled module slots (2.0.77+): get_machine_module_inventory_size
    # reports base + per-quality bonus flag-free. Skips when the quality mod is
    # absent (the fs-test fixture machine still loads, but legendary quality won't
    # exist), so run with -Mods ...,space-age,quality to actually exercise it.
    $qualSlots = Invoke-RconCommand -Stream $stream `
        -Command "/silent-command rcon.print(remote.call('$iface','check_quality_module_slots'))"
    if ($qualSlots -eq "OK") {
        Write-Host "SMOKE PASS: [quality_module_slots] module slots scale by quality (flag-free)"
    } else {
        Write-Host "SMOKE FAIL: [quality_module_slots] $qualSlots"
        $allPass = $false
    }

    # An offshore-pump's output is its fluid_box filter when set, else the tile's
    # fluid. A filter-pinned, tile-less fluid (lubricant) must surface via a
    # <pump-fluid> recipe served only by that pump, the unfiltered pump must be
    # excluded from it yet offered for water, and the preset layer must cover it.
    # Solution-independent, driven off data_test.lua, so it runs once up front too.
    $pumpFilter = Invoke-RconCommand -Stream $stream `
        -Command "/silent-command rcon.print(remote.call('$iface','check_offshore_pump_filter'))"
    if ($pumpFilter -eq "OK") {
        Write-Host "SMOKE PASS: [offshore_pump_filter] filter fluid surfaces; unfiltered pump excluded"
    } else {
        Write-Host "SMOKE FAIL: [offshore_pump_filter] $pumpFilter"
        $allPass = $false
    }
    foreach ($fixture in $Fixtures) {
        $setup = Invoke-RconCommand -Stream $stream `
            -Command "/silent-command rcon.print(remote.call('$iface','setup','$fixture'))"
        if ($setup -match '^SKIP:') {
            # A required mod isn't in this run's set -- trimmed coverage, not a failure.
            Write-Host "SMOKE SKIP: [$fixture] $($setup -replace '^SKIP:\s*', '')"
            $skipCount++
            continue
        }
        if ($setup -notmatch '^OK:') {
            Write-Host "SMOKE FAIL: [$fixture] setup -> $setup"
            $allPass = $false
            continue
        }

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $state = $null
        $verdict = $null
        while ($true) {
            $state = Invoke-RconCommand -Stream $stream `
                -Command "/silent-command rcon.print(remote.call('$iface','state'))"
            switch -Regex ($state) {
                '^finished$'                          { $verdict = "PASS"; break }
                '^(unfinished|unbounded|unfeasible)$' { $verdict = "FAIL"; break }
                '^ERROR'                              { $verdict = "FAIL"; break }
                default { }   # "ready" or "calculating": keep polling
            }
            if ($verdict) { break }
            if ((Get-Date) -gt $deadline) { $verdict = "FAIL"; $state = "deadline exceeded (last=$state)"; break }
            if ($proc.HasExited) { $verdict = "FAIL"; $state = "factorio exited mid-solve"; break }
            Start-Sleep -Milliseconds 200
        }

        # On convergence, also exercise the read-side total helpers
        # (report.get_total_*) -- the path that crashed in the 0.3.13 report.
        # They take the force's ResearchBonuses directly, so they run with no
        # player. A read-side failure flips the verdict to FAIL.
        $readSide = $null
        if ($verdict -eq "PASS") {
            $readSide = Invoke-RconCommand -Stream $stream `
                -Command "/silent-command rcon.print(remote.call('$iface','check_read_side'))"
            if ($readSide -ne "OK") { $verdict = "FAIL" }
        }

        # The catalyst_reclassify fixture additionally proves the observe-price
        # machine resolved the catalyst loop (observe_price settled, residual
        # cheat ~0, loop recipes running), not merely that the solve converged --
        # a clean solve also reaches "finished".
        $reclassify = $null
        if ($verdict -eq "PASS" -and $fixture -eq "catalyst_reclassify") {
            $reclassify = Invoke-RconCommand -Stream $stream `
                -Command "/silent-command rcon.print(remote.call('$iface','check_catalyst_reclassify'))"
            if ($reclassify -ne "OK") { $verdict = "FAIL" }
        }

        # The target_rescue fixture additionally proves the lexicographic target
        # rescue resolved the tier-1 collapse (budget locked, target met, loop
        # running) -- the collapsed all-zero answer also reaches "finished".
        $rescue = $null
        if ($verdict -eq "PASS" -and $fixture -eq "target_rescue") {
            $rescue = Invoke-RconCommand -Stream $stream `
                -Command "/silent-command rcon.print(remote.call('$iface','check_target_rescue'))"
            if ($rescue -ne "OK") { $verdict = "FAIL" }
        }

        $detail = "solver_state=$state"
        if ($readSide) { $detail += "; read_side=$readSide" }
        if ($reclassify) { $detail += "; reclassify=$reclassify" }
        if ($rescue) { $detail += "; rescue=$rescue" }
        Write-Host "SMOKE $verdict`: [$fixture] $detail"
        if ($verdict -ne "PASS") { $allPass = $false }
    }

    if ($skipCount -gt 0) {
        Write-Host "smoke_rcon: $skipCount of $($Fixtures.Count) fixtures skipped (required mods not in the set)"
    }
    $exitCode = if ($allPass) { 0 } else { 1 }
}
catch {
    Write-Host "SMOKE FAIL: $($_.Exception.Message)"
    Write-Host "smoke_rcon: last 30 lines of the Factorio log:"
    if (Test-Path $ws.LogFile) {
        Get-Content $ws.LogFile -Tail 30 | ForEach-Object { Write-Host "  $_" }
    }
    $exitCode = 2
}
finally {
    # Try a clean server shutdown over RCON; fall back to killing the process
    # (Factorio offers no in-Lua self-terminate).
    if ($stream) {
        try { Send-RconPacket -Stream $stream -Id 3 -Type 2 -Body "/quit" } catch {}
    }
    if ($client) { $client.Dispose() }
    Start-Sleep -Milliseconds 500
    if (-not $proc.HasExited) {
        $proc.Kill()
        Start-Sleep -Milliseconds 500
    }

    # The autosave, the log, the .lock -- everything Factorio wrote -- lives in
    # the run workspace, which is removed wholesale. Kept on -KeepRun, and on
    # any non-zero exit so a FAIL's log survives for autopsy.
    Remove-RunWorkspace -Workspace $ws -Keep:($KeepRun -or $exitCode -ne 0)
}

exit $exitCode
