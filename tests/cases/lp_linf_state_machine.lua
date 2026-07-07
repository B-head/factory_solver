-- The L-infinity ("leveled") STATE MACHINE (manage/pre_solve.lua forwerd_solve
-- + target_rescue_step + linf_step), driven end-to-end headless. The shaping
-- each stage applies is pinned in lp_solver_norms.lua; what this file pins is
-- the tick-pump orchestration across the stage rebuilds -- specifically the
-- target-budget threading through the "ready" preserve list.
--
-- Regression (2026-07-08): lf_restart was missing from forwerd_solve's
-- target-rescue preserve condition, so every linf stage rebuild dropped the
-- settled solution.target_rescue. Two consequences on any problem where the
-- rescue fires (the lp_target_rescue collapse fixture):
--   * the min-max / capped builds lost the target_budget row, so the capped
--     stage (back on L1 elastic_cost) re-entered the baseline's collapse
--     economics and abandoned the rescued target;
--   * after each stage finished, target_rescue_step re-measured the stage
--     solution with no rescue state, re-armed stage 1 mid-linf (destroying
--     solution.linf), and the pump LIVELOCKED on a 4-rebuild
--     rescue<->minmax<->capped cycle -- reproduced at 988 rebuilds / 20k steps
--     without settling.
-- The fix threads solution.linf.t_limit into both stage builds and preserves
-- target_rescue across lf_restart; the fixture settles in 5 rebuilds
-- (baseline -> stage1 -> resolve -> minmax -> capped) with the target met.
--
-- forwerd_solve is headless-safe except for the production-line normalizer
-- (prototype reads), so each case stubs pre_solve.to_normalized_production_lines
-- to hand back the already-normalized fixture lines -- the same shape the
-- create_problem-level cases feed directly.

local harness = require "tests/harness"
local pre_solve = require "manage/pre_solve"

local function it(name, amount)
    return { type = "item", name = name, quality = "normal", amount_per_second = amount }
end
local function line(recipe, products, ingredients)
    return {
        recipe_typed_name = { type = "recipe", name = recipe, quality = "normal" },
        products = products, ingredients = ingredients,
        power_per_second = 0, pollution_per_second = 0,
    }
end

---Drive forwerd_solve to a terminal state exactly as the on_tick pump does,
---with the normalizer stubbed to return `lines` as-is. Returns the settled
---solution plus the number of "ready" rebuilds consumed (the livelock detector:
---the linf pipeline is at most baseline + 3 rescue solves + 2 stages).
---@return table solution, integer rebuilds
local function drive_linf(lines, constraints, max_steps)
    max_steps = max_steps or 5000
    local solution = {
        name = "linf-pump",
        constraints = constraints,
        production_lines = {},
        solver_state = "ready",
        solver_norm = "linf",
    }
    local force_data = { research_bonuses = nil }

    local saved = pre_solve.to_normalized_production_lines
    pre_solve.to_normalized_production_lines = function() return lines end
    local rebuilds, steps = 0, 0
    local ok, err = pcall(function()
        while solution.solver_state == "ready" or solution.solver_state == "calculating" do
            if solution.solver_state == "ready" then rebuilds = rebuilds + 1 end
            pre_solve.forwerd_solve(force_data, solution)
            steps = steps + 1
            assert(steps <= max_steps,
                string.format("linf pump did not settle after %d steps / %d rebuilds (livelock)",
                    steps, rebuilds))
        end
    end)
    pre_solve.to_normalized_production_lines = saved
    if not ok then error(err, 0) end
    return solution, rebuilds
end

local function sum_kind(problem, vars, kind)
    local total = 0
    for key, p in pairs(problem.primals) do
        if p.kind == kind then total = total + math.abs(vars.x[key] or 0) end
    end
    return total
end

local cases = {}

table.insert(cases, {
    name = "linf pump settles on a rescue-firing problem, target budget rides both stages",
    run = function()
        -- lp_target_rescue's collapse fixture: meeting 1 T/s forces ~3000
        -- units/s of penalised surplus (> 1024 violation units per target
        -- unit), so the plain baseline collapses and the rescue fires.
        local lines = {
            line("r_t", { it("T", 1), it("J", 3000) }, { it("Jin", 1) }),
            line("r_x", { it("Jin", 1) }, { it("J", 1) }),
            line("r_b", { it("Jin", 0.001) }, {}),
        }
        local constraints = {
            { type = "item", name = "T", quality = "normal",
                limit_type = "equal", limit_amount_per_second = 1 },
        }
        local solution, rebuilds = drive_linf(lines, constraints)
        harness.assert_eq(solution.solver_state, "finished", "solver_state")
        harness.assert_eq(solution.linf and solution.linf.phase, "done", "linf settled")
        harness.assert_true(rebuilds <= 8,
            "pipeline is baseline + rescue + 2 stages, got " .. rebuilds .. " rebuilds")
        assert(solution.raw_variables, "expected packed variables")
        -- The capped stage carried the rescued budget: the target is met and the
        -- forced surplus is actually paid, not dodged by re-collapsing.
        harness.assert_near(solution.raw_variables.x["recipe/r_t/normal"] or 0, 1, 1e-2,
            "target recipe runs at the requested rate in the leveled answer")
        harness.assert_true(
            sum_kind(solution.problem, solution.raw_variables, "elastic") <= 2e-6,
            "target relaxation stays under the rescued budget")
        harness.assert_true(solution.linf.t_limit ~= nil and solution.linf.t_limit <= 2e-6,
            "t_limit locked from the rescue budget")
    end,
})

table.insert(cases, {
    name = "linf pump on a clean chain: no rescue, minimal solves, answer intact",
    run = function()
        local lines = {
            line("mk_widget", { it("widget", 1) }, { it("ore", 1) }),
            line("mk_ore", { it("ore", 1) }, { it("raw", 1) }),
        }
        local constraints = {
            { type = "item", name = "widget", quality = "normal",
                limit_type = "equal", limit_amount_per_second = 1 },
        }
        local solution, rebuilds = drive_linf(lines, constraints)
        harness.assert_eq(solution.solver_state, "finished", "solver_state")
        harness.assert_eq(solution.linf and solution.linf.phase, "done", "linf settled")
        -- No rescue solves: baseline + minmax + capped only.
        harness.assert_true(rebuilds <= 3, "no rescue fired, got " .. rebuilds .. " rebuilds")
        assert(solution.raw_variables, "expected packed variables")
        -- The no-rescue t_limit (locked at the baseline's ~0 relaxation) is a
        -- slack row: the clean chain solves exactly as the plain build would.
        harness.assert_near(solution.raw_variables.x["recipe/mk_widget/normal"] or 0, 1, 1e-3,
            "widget recipe runs")
        harness.assert_near(solution.raw_variables.x["recipe/mk_ore/normal"] or 0, 1, 1e-3,
            "ore recipe runs in full")
        harness.assert_true(
            sum_kind(solution.problem, solution.raw_variables, "elastic") <= 1e-3,
            "target met on the clean chain")
    end,
})

return cases
