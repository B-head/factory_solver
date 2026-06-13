# Shared plumbing for the RCON-driven test/dev launchers (tests/smoke_rcon.ps1,
# tests/explore_chains.ps1, tests/console.ps1). Dot-source it AFTER the param()
# block: `. "$PSScriptRoot/rcon_lib.ps1"`.
#
# This module is pure function definitions -- no param(), no top-level side
# effects, no $ErrorActionPreference change -- so dot-sourcing only injects the
# functions into the caller's scope. Paths are passed in (it never reads
# $PSScriptRoot, which under dot-source resolves to the CALLER's directory).
#
# Four previously-duplicated concerns live here:
#   * the Source RCON wire protocol (Read-Exact / Send / Receive / Invoke),
#   * resolving Factorio + the mods dir from the .vscode/* configs (with a
#     fallback to the main checkout's .vscode when run from a git worktree),
#   * the per-run "run workspace": a scratch mods dir (junction + hardlinks)
#     plus an isolated Factorio write-data, so launchers never touch the shared
#     mods dir or the user's %APPDATA%\Factorio and can run concurrently, and
#   * the RCON connect + authenticate loop.
# Launcher-specific machinery (the explorer worker pool, the console REPL
# helpers, fixture orchestration) deliberately stays in each launcher.

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
    return , $buf
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
# (For those, use Invoke-RconCommandDrain.)
function Invoke-RconCommand {
    param([System.IO.Stream] $Stream, [string] $Command)
    Send-RconPacket -Stream $Stream -Id 2 -Type 2 -Body $Command
    $resp = Receive-RconPacket -Stream $Stream
    return $resp.Body.Trim()
}

# Send one command and return its full response across multiple packets. Factorio
# fragments responses over ~4 KB, so after the first packet (allowed up to 1.5 s
# for the server to compute) we keep reading until the stream goes idle. Used by
# the interactive console where pretty-printed tables come back large.
function Invoke-RconCommandDrain {
    param([System.IO.Stream] $Stream, [string] $CommandText)
    Send-RconPacket -Stream $Stream -Id 2 -Type 2 -Body $CommandText
    $sb = New-Object System.Text.StringBuilder
    $Stream.ReadTimeout = 1500
    try {
        $first = Receive-RconPacket -Stream $Stream
        [void]$sb.Append($first.Body)
    } catch [System.IO.IOException] {
        return ""   # no response (e.g. a statement that printed nothing)
    }
    $Stream.ReadTimeout = 200
    while ($true) {
        try { [void]$sb.Append((Receive-RconPacket -Stream $Stream).Body) }
        catch [System.IO.IOException] { break }   # idle => response complete
    }
    return $sb.ToString().TrimEnd()
}

# ---------------------------------------------------------------------------
# Config resolution
#
# Factorio binary from .vscode/settings.json; mods dir from .vscode/launch.json's
# modsPath (the same value factoriomod-debug uses, so launchers stay in lockstep
# with the debugger config instead of hardcoding "repo parent"). Both files are
# JSONC: strip // line comments (launch.json) and trailing commas (both) before
# Windows PowerShell 5.1's ConvertFrom-Json, which rejects them. Throws with a
# descriptive message on any missing file/field; the caller decides how to exit.
#
# .vscode/ is gitignored, so a git worktree checkout has none. Launchers run
# from a worktree fall back to the MAIN checkout's .vscode (worktrees share the
# .git directory, so it is discoverable via `git rev-parse --git-common-dir`).
# ---------------------------------------------------------------------------

# The root of the main (primary) checkout this worktree belongs to. From the
# main checkout itself, returns $RepoRoot. Falls back to $RepoRoot when git is
# unavailable or the directory is not a repository.
function Resolve-MainCheckoutRoot {
    param([string] $RepoRoot)
    try {
        $common = & git -C $RepoRoot rev-parse --git-common-dir
        if ($LASTEXITCODE -ne 0 -or -not $common) { return $RepoRoot }
    } catch { return $RepoRoot }
    # Main checkout returns the relative ".git"; a worktree returns an absolute
    # path to the shared .git directory.
    if (-not [System.IO.Path]::IsPathRooted($common)) { $common = Join-Path $RepoRoot $common }
    try {
        return (Split-Path -Parent (Resolve-Path $common).ProviderPath)
    } catch { return $RepoRoot }
}

