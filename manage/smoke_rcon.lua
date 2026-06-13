-- RCON-driven smoke-test driver -- the single in-game smoke test. It replaced
-- the earlier per-scenario variants, which auto-ran on on_player_created and
-- reported verdicts as SMOKE PASS/FAIL markers grepped out of
-- factorio-current.log.
--
-- This driver is *pulled* from outside via a remote interface over RCON. The
-- launcher [tests/smoke_rcon.ps1](../tests/smoke_rcon.ps1) boots Factorio as a
-- dedicated server (`--start-server-load-scenario factory_solver/smoke_rcon`
-- plus `--rcon-bind`/`--rcon-password`), connects over RCON, and drives the test
-- synchronously:
--
--   /silent-command rcon.print(remote.call("factory_solver_smoke", "setup", "iron_plate"))
--   /silent-command rcon.print(remote.call("factory_solver_smoke", "state"))   -- poll until terminal
--
-- Why RCON over the old log-marker approach:
--   * synchronous, structured request/response (no log byte-offset grepping);
--   * many fixtures per boot (the expensive Factorio bootstrap is paid once).
--
-- Why a zero-player dedicated server is enough, and what it constrains:
--   * The IPM pump in control.lua's on_tick is force-scoped
--     (pre_solve.find_the_need_for_solve iterates game.forces, not players), so
--     it advances a solution to a terminal solver_state with no player
--     connected. That is the core path this driver exercises.
--   * save.new_production_line's machine-preset selection is player-scoped, so
--     fixtures instead plant the Solution table directly into the force's
--     storage and pick a machine explicitly.
--   * The read-side report.get_total_* helpers take the force's ResearchBonuses
--     directly (no player), so check_read_side exercises them here too.
--   * The GUI is deliberately out of scope. The only engine API that can
--     synthesise real GUI input -- a test player, cursor moves, clicks --
--     is LuaSimulation, which is simulation-only and, per the engine, does not
--     run a mod's control.lua unless the mod is opted in through
--     SimulationDefinition.mods. Driving the GUI that way would be a separate
--     harness built on brittle coordinate-based clicking, so it is left out.
--
-- Adding a fixture: add a `{ requires = {...}, build = function(solution) ... }`
-- entry to `fixtures` below and its name to the launcher's $Fixtures. `requires`
-- lists the mods whose prototype definitions the fixture reads; setup() returns
-- "SKIP: ..." (not a failure) when one is missing from script.active_mods, so a
-- fixture that needs Space Age is simply skipped on a vanilla mod set rather than
-- failing. The smoke's mod set is variable (tests/smoke_rcon.ps1's -Mods), so
-- guard every mod you touch this way -- including official ones (space-age /
-- quality / elevated-rails). The only names you may omit are factory_solver's
-- hard info.json dependencies (base, flib), which are always present.

local flib_table = require "__flib__/table"
local fs_log = require "fs_log"
local acc = require "manage/accessor"
local fp_codec = require "manage/factoryplanner_codec"
local helmod_codec = require "manage/helmod_codec"
local yafc_codec = require "manage/yafc_codec"
local preset = require "manage/preset"
local relation = require "manage/relation"
local report = require "manage/report"
local save = require "manage/save"
local solution_codec = require "manage/solution_codec"
local tn = require "manage/typed_name"

local log = fs_log.for_module("smoke_rcon")

local M = {}

-- The default "player" force. Forces exist independently of players, so index 1
-- is present even on a dedicated server with nobody connected.
local FORCE_INDEX = 1

-- A synthetic player index for the codec import path. The interop *_to_payload
-- converters consult a player's fuel presets (FP / Helmod omit fuel for some
-- machines), and save.init_player_data builds those presets purely from
-- prototypes + storage.virtuals -- it never touches game.players -- so a player
-- that exists only in storage is enough here. The solver / read-side paths are
-- all force-scoped and never index game.players[PLAYER_INDEX], so the absence of
-- a real connected player is harmless.
local PLAYER_INDEX = 1

-- Fixtures. Each is `{ requires = {<mod names>}, build = function(solution) }`.
-- `build` plants a Solution into the force's storage; the caller marks it
-- solver_state="ready" so the on_tick pump picks it up. `requires` drives the
-- SKIP guard in setup (see the header). Kept deliberately player-free.
local fixtures = {}

---Populate a solution with the canonical electric-furnace iron-plate line plus
---a lower bound that forces the furnace to run. Shared by the codec round-trip
---fixtures so each starts from the same known-good, solvable shape and only the
---encode/decode layer under test varies.
---@param solution Solution
local function build_iron_plate_demand(solution)
    ---@type ProductionLine
    local line = {
        recipe_typed_name = tn.create_typed_name("recipe", "iron-plate"),
        machine_typed_name = tn.create_typed_name("machine", "electric-furnace"),
        module_typed_names = {},
        affected_by_beacons = {},
    }
    flib_table.insert(solution.production_lines, line)

    ---@type Constraint
    local constraint = {
        type = "item",
        name = "iron-plate",
        quality = "normal",
        limit_type = "lower",
        limit_amount_per_second = 1,
    }
    flib_table.insert(solution.constraints, constraint)
end

---True when a payload's production_lines contain an iron-plate recipe line.
---Used as the round-trip survival check across the lossy interop codecs (FP /
---Helmod drop features but must preserve the core recipe identity).
---@param payload table
---@return boolean
local function payload_has_iron_plate(payload)
    for _, line in ipairs(payload.production_lines or {}) do
        local rtn = line.recipe_typed_name
        if rtn and rtn.name == "iron-plate" then
            return true
        end
    end
    return false
end

---Happy path: smelt iron-plate in an electric furnace (electric, so no fuel is
---needed), with an upper-bound constraint on the product. Exercises pre_solve
---folding plus the LP end to end. Base-game prototypes only, so `requires` is
---empty (base is a hard dependency, never guarded).
fixtures.iron_plate = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        ---@type ProductionLine
        local line = {
            recipe_typed_name = tn.create_typed_name("recipe", "iron-plate"),
            machine_typed_name = tn.create_typed_name("machine", "electric-furnace"),
            module_typed_names = {},
            affected_by_beacons = {},
        }
        flib_table.insert(solution.production_lines, line)

        save.new_constraint(solution, tn.create_typed_name("item", "iron-plate"))
    end,
}

---Missing-prototype fallback: a Solution pointing at machine / recipe / fuel
---names that no loaded mod provides, so the entity-unknown / recipe-unknown /
---item-unknown fallbacks in manage/typed_name.lua are exercised through a full
---solve. The names are intentionally fictional, so there is nothing to require.
fixtures.missing_prototype = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        ---@type ProductionLine
        local line = {
            recipe_typed_name = { type = "recipe", name = "fs-missing-recipe", quality = "normal" },
            machine_typed_name = { type = "machine", name = "fs-missing-machine", quality = "normal" },
            module_typed_names = {},
            affected_by_beacons = {},
            fuel_typed_name = { type = "item", name = "fs-missing-fuel", quality = "normal" },
        }
        flib_table.insert(solution.production_lines, line)

        ---@type Constraint
        local constraint = {
            type = "item",
            name = "fs-missing-product",
            quality = "normal",
            limit_type = "upper",
            limit_amount_per_second = 0.5,
        }
        flib_table.insert(solution.constraints, constraint)
    end,
}

---Virtual recipe + burner fuel + fluid temperature, end to end. iron_plate is
---an electric, item-only real recipe, so it never touches three whole branches
---of the read side and normalize: a virtual_recipe (manage/virtual.lua's
---create_boiler_virtual output, normalized via get_virtual_recipe_rates rather
---than crafting_speed), a burnt fuel ingredient (the fuel_ingredient debit in
---report.get_total_amounts), and a temperature-tagged fluid product (the fluid
---branch with [min,max] in the totals). A lower bound on the boiler recipe
---forces it to run: running it costs ~source_cost (water + coal) which is far
---below the lower bound's target_cost (2^20) elastic, so the LP genuinely
---activates the boiler instead of parking it -- the read side then folds
---non-zero steam / water / coal flow. Base game only (boiler / water / steam /
---coal), so `requires` is empty. build() asserts the virtual recipe exists up
---front so a rename or a base-game change surfaces as an ERROR rather than a
---quietly-degraded (elastic-satisfied) solve.
fixtures.boiler_steam = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        -- create_boiler_virtual keys the recipe <run>{entity}:{input fluid};
        -- the base boiler is the "boiler" entity heating "water". Assert it is
        -- present so a registry change is caught here, not hidden behind the
        -- lower bound's elastic escape hatch.
        local recipe_name = "<run>boiler:water"
        assert(storage.virtuals.recipe[recipe_name],
            "boiler virtual recipe '" .. recipe_name .. "' not registered")

        ---@type ProductionLine
        local line = {
            recipe_typed_name = tn.create_typed_name("virtual_recipe", recipe_name),
            machine_typed_name = tn.create_typed_name("machine", "boiler"),
            module_typed_names = {},
            affected_by_beacons = {},
            -- A boiler is a burner, so is_use_fuel is true and a fuel is
            -- required; coal exercises the solid-fuel ingredient path.
            fuel_typed_name = tn.create_typed_name("item", "coal"),
        }
        flib_table.insert(solution.production_lines, line)

        -- Lower-bound the boiler recipe itself (its machine-count variable),
        -- not the steam output, so the demand is independent of the boiler's
        -- exact target_temperature.
        ---@type Constraint
        local constraint = {
            type = "virtual_recipe",
            name = recipe_name,
            quality = "normal",
            limit_type = "lower",
            limit_amount_per_second = 1,
        }
        flib_table.insert(solution.constraints, constraint)
    end,
}

