-- Exercise the IPM solver against a hand-built Problem instance.
--
-- We bypass create_problem / NormalizedProductionLine here to isolate the
-- linear-programming layer from the recipe-graph translation layer. Failures
-- here mean the IPM math is broken; failures only in lp_short_loop.lua imply
-- the translation layer is the culprit.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local pg = require "solver/problem_generator"

local cases = {}

table.insert(cases, {
    name = "trivial 2-variable equality LP converges to the expected vertex",
    run = function()
        -- Minimize x1 + x2 subject to x1 + 2*x2 = 4, x1,x2 >= 0.
        -- The cost-minimizing solution is (x1, x2) = (0, 2). IPM stays
        -- interior so x1 won't reach 0 exactly — we check it's near.
        local problem = pg.new("trivial-equality")
        problem:add_objective("x1", 1, true)
        problem:add_objective("x2", 1, true)
        problem:add_equivalence_constraint("c1", 4)
        problem:add_subject_term("x1", "c1", 1)
        problem:add_subject_term("x2", "c1", 2)

        local state, vars, steps = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-7, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        harness.assert_near(vars.x.x2, 2, 1e-3, "x2")
        harness.assert_near(vars.x.x1, 0, 1e-2, "x1")
        harness.assert_true(steps < 300, "converged within 300 iterations (took " .. steps .. ")")
    end,
})

table.insert(cases, {
    name = "feasible-region weighting prefers the cheaper variable",
    run = function()
        -- Minimize 10*x1 + x2 subject to x1 + x2 = 3, x_i >= 0.
        -- The cheap variable should absorb almost all of the budget.
        local problem = pg.new("cost-weighted")
        problem:add_objective("x1", 10, true)
        problem:add_objective("x2", 1, true)
        problem:add_equivalence_constraint("c1", 3)
        problem:add_subject_term("x1", "c1", 1)
        problem:add_subject_term("x2", "c1", 1)

        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-7, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        harness.assert_near(vars.x.x2, 3, 1e-2, "x2 (cheap) absorbs the constraint")
        harness.assert_near(vars.x.x1, 0, 1e-2, "x1 (expensive) stays near zero")
    end,
})

return cases
