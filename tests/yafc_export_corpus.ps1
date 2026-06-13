# FS -> YAFC export corpus generator.
#
# Boots a headless Factorio with a pyanodon mod set (the same default
# tests/explore_chains.ps1 uses), regenerates a small matrix of random recipe
# chains in-engine, and runs each through factory_solver's YAFC export codec
# (manage/yafc_codec.lua) via the factory_solver_explore.encode_yafc remote
# function. Each export's share string is written by the mod to
#   <run workspace>/write/script-output/yafc_exports/<name>.b64
# and this launcher collects them into one output directory.
#
# The point is NOT to solve anything -- it is to produce real, pyanodon-scale
# YAFC share strings so the headless YAFC import probe (S:\tmp\yafc_probe) can
# feed them to real YAFC's deserialiser and surface export-format bugs. Run the
# probe afterwards against this run's workspace mods dir (printed at the end) so
# YAFC loads the exact same mod set.
#
# The run workspace is always KEPT (the probe needs its mods dir + the b64
# files); delete it yourself when done, or pass -RunRoot to control where it
# lives.
#
# Usage:
#   pwsh tests/yafc_export_corpus.ps1
#   pwsh tests/yafc_export_corpus.ps1 -Seeds 30 -Hops 12
#   pwsh tests/yafc_export_corpus.ps1 -Mods base,flib,factory_solver,quality

[CmdletBinding()]
param(
    # First seed and how many consecutive seeds to generate per config.
    [int] $StartSeed = 1,
    [int] $Seeds = 12,
    # Base hop count; configs scale it (xN) like explore_chains.
    [int] $Hops = 8,
    # Seconds to wait for RCON after launch. pyanodon's data stage is slow.
    [int] $RconStartupSeconds = 600,
    # Mod set; empty = base + flib + factory_solver + every py*.zip on disk.
    [string[]] $Mods = @(),
    # Where the collected *.b64 exports are written (default: a sibling of the
    # run workspace). Created if missing.
    [string] $OutDir = "",
    # Optional: a directory of external YAFC share strings (*.b64 / *.txt). Each
    # is imported and RE-exported (YAFC -> FS -> YAFC) via reexport_yafc, so the
    # probe can check a real factory survives the round-trip. Pass -Seeds 0 to do
    # ONLY the re-exports (skip random-chain corpus generation).
    [string] $ReexportDir = "",
    # Optional: a file holding a factory_solver NATIVE share string. Every solution
    # in it is imported and exported to YAFC (FS native -> YAFC), driving the export
    # over real hand-built factories. The -Mods set must match the string's content.
    [string] $FsNativeFile = "",
    # Run-workspace root; empty = $env:FS_RUN_ROOT, else $env:TEMP\fs_runs.
    [string] $RunRoot = "",
    [int] $RconPort = 0,
    [string] $RconPassword = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
. "$PSScriptRoot/rcon_lib.ps1"

if ($RconPort -eq 0) { $RconPort = Get-FreeTcpPort }
if (-not $RconPassword) { $RconPassword = [guid]::NewGuid().ToString('N') }
$runRoot = Resolve-RunRoot -RunRoot $RunRoot

$ws = $null
try {
    Invoke-RunRootGc -RunRoot $runRoot
    $cfg = Resolve-FactorioConfig -RepoRoot $repoRoot.Path
    $modsDir = $cfg.ModsDir

    # Default mod set: base + flib + factory_solver + every pyanodon mod on disk
    # (graphics packs included; they are dependencies). PyBlock is a separate game
    # mode, excluded. Mirrors tests/explore_chains.ps1.
    if (-not $Mods -or $Mods.Count -eq 0) {
        $pyMods = @(Get-ChildItem $modsDir -Filter 'py*.zip' -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.BaseName -match '^(.+)_\d+\.\d+\.\d+$') { $Matches[1] }
            } | Where-Object { $_ -and $_ -ne 'PyBlock' } | Sort-Object -Unique)
        $Mods = @('base', 'flib', 'factory_solver') + $pyMods
    }
    else {
        $Mods = @($Mods | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    $ws = New-RunWorkspace -Tag "yafcexp" -ServerName "factory_solver_yafc_export" -RunRoot $runRoot
    Initialize-ScratchMods -Workspace $ws -SourceModsDir $modsDir -RepoRoot $repoRoot.Path -Mods $Mods
}
catch {
    Write-Error $_.Exception.Message
    if ($ws) { Remove-RunWorkspace -Workspace $ws }
    exit 2
}
$factorio = $cfg.Factorio
# Factorio data/ dir for the probe hint: <install>/bin/x64/factorio.exe -> <install>/data
$dataDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $factorio))) "data"

