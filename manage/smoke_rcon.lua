-- RCON-driven smoke-test driver.
--
-- Unlike [manage/smoke.lua](smoke.lua) and
-- [manage/smoke_missing_prototype.lua](smoke_missing_prototype.lua) -- which
-- auto-run on on_player_created and report verdicts through SMOKE PASS/FAIL
-- markers in factorio-current.log -- this driver is *pulled* from outside via a
-- remote interface over RCON. The launcher
-- [tests/smoke_rcon.ps1](../tests/smoke_rcon.ps1) boots Factorio as a dedicated
-- server (`--start-server-load-scenario factory_solver/smoke_rcon` plus
-- `--rcon-bind`/`--rcon-password`), connects over RCON, and drives the test
-- synchronously:
--
--   /silent-command rcon.print(remote.call("factory_solver_smoke", "setup", "iron_plate"))
--   /silent-command rcon.print(remote.call("factory_solver_smoke", "state"))   -- poll until terminal
--
-- This buys two things over the log-marker smoke variants:
--   * synchronous, structured request/response (no log byte-offset grepping);
--   * many fixtures per boot (the expensive Factorio bootstrap is paid once).
--
-- Running headless with zero players constrains what this can cover:
--   * The IPM pump in control.lua's on_tick is force-scoped
--     (pre_solve.find_the_need_for_solve iterates game.forces, not players), so
--     it advances a solution to a terminal solver_state with no player
--     connected. That is the path this driver exercises.
--   * Player-scoped paths -- machine-preset selection in
--     save.new_production_line, the read-side report.get_total_* helpers, and
--     the whole GUI -- are NOT reachable with no player. Fixtures therefore
--     plant the Solution table directly into the force's storage (the same
--     technique manage/smoke_missing_prototype.lua uses) and pick a machine
--     explicitly instead of going through preset selection. Read-side / GUI
--     coverage stays with the player-based smoke variants.

local flib_table = require "__flib__/table"
local fs_log = require "fs_log"
local save = require "manage/save"
local tn = require "manage/typed_name"

local log = fs_log.for_module("smoke_rcon")

local M = {}

-- The default "player" force. Forces exist independently of players, so index 1
-- is present even on a dedicated server with nobody connected.
local FORCE_INDEX = 1

-- Fixture builders. Each plants a Solution into the force's storage; the caller
-- marks it solver_state="ready" so the on_tick pump picks it up. Kept
-- deliberately player-free (see the header).
local fixtures = {}

---Happy path: smelt iron-plate in an electric furnace (electric, so no fuel is
---needed), with an upper-bound constraint on the product. Exercises pre_solve
---folding plus the LP end to end.
---@param solution Solution
function fixtures.iron_plate(solution)
    ---@type ProductionLine
    local line = {
        recipe_typed_name = tn.create_typed_name("recipe", "iron-plate"),
        machine_typed_name = tn.create_typed_name("machine", "electric-furnace"),
        module_typed_names = {},
        affected_by_beacons = {},
    }
    flib_table.insert(solution.production_lines, line)

    save.new_constraint(solution, tn.create_typed_name("item", "iron-plate"))
end

---Missing-prototype fallback: a Solution pointing at machine / recipe / fuel
---names that no loaded mod provides, so the entity-unknown / recipe-unknown /
---item-unknown fallbacks in manage/typed_name.lua are exercised through a full
---solve. Mirrors the fixture in manage/smoke_missing_prototype.lua; the
---read-side report exercise from that driver is player-scoped and stays there.
---@param solution Solution
function fixtures.missing_prototype(solution)
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
end

---RCON entry point: clear any prior solution, build the named fixture, and hand
---it to the pump. Returns a status string the launcher reads via rcon.print --
---"OK: <solution name>" or "ERROR: <detail>".
---@param fixture_name string
---@return string
function M.setup(fixture_name)
    local builder = fixtures[fixture_name]
    if not builder then
        return "ERROR: unknown fixture '" .. tostring(fixture_name) .. "'"
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

    local ok, err = pcall(builder, solution)
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

---Register the remote interface the launcher calls. Interface names share a
---flat namespace across mods, so it carries the factory_solver_ prefix. Remote
---interfaces are not persisted across save/load, so this must run on every load
----- control.lua calls it from its main chunk (which it does only for the
---smoke_rcon scenario).
function M.register()
    remote.add_interface("factory_solver_smoke", {
        setup = M.setup,
        state = M.state,
    })
end

return M