function Resolve-FactorioConfig {
    param([string] $RepoRoot)

    # Prefer the checkout's own .vscode (lets a worktree carry a local override);
    # fall back to the main checkout's, which every worktree shares.
    $configRoot = $null
    foreach ($candidate in @($RepoRoot, (Resolve-MainCheckoutRoot -RepoRoot $RepoRoot))) {
        if (Test-Path (Join-Path $candidate ".vscode/settings.json")) { $configRoot = $candidate; break }
    }
    if (-not $configRoot) {
        throw "settings.json not found at $RepoRoot\.vscode (nor in the main checkout's .vscode)"
    }

    $settingsPath = Join-Path $configRoot ".vscode/settings.json"
    $settingsJson = (Get-Content $settingsPath -Raw) -replace ',(\s*[}\]])', '$1'
    $factorio = ($settingsJson | ConvertFrom-Json).'factorio.versions'[0].factorioPath
    if (-not (Test-Path $factorio)) { throw "Factorio binary not found at $factorio" }

    $launchPath = Join-Path $configRoot ".vscode/launch.json"
    if (-not (Test-Path $launchPath)) { throw "launch.json not found at $launchPath" }
    $launchNoComments = ((Get-Content $launchPath -Raw) -split "`n" | ForEach-Object { $_ -replace '//.*$', '' }) -join "`n"
    $launch = ($launchNoComments -replace ',(\s*[}\]])', '$1') | ConvertFrom-Json
    $modsPathRaw = ($launch.configurations | Where-Object { $_.modsPath } | Select-Object -First 1).modsPath
    if (-not $modsPathRaw) { throw "no configuration with a modsPath in launch.json" }
    # ${workspaceFolder} resolves against the .vscode owner, not $RepoRoot: the
    # standard layout's modsPath is "${workspaceFolder}\.." (the shared mods
    # library), which resolved against a worktree under .claude/worktrees/
    # would point at a directory holding no mods at all.
    $modsDir = (Resolve-Path ($modsPathRaw -replace [regex]::Escape('${workspaceFolder}'), $configRoot)).Path

    # The retired in-place mod-list rewrite backed the dev config up to
    # mod-list.json.<tag>-bak siblings; a leftover one means a pre-migration run
    # crashed and the dev config may still be the rewritten test set. Current
    # launchers never touch the shared mod-list.json, so just point it out.
    foreach ($bak in Get-ChildItem (Join-Path $modsDir "mod-list.json.*-bak") -ErrorAction SilentlyContinue) {
        Write-Host "warning: stale backup $($bak.Name) in $modsDir (from a pre-workspace launcher run); compare it with mod-list.json and delete it manually"
    }

    return [PSCustomObject]@{ Factorio = $factorio; ModsDir = $modsDir; ConfigRoot = $configRoot }
}

# ---------------------------------------------------------------------------
# Run workspace
#
# Every launcher run gets a throwaway directory holding everything Factorio
# reads and writes, so no run touches the shared mods dir or the user's
# %APPDATA%\Factorio, and two runs (e.g. one per git worktree) can boot
# concurrently:
#
#   <run root>\<tag>_<timestamp>_<pid>\
#     mods\                 scratch mods dir, passed via --mod-directory:
#       factory_solver        junction -> the checkout under test (works from a
#                             worktree whose folder name is not the mod name)
#       <name>_<ver>.zip      hardlink to the shared mods dir (same volume),
#                             else a copy; directory mods become junctions
#       mod-list.json         generated; the shared one is never rewritten
#       mod-settings.dat      copied (keeps startup settings deterministic)
#     write\                Factorio write-data via a generated config.ini:
#                           .lock, factorio-current.log, saves\, script-output\
#     config.ini            [path] read-data/write-data, passed via --config
#     server-settings.json  minimal headless-server settings
#
# The run root defaults to $env:TEMP\fs_runs; override with the launchers'
# -RunRoot or the FS_RUN_ROOT environment variable (putting it on the mods
# dir's volume lets the zip hardlinks succeed, which matters for big modpacks).
# A workspace is removed on success and kept (with its path printed) on
# failure or -KeepRun; Invoke-RunRootGc sweeps old leftovers at startup.
# ---------------------------------------------------------------------------

function Resolve-RunRoot {
    param([string] $RunRoot)
    if ($RunRoot) { return $RunRoot }
    if ($env:FS_RUN_ROOT) { return $env:FS_RUN_ROOT }
    return (Join-Path $env:TEMP "fs_runs")
}

# An OS-assigned free TCP port. The listener is closed before Factorio binds,
# so a concurrent process could in principle grab the port in between; if that
# happens Factorio exits at bind time, the launcher throws on "exited before
# RCON came up", and a re-run picks a fresh port.
function Get-FreeTcpPort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return $port
}

