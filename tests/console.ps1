# Interactive RCON console for a modded Factorio.
#
# A developer convenience -- NOT a test. It boots a headless Factorio server (or
# attaches to a running one) and lets you issue console commands over RCON,
# either interactively (a REPL) or one-shot (-Command). Handy for probing
# prototype names, inspecting `storage`, trying `remote.call`s, and reading the
# log, without writing a fixture. It reuses the smoke harness's plumbing:
# factorioPath from .vscode/settings.json, modsPath from .vscode/launch.json,
# the -Mods / mod-list.json backup-restore, and the Source RCON client.
#
# Input conventions (per line, in both modes):
#   /cmd...      send a raw console command verbatim (e.g. /c game.print("hi"))
#   =<expr>      evaluate a Lua expression and pretty-print it via serpent
#                (e.g. =game.tick, =prototypes.recipe["iron-plate"].category)
#   <lua>        run a Lua statement as /silent-command (no automatic output)
#   :log [all|N] dump the log: appended-since-boot (default), the whole file
#                (all), or the last N lines
#   :help        show the conventions
#   :quit        exit (also Ctrl-C / EOF)
#
# Usage:
#   pwsh tests/console.ps1                                  # interactive REPL
#   pwsh tests/console.ps1 -Run '=game.tick'               # one-shot
#   pwsh tests/console.ps1 -Run '=prototypes.recipe["casting-iron"]' -Mods base,flib,factory_solver,space-age,quality,elevated-rails
#   pwsh tests/console.ps1 -Scenario base/freeplay         # real map instead of the empty smoke scenario
#   pwsh tests/console.ps1 -Connect 127.0.0.1:27015 -RconPassword secret   # attach, don't boot
#
# Note: the one-shot parameter is -Run, not -Command -- the latter collides with
# powershell.exe's own -Command switch when launched via `powershell -File`.

