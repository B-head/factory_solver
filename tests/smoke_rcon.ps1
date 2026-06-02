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
# Mod set: the launcher rewrites <mods>/mod-list.json to a reproducible set
# (-Mods, default base+flib+factory_solver) and restores the original afterward.
# The mods directory comes from .vscode/launch.json's modsPath -- the same value
# the factoriomod-debug extension uses -- rather than being hardcoded. A fixture
# that reads a mod's prototypes declares it in `requires` and is SKIPped (not
# failed) when that mod isn't in the set.
#
# Exit codes: 0 = all fixtures PASS (skips are not failures), 1 = a fixture
# FAILed (or no response), 2 = setup error (Factorio not found, RCON never came
# up, etc).
#
# Usage:
#   pwsh tests/smoke_rcon.ps1
#   pwsh tests/smoke_rcon.ps1 -Fixtures iron_plate -Mods base,flib,factory_solver,space-age,quality,elevated-rails

[CmdletBinding()]
param(
    # Per-fixture deadline for the solver to reach a terminal state.
    [int] $TimeoutSeconds = 45,
    # Seconds to wait for the server to open its RCON port after launch.
    [int] $RconStartupSeconds = 90,
    [string[]] $Fixtures = @("iron_plate", "missing_prototype", "boiler_steam", "reactor_burnt_fuel",
        "migration_legacy_shape", "codec_solution_roundtrip", "codec_fp_roundtrip", "codec_helmod_roundtrip"),
    # Mods to enable for the run; everything else in mod-list.json is disabled.
    # Default is the vanilla minimal set. Pass @() to leave mod-list.json
    # untouched (load whatever the dev config has enabled).
    [string[]] $Mods = @("base", "flib", "factory_solver"),
    [int] $RconPort = 27115,
    [string] $RconPassword = "smoke"
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

# Normalize -Mods to a clean string array. `powershell -File ... -Mods a,b,c`
# binds the comma list as a SINGLE string (no split) rather than an array, which
# would silently leave only base enabled; splitting on commas here makes both
# comma- and space-separated forms work regardless of how -File bound them.
$Mods = @($Mods | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# ---------------------------------------------------------------------------
# Settings / paths (shared shape with tests/smoke.ps1)
# ---------------------------------------------------------------------------
$settingsPath = Join-Path $repoRoot ".vscode/settings.json"
if (-not (Test-Path $settingsPath)) {
    Write-Error "settings.json not found at $settingsPath"
    exit 2
}
# Windows PowerShell 5.1's ConvertFrom-Json rejects JSONC trailing commas; strip
# them first (same workaround as tests/smoke.ps1).
$settingsJson = (Get-Content $settingsPath -Raw) -replace ',(\s*[}\]])', '$1'
$settings = $settingsJson | ConvertFrom-Json
$factorio = $settings.'factorio.versions'[0].factorioPath
if (-not (Test-Path $factorio)) {
    Write-Error "Factorio binary not found at $factorio"
    exit 2
}

# The mods directory is sourced from .vscode/launch.json's modsPath -- the same
# value factoriomod-debug uses -- so the smoke stays in lockstep with the
# debugger config instead of hardcoding "repo parent". launch.json is JSONC, so
# strip // line comments and trailing commas before parsing.
$launchPath = Join-Path $repoRoot ".vscode/launch.json"
if (-not (Test-Path $launchPath)) {
    Write-Error "launch.json not found at $launchPath"
    exit 2
}
$launchNoComments = ((Get-Content $launchPath -Raw) -split "`n" | ForEach-Object { $_ -replace '//.*$', '' }) -join "`n"
$launch = ($launchNoComments -replace ',(\s*[}\]])', '$1') | ConvertFrom-Json
$modsPathRaw = ($launch.configurations | Where-Object { $_.modsPath } | Select-Object -First 1).modsPath
if (-not $modsPathRaw) {
    Write-Error "no configuration with a modsPath in launch.json"
    exit 2
}
$modsDir = (Resolve-Path ($modsPathRaw -replace [regex]::Escape('${workspaceFolder}'), $repoRoot.Path)).Path
$logFile = Join-Path $env:APPDATA "Factorio/factorio-current.log"

# A dedicated server wants a server-settings file; the built-in defaults prompt
# for things we do not want in a throwaway local run. Write a minimal one to
# TEMP: private, no user verification, single slot. Missing fields fall back to
# engine defaults.
$serverSettings = Join-Path $env:TEMP "factory_solver_smoke_server_settings.json"
@'
{
    "name": "factory_solver_smoke_rcon",
    "description": "factory_solver RCON smoke test",
    "visibility": { "public": false, "lan": false },
    "require_user_verification": false,
    "max_players": 1,
    "allow_commands": "true"
}
'@ | Set-Content -Path $serverSettings -Encoding utf8

Write-Host "smoke_rcon: factorio = $factorio"
Write-Host "smoke_rcon: mods     = $modsDir"
Write-Host "smoke_rcon: rcon     = 127.0.0.1:$RconPort"
Write-Host "smoke_rcon: fixtures = $($Fixtures -join ', ')"
Write-Host "smoke_rcon: mod set  = $(if ($Mods.Count) { $Mods -join ', ' } else { '(dev config unchanged)' })"

# ---------------------------------------------------------------------------
# RCON client (Source RCON protocol over TCP, .NET sockets, no dependencies)
#
# Packet on the wire (all little-endian, which is what .NET BitConverter emits
# on x86/x64): int32 size | int32 id | int32 type | body (ASCII) | 0x00 | 0x00.
# `size` counts everything after itself, i.e. 4 + 4 + len(body) + 2.
# Types: 3 = auth request, 2 = exec command / auth response, 0 = response value.
# ---------------------------------------------------------------------------
function Read-Exact {
    param([System.IO.Stream] $Stream, [int] $Count)
    $buf = [byte[]]::new($Count)
    $off = 0
    while ($off -lt $Count) {
        $n = $Stream.Read($buf, $off, $Count - $off)
        if ($n -le 0) { throw "RCON stream closed mid-packet" }
        $off += $n
    }
    return ,$buf
}

function Send-RconPacket {
    param([System.IO.Stream] $Stream, [int] $Id, [int] $Type, [string] $Body)
    $bodyBytes = [System.Text.Encoding]::ASCII.GetBytes($Body)
    $size = 10 + $bodyBytes.Length
    $buf = [byte[]]::new(4 + $size)               # last 2 bytes stay zero = the nulls
    [BitConverter]::GetBytes([int]$size).CopyTo($buf, 0)
    [BitConverter]::GetBytes([int]$Id).CopyTo($buf, 4)
    [BitConverter]::GetBytes([int]$Type).CopyTo($buf, 8)
    [Array]::Copy($bodyBytes, 0, $buf, 12, $bodyBytes.Length)
    $Stream.Write($buf, 0, $buf.Length)
    $Stream.Flush()
}

function Receive-RconPacket {
    param([System.IO.Stream] $Stream)
    $sizeBytes = Read-Exact -Stream $Stream -Count 4
    $size = [BitConverter]::ToInt32($sizeBytes, 0)
    $rest = Read-Exact -Stream $Stream -Count $size
    $id = [BitConverter]::ToInt32($rest, 0)
    $type = [BitConverter]::ToInt32($rest, 4)
    $bodyLen = $size - 10
    $body = if ($bodyLen -gt 0) { [System.Text.Encoding]::ASCII.GetString($rest, 8, $bodyLen) } else { "" }
    return [PSCustomObject]@{ Id = $id; Type = $type; Body = $body }
}

# Run a single console command and return its rcon.print output (trimmed).
# Commands here always wrap their payload in rcon.print(), so a response is
# expected. Responses are small (a solution name or a solver_state word), so
# single-packet reads suffice; large multi-packet responses are out of scope.
function Invoke-RconCommand {
    param([System.IO.Stream] $Stream, [string] $Command)
    Send-RconPacket -Stream $Stream -Id 2 -Type 2 -Body $Command
    $resp = Receive-RconPacket -Stream $Stream
    return $resp.Body.Trim()
}

# ---------------------------------------------------------------------------
# Launch (Steam relaunch + stale lock handling mirror tests/smoke.ps1)
# ---------------------------------------------------------------------------
$arguments = @(
    "--start-server-load-scenario", "factory_solver/smoke_rcon",
    "--mod-directory", $modsDir,
    "--server-settings", $serverSettings,
    "--rcon-bind", "127.0.0.1:$RconPort",
    "--rcon-password", $RconPassword,
    "--no-log-rotation",
    "--disable-audio"
)

# Steam-built factorio.exe relaunches itself via Steam unless it thinks Steam
# launched it; setting SteamAppId makes the SDK skip the relaunch (same trick as
# tests/smoke.ps1 and factoriomod-debug).
$env:SteamAppId = "427520"

$lockFile = Join-Path $env:APPDATA "Factorio/.lock"
if ((Test-Path $lockFile) -and -not (Get-Process -Name "factorio" -ErrorAction SilentlyContinue)) {
    Write-Host "smoke_rcon: clearing stale lock file"
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}

# --- Mod set control --------------------------------------------------------
# Factorio reads enable/disable state from <mod-directory>/mod-list.json. To run
# a known, reproducible set we rewrite that file (requested mods enabled, the
# rest disabled) and restore it in the finally block. Because the directory is
# the shared dev mods folder, the original is backed up to a .smoke-bak sibling;
# a .smoke-bak left over by a crashed run is restored on startup before we touch
# anything, so the dev config is never lost. -Mods @() opts out entirely.
$modListPath = Join-Path $modsDir "mod-list.json"
$modListBak = "$modListPath.smoke-bak"
$controlMods = $Mods.Count -gt 0
$modListHadOriginal = $false

if (Test-Path $modListBak) {
    Write-Host "smoke_rcon: restoring mod-list.json from a prior run's backup"
    Move-Item -Force $modListBak $modListPath
}

if ($controlMods) {
    $modListHadOriginal = Test-Path $modListPath
    $names = New-Object System.Collections.Generic.List[string]
    if ($modListHadOriginal) {
        Copy-Item $modListPath $modListBak -Force
        foreach ($m in (Get-Content $modListPath -Raw | ConvertFrom-Json).mods) { [void]$names.Add($m.name) }
    }
    # Ensure requested mods appear even if absent from the dev config.
    foreach ($m in $Mods) { if (-not $names.Contains($m)) { [void]$names.Add($m) } }
    # Close the gap: a mod present on disk but absent from the original
    # mod-list.json is auto-enabled by Factorio (mods it doesn't find listed
    # default to enabled). Enumerate disk mods -- folders with an info.json and
    # name_version.zip archives -- so each gets an explicit entry and is disabled
    # unless requested, keeping the set reproducible.
    foreach ($d in Get-ChildItem $modsDir -Directory -ErrorAction SilentlyContinue) {
        $info = Join-Path $d.FullName "info.json"
        if (Test-Path $info) {
            try { $n = (Get-Content $info -Raw | ConvertFrom-Json).name } catch { $n = $null }
            if ($n -and -not $names.Contains($n)) { [void]$names.Add($n) }
        }
    }
    foreach ($z in Get-ChildItem $modsDir -Filter *.zip -ErrorAction SilentlyContinue) {
        if ($z.BaseName -match '^(.+)_\d+\.\d+\.\d+$' -and -not $names.Contains($Matches[1])) {
            [void]$names.Add($Matches[1])
        }
    }
    # base is core and always loads; force it enabled regardless of -Mods.
    $entries = foreach ($name in $names) {
        [PSCustomObject]@{ name = $name; enabled = ($Mods -contains $name) -or ($name -eq 'base') }
    }
    ([PSCustomObject]@{ mods = @($entries) } | ConvertTo-Json -Depth 5) |
        Set-Content -Path $modListPath -Encoding utf8
}

$proc = Start-Process -FilePath $factorio -ArgumentList $arguments -PassThru -NoNewWindow

$client = $null
$stream = $null
$exitCode = 1

try {
    # --- Wait for the server to open its RCON port -------------------------
    $connectDeadline = (Get-Date).AddSeconds($RconStartupSeconds)
    while ($true) {
        if ($proc.HasExited) { throw "Factorio exited before RCON came up (code $($proc.ExitCode))" }
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect("127.0.0.1", $RconPort)
            $stream = $client.GetStream()
            break
        } catch {
            if ($client) { $client.Dispose(); $client = $null }
            if ((Get-Date) -gt $connectDeadline) { throw "RCON port $RconPort never opened within ${RconStartupSeconds}s" }
            Start-Sleep -Milliseconds 500
        }
    }
    Write-Host "smoke_rcon: RCON connected"

    # --- Authenticate ------------------------------------------------------
    Send-RconPacket -Stream $stream -Id 1 -Type 3 -Body $RconPassword
    $auth = Receive-RconPacket -Stream $stream
    # Some servers emit an empty RESPONSE_VALUE before the AUTH_RESPONSE; skip it.
    if ($auth.Type -eq 0) { $auth = Receive-RconPacket -Stream $stream }
    if ($auth.Id -eq -1) { throw "RCON auth failed (wrong password?)" }
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

        $detail = "solver_state=$state"
        if ($readSide) { $detail += "; read_side=$readSide" }
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
    if (Test-Path $logFile) {
        Get-Content $logFile -Tail 30 | ForEach-Object { Write-Host "  $_" }
    }
    $exitCode = 2
}
finally {
    # Try a clean server shutdown over RCON; fall back to killing the process
    # (Factorio offers no in-Lua self-terminate -- see tests/smoke.ps1).
    if ($stream) {
        try { Send-RconPacket -Stream $stream -Id 3 -Type 2 -Body "/quit" } catch {}
    }
    if ($client) { $client.Dispose() }
    Start-Sleep -Milliseconds 500
    if (-not $proc.HasExited) {
        $proc.Kill()
        Start-Sleep -Milliseconds 500
    }

    # A server autosaves the scenario on /quit, leaving saves/smoke_rcon.zip.
    # It is overwritten each run (never accumulates) but clutters the in-game
    # save list, so remove this throwaway test artifact. The name matches our
    # scenario, so there is nothing of the user's to clobber.
    $smokeSave = Join-Path $env:APPDATA "Factorio/saves/smoke_rcon.zip"
    if (Test-Path $smokeSave) { Remove-Item $smokeSave -Force -ErrorAction SilentlyContinue }

    # Restore the dev mod-list.json we rewrote for this run.
    if ($controlMods) {
        if (Test-Path $modListBak) {
            Move-Item -Force $modListBak $modListPath
        } elseif (-not $modListHadOriginal) {
            Remove-Item $modListPath -Force -ErrorAction SilentlyContinue
        }
    }
}

exit $exitCode
