# CLAUDE.md

This is a Factorio 2.0 mod. Everything you need to work on the code lives in three files — read them in order:

1. **[README.md](README.md)** — what the mod does, what's shipped, MP warning.
2. **[changelog.txt](changelog.txt)** — release history. The most recent entries are the best reference for "what's the current state of feature X".
3. **[CONTRIBUTOR.md](CONTRIBUTOR.md)** — development environment, the headless / smoke test layout, architecture (logging / solver pipeline / state / GUI), branching model, and design principles. Everything not in README / changelog.

The reason the solver exists (LP + interior-point method, so recipe **loops** like refining / kovarex / productivity feedback / quality recycling solve without manual unrolling) drives most architectural choices documented in CONTRIBUTOR.md — keep this in mind while reading it.

A few habits that make working on this codebase smoother:

- **Use the headless suite (`lua tests/run.lua`) as your inner loop** for any change to `solver/` or `create_problem.lua`. Don't ask the user to boot Factorio just to validate solver math — that's what the suite exists to avoid. Factorio is needed only for `manage/pre_solve.lua` folding, virtuals, migrations, and GUI; defer those checks to the smoke test or a manual run.
- **Don't touch `info.json`'s `version` field** unless asked. It's intentionally drift-managed by the maintainer; migrations are exercised through `on_configuration_changed`, not version bumps you make.
- **Confirm the branch before committing.** Bug fixes targeting the released version go to `stable` first, not `main` — see CONTRIBUTOR.md's "Branching model".

## Working with the Factorio API

Four principles that override anything you think you know about the API surface:

- **Prototype definitions and the runtime API don't share names or structure.** Data-stage prototype tables (`data:extend{...}`) and runtime `LuaXxxPrototype` objects evolved largely independently; a field present on one side may be renamed, absent, or shaped differently on the other. Confirm which stage you're in before trusting a field name.
- **The API surface changes often.** Don't rely on training-data recall for what exists or what it returns. Check [lua-api.factorio.com/latest](https://lua-api.factorio.com/latest/) (or the version-specific docs) for whatever method you're about to call.
- **Runtime methods are always callable, but unsupported prototypes return `nil`.** A method declared on `LuaEntityPrototype` (etc.) does not throw when invoked on a prototype that logically doesn't support the feature — it returns `nil` regardless of what the docs imply. Guard the return value, not the call site.
- **Accessing a non-existent identifier on a runtime object throws.** Unlike plain Lua tables, runtime objects raise an error when you index a field that doesn't exist on that specific subtype. When working with union-typed values (a field that could be one of several `LuaXxxPrototype` variants, for example), discriminate the type first (`proto.type == "..."` checks, `pcall`, etc.) before touching subtype-specific fields.

## Runtime API gotchas

Specific cases of the above that you'd plausibly miss from the docs alone. Experienced Factorio modders generally already know these; you don't.

- **`quality_affects_*` flags are 2.0.77 (experimental) only.** `lua-api.factorio.com/latest` documents `LuaEntityPrototype.quality_affects_energy_usage`, `crafting_speed_quality_multiplier`, etc. as readable — but on stable Factorio (≤ 2.0.76) reading them throws. Anything compiled into this mod must restrict itself to APIs available since 2.0.69 (the long-lived stable). To detect quality scaling at runtime in a stable-safe way, compare `get_max_energy_usage("normal") vs get_max_energy_usage("legendary")` — engine-side behaviour for scaled entities is uniformly `default_multiplier`. The `accessor.lua` `get_virtual_recipe_rates` family already follows this rule by trusting the `get_*(quality)` return value unconditionally.
- **Temperature sentinels are FLT, not nil.** `Ingredient.minimum_temperature` / `maximum_temperature` come back as `±3.4028234663853e+38` (single-precision FLT_MIN / FLT_MAX) when the prototype hasn't set a bound, **not** `nil`. (`Product.temperature` is asymmetric and does return `nil`.) Always clamp against `proto.default_temperature` / `proto.max_temperature` when consuming these; `raw_ingredient_to_amount` in [manage/accessor.lua](manage/accessor.lua) is the one place that already does, so route new readers through it. As a related quirk, `default_temperature` is stored single-precision — a fluid declared at `0.01` reads back as `0.0099999997764826`, so use `%g` for display.
- **Some "methods" are actually bound functions — call them with `.`, not `:`.** `LuaItemPrototype.get_durability(quality)` is the canonical case: indexing the prototype with `get_durability` returns a closure with `self` already bound, so `item_proto:get_durability(quality)` puts `item_proto` in the quality slot and fails with `Invalid QualityID`. The LuaCATS type stub also signs it without `self`, and `redundant-parameter` warnings are the tell. Pass quality as a `LuaQualityPrototype` (resolved via `prototypes.quality[name]`) rather than a string — string `QualityID` is documented but unreliable in practice. Guard `"unknown-quality"` and other sentinel keys before that lookup.
- **Fluid throughput getter naming diverges from the data stage.** Generators expose `entity.fluid_usage_per_tick` as a static property (no quality), fusion-reactor and fusion-generator have **`entity.get_fluid_usage_per_tick(quality?)`** as a method, and the data-stage field `max_fluid_usage` is **not** runtime-readable — touching it throws `LuaEntityPrototype doesn't contain key max_fluid_usage`. Thrusters are outside this getter family entirely; read `entity.max_performance.fluid_usage` (and `.fluid_volume`, `.effectivity`) directly, then apply the `1 + 0.3·level` quality multiplier via `acc.get_crafting_speed`'s fallback rather than special-casing. Rule of thumb: data-stage `max_*` fields usually map to runtime `get_max_*()` methods, but not always — confirm before reading.