[CmdletBinding()]
param(
    # One or more commands to run, then exit. Omit for an interactive REPL.
    [string[]] $Run,
    # Scenario to load when booting (ignored with -Connect). The empty smoke
    # scenario is fastest and exposes the factory_solver_smoke interface; use
    # base/freeplay for a real map with surfaces and entities.
    [string] $Scenario = "factory_solver/smoke_rcon",
    # Mods to enable for the run; everything else in mod-list.json is disabled.
    # @() leaves mod-list.json untouched (loads the dev config as-is).
    [string[]] $Mods = @("base", "flib", "factory_solver"),
    # host:port of an already-running RCON server to attach to instead of booting.
    [string] $Connect = "",
    [int] $RconPort = 27116,
    [string] $RconPassword = "console",
    [int] $RconStartupSeconds = 120,
    # Print everything appended to the log since boot, then exit (one-shot aid).
    [switch] $ShowLog
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

# Shared RCON transport / config resolution / mod-list control (also used by
# tests/smoke_rcon.ps1 and tests/explore_chains.ps1).
. "$PSScriptRoot/rcon_lib.ps1"

# -Mods comma/space normalization (see smoke_rcon.ps1 for why -File mangles it).
$Mods = @($Mods | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$logFile = Join-Path $env:APPDATA "Factorio/factorio-current.log"
$booting = [string]::IsNullOrWhiteSpace($Connect)

# RCON transport (Read-Exact / Send / Receive / Invoke-RconCommandDrain) comes
# from rcon_lib.ps1, dot-sourced above. The console uses the multi-packet drain
# variant so large pretty-printed tables come back whole.

# ---------------------------------------------------------------------------
# Translate a REPL line into a console command. Returns $null for a handled
# meta-command (already actioned by the caller via the switch below).
# ---------------------------------------------------------------------------
function ConvertTo-ConsoleCommand {
    param([string] $Line)
    if ($Line.StartsWith("/")) { return $Line }
    if ($Line.StartsWith("=")) {
        $expr = $Line.Substring(1)
        # serpent is exposed in the Factorio Lua runtime; block-pretty-print so
        # tables are readable. Wrap the expr in parens so `=a, b` etc. still parse.
        return "/silent-command rcon.print(serpent.block(({ $expr })[1], {comment=false}))"
    }
    return "/silent-command $Line"
}

function Show-Log {
    param([string] $Arg, [long] $PreBytes)
    if (-not (Test-Path $logFile)) { Write-Host "(no log file at $logFile)"; return }
    if ($Arg -eq "all") {
        Get-Content $logFile
    } elseif ($Arg -match '^\d+$') {
        Get-Content $logFile -Tail ([int]$Arg)
    } else {
        # Appended since boot.
        $stream = [System.IO.File]::Open($logFile, 'Open', 'Read', 'ReadWrite')
        try {
            $stream.Seek($PreBytes, 'Begin') | Out-Null
            (New-Object System.IO.StreamReader($stream)).ReadToEnd()
        } finally { $stream.Dispose() }
    }
}

$helpText = @"
  /cmd...      raw console command (e.g. /c game.print("hi"))
  =<expr>      evaluate + pretty-print a Lua expression (e.g. =game.tick)
  <lua>        run a Lua statement (/silent-command; no auto output)
  :log [all|N] log: since-boot (default), whole file (all), or last N lines
  :help        this help
  :quit        exit
"@

# ---------------------------------------------------------------------------
# Resolve Factorio + mods (only needed when booting).
# ---------------------------------------------------------------------------
$proc = $null
$client = $null
$stream = $null
$modList = $null
$preBytes = if (Test-Path $logFile) { (Get-Item $logFile).Length } else { 0 }
$exitCode = 0

try {
    if ($booting) {
        $cfg = Resolve-FactorioConfig -RepoRoot $repoRoot.Path
        $factorio = $cfg.Factorio
        $modsDir = $cfg.ModsDir

        $serverSettings = Join-Path $env:TEMP "factory_solver_console_server_settings.json"
        @'
{
    "name": "factory_solver_console",
    "description": "factory_solver dev console",
    "visibility": { "public": false, "lan": false },
    "require_user_verification": false,
    "max_players": 1,
    "allow_commands": "true"
}
'@ | Set-Content -Path $serverSettings -Encoding utf8

        Write-Host "console: booting $Scenario  (mods: $(if ($Mods.Count) { $Mods -join ', ' } else { 'dev config unchanged' }))"

        # Mod set control (shared; -Mods @() leaves the dev config untouched).
        $modList = Set-ReproducibleModList -ModsDir $modsDir -Mods $Mods -BackupSuffix "console-bak"

        $arguments = @(
            "--start-server-load-scenario", $Scenario,
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
            Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
        }
        $proc = Start-Process -FilePath $factorio -ArgumentList $arguments -PassThru -NoNewWindow

        $connectHost = "127.0.0.1"
        $connectPort = $RconPort
    } else {
        $parts = $Connect -split ':', 2
        $connectHost = $parts[0]
        $connectPort = [int]$parts[1]
        Write-Host "console: attaching to $connectHost`:$connectPort"
    }

    # --- Connect + authenticate -------------------------------------------
    $connectDeadline = (Get-Date).AddSeconds($RconStartupSeconds)
    while ($true) {
        if ($proc -and $proc.HasExited) { throw "Factorio exited before RCON came up (code $($proc.ExitCode))" }
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect($connectHost, $connectPort)
            $stream = $client.GetStream()
            break
        } catch {
            if ($client) { $client.Dispose(); $client = $null }
            if ((Get-Date) -gt $connectDeadline) { throw "RCON $connectHost`:$connectPort never opened within ${RconStartupSeconds}s" }
            Start-Sleep -Milliseconds 500
        }
    }
    Send-RconPacket -Stream $stream -Id 1 -Type 3 -Body $RconPassword
    $auth = Receive-RconPacket -Stream $stream
    if ($auth.Type -eq 0) { $auth = Receive-RconPacket -Stream $stream }
    if ($auth.Id -eq -1) { throw "RCON auth failed (wrong password?)" }
    Write-Host "console: connected. Type :help for conventions, :quit to exit."

    # --- Run one line (shared by REPL and -Command) -----------------------
    function Invoke-Line {
        param([string] $Line)
        $Line = $Line.Trim()
        if ($Line -eq "") { return }
        if ($Line -eq ":quit" -or $Line -eq ":q") { return "QUIT" }
        if ($Line -eq ":help" -or $Line -eq ":h") { Write-Host $helpText; return }
        if ($Line -match '^:log\s*(.*)$') { Show-Log -Arg $Matches[1].Trim() -PreBytes $preBytes; return }
        $resp = Invoke-RconCommandDrain -Stream $stream -CommandText (ConvertTo-ConsoleCommand $Line)
        if ($resp -ne "") { Write-Host $resp }
    }

    if ($Run) {
        foreach ($line in $Run) {
            Write-Host "> $line"
            if ((Invoke-Line $line) -eq "QUIT") { break }
        }
    } else {
        while ($true) {
            $line = Read-Host "factorio"
            if ($null -eq $line) { break }                 # EOF
            if ((Invoke-Line $line) -eq "QUIT") { break }
        }
    }

    if ($ShowLog) {
        Write-Host "`n--- factorio-current.log (since boot) ---"
        Show-Log -Arg "" -PreBytes $preBytes
    }
}
catch {
    Write-Host "console: $($_.Exception.Message)"
    $exitCode = 2
}
finally {
    if ($stream -and $booting) { try { Send-RconPacket -Stream $stream -Id 3 -Type 2 -Body "/quit" } catch {} }
    if ($client) { $client.Dispose() }
    if ($proc) {
        Start-Sleep -Milliseconds 500
        if (-not $proc.HasExited) { $proc.Kill(); Start-Sleep -Milliseconds 500 }
        $smokeSave = Join-Path $env:APPDATA "Factorio/saves/$(($Scenario -split '/')[-1]).zip"
        if (Test-Path $smokeSave) { Remove-Item $smokeSave -Force -ErrorAction SilentlyContinue }
    }
    Restore-ModList -State $modList
}

exit $exitCode
