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
local report = require "manage/report"
local save = require "manage/save"
local tn = require "manage/typed_name"

local log = fs_log.for_module("smoke_rcon")

local M = {}

-- The default "player" force. Forces exist independently of players, so index 1
-- is present even on a dedicated server with nobody connected.
local FORCE_INDEX = 1

-- Fixtures. Each is `{ requires = {<mod names>}, build = function(solution) }`.
-- `build` plants a Solution into the force's storage; the caller marks it
-- solver_state="ready" so the on_tick pump picks it up. `requires` drives the
-- SKIP guard in setup (see the header). Kept deliberately player-free.
local fixtures = {}

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
---value ("finished" / "unfinished" / "unbounded" / "unfeasible") or an ERROR.
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
    })
end

return M