## Multiplayer determinism

Factorio's multiplayer is deterministic lockstep, so the invariant for `storage` is bit-identity across every client at every tick. Experienced Factorio modders already work to this; you don't. A `storage` write whose value can differ between two clients running the same tick on the same input is a latent desync, even when the read site looks innocent — both write sites and read sites matter. The non-deterministic write sites that have historically broken this:

- Bare `math.random()` / `math.randomseed()`. Lua's global RNG state is per-process, so each client gets a different sequence. The codebase uses `game.create_random_generator()` (stored in `storage` so the seed survives save/load) when randomness influences `storage`.
- Any wall-clock source (`os.time`, `os.clock`, `os.date`, ...). `game.tick` is used instead.
- Reading `game.player` (the "local" player) and writing the result anywhere observable. `game.player` is only valid in command/console contexts and resolves differently per client; players are derived from event payloads (`event.player_index`) or via iteration over `game.players`.
- Anything keyed off the host filesystem, the network, or `__DebugAdapter` in a save that could be loaded on a non-debug client. Debug-only paths are gated so they can't mutate `storage` in shipped saves.
- Iterating tables keyed by `LuaObject` references without first sorting by a stable key — that order is non-deterministic across clients.

### GUI under lockstep

GUI state in this mod lives on two distinct planes; confusing them is the fastest way to introduce a desync:

- **Logical UI state** (which window is open, selected solution, panel widths, filter text, …) lives in `storage.players[player_index]`. Because `storage` is replicated, every client holds every player's logical UI state, even though only the owning player ever sees that UI. GUI event handlers (`on_gui_click`, `on_gui_text_changed`, …) fire on every client in lockstep and mutate `storage.players[event.player_index]` identically everywhere.
- **The actual `LuaGuiElement` tree** lives under `game.players[i].gui.*`. The tree itself (its structure, its property values, including `tags`) is part of the saved simulation state, so every client holds a full copy of every player's GUI tree — not just its own local player's. Open windows survive save/load and a joining client receives them via the save. Only the rendering layer is local: each client visually draws only its own local player's tree, but the data structures for all players exist and stay bit-identical on every client. The per-VM data that doesn't go into `storage` is the *Lua handle* to an element (the `LuaGuiElement` reference value), its runtime-only `element_index`, and any other identity that may differ between processes. Element data is read and written freely in handlers; references themselves are never persisted, and `storage` values are not derived from them.

`LuaGuiElement.tags` is a third persistence channel — treated as a hint, not as truth. Tags survive save/load and are part of the GUI tree's persisted state (which is what `flib_gui` relies on for handler dispatch, hence the `flib_gui.handle_events()` re-bind on every load at the bottom of [control.lua](control.lua)). Constraints from the [Tags concept docs](https://lua-api.factorio.com/latest/concepts/Tags.html):

- Values are `string` / `boolean` / `number` / `table`. No functions. No `LuaObject` references.
- Tags are returned as a snapshot — in-place mutation does **not** propagate; changing a tag means reassigning the whole table: `element.tags = { ... }`.
- Nested tables with non-sequence numeric keys (gaps, or not starting at 1) get their keys coerced to strings on round-trip; sparse arrays inside tags are avoided.
- Operational rule in this codebase: `storage` is the source of truth for solver and solution state; tags hold just enough identity (IDs, indices, kind discriminators) for handlers to look the real data back up. Large state isn't duplicated into tags, and `storage` and tags don't hold diverging copies of the same fact.

