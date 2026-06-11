# tests/research/

One-shot research drivers for the **tilt-cost** investigation (and the cost /
reachability experiments around it). These are *not* part of the pass/fail gate —
they emit raw numbers a human reads, they have no assertions, and most were
written to answer a single hypothesis. They live here, separate from the durable
suite in `tests/`, so the regression net and the research scratchpad don't blur
together.

Nothing in the shipped mod depends on this folder. The durable entry points stay
at the `tests/` top level: `run.lua` (the headless suite), `smoke_rcon.ps1` /
`console.ps1` (RCON), and `explore_chains.ps1` (the chain explorer), plus the
shared libraries every driver here requires (`harness`, `headless_env`,
`problem_dump`, `explore_detect`).

## Layout

- **`research_lib.lua`** — shared boilerplate for the probes: load / build / solve a
  dumped problem, classify escapes, and the SCC-aggregation reads
  (`internal_recipes`, `internal_flow`, `target_relax`, `other_escape_sum`,
  `shortage_of_material` / `shortage_of_keys`) the probes used to copy-paste.
  Read its header caveat before trusting any output built on it — these are
  *screening* helpers, not verdicts.
- **`probe_*.lua`** — single-hypothesis drivers. Most are single-shot workers
  (one dump file → stdout) fanned over the corpus by `run_corpus.ps1`; a few take
  a `--manifest` / `--thresholds` / `--flip` TSV instead (see each file's Usage
  header). `exp_tilt.lua` and `drill_seed18.lua` are one-off fixture dissections.
- **`sweep_cost.lua` / `sweep_tolerance.lua`** — per-variable cost and IPM-tolerance
  sensitivity on one dumped problem. `sweep_fanout.ps1` shards `sweep_cost` across
  cores by target range.
- **`collect_useful.lua` / `classify_useful.lua`** — useful-variable collection over
  the corpus; `collect_corpus.ps1` fans them into one TSV.
- **`run_ablated.lua`** — the headless suite re-run with `create_problem` options
  ablated via `CP_*` env vars (e.g. `CP_REACHABILITY_GATING=0`).
- **`ps_lib.ps1`** — shared `Resolve-LuaExe` (LuaJIT-preferred) and `Invoke-LuaPool`
  (the throttled headless worker pool) for the three `.ps1` launchers here. Speaks
  no RCON; that plumbing is `tests/rcon_lib.ps1`.

## Running

The dumps these consume live in the **canonical corpus**, named by the
`FS_CORPUS_DIR` environment variable — the default for every `-DumpDir` here
(and the value of `research_lib.lua`'s `DUMP_DIR`). There is deliberately no
baked-in fallback path: set the variable once (any durable directory), or pass
`-DumpDir` explicitly. The corpus is read-only for the tooling. The chain
explorer (`pwsh tests/explore_chains.ps1 -Seeds N`) publishes each run's dumps
to the checkout-local `tests/explore_problems/` (gitignored, replaced per
run); promote a run into the canonical corpus by hand when it should become
the new analysis baseline:

```powershell
Copy-Item tests\explore_problems\*.lua $env:FS_CORPUS_DIR
```

Dump generation is deterministic only per code version, so an unpromoted
branch's run can never silently overwrite the corpus your analyses (and the
refcache keys) are built on. Then, from the repo root:

```
lua  tests/research/probe_force.lua <dump.lua>
pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_force.lua -Collect '^RESULT'
pwsh tests/research/sweep_fanout.ps1 -Mode measure
pwsh tests/research/collect_corpus.ps1 -Out useful_corpus.tsv
```

The `lua` drivers `require "tests/..."` against the repo root, so always run them
from there (the `.ps1` launchers set the worker CWD for you).
