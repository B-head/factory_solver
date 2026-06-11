# Interactive RCON console for a modded Factorio.
#
# A developer convenience -- NOT a test. It boots a headless Factorio server (or
# attaches to a running one) and lets you issue console commands over RCON,
# either interactively (a REPL) or one-shot (-Command). Handy for probing
# prototype names, inspecting `storage`, trying `remote.call`s, and reading the
# log, without writing a fixture. It reuses the smoke harness's plumbing:
# factorioPath from .vscode/settings.json, modsPath from .vscode/launch.json
# (with the worktree fallback), the per-run run workspace (scratch mods dir +
# isolated write-data; the shared mod-list.json and %APPDATA%\Factorio are
# never touched), and the Source RCON client. The boot banner prints the RCON
# port and password, so a second terminal can attach with -Connect.
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
    # Mods to enable for the run; everything else is explicitly disabled in the
    # workspace's generated mod-list.json. @() mirrors the dev config (every
    # shared mod linked, shared mod-list.json copied verbatim).
    [string[]] $Mods = @("base", "flib", "factory_solver"),
    # host:port of an already-running RCON server to attach to instead of
    # booting. Pass the booting terminal's banner password via -RconPassword.
    [string] $Connect = "",
    # 0 = pick a free port (the banner prints the actual one for -Connect).
    [int] $RconPort = 0,
    # Empty = a per-run random password when booting; required with -Connect.
    [string] $RconPassword = "",
    [int] $RconStartupSeconds = 120,
    # Print everything appended to the log since boot, then exit (one-shot aid).
    [switch] $ShowLog,
    # Where run workspaces live; empty = $env:FS_RUN_ROOT, else $env:TEMP\fs_runs.
    [string] $RunRoot = "",
    # Keep the run workspace (mods junction, write-data, logs) after the session.
    [switch] $KeepRun
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

# Shared RCON transport / config resolution / run-workspace machinery (also
# used by tests/smoke_rcon.ps1 and tests/explore_chains.ps1).
. "$PSScriptRoot/rcon_lib.ps1"

# -Mods comma/space normalization (see smoke_rcon.ps1 for why -File mangles it).
$Mods = @($Mods | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# Set when booting (the run workspace's per-run log); stays $null when
# attaching, where the server's log lives wherever that server runs.
$logFile = $null
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

# Prints via Write-Host: Invoke-Line's caller consumes the function's success
# stream (`if ((Invoke-Line $line) -eq "QUIT")`), so pipeline output from here
# would be swallowed by that comparison instead of reaching the console.
function Show-Log {
    param([string] $Arg, [long] $PreBytes)
    if (-not $logFile) { Write-Host "(no log available when attached with -Connect)"; return }
    if (-not (Test-Path $logFile)) { Write-Host "(no log file at $logFile)"; return }
    if ($Arg -eq "all") {
        Get-Content $logFile | ForEach-Object { Write-Host $_ }
    } elseif ($Arg -match '^\d+$') {
        Get-Content $logFile -Tail ([int]$Arg) | ForEach-Object { Write-Host $_ }
    } else {
        # Appended since boot.
        $stream = [System.IO.File]::Open($logFile, 'Open', 'Read', 'ReadWrite')
        try {
            $stream.Seek($PreBytes, 'Begin') | Out-Null
            Write-Host (New-Object System.IO.StreamReader($stream)).ReadToEnd()
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
# Resolve Factorio + build the run workspace (only needed when booting).
# ---------------------------------------------------------------------------
$proc = $null
$client = $null
$stream = $null
$ws = $null
$preBytes = 0   # the per-run log starts empty; ":log" with no arg shows it all
$exitCode = 0

try {
    if ($booting) {
        if ($RconPort -eq 0) { $RconPort = Get-FreeTcpPort }
        if (-not $RconPassword) { $RconPassword = [guid]::NewGuid().ToString('N') }
        $runRoot = Resolve-RunRoot -RunRoot $RunRoot
        Invoke-RunRootGc -RunRoot $runRoot

        $cfg = Resolve-FactorioConfig -RepoRoot $repoRoot.Path
        $ws = New-RunWorkspace -Tag "console" -ServerName "factory_solver_console" -RunRoot $runRoot
        Initialize-ScratchMods -Workspace $ws -SourceModsDir $cfg.ModsDir -RepoRoot $repoRoot.Path -Mods $Mods
        $logFile = $ws.LogFile

        Write-Host "console: booting $Scenario  (mods: $(if ($Mods.Count) { $Mods -join ', ' } else { 'dev config mirrored' }))"
        Write-Host "console: run dir = $($ws.Dir)"
        Write-Host "console: rcon    = 127.0.0.1:$RconPort  (password $RconPassword)"

        $arguments = New-FactorioArgumentList -Workspace $ws -Scenario $Scenario `
            -RconPort $RconPort -RconPassword $RconPassword
        $env:SteamAppId = "427520"
        $proc = Start-Process -FilePath $cfg.Factorio -ArgumentList $arguments -PassThru -NoNewWindow

        $connectHost = "127.0.0.1"
        $connectPort = $RconPort
    } else {
        $parts = $Connect -split ':', 2
        $connectHost = $parts[0]
        $connectPort = [int]$parts[1]
        Write-Host "console: attaching to $connectHost`:$connectPort"
    }

    # --- Connect + authenticate -------------------------------------------
    $rcon = Connect-Rcon -ConnectHost $connectHost -Port $connectPort -Password $RconPassword `
        -TimeoutSeconds $RconStartupSeconds -Proc $proc
    $client = $rcon.Client
    $stream = $rcon.Stream
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
    }
    # The autosave, log and .lock all live in the run workspace; remove it
    # wholesale (kept on -KeepRun or a setup failure).
    Remove-RunWorkspace -Workspace $ws -Keep:($KeepRun -or $exitCode -ne 0)
}

exit $exitCode
