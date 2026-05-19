# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Factorio 2.0 mod (`factory_solver`, see `info.json`) that acts as a recipe-chain calculator. It is **not** a stand-alone Lua program: all code runs inside Factorio's modded Lua VM, against the runtime API (`game`, `script`, `storage`, `prototypes`, `data:extend`, `defines`, ...) and the `flib` library (`__flib__/gui`, `__flib__/table`, `__flib__/dictionary`, ...). There is no npm/cargo/make and no test runner — code is exercised by running Factorio.

The headline feature is its solver: it formulates the production graph as a linear program and solves it with a primal-dual interior-point method, so factories with recipe **loops** (refining, kovarex, productivity feedback, ...) can be solved without manual unrolling. The UI superficially resembles `FactoryPlanner`, but the codebase is written from scratch — there is no shared code lineage.

## Running / debugging

Development is done through the [`justarandomgeek.factoriomod-debug`](https://marketplace.visualstudio.com/items?itemName=justarandomgeek.factoriomod-debug) VS Code extension. The three launch configurations in [.vscode/launch.json](.vscode/launch.json) all assume `modsPath` is the parent directory (`${workspaceFolder}\..`) — the working copy must therefore live alongside other mods in a `factorio_mods/` folder, not inside Factorio's actual `mods/` directory.

- **Factorio Mod Debug** — normal control-stage debug. Default choice.
- **Factorio Mod Debug (Settings & Data)** — also hooks settings + data stages; use when changing [data.lua](data.lua) or prototype loading.
- **Factorio Mod Debug (Profile)** — performance profile mode.

When launched via the debugger, `__DebugAdapter` is truthy. The code paths gated on it (in [control.lua](control.lua), [data.lua](data.lua), [manage/save.lua](manage/save.lua)) auto-enable cheat mode, skip the freeplay intro, unlock all qualities, expose hidden/unresearched recipes in the picker, and register a suite of `fs-test-*` recipes (short/long/parallel loops in [data.lua](data.lua)) used to stress the LP solver against the kind of cyclic chains that motivated the mod.

Factorio's path is configured in [.vscode/settings.json](.vscode/settings.json) — update `factorio.versions[0].factorioPath` for a non-Steam install. `Lua.workspace.library` points sumneko-lua at `E:\source\factorio_mods` so flib types resolve; adjust to wherever flib lives locally.

There is no separate build step. `info.json` has a `package` block consumed by factoriomod-debug's publish command (`stable` branch, gallery and `tests/` excluded from the upload).

## Headless testing (`tests/`)

The solver pipeline ([solver/csr_matrix.lua](solver/csr_matrix.lua), [solver/problem_generator.lua](solver/problem_generator.lua), [solver/linear_programming.lua](solver/linear_programming.lua), [solver/create_problem.lua](solver/create_problem.lua)) is **pure Lua** with no `game` / `script` / `storage` / `prototypes` dependencies. It can therefore be exercised from a standalone Lua interpreter, outside Factorio, with no debugger session and no save game. This is the recommended feedback loop for any change that touches the LP math, the CSR layer, or `create_problem`'s reachability / cost-tier logic — running the IPM in the game requires building a UI scenario and watching `on_tick`, which is slow and hard to assert on.

Prerequisite: a standalone Lua 5.2+ or LuaJIT on `PATH`. Factorio 2.0 itself runs **Lua 5.2.1**, vendored in its binary and not exposed as a CLI. For the local test harness install a separate interpreter — `winget install DEVCOM.Lua` brings in 5.4 today, which is what this scaffold was verified against; `scoop install lua` and the binaries at [luabinaries.sourceforge.net](https://luabinaries.sourceforge.net/) are equally fine. The solver code deliberately stays inside the language subset common to 5.2–5.4 / LuaJIT (`goto` / `^` / `/` returning floats / no `//` / no bitops / no integer literal coercion), so the host version does not affect what runs in-game.

Run from the repo root so the `require` paths resolve:

- `lua tests/run.lua` — runs every case file under [tests/cases/](tests/cases/), prints one line per case, exits non-zero on any failure.
- `lua tests/run.lua -v` — same, plus the solver's captured debug dumps (cost / limit / primal vectors).
- `lua tests/run.lua short_loop` — only run cases whose file name contains the given substring.

How the harness is wired (see [tests/harness.lua](tests/harness.lua) and [tests/run.lua](tests/run.lua)):

- Solver-side diagnostics go through [fs_log.lua](fs_log.lua). The runner calls `fs_log.set_sink` to route every emission into a per-case buffer and `fs_log.set_level("debug")` so nothing is filtered out during testing; the buffer is replayed only on failure (or under `-v`). `fs_log` resolves its sink dynamically on each emit, so no load-order dance with the solver is required.
- Each file in `tests/cases/` returns a list of `{ name, run }` tables. Add a new file there and register its stem in the `case_files` table at the top of [tests/run.lua](tests/run.lua) (explicit registration beats directory scanning when there's no portable `ls`).
- `harness.solve_to_completion` drives `linear_programming.M.solve` from `"ready"` through the IPM iteration loop to a terminal state (`"finished"` / `"unfinished"` / `"unbounded"` / `"unfeasible"`), matching the state machine that [control.lua](control.lua)'s `on_tick` pumps in production.

What belongs in `tests/cases/`: regressions for the solver, the CSR primitives, and translation logic that operates on plain `NormalizedProductionLine[]` / `Constraint[]` fixtures. Anything that needs `prototypes`, `storage.virtuals`, machine-speed / module / quality folding, or UI behaviour stays out — those still require running Factorio. The cost-tier constants (`slack_cost`, `elastic_cost`, `target_cost`) and the IPM epsilons (`2^-52`, `2^52`, `step_scale = 1 - tolerance`) are exactly the kind of hand-tuned values whose changes should be guarded by a test here.

## In-game smoke test (`scenarios/smoke/` + `tests/smoke.ps1`)

For the layers the headless suite cannot reach — [manage/pre_solve.lua](manage/pre_solve.lua)'s machine-speed / module / quality folding, [manage/virtual.lua](manage/virtual.lua)'s virtual-recipe generation, [manage/save.lua](manage/save.lua)'s migration paths, and the GUI lifecycle — there is a single end-to-end smoke test that boots a real Factorio with the mod loaded, constructs a minimal `Solution`, and waits for the solver pump to converge.

How the pieces fit together:

- [scenarios/smoke/control.lua](scenarios/smoke/control.lua) is a deliberately empty marker file. Scenarios run in their own Lua context with a separate `storage`, so doing the real work from there would mean either duplicating the mod code or going through `remote.call`.
- [manage/smoke.lua](manage/smoke.lua) is the real driver, living inside the mod so it shares `storage` and module state with everything else. It builds an iron-plate production line + an upper-bound constraint on the product, then polls `solution.solver_state` until terminal.
- [control.lua](control.lua) activates the driver only when `script.level.level_name == "smoke"`, so a normal load never pays for it. Chained at the end of the existing `on_player_created` and `on_tick` handlers; production flow is otherwise untouched.
- Verdicts are emitted via [fs_log](fs_log.lua) at `info`, with the marker `SMOKE PASS:` or `SMOKE FAIL:` followed by detail. Both land in `factorio-current.log` regardless of `__DebugAdapter`.
- [tests/smoke.ps1](tests/smoke.ps1) is the launcher. It reads `factorio.versions[0].factorioPath` from [.vscode/settings.json](.vscode/settings.json), launches Factorio with `--load-scenario factory_solver/smoke --mod-directory <parent>`, snapshots `factorio-current.log` size before the run, polls the appended bytes for a verdict marker, and kills the process the moment one appears (Factorio has no Lua API to terminate itself cleanly — `game.set_game_state{game_finished=true}` only triggers a victory/defeat GUI, which is more noise than help).

Runtime details worth knowing:

- **Steam relaunch suppression.** The Steam build of `factorio.exe` relaunches itself through Steam if not started by Steam, dropping every command-line argument in the process. The launcher works around this by setting the `SteamAppId=427520` environment variable on the child process, which makes the Steam SDK consider the run already-launched-by-Steam and skip the relaunch. The `factoriomod-debug` extension uses the same trick (changelog 1.1.38).
- **Stale lock file.** Every run ends with the launcher killing the Factorio process, which leaves `%APPDATA%/Factorio/.lock` behind. The launcher clears it on startup, but only when `Get-Process factorio` returns nothing — never yank the lock from under a live instance.
- **Wall-clock cost.** Factorio bootstrap (data stage + atlas mipmaps + game init) dominates: ~20 s on a warm cache for the iron-plate fixture. The solver itself converges in single-digit ticks (~150 ms). This is *not* an inner-loop check — run the headless suite for that. Treat the smoke as a pre-release / pre-merge sanity gate.

Run it via `powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke.ps1` (PowerShell 5.1 is fine; we strip JSONC trailing commas before parsing `settings.json` for compatibility). Exit codes: 0 = PASS, 1 = FAIL or no marker, 2 = setup error (Factorio binary not found, log file missing).

The scenario folder is excluded from the published mod via the `package.ignore` entry in [info.json](info.json), alongside `gallery/*` and `tests/*`.

## Architecture

### Stages

Factorio runs Lua in three stages; each stage corresponds to a different entry file:

- [data.lua](data.lua) — **data stage**. Registers the `factory-solver-toggle-main-window` input/shortcut, all `factory_solver_*` GUI styles, the `other` item-group fallback (only when `base` is absent), and `fs-test-*` debug recipes.
- [control.lua](control.lua) — **control stage** entry. Wires `script.on_init` / `on_load` / `on_configuration_changed`, per-player and per-force lifecycle events, the per-tick solver pump, and the toggle-window shortcut.
- [meta.lua](meta.lua) — **not loaded at runtime**. Pure LuaLS `---@meta` annotations defining the project's type vocabulary (`TypedName`, `Solution`, `ProductionLine`, `Constraint`, `NormalizedProductionLine`, `PlayerLocalData`, `ForceLocalData`, `SolverState`, `Virtuals`, ...). Read this first when touching unfamiliar code — almost every function elsewhere is annotated against these types.

### Logging (`fs_log.lua`)

[fs_log.lua](fs_log.lua) is a thin wrapper around Factorio's `log()` that adds severity levels (`debug` / `info` / `warn` / `error`) and a module-name prefix so the resulting `factorio-current.log` lines tell you who emitted them. Pattern:

```lua
local fs_log = require "fs_log"
local log = fs_log.for_module("solver.lp")
log.info("step %d: p=%f d=%f", step, p_criteria, d_criteria)
```

Default threshold is `info`, except under `__DebugAdapter` where it drops to `debug` — so verbose traces only flow when running through the debugger, never in a shipped save. `fs_log.set_level("debug")` changes it at runtime, `fs_log.set_sink(fn)` swaps the underlying writer (used by the test harness to capture lines into a buffer; production code should leave it alone).

The level check happens **before** `string.format`, so a filtered call only pays an integer comparison. Even so, every emit runs on every client under lockstep — keep format arguments side-effect-free and don't compute expensive values just to log them (snapshot first, then pass the snapshot). One caveat: Lua evaluates the call's argument list before the function runs, so a `log.debug("primal:\n%s", problem:dump_primal(x))`-style call still pays for the `dump_primal` call even when filtered. Guard expensive payload construction with an explicit `if` if it matters; the solver's per-solve dumps are currently rare enough that we don't bother.

### Solver pipeline (`solver/`)

The solver is the heart of the mod and the reason it exists. The pipeline is:

1. `ProductionLine[]` (user-edited) → `pre_solve.to_normalized_production_lines` in [manage/pre_solve.lua](manage/pre_solve.lua) folds in machine speed, modules, beacons, quality, productivity, fuel and pollution, producing `NormalizedProductionLine[]` with per-second amounts.
2. [solver/create_problem.lua](solver/create_problem.lua) turns those lines plus the user's `Constraint[]` into a `Problem` (see [solver/problem_generator.lua](solver/problem_generator.lua)). Each recipe becomes a primal variable; each material becomes an equivalence constraint summing to zero; **elastic** variables (`|surplus_sink|`, `|shortage_source|`, `|elastic|`) keep the LP feasible when the user's constraints are over- or under-determined, and **slack** sources/sinks (`|basic_source|`, `|final_sink|`) supply free raw materials or absorb final products. User `Constraint` rows attach a cost via `target_cost` so the optimum is pulled toward the requested production rate.
3. [solver/linear_programming.lua](solver/linear_programming.lua) implements primal-dual interior-point iteration on sparse CSR matrices ([solver/csr_matrix.lua](solver/csr_matrix.lua), which provides Hadamard ops, Cholesky decomposition and forward/backward substitution). One IPM step is performed per call; `solver_state` carries the iteration count (or one of `"ready"`, `"finished"`, `"unfinished"`, `"unbounded"`, `"unfeasible"`).
4. [control.lua](control.lua)'s `on_tick` handler calls `pre_solve.find_the_need_for_solve` once per tick, advances one IPM step, then dispatches `on_calculation_changed` down the GUI tree so result panels refresh. This means solving is **incremental and amortised across ticks** — large problems take many ticks but never block.

The CSR matrix layer is hand-rolled (no BLAS, all pure Lua) and is the most numerically delicate code in the repo. `linear_programming.M.solve` clamps `x` and `s` to `[2^-52, 2^52]` to avoid NaN propagation; `find_step` picks the largest step that keeps variables positive; the barrier is scaled by `(p_criteria + d_criteria) / (1 + p_criteria + d_criteria)`.

Three "cost tiers" are used in [solver/create_problem.lua](solver/create_problem.lua): `slack_cost = 0` (free trade), `elastic_cost = 2^10` (penalised slack to enforce balance), `target_cost = 2^20` (user-requested constraints). Keep this ordering when adding new variable classes — inverting it can make the LP prefer wrong solutions.

### State (`manage/`)

All persistent state lives under `storage` (Factorio's auto-serialised global table). **Any mod state that must survive save/load — or that must be visible to a client joining a multiplayer game in progress — has to live here.** Factorio's multiplayer uses deterministic lockstep, so anything kept in plain Lua globals (or in `local` upvalues set during runtime) exists only on the host, never gets sent to late-joining clients, and will desync the moment two players' states diverge. The official [storage docs](https://lua-api.factorio.com/latest/auxiliary/storage.html) only guarantee that `storage` is serialised across save/load; the multiplayer rationale comes from the [Factorio wiki's Desynchronization page](https://wiki.factorio.com/Desynchronization). Treat both as load-bearing: if a value matters past the current tick, it goes in `storage`, even if multiplayer is "untested" today. Top-level shape is declared in [meta.lua](meta.lua) (`Storage`):

- `storage.players[player_index]` → `PlayerLocalData` (UI prefs, presets, selected solution).
- `storage.forces[force_index]` → `ForceLocalData` (solutions, cached `relation_to_recipes` and `group_infos` invalidated by `*_needs_updating` flags).
- `storage.virtuals` → `Virtuals` (synthesised "recipes" for boilers, generators, mining drills, etc. — anything that isn't a real `LuaRecipePrototype` but needs to participate in the LP).

Putting state in `storage` is **necessary but not sufficient** for multiplayer correctness. Deterministic lockstep requires a stronger invariant: every client's `storage` must be **bit-identical at every tick**. That means every code path that writes to `storage` must itself be deterministic. Anti-patterns to avoid:

- Bare `math.random()` / `math.randomseed()` — Lua's global RNG state is per-process, so each client gets a different sequence. Use `game.create_random_generator()` (stored in `storage` so the seed survives save/load) when randomness must influence `storage`.
- `os.time()`, `os.clock()`, `os.date()`, or any wall-clock source — machines differ. Use `game.tick` instead.
- Reading `game.player` (the "local" player) and writing the result anywhere observable. `game.player` is only valid in command/console contexts and resolves differently per client. Always derive the player from event payloads (`event.player_index`) or iterate `game.players` for each-player work.
- Anything keyed off the host filesystem, the network, or `__DebugAdapter` in a save that could be loaded on a non-debug client. Debug-only paths must be gated so they cannot mutate `storage` in shipped saves.
- Iterating data structures whose order is non-deterministic. Factorio's Lua keeps `pairs()` stable for integer-indexed and string-indexed tables, but never rely on it for tables keyed by `LuaObject` references — sort by a stable key first.

When in doubt: if a value written to `storage` could differ between two clients running the same tick on the same input, that's a latent desync. Audit the write site, not just the read site.

[manage/save.lua](manage/save.lua) is the schema authority. Its `init_*` / `reinit_*` functions are the migration path: `on_configuration_changed` (mod update / config change / research finished / research reversed) routes through `reinit_force_data`, which walks every `Solution`'s `production_lines` and `constraints` running [manage/typed_name.lua](manage/typed_name.lua)'s `typed_name_migration` on every `TypedName` field. The historical `module_names` → `module_typed_names` and `beacon_name` → `beacon_typed_name` migrations live there as concrete examples — follow the same pattern for any new persistent field.

`on_load` calls `resetup_force_data_metatable` to reattach the `Problem` metatable, because metatables don't survive save/load. Anything you save into `storage` that needs methods must do the same.

`TypedName = { type, name, quality }` is the universal handle for "something that can appear in a recipe slot" — items, fluids, recipes, machines, virtual materials, virtual recipes. [manage/typed_name.lua](manage/typed_name.lua) is the only module that knows how to map a `TypedName` to a prototype, sprite, tooltip, or LP variable name (`typed_name_to_variable_name` produces the `"type/name/quality"` strings used as keys throughout the solver).

[manage/accessor.lua](manage/accessor.lua) holds prototype-derived math primitives: crafting speed, energy usage, productivity caps, fuel amount per second, quality level — anything that reads a `LuaEntityPrototype` / `LuaRecipePrototype` to produce a single number. [manage/pre_solve.lua](manage/pre_solve.lua) is the designated place to **aggregate** those primitives: it folds raw Factorio data (machines, modules, beacons, quality, productivity, fuel, pollution) into `NormalizedProductionLine[]` with per-second amounts before the LP sees it. New pre-LP transformation logic belongs here, not in the UI — keep the UI free of prototype math so it only reads the already-normalized values.

### GUI (`ui/`)

Built on `flib_gui`. [fs_util.lua](fs_util.lua) wraps it with helpers that the rest of the codebase relies on:

- `fs_util.add_gui(parent, def, append_tags)` adds a subtree and dispatches a synthetic `on_added` event down it, so handlers can do init work at construction time.
- `fs_util.dispatch_to_subtree(root, event_name, data?)` walks the subtree DFS and synthesises events. The solver pump uses this to fire `on_calculation_changed` after each IPM step.
- `fs_util.find_upper(start, name)` / `follow_upper` walk parent links — used by handlers to locate the enclosing window/panel rather than capturing closures.

[ui/main_window.lua](ui/main_window.lua) is a static `flib.GuiElemDef` tree composing [solution_selector](ui/solution_selector.lua), [common_settings](ui/common_settings.lua), [solution_editor](ui/solution_editor.lua), [solution_settings](ui/solution_settings.lua), [solution_results](ui/solution_results.lua). Adding a new panel = require the module from `main_window.lua` and slot it into the tree. Handler functions are registered on the def via `handler = { [defines.events.on_gui_click] = ... }` and resolved at registration time by `flib_gui.handle_events()` (called at the bottom of [control.lua](control.lua)).

When any save mutation must trigger a recompute, set `solution.solver_state = "ready"` (see the `new_*` / `delete_*` / `update_*` functions in [manage/save.lua](manage/save.lua)). The on_tick pump will pick it up next tick.

**The GUI's two-layer model under lockstep.** GUI state in this mod lives on two distinct planes, and confusing them is the fastest way to introduce a desync:

- **Logical UI state** (which window is open, selected solution, panel widths, filter text, …) lives in `storage.players[player_index]`. Because `storage` is replicated, **every client holds every player's logical UI state**, even though only the owning player ever sees that UI. GUI event handlers (`on_gui_click`, `on_gui_text_changed`, …) fire on **every** client in lockstep and mutate `storage.players[event.player_index]` identically everywhere.
- **The actual `LuaGuiElement` tree** lives under `game.players[i].gui.*`. The tree itself (its structure, its property values, including `tags`) **is part of the saved simulation state**, so **every client holds a full copy of every player's GUI tree** — not just its own local player's. Open windows survive save/load and a joining client receives them via the save. Only the rendering layer is local: each client visually draws only its own local player's tree, but the data structures for all players must exist and stay bit-identical on every client. What is **per-VM and must never go into `storage`** is the *Lua handle* to an element (the `LuaGuiElement` reference value), its runtime-only `element_index`, and any other identity that may differ between processes. Read/write the element's data freely in handlers, but never persist the reference itself or derive `storage` values from it.

**`LuaGuiElement.tags` is a third persistence channel — use it as a hint, not as truth.** Tags survive save/load and are part of the GUI tree's persisted state (this is exactly what `flib_gui` relies on for handler dispatch, which is why `flib_gui.handle_events()` re-binds on every load at the bottom of [control.lua](control.lua)). Constraints to keep in mind ([Tags concept docs](https://lua-api.factorio.com/latest/concepts/Tags.html)):

- Values must be `string` / `boolean` / `number` / `table`. No functions. No `LuaObject` references.
- Tags are returned as a snapshot — in-place mutation does **not** propagate. To change a tag, reassign the whole table: `element.tags = { ... }`.
- Nested tables with non-sequence numeric keys (gaps, or not starting at 1) get their keys coerced to strings on round-trip. Avoid sparse arrays inside tags.
- Operational rule for this codebase: `storage` is the **source of truth** for solver and solution state; tags are a lightweight hint carrying just enough identity (IDs, indices, kind discriminators) for a handler to look the real data back up in `storage`. Don't duplicate large state into tags, and don't let `storage` and tags hold diverging copies of the same fact.

Rules that fall out of the two-layer model:

- In handlers, the acting player is **always** `event.player_index`. Never `game.player` (only valid in command contexts; resolves differently per client).
- GUI mutations must run unconditionally on every client. Do **not** gate `game.players[event.player_index].gui.*` writes on "is this my local player" — that condition has no meaning here and skipping the mutation on remote clients desyncs the GUI tree. Each client applies the same mutation to its own copy of that player's tree; only the rendering layer naturally restricts what shows up on screen.
- **Keep handlers light.** Because every handler runs on every client, the same work is paid N times in parallel across the session, and the slowest client gates the tick. Worse, GUI tree mutations themselves are part of the synchronized work — building a complex panel for player Alice costs every client (including Bob, Carol, …) the same construction cost, even though only Alice sees it. Don't run LP-scale or O(prototypes) computation inside a click handler — flip a flag in `storage` (e.g. `solution.solver_state = "ready"` or a `*_needs_updating` cache marker) and let the on_tick pump or the next render pass do the actual work in small slices. The incremental IPM solver and the `relation_to_recipes` / `group_infos` cache invalidation already follow this pattern; new heavy GUI features should fit the same shape.

## Known incomplete areas

Recipe loops — long the headline limitation — are now handled correctly by the reachability gating in [solver/create_problem.lua](solver/create_problem.lua) (added in 0.3.14). Virtual recipes for some generators/boilers are still incomplete per [README.md](README.md). Multiplayer is untested. The version history around loops (0.3.7 spreading gain/cost across recipes, 0.3.10 fixing large product/ingredient counts, 0.3.12 reintroducing elastic variables to recover loop coverage lost in 0.3.7, 0.3.14 reachability gating) shows where the rough edges historically were.

## Branching model

A modified OneFlow with two long-lived branches:

- **`main`** — ongoing development toward the next release. Feature branches are cut from `main` and merge back here.
- **`stable`** — the persistent maintenance line for the most recent release. Standard OneFlow would delete hotfix branches and re-branch from a tag for the next hotfix; this repo keeps `stable` alive and reuses it instead. Bug fixes targeting the released version land on `stable` first, get tagged there, and are then merged into `main` (the historical `Merge branch 'stable' version X.Y.Z` commits trace this pattern).

When in doubt about which branch to use:

- New features, refactors, documentation updates → `main`.
- Bug fixes that should ship to users without waiting for the next release → `stable`, then merge into `main`.
- Topic / experimental work (e.g. `blog`, `inconsistency`) → its own branch cut from `main`.

The corollary: if a task is described as "fix bug X in the released version", do not start by committing to `main`. Switch to `stable` (or branch from it) first.

## Identifier namespacing (hard requirement, not style)

Factorio has **no per-mod namespacing for prototype / engine IDs**. Prototype names, custom-input names, shortcut names, virtual signal names, GUI style entries under `data.raw["gui-style"].default`, item-group and item-subgroup names, technology names, achievement names, etc. all live in a single flat namespace shared with the base game and every other loaded mod. Two mods registering the same name conflict at the data stage — silently overwriting each other in the worst case, hard-erroring at load in the best. Mod-name-prefixed IDs are the only defence.

This mod uses the prefix **`factory_solver_` for underscored identifiers and `factory-solver-` for hyphenated prototype names**. Concretely:

- **`factory-solver-…`** (hyphen): `custom-input` and `shortcut` prototype names — e.g. `factory-solver-toggle-main-window`. Any new shortcut, input binding, custom event, virtual signal, item group, technology, recipe, item, fluid, entity, or other prototype registered in [data.lua](data.lua) must carry this prefix. The `fs-test-*` debug recipes follow a shortened form of the same convention because they're debug-only — keep new shipped prototypes on the full prefix.
- **`factory_solver_…`** (underscore): GUI style names registered into `data.raw["gui-style"].default`, since style keys use underscores by convention.
- **No prefix needed**: anything that is *not* a global engine ID — Lua module names under `require`, function names, fields on `storage`, fields on `meta.lua` types, internal table keys. Those are scoped by Lua / by `storage`'s per-mod table and cannot collide with other mods.

When in doubt: if the identifier ends up as a string the Factorio engine looks up across all loaded mods (data stage prototype, event ID, style key), prefix it. If it's purely a Lua-internal name, don't bother.

## Style conventions to preserve

- All Lua modules return a single `M` table (`local M = {} ... return M`).
- Public functions carry LuaLS `---@param` / `---@return` annotations referencing types from [meta.lua](meta.lua). Keep them in sync — the project leans on sumneko-lua for safety since there is no test suite.
- Numeric epsilons and cost tiers in the solver are hand-tuned; if you change them, run the `fs-test-*` debug recipes (short/long/parallel loops) to confirm the LP still converges.