if (-not $OutDir) { $OutDir = Join-Path $ws.Dir "yafc_exports_collected" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# A small but varied config matrix: a downstream+upstream chain and two loop
# (cycle) chains at two depths. All real-recipe, no quality (qual=off) so the
# exports are plain pyanodon production lines.
$configs = @(
    @{ mode = 'both'; void = 'in'; nosrc = 'in'; pins = 1; qual = 'off'; hops = $Hops },
    @{ mode = 'cycle'; void = 'in'; nosrc = 'in'; pins = 1; qual = 'off'; hops = ($Hops * 2) },
    @{ mode = 'cycle'; void = 'ex'; nosrc = 'ex'; pins = 1; qual = 'off'; hops = ($Hops * 2) }
)

Write-Host "yafc_export: factorio = $factorio"
Write-Host "yafc_export: mods     = $modsDir (linked into the run workspace)"
Write-Host "yafc_export: run dir  = $($ws.Dir)"
Write-Host "yafc_export: out dir  = $OutDir"
Write-Host "yafc_export: rcon     = 127.0.0.1:$RconPort"
Write-Host "yafc_export: seeds    = $StartSeed .. $($StartSeed + $Seeds - 1)  (x$($configs.Count) configs)"
Write-Host "yafc_export: mod set  = $($Mods -join ', ')"

$arguments = New-FactorioArgumentList -Workspace $ws -Scenario "factory_solver/smoke_rcon" `
    -RconPort $RconPort -RconPassword $RconPassword
$env:SteamAppId = "427520"
$proc = Start-Process -FilePath $factorio -ArgumentList $arguments -PassThru -NoNewWindow

$client = $null
$stream = $null
$exitCode = 1
$exported = 0
$skipped = 0
$errors = 0
$warnTally = @{}

try {
    $rcon = Connect-Rcon -Port $RconPort -Password $RconPassword -TimeoutSeconds $RconStartupSeconds -Proc $proc
    $client = $rcon.Client
    $stream = $rcon.Stream
    Write-Host "yafc_export: RCON authenticated"

    $iface = "factory_solver_explore"
    if ($Seeds -le 0) { $configs = @() }   # -Seeds 0: re-export only, no corpus
    foreach ($conf in $configs) {
        $ini = if ($conf.init) { $conf.init } else { 'recipe' }
        $tgt = if ($conf.target) { $conf.target } else { 'recipe' }
        $cls = if ($conf.closure) { $conf.closure } else { 'on' }
        $co = if ($conf.cycleonly) { $conf.cycleonly } else { 'off' }
        Write-Host "`nconfig mode=$($conf.mode) void=$($conf.void) nosrc=$($conf.nosrc) qual=$($conf.qual) hops=$($conf.hops)" -ForegroundColor Cyan

        for ($s = $StartSeed; $s -lt ($StartSeed + $Seeds); $s++) {
            $a = "seed=$s;hops=$($conf.hops);mode=$($conf.mode);init=$ini;void=$($conf.void);nosrc=$($conf.nosrc);pins=$($conf.pins);qual=$($conf.qual);target=$tgt;closure=$cls;cycleonly=$co"
            $cmd = "/silent-command rcon.print(remote.call('$iface','encode_yafc','$a'))"
            $r = Invoke-RconCommand -Stream $stream -Command $cmd

            $obj = $null
            try { $obj = $r | ConvertFrom-Json } catch {}
            if (-not $obj) {
                Write-Host "  seed=$s ERROR non-JSON: $r" -ForegroundColor Red
                $errors++
                continue
            }
            if (-not $obj.ok) {
                $msg = "$($obj.message)"
                if ($msg -match 'built 0|empty chain|SKIP') {
                    $skipped++
                    Write-Host "  seed=$s SKIP $msg" -ForegroundColor DarkYellow
                }
                else {
                    $errors++
                    Write-Host "  seed=$s ERROR $msg" -ForegroundColor Red
                }
                continue
            }

            # helpers.table_to_json renders an empty Lua array as "{}" (an object),
            # which ConvertFrom-Json turns into a PSCustomObject, not an array; only
            # a non-empty warnings list comes back as an array of strings.
            $wkeys = if ($obj.warnings -is [System.Array]) { @($obj.warnings | Where-Object { $_ }) } else { @() }
            foreach ($w in $wkeys) {
                if ($warnTally.ContainsKey($w)) { $warnTally[$w]++ } else { $warnTally[$w] = 1 }
            }
            $exported++
            $wtxt = if ($wkeys.Count) { "  warn=[$($wkeys -join ',')]" } else { "" }
            Write-Host "  seed=$s OK lines=$($obj.lines) -> $($obj.name).b64$wtxt"
        }
    }

    # Optional re-export phase: import each external YAFC string and re-export it.
    if ($ReexportDir -and (Test-Path $ReexportDir)) {
        Write-Host "`nre-export (YAFC -> FS -> YAFC) from $ReexportDir" -ForegroundColor Cyan
        $inFiles = @(Get-ChildItem $ReexportDir -Include *.b64, *.txt -File -ErrorAction SilentlyContinue)
        if ($inFiles.Count -eq 0) { $inFiles = @(Get-ChildItem $ReexportDir -File -ErrorAction SilentlyContinue) }
        foreach ($f in $inFiles) {
            $b64in = (Get-Content $f.FullName -Raw).Trim()
            $stem = "reexport_" + $f.BaseName
            $cmd = "/silent-command rcon.print(remote.call('$iface','reexport_yafc','$b64in','$stem'))"
            $r = Invoke-RconCommand -Stream $stream -Command $cmd
            $obj = $null
            try { $obj = $r | ConvertFrom-Json } catch {}
            if (-not $obj) { Write-Host "  $($f.Name) ERROR non-JSON: $r" -ForegroundColor Red; $errors++; continue }
            if (-not $obj.ok) { Write-Host "  $($f.Name) ERROR $($obj.message)" -ForegroundColor Red; $errors++; continue }
            $wkeys = if ($obj.warnings -is [System.Array]) { @($obj.warnings | Where-Object { $_ }) } else { @() }
            foreach ($w in $wkeys) { if ($warnTally.ContainsKey($w)) { $warnTally[$w]++ } else { $warnTally[$w] = 1 } }
            $exported++
            $wtxt = if ($wkeys.Count) { "  warn=[$($wkeys -join ',')]" } else { "" }
            Write-Host "  $($f.Name) OK in_rows=$($obj.in_rows) out_rows=$($obj.out_rows) -> $($obj.name).b64$wtxt"
        }
    }

    # Optional FS-native -> YAFC phase: export every solution in a native string.
    if ($FsNativeFile -and (Test-Path $FsNativeFile)) {
        Write-Host "`nFS native -> YAFC from $FsNativeFile" -ForegroundColor Cyan
        $fsb64 = (Get-Content $FsNativeFile -Raw).Trim()
        $cmd = "/silent-command rcon.print(remote.call('$iface','encode_fs_to_yafc','$fsb64'))"
        $r = Invoke-RconCommand -Stream $stream -Command $cmd
        $obj = $null
        try { $obj = $r | ConvertFrom-Json } catch {}
        if (-not $obj) { Write-Host "  ERROR non-JSON: $r" -ForegroundColor Red; $errors++ }
        elseif (-not $obj.ok) { Write-Host "  ERROR $($obj.message)" -ForegroundColor Red; $errors++ }
        else {
            Write-Host "  decoded $($obj.count) solution(s)"
            foreach ($res in $obj.results) {
                if ($res.error) {
                    Write-Host "    [ERR ] $($res.name): $($res.error)" -ForegroundColor Red
                    $errors++
                }
                else {
                    $wkeys = if ($res.warnings -is [System.Array]) { @($res.warnings | Where-Object { $_ }) } else { @() }
                    foreach ($w in $wkeys) { if ($warnTally.ContainsKey($w)) { $warnTally[$w]++ } else { $warnTally[$w] = 1 } }
                    $exported++
                    $wtxt = if ($wkeys.Count) { "  warn=[$($wkeys -join ',')]" } else { "" }
                    Write-Host "    [ OK ] $($res.name) rows=$($res.rows) -> $($res.file)$wtxt"
                }
            }
        }
    }

    # Collect the b64 files the mod wrote into the run workspace's script-output.
    $srcDir = Join-Path $ws.ScriptOutputDir "yafc_exports"
    if (Test-Path $srcDir) {
        Copy-Item -Path (Join-Path $srcDir "*.b64") -Destination $OutDir -Force -ErrorAction SilentlyContinue
    }
    $collected = @(Get-ChildItem $OutDir -Filter '*.b64' -ErrorAction SilentlyContinue).Count
    $exitCode = 0

    Write-Host "`nyafc_export: $exported exported, $skipped skipped, $errors error(s); $collected .b64 files collected"
    if ($warnTally.Count) {
        Write-Host "yafc_export: export warnings (key=count):"
        foreach ($k in ($warnTally.Keys | Sort-Object)) { Write-Host "  $k = $($warnTally[$k])" }
    }
}
catch {
    Write-Error $_.Exception.Message
    $exitCode = 2
}
finally {
    if ($stream) { $stream.Dispose() }
    if ($client) { $client.Dispose() }
    if ($proc -and -not $proc.HasExited) {
        try { $proc.Kill() } catch {}
    }
}

Write-Host "`n--- next step: validate with the headless YAFC probe ---"
Write-Host "  & S:\tmp\yafc_probe\bin\Release\net10.0\YafcImportProbe.exe ``"
Write-Host "      `"$dataDir`" ``  # Factorio data/ dir"
Write-Host "      `"$($ws.ModsDir)`" ``  # this run's mod set (matches the export)"
Write-Host "      `"$OutDir`""
Write-Host "yafc_export: run workspace kept at $($ws.Dir)"

exit $exitCode