# An OS-assigned free UDP port for Factorio's game socket (--port). Without it
# every headless run binds the default 34197 and collides with any other Factorio
# -- another launcher run, or the user's own running game -- failing at bind with
# "Host address is already in use". Closed before Factorio binds (same small race
# as Get-FreeTcpPort).
function Get-FreeUdpPort {
    $udp = New-Object System.Net.Sockets.UdpClient(0)
    $port = ([System.Net.IPEndPoint]$udp.Client.LocalEndPoint).Port
    $udp.Close()
    return $port
}

function New-RunWorkspace {
    param([string] $Tag, [string] $ServerName, [string] $RunRoot)
    $dir = Join-Path $RunRoot ("{0}_{1}_{2}" -f $Tag, (Get-Date -Format "yyyyMMddHHmmss"), $PID)
    $modsDir = Join-Path $dir "mods"
    $writeDir = Join-Path $dir "write"
    New-Item -ItemType Directory -Force -Path $modsDir, $writeDir | Out-Null

    # config.ini redirects everything Factorio writes into the workspace.
    # __PATH__executable__ keeps read-data independent of the install location;
    # ini values take raw paths (no quoting), forward slashes for safety.
    $configPath = Join-Path $dir "config.ini"
    $configText = "[path]`r`nread-data=__PATH__executable__/../../data`r`nwrite-data=$($writeDir -replace '\\', '/')`r`n"
    [System.IO.File]::WriteAllText($configPath, $configText, (New-Object System.Text.UTF8Encoding($false)))

    # A dedicated server wants a server-settings file; the built-in defaults
    # prompt for things we do not want in a throwaway local run: private, no
    # user verification, single slot. Missing fields fall back to engine defaults.
    $serverSettingsPath = Join-Path $dir "server-settings.json"
    $serverSettingsText = @"
{
    "name": "$ServerName",
    "description": "factory_solver test launcher run",
    "visibility": { "public": false, "lan": false },
    "require_user_verification": false,
    "max_players": 1,
    "allow_commands": "true"
}
"@
    [System.IO.File]::WriteAllText($serverSettingsPath, $serverSettingsText, (New-Object System.Text.UTF8Encoding($false)))

    return [PSCustomObject]@{
        Dir                = $dir
        ModsDir            = $modsDir
        WriteDir           = $writeDir
        ConfigPath         = $configPath
        ServerSettingsPath = $serverSettingsPath
        LogFile            = Join-Path $writeDir "factorio-current.log"
        ScriptOutputDir    = Join-Path $writeDir "script-output"
        Junctions          = New-Object System.Collections.Generic.List[string]
    }
}

# Link one shared-mods-dir entry into the scratch mods dir: directory mods as
# junctions, zips as hardlinks (same volume only) falling back to a copy.
function Add-ScratchModEntry {
    param([PSCustomObject] $Workspace, [System.IO.FileSystemInfo] $Source)
    $dest = Join-Path $Workspace.ModsDir $Source.Name
    if (Test-Path $dest) { return }
    if ($Source.PSIsContainer) {
        New-Item -ItemType Junction -Path $dest -Target $Source.FullName | Out-Null
        [void]$Workspace.Junctions.Add($dest)
    } else {
        try {
            New-Item -ItemType HardLink -Path $dest -Target $Source.FullName -ErrorAction Stop | Out-Null
        } catch {
            Copy-Item $Source.FullName $dest
        }
    }
}

