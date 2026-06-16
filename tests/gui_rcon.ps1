# RCON-driven in-game GUI test launcher.
#
# The smoke harness (tests/smoke_rcon.ps1) drives the solver + manage layers from
# an EMPTY scenario, which on a headless dedicated server has NO player -- so the
# GUI layer (ui/*.lua handlers, which can only build under LuaPlayer.gui) is out of
# its scope. This launcher closes that gap: it boots Factorio with a real,
# player-bearing SAVE (--start-server <save>, not --start-server-load-scenario), so
# game.players[1].gui.screen works against the offline player, and runs each GUI
# test in tests/gui/*.lua via /silent-command in the mod's VM.
#
# A player cannot be script-created on a headless server (game.create_player does
# not exist; a fresh scenario has 0 players), so the one un-scriptable ingredient
# -- a single player -- must come from a save minted once by a real client session.
# The TEST LOGIC is NOT frozen into that save: only the level/scenario script is
# snapshotted in a save, while mod code (and these test scripts, run via
# /silent-command in the mod VM) executes fresh from the current checkout on every
# load. So tests/gui/*.lua can be edited freely without regenerating the save.
#
# Each test prints exactly one verdict line: "GUITEST PASS: ..." or
# "GUITEST FAIL: ...". The launcher boots once, runs every test in the same server,
# and decides the run from those lines.
#
# Exit codes: 0 = all tests PASS, 1 = a test FAILed (or gave no verdict), 2 = setup
# error (Factorio / save not found, RCON never came up, etc).
#
# Usage:
#   pwsh tests/gui_rcon.ps1
#   pwsh tests/gui_rcon.ps1 -SavePath "$env:APPDATA\Factorio\saves\_autosave1.zip" -Mods @()
#   pwsh tests/gui_rcon.ps1 -Tests machine_presets_toggle -KeepRun

