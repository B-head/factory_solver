-- Smoke-test driver for the "missing prototype fallback" path. Same shape as
-- [manage/smoke.lua](smoke.lua), but the Solution it builds points at machine /
-- recipe / fuel names that do NOT exist in `prototypes`, so the fallbacks in
-- [manage/typed_name.lua](typed_name.lua) (`entity-unknown`, `recipe-unknown`,
-- `item-unknown`) are exercised end-to-end through pre_solve / accessor / LP.
--
-- Reproduces the 0.3.13 crash report
-- (https://mods.factorio.com/mod/factory_solver/discussion/67b60b2dfe381692daeeb08d):
-- selecting a Solution that depended on a machine no longer present in any
-- loaded mod would trap with `attempt to index local 'machine' (a nil value)`.

local flib_table = require "__flib__/table"
local fs_log = require "fs_log"
local report = require "manage/report"
local save = require "manage/save"

local log = fs_log.for_module("smoke")

local M = {}

local DEADLINE_TICK = 30 * 60

local state = { phase = "waiting_for_player" }

local function emit_verdict(verdict, detail)
    log.info("SMOKE %s: %s", verdict, detail or "")
    state.phase = "done"
end

---Bypass save.new_production_line / new_constraint on purpose: those helpers
---resolve machine presets and would refuse to install a typed_name pointing at
---a non-existent prototype. The whole point of this fixture is to plant exactly
---such a line directly into storage, mimicking what a save inherits when a mod
---is removed between sessions.
---@param player_index integer
local function plant_missing_prototype_solution(player_index)
    local solutions = save.get_solutions(player_index)
    local solution_name = save.new_solution(solutions, "smoke_missing")
    local solution = assert(solutions[solution_name])

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

    solution.solver_state = "ready"

    local player_data = save.get_player_data(player_index)
    player_data.selected_solution = solution_name
end

local function exercise_read_side(player_index, solution)
    report.get_total_amounts(player_index, solution)
    report.get_total_power(player_index, solution)
    report.get_total_pollution(player_index, solution)
end

function M.on_player_created(event)
    if state.phase ~= "waiting_for_player" then return end
    log.info("setup at tick=%d for player_index=%d", event.tick, event.player_index)

    local ok, err = pcall(plant_missing_prototype_solution, event.player_index)
    if not ok then
        emit_verdict("FAIL", "setup raised: " .. tostring(err))
        return
    end
    state.phase = "polling"
    state.player_index = event.player_index
end

function M.on_tick(event)
    if state.phase ~= "polling" then return end

    if event.tick > DEADLINE_TICK then
        emit_verdict("FAIL", "deadline exceeded at tick=" .. event.tick)
        return
    end

    local solution = save.get_selected_solution(state.player_index)
    if not solution then
        emit_verdict("FAIL", "no selected solution")
        return
    end

    local ss = solution.solver_state
    if ss == "ready" or type(ss) == "number" then
        return -- still iterating, keep polling
    end

    -- Solver reached a terminal state without raising. Also confirm the
    -- read-side total functions don't choke on the same Solution -- that is
    -- the path that actually crashed in the original report.
    local ok, err = pcall(exercise_read_side, state.player_index, solution)
    if not ok then
        emit_verdict("FAIL", "read-side total raised: " .. tostring(err))
        return
    end

    emit_verdict("PASS", string.format("solver_state=%s at tick=%d", tostring(ss), event.tick))
end

return M