# Populate the workspace's scratch mods dir. The checkout under test is always
# junctioned in as "factory_solver" (so the checkout's own folder name does not
# matter -- worktrees load fine); any same-named entry in the shared mods dir is
# skipped in its favour.
#
# With a non-empty $Mods, mod-list.json is generated with exactly that set
# enabled. Every name from the shared mod-list.json is carried over as an
# explicit disabled entry: a mod absent from mod-list.json is auto-enabled by
# Factorio, and that includes the read-data expansions (space-age & co.), which
# would silently break the reproducible vanilla minimal set. Requested mods
# missing from the shared dir only warn -- base and the expansions live in
# read-data, not the mods dir.
#
# With an empty $Mods ("dev config" mode), the shared mod-list.json is copied
# verbatim and every shared mod is linked, so the run sees the same set the
# debugger would -- just through the scratch dir.
function Initialize-ScratchMods {
    param(
        [PSCustomObject] $Workspace,
        [string] $SourceModsDir,
        [string] $RepoRoot,
        [string[]] $Mods
    )
    $modUnderTest = "factory_solver"
    $junction = Join-Path $Workspace.ModsDir $modUnderTest
    New-Item -ItemType Junction -Path $junction -Target (Resolve-Path $RepoRoot).ProviderPath | Out-Null
    [void]$Workspace.Junctions.Add($junction)

    $settingsDat = Join-Path $SourceModsDir "mod-settings.dat"
    if (Test-Path $settingsDat) { Copy-Item $settingsDat (Join-Path $Workspace.ModsDir "mod-settings.dat") }

    # Index the shared mods dir: name -> entries (a name can have several zip
    # versions; link them all and let Factorio pick the newest, as it would in
    # the shared dir).
    $disk = @{}
    foreach ($d in Get-ChildItem $SourceModsDir -Directory -ErrorAction SilentlyContinue) {
        $info = Join-Path $d.FullName "info.json"
        if (-not (Test-Path $info)) { continue }
        try { $n = (Get-Content $info -Raw | ConvertFrom-Json).name } catch { $n = $null }
        if ($n -and $n -ne $modUnderTest) {
            if (-not $disk.ContainsKey($n)) { $disk[$n] = New-Object System.Collections.Generic.List[object] }
            [void]$disk[$n].Add($d)
        }
    }
    foreach ($z in Get-ChildItem $SourceModsDir -Filter *.zip -ErrorAction SilentlyContinue) {
        if ($z.BaseName -match '^(.+)_\d+\.\d+\.\d+$' -and $Matches[1] -ne $modUnderTest) {
            $n = $Matches[1]
            if (-not $disk.ContainsKey($n)) { $disk[$n] = New-Object System.Collections.Generic.List[object] }
            [void]$disk[$n].Add($z)
        }
    }

    $sourceListPath = Join-Path $SourceModsDir "mod-list.json"
    $sourceNames = New-Object System.Collections.Generic.List[string]
    if (Test-Path $sourceListPath) {
        foreach ($m in (Get-Content $sourceListPath -Raw | ConvertFrom-Json).mods) { [void]$sourceNames.Add($m.name) }
    }

    $listPath = Join-Path $Workspace.ModsDir "mod-list.json"
    if ($Mods.Count -gt 0) {
        foreach ($name in $Mods) {
            if ($disk.ContainsKey($name)) {
                foreach ($entry in $disk[$name]) { Add-ScratchModEntry -Workspace $Workspace -Source $entry }
            } elseif ($name -ne $modUnderTest -and -not $sourceNames.Contains($name)) {
                Write-Host "warning: requested mod '$name' not found in $SourceModsDir (fine for base / read-data expansions)"
            }
        }
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($n in $sourceNames) { if (-not $names.Contains($n)) { [void]$names.Add($n) } }
        foreach ($n in $Mods) { if (-not $names.Contains($n)) { [void]$names.Add($n) } }
        if (-not $names.Contains($modUnderTest)) { [void]$names.Add($modUnderTest) }
        # base is core and always loads; force it enabled regardless of -Mods.
        $entries = foreach ($name in $names) {
            [PSCustomObject]@{ name = $name; enabled = ($Mods -contains $name) -or ($name -eq 'base') }
        }
        ([PSCustomObject]@{ mods = @($entries) } | ConvertTo-Json -Depth 5) |
            Set-Content -Path $listPath -Encoding utf8
    } else {
        foreach ($entries in $disk.Values) {
            foreach ($entry in $entries) { Add-ScratchModEntry -Workspace $Workspace -Source $entry }
        }
        if (Test-Path $sourceListPath) {
            Copy-Item $sourceListPath $listPath
        }
        # No shared mod-list.json -> let Factorio auto-enable what it finds.
    }
}

# Quote an argument for Start-Process -ArgumentList, which joins elements with
# spaces WITHOUT quoting -- an unquoted path containing a space (the default
# run root lives under $env:TEMP, i.e. the user profile) would split.
function Format-CommandArgument {
    param([string] $Arg)
    if ($Arg -match '[\s"]') { return '"' + ($Arg -replace '"', '\"') + '"' }
    return $Arg
}

function New-FactorioArgumentList {
    param([PSCustomObject] $Workspace, [string] $Scenario, [int] $RconPort, [string] $RconPassword)
    $list = @(
        "--start-server-load-scenario", $Scenario,
        "--mod-directory", $Workspace.ModsDir,
        "--server-settings", $Workspace.ServerSettingsPath,
        "--config", $Workspace.ConfigPath,
        "--port", (Get-FreeUdpPort),
        "--rcon-bind", "127.0.0.1:$RconPort",
        "--rcon-password", $RconPassword,
        "--no-log-rotation",
        "--disable-audio"
    )
    return @($list | ForEach-Object { Format-CommandArgument $_ })
}

