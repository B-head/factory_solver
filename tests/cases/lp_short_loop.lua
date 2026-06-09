-- Integration test that drives the full create_problem -> IPM pipeline
-- against NormalizedProductionLine fixtures that mirror the fs-test-* debug
-- recipes in data.lua. This is the regression net for the cyclic-LP behaviour
-- the mod exists to handle.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local fixture = require "tests/cases/fixture"
local item, line = fixture.item, fixture.line

local cases = {}

table.insert(cases, {
    name = "linear two-recipe chain with an equality constraint converges",
    -- m1 --[r1]--> m2 --[r2]--> m3, pin m3 == 5/s.
    -- Both recipes are 1:1, so both should run at 5/s and the basic-source
    -- of m1 should supply 5/s. `equal` is what forces the rate here: a
    -- bare `lower` would leave the LP unbounded because recipe cost is a
    -- mild negative (run-preference) with no upper cap.
    run = function()
        local lines = {
            line("r1", { item("m2", 1) }, { item("m1", 1) }),
            line("r2", { item("m3", 1) }, { item("m2", 1) }),
        }
        local constraints = {
            { type = "item", name = "m3", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 5 },
        }

        local problem = cp.create_problem("chain", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_near(vars.x["recipe/r1/normal"], 5, 0.1, "r1 rate")
        harness.assert_near(vars.x["recipe/r2/normal"], 5, 0.1, "r2 rate")
    end,
})

table.insert(cases, {
    name = "short cyclic loop (base + short-positive) reaches a terminal state",
    -- A cycle on speed-module <-> speed-module-2 with a non-cycle input
    -- (efficiency-module) and a non-cycle output (efficiency-module-2). This
    -- is the canonical short-loop topology; it is the case 0.3.12 / 0.3.14
    -- fixed; the assertion is that the LP converges (does not return
    -- "unbounded" / "unfeasible") and that the requested product comes out.
    run = function()
        local lines = {
            line("base",
                { item("efficiency-module-2", 1), item("speed-module-2", 1) },
                { item("efficiency-module",   1), item("speed-module",   1) }),
            line("short-positive",
                { item("speed-module", 2) },
                { item("speed-module-2", 1) }),
        }
        local constraints = {
            { type = "item", name = "efficiency-module-2", quality = "normal",
              limit_type = "lower", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("short-loop", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_true(
            vars.x["recipe/base/normal"] > 0.5,
            "base recipe runs (got " .. tostring(vars.x["recipe/base/normal"]) .. ")"
        )
    end,
})

return cases
