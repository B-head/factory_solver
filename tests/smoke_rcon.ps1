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
# Exit codes: 0 = all fixtures PASS, 1 = a fixture FAILed (or no response),
# 2 = setup error (Factorio not found, RCON never came up, etc).
#
# Usage:
#   pwsh tests/smoke_rcon.ps1
#   pwsh tests/smoke_rcon.ps1 -TimeoutSeconds 45 -Fixtures iron_plate,missing_prototype

[CmdletBinding()]
param(
    # Per-fixture deadline for the solver to reach a terminal state.
    [int] $TimeoutSeconds = 45,
    # Seconds to wait for the server to open its RCON port after launch.
    [int] $RconStartupSeconds = 90,
    [string[]] $Fixtures = @("iron_plate", "missing_prototype"),
    [int] $RconPort = 27115,
    [string] $RconPassword = "smoke"
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

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

$modsDir = (Resolve-Path (Join-Path $repoRoot "..")).Path
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
    foreach ($fixture in $Fixtures) {
        $setup = Invoke-RconCommand -Stream $stream `
            -Command "/silent-command rcon.print(remote.call('$iface','setup','$fixture'))"
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
                default { }   # "ready" or a numeric iteration count: keep polling
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
}

exit $exitCode
