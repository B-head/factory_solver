# Collect tests/research/collect_useful.lua over every explorer-dumped problem into one
# TSV corpus. The collection is Factorio-free (the dumps already exist under
# script-output/explore_problems); this just lists them into a manifest and runs
# the Lua worker ONCE, which reads the manifest and writes the --out file itself.
# Writing the file from Lua sidesteps every WinPS native-stdout/stderr capture
# quirk and the command-line-length limit on a large dump set.
#
# Widen the corpus first by regenerating more dumps (boots Factorio once):
#   pwsh tests/explore_chains.ps1 -Seeds 30 -StartSeed 1
# then collect them here (no Factorio):
#   pwsh tests/research/collect_corpus.ps1 -Out useful_corpus.tsv
#
# collect_useful.lua keeps reachability_gating / deficit_seeding /
# catalyst_closure OFF by default (pure tilted-cost experiment); set the matching
# CP_<NAME>=1 env var before running to turn one back on for an A/B.

[CmdletBinding()]
param(
    [string] $DumpDir = (Join-Path $env:APPDATA "Factorio/script-output/explore_problems"),
    [string] $Out = "useful_corpus.tsv",
    [string] $LuaExe = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/ps_lib.ps1"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

$LuaExe = Resolve-LuaExe $LuaExe

if (-not (Test-Path $DumpDir)) {
    Write-Error "dump dir not found: $DumpDir (run tests/explore_chains.ps1 first)"; exit 2
}
$dumps = @(Get-ChildItem -Path $DumpDir -Filter "*.lua" | Sort-Object Name)
if ($dumps.Count -eq 0) { Write-Error "no *.lua dumps in $DumpDir"; exit 2 }
if (-not [System.IO.Path]::IsPathRooted($Out)) { $Out = Join-Path $repoRoot.Path $Out }

# Manifest: one dump path per line. Plain ASCII paths, UTF-8 no BOM so Lua's
# io.lines reads them cleanly.
$manifest = [System.IO.Path]::GetTempFileName()
Set-Content -Path $manifest -Value ($dumps.FullName) -Encoding ascii

Write-Host "collecting $($dumps.Count) dumps with $LuaExe -> $Out"
Push-Location $repoRoot.Path
try {
    # Lua writes $Out itself; we don't capture its stdout. Let any stderr show.
    & $LuaExe "tests/research/collect_useful.lua" "--manifest" $manifest "--out" $Out
} finally { Pop-Location; Remove-Item $manifest -ErrorAction SilentlyContinue }

$rows = @(Get-Content $Out | Where-Object { $_ -and ($_ -notmatch '^#') })
Write-Host "done: $($dumps.Count) dumps, $($rows.Count) candidate rows -> $Out"
