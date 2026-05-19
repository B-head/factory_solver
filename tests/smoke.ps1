# In-game smoke test launcher.
#
# Boots Factorio with `--load-scenario factory_solver/smoke`, lets the mod's
# smoke driver build a trivial Solution and run the solver to completion, then
# greps the resulting log file for the verdict marker that manage/smoke.lua
# emits.
#
# Exit codes: 0 = SMOKE PASS, 1 = SMOKE FAIL (or no verdict found), 2 = setup
# error (Factorio not found, log file missing, etc).
#
# Usage:
#   pwsh tests/smoke.ps1                 # default 90s timeout
#   pwsh tests/smoke.ps1 -TimeoutSeconds 180

[CmdletBinding()]
param(
    [int] $TimeoutSeconds = 90
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

# Pull the Factorio binary path from .vscode/settings.json so this stays in
# lockstep with the debugger config (factoriomod-debug reads the same field).
$settingsPath = Join-Path $repoRoot ".vscode/settings.json"
if (-not (Test-Path $settingsPath)) {
    Write-Error "settings.json not found at $settingsPath"
    exit 2
}
# VS Code tolerates JSONC-style trailing commas; Windows PowerShell 5.1's
# ConvertFrom-Json does not. Strip them before parsing.
$settingsJson = (Get-Content $settingsPath -Raw) -replace ',(\s*[}\]])', '$1'
$settings = $settingsJson | ConvertFrom-Json
$factorio = $settings.'factorio.versions'[0].factorioPath
if (-not (Test-Path $factorio)) {
    Write-Error "Factorio binary not found at $factorio"
    exit 2
}

# launch.json convention: modsPath = workspace parent. Same here.
$modsDir = (Resolve-Path (Join-Path $repoRoot "..")).Path

# Factorio has no --logfile flag; it always writes to
# %APPDATA%\Factorio\factorio-current.log. --no-log-rotation keeps the run's
# output from being shoved into factorio-previous.log if the file already
# existed.
$logFile = Join-Path $env:APPDATA "Factorio/factorio-current.log"

Write-Host "smoke: factorio = $factorio"
Write-Host "smoke: mods     = $modsDir"
Write-Host "smoke: log      = $logFile"
Write-Host "smoke: timeout  = ${TimeoutSeconds}s"

$arguments = @(
    "--load-scenario", "factory_solver/smoke",
    "--mod-directory", $modsDir,
    "--no-log-rotation",
    "--disable-audio"
)

# Steam-built factorio.exe relaunches itself via Steam when not started by
# Steam, dropping any extra command-line args in the process. Setting
# SteamAppId in the child's environment makes the Steam SDK treat the process
# as already-launched-by-Steam and skip the relaunch. The factoriomod-debug
# extension uses the same approach (changelog 1.1.38).
$env:SteamAppId = "427520"

# Snapshot the log size BEFORE launching so we only scan entries this run
# produced. Stale SMOKE PASS / FAIL lines from yesterday must not be counted.
$preBytes = if (Test-Path $logFile) { (Get-Item $logFile).Length } else { 0 }

# Read everything appended to the log since the snapshot, robustly under
# concurrent writes from the still-running Factorio.
function Get-NewLogContent {
    if (-not (Test-Path $logFile)) { return "" }
    $stream = [System.IO.File]::Open($logFile, 'Open', 'Read', 'ReadWrite')
    try {
        $stream.Seek($preBytes, 'Begin') | Out-Null
        $reader = New-Object System.IO.StreamReader($stream)
        return $reader.ReadToEnd()
    } finally {
        $stream.Dispose()
    }
}

# A previous run (this launcher always kills Factorio at the end) tends to
# leave a stale .lock file behind. Remove it ONLY if no factorio process is
# actually running — never yank the lock from under a live instance.
$lockFile = Join-Path $env:APPDATA "Factorio/.lock"
if ((Test-Path $lockFile) -and -not (Get-Process -Name "factorio" -ErrorAction SilentlyContinue)) {
    Write-Host "smoke: clearing stale lock file"
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}

$proc = Start-Process -FilePath $factorio -ArgumentList $arguments -PassThru -NoNewWindow

# Poll: Factorio does not exit on game.set_game_state{game_finished=true} —
# it just returns to the main menu and keeps the window open. So we watch the
# log for the verdict marker and kill the process as soon as it appears.
$pollMs = 500
$elapsed = 0
$verdictLine = $null

while ($elapsed -lt ($TimeoutSeconds * 1000)) {
    Start-Sleep -Milliseconds $pollMs
    $elapsed += $pollMs

    $verdictLine = (Get-NewLogContent) -split "`n" |
        Where-Object { $_ -match 'SMOKE (PASS|FAIL):' } |
        Select-Object -First 1
    if ($verdictLine) { break }
    if ($proc.HasExited) { break }
}

if (-not $proc.HasExited) {
    $proc.Kill()
    Start-Sleep -Milliseconds 500
}

# One more read after the process is gone in case the verdict was written
# during the kill window.
if (-not $verdictLine) {
    $verdictLine = (Get-NewLogContent) -split "`n" |
        Where-Object { $_ -match 'SMOKE (PASS|FAIL):' } |
        Select-Object -First 1
}

if (-not $verdictLine) {
    Write-Host ""
    Write-Host "smoke: no SMOKE PASS/FAIL marker in this run's log entries."
    Write-Host "smoke: last 30 lines of new content:"
    (Get-NewLogContent) -split "`n" | Select-Object -Last 30 | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host ""
Write-Host $verdictLine.Trim()
if ($verdictLine -match 'SMOKE FAIL') {
    exit 1
}
exit 0