# Wait for the server's RCON port, connect, authenticate. Auth failure throws
# immediately: with per-run random passwords this is what turns "accidentally
# connected to some other run's server" into a hard error instead of silently
# driving (and PASSing against) the wrong build.
function Connect-Rcon {
    param(
        [string] $ConnectHost = "127.0.0.1",
        [int] $Port,
        [string] $Password,
        [int] $TimeoutSeconds,
        $Proc = $null
    )
    $client = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        if ($Proc -and $Proc.HasExited) { throw "Factorio exited before RCON came up (code $($Proc.ExitCode))" }
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect($ConnectHost, $Port)
            $stream = $client.GetStream()
            break
        } catch {
            if ($client) { $client.Dispose(); $client = $null }
            if ((Get-Date) -gt $deadline) { throw "RCON $ConnectHost`:$Port never opened within ${TimeoutSeconds}s" }
            Start-Sleep -Milliseconds 500
        }
    }
    Send-RconPacket -Stream $stream -Id 1 -Type 3 -Body $Password
    $auth = Receive-RconPacket -Stream $stream
    # Some servers emit an empty RESPONSE_VALUE before the AUTH_RESPONSE; skip it.
    if ($auth.Type -eq 0) { $auth = Receive-RconPacket -Stream $stream }
    if ($auth.Id -eq -1) {
        $client.Dispose()
        throw "RCON auth failed (wrong password, or connected to a different server's port?)"
    }
    return [PSCustomObject]@{ Client = $client; Stream = $stream }
}

# Junction-first deletion of one run directory. Junctions MUST be removed as
# bare reparse points ([IO.Directory]::Delete, non-recursive) before the
# recursive remove: Remove-Item -Recurse on a junction descends into the TARGET
# and would delete the checkout itself. Hardlinked zips are plain files whose
# removal just drops a link, leaving the shared dir's copy intact.
function Remove-RunDirectory {
    param([string] $Dir, [System.Collections.Generic.List[string]] $KnownJunctions = $null)
    $junctions = New-Object System.Collections.Generic.List[string]
    if ($KnownJunctions) { foreach ($j in $KnownJunctions) { [void]$junctions.Add($j) } }
    $mods = Join-Path $Dir "mods"
    if (Test-Path $mods) {
        foreach ($e in Get-ChildItem $mods -Directory -ErrorAction SilentlyContinue) {
            if ($e.LinkType -and -not $junctions.Contains($e.FullName)) { [void]$junctions.Add($e.FullName) }
        }
    }
    foreach ($j in $junctions) {
        if (Test-Path $j) { [System.IO.Directory]::Delete($j) }
    }
    Remove-Item $Dir -Recurse -Force -ErrorAction Stop
}

function Remove-RunWorkspace {
    param([PSCustomObject] $Workspace, [switch] $Keep)
    if (-not $Workspace -or -not (Test-Path $Workspace.Dir)) { return }
    if ($Keep) {
        Write-Host "run workspace kept at $($Workspace.Dir)"
        return
    }
    try {
        Remove-RunDirectory -Dir $Workspace.Dir -KnownJunctions $Workspace.Junctions
    } catch {
        # Factorio may still hold write\.lock for a moment after the kill.
        Start-Sleep -Seconds 1
        try {
            Remove-RunDirectory -Dir $Workspace.Dir -KnownJunctions $Workspace.Junctions
        } catch {
            Write-Host "warning: could not remove run workspace $($Workspace.Dir): $($_.Exception.Message)"
        }
    }
}

# Sweep leftovers (crashed or -KeepRun'd runs) older than $MaxAgeDays out of the
# run root. A directory still held open (a live run's .lock) just fails the
# remove and is skipped silently.
function Invoke-RunRootGc {
    param([string] $RunRoot, [int] $MaxAgeDays = 7)
    if (-not (Test-Path $RunRoot)) { return }
    $cutoff = (Get-Date).AddDays(-$MaxAgeDays)
    foreach ($d in Get-ChildItem $RunRoot -Directory -ErrorAction SilentlyContinue) {
        if ($d.CreationTime -gt $cutoff) { continue }
        try { Remove-RunDirectory -Dir $d.FullName } catch {}
    }
}
