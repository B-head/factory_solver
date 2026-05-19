-- Smoke-test driver. Loaded by control.lua only when the live scenario is
-- `factory_solver/smoke` — see the `script.level` gate at the bottom of
-- [control.lua](../control.lua) for the wiring. Verdict lines are emitted via
-- [fs_log](../fs_log.lua) at INFO so they land in `factorio-current.log`
-- regardless of `__DebugAdapter`; the [tests/smoke.ps1](../tests/smoke.ps1)
-- launcher greps for them.

local fs_log = require "fs_log"
local save = require "manage/save"
local tn = require "manage/typed_name"

local log = fs_log.for_module("smoke")

local M = {}

-- Hard deadline so the launcher never hangs on a stuck IPM iteration. 30
-- seconds of game time is plenty for the trivial fixture below; if the solver
-- has not converged by then something is wrong upstream.
local DEADLINE_TICK = 30 * 60

-- Transient state. The scenario runs once start-to-finish with no save/load
-- round-trip, so a module-local is enough — keeping it out of `storage` also
-- means it can't accidentally contaminate a real save.
local state = { phase = "waiting_for_player" }

-- We deliberately do NOT touch game.set_game_state here. Setting
-- player_won=true triggers the celebratory "Victory!" GUI, and
-- player_won=false shows a game-over screen — both are noisy and there is no
-- "quietly finish" option. There is also no Lua API to terminate the
-- factorio.exe process, so a clean Lua-side shutdown is not really achievable
-- regardless. Instead we just emit the marker; the launcher
-- (tests/smoke.ps1) polls the log file and kills the process as soon as the
-- verdict appears.
local function emit_verdict(verdict, detail)
    log.info("SMOKE %s: %s", verdict, detail or "")
    state.phase = "done"
end

---Build a minimal Solution that exercises the prototype-reading layer:
---one production line (iron-plate, "smelting" category → resolves to a real
---machine preset), one upper-bound constraint on the product.
---@param player_index integer
local function setup_test(player_index)
    local solutions = save.get_solutions(player_index)
    local solution_name = save.new_solution(solutions, "smoke")
    local solution = assert(solutions[solution_name])

    local recipe_tn = tn.create_typed_name("recipe", "iron-plate")
    save.new_production_line(player_index, solution, recipe_tn, nil, nil)

    local product_tn = tn.create_typed_name("item", "iron-plate")
    save.new_constraint(solution, product_tn)

    local player_data = save.get_player_data(player_index)
    player_data.selected_solution = solution_name
end

function M.on_player_created(event)
    if state.phase ~= "waiting_for_player" then return end
    log.info("setup at tick=%d for player_index=%d", event.tick, event.player_index)

    local ok, err = pcall(setup_test, event.player_index)
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
    if ss == "finished" then
        emit_verdict("PASS", string.format("converged at tick=%d", event.tick))
    elseif ss == "unfinished" or ss == "unbounded" or ss == "unfeasible" then
        emit_verdict("FAIL", "solver_state=" .. tostring(ss))
    end
    -- otherwise still iterating ("ready" or a numeric step count): keep polling
end

return M
