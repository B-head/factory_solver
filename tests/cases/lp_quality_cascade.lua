-- Single-producer quality cascade fixtures: a recipe that emits its product
-- split across several quality tiers (what pre_solve.quality_decomposition
-- produces). No recycler loops here — those live in lp_quality_recycling_loop.
-- These cases exercise the LP's ability to balance flow when a producer
-- generates multiple sibling materials at once, with mismatched per-quality
-- consumers.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local fixture = require "tests/cases/fixture"
local QUALITY = fixture.QUALITY
local item, line, cascade = fixture.item, fixture.line, fixture.cascade

local cases = {}

table.insert(cases, {
    name = "2-tier cascade with constraint on the dominant (normal) tier converges",
    -- iron-plate recipe with 10% quality module: 1 iron-ore -> [normal 0.9,
    -- uncommon 0.1] iron-plate per machine. Constraint: produce 0.9 normal
    -- iron-plate/s (= exactly one machine's normal output). uncommon iron-plate
    -- has no consumer so it goes to its own free final_sink.
    run = function()
        local lines = {
            line("iron-plate", "normal",
                cascade("iron-plate", 1, "normal", 2),
                { item("iron-ore", "normal", 1) }),
        }
        local constraints = {
            { type = "item", name = "iron-plate", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 0.9 },
        }

        local problem = cp.create_problem("cascade-2t-normal", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_near(vars.x["recipe/iron-plate/normal"], 1, 0.05, "iron-plate machine count")
        harness.assert_near(vars.x["|final_sink|item/iron-plate/uncommon"], 0.1, 0.02,
            "uncommon iron-plate flows to its final_sink")
    end,
})

table.insert(cases, {
    name = "2-tier cascade with constraint on the rare (uncommon) tier converges",
    -- Same producer, but constrain the uncommon tier. The LP must run the
    -- recipe 10x harder (since only 10% of its output is uncommon), then the
    -- normal tier flows out at 9x the constrained rate. This is the basic
    -- "produce one rare thing, dump everything else" pattern.
    run = function()
        local lines = {
            line("iron-plate", "normal",
                cascade("iron-plate", 1, "normal", 2),
                { item("iron-ore", "normal", 1) }),
        }
        local constraints = {
            { type = "item", name = "iron-plate", quality = "uncommon",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("cascade-2t-uncommon", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_near(vars.x["recipe/iron-plate/normal"], 10, 0.2, "iron-plate machine count")
        harness.assert_near(vars.x["|final_sink|item/iron-plate/normal"], 9, 0.2,
            "normal iron-plate flows out at 9x the constrained tier")
        harness.assert_near(vars.x["|final_sink|item/iron-plate/uncommon"], 1, 0.05,
            "uncommon iron-plate matches the constraint")
    end,
})

table.insert(cases, {
    name = "3-tier cascade with per-tier consumers picks the right balance",
    -- Producer iron-plate -> [n 0.9, u 0.09, r 0.01]. Two per-tier consumer
    -- recipes (circuit/normal and circuit/uncommon) drain the lower two
    -- tiers; rare has no consumer so it must flow to surplus_sink (priced).
    -- Constraint: produce 0.09 uncommon circuits/s. The optimum is one
    -- iron-plate machine (which produces the matching uncommon flow) with
    -- circuit/normal absorbing the 0.9 normal byproduct for free via its
    -- own final_sink.
    run = function()
        local lines = {
            line("iron-plate", "normal",
                cascade("iron-plate", 1, "normal", 3),
                { item("iron-ore", "normal", 1) }),
            line("circuit", "normal",
                { item("circuit", "normal", 1) },
                { item("iron-plate", "normal", 1) }),
            line("circuit", "uncommon",
                { item("circuit", "uncommon", 1) },
                { item("iron-plate", "uncommon", 1) }),
        }
        local constraints = {
            { type = "item", name = "circuit", quality = "uncommon",
              limit_type = "equal", limit_amount_per_second = 0.09 },
        }

        local problem = cp.create_problem("cascade-3t-per-tier", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_near(vars.x["recipe/iron-plate/normal"], 1, 0.05, "iron-plate machine count")
        harness.assert_near(vars.x["recipe/circuit/uncommon"], 0.09, 0.01,
            "uncommon circuit recipe matches constraint")
        harness.assert_near(vars.x["recipe/circuit/normal"], 0.9, 0.05,
            "normal circuit recipe absorbs the 0.9 normal byproduct")
    end,
})

return cases
