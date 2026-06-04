# Random-chain explorer launcher (research/stress harness, NOT a pass/fail gate).
#
# Boots Factorio as a dedicated server with the factory_solver/smoke_rcon
# scenario (control.lua registers BOTH the smoke driver and the chain explorer
# there), enables a pyanodon mod set, then drives manage/chain_explorer.lua over
# RCON: for each seed it builds a random connected recipe chain, pins the seed
# recipe, solves it through the real pre_solve -> create_problem -> IPM path, and
# reports whether the solution is "undesirable" (solver_state != finished, or a
# large fraction of recipe variables parked near zero).
#
# This shares the RCON transport / launch / mod-list machinery with
# tests/smoke_rcon.ps1; it is a separate file so the smoke gate stays a clean
# pass/fail and this stays an open-ended explorer. Lines ending in "<<HIT" are
# the undesirable solutions; each is reproducible by re-running its seed.
#
# Usage:
#   pwsh tests/explore_chains.ps1                 # 30 seeds, pyanodon full set
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
    [int] $RconPort = 27116,
    [string] $RconPassword = "explore",
    [string] $HitLog = "",
    # Quality recycling mode: enable the quality mod, fill machine module slots
    # with quality modules, and target a high-quality item (drives the
    # upgrade-and-recycle loop -- this mod's USP and the hardest case for the IPM).
    [switch] $Quality
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

$settingsPath = Join-Path $repoRoot ".vscode/settings.json"
if (-not (Test-Path $settingsPath)) { Write-Error "settings.json not found at $settingsPath"; exit 2 }
$settingsJson = (Get-Content $settingsPath -Raw) -replace ',(\s*[}\]])', '$1'
$settings = $settingsJson | ConvertFrom-Json
$factorio = $settings.'factorio.versions'[0].factorioPath
if (-not (Test-Path $factorio)) { Write-Error "Factorio binary not found at $factorio"; exit 2 }

$launchPath = Join-Path $repoRoot ".vscode/launch.json"
if (-not (Test-Path $launchPath)) { Write-Error "launch.json not found at $launchPath"; exit 2 }
$launchNoComments = ((Get-Content $launchPath -Raw) -split "`n" | ForEach-Object { $_ -replace '//.*$', '' }) -join "`n"
$launch = ($launchNoComments -replace ',(\s*[}\]])', '$1') | ConvertFrom-Json
$modsPathRaw = ($launch.configurations | Where-Object { $_.modsPath } | Select-Object -First 1).modsPath
if (-not $modsPathRaw) { Write-Error "no configuration with a modsPath in launch.json"; exit 2 }
$modsDir = (Resolve-Path ($modsPathRaw -replace [regex]::Escape('${workspaceFolder}'), $repoRoot.Path)).Path
$logFile = Join-Path $env:APPDATA "Factorio/factorio-current.log"

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

if (-not $HitLog) { $HitLog = Join-Path $repoRoot.Path "..\explore_hits.log" }
if (-not [System.IO.Path]::IsPathRooted($HitLog)) { $HitLog = Join-Path (Get-Location).Path $HitLog }
$HitLog = [System.IO.Path]::GetFullPath($HitLog)

# Minimal dedicated-server settings (same shape as smoke_rcon.ps1).
$serverSettings = Join-Path $env:TEMP "factory_solver_explore_server_settings.json"
@'
{
    "name": "factory_solver_explore",
    "description": "factory_solver random-chain explorer",
    "visibility": { "public": false, "lan": false },
    "require_user_verification": false,
    "max_players": 1,
    "allow_commands": "true"
}
'@ | Set-Content -Path $serverSettings -Encoding utf8

Write-Host "explore: factorio = $factorio"
Write-Host "explore: mods     = $modsDir"
Write-Host "explore: rcon     = 127.0.0.1:$RconPort"
Write-Host "explore: seeds    = $StartSeed .. $($StartSeed + $Seeds - 1)  (hops=$Hops)"
Write-Host "explore: mod set  = $($Mods -join ', ')"
Write-Host "explore: hit log  = $HitLog"

