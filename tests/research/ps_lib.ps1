# Shared helpers for the headless `lua`-pool research launchers in this folder
# (run_corpus.ps1, sweep_fanout.ps1, collect_corpus.ps1). Dot-source it:
#
#     . "$PSScriptRoot/ps_lib.ps1"
#
# These speak no RCON and boot no Factorio -- that plumbing lives in
# tests/rcon_lib.ps1. This file only resolves the standalone Lua interpreter and
# fans headless `lua <args>` workers out across cores (PS 5.1: no
# ForEach-Object -Parallel). It defines functions only, no top-level state.

# Resolve the standalone Lua interpreter. Prefer an explicit -LuaExe, then LuaJIT
# (~2.7x on the solve corpus, identical results per CLAUDE.md), then stock lua
# under %LOCALAPPDATA%\Programs, then either on PATH. Throws if none is found.
function Resolve-LuaExe {
    param([string] $LuaExe = '')
    if ($LuaExe) {
        if (Test-Path $LuaExe) { return $LuaExe }
        throw "lua interpreter not found at -LuaExe: $LuaExe"
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs/LuaJIT/bin/luajit.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs/Lua/bin/lua.exe')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $onPath = Get-Command luajit -ErrorAction SilentlyContinue
    if (-not $onPath) { $onPath = Get-Command lua -ErrorAction SilentlyContinue }
    if ($onPath) { return $onPath.Source }
    throw "lua interpreter not found (looked for -LuaExe, LuaJIT/lua under $env:LOCALAPPDATA\Programs, and on PATH)."
}

# Throttled headless worker pool. Each item is @{ ArgList = @(...); Tag = <any> }.
# Runs at most $Jobs `lua <ArgList>` processes at once, reaping the finished ones.
#   * With -OnResult, its scriptblock is invoked (Tag, stdout-text) as each worker
#     exits (streaming) -- use for `Write-Output` row pass-through.
#   * Without it, the (Tag, Output) pairs are collected and returned.
# -ShowProgress prints a `\r running done/total` counter (off by default).
# A 40ms re-read guards the case where Proc.HasExited flips true a beat before the
# OS flushes the redirected stdout file, so a fast worker's output is not dropped.
function Invoke-LuaPool {
    param(
        [object[]] $Items,
        [int] $Jobs,
        [string] $LuaExe,
        [string] $WorkDir,
        [scriptblock] $OnResult,
        [switch] $ShowProgress
    )
    $queue = New-Object System.Collections.Queue
    foreach ($it in $Items) { [void]$queue.Enqueue($it) }
    $running = New-Object System.Collections.Generic.List[object]
    $collected = New-Object System.Collections.Generic.List[object]
    $total = $queue.Count; $done = 0
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($running.Count -lt $Jobs -and $queue.Count -gt 0) {
            $it = $queue.Dequeue()
            $tmpOut = [System.IO.Path]::GetTempFileName()
            $p = Start-Process -FilePath $LuaExe -ArgumentList $it.ArgList `
                -WorkingDirectory $WorkDir -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut
            [void]$running.Add([PSCustomObject]@{ Proc = $p; Out = $tmpOut; Tag = $it.Tag })
        }
        for ($i = $running.Count - 1; $i -ge 0; $i--) {
            $r = $running[$i]
            if ($r.Proc.HasExited) {
                $txt = Get-Content $r.Out -Raw -ErrorAction SilentlyContinue
                if (-not $txt) { Start-Sleep -Milliseconds 40; $txt = Get-Content $r.Out -Raw -ErrorAction SilentlyContinue }
                Remove-Item $r.Out -Force -ErrorAction SilentlyContinue
                $running.RemoveAt($i); $done++
                if ($OnResult) { & $OnResult $r.Tag $txt }
                else { [void]$collected.Add([PSCustomObject]@{ Tag = $r.Tag; Output = $txt }) }
            }
        }
        if ($ShowProgress) { Write-Host -NoNewline "`r  running $done/$total ...   " }
        if ($running.Count -ge $Jobs -or ($queue.Count -eq 0 -and $running.Count -gt 0)) {
            Start-Sleep -Milliseconds 20
        }
    }
    if ($ShowProgress) { Write-Host "" }
    # In -OnResult (streaming) mode the rows were already emitted by the callback;
    # only the collect mode returns pairs.
    if (-not $OnResult) { return $collected }
}
