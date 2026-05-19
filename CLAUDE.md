# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Factorio 2.0 mod (`factory_solver`, see `info.json`) that acts as a recipe-chain calculator. It is **not** a stand-alone Lua program: all code runs inside Factorio's modded Lua VM, against the runtime API (`game`, `script`, `storage`, `prototypes`, `data:extend`, `defines`, ...) and the `flib` library (`__flib__/gui`, `__flib__/table`, `__flib__/dictionary`, ...). There is no npm/cargo/make and no test runner — code is exercised by running Factorio.

The headline feature, and the reason this mod was forked off `FactoryPlanner`, is its solver: it formulates the production graph as a linear program and solves it with a primal-dual interior-point method, so factories with recipe **loops** (refining, kovarex, productivity feedback, ...) can be solved without manual unrolling.

## Running / debugging

Development is done through the [`justarandomgeek.factoriomod-debug`](https://marketplace.visualstudio.com/items?itemName=justarandomgeek.factoriomod-debug) VS Code extension. The three launch configurations in [.vscode/launch.json](.vscode/launch.json) all assume `modsPath` is the parent directory (`${workspaceFolder}\..`) — the working copy must therefore live alongside other mods in a `factorio_mods/` folder, not inside Factorio's actual `mods/` directory.

- **Factorio Mod Debug** — normal control-stage debug. Default choice.
- **Factorio Mod Debug (Settings & Data)** — also hooks settings + data stages; use when changing [data.lua](data.lua) or prototype loading.
- **Factorio Mod Debug (Profile)** — performance profile mode.

When launched via the debugger, `__DebugAdapter` is truthy. The code paths gated on it (in [control.lua](control.lua), [data.lua](data.lua), [manage/save.lua](manage/save.lua)) auto-enable cheat mode, skip the freeplay intro, unlock all qualities, expose hidden/unresearched recipes in the picker, and register a suite of `fs-test-*` recipes (short/long/parallel loops in [data.lua](data.lua)) used to stress the LP solver against the kind of cyclic chains that motivated the mod.

Factorio's path is configured in [.vscode/settings.json](.vscode/settings.json) — update `factorio.versions[0].factorioPath` for a non-Steam install. `Lua.workspace.library` points sumneko-lua at `E:\source\factorio_mods` so flib types resolve; adjust to wherever flib lives locally.

There is no separate build step. `info.json` has a `package` block consumed by factoriomod-debug's publish command (`stable` branch, gallery excluded from the upload).

## Architecture

### Stages

Factorio runs Lua in three stages; each stage corresponds to a different entry file:

- [data.lua](data.lua) — **data stage**. Registers the `factory-solver-toggle-main-window` input/shortcut, all `factory_solver_*` GUI styles, the `other` item-group fallback (only when `base` is absent), and `fs-test-*` debug recipes.
- [control.lua](control.lua) — **control stage** entry. Wires `script.on_init` / `on_load` / `on_configuration_changed`, per-player and per-force lifecycle events, the per-tick solver pump, and the toggle-window shortcut.
- [meta.lua](meta.lua) — **not loaded at runtime**. Pure LuaLS `---@meta` annotations defining the project's type vocabulary (`TypedName`, `Solution`, `ProductionLine`, `Constraint`, `NormalizedProductionLine`, `PlayerLocalData`, `ForceLocalData`, `SolverState`, `Virtuals`, ...). Read this first when touching unfamiliar code — almost every function elsewhere is annotated against these types.

### Solver pipeline (`solver/`)

The solver is the heart of the mod and the reason it exists. The pipeline is:

1. `ProductionLine[]` (user-edited) → `pre_solve.to_normalized_production_lines` in [manage/pre_solve.lua](manage/pre_solve.lua) folds in machine speed, modules, beacons, quality, productivity, fuel and pollution, producing `NormalizedProductionLine[]` with per-second amounts.
2. [solver/create_problem.lua](solver/create_problem.lua) turns those lines plus the user's `Constraint[]` into a `Problem` (see [solver/problem_generator.lua](solver/problem_generator.lua)). Each recipe becomes a primal variable; each material becomes an equivalence constraint summing to zero; **elastic** variables (`|surplus_sink|`, `|shortage_source|`, `|elastic|`) keep the LP feasible when the user's constraints are over- or under-determined, and **slack** sources/sinks (`|basic_source|`, `|final_sink|`) supply free raw materials or absorb final products. User `Constraint` rows attach a cost via `target_cost` so the optimum is pulled toward the requested production rate.
3. [solver/linear_programming.lua](solver/linear_programming.lua) implements primal-dual interior-point iteration on sparse CSR matrices ([solver/csr_matrix.lua](solver/csr_matrix.lua), which provides Hadamard ops, Cholesky decomposition and forward/backward substitution). One IPM step is performed per call; `solver_state` carries the iteration count (or one of `"ready"`, `"finished"`, `"unfinished"`, `"unbounded"`, `"unfeasible"`).
4. [control.lua](control.lua)'s `on_tick` handler calls `pre_solve.find_the_need_for_solve` once per tick, advances one IPM step, then dispatches `on_calculation_changed` down the GUI tree so result panels refresh. This means solving is **incremental and amortised across ticks** — large problems take many ticks but never block.

The CSR matrix layer is hand-rolled (no BLAS, all pure Lua) and is the most numerically delicate code in the repo. `linear_programming.M.solve` clamps `x` and `s` to `[2^-52, 2^52]` to avoid NaN propagation; `find_step` picks the largest step that keeps variables positive; the barrier is scaled by `(p_criteria + d_criteria) / (1 + p_criteria + d_criteria)`.

Three "cost tiers" are used in [solver/create_problem.lua](solver/create_problem.lua): `slack_cost = 0` (free trade), `elastic_cost = 2^10` (penalised slack to enforce balance), `target_cost = 2^20` (user-requested constraints). Keep this ordering when adding new variable classes — inverting it can make the LP prefer wrong solutions.

### State (`manage/`)

All persistent state lives under `storage` (Factorio's auto-serialised global table). Top-level shape is declared in [meta.lua](meta.lua) (`Storage`):

- `storage.players[player_index]` → `PlayerLocalData` (UI prefs, presets, selected solution).
- `storage.forces[force_index]` → `ForceLocalData` (solutions, cached `relation_to_recipes` and `group_infos` invalidated by `*_needs_updating` flags).
- `storage.virtuals` → `Virtuals` (synthesised "recipes" for boilers, generators, mining drills, etc. — anything that isn't a real `LuaRecipePrototype` but needs to participate in the LP).

[manage/save.lua](manage/save.lua) is the schema authority. Its `init_*` / `reinit_*` functions are the migration path: `on_configuration_changed` (mod update / config change / research finished / research reversed) routes through `reinit_force_data`, which walks every `Solution`'s `production_lines` and `constraints` running [manage/typed_name.lua](manage/typed_name.lua)'s `typed_name_migration` on every `TypedName` field. The historical `module_names` → `module_typed_names` and `beacon_name` → `beacon_typed_name` migrations live there as concrete examples — follow the same pattern for any new persistent field.

`on_load` calls `resetup_force_data_metatable` to reattach the `Problem` metatable, because metatables don't survive save/load. Anything you save into `storage` that needs methods must do the same.

`TypedName = { type, name, quality }` is the universal handle for "something that can appear in a recipe slot" — items, fluids, recipes, machines, virtual materials, virtual recipes. [manage/typed_name.lua](manage/typed_name.lua) is the only module that knows how to map a `TypedName` to a prototype, sprite, tooltip, or LP variable name (`typed_name_to_variable_name` produces the `"type/name/quality"` strings used as keys throughout the solver).

[manage/accessor.lua](manage/accessor.lua) holds prototype-derived math: crafting speed, energy usage, productivity caps, fuel amount per second, quality level — anything that reads a `LuaEntityPrototype` / `LuaRecipePrototype` to produce a number. Keep that calculation logic out of [manage/pre_solve.lua](manage/pre_solve.lua) and the UI.

### GUI (`ui/`)

Built on `flib_gui`. [fs_util.lua](fs_util.lua) wraps it with helpers that the rest of the codebase relies on:

- `fs_util.add_gui(parent, def, append_tags)` adds a subtree and dispatches a synthetic `on_added` event down it, so handlers can do init work at construction time.
- `fs_util.dispatch_to_subtree(root, event_name, data?)` walks the subtree DFS and synthesises events. The solver pump uses this to fire `on_calculation_changed` after each IPM step.
- `fs_util.find_upper(start, name)` / `follow_upper` walk parent links — used by handlers to locate the enclosing window/panel rather than capturing closures.

[ui/main_window.lua](ui/main_window.lua) is a static `flib.GuiElemDef` tree composing [solution_selector](ui/solution_selector.lua), [common_settings](ui/common_settings.lua), [solution_editor](ui/solution_editor.lua), [solution_settings](ui/solution_settings.lua), [solution_results](ui/solution_results.lua). Adding a new panel = require the module from `main_window.lua` and slot it into the tree. Handler functions are registered on the def via `handler = { [defines.events.on_gui_click] = ... }` and resolved at registration time by `flib_gui.handle_events()` (called at the bottom of [control.lua](control.lua)).

When any save mutation must trigger a recompute, set `solution.solver_state = "ready"` (see the `new_*` / `delete_*` / `update_*` functions in [manage/save.lua](manage/save.lua)). The on_tick pump will pick it up next tick.

## Known incomplete areas

Recipe loops — long the headline limitation — are now handled correctly by the reachability gating in [solver/create_problem.lua](solver/create_problem.lua) (added in 0.3.14). Virtual recipes for some generators/boilers are still incomplete per [README.md](README.md). Multiplayer is untested. The version history around loops (0.3.7 spreading gain/cost across recipes, 0.3.10 fixing large product/ingredient counts, 0.3.12 reintroducing elastic variables to recover loop coverage lost in 0.3.7, 0.3.14 reachability gating) shows where the rough edges historically were.

## Style conventions to preserve

- All Lua modules return a single `M` table (`local M = {} ... return M`).
- Public functions carry LuaLS `---@param` / `---@return` annotations referencing types from [meta.lua](meta.lua). Keep them in sync — the project leans on sumneko-lua for safety since there is no test suite.
- GUI style names, custom-input names, and shortcut names use the `factory_solver_` / `factory-solver-` prefix consistently (underscore for Lua identifiers and GUI styles, hyphen for prototype names).
- Numeric epsilons and cost tiers in the solver are hand-tuned; if you change them, run the `fs-test-*` debug recipes (short/long/parallel loops) to confirm the LP still converges.