Consequences of the two-layer model:

- The acting player in a handler is `event.player_index`. `game.player` is only valid in command contexts and resolves differently per client.
- GUI mutations run unconditionally on every client. Gating `game.players[event.player_index].gui.*` writes on "is this my local player" would desync the GUI tree, because the condition has no meaning here — each client applies the same mutation to its own copy of that player's tree, and only the rendering layer naturally restricts what shows up on screen.
- **Handlers stay light.** Every handler runs on every client, so the same work is paid N times in parallel across the session, and the slowest client gates the tick. GUI tree mutations themselves are part of that synchronized work: building a complex panel for player Alice costs every client (including Bob, Carol, …) the same construction cost, even though only Alice sees it. LP-scale or O(prototypes) computation in click handlers is therefore avoided — handlers flip a flag in `storage` (e.g. `solution.solver_state = "ready"` or a `*_needs_updating` cache marker) and defer the actual work to the on_tick pump or the next render pass. The incremental IPM solver and the `relation_to_recipes` / `group_infos` cache invalidation already follow this shape.

## Identifier namespacing (hard requirement, not style)

Factorio has **no per-mod namespacing for prototype / engine IDs**. Prototype names, custom-input names, shortcut names, virtual signal names, GUI style entries under `data.raw["gui-style"].default`, item-group and item-subgroup names, technology names, achievement names, etc. all live in a single flat namespace shared with the base game and every other loaded mod. Two mods registering the same name conflict at the data stage — silently overwriting each other in the worst case, hard-erroring at load in the best. Mod-name-prefixed IDs are the only defence.

This mod uses the prefix **`factory_solver_` for underscored identifiers and `factory-solver-` for hyphenated prototype names**. Concretely:

- **`factory-solver-…`** (hyphen): `custom-input` and `shortcut` prototype names — e.g. `factory-solver-toggle-main-window`. Any new shortcut, input binding, custom event, virtual signal, item group, technology, recipe, item, fluid, entity, or other prototype registered in [data.lua](data.lua) must carry this prefix. The `fs-test-*` debug recipes follow a shortened form of the same convention because they're debug-only — keep new shipped prototypes on the full prefix.
- **`factory_solver_…`** (underscore): GUI style names registered into `data.raw["gui-style"].default`, since style keys use underscores by convention.
- **No prefix needed**: anything that is *not* a global engine ID — Lua module names under `require`, function names, fields on `storage`, fields on `meta.lua` types, internal table keys. Those are scoped by Lua / by `storage`'s per-mod table and cannot collide with other mods.

## Loose conventions (not strictly enforced)

The project hasn't formalised a style guide, but these patterns are pervasive enough that new code should match them unless there's a reason not to:

- All Lua modules return a single `M` table (`local M = {} ... return M`).
- Public functions carry LuaCATS `---@param` / `---@return` annotations referencing types from [meta.lua](meta.lua). Keep them in sync — the project leans on sumneko-lua for type safety across the codebase that the headless suite doesn't cover. Any `---@`-prefixed annotation in this codebase is LuaCATS, consumed by sumneko-lua specifically; do not assume compatibility with other Lua annotation tools that happen to share similar syntax.
- Numeric epsilons and cost tiers in the solver are hand-tuned; if you change them, run the headless suite (`lua tests/run.lua`) first to confirm the LP still converges, and use the in-game `fs-test-*` debug recipes (short/long/parallel loops) as an additional sanity path.
- **Lint suppression policy.** Don't sprinkle `---@diagnostic disable: <code>` to silence warnings — the directive's scope extends to EOF, which is broader than it looks. Prefer leaving a known-false-positive warning visible (the `flib.GuiElemDef` discriminated-union `assign-type-mismatch "string"→"button"` noise is the standing example) over scattering `disable-next-line` across many sites. Real type bugs (`need-check-nil`, fixable `param-type-mismatch`, declarable `undefined-global`) should be fixed at the source; environment issues (`undefined-doc-name` from missing library paths) should be fixed in settings. Blanket suppression hides real bugs that land later.
- **Don't fix vanilla data inconsistencies.** Vanilla and Space Age prototypes have small mismatches (item marked `hidden` while its recipe isn't, etc.). Don't patch them unless they're concretely breaking factory_solver — once you start, similar inconsistencies surface endlessly, and the line between "factory_solver bug" and "Factorio quirk" blurs. Note the observation, leave the data alone.