---Save migration: plant a *legacy-shaped* Solution -- the formats that
---predate the current schema -- then run it through save.reinit_force_data
---(the same call control.lua makes on_configuration_changed) and assert the
---migration rewrote every field before solving. This is the only fixture that
---exercises manage/save.lua's reinit_force_data + manage/typed_name.lua's
---typed_name_migration; the other fixtures build current-format data, so the
---migration branches would otherwise be dead in the smoke. Every shape below
---is a real legacy form the migration code still has a branch for:
---   * machine_typed_name.type = "virtual-machine"  -> "machine"
---   * recipe_typed_name with no quality            -> quality = "normal"
---   * line.module_names (string list)              -> line.module_typed_names
---   * affected.beacon_name / .module_names         -> *_typed_name(s)
---   * <pump>{pump}:{tile} recipe key               -> <pump>{tile}
---   * constraint with a single .temperature field  -> [T,T] range, .temperature cleared
---The asserts run inside build(), so a regressed migration surfaces as
---setup() -> "ERROR: ..." (a FAIL), not a silently-degraded solve. Base-game
---prototypes only (iron-plate / electric-furnace / speed-module / beacon /
---steam), so `requires` is empty. The migrated solution is then left solvable
---(a lower bound on iron-plate forces the furnace line to run) so the pump
---still drives it to a terminal state end to end.
fixtures.migration_legacy_shape = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        -- Legacy iron-plate line: old type tag, no quality, pre-typed-name
        -- module / beacon lists.
        ---@diagnostic disable-next-line: missing-fields
        local line = {
            recipe_typed_name = { type = "recipe", name = "iron-plate" },
            machine_typed_name = { type = "virtual-machine", name = "electric-furnace" },
            module_names = { "speed-module" },
            -- beacon_quantity predates the typed-name conversion (it has been
            -- on AffectedByBeacon since the first commit), so a real legacy
            -- entry carried it even when beacon_name / module_names were still
            -- the bare-string form. The migration deliberately only rewrites
            -- the fields whose shape changed; beacon_quantity passes through.
            affected_by_beacons = {
                { beacon_name = "beacon", beacon_quantity = 2, module_names = { "speed-module" } },
            },
        }
        flib_table.insert(solution.production_lines, line)

        -- Legacy offshore-pump line: the pre-machine-picker recipe key carried
        -- both the pump and the tile (<pump>{pump}:{tile}); reinit splits the
        -- pump out and rekeys the recipe to <pump>{tile}.
        ---@diagnostic disable-next-line: missing-fields
        local pump_line = {
            recipe_typed_name = { type = "virtual_recipe", name = "<pump>offshore-pump:water" },
            machine_typed_name = { type = "machine", name = "offshore-pump" },
            module_typed_names = {},
            affected_by_beacons = {},
        }
        flib_table.insert(solution.production_lines, pump_line)

        -- Legacy fluid constraint: the LP dropped the scalar `temperature`
        -- field for a [min,max] range; migration must lift T to [T,T]. Upper
        -- bound on steam (which nothing here produces) is trivially satisfied,
        -- so it does not perturb the solve.
        ---@diagnostic disable-next-line: missing-fields
        local steam_constraint = {
            type = "fluid",
            name = "steam",
            temperature = 165,
            limit_type = "upper",
            limit_amount_per_second = 10,
        }
        flib_table.insert(solution.constraints, steam_constraint)

        -- A real demand so the migrated solution has something to solve.
        ---@type Constraint
        local iron_constraint = {
            type = "item",
            name = "iron-plate",
            quality = "normal",
            limit_type = "lower",
            limit_amount_per_second = 1,
        }
        flib_table.insert(solution.constraints, iron_constraint)

        -- Run the exact migration control.lua runs on_configuration_changed.
        -- Force-scoped, no player -- the whole reason it is reachable headless.
        save.reinit_force_data(FORCE_INDEX)

        -- Now assert every legacy field was rewritten. Any failure raises out
        -- of build() and becomes a setup ERROR (a FAIL), pinning the migration.
        assert(line.machine_typed_name.type == "machine",
            "machine type not migrated: " .. tostring(line.machine_typed_name.type))
        assert(line.recipe_typed_name.quality == "normal",
            "recipe quality not defaulted")
        assert(line.module_names == nil and line.module_typed_names,
            "line module_names not migrated to module_typed_names")
        assert(line.module_typed_names[1] and line.module_typed_names[1].name == "speed-module",
            "migrated line module is wrong")
        local affected = line.affected_by_beacons[1]
        assert(affected.beacon_name == nil and affected.beacon_typed_name
            and affected.beacon_typed_name.name == "beacon",
            "beacon_name not migrated to beacon_typed_name")
        assert(affected.module_names == nil and affected.module_typed_names
            and affected.module_typed_names[1].name == "speed-module",
            "beacon module_names not migrated")
        assert(pump_line.recipe_typed_name.name == "<pump>water",
            "offshore-pump recipe key not rekeyed: " .. pump_line.recipe_typed_name.name)
        assert(steam_constraint.minimum_temperature == 165
            and steam_constraint.maximum_temperature == 165
            and steam_constraint.temperature == nil,
            "scalar temperature not lifted to a [T,T] range")
        assert(solution.problem == nil and solution.raw_variables == nil,
            "cached problem / warm-start not discarded by migration")
    end,
}

---Native shared-string codec round-trip: build the iron-plate solution, run it
---through solution_codec.encode -> decode (which also runs migrate_typed_names),
---assert the user-input fields survive byte-for-byte, then replace the live
---solution with the decoded payload so the pump solves the *imported* copy. The
---native codec is lossless (it only serializes name / constraints /
---production_lines), so this asserts an exact structural round-trip, unlike the
---lossy interop codecs below. Base game only.
fixtures.codec_solution_roundtrip = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        build_iron_plate_demand(solution)

        local encoded = solution_codec.encode({ solution })
        local payloads, err = solution_codec.decode(encoded)
        assert(payloads, "native decode failed: " .. tostring(err and err[1]))
        assert(#payloads == 1, "expected exactly one decoded payload, got " .. #payloads)

        local payload = payloads[1]
        assert(payload.name == solution.name, "name not preserved")
        assert(#payload.production_lines == #solution.production_lines,
            "production line count changed across round-trip")
        assert(#payload.constraints == #solution.constraints,
            "constraint count changed across round-trip")
        assert(payload_has_iron_plate(payload), "iron-plate line lost in round-trip")
        assert(payload.constraints[1].limit_type == "lower"
            and payload.constraints[1].name == "iron-plate",
            "constraint mangled across round-trip")

        -- Solve the imported copy, not the original, so the import field shapes
        -- (post-migrate_typed_names) are what reaches the solver.
        solution.constraints = payload.constraints
        solution.production_lines = payload.production_lines
    end,
}

---Frozen-solution import: a payload carrying `solved_machines` (written by the
---headless reference solver path, tests/bundle_solutions.lua --reference) must
---materialize with solver_state = "freeze" and the counts applied verbatim,
---and a frozen Solution must round-trip its counts through encode -> decode.
---All assertions run synchronously here; the frozen copy is deleted before the
---pump phase, which then just solves the ordinary iron-plate solution (the
---pump skipping "freeze" is dispatch-level: it only picks ready/calculating).
---Base game only.
fixtures.codec_frozen_import = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        build_iron_plate_demand(solution)

        -- Freeze the live solution with a synthetic count and round-trip it.
        solution.quantity_of_machines_required = { ["recipe/iron-plate/normal"] = 1.25 }
        solution.solver_state = "freeze"
        local encoded = solution_codec.encode({ solution })
        local payloads, err = solution_codec.decode(encoded)
        assert(payloads, "frozen decode failed: " .. tostring(err and err[1]))
        local payload = payloads[1]
        assert(type(payload.solved_machines) == "table"
            and payload.solved_machines["recipe/iron-plate/normal"] == 1.25,
            "solved_machines not preserved across the round-trip")

        local solutions = storage.forces[FORCE_INDEX].solutions
        local imported_name = save.import_solution(solutions, payload)
        local imported = assert(solutions[imported_name])
        assert(imported.solver_state == "freeze",
            "imported snapshot not frozen: " .. tostring(imported.solver_state))
        assert(imported.quantity_of_machines_required["recipe/iron-plate/normal"] == 1.25,
            "imported snapshot lost its counts")
        save.delete_solution(solutions, imported_name)

        -- Hand the ordinary solution to the pump phase (setup re-arms to
        -- "ready" right after build).
        solution.quantity_of_machines_required = {}
    end,
}

---Factory Planner interop round-trip: FS solution -> fp_codec.encode (FS->FP) ->
---decode -> factory_to_payload (FP->FS) -> solve. This drives the FP mapping in
---*both* directions through real Factorio (the layers the headless suite can't
---reach), which the maintainer previously had to validate by hand in-game. The
---interop codecs are intentionally lossy (FP percentage / subfloors / priority
---product have no FS equivalent and drop with a warning), so the assertion is
---"the core recipe identity survived", not byte equality. factory_to_payload
---reads the player's fuel preset, so a synthetic player is seeded first (see
---PLAYER_INDEX). Base game only.
fixtures.codec_fp_roundtrip = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        save.init_player_data(PLAYER_INDEX)
        build_iron_plate_demand(solution)

        local encoded = fp_codec.encode({ solution })
        local decoded, err = fp_codec.decode(encoded)
        assert(decoded, "FP decode failed: " .. tostring(err and err[1]))
        assert(decoded.factories and decoded.factories[1], "FP decode produced no factory")

        local payload = fp_codec.factory_to_payload(decoded.factories[1], PLAYER_INDEX)
        assert(payload_has_iron_plate(payload), "iron-plate line lost across the FP round-trip")

        solution.constraints = payload.constraints
        solution.production_lines = payload.production_lines
    end,
}

---Helmod interop round-trip: FS solution -> helmod_codec.encode (FS->Helmod,
---serpent.dump inner payload) -> decode (loadstring) -> model_to_payload
---(Helmod->FS) -> solve. Same rationale as the FP fixture; Helmod's wire format
---and conversion rules differ enough (serpent vs JSON, Model/block hierarchy,
---getTableKey-compatible keys) that it needs its own coverage. Lossy, so the
---assertion is core-recipe survival. Base game only.
fixtures.codec_helmod_roundtrip = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        save.init_player_data(PLAYER_INDEX)
        build_iron_plate_demand(solution)

        local encoded = helmod_codec.encode({ solution })
        local model, err = helmod_codec.decode(encoded)
        assert(model, "Helmod decode failed: " .. tostring(err and err[1]))

        local payload = helmod_codec.model_to_payload(model, PLAYER_INDEX)
        assert(payload_has_iron_plate(payload), "iron-plate line lost across the Helmod round-trip")

        solution.constraints = payload.constraints
        solution.production_lines = payload.production_lines
    end,
}