# --- RCON client (Source RCON over TCP; copied from smoke_rcon.ps1) ----------
function Read-Exact {
    param([System.IO.Stream] $Stream, [int] $Count)
    $buf = [byte[]]::new($Count); $off = 0
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
    $buf = [byte[]]::new(4 + $size)
    [BitConverter]::GetBytes([int]$size).CopyTo($buf, 0)
    [BitConverter]::GetBytes([int]$Id).CopyTo($buf, 4)
    [BitConverter]::GetBytes([int]$Type).CopyTo($buf, 8)
    [Array]::Copy($bodyBytes, 0, $buf, 12, $bodyBytes.Length)
    $Stream.Write($buf, 0, $buf.Length); $Stream.Flush()
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
function Invoke-RconCommand {
    param([System.IO.Stream] $Stream, [string] $Command)
    Send-RconPacket -Stream $Stream -Id 2 -Type 2 -Body $Command
    $resp = Receive-RconPacket -Stream $Stream
    return $resp.Body.Trim()
}

# --- Launch (mirrors smoke_rcon.ps1) -----------------------------------------
$arguments = @(
    "--start-server-load-scenario", "factory_solver/smoke_rcon",
    "--mod-directory", $modsDir,
    "--server-settings", $serverSettings,
    "--rcon-bind", "127.0.0.1:$RconPort",
    "--rcon-password", $RconPassword,
    "--no-log-rotation",
    "--disable-audio"
)
$env:SteamAppId = "427520"

$lockFile = Join-Path $env:APPDATA "Factorio/.lock"
if ((Test-Path $lockFile) -and -not (Get-Process -Name "factorio" -ErrorAction SilentlyContinue)) {
    Write-Host "explore: clearing stale lock file"
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}

# --- Mod set control (rewrite mod-list.json, restore in finally) -------------
$modListPath = Join-Path $modsDir "mod-list.json"
$modListBak = "$modListPath.explore-bak"
$modListHadOriginal = $false
if (Test-Path $modListBak) {
    Write-Host "explore: restoring mod-list.json from a prior run's backup"
    Move-Item -Force $modListBak $modListPath
}
$modListHadOriginal = Test-Path $modListPath
$names = New-Object System.Collections.Generic.List[string]
if ($modListHadOriginal) {
    Copy-Item $modListPath $modListBak -Force
    foreach ($m in (Get-Content $modListPath -Raw | ConvertFrom-Json).mods) { [void]$names.Add($m.name) }
}
foreach ($m in $Mods) { if (-not $names.Contains($m)) { [void]$names.Add($m) } }
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
$entries = foreach ($name in $names) {
    [PSCustomObject]@{ name = $name; enabled = ($Mods -contains $name) -or ($name -eq 'base') }
}
([PSCustomObject]@{ mods = @($entries) } | ConvertTo-Json -Depth 5) |
    Set-Content -Path $modListPath -Encoding utf8

$proc = Start-Process -FilePath $factorio -ArgumentList $arguments -PassThru -NoNewWindow
$client = $null; $stream = $null; $exitCode = 1
$hits = New-Object System.Collections.Generic.List[string]
$errors = 0; $finished = 0

try {
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
    Write-Host "explore: RCON connected"

    Send-RconPacket -Stream $stream -Id 1 -Type 3 -Body $RconPassword
    $auth = Receive-RconPacket -Stream $stream
    if ($auth.Type -eq 0) { $auth = Receive-RconPacket -Stream $stream }
    if ($auth.Id -eq -1) { throw "RCON auth failed (wrong password?)" }
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
            @{mode = 'both'; void = 'in'; nosrc = 'in'; pins = 1; qual = 'off'; hops = $Hops }         # control
        )
    }
    foreach ($cfg in $configs) {
        $tgt = if ($cfg.target) { $cfg.target } else { 'recipe' }
        $cls = if ($cfg.closure) { $cfg.closure } else { 'on' }
        $ini = if ($cfg.init) { $cfg.init } else { 'recipe' }
        $banner = "config mode=$($cfg.mode) init=$ini void=$($cfg.void) nosrc=$($cfg.nosrc) pins=$($cfg.pins) qual=$($cfg.qual) target=$tgt closure=$cls hops=$($cfg.hops)"
        Write-Host "`n--- $banner ---"
        "## $banner" | Out-File -FilePath $HitLog -Append -Encoding utf8
        for ($i = 0; $i -lt $Seeds; $i++) {
            $s = $StartSeed + $i
            if ($proc.HasExited) { throw "factorio exited mid-run" }
            $exploreArgs = "seed=$s;hops=$($cfg.hops);mode=$($cfg.mode);init=$ini;void=$($cfg.void);nosrc=$($cfg.nosrc);pins=$($cfg.pins);qual=$($cfg.qual);target=$tgt;closure=$cls"
            $cmd = "/silent-command rcon.print(remote.call('$iface','explore','$exploreArgs'))"
            $r = Invoke-RconCommand -Stream $stream -Command $cmd
            if ($r -match '<<HIT') {
                Write-Host "  $r" -ForegroundColor Yellow
                $hits.Add($r); $r | Out-File -FilePath $HitLog -Append -Encoding utf8
            } elseif ($r -match '^ERROR') {
                Write-Host "  $r" -ForegroundColor Red
                $errors++; $r | Out-File -FilePath $HitLog -Append -Encoding utf8
            } elseif ($r -match '~park') {
                Write-Host "  $r" -ForegroundColor DarkYellow
                $r | Out-File -FilePath $HitLog -Append -Encoding utf8
            } else {
                Write-Host "  $r"
                if ($r -match 'state=finished') { $finished++ }
            }
        }
    }

    Write-Host "`nexplore: done. $($hits.Count) HIT, $errors ERROR, $finished clean-finished of $($configs.Count * $Seeds) solves"
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

    $smokeSave = Join-Path $env:APPDATA "Factorio/saves/smoke_rcon.zip"
    if (Test-Path $smokeSave) { Remove-Item $smokeSave -Force -ErrorAction SilentlyContinue }

    if (Test-Path $modListBak) {
        Move-Item -Force $modListBak $modListPath
    } elseif (-not $modListHadOriginal) {
        Remove-Item $modListPath -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
