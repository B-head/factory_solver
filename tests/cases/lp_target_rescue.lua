-- Target-rescue (create_problem's target_only_objective / target_budget)
-- regressions: the all-zero target collapse and its lexicographic fix.
--
-- The single weighted LP trades the target against violations at the finite
-- exchange rate target_cost / elastic_cost = 2^20 / 2^10 = 1024. A target whose
-- chain unavoidably forces MORE than 1024 violation units per target unit is
-- therefore rationally abandoned: the LP keeps every recipe at zero and pays the
-- target elastic once -- and because the trade is linear, the collapse is
-- all-or-nothing (T relaxed in full, never partially). Measured on the explorer
-- corpus: 30/1678 problems, the identical set under the hard and the soft gate,
-- reference violations 1499.5 .. 3.8e7 per target unit -- all above 1024
-- (S:/tmp/corpus drill, 2026-06-12).
--
-- The fix is the lexicographic rescue in manage/pre_solve.lua
-- (M.target_rescue_step), whose two build switches are pinned here:
--   target_only_objective  stage 1 -- the target elastics become the only
--                          objective, so the solve measures T_min (the least
--                          violation the build can structurally reach);
--   target_budget          the lock -- one row sum(elastic) <= budget(T_min)
--                          that every later build carries, making the target
--                          hierarchically senior to every violation cost.
-- The in-game phase machinery runs across pre_solve's ticks (smoke-tested);
-- what the headless suite pins is the build-level behaviour of the switches
-- and the collapse economics they fix.
--
-- Fixture: a mass-positive loop {J, Jin} whose throughput scales with the
-- target. r_t consumes 1 Jin and emits the target plus 3000 J; r_x converts
-- J -> Jin 1:1; r_b bootstraps Jin from nothing (catalyst fixtures need a
-- bootstrap source -- see tests/cases/lp_catalyst_loop_bootstrap.lua). Meeting
-- 1 T/s forces ~3000 units/s of surplus through the penalised |surplus_sink|
-- (J or Jin, whichever side dumps): 3000 * 2^10 ~ 2.9 * target_cost, so the
-- collapse is strictly cheaper for the baseline build.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

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

local function collapse_fixture()
    local lines = {
        line("r_t", { it("T", 1), it("J", 3000) }, { it("Jin", 1) }),
        line("r_x", { it("Jin", 1) }, { it("J", 1) }),
        line("r_b", { it("Jin", 0.001) }, {}),
    }
    local constraints = {
        { type = "item", name = "T", quality = "normal",
            limit_type = "equal", limit_amount_per_second = 1 },
    }
    return lines, constraints
end

local function sum_kind(problem, vars, kind)
    local total = 0
    for key, p in pairs(problem.primals) do
        if p.kind == kind then total = total + math.abs(vars.x[key] or 0) end
    end
    return total
end

local function solve(problem)
    return harness.solve_to_completion(lp, problem, { tolerance = 1e-7, iterate_limit = 600 })
end

local cases = {}

table.insert(cases, {
    name = "baseline collapses: a >1024-violations-per-unit target is abandoned in full",
    run = function()
        local lines, constraints = collapse_fixture()
        local problem = cp.create_problem("collapse-baseline", constraints, lines)
        local state, vars = solve(problem)
        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables")
        -- All-or-nothing: the elastic carries the WHOLE target, no recipe runs.
        harness.assert_near(sum_kind(problem, vars, "elastic"), 1, 1e-3,
            "target relaxed in full (the collapse)")
        harness.assert_near(vars.x["recipe/r_t/normal"] or 0, 0, 1e-3, "target recipe parked")
    end,
})

table.insert(cases, {
    name = "target_only_objective measures T_min = 0 on the same build",
    run = function()
        local lines, constraints = collapse_fixture()
        local problem = cp.create_problem("collapse-stage1", constraints, lines, nil,
            { target_only_objective = true })
        local state, vars = solve(problem)
        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables")
        -- The target is structurally reachable -- the collapse is economics,
        -- not reachability.
        harness.assert_near(sum_kind(problem, vars, "elastic"), 0, 1e-3,
            "stage 1 reaches the target")
    end,
})

table.insert(cases, {
    name = "target_budget locks the target: the chain runs and pays its dumps",
    run = function()
        local lines, constraints = collapse_fixture()
        local problem = cp.create_problem("collapse-rescued", constraints, lines, nil,
            { target_budget = 1e-6 })
        local state, vars = solve(problem)
        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables")
        harness.assert_true(sum_kind(problem, vars, "elastic") <= 2e-6,
            "target relaxation capped by the budget row")
        harness.assert_near(vars.x["recipe/r_t/normal"] or 0, 1, 1e-2,
            "target recipe runs at the requested rate")
        -- The violation bill the collapse was dodging is now actually paid.
        harness.assert_true(sum_kind(problem, vars, "surplus_sink") > 1024,
            "the >1024-unit surplus is carried, not dodged")
    end,
})

table.insert(cases, {
    name = "a non-collapsing build is untouched by the budget row",
    run = function()
        -- Cheap chain (no penalised escapes needed): the budget row is slack.
        local lines = {
            line("mk", { it("T", 1) }, { it("ore", 1) }),
        }
        local constraints = {
            { type = "item", name = "T", quality = "normal",
                limit_type = "equal", limit_amount_per_second = 1 },
        }
        local plain = cp.create_problem("no-collapse-plain", constraints, lines)
        local s1, v1 = solve(plain)
        local locked = cp.create_problem("no-collapse-locked", constraints, lines, nil,
            { target_budget = 1e-6 })
        local s2, v2 = solve(locked)
        harness.assert_eq(s1, "finished", "plain solver_state")
        harness.assert_eq(s2, "finished", "locked solver_state")
        assert(v1 and v2, "expected packed variables")
        harness.assert_near(v2.x["recipe/mk/normal"], v1.x["recipe/mk/normal"], 1e-4,
            "same recipe activity with and without the lock")
    end,
})

return cases
