# Shared plumbing for the RCON-driven test/dev launchers (tests/smoke_rcon.ps1,
# tests/explore_chains.ps1, tests/console.ps1). Dot-source it AFTER the param()
# block: `. "$PSScriptRoot/rcon_lib.ps1"`.
#
# This module is pure function definitions -- no param(), no top-level side
# effects, no $ErrorActionPreference change -- so dot-sourcing only injects the
# functions into the caller's scope. Paths are passed in (it never reads
# $PSScriptRoot, which under dot-source resolves to the CALLER's directory).
#
# Three previously-duplicated concerns live here:
#   * the Source RCON wire protocol (Read-Exact / Send / Receive / Invoke),
#   * resolving Factorio + the mods dir from the .vscode/* configs, and
#   * the reproducible mod-list.json backup -> rewrite -> restore dance.
# Launcher-specific machinery (Factorio launch args, the explorer worker pool,
# the console REPL helpers) deliberately stays in each launcher.

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
# ---------------------------------------------------------------------------
function Resolve-FactorioConfig {
    param([string] $RepoRoot)

    $settingsPath = Join-Path $RepoRoot ".vscode/settings.json"
    if (-not (Test-Path $settingsPath)) { throw "settings.json not found at $settingsPath" }
    $settingsJson = (Get-Content $settingsPath -Raw) -replace ',(\s*[}\]])', '$1'
    $factorio = ($settingsJson | ConvertFrom-Json).'factorio.versions'[0].factorioPath
    if (-not (Test-Path $factorio)) { throw "Factorio binary not found at $factorio" }

    $launchPath = Join-Path $RepoRoot ".vscode/launch.json"
    if (-not (Test-Path $launchPath)) { throw "launch.json not found at $launchPath" }
    $launchNoComments = ((Get-Content $launchPath -Raw) -split "`n" | ForEach-Object { $_ -replace '//.*$', '' }) -join "`n"
    $launch = ($launchNoComments -replace ',(\s*[}\]])', '$1') | ConvertFrom-Json
    $modsPathRaw = ($launch.configurations | Where-Object { $_.modsPath } | Select-Object -First 1).modsPath
    if (-not $modsPathRaw) { throw "no configuration with a modsPath in launch.json" }
    $modsDir = (Resolve-Path ($modsPathRaw -replace [regex]::Escape('${workspaceFolder}'), $RepoRoot)).Path

    return [PSCustomObject]@{ Factorio = $factorio; ModsDir = $modsDir }
}

# ---------------------------------------------------------------------------
# Reproducible mod-list.json control
#
# Factorio reads enable/disable state from <mods>/mod-list.json. To run a known
# set we rewrite it (requested mods enabled, the rest -- including disk mods the
# original omits, which Factorio would auto-enable -- disabled) and restore it
# afterward. The original is backed up to a "<BackupSuffix>" sibling; a stale
# backup from a crashed run is restored first so the dev config is never lost.
# An empty -Mods opts out entirely (Controlled = $false -> no rewrite, no
# restore), which is how smoke/console leave the dev config untouched.
#
# Returns a state bag to hand to Restore-ModList in the caller's finally block.
# ---------------------------------------------------------------------------
function Set-ReproducibleModList {
    param(
        [string] $ModsDir,
        [string[]] $Mods,
        [string] $BackupSuffix,
        # Printed (if non-empty) when a prior run's leftover backup is restored,
        # so each launcher keeps its own "<tag>: restoring ..." line.
        [string] $RestoreMessage = ""
    )
    $modListPath = Join-Path $ModsDir "mod-list.json"
    $modListBak = "$modListPath.$BackupSuffix"
    $controlMods = $Mods.Count -gt 0
    $hadOriginal = $false

    if (Test-Path $modListBak) {
        if ($RestoreMessage) { Write-Host $RestoreMessage }
        Move-Item -Force $modListBak $modListPath
    }

    if ($controlMods) {
        $hadOriginal = Test-Path $modListPath
        $names = New-Object System.Collections.Generic.List[string]
        if ($hadOriginal) {
            Copy-Item $modListPath $modListBak -Force
            foreach ($m in (Get-Content $modListPath -Raw | ConvertFrom-Json).mods) { [void]$names.Add($m.name) }
        }
        # Ensure requested mods appear even if absent from the dev config.
        foreach ($m in $Mods) { if (-not $names.Contains($m)) { [void]$names.Add($m) } }
        # Close the gap: a mod present on disk but absent from the original
        # mod-list.json is auto-enabled by Factorio. Enumerate disk mods -- folders
        # with an info.json and name_version.zip archives -- so each gets an
        # explicit entry and is disabled unless requested.
        foreach ($d in Get-ChildItem $ModsDir -Directory -ErrorAction SilentlyContinue) {
            $info = Join-Path $d.FullName "info.json"
            if (Test-Path $info) {
                try { $n = (Get-Content $info -Raw | ConvertFrom-Json).name } catch { $n = $null }
                if ($n -and -not $names.Contains($n)) { [void]$names.Add($n) }
            }
        }
        foreach ($z in Get-ChildItem $ModsDir -Filter *.zip -ErrorAction SilentlyContinue) {
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

    return [PSCustomObject]@{
        ModListPath = $modListPath
        ModListBak  = $modListBak
        Controlled  = $controlMods
        HadOriginal = $hadOriginal
    }
}

# Restore the dev mod-list.json rewritten by Set-ReproducibleModList. Call from
# the caller's finally block with the state bag it returned. A no-op when mods
# were not controlled (empty -Mods).
function Restore-ModList {
    param([PSCustomObject] $State)
    if (-not $State -or -not $State.Controlled) { return }
    if (Test-Path $State.ModListBak) {
        Move-Item -Force $State.ModListBak $State.ModListPath
    } elseif (-not $State.HadOriginal) {
        Remove-Item $State.ModListPath -Force -ErrorAction SilentlyContinue
    }
}
