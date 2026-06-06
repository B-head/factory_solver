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

---Two-pass diagnose-then-reclassify (manage/pre_solve.lua). Plant the data_test
---bootstrap-trapped catalyst loop -- two recipes forming a copper-plate <->
---iron-gear-wheel cycle whose entry recipe is gated behind a large priced raw
---(a: copper + 2000 iron-plate -> gear, b: gear -> 2 copper) -- and demand
---copper-plate. Neither cycle material can be produced from zero, and the
---2000-iron real chain costs more than the shortage penalty, so pass 1 fabricates
---copper-plate via |shortage_source| (an AVOIDABLE cheat the cost tiers prefer).
---The cycle is self-sustaining, so the upfront catalyst-loop heuristics skip it;
---only the reclassify pass -- which diagnoses copper-plate as export-feasible and
---re-seeds it as an import -- removes the cheat, and pass 2 converges at zero
---cheat. The launcher polls state() until "finished" (which now spans both
---passes), then calls check_catalyst_reclassify to assert the reclassify actually
---fired -- a bare "finished" would also pass for a clean solve. Needs the
---data_test.lua synthetic recipes (always present in a dev checkout); build()
---asserts them so a missing one surfaces as ERROR, not a silently-degraded solve.
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

---RCON entry point: assert the two-pass diagnose-then-reclassify actually fired
---for the catalyst_reclassify fixture. The launcher calls this after that fixture
---converges (a bare "finished" can't tell a reclassified solve from a clean one).
---Asserts (a) the solve reached "finished", (b) forced_imports is non-empty -- an
---avoidable cheat was diagnosed and re-seeded for pass 2 -- and (c) the converged
---primal carries no residual cheat (|shortage_source| / |elastic| all ~0), i.e.
---pass 2 replaced fabrication with a real import plus the loop running. WHICH
---cycle material the LP fabricates (copper-plate the target, or iron-gear-wheel
---the mid) is the LP's own least-cost choice, so this asserts the set is non-empty
---rather than naming one -- mirroring lp_two_pass_reclassify.lua. Returns "OK" or
---"ERROR: <detail>".
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

    local forced = solution.forced_imports
    if not forced or next(forced) == nil then
        return "ERROR: forced_imports empty -- the reclassify pass never fired " ..
            "(pass 1 found no avoidable cheat?)"
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
            " after reclassify (pass 2 did not eliminate the avoidable shortage)"
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