---Helmod import ordering: walk_blocks must take `block.children` in `index`
---ascending order (product-first), not raw `pairs()` order. A hand-built model
---stores three recipes whose `index` deliberately disagrees with their dict-key
---order, so a regression to unordered iteration surfaces here. Asserts the
---decoded production_lines come out in index order, then leaves the solution
---solvable (iron-plate demand) so the on_tick pump + check_read_side still run.
---Base game only.
fixtures.codec_helmod_import_order = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        save.init_player_data(PLAYER_INDEX)

        -- index order (copper-plate=0, iron-gear-wheel=1, iron-plate=2) is the
        -- reverse of the R1/R2/R3 id order, so the expected result only holds if
        -- walk_blocks sorts by index rather than trusting dict iteration.
        local model = {
            class = "Model",
            time = 1,
            block_root = {
                class = "Block",
                id = "block_1",
                by_product = true,
                children = {
                    R1 = { class = "Recipe", id = "R1", name = "iron-plate",
                        type = "recipe", index = 2, factory = { name = "electric-furnace" } },
                    R2 = { class = "Recipe", id = "R2", name = "copper-plate",
                        type = "recipe", index = 0, factory = { name = "electric-furnace" } },
                    R3 = { class = "Recipe", id = "R3", name = "iron-gear-wheel",
                        type = "recipe", index = 1, factory = { name = "assembling-machine-2" } },
                },
                products = {},
                ingredients = {},
            },
            blocks = {},
        }

        local payload = helmod_codec.model_to_payload(model, PLAYER_INDEX)
        local got = {}
        for _, line in ipairs(payload.production_lines) do
            got[#got + 1] = line.recipe_typed_name.name
        end
        local expected = { "copper-plate", "iron-gear-wheel", "iron-plate" }
        assert(#got == #expected,
            "expected 3 imported lines, got " .. #got)
        for i = 1, #expected do
            assert(got[i] == expected[i], string.format(
                "Helmod import order wrong at %d: expected '%s', got '%s'",
                i, expected[i], tostring(got[i])))
        end

        -- Leave it solvable so the downstream solve + read-side path still runs.
        -- The payload already carries the iron-plate line, so add only a lower
        -- bound (not build_iron_plate_demand, which would insert a duplicate
        -- iron-plate line and trip the add_objective same-name assert).
        solution.constraints = payload.constraints
        solution.production_lines = payload.production_lines
        flib_table.insert(solution.constraints, {
            type = "item",
            name = "iron-plate",
            quality = "normal",
            limit_type = "lower",
            limit_amount_per_second = 1,
        })
    end,
}

---YAFC interop round-trip: FS solution -> yafc_codec.encode (FS->YAFC, raw
---DEFLATE + base64 via the vendored LibDeflate) -> decode -> yafc_to_payload
---(YAFC->FS) -> solve. Same rationale as the FP / Helmod fixtures, but YAFC's
---wire format is the odd one out: raw DEFLATE (no zlib header), which
---helpers.decode_string cannot read, so this is the only fixture that exercises
---the LibDeflate compress/inflate path inside real Factorio. Lossy, so the
---assertion is core-recipe survival. Base game only.
fixtures.codec_yafc_roundtrip = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        save.init_player_data(PLAYER_INDEX)
        build_iron_plate_demand(solution)

        -- Put a module on the line so the round-trip exercises the ModuleTemplate
        -- shape (the real-YAFC export bug was an empty `{}` where YAFC needs `[]`).
        -- electric-furnace has module slots; "productivity-module" exists in base.
        local line = solution.production_lines[1]
        line.module_typed_names = { ["1"] = tn.create_typed_name("item", "productivity-module") }

        -- A temperatured fluid constraint must export as "Fluid.steam@500" and
        -- decode back with its temperature (YAFC keys fluid variants by @temp).
        flib_table.insert(solution.constraints,
            tn.create_typed_name("fluid", "steam", nil, 500, 500) --[[@as Constraint]])
        solution.constraints[#solution.constraints].limit_type = "lower"
        solution.constraints[#solution.constraints].limit_amount_per_second = 10

        local encoded = yafc_codec.encode({ solution })
        local page, err = yafc_codec.decode(encoded)
        assert(page, "YAFC decode failed: " .. tostring(err and err[1]))

        -- The exported link goods is YAFC's dictionary-key string form
        -- "!<target>!<quality>", and the fluid target carries the temperature
        -- suffix. (The string form is mandatory: YAFC's object-form reader is
        -- positional, so the alphabetically-sorted object we used to emit -- with
        -- quality before target -- silently failed to resolve in real YAFC.)
        local steam_goods
        for _, lk in ipairs(page.content.links or {}) do
            if lk.goods and string.find(tostring(lk.goods), "steam", 1, true) then
                steam_goods = lk.goods
            end
        end
        assert(steam_goods == "!Fluid.steam@500!normal",
            "temperatured fluid constraint did not export as !Fluid.steam@500!normal (got "
            .. tostring(steam_goods) .. ")")

        local payload = yafc_codec.yafc_to_payload(page, PLAYER_INDEX)
        assert(payload_has_iron_plate(payload), "iron-plate line lost across the YAFC round-trip")

        -- The module must survive encode (full ModuleTemplate object) -> decode.
        local imported_line
        for _, l in ipairs(payload.production_lines) do
            if l.recipe_typed_name.name == "iron-plate" then imported_line = l end
        end
        assert(imported_line and imported_line.module_typed_names
            and imported_line.module_typed_names["1"]
            and imported_line.module_typed_names["1"].name == "productivity-module",
            "module lost across the YAFC round-trip")

        -- The steam constraint must come back with its temperature.
        local steam_ok = false
        for _, c in ipairs(payload.constraints) do
            if c.name == "steam" and c.minimum_temperature == 500 and c.maximum_temperature == 500 then
                steam_ok = true
            end
        end
        assert(steam_ok, "steam@500 constraint lost its temperature across the round-trip")

        -- Hand the driver a solvable solution: keep the imported lines, but drop
        -- the synthetic steam target (no producer here) so the solve stays feasible.
        solution.production_lines = payload.production_lines
        solution.constraints = {}
        for _, c in ipairs(payload.constraints) do
            if c.name ~= "steam" then
                solution.constraints[#solution.constraints + 1] = c
            end
        end
    end,
}

-- A real YAFC-CE "ProjectPage" share string (a pyanodon nuclear sample). Decoded
-- and asserted by the yafc_real_sample fixture below. The py recipes/entities in
-- it do not resolve on a base-game mod set, but the reactor-heat row maps via the
-- base-game nuclear-reactor entity, which is the cross-tool path under test.
local YAFC_REAL_SAMPLE =
[==[inR0c+YKKMrPSk0uCUhMT+Uy0jM01zPQM+Di4gIAAAD//+1b2W7jNhT9lULPpuE4CRL7qZhBAwRo2rTNS1HMwxV1JbGhRJaLFwT5915KcpbOFHZkEU1n9CbR1LkSD5dzFz8kXNUOa3e31Zgsk98h59MblaGc0hOZ506o+g5SickkKbzIqM+CL045P4UUMD3LZtkC8sXi4uJykZ7ML8/gnHoKQqWe1w6rae25RDDMQqUbmBqqYOonz7/7bdfWvUWyfEhwo6HOkCw543GSSFHf22T5x0NSKJXR1UPiwBTodga8gVr4iikTkP7yIIXb0o+/tFfTWpkKZPI4SaBSPhhhJ3QtC2WEK6tkOXuc/Ct4YSBDdsL8gdCzNyLPIyBrtc7QYDYs9JUk+qeeaS81m53Eg57Hgz4dfKy3KKVaMw73ODi2Z/PT8+FRu+WSe5SM0+sPbiFDWtQuzL+Yplpmbcp0qawuwdEyHfxTCL7UimbP8G+upXeqGR6NRm1ENvwEejYRCT/M0MsosGez4Udc1Jm3zgiQzCq5CufN8PNRZcDAlhGQHUL1/cn5LBb0PAr0y/UZYWdvwZVR3jLgpE8iWRA1sgLs4HN9Tc09QT9NEoNcaGzVUXv9ysKvTdPBGqZVbbWXcpJkaLkROsi/XROtl+bJFwZ+aJqmfwKdgMbbEs0eE+EkeIVwq9ZopihJmxrBw2N7AMQGsw9eyEzUhW0GpWm6aoBzkBa7luu6IA0kGlXZfkDT3MnaXVtKUO4FXttqS7W+Uw7k9c9PoFgHGfwkSx0UjfWK4CQ+P+nTgiaj3t2vgPab2gWKPoVpcABLjPqEwYzFlqg0cLcjjFX3e8XcyNoe1kjFs6icWaQnMzDbkbZBFtuhbkxvwsjl5XRoFMw6CE+My2wQvvYpiJGv93GYHepwj3y9F75IfZUNabEY4yVWgpPvpSW907gfHsWX1UQLa4NPB8SeepOmwThB8VvyrSh+gwacGhXjkUvtjUGx3twBBX8qcrszlpPeV6QdSerPv12p/5CkJMqeR04K6xrPue3xhThUlwFZ0ReyrtMBH/+xc9eDg95a/LG1RBOjz7y5QV7SlOF2arAhcloiuFizZpeu6Wy9dbr0CjF/vefq0wiwTNgm6BiLt4rGYdyaj2OLeolK1dvnkGU0MUQ/GZH7AkchdBRlr1Mcjas9cvbON0XtDW7Y02Jbqb1h+/5xM4rKpem4MR7LWJdlEfyQJEtvtuiMdEIGH+PbVakDUxUtYFbqfCTp6FMrFju4Aq0ab30k6XhpYZFKNKJqizHOMvhG+FndYVy3awys/O8CK5+v89LnOQU7ox2aNXpnKBkIqVWmryxty1LSQ9XY1yt13lzPNQZX/kO2DqyM6x/uLgSl2sf0xJE0caVoOYWCQEYFgcwptr/ksL/s2bIQy2a4CSHuYiwf68/bzvdlqRKUqGNril6aQF/DZUQC/2F49Df6MihVwUI5KKXrSNVEImxNxdVjxd+eDZL05YusYS6kvKH6X0N33VkZUqtX1HwL2xT4fSeqJE1/+u9UI3k7rfQq4djefamHvUWzk1TJ8nKSqBUaQyX7Hw3ktI4/tL3obR4fg9blRlFSbXlx/vg3]==]

---Decode a real, externally-produced YAFC share string (not one this codec
---wrote) and assert the cross-tool decode path holds end-to-end: base64 +
---LibDeflate raw inflate + envelope split + JSON parse + the Mechanics-via-entity
---virtual-recipe resolution. The reactor-heat row's `Entity.nuclear-reactor`
---must resolve to factory_solver's `<run>nuclear-reactor` virtual recipe, which
---exists on the base mod set. build() asserts on the decoded payload directly
---(no solve -- the py recipes don't exist here, so the LP would be infeasible),
---then leaves the solution empty so the driver's solve step is a trivial pass.
fixtures.yafc_real_sample = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        local page, err = yafc_codec.decode(YAFC_REAL_SAMPLE)
        assert(page, "real YAFC sample decode failed: " .. tostring(err and err[1]))
        assert(page.content and type(page.content.recipes) == "table",
            "decoded YAFC page has no recipes table")

        local payload = yafc_codec.yafc_to_payload(page, PLAYER_INDEX)
        assert(#payload.production_lines > 0,
            "real YAFC sample produced no production lines")

        local found_reactor = false
        for _, line in ipairs(payload.production_lines) do
            if line.recipe_typed_name.name == "<run>nuclear-reactor" then
                found_reactor = true
                assert(line.recipe_typed_name.type == "virtual_recipe",
                    "reactor-heat row did not map to a virtual recipe")
                assert(storage.virtuals.recipe["<run>nuclear-reactor"],
                    "reactor-heat mapped to a virtual recipe that is not registered")
            end
        end
        assert(found_reactor,
            "reactor-heat Mechanics row did not resolve to <run>nuclear-reactor")

        -- The py recipes in the sample do not exist on a base mod set, so the
        -- sample's own lines are not solvable here. Hand the driver a known-good
        -- solvable solution for its solve step, the decode assertions above being
        -- this fixture's real subject.
        build_iron_plate_demand(solution)
    end,
}

---YAFC -> FS -> YAFC re-export fidelity over the real pyanodon sample. The only
---real-world factory data in the tree (YAFC_REAL_SAMPLE) carries fluids, a
---Mechanics reactor-heat row, and module-bearing rows -- and it uses YAFC's
---older *object* reference form. Importing it (yafc_to_payload) then re-exporting
---must carry the content through the object-form decode -> string-form encode
---flow: no row is silently dropped, the reactor still maps to
---Mechanics.reactor.heat, and every re-emitted reference is the order-independent
---string form (the bug class fixed in this branch). Runs on the base mod set
---because the mapping is name-level. NOTE: module survival is deliberately NOT
---asserted here -- the sample's module rows are crafted on pyanodon machines
---(automated-factory-mk02 / mixer-mk02), and YAFC's fixedCount=0 "auto-fill"
---modules expand against the owner entity's slot count, which is 0 when that
---entity is absent (base mod set). Module re-export fidelity is covered on a real
---pyanodon load by the headless YAFC probe (reexport_yafc remote function).
fixtures.yafc_real_reexport = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        local page = assert(yafc_codec.decode(YAFC_REAL_SAMPLE), "sample decode failed")
        local payload = yafc_codec.yafc_to_payload(page, PLAYER_INDEX)

        ---@type Solution
        local probe = {
            name = "yafc-reexport-probe",
            constraints = payload.constraints,
            production_lines = payload.production_lines,
            quantity_of_machines_required = {},
            solver_state = "ready",
        }
        local reexported = assert(yafc_codec.encode({ probe }), "re-encode failed")
        local page2 = assert(yafc_codec.decode(reexported), "re-export re-decode failed")
        local recipes2 = (page2.content and page2.content.recipes) or {}
        assert(#recipes2 == #payload.production_lines, string.format(
            "re-export dropped rows: imported %d, re-exported %d",
            #payload.production_lines, #recipes2))

        local found_reactor = false
        for _, r in ipairs(recipes2) do
            if r.recipe == "!Mechanics.reactor.heat!normal" then found_reactor = true end
            -- Every reference must be the dictionary-key string form.
            assert(type(r.recipe) == "string" and string.sub(r.recipe, 1, 1) == "!",
                "re-export emitted a non-string recipe ref: " .. tostring(r.recipe))
            assert(type(r.entity) == "string" and string.sub(r.entity, 1, 1) == "!",
                "re-export emitted a non-string entity ref: " .. tostring(r.entity))
        end
        assert(found_reactor, "reactor-heat row lost across the YAFC re-export")

        build_iron_plate_demand(solution)
    end,
}

---YAFC virtual-recipe export mapping: a factory_solver virtual recipe is mapped
---to YAFC's "Mechanics.*" special-recipe token on export (so it imports into
---real YAFC) and survives a round-trip back. A nuclear reactor's `<run>nuclear-
---reactor` must export as `Mechanics.reactor.heat` (YAFC's former-alias for the
---reactor-heat recipe, which YAFC merges into its type-name lookup) carried by an
---`Entity.nuclear-reactor` crafter, then decode back to `<run>nuclear-reactor`.
---Base game only.
fixtures.codec_yafc_virtual = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        save.init_player_data(PLAYER_INDEX)
        assert(storage.virtuals.recipe["<run>nuclear-reactor"],
            "reactor virtual recipe not registered -- fixture assumptions broken")

        ---@type Solution
        local probe = {
            name = "yafc-virtual-probe",
            constraints = {},
            production_lines = {
                {
                    recipe_typed_name = tn.create_typed_name("virtual_recipe", "<run>nuclear-reactor"),
                    machine_typed_name = tn.create_typed_name("machine", "nuclear-reactor"),
                    module_typed_names = {},
                    affected_by_beacons = {},
                    fuel_typed_name = tn.create_typed_name("item", "uranium-fuel-cell"),
                },
            },
            quantity_of_machines_required = {},
            solver_state = "ready",
        }

        local encoded = yafc_codec.encode({ probe })
        local page = assert(yafc_codec.decode(encoded), "probe re-decode failed")
        -- Refs export as YAFC's dictionary-key string form "!<target>!<quality>"
        -- (not the positional object form, which real YAFC mis-resolves).
        local row = page.content.recipes and page.content.recipes[1]
        assert(row and row.recipe == "!Mechanics.reactor.heat!normal",
            "reactor did not export as !Mechanics.reactor.heat!normal (got "
            .. tostring(row and row.recipe) .. ")")
        assert(row.entity == "!Entity.nuclear-reactor!normal",
            "reactor export lost its Entity.nuclear-reactor crafter (got "
            .. tostring(row.entity) .. ")")

        local payload = yafc_codec.yafc_to_payload(page, PLAYER_INDEX)
        local round_tripped = false
        for _, l in ipairs(payload.production_lines) do
            if l.recipe_typed_name.name == "<run>nuclear-reactor" then round_tripped = true end
        end
        assert(round_tripped,
            "reactor did not round-trip FS -> YAFC -> FS back to <run>nuclear-reactor")

        build_iron_plate_demand(solution)
    end,
}

-- A real YAFC 2.19 export of a single uf6 fluid. Its link goods uses the newer
-- string form "!Fluid.uf6@39!normal" (separator "!", bare quality, temperature
-- suffix) rather than the older { target, quality } object. Decoded by the
-- yafc_string_form fixture.
local YAFC_UF6_SAMPLE =
[==[inR0c+YKKMrPSk0uCUhMT+Uy0jO01DPQM+Di4gIAAAD//22PQU/DMAyFf8t8jqoNOtb1hEDabdIOuyDEwUmcEs1NqjRBTFX/Oy4DiQM3P/v5e/YEJoZMIZ+vA0ELL+hMdYyWuJINW0z2MZxRM4GCrngrni051PW62W0c1UY3uGv221292WuDd7XT4vRChTYUZgUB+4Vc3IMMftKgnYA+BwyWhJhTIQXsw2WE9nWCLkYrFawOLImVbD7e71chph5ZGNjHsiA2UnIXk8/vPbTr+U1BIuMHWigiermfFzGB88xHHyiJcsijxGHJ8SDtE141mosA1LeNkrwve7/na8I/z9zUf47xROmpeLY+dNA2CuIHpeQtPSd0WWY3l1wzz7OC0aTIfEPMXw==]==]

---Importing a YAFC 2.19 string-form good reference. The link goods
---"!Fluid.uf6@39!normal" must decode to a fluid constraint named "uf6" carrying
---temperature 39 -- exercising read_ref's "!sep!" parsing and the "@temp"
---suffix split that the object form does not cover. The uf6 fluid is py-only, so
---only the parsed shape is asserted (no prototype resolution / solve). Base only.
fixtures.yafc_string_form = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        local page, err = yafc_codec.decode(YAFC_UF6_SAMPLE)
        assert(page, "uf6 string-form decode failed: " .. tostring(err and err[1]))

        local payload = yafc_codec.yafc_to_payload(page, PLAYER_INDEX)
        local uf6
        for _, c in ipairs(payload.constraints) do
            if c.name == "uf6" then uf6 = c end
        end
        assert(uf6, "uf6 string-form link did not decode to a constraint")
        assert(uf6.type == "fluid", "uf6 constraint should be a fluid")
        assert(uf6.minimum_temperature == 39 and uf6.maximum_temperature == 39,
            "uf6 string-form link lost its @39 temperature (got "
            .. tostring(uf6.minimum_temperature) .. ")")

        build_iron_plate_demand(solution)
    end,
}

---Spent-fuel (burnt_result) crediting -- the one read-side path no other
---fixture reaches. boiler_steam burns coal (no burnt_result) and every other
---fixture is electric or fuel-less, so accessor.normalize_production_line's
---fuel_burnt_result construction and report.get_total_amounts' burnt credit
---(the spent-cell counterpart to the fuel debit) are otherwise untested. A
---nuclear reactor (base game; type "reactor", so create_reactor_virtual emits
---`<run>nuclear-reactor`) burns uranium-fuel-cell, whose burnt_result is
---depleted-uranium-fuel-cell. build() asserts the normalized line credits that
---spent cell directly (so a regressed try_get_burnt_result fails loudly here,
---not as a silently-wrong total), then a lower bound forces the reactor to run
---so the read side folds the credit through report. Base game only.
fixtures.reactor_burnt_fuel = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        local recipe_name = "<run>nuclear-reactor"
        assert(storage.virtuals.recipe[recipe_name],
            "reactor virtual recipe '" .. recipe_name .. "' not registered")
        local fuel = prototypes.item["uranium-fuel-cell"]
        assert(fuel and fuel.burnt_result,
            "uranium-fuel-cell / its burnt_result is missing -- fixture assumptions broken")

        ---@type ProductionLine
        local line = {
            recipe_typed_name = tn.create_typed_name("virtual_recipe", recipe_name),
            machine_typed_name = tn.create_typed_name("machine", "nuclear-reactor"),
            module_typed_names = {},
            affected_by_beacons = {},
            fuel_typed_name = tn.create_typed_name("item", "uranium-fuel-cell"),
        }
        flib_table.insert(solution.production_lines, line)

        -- Directly assert the non-obvious accessor wiring: a burning machine
        -- emits its fuel's burnt_result 1:1 as a dedicated normalized product.
        -- This runs pre-solve, so it pins the construction independently of the
        -- LP. (bonuses=nil: burnt_result does not depend on research.)
        local n = acc.normalize_production_line(line, nil)
        assert(n.fuel_ingredient and n.fuel_ingredient.name == "uranium-fuel-cell",
            "reactor fuel ingredient not normalized")
        assert(n.fuel_burnt_result
            and n.fuel_burnt_result.name == fuel.burnt_result.name,
            "spent fuel (burnt_result) not credited as a normalized product")

        -- Lower-bound the reactor recipe so the LP actually runs it (pulling
        -- the fuel and emitting the spent cell), driving the report burnt-credit
        -- fold under check_read_side.
        ---@type Constraint
        local constraint = {
            type = "virtual_recipe",
            name = recipe_name,
            quality = "normal",
            limit_type = "lower",
            limit_amount_per_second = 1,
        }
        flib_table.insert(solution.constraints, constraint)
    end,
}

---observe-price end-to-end through the incremental solver (manage/pre_solve.lua +
---solver/observe_price.lua). Plant the data_test bootstrap-trapped catalyst loop
----- two recipes forming a copper-plate <-> iron-gear-wheel cycle whose entry
---recipe is gated behind a large priced raw (a: copper + 2000 iron-plate -> gear,
---b: gear -> 2 copper) -- and demand copper-plate. Neither cycle material can be
---produced from zero and the 2000-iron real chain costs more than the shortage
---penalty, so a flat baseline fabricates copper-plate via |shortage_source| (an
---AVOIDABLE cheat). The shipped path drives this across ticks: the soft gate
---prices reachable shortages and the observe-price fixed point reprices the
---unreachable self-sustaining cycle so it runs instead of importing. The launcher
---polls state() until "finished" (which now spans the baseline + observe + verify
---solves), then calls check_catalyst_reclassify to assert the observe-price
---machine settled at zero cheat with the loop running -- a bare "finished" would
---also pass for a clean solve. Needs the data_test.lua synthetic recipes (always
---present in a dev checkout); build() asserts them so a missing one surfaces as
---ERROR, not a silently-degraded solve.
fixtures.catalyst_reclassify = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        assert(prototypes.recipe["fs-test-catalyst-a"] and prototypes.recipe["fs-test-catalyst-b"],
            "fs-test-catalyst-a/-b recipes missing -- data_test.lua not loaded?")

        for _, recipe in ipairs({ "fs-test-catalyst-a", "fs-test-catalyst-b" }) do
            ---@type ProductionLine
            local line = {
                recipe_typed_name = tn.create_typed_name("recipe", recipe),
                machine_typed_name = tn.create_typed_name("machine", "fs-test-catalyst-machine"),
                module_typed_names = {},
                affected_by_beacons = {},
            }
            flib_table.insert(solution.production_lines, line)
        end

        -- Demand exactly 1 copper-plate. It is trapped in the cycle (no seed) and
        -- the real chain is costlier than the shortage penalty, so pass 1 cheats
        -- and the reclassify pass has an avoidable cheat to diagnose.
        ---@type Constraint
        local constraint = {
            type = "item",
            name = "copper-plate",
            quality = "normal",
            limit_type = "equal",
            limit_amount_per_second = 1,
        }
        flib_table.insert(solution.constraints, constraint)
    end,
}

---Target rescue end-to-end through the incremental solver (manage/pre_solve.lua
---M.target_rescue_step + create_problem's target_only_objective/target_budget).
---Plant the data_test collapse loop -- boot: nothing -> copper, a: copper ->
---gear + 3000 stone, b: stone -> copper -- and demand 1 gear/s. Meeting the
---target forces ~3000 units/s of penalised surplus (~2.9x target_cost), so the
---baseline LP rationally abandons it (the all-zero tier-1 collapse: every
---recipe parked, elastic = 1). The shipped path must then run the rescue
---across ticks: stage 1 (target-only objective -> T_min = 0), then re-solve
---with the sum(elastic) <= budget row, then hand the rescued baseline to the
---observe-price machine. The launcher polls state() until "finished" and calls
---check_target_rescue -- a bare "finished" would also pass for the collapsed
---all-zero answer, so the check asserts the rescue state, the met target, and
---the running loop.
fixtures.target_rescue = {
    requires = {},
    ---@param solution Solution
    build = function(solution)
        assert(prototypes.recipe["fs-test-collapse-a"] and prototypes.recipe["fs-test-collapse-b"]
            and prototypes.recipe["fs-test-collapse-boot"],
            "fs-test-collapse-* recipes missing -- data_test.lua not loaded?")

        for _, recipe in ipairs({ "fs-test-collapse-boot", "fs-test-collapse-a", "fs-test-collapse-b" }) do
            ---@type ProductionLine
            local line = {
                recipe_typed_name = tn.create_typed_name("recipe", recipe),
                machine_typed_name = tn.create_typed_name("machine", "fs-test-collapse-machine"),
                module_typed_names = {},
                affected_by_beacons = {},
            }
            flib_table.insert(solution.production_lines, line)
        end

        ---@type Constraint
        local constraint = {
            type = "item",
            name = "iron-gear-wheel",
            quality = "normal",
            limit_type = "equal",
            limit_amount_per_second = 1,
        }
        flib_table.insert(solution.constraints, constraint)
    end,
}

---RCON entry point: clear any prior solution, build the named fixture, and hand
---it to the pump. Returns a status string the launcher reads via rcon.print --
---"OK: <solution name>", "SKIP: <detail>" (a required mod isn't loaded), or
---"ERROR: <detail>".
---@param fixture_name string
---@return string
function M.setup(fixture_name)
    local fixture = fixtures[fixture_name]
    if not fixture then
        return "ERROR: unknown fixture '" .. tostring(fixture_name) .. "'"
    end

    -- Guard: a fixture that reads prototypes from a mod which isn't loaded is
    -- skipped, not failed, so narrowing the mod set (smoke_rcon.ps1 -Mods) trims
    -- coverage instead of going red.
    for _, mod_name in ipairs(fixture.requires) do
        if not script.active_mods[mod_name] then
            return "SKIP: fixture '" .. fixture_name .. "' requires mod '" .. mod_name .. "' (not loaded)"
        end
    end

    save.init_force_data(FORCE_INDEX)
    local solutions = storage.forces[FORCE_INDEX].solutions

    -- One solution at a time: clear the previous fixture so successive setups in
    -- the same boot do not pile up and find_the_need_for_solve has exactly one
    -- candidate to converge.
    for name in pairs(solutions) do
        solutions[name] = nil
    end

    local solution_name = save.new_solution(solutions, "smoke_rcon")
    local solution = assert(solutions[solution_name])

    local ok, err = pcall(fixture.build, solution)
    if not ok then
        return "ERROR: fixture '" .. fixture_name .. "' raised: " .. tostring(err)
    end

    solution.solver_state = "ready"
    log.info("setup fixture=%s solution=%s", fixture_name, solution_name)
    return "OK: " .. solution_name
end

---RCON entry point: report the current solver_state of the single smoke
---solution as a string. The launcher polls this until it reads a terminal
---value ("finished" / "unfinished" / "singular" / "unbounded" / "unfeasible") or an ERROR.
---@return string
function M.state()
    local force_data = storage.forces[FORCE_INDEX]
    local solutions = force_data and force_data.solutions
    if not solutions then
        return "ERROR: no force data"
    end
    local _, solution = next(solutions)
    if not solution then
        return "ERROR: no solution"
    end
    return tostring(solution.solver_state)
end

---RCON entry point: exercise the read-side total helpers against the current
---solution, the path that crashed in the 0.3.13 report. report.get_total_* take
---the force-scoped ResearchBonuses directly (no player needed), so they run
---headless here. Returns "OK" or "ERROR: <detail>"; the launcher calls this once
---a fixture has converged and folds the result into the verdict.
---@return string
function M.check_read_side()
    local force_data = storage.forces[FORCE_INDEX]
    local solutions = force_data and force_data.solutions
    local _, solution = next(solutions or {})
    if not solution then
        return "ERROR: no solution"
    end

    local bonuses = force_data.research_bonuses
    local ok, err = pcall(function()
        report.get_total_amounts(bonuses, solution)
        report.get_total_power(bonuses, solution)
        report.get_total_pollution(bonuses, solution)
    end)
    if not ok then
        return "ERROR: read-side raised: " .. tostring(err)
    end
    return "OK"
end

---RCON entry point: assert the observe-price machine resolved the catalyst loop.
---The launcher calls this after the catalyst_reclassify fixture converges (a bare
---"finished" can't tell an observe-priced solve from a clean one). Asserts (a) the
---solve reached "finished", (b) the legacy two-pass did NOT run (forced_imports
---unset) and the observe-price state settled (observe_price.phase == "done"),
---(c) the converged primal carries no residual cheat (|shortage_source| /
---|elastic| all ~0), and (d) the placed loop recipes actually run rather than the
---cycle resolving to pure import. Returns "OK" or "ERROR: <detail>".
---@return string
function M.check_catalyst_reclassify()
    local force_data = storage.forces[FORCE_INDEX]
    local solutions = force_data and force_data.solutions
    local _, solution = next(solutions or {})
    if not solution then
        return "ERROR: no solution"
    end
    if solution.solver_state ~= "finished" then
        return "ERROR: solver_state is " .. tostring(solution.solver_state) .. ", not finished"
    end

    -- The shipped path runs the observe-price machine (the soft gate + the fixed
    -- point + the two-pass diagnose that cheap-imports the avoidable cheats it does
    -- not fabricate). Prove that machine ran to completion: the state exists and
    -- settled at "done".
    local op = solution.observe_price
    if not op then
        return "ERROR: observe_price state nil -- the observe-price machine never started"
    end
    if op.phase ~= "done" then
        return "ERROR: observe_price phase is " .. tostring(op.phase) .. ", not done (loop did not settle)"
    end

    -- This bootstrap-trapped loop is an import-correct case: the 2000-iron real
    -- chain costs more than importing the cycle material, so the diagnose
    -- cheap-imports it. forced_imports being non-empty proves the avoidable cheat
    -- was actually found and re-seeded -- a bare "finished" can't tell that from a
    -- clean solve. (A fabricate-correct cycle would instead show observe_price.plan
    -- set; this fixture exercises the import branch.)
    if not solution.forced_imports or next(solution.forced_imports) == nil then
        return "ERROR: forced_imports empty -- the diagnose never re-seeded the avoidable cheat"
    end

    local x = solution.raw_variables and solution.raw_variables.x or {}
    local primals = solution.problem and solution.problem.primals or {}
    local cheat = 0
    for k, v in pairs(x) do
        local p = primals[k]
        if math.abs(v) > 1e-6 and p and (p.kind == "shortage_source" or p.kind == "elastic") then
            cheat = cheat + math.abs(v)
        end
    end
    if cheat > 1e-3 then
        return "ERROR: residual cheat " .. string.format("%.4f", cheat) ..
            " -- the cycle material was neither fabricated nor cheap-imported"
    end

    return "OK"
end

---RCON entry point: assert the target rescue resolved the tier-1 collapse. The
---launcher calls this after the target_rescue fixture converges -- a bare
---"finished" can't tell the rescued answer from the collapsed all-zero one (the
---collapse IS a finished solve). Asserts (a) "finished", (b) the rescue state
---settled at "done" WITH a locked budget (a clean solve parks the sentinel with
---no budget, so the budget is the proof the rescue actually fired), (c) the
---target is met (elastic ~0 -- without the rescue it reads 1), and (d) the
---collapse loop actually runs and pays its surplus instead of parking.
---Returns "OK" or "ERROR: <detail>".
---@return string
function M.check_target_rescue()
    local force_data = storage.forces[FORCE_INDEX]
    local solutions = force_data and force_data.solutions
    local _, solution = next(solutions or {})
    if not solution then
        return "ERROR: no solution"
    end
    if solution.solver_state ~= "finished" then
        return "ERROR: solver_state is " .. tostring(solution.solver_state) .. ", not finished"
    end

    local rescue = solution.target_rescue
    if not rescue then
        return "ERROR: target_rescue state nil -- the rescue machine never started"
    end
    if rescue.phase ~= "done" then
        return "ERROR: target_rescue phase is " .. tostring(rescue.phase) .. ", not done"
    end
    if not rescue.budget then
        return "ERROR: target_rescue.budget nil -- the baseline never collapsed or stage 1 found no headroom"
    end

    local x = solution.raw_variables and solution.raw_variables.x or {}
    local primals = solution.problem and solution.problem.primals or {}
    local elastic, surplus = 0, 0
    for k, v in pairs(x) do
        local p = primals[k]
        if p and p.kind == "elastic" then elastic = elastic + math.abs(v) end
        if p and p.kind == "surplus_sink" then surplus = surplus + math.abs(v) end
    end
    if elastic > 1e-3 then
        return "ERROR: target still relaxed by " .. string.format("%.4f", elastic)
    end
    -- x is the MACHINE count (1 gear/s on a crafting_speed-0.75 machine reads
    -- 4/3), so don't pin an exact value here -- the met target is already
    -- proven exactly by the elastic check above; this asserts the loop recipe
    -- actually runs rather than the answer degenerating to pure import.
    local gear = x["recipe/fs-test-collapse-a/normal"] or 0
    if gear < 0.1 then
        return "ERROR: collapse loop not running (recipe a at " .. string.format("%.4f", gear) .. ")"
    end
    if surplus <= 1024 then
        return "ERROR: surplus " .. string.format("%.1f", surplus) ..
            " -- the >1024-unit violation bill is not being carried"
    end

    return "OK"
end

---RCON entry point: assert the force/prototype-global cache invariants that the
---solve path never exercises. Unlike check_read_side (per-solution report
---totals), this is solution-independent, so the launcher calls it once per boot.
---It builds the relation / group_infos caches (manage/relation.lua) and the
---machine / fuel presets (manage/preset.lua) and asserts their non-obvious
---contracts rather than merely that they don't raise:
---  * relation: an item burned as fuel registers its burnt_result as a product
---    of the consuming recipe (the spent-cell credit), and source/sink recipes
---    land in the dedicated External group bucket, not the Virtual one.
---  * preset: create_machine_presets resolves a (validated or sentinel) machine
---    for every recipe_category -- the invariant get_machine_preset asserts on
---    -- and get_fuel_preset dispatches by energy source: an item/heat/fluid
---    fuel machine yields a non-nil fuel, a fuel-less machine yields nil.
---Returns "OK" or "ERROR: <detail>". Base-game prototypes only.
---@return string
function M.check_force_caches()
    local ok, err = pcall(function()
        local rel = relation.create_relation_to_recipes(FORCE_INDEX)
        local groups = relation.create_group_infos(FORCE_INDEX, rel)

        -- relation (1): burnt_result registration. For any item consumed as a
        -- fuel (recipe_for_fuel non-empty) that has a burnt_result, the spent
        -- item must be registered as a product of that consumer. Base game
        -- exercises this via the nuclear-reactor virtual recipe burning
        -- uranium-fuel-cell -> depleted-uranium-fuel-cell. Generic over the mod
        -- set: any fuel-with-burnt_result that something consumes is checked.
        local checked_burnt = false
        for name, item in pairs(prototypes.item) do
            local burnt = item.burnt_result
            if burnt then
                local fuel_info = rel.item[name]
                if fuel_info and #fuel_info.recipe_for_fuel > 0 then
                    local burnt_info = rel.item[burnt.name]
                    assert(burnt_info and #burnt_info.recipe_for_burnt_result > 0,
                        "burnt_result '" .. burnt.name .. "' not registered under recipe_for_burnt_result "
                        .. "for the recipe burning '" .. name .. "'")
                    checked_burnt = true
                end
            end
        end
        log.info("check_force_caches: burnt_result path %s",
            checked_burnt and "exercised" or "absent on this mod set")

        -- relation (2): source/sink recipes are bucketed into External, never
        -- Virtual. The universal source/sink virtuals are always registered
        -- (create_source_sink_virtuals), so the External counts must be > 0.
        local external_total = 0
        for _, g in pairs(groups.external) do
            external_total = external_total + g.hidden_count + g.researched_count + g.unresearched_count
        end
        assert(external_total > 0, "no source/sink recipes landed in the External bucket")

        -- preset (1): every recipe_category resolves to a non-nil machine
        -- preset (validated craft or the unknown-entity sentinel). This is the
        -- invariant preset.get_machine_preset's assert relies on.
        local machine_presets = preset.create_machine_presets()
        for category in pairs(prototypes.recipe_category) do
            assert(machine_presets[category],
                "create_machine_presets left category '" .. category .. "' unresolved")
        end

        -- preset (2): get_fuel_preset dispatches by energy source. Seed a
        -- synthetic player for the preset tables, then check a burner machine
        -- (boiler) yields a fuel and a fuel-less machine (electric-furnace)
        -- yields nil. Guarded on prototype presence so a stripped mod set that
        -- lacks either entity skips that leg instead of failing.
        save.init_player_data(PLAYER_INDEX)
        if prototypes.entity["boiler"] then
            local boiler_fuel = preset.get_fuel_preset(PLAYER_INDEX,
                tn.create_typed_name("machine", "boiler"))
            assert(boiler_fuel, "get_fuel_preset returned nil for a burner (boiler)")
        end
        if prototypes.entity["electric-furnace"] then
            local furnace_fuel = preset.get_fuel_preset(PLAYER_INDEX,
                tn.create_typed_name("machine", "electric-furnace"))
            assert(furnace_fuel == nil, "get_fuel_preset returned non-nil for a fuel-less machine")
        end
    end)
    if not ok then
        return "ERROR: force-cache check raised: " .. tostring(err)
    end
    return "OK"
end

---Asserts that the stored fuel follows a machine change across every fuel mode,
---the bug behind acc.reconcile_fuel_for_machine / reconcile_fluid_fuel_for_machine.
---Fluid leg: a default RANGE re-derives to the new machine's acceptance range, an
---in-range single pick survives, an out-of-range one snaps, idempotent. Cross-type
---leg: switching to a heat machine pins <heat>, to a fixed-filter fluid machine
---adopts its fluid, to an item/any-fluid machine keeps an in-list fuel or signals
---needs_preset; a void machine takes no fuel. Driven off the data_test.lua synthetic
---machines, all on the fs-test-machine category (fs-test-fes-no-scale = wide steam,
---fes-window-100-300 = steam window [100,300], fs-test-cm-heat, fs-test-cm-multi-fuel,
---fs-test-fes-any-fluid, fs-test-cm-void); guarded on presence so a stripped build
---skips instead of failing. Also exercises the persisted apply_machine_clipboard path.
---Returns "OK" or "ERROR: <detail>".
---@return string
function M.check_fuel_reconciliation()
    local wide_machine = prototypes.entity["fs-test-fes-no-scale"]
    local narrow_machine = prototypes.entity["fes-window-100-300"]
    if not (wide_machine and narrow_machine) then
        log.info("check_fuel_reconciliation: data_test machines absent, skipped")
        return "OK"
    end

    local ok, err = pcall(function()
        -- The two machines' acceptance ranges, straight from the prototype.
        local wide = acc.try_get_fixed_fuel(wide_machine)
        local narrow = acc.try_get_fixed_fuel(narrow_machine)
        assert(wide and wide.type == "fluid" and wide.name == "steam",
            "wide machine fixed fuel is not steam")
        assert(narrow and narrow.type == "fluid" and narrow.name == "steam",
            "narrow machine fixed fuel is not steam")
        -- (1) wide machine has a real range straddling the narrow window.
        assert(wide.minimum_temperature ~= wide.maximum_temperature
            and wide.minimum_temperature < 100 and wide.maximum_temperature > 300,
            "wide machine steam acceptance is not a range straddling [100,300]")
        -- (2) narrow machine is exactly the fluid_box window [100,300].
        assert(narrow.minimum_temperature == 100 and narrow.maximum_temperature == 300,
            "narrow machine steam acceptance is not [100,300]")

        -- (3) the bug: a default range follows the machine change to the narrow one.
        local followed = acc.reconcile_fluid_fuel_for_machine(
            tn.create_typed_name("fluid", "steam", nil,
                wide.minimum_temperature, wide.maximum_temperature), narrow_machine)
        assert(followed.minimum_temperature == 100 and followed.maximum_temperature == 300,
            "stale range did not follow the machine change to [100,300]")

        -- (4) a deliberate in-range single pick is preserved.
        local kept = acc.reconcile_fluid_fuel_for_machine(
            tn.create_typed_name("fluid", "steam", nil, 200, 200), narrow_machine)
        assert(kept.minimum_temperature == 200 and kept.maximum_temperature == 200,
            "in-range single pick was not preserved")

        -- (5) an out-of-range single pick snaps to the machine's range.
        local snapped = acc.reconcile_fluid_fuel_for_machine(
            tn.create_typed_name("fluid", "steam", nil, 500, 500), narrow_machine)
        assert(snapped.minimum_temperature == 100 and snapped.maximum_temperature == 300,
            "out-of-range single pick did not snap to [100,300]")

        -- (6) idempotent: the machine's own range round-trips unchanged in value.
        local idem = acc.reconcile_fluid_fuel_for_machine(
            tn.create_typed_name("fluid", "steam", nil, 100, 300), narrow_machine)
        assert(idem.minimum_temperature == 100 and idem.maximum_temperature == 300,
            "reconcile is not idempotent on the machine's own range")

        -- (7) cross-type: switching between item / heat / fluid fuels in either
        -- direction updates the selection. reconcile_fuel_for_machine returns
        -- (fuel, needs_preset); the test fuels are a steam range, a coal item, and
        -- the <heat> virtual material.
        local steam_fuel = tn.create_typed_name("fluid", "steam", nil,
            wide.minimum_temperature, wide.maximum_temperature)
        local coal_fuel = prototypes.item["coal"] and tn.create_typed_name("item", "coal")
        local heat_fuel = tn.create_typed_name("virtual_material", "<heat>")

        local heat_machine = prototypes.entity["fs-test-cm-heat"]
        if heat_machine then
            for _, from in ipairs({ steam_fuel, coal_fuel }) do
                if from then
                    local f, np = acc.reconcile_fuel_for_machine(from, heat_machine)
                    assert(f and f.type == "virtual_material" and f.name == "<heat>" and not np,
                        "switch to heat machine did not pin <heat>")
                end
            end
        end

        -- fixed-filter fluid machine adopts its own fluid when fed a non-fluid fuel.
        if coal_fuel then
            local f, np = acc.reconcile_fuel_for_machine(coal_fuel, narrow_machine)
            assert(f and f.type == "fluid" and f.name == "steam"
                and f.minimum_temperature == 100 and f.maximum_temperature == 300 and not np,
                "switch from item fuel to fluid machine did not adopt steam [100,300]")
        end
        do
            local f, np = acc.reconcile_fuel_for_machine(heat_fuel, narrow_machine)
            assert(f and f.type == "fluid" and f.name == "steam" and not np,
                "switch from heat to fluid machine did not adopt the machine's fluid")
        end

        local burner = prototypes.entity["fs-test-cm-multi-fuel"]
        if burner then
            -- a fluid fuel is invalid for an item burner -> needs_preset.
            local _, np_fluid = acc.reconcile_fuel_for_machine(steam_fuel, burner)
            assert(np_fluid, "fluid fuel on an item burner did not request a preset")
            if coal_fuel then
                -- coal (chemical) is in the burner's fuel list -> kept as-is.
                local f, np = acc.reconcile_fuel_for_machine(coal_fuel, burner)
                assert(f and f.type == "item" and f.name == "coal" and not np,
                    "in-list item fuel was not kept on the burner")
            end
        end

        local anyfluid = prototypes.entity["fs-test-fes-any-fluid"]
        if anyfluid then
            -- A fuel in the machine's candidate list is kept; an item fuel is not
            -- (-> needs_preset). The any-fluid candidate set is get_any_fluid_fuels
            -- (fuel-value fluids), so sample it rather than assume a specific fluid.
            local any_fuels = acc.get_any_fluid_fuels()
            if #any_fuels > 0 then
                local sample = any_fuels[1]
                local f, np = acc.reconcile_fuel_for_machine(
                    tn.create_typed_name("fluid", sample.name), anyfluid)
                assert(f and f.type == "fluid" and f.name == sample.name and not np,
                    "in-list fluid fuel was not kept on the any-fluid machine")
            end
            if coal_fuel then
                local _, np_item = acc.reconcile_fuel_for_machine(coal_fuel, anyfluid)
                assert(np_item, "item fuel on an any-fluid machine did not request a preset")
            end
        end

        local void_machine = prototypes.entity["fs-test-cm-void"]
        if void_machine and coal_fuel then
            -- a fuel-less machine reconciles to no fuel and never needs a preset.
            local f, np = acc.reconcile_fuel_for_machine(coal_fuel, void_machine)
            assert(f == nil and not np, "void machine did not reconcile to a nil fuel")
        end

        -- (8) persisted path: a machine paste re-derives the line's fuel range.
        -- Build a line on the wide machine, snapshot it to the clipboard, then
        -- paste the narrow machine onto it and assert the fuel range followed.
        save.init_force_data(FORCE_INDEX)
        save.init_player_data(PLAYER_INDEX)
        local solutions = storage.forces[FORCE_INDEX].solutions
        local solution_name = save.new_solution(solutions, "fuel_reconcile_probe")
        local solution = solutions[solution_name]
        local recipe_tn = tn.create_typed_name("recipe", "fs-test-machine-recipe")

        save.new_production_line(PLAYER_INDEX, solution, recipe_tn)
        local line = solution.production_lines[1]
        -- Pin the line onto the wide machine with its default (range) fuel.
        line.machine_typed_name = tn.create_typed_name("machine", "fs-test-fes-no-scale")
        line.fuel_typed_name = acc.try_get_fixed_fuel(
            tn.typed_name_to_machine(line.machine_typed_name))
        assert(line.fuel_typed_name
            and line.fuel_typed_name.minimum_temperature ~= line.fuel_typed_name.maximum_temperature,
            "seeded wide-machine line fuel is not a range")

        save.set_machine_clipboard(PLAYER_INDEX, {
            machine_typed_name = tn.create_typed_name("machine", "fes-window-100-300"),
            fuel_typed_name = acc.try_get_fixed_fuel(
                tn.typed_name_to_machine(tn.create_typed_name("machine", "fes-window-100-300"))),
            substrate_tile_name = nil,
            module_typed_names = {},
            affected_by_beacons = {},
        }, "machine_fuel")
        local result = save.apply_machine_clipboard(PLAYER_INDEX, solution, 1)
        assert(result == "ok", "apply_machine_clipboard rejected the paste: " .. tostring(result))
        local pasted = solution.production_lines[1].fuel_typed_name
        assert(pasted and pasted.type == "fluid" and pasted.name == "steam"
            and pasted.minimum_temperature == 100 and pasted.maximum_temperature == 300,
            "pasted line fuel did not follow the narrow machine to [100,300]")

        solutions[solution_name] = nil -- leave no probe solution behind
    end)
    if not ok then
        return "ERROR: fuel reconciliation check raised: " .. tostring(err)
    end
    return "OK"
end

---Exercises get_fluid_fuel_temperature_variants: the fuel-temperature picker
---options for a burns_fluid=false machine. Asserts the list leads with the
---machine's acceptance-range variant, then the distinct single temperatures
---recipes produce the fluid at, clipped to the acceptance range but NOT to the
---energy-conversion cap. Driven off the data_test.lua synthetic machines
---(fs-test-fes-no-scale = wide steam [15,1000], fes-window-100-300 = [100,300],
---fs-test-fes-low-cap = wide steam acceptance with a 200C cap). Base-game steam
---has registered point temperatures at 165 (boiler) and 500 (heat exchanger).
---Guarded on presence so a stripped build skips instead of failing.
---@return string
function M.check_fluid_fuel_temperature_variants()
    local wide_machine = prototypes.entity["fs-test-fes-no-scale"]
    local narrow_machine = prototypes.entity["fes-window-100-300"]
    local lowcap_machine = prototypes.entity["fs-test-fes-low-cap"]
    if not (wide_machine and narrow_machine and lowcap_machine) then
        log.info("check_fluid_fuel_temperature_variants: data_test machines absent, skipped")
        return "OK"
    end

    -- The degenerate single temperature a variant decodes to (min == max), or
    -- nil if it is a non-degenerate range.
    local function point_of(variant)
        local tname = tn.craft_to_typed_name(variant)
        if tname.type == "fluid"
            and tname.minimum_temperature == tname.maximum_temperature then
            return tname.minimum_temperature
        end
        return nil
    end

    local function points_in(variants)
        local set = {}
        for _, v in ipairs(variants) do
            local p = point_of(v)
            if p then set[p] = true end
        end
        return set
    end

    local ok, err = pcall(function()
        -- (1) wide machine: first entry is the full acceptance range, followed by
        -- every in-range steam point. Steam's physical range is [15,1000], so both
        -- the 165 and 500 boiler/heat-exchanger points qualify.
        local wide = acc.get_fluid_fuel_temperature_variants(wide_machine)
        assert(wide and #wide >= 2, "wide machine offered no fuel-temperature choice")
        local wide_range = tn.craft_to_typed_name(wide[1])
        local acc_wide = acc.try_get_fixed_fuel(wide_machine)
        assert(wide_range.type == "fluid" and wide_range.name == "steam"
            and wide_range.minimum_temperature == acc_wide.minimum_temperature
            and wide_range.maximum_temperature == acc_wide.maximum_temperature
            and wide_range.minimum_temperature ~= wide_range.maximum_temperature,
            "wide machine's first variant is not the acceptance range")
        local wp = points_in(wide)
        assert(wp[165] and wp[500],
            "wide machine did not offer the 165 and 500 steam points")

        -- (2) narrow machine [100,300]: 165 is in range and offered; 500 is out of
        -- the acceptance range and must be clipped out.
        local narrow = acc.get_fluid_fuel_temperature_variants(narrow_machine)
        assert(narrow and #narrow >= 2, "narrow machine offered no fuel-temperature choice")
        local narrow_range = tn.craft_to_typed_name(narrow[1])
        assert(narrow_range.minimum_temperature == 100 and narrow_range.maximum_temperature == 300,
            "narrow machine's first variant is not the [100,300] acceptance range")
        local np = points_in(narrow)
        assert(np[165], "narrow machine did not offer the in-range 165 point")
        assert(not np[500], "narrow machine offered the out-of-acceptance 500 point")

        -- (3) low-cap machine: acceptance is the full [15,1000] range but the cap
        -- is 200. The 500 point is above the cap yet within acceptance, so it is
        -- still offered (clip to acceptance, not to the cap).
        local lowcap = acc.get_fluid_fuel_temperature_variants(lowcap_machine)
        assert(lowcap and #lowcap >= 2, "low-cap machine offered no fuel-temperature choice")
        local lp = points_in(lowcap)
        assert(lp[500], "low-cap machine clipped the above-cap (but in-range) 500 point")
    end)
    if not ok then
        return "ERROR: fluid fuel temperature variants check raised: " .. tostring(err)
    end
    return "OK"
end

---Exercises the engine `fixed_recipe` lock for an ordinary crafting machine (not
---a rocket-silo). Driven off the data_test 8e fixture: a lone machine
---fs-test-fixed-recipe-machine locked to fs-test-fixed-recipe-a, in category
---fs-test-fixed-cat which also holds recipe ...-b. Asserts the machine is offered
---for A only, that B has no eligible machine (uncraftable in-game), that the
---category has no general (lock-free) machine, and so never becomes a
---category-wide machine preset (unknown-entity sentinel). Guarded on presence so
---a stripped build skips instead of failing.
---@return string
function M.check_fixed_recipe_machine()
    local machine = prototypes.entity["fs-test-fixed-recipe-machine"]
    local recipe_a = prototypes.recipe["fs-test-fixed-recipe-a"]
    local recipe_b = prototypes.recipe["fs-test-fixed-recipe-b"]
    if not (machine and recipe_a and recipe_b) then
        log.info("check_fixed_recipe_machine: data_test fixtures absent, skipped")
        return "OK"
    end

    local function has_machine(list, name)
        for _, m in ipairs(list) do
            if m.name == name then return true end
        end
        return false
    end

    local ok, err = pcall(function()
        assert(machine.fixed_recipe == "fs-test-fixed-recipe-a",
            "fixture machine is not locked to recipe A")

        assert(acc.machine_allows_recipe(machine, "fs-test-fixed-recipe-a"),
            "machine_allows_recipe rejected the machine's own fixed recipe")
        assert(not acc.machine_allows_recipe(machine, "fs-test-fixed-recipe-b"),
            "machine_allows_recipe permitted a recipe outside the lock")

        local for_a = acc.get_machines_for_recipe(recipe_a)
        assert(has_machine(for_a, "fs-test-fixed-recipe-machine"),
            "fixed machine not offered for its own recipe A")

        local for_b = acc.get_machines_for_recipe(recipe_b)
        assert(not has_machine(for_b, "fs-test-fixed-recipe-machine"),
            "fixed machine wrongly offered for recipe B")
        assert(#for_b == 0,
            "recipe B should have no eligible machine, got " .. #for_b)

        assert(#acc.get_general_machines_in_category("fs-test-fixed-cat") == 0,
            "fixed-only category reported a general machine")

        local presets = preset.create_machine_presets()
        local cat_preset = presets["fs-test-fixed-cat"]
        assert(cat_preset and cat_preset.name == "unknown-entity",
            "fixed-only category default is not the unknown-entity sentinel")
    end)
    if not ok then
        return "ERROR: fixed recipe machine check raised: " .. tostring(err)
    end
    return "OK"
end

---Three general machines in fs-test-ing-cap disagree on ingredient_count (caps 2 / 4
---/ 10). Asserts the cap filters get_machines_for_recipe by item-ingredient count (the
---fluid ingredient is exempt) and that the category splits into machine-preset tiers:
---a base key plus a DISTINCT "...|>2" tier that lists the two larger machines -- the
---same data the machine-presets dialog renders as a separate row. Driven off the
---data_test 8f fixture; guarded on presence so a stripped build skips instead of failing.
---@return string
function M.check_ingredient_count_machine()
    local cap2 = prototypes.entity["fs-test-ing-cap-2"]
    local cap4 = prototypes.entity["fs-test-ing-cap-4"]
    local cap10 = prototypes.entity["fs-test-ing-cap-10"]
    local ok_recipe = prototypes.recipe["fs-test-ing-ok"]
    local over = prototypes.recipe["fs-test-ing-over"]
    local fluid = prototypes.recipe["fs-test-ing-fluid"]
    if not (cap2 and cap4 and cap10 and ok_recipe and over and fluid) then
        log.info("check_ingredient_count_machine: data_test fixtures absent, skipped")
        return "OK"
    end

    local function has_machine(list, name)
        for _, m in ipairs(list) do
            if m.name == name then return true end
        end
        return false
    end

    local ok, err = pcall(function()
        assert(cap2.ingredient_count == 2, "cap-2 machine is not capped at 2")

        -- Item-ingredient counting: the fluid ingredient does not count.
        assert(acc.count_item_ingredients(ok_recipe) == 2, "ok recipe item count wrong")
        assert(acc.count_item_ingredients(over) == 3, "over recipe item count wrong")
        assert(acc.count_item_ingredients(fluid) == 2, "fluid recipe item count wrong (fluid counted?)")

        assert(acc.machine_within_ingredient_count(cap2, ok_recipe), "cap-2 rejected a 2-item recipe")
        assert(not acc.machine_within_ingredient_count(cap2, over), "cap-2 accepted a 3-item recipe")
        assert(acc.machine_within_ingredient_count(cap2, fluid), "cap-2 rejected a 2-item + fluid recipe")
        assert(acc.machine_within_ingredient_count(cap4, over), "cap-4 rejected a 3-item recipe")

        -- Picker / get_machines_for_recipe reflects the cap.
        local for_over = acc.get_machines_for_recipe(over)
        assert(not has_machine(for_over, "fs-test-ing-cap-2"),
            "capped machine offered for an over-cap recipe")
        assert(has_machine(for_over, "fs-test-ing-cap-4") and has_machine(for_over, "fs-test-ing-cap-10"),
            "over-cap recipe did not offer both eligible machines")
        local for_ok = acc.get_machines_for_recipe(ok_recipe)
        assert(#for_ok == 3, "in-cap recipe did not offer all three machines")
        local for_fluid = acc.get_machines_for_recipe(fluid)
        assert(#for_fluid == 3, "fluid recipe excluded a machine (fluid counted toward cap?)")

        -- Preset tiering: base key for the 2-item recipe, "...|>2" for the 3-item one.
        assert(preset.machine_preset_key("fs-test-ing-cap", 2) == "fs-test-ing-cap",
            "2-item recipe did not map to the base preset key")
        assert(preset.machine_preset_key("fs-test-ing-cap", 3) == "fs-test-ing-cap|>2",
            "3-item recipe did not map to the |>2 preset tier")

        -- The category produces a NEW, distinct preset row: a base tier listing all
        -- three machines and a ">2" tier listing the two that can craft over-cap
        -- recipes. The dialog renders exactly the tiers with >1 machine, so the ">2"
        -- tier having two machines is what makes it a visible second row.
        local tiers = preset.machine_preset_tiers("fs-test-ing-cap")
        local base_tier, over_tier
        for _, tier in ipairs(tiers) do
            if tier.key == "fs-test-ing-cap" then base_tier = tier end
            if tier.key == "fs-test-ing-cap|>2" then over_tier = tier end
        end
        assert(base_tier and base_tier.threshold == nil and #base_tier.machines == 3,
            "base preset tier should list all three machines")
        assert(over_tier and over_tier.threshold == 2 and #over_tier.machines == 2,
            "the >2 preset tier should be a distinct row listing the two larger machines")

        local presets = preset.create_machine_presets()
        assert(presets["fs-test-ing-cap"], "base machine preset tier missing")
        local over_preset = presets["fs-test-ing-cap|>2"]
        assert(over_preset and over_preset.name ~= "fs-test-ing-cap-2",
            "over-cap preset tier defaulted to a machine that cannot craft over-cap recipes")
        assert(over_preset.name == "fs-test-ing-cap-4" or over_preset.name == "fs-test-ing-cap-10",
            "over-cap preset tier default is not one of its eligible machines")
    end)
    if not ok then
        return "ERROR: ingredient_count machine check raised: " .. tostring(err)
    end
    return "OK"
end

---Two machines locked to the same real recipe via fixed_recipe, in a category with no
---general machine (data_test 8g). The recipe is craftable only by those two, so it
---qualifies for a recipe-keyed fixed_recipe preset that persists the machine choice --
---which a category preset (excluding fixed_recipe machines) cannot. Asserts the trigger
---set, the single-fixed boundary (8e must not qualify), and that the preset is populated
---with a real default. Guarded on presence so a stripped build skips instead of failing.
---@return string
function M.check_shared_fixed_recipe_machine()
    local machine_a = prototypes.entity["fs-test-shared-machine-a"]
    local machine_b = prototypes.entity["fs-test-shared-machine-b"]
    local recipe = prototypes.recipe["fs-test-shared-recipe"]
    if not (machine_a and machine_b and recipe) then
        log.info("check_shared_fixed_recipe_machine: data_test fixtures absent, skipped")
        return "OK"
    end

    local function has_machine(list, name)
        for _, m in ipairs(list) do
            if m.name == name then return true end
        end
        return false
    end

    local ok, err = pcall(function()
        assert(machine_a.fixed_recipe == "fs-test-shared-recipe"
            and machine_b.fixed_recipe == "fs-test-shared-recipe",
            "fixture machines are not both locked to the shared recipe")

        -- Trigger set: a recipe craftable only by >=2 fixed machines qualifies; a
        -- recipe with a single fixed machine (8e) does not (no choice to persist).
        assert(storage.virtuals.shared_fixed_recipes["fs-test-shared-recipe"],
            "shared fixed recipe missing from shared_fixed_recipes")
        assert(not storage.virtuals.shared_fixed_recipes["fs-test-fixed-recipe-a"],
            "single-fixed-machine recipe wrongly treated as shared")

        local machines = acc.get_machines_for_recipe(recipe)
        assert(#machines == 2
            and has_machine(machines, "fs-test-shared-machine-a")
            and has_machine(machines, "fs-test-shared-machine-b"),
            "shared recipe did not offer exactly its two fixed machines")

        -- The recipe-keyed preset is created with a real default (not the
        -- unknown-entity sentinel), so the machine choice has somewhere to persist.
        local presets = preset.create_fixed_recipe_presets()
        local stored = presets["fs-test-shared-recipe"]
        assert(stored and (stored.name == "fs-test-shared-machine-a"
            or stored.name == "fs-test-shared-machine-b"),
            "fixed_recipe preset did not default to one of the shared machines")
    end)
    if not ok then
        return "ERROR: shared fixed recipe machine check raised: " .. tostring(err)
    end
    return "OK"
end

---Exercises required_fluid normalization on mining virtual recipes. A drill
---consumes mineable.fluid_amount of the required fluid once per mining cycle --
---the same cadence at which products are yielded -- so create_resource_virtual
---must divide it by mining_time exactly as it does the products. Regression lock
---for the bug where the fluid skipped that division and was over-counted by a
---factor of mining_time (2x on vanilla uranium-ore, mining_time=2). Driven off
---vanilla uranium-ore (required_fluid = sulfuric-acid); guarded on presence so a
---mod set without it skips instead of failing.
---@return string
function M.check_required_fluid_mining()
    local resource = prototypes.entity["uranium-ore"]
    local mineable = resource and resource.mineable_properties
    if not (mineable and mineable.required_fluid) then
        log.info("check_required_fluid_mining: uranium-ore with required_fluid absent, skipped")
        return "OK"
    end

    local ok, err = pcall(function()
        local recipe = storage.virtuals.recipe["<mine>uranium-ore"]
        assert(recipe, "no <mine>uranium-ore virtual recipe generated")

        local fluid_ingredient
        for _, ingredient in ipairs(recipe.ingredients) do
            if ingredient.type == "fluid" and ingredient.name == mineable.required_fluid then
                fluid_ingredient = ingredient
                break
            end
        end
        assert(fluid_ingredient,
            "required_fluid " .. mineable.required_fluid .. " missing from ingredients")

        -- Consumed once per mining cycle, so the per-craft amount must be the raw
        -- fluid_amount divided by mining_time (matching the products). Pre-fix this
        -- was the raw fluid_amount, mining_time times too large.
        local expected = mineable.fluid_amount / mineable.mining_time
        assert(math.abs(fluid_ingredient.amount - expected) < 1e-9,
            string.format("required_fluid per-craft amount %s, expected %s (fluid_amount %s / mining_time %s)",
                tostring(fluid_ingredient.amount), tostring(expected),
                tostring(mineable.fluid_amount), tostring(mineable.mining_time)))
    end)
    if not ok then
        return "ERROR: required fluid mining check raised: " .. tostring(err)
    end
    return "OK"
end

---Exercises quality-scaled module slots (Factorio 2.0.77+). Driven off the
---data_test fs-test-quality-module-slots machine, which opts into
---quality_affects_module_slots; no vanilla entity does, so this is the only way
---to hit get_machine_module_inventory_size's scaling branch. Confirms the
---accessor reports base + the per-quality bonus at legendary and base at normal
---(read flag-free via get_inventory_size), and that a vanilla (non-opted-in)
---machine stays unscaled. Guarded on the fixture and the legendary quality so a
---base-only / quality-less run skips instead of failing.
---@return string
function M.check_quality_module_slots()
    local machine = prototypes.entity["fs-test-quality-module-slots"]
    local legendary = prototypes.quality["legendary"]
    if not (machine and legendary) then
        log.info("check_quality_module_slots: fixture or quality absent, skipped")
        return "OK"
    end

    local ok, err = pcall(function()
        local base = machine.module_inventory_size
        local bonus = legendary.crafting_machine_module_slots_bonus
        assert(base and base > 0, "fixture has no module slots")
        assert(bonus and bonus > 0, "legendary quality has no crafting_machine_module_slots_bonus")

        local scaled = acc.get_machine_module_inventory_size(machine, "legendary")
        assert(scaled == base + bonus,
            string.format("scaled slots %s, expected %s (base %s + bonus %s)",
                tostring(scaled), tostring(base + bonus), tostring(base), tostring(bonus)))

        local at_normal = acc.get_machine_module_inventory_size(machine, "normal")
        assert(at_normal == base,
            string.format("normal slots %s, expected base %s", tostring(at_normal), tostring(base)))

        -- A vanilla machine does not opt in, so quality must not change its slots.
        local vanilla = prototypes.entity["assembling-machine-3"]
        if vanilla then
            local vbase = vanilla.module_inventory_size
            local vleg = acc.get_machine_module_inventory_size(vanilla, "legendary")
            assert(vleg == vbase,
                string.format("vanilla machine scaled to %s, expected unchanged %s",
                    tostring(vleg), tostring(vbase)))
        end
    end)
    if not ok then
        return "ERROR: quality module slots check raised: " .. tostring(err)
    end
    return "OK"
end

---Offshore-pump fluid_box filter: a pump's output is its filter fluid when one
---is set, else the placed tile's fluid. Driven off the data_test 5b fixtures
---(fs-test-offshore-pump-water filtered to water; fs-test-offshore-pump-lubricant
---filtered to lubricant, which NO tile produces). Asserts the lubricant pump
---surfaces via a fluid-keyed `<pump-fluid>lubricant` recipe with only itself as a
---candidate, that the unfiltered vanilla pump is excluded from lubricant yet
---offered for water, and that the preset layer covers the tile-less fluid (which
---used to crash get_machine_preset's assert). Guarded on presence so a stripped
---build skips instead of failing.
---@return string
function M.check_offshore_pump_filter()
    local plain = prototypes.entity["offshore-pump"]
    local pump_water = prototypes.entity["fs-test-offshore-pump-water"]
    local pump_lubricant = prototypes.entity["fs-test-offshore-pump-lubricant"]
    if not (plain and pump_water and pump_lubricant) then
        log.info("check_offshore_pump_filter: data_test fixtures absent, skipped")
        return "OK"
    end

    local function has_machine(list, name)
        for _, m in ipairs(list) do
            if m.name == name then return true end
        end
        return false
    end

    local ok, err = pcall(function()
        -- The filter-pinned, tile-less fluid gets its own fluid-keyed recipe.
        local recipe = storage.virtuals.recipe["<pump-fluid>lubricant"]
        assert(recipe, "no <pump-fluid>lubricant recipe was generated")
        assert(recipe.pumped_fluid_name == "lubricant",
            "<pump-fluid>lubricant has the wrong pumped_fluid_name")
        assert(recipe.source_planet_names == nil,
            "<pump-fluid>lubricant must carry no planet restriction")

        -- Its machine list is exactly the lubricant-filtered pump.
        local for_lub = acc.get_machines_for_recipe(recipe)
        assert(has_machine(for_lub, "fs-test-offshore-pump-lubricant"),
            "lubricant pump not offered for its own <pump-fluid> recipe")
        assert(not has_machine(for_lub, "offshore-pump"),
            "unfiltered pump wrongly offered for lubricant")
        assert(not has_machine(for_lub, "fs-test-offshore-pump-water"),
            "water-filtered pump wrongly offered for lubricant")

        -- Candidate rule directly: lubricant excludes the unfiltered pump (it can
        -- only pump tile-borne fluids); water includes it plus the water-filtered
        -- pump and excludes the lubricant pump.
        local lub_pumps = acc.get_offshore_pumps_for_fluid("lubricant")
        assert(has_machine(lub_pumps, "fs-test-offshore-pump-lubricant")
            and not has_machine(lub_pumps, "offshore-pump")
            and not has_machine(lub_pumps, "fs-test-offshore-pump-water"),
            "get_offshore_pumps_for_fluid('lubricant') candidate set is wrong")

        local water_pumps = acc.get_offshore_pumps_for_fluid("water")
        assert(has_machine(water_pumps, "offshore-pump")
            and has_machine(water_pumps, "fs-test-offshore-pump-water")
            and not has_machine(water_pumps, "fs-test-offshore-pump-lubricant"),
            "get_offshore_pumps_for_fluid('water') candidate set is wrong")

        -- The tile-fluid predicate the candidate rule and enumeration share.
        assert(acc.fluid_has_offshore_tile("water"),
            "water should be a tile-borne fluid")
        assert(not acc.fluid_has_offshore_tile("lubricant"),
            "lubricant should not be a tile-borne fluid")

        -- Preset layer must cover the tile-less fluid, or get_machine_preset's
        -- assert trips on this recipe (the pre-fix crash).
        local lub_preset = preset.create_pump_presets()["lubricant"]
        assert(lub_preset and lub_preset.name == "fs-test-offshore-pump-lubricant",
            "pump preset for lubricant missing or wrong")
    end)
    if not ok then
        return "ERROR: offshore pump filter check raised: " .. tostring(err)
    end
    return "OK"
end

---Register the remote interface the launcher calls. Interface names share a
---flat namespace across mods, so it carries the factory_solver_ prefix. Remote
---interfaces are not persisted across save/load, so this must run on every load
----- control.lua calls it from its main chunk (which it does only for the
---smoke_rcon scenario).
function M.register()
    remote.add_interface("factory_solver_smoke", {
        setup = M.setup,
        state = M.state,
        check_read_side = M.check_read_side,
        check_catalyst_reclassify = M.check_catalyst_reclassify,
        check_target_rescue = M.check_target_rescue,
        check_force_caches = M.check_force_caches,
        check_fuel_reconciliation = M.check_fuel_reconciliation,
        check_fluid_fuel_temperature_variants = M.check_fluid_fuel_temperature_variants,
        check_fixed_recipe_machine = M.check_fixed_recipe_machine,
        check_ingredient_count_machine = M.check_ingredient_count_machine,
        check_shared_fixed_recipe_machine = M.check_shared_fixed_recipe_machine,
        check_required_fluid_mining = M.check_required_fluid_mining,
        check_quality_module_slots = M.check_quality_module_slots,
        check_offshore_pump_filter = M.check_offshore_pump_filter,
    })
end

return M
