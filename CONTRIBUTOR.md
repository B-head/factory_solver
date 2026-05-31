# Contributing to factory_solver

For the user-facing pitch, feature list, and version history, see [README.md](README.md) and [changelog.txt](changelog.txt). This file covers what's needed to work on the code; there is no separate build step, and the only out-of-Factorio test harness is the headless solver suite described below.

Before opening a feature branch, pick which long-lived branch to cut from — the repo uses a modified OneFlow with two:

- **`main`** — start here for new features, refactors, docs, or topic / experimental work (e.g. `blog`, `inconsistency`). The next release rolls out from this branch.
- **`stable`** — start here for bug fixes that should reach the released version without waiting for the next release. Fixes land on `stable`, get tagged there, and are merged into `main` afterward (the historical `Merge branch 'stable' version X.Y.Z` commits trace the pattern). The branch is kept alive and reused rather than re-branched from a tag per fix.

## Running / debugging

Development uses the [`justarandomgeek.factoriomod-debug`](https://marketplace.visualstudio.com/items?itemName=justarandomgeek.factoriomod-debug) VS Code extension; it handles workspace configuration (debug launch, sumneko's reference to Factorio's runtime API stubs, publish command) automatically once installed. The repo's standard layout puts the working copy alongside other mods in a `factorio_mods/` folder (`modsPath = ${workspaceFolder}\..`), not inside Factorio's actual `mods/` directory.

The one piece the extension can't auto-configure is `flib`, because it lives in a separate mod. Extract the `flib` mod into the `factorio_mods/` parent folder, then add that folder to `Lua.workspace.library` in a local `.vscode/settings.json` so `__flib__/*` imports resolve in [sumneko-lua](https://github.com/LuaLS/lua-language-server). `.vscode/` is gitignored, so each contributor maintains their own copy.

Under the debugger, `__DebugAdapter` is truthy. The code paths gated on it (in [control.lua](control.lua), [data.lua](data.lua), [manage/save.lua](manage/save.lua)) auto-enable cheat mode, skip the freeplay intro, unlock all qualities, expose hidden/unresearched recipes in the picker, and register the `fs-test-*` recipes (short/long/parallel loops in [data.lua](data.lua)) used to stress the LP solver against the cyclic chains that motivated the mod.

[info.json](info.json) has a `package` block consumed by factoriomod-debug's publish command (`stable` branch, gallery and `tests/` excluded from the upload).

## Architecture

[meta.lua](meta.lua) is not loaded at runtime — it holds pure LuaCATS `---@meta` annotations for the project's type vocabulary (`TypedName`, `Solution`, `ProductionLine`, `Constraint`, `NormalizedProductionLine`, `PlayerLocalData`, `ForceLocalData`, `SolverState`, `Virtuals`, ...). Almost every function elsewhere is annotated against these types, and the Solver pipeline / State / GUI subsections below reference them directly.

### Logging (`fs_log.lua`)

[fs_log.lua](fs_log.lua) wraps Factorio's `log()` with severity levels (`debug` / `info` / `warn` / `error`) and a per-module prefix; loggers are obtained via `fs_log.for_module("<module name>")`.

### Solver pipeline (`solver/`)

The solver is the heart of the mod and the reason it exists. The pipeline is:

1. `ProductionLine[]` (user-edited) → `pre_solve.to_normalized_production_lines` in [manage/pre_solve.lua](manage/pre_solve.lua) folds in machine speed, modules, beacons, quality, productivity, fuel and pollution, producing `NormalizedProductionLine[]` with per-second amounts.
2. [solver/create_problem.lua](solver/create_problem.lua) turns those lines plus the user's `Constraint[]` into a `Problem` (see [solver/problem_generator.lua](solver/problem_generator.lua)). Each recipe becomes a primal variable, each material an equivalence constraint summing to zero, with auxiliary source / sink / elastic / target variables attached as needed (full taxonomy below).
3. [solver/linear_programming.lua](solver/linear_programming.lua) implements primal-dual interior-point iteration on sparse CSR matrices ([solver/csr_matrix.lua](solver/csr_matrix.lua), which provides Hadamard ops, Cholesky decomposition and forward/backward substitution). One IPM step is performed per call; `solver_state` carries the iteration count (or one of `"ready"`, `"finished"`, `"unfinished"`, `"unbounded"`, `"unfeasible"`).
4. [control.lua](control.lua)'s `on_tick` handler calls `pre_solve.find_the_need_for_solve` once per tick, advances one IPM step, then dispatches `on_calculation_changed` down the GUI tree so result panels refresh. Solving is therefore **incremental and amortised across ticks** — large problems take many ticks but never block.

One dynamic in step 2 is worth pulling out: `|surplus_sink|` is attached unconditionally to every intermediate, but `|shortage_source|` is reachability-gated. `compute_reachable_materials` runs a fixed point from raw / zero-ingredient sources, lighting up recipes whose ingredients are all reachable, and only materials **unreachable** from those receive a `|shortage_source|`. Without this gate, the LP pays elastic cost to "fabricate" intermediates instead of running producer chains (Fulgora-style byproduct cascades); without `|shortage_source|` at all, mass-losing loops with no external input deadlock at all-zero. The reachability fixed point reconciles the two.

The CSR matrix layer is hand-rolled (no BLAS, all pure Lua) and is the most numerically delicate code in the repo. `linear_programming.M.solve` clamps `x` and `s` to avoid NaN propagation, `find_step` picks the largest step that keeps variables positive, and the barrier is scaled by the combined primal-dual residual — exact bounds and the scaling expression live in the source.

Variables in the LP (all defined in [solver/create_problem.lua](solver/create_problem.lua)):

| Variable | Class | Cost | Attached to | Role |
|---|---|---|---|---|
| primal recipe variable | primal | `0` | one per in-scope recipe | decision: how much to run |
| `\|basic_source\|<material>` | slack source | `slack_cost` | raw inputs and cycle-entry deficits | supplies external material at zero cost |
| `\|final_sink\|<material>` | slack sink | `slack_cost` | user-requested products | absorbs the final output |
| `\|surplus_sink\|<material>` | elastic sink | `elastic_cost` | every intermediate | absorbs overshoot when balance is over-determined |
| `\|shortage_source\|<material>` | elastic source | `elastic_cost` | intermediates unreachable from raw inputs (gated) | escape hatch for dead-end / mass-losing cycles |
| `\|elastic\|<constraint>` | elastic | `elastic_cost` | `Constraint`s of type `lower` / `equal` | lets the LP miss the requested rate instead of terminating at `"unfeasible"` |
| upper-limit constraint slack | target | `target_cost` | `Constraint`s of type `upper` | pulls the optimum toward the requested cap |

The three cost tiers form a load-bearing ordering `slack_cost` < `elastic_cost` < `target_cost` — inverting it would make the LP prefer wrong solutions. Concrete values live in [solver/create_problem.lua](solver/create_problem.lua).

**Where costs are allowed to mean something.** The objective function carries meaningful weight at three kinds of variables only: **sources** (`|basic_source|`, `|shortage_source|`), **sinks** (`|final_sink|`, `|surplus_sink|`), and **constrained variables** (those that carry `target_cost`). Cost on a recipe variable itself is essentially meaningless: the recipe's role is already pinned by material balance, and any cost there leaks identically across every path that includes it. The intent "this recipe should run" is expressed at the constrained variable on the recipe's output, not on the recipe variable.

Two corollaries already baked into the design:

- **No per-item cost weights.** The cost tier is set by *variable class*, not by which item the variable represents. Per-item weighting would introduce three unresolvable problems: multiple producer paths make the weight circular, research progression makes it non-stationary, and loop traversal explodes on recycling chains — exactly the case the LP is here to handle. A defensible cousin design exists (per-raw-resource cost + lexicographic priority on resource-extraction recipes, with all other recipes uncosted), but full per-item weights don't fit.
- **No penalty on recipe classes.** No fixed multiplier is applied to "all recycling recipes" or "all mining recipes". The structural problems class penalties try to fix — loops, byproduct cascades — are addressed *structurally* (reachability gating, traversal decomposition), because a class penalty also damages the cases where that recipe class is genuinely required. Quality recycling is the load-bearing example (see [README.md](README.md)).

### State (`manage/`)

All persistent state lives under `storage` (Factorio's auto-serialised global table). Mod state that survives save/load — or that is visible to a client joining a multiplayer game in progress — has to live here. Factorio's multiplayer uses deterministic lockstep, so anything kept in plain Lua globals (or in `local` upvalues set at runtime) exists only on the host, never reaches late-joining clients, and desyncs the moment two players' states diverge. The official [storage docs](https://lua-api.factorio.com/latest/auxiliary/storage.html) only guarantee that `storage` is serialised across save/load; the multiplayer rationale comes from the [Factorio wiki's Desynchronization page](https://wiki.factorio.com/Desynchronization). Both are load-bearing here: values that matter past the current tick live in `storage`, even though multiplayer is untested today. Top-level shape is declared in [meta.lua](meta.lua) (`Storage`):

- `storage.players[player_index]` → `PlayerLocalData` (UI prefs, presets, selected solution).
- `storage.forces[force_index]` → `ForceLocalData` (solutions, cached `relation_to_recipes` and `group_infos` invalidated by `*_needs_updating` flags).
- `storage.virtuals` → `Virtuals` (synthesised "recipes" for boilers, generators, mining drills, etc. — anything that isn't a real `LuaRecipePrototype` but needs to participate in the LP).

Two prototype classes are deliberately excluded from virtual recipes:

- **Electricity-only prototypes are not modelled.** The LP doesn't treat electricity as a first-class resource (pure electricity flow is a sum/diff, not an optimisation problem). Solar panels, accumulators, lightning-attractors, `electric-energy-interface` therefore get no virtual recipe. Prototypes that *consume* electricity but produce items/fluids (captive biter spawner, fusion-generator's fluid side) are still in scope — the electric input is just dropped on the floor.
- **Debug-infinity prototypes get no individual virtual.** `heat-interface`, `infinity-container` / `infinity-chest`, `infinity-pipe`, `electric-energy-interface` are placeholder; a planned generic infinite source/sink virtual will cover them. Splitting one off per prototype would duplicate that future facility and add picker noise.

[manage/save.lua](manage/save.lua) is the schema authority. Its `init_*` / `reinit_*` functions are the migration path: `on_configuration_changed` (mod update / config change / research finished / research reversed) routes through `reinit_force_data`, which walks every `Solution`'s `production_lines` and `constraints` running [manage/typed_name.lua](manage/typed_name.lua)'s `typed_name_migration` on every `TypedName` field. The `module_names` → `module_typed_names` and `beacon_name` → `beacon_typed_name` migrations are the concrete examples; new persistent fields use the same pattern.

`on_load` calls `resetup_force_data_metatable` to reattach the `Problem` metatable, because metatables don't survive save/load. The same is done for anything saved into `storage` that needs methods.

`TypedName = { type, name, quality }` is the universal handle for "something that can appear in a recipe slot" — items, fluids, recipes, machines, virtual materials, virtual recipes. [manage/typed_name.lua](manage/typed_name.lua) is the only module that maps a `TypedName` to a prototype, sprite, tooltip, or LP variable name (`typed_name_to_variable_name` produces the `"type/name/quality"` strings used as keys throughout the solver).

[manage/accessor.lua](manage/accessor.lua) holds prototype-derived helpers: math primitives (crafting speed, energy usage, productivity caps, fuel amount per second, quality level), prototype-set lookups (`get_machines_in_category`, `get_offshore_pumps_for_fluid`, `get_labs_for_pack`, `get_fuels_in_categories`, `get_module`, `get_beacon`, ...), and predicates (`is_hidden`, `is_unresearched`, `is_use_fuel`, ...) — anything that reads a `LuaEntityPrototype` / `LuaRecipePrototype` / `LuaItemPrototype` (or a small structured wrapper around one). The single-line aggregator `acc.normalize_production_line` also lives here.

[manage/pre_solve.lua](manage/pre_solve.lua) is the place that **batch-aggregates** the same primitives across an entire solution, folding raw Factorio data (machines, modules, beacons, quality, productivity, fuel, pollution) into `NormalizedProductionLine[]` with per-second amounts before the LP sees it. The UI calls `acc.normalize_production_line` directly for per-line display rather than rolling its own folding; `pre_solve.lua` and the UI are both callers of the same accessor helper.

### GUI (`ui/`)

Built on `flib_gui`. [fs_util.lua](fs_util.lua) wraps it with helpers that the rest of the codebase relies on:

- `fs_util.add_gui(parent, def, append_tags)` adds a subtree and dispatches a synthetic `on_added` event down it, so handlers can do init work at construction time.
- `fs_util.dispatch_to_subtree(root, event_name, data?)` walks the subtree DFS and synthesises events. The solver pump uses this to fire `on_calculation_changed` after each IPM step.
- `fs_util.find_upper(start, name)` / `follow_upper` walk parent links — handlers use them to locate the enclosing window/panel rather than capturing closures.

[ui/main_window.lua](ui/main_window.lua) is a static `flib.GuiElemDef` tree composing [solution_selector](ui/solution_selector.lua), [common_settings](ui/common_settings.lua), [solution_editor](ui/solution_editor.lua), [solution_settings](ui/solution_settings.lua), [solution_results](ui/solution_results.lua). A new panel is added by requiring its module from `main_window.lua` and slotting it into the tree. Handler functions are registered on the def via `handler = { [defines.events.on_gui_click] = ... }` and resolved at registration time by `flib_gui.handle_events()` (called at the bottom of [control.lua](control.lua)).

Save mutations that need a recompute mark `solution.solver_state = "ready"` (see the `new_*` / `delete_*` / `update_*` functions in [manage/save.lua](manage/save.lua)); the on_tick pump picks it up next tick.

### Design choice: auto-recovery over user diagnosis

The soft-cost + elastic/slack + reachability-gating stack ensures the solver always returns *something* for any input, instead of terminating at `"unfeasible"` and pushing diagnosis onto the user (the path some other calculators take, via hard-equality constraints with after-the-fact SCC diagnosis, or via many user-exposed cost weights). The current solver pipeline was built as an investment in this UX rather than in solver elegance for its own sake.

The user-facing surface exposes **categorical choices** (which recipe, target rate, which machine) but no **opaque numeric knobs**. Cost tiers are fixed in [solver/create_problem.lua](solver/create_problem.lua) and not user-tunable; exposing them would reduce to "everyone leaves the defaults", adding GUI surface for no behaviour change.

## Headless testing (`tests/`)

`solver/*` is pure Lua with no Factorio runtime dependencies, so the suite runs from a standalone Lua 5.2+ / LuaJIT interpreter outside Factorio. Any `lua` on your `PATH` works — there are no external rocks to install. On Windows, `winget install DEVCOM.Lua` installs Lua 5.4 and puts `lua` on `PATH`; verify with `lua -v`. Invoked from the repo root:

- `lua tests/run.lua` — runs every case under [tests/cases/](tests/cases/).
- `lua tests/run.lua -v` — same, with captured solver dumps on success too.
- `lua tests/run.lua short_loop` — only runs cases whose file name contains the substring.

[tests/run.lua](tests/run.lua)'s header comment covers rationale, scope, the case-file registration mechanism, and the bootstrap rule for loop fixtures. [tests/harness.lua](tests/harness.lua) holds the log-capture machinery, the assertion helpers, and `solve_to_completion`.

## In-game smoke test (`scenarios/smoke_rcon/` + `tests/smoke_rcon.ps1`)

For the layers the headless suite can't reach — [manage/pre_solve.lua](manage/pre_solve.lua)'s machine-speed / module / quality folding, [manage/virtual.lua](manage/virtual.lua)'s virtual-recipe generation, [manage/save.lua](manage/save.lua)'s migration paths, and the read-side total helpers in [manage/report.lua](manage/report.lua) — an end-to-end smoke test boots a real Factorio with the mod loaded and drives the solver synchronously over RCON. It boots **once** and runs every fixture in the same server; the verdict is decided from structured RCON responses, not by grepping `factorio-current.log`.

The boot is a **headless dedicated server** (`--start-server-load-scenario`), so there are no players. It exercises the force-scoped solver pump and the read-side total helpers; **the GUI is out of scope**. The design rationale — why a zero-player server still converges, why fixtures build the `Solution` directly rather than through player presets, and why `LuaSimulation` isn't the route to GUI coverage — lives in the header comment of [manage/smoke_rcon.lua](manage/smoke_rcon.lua).

How the pieces fit together:

- [scenarios/smoke_rcon/control.lua](scenarios/smoke_rcon/control.lua) is a deliberately empty marker file. Scenarios run in their own Lua context with a separate `storage`, so the real work goes through the mod via `remote.call` instead.
- [manage/smoke_rcon.lua](manage/smoke_rcon.lua) is the driver, living inside the mod so it shares `storage` and module state. It registers the `factory_solver_smoke` remote interface (`setup` / `state` / `check_read_side`). Fixtures (`iron_plate`, `missing_prototype`) plant a `Solution` directly into the force's storage and pick a machine explicitly; `check_read_side` runs `report.get_total_*` under `pcall` against the force's `ResearchBonuses`. Each fixture also declares the mods whose prototypes it reads in `requires`; `setup` returns `SKIP` (not a failure) when one isn't in `script.active_mods`, so narrowing the mod set just trims coverage. Guard every mod a fixture touches this way, including official ones (`space-age` / `quality` / `elevated-rails`); only factory_solver's hard `info.json` dependencies (`base`, `flib`) may be omitted.
- [control.lua](control.lua) registers the interface from its main chunk only when `script.level.level_name == "smoke_rcon"`, so a normal load never pays for it. No `on_tick` / `on_player_created` hook is needed; the force-scoped pump already runs.
- [tests/smoke_rcon.ps1](tests/smoke_rcon.ps1) is the launcher. It reads `factorioPath` from [.vscode/settings.json](.vscode/settings.json) and the mods directory from [.vscode/launch.json](.vscode/launch.json)'s `modsPath` (the same value factoriomod-debug uses — not hardcoded), starts the server with `--start-server-load-scenario factory_solver/smoke_rcon --mod-directory <modsPath> --rcon-bind 127.0.0.1:<port> --rcon-password <pw>` and a minimal generated `--server-settings`, then connects over RCON. For each fixture it sends `setup`, polls `state` until terminal, and on convergence calls `check_read_side`; a `FAIL`/`ERROR` from either flips the verdict (a `SKIP` does not). The Source RCON binary framing is implemented inline with .NET sockets (no external dependency).

Runtime details:

- **Reproducible mod set.** `-Mods` (default the vanilla minimal `base flib factory_solver`) rewrites `<modsPath>/mod-list.json` to enable exactly that set and disable everything else, then restores the original in the finally block — the dev config is backed up to a `.smoke-bak` sibling, and a leftover backup from a crashed run is restored on the next startup, so the shared config is never lost. `-Mods @()` opts out (loads the dev config as-is). Pass interop or Space Age mods explicitly (e.g. `-Mods base,flib,factory_solver,space-age,quality,elevated-rails`); comma- and space-separated forms both work.
- **Steam relaunch suppression.** The Steam build of `factorio.exe` relaunches itself through Steam if not started by Steam, dropping every command-line argument in the process. The launcher works around this by setting the `SteamAppId=427520` environment variable on the child process, which makes the Steam SDK consider the run already-launched-by-Steam and skip the relaunch. The `factoriomod-debug` extension uses the same trick.
- **Clean shutdown + autosave cleanup.** The launcher quits the server cleanly over RCON (`/quit`), falling back to killing the process. A server autosaves the scenario on `/quit`, so the launcher removes the throwaway `saves/smoke_rcon.zip` afterward (same name each run, so it never accumulates, but it would otherwise clutter the in-game save list).
- **Stale lock file.** A killed run can leave `%APPDATA%/Factorio/.lock` behind. The launcher clears it on startup, but only when `Get-Process factorio` returns nothing — the lock is never yanked from a live instance.
- **Wall-clock cost.** A headless server boots without graphics (no atlas mipmaps), so the whole run — boot, both fixtures, clean quit — is on the order of ten seconds. This is still not an inner-loop check (the headless suite is); the smoke is a pre-release / pre-merge sanity gate.

Invocation: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke_rcon.ps1` (PowerShell 5.1 works; JSONC comments and trailing commas are stripped before parsing `settings.json` / `launch.json` for compatibility). Exit codes: 0 = every fixture PASS (skips are not failures), 1 = a fixture FAILed (or no response), 2 = setup error (Factorio binary not found, RCON never came up). Adding a fixture is a `{ requires, build }` entry in `manage/smoke_rcon.lua` plus its name in the launcher's `$Fixtures` — no extra boot; declare any non-dependency mods it needs in `requires` so it SKIPs cleanly on a narrower `-Mods` set.

The scenario folder is excluded from the published mod via the `package.ignore` entry in [info.json](info.json) (`scenarios/*`), alongside `gallery/*` and `tests/*`.
