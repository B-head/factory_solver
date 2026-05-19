# In-game smoke test launcher for the "missing prototype fallback" scenario.
#
# Boots Factorio with `--load-scenario factory_solver/smoke_missing_prototype`,
# lets the mod's driver build a Solution whose production_line points at
# machine / recipe / fuel names that no loaded mod provides, then greps the
# resulting log file for the verdict marker that manage/smoke_missing_prototype.lua
# emits.
#
# Reproduces the 0.3.13 crash report
# (https://mods.factorio.com/mod/factory_solver/discussion/67b60b2dfe381692daeeb08d):
# selecting a Solution that depended on a machine no longer present in any
# loaded mod would trap with `attempt to index local 'machine' (a nil value)`.
#
# Exit codes: 0 = SMOKE PASS, 1 = SMOKE FAIL (or no verdict found), 2 = setup
# error (Factorio not found, log file missing, etc).
#
# Usage:
#   pwsh tests/smoke_missing_prototype.ps1                 # default 90s timeout
#   pwsh tests/smoke_missing_prototype.ps1 -TimeoutSeconds 180

[CmdletBinding()]
param(
    [int] $TimeoutSeconds = 90
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

$settingsPath = Join-Path $repoRoot ".vscode/settings.json"
if (-not (Test-Path $settingsPath)) {
    Write-Error "settings.json not found at $settingsPath"
    exit 2
}
$settingsJson = (Get-Content $settingsPath -Raw) -replace ',(\s*[}\]])', '$1'
$settings = $settingsJson | ConvertFrom-Json
$factorio = $settings.'factorio.versions'[0].factorioPath
if (-not (Test-Path $factorio)) {
    Write-Error "Factorio binary not found at $factorio"
    exit 2
}

$modsDir = (Resolve-Path (Join-Path $repoRoot "..")).Path
$logFile = Join-Path $env:APPDATA "Factorio/factorio-current.log"

Write-Host "smoke_missing_prototype: factorio = $factorio"
Write-Host "smoke_missing_prototype: mods     = $modsDir"
Write-Host "smoke_missing_prototype: log      = $logFile"
Write-Host "smoke_missing_prototype: timeout  = ${TimeoutSeconds}s"

$arguments = @(
    "--load-scenario", "factory_solver/smoke_missing_prototype",
    "--mod-directory", $modsDir,
    "--no-log-rotation",
    "--disable-audio"
)

$env:SteamAppId = "427520"

$preBytes = if (Test-Path $logFile) { (Get-Item $logFile).Length } else { 0 }

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

$lockFile = Join-Path $env:APPDATA "Factorio/.lock"
if ((Test-Path $lockFile) -and -not (Get-Process -Name "factorio" -ErrorAction SilentlyContinue)) {
    Write-Host "smoke_missing_prototype: clearing stale lock file"
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}

$proc = Start-Process -FilePath $factorio -ArgumentList $arguments -PassThru -NoNewWindow

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

if (-not $verdictLine) {
    $verdictLine = (Get-NewLogContent) -split "`n" |
        Where-Object { $_ -match 'SMOKE (PASS|FAIL):' } |
        Select-Object -First 1
}

if (-not $verdictLine) {
    Write-Host ""
    Write-Host "smoke_missing_prototype: no SMOKE PASS/FAIL marker in this run's log entries."
    Write-Host "smoke_missing_prototype: last 30 lines of new content:"
    (Get-NewLogContent) -split "`n" | Select-Object -Last 30 | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host ""
Write-Host $verdictLine.Trim()
if ($verdictLine -match 'SMOKE FAIL') {
    exit 1
}
exit 0