[CmdletBinding()]
param(
    # Player-bearing save to load. Default is the checked-in minimal fixture (a
    # base+flib+factory_solver freeplay save with one player). Override to run the
    # GUI tests against a heavier mod set (e.g. a pyanodon autosave with -Mods @()).
    [string] $SavePath = "",
    # Test base-names (tests/gui/<name>.lua). Default = every .lua in tests/gui.
    [string[]] $Tests = @(),
    # Mods to enable; must be a superset of what the save needs. Default mirrors
    # smoke's vanilla set (the minimal fixture is made with exactly these). Pass
    # @() to mirror the dev config (for a modded save like a pyanodon autosave).
    [string[]] $Mods = @("base", "flib", "factory_solver"),
    # Per-test deadline for the /silent-command to return (a synchronous GUI build
    # of thousands of buttons can take a few seconds).
    [int] $TestTimeoutSeconds = 120,
    [int] $RconStartupSeconds = 600,
    [int] $RconPort = 0,
    [string] $RconPassword = "",
    [string] $RunRoot = "",
    [switch] $KeepRun
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
. "$PSScriptRoot/rcon_lib.ps1"

# -Mods / -Tests comma+space normalization (see smoke_rcon.ps1 for the -File quirk).
$Mods = @($Mods | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Tests = @($Tests | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if (-not $SavePath) { $SavePath = Join-Path $repoRoot.Path "tests/fixtures/gui_player.zip" }
if (-not (Test-Path -LiteralPath $SavePath)) {
    Write-Host "gui_rcon: SETUP ERROR: save not found: $SavePath"
    Write-Host "gui_rcon: mint a minimal player-bearing save once (new game with base+flib+factory_solver,"
    Write-Host "gui_rcon: then save) and place it at tests/fixtures/gui_player.zip, or pass -SavePath."
    exit 2
}

# Resolve the test files.
$guiDir = Join-Path $PSScriptRoot "gui"
$testFiles = @()
if ($Tests.Count -gt 0) {
    foreach ($t in $Tests) { $testFiles += (Join-Path $guiDir "$t.lua") }
} else {
    $testFiles = @(Get-ChildItem -Path $guiDir -Filter "*.lua" | Sort-Object Name | ForEach-Object { $_.FullName })
}
if ($testFiles.Count -eq 0) {
    Write-Host "gui_rcon: SETUP ERROR: no test files under $guiDir"
    exit 2
}

if ($RconPort -eq 0) { $RconPort = Get-FreeTcpPort }
if (-not $RconPassword) { $RconPassword = [guid]::NewGuid().ToString('N') }
$runRoot = Resolve-RunRoot -RunRoot $RunRoot

$ws = $null
try {
    Invoke-RunRootGc -RunRoot $runRoot
    $cfg = Resolve-FactorioConfig -RepoRoot $repoRoot.Path
    $ws = New-RunWorkspace -Tag "gui" -ServerName "factory_solver_gui_rcon" -RunRoot $runRoot
    Initialize-ScratchMods -Workspace $ws -SourceModsDir $cfg.ModsDir -RepoRoot $repoRoot.Path -Mods $Mods
} catch {
    Write-Error $_.Exception.Message
    Remove-RunWorkspace -Workspace $ws
    exit 2
}

# Copy the save into the workspace so the original is never written back to.
$saveCopy = Join-Path $ws.Dir "gui_load.zip"
Copy-Item -LiteralPath $SavePath -Destination $saveCopy -Force

Write-Host "gui_rcon: factorio = $($cfg.Factorio)"
Write-Host "gui_rcon: save     = $SavePath"
Write-Host "gui_rcon: run dir  = $($ws.Dir)"
Write-Host "gui_rcon: rcon     = 127.0.0.1:$RconPort"
Write-Host "gui_rcon: mod set  = $(if ($Mods.Count) { $Mods -join ', ' } else { '(dev config mirrored)' })"
Write-Host "gui_rcon: tests    = $(($testFiles | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) }) -join ', ')"

$list = @(
    "--start-server", $saveCopy,
    "--mod-directory", $ws.ModsDir,
    "--server-settings", $ws.ServerSettingsPath,
    "--config", $ws.ConfigPath,
    "--port", (Get-FreeUdpPort),
    "--rcon-bind", "127.0.0.1:$RconPort",
    "--rcon-password", $RconPassword,
    "--no-log-rotation",
    "--disable-audio"
)
$arguments = @($list | ForEach-Object { Format-CommandArgument $_ })
$env:SteamAppId = "427520"
$proc = Start-Process -FilePath $cfg.Factorio -ArgumentList $arguments -PassThru -NoNewWindow

$client = $null; $stream = $null; $exitCode = 1
try {
    $rcon = Connect-Rcon -Port $RconPort -Password $RconPassword -TimeoutSeconds $RconStartupSeconds -Proc $proc
    $client = $rcon.Client
    $stream = $rcon.Stream
    Write-Host "gui_rcon: RCON authenticated`n"

    # A freshly-minted save still has achievements enabled, so the FIRST Lua console
    # command is intercepted ("Using Lua console commands will disable achievements.
    # Please repeat the command to proceed.") and does NOT execute -- it only flips
    # the session into command-allowed state. Absorb that one-time gate with a
    # throwaway command so the first real test isn't silently eaten by it. (A save
    # that already used commands skips the warning; the warmup is then harmless.)
    Send-RconPacket -Stream $stream -Id 2 -Type 2 -Body "/silent-command rcon.print('gui_rcon warmup')"
    $stream.ReadTimeout = 5000
    try { [void](Receive-RconPacket -Stream $stream) } catch {}
    $stream.ReadTimeout = 400
    while ($true) { try { [void](Receive-RconPacket -Stream $stream) } catch [System.IO.IOException] { break } }

    $allPass = $true
    foreach ($file in $testFiles) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
        $lua = (Get-Content -Raw $file) -replace "`r", ""
        $command = "/silent-command __factory_solver__ " + $lua

        Send-RconPacket -Stream $stream -Id 2 -Type 2 -Body $command
        # The command blocks until the (possibly heavy, synchronous) Lua returns, so
        # the first packet can take seconds -- wait long for it, then drain the rest.
        $stream.ReadTimeout = ($TestTimeoutSeconds * 1000)
        $sb = New-Object System.Text.StringBuilder
        try {
            [void]$sb.Append((Receive-RconPacket -Stream $stream).Body)
        } catch {
            Write-Host "GUI FAIL: [$name] no response within ${TestTimeoutSeconds}s ($($_.Exception.Message))"
            $allPass = $false
            continue
        }
        $stream.ReadTimeout = 400
        while ($true) {
            try { [void]$sb.Append((Receive-RconPacket -Stream $stream).Body) }
            catch [System.IO.IOException] { break }
        }
        $out = $sb.ToString().Trim()

        if ($out -match "GUITEST FAIL") {
            $detail = ($out -split "`n" | Where-Object { $_ -match "GUITEST FAIL" } | Select-Object -First 1)
            Write-Host "GUI FAIL: [$name] $($detail -replace 'GUITEST FAIL:\s*', '')"
            $allPass = $false
        } elseif ($out -match "GUITEST PASS") {
            $detail = ($out -split "`n" | Where-Object { $_ -match "GUITEST PASS" } | Select-Object -First 1)
            Write-Host "GUI PASS: [$name] $($detail -replace 'GUITEST PASS:\s*', '')"
        } else {
            Write-Host "GUI FAIL: [$name] no GUITEST verdict in output: $($out -replace "`n", ' | ')"
            $allPass = $false
        }
    }

    $exitCode = if ($allPass) { 0 } else { 1 }
}
catch {
    Write-Host "gui_rcon: FAILED: $($_.Exception.Message)"
    if (Test-Path $ws.LogFile) {
        Write-Host "gui_rcon: last 30 log lines:"
        Get-Content $ws.LogFile -Tail 30 | ForEach-Object { Write-Host "  $_" }
    }
    $exitCode = 2
}
finally {
    if ($stream) { try { Send-RconPacket -Stream $stream -Id 3 -Type 2 -Body "/quit" } catch {} }
    if ($client) { $client.Dispose() }
    Start-Sleep -Milliseconds 500
    if (-not $proc.HasExited) { $proc.Kill(); Start-Sleep -Milliseconds 500 }
    Remove-RunWorkspace -Workspace $ws -Keep:($KeepRun -or $exitCode -ne 0)
}
exit $exitCode
