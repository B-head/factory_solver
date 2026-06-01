-- Two independent lower-bound targets that share intermediate recipes, so
-- the LP has to allocate enough shared throughput to feed both branches at
-- once -- a regime not exercised by lp_lower_limit (single target) or
-- lp_short_loop (cyclic but no branching).
--
-- Captured from a vanilla (no Space Age) save with both rocket-part and
-- utility-science-pack pinned at 1000 / min (= 16.666... / s). The dependency
-- graph is:
--   rocket-part            <- processing-unit, low-density-structure, rocket-fuel
--   utility-science-pack   <- processing-unit, flying-robot-frame, low-density-structure
-- Shared intermediates: processing-unit, low-density-structure.
-- Branch-only: rocket-fuel (rocket-part) and flying-robot-frame (science).
-- All raw inputs (electronic-circuit, copper-plate, ...) bottom out into
-- initial_source primals; this fixture intentionally has no further upstream
-- recipes so the LP layer is isolated from create_problem.
--
-- The expected optimum is exact: rocket-part = 50, utility-science-pack =
-- 93.333..., processing-unit = 222.222..., low-density-structure = 400,
-- flying-robot-frame = 88.888..., rocket-fuel = 200. Every surplus_sink and
-- both elastic-limit slacks sit at zero. Any regression that drops one
-- branch (elastic slack absorbs the bound instead) is caught by the
-- elastic-stays-at-zero assertions.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local pg = require "solver/problem_generator"

local cases = {}

table.insert(cases, {
    name = "two lower-bound targets sharing intermediates both run at the bound",
    run = function()
        local p = pg.new("vanilla-rocket-and-science")

        -- Primals (26): 6 recipes (results) + 4 surplus sinks +
        -- 2 final sinks + 10 basic sources + 2 lower-bound slack pairs.
        p:add_objective("recipe/rocket-part",            0, true)
        p:add_objective("recipe/utility-science-pack",   0, true)
        p:add_objective("recipe/processing-unit",        0, true)
        p:add_objective("recipe/flying-robot-frame",     0, true)
        p:add_objective("recipe/low-density-structure",  0, true)
        p:add_objective("recipe/rocket-fuel",            0, true)

        p:add_objective("|surplus_sink|processing-unit",        1024, false)
        p:add_objective("|surplus_sink|flying-robot-frame",     1024, false)
        p:add_objective("|surplus_sink|low-density-structure",  1024, false)
        p:add_objective("|surplus_sink|rocket-fuel",            1024, false)

        p:add_objective("|final_sink|rocket-part",          0, false)
        p:add_objective("|final_sink|utility-science-pack", 0, false)

        p:add_objective("|initial_source|electronic-circuit",   1,    false)
        p:add_objective("|initial_source|advanced-circuit",     1,    false)
        p:add_objective("|initial_source|sulfuric-acid",        0.1,  false)
        p:add_objective("|initial_source|steel-plate",          1,    false)
        p:add_objective("|initial_source|battery",              1,    false)
        p:add_objective("|initial_source|electric-engine-unit", 1,    false)
        p:add_objective("|initial_source|copper-plate",         1,    false)
        p:add_objective("|initial_source|plastic-bar",          1,    false)
        p:add_objective("|initial_source|solid-fuel",           1,    false)
        p:add_objective("|initial_source|light-oil",            0.1,  false)

        p:add_objective("%negative_slack%|limit|rocket-part",          0,       false)
        p:add_objective("|elastic||limit|rocket-part",                 1048576, false)
        p:add_objective("%negative_slack%|limit|utility-science-pack", 0,       false)
        p:add_objective("|elastic||limit|utility-science-pack",        1048576, false)

        -- Duals (18): 16 material balances + 2 lower-bound rows pinned at
        -- 1000 / min.
        p:add_equivalence_constraint("processing-unit",        0)
        p:add_equivalence_constraint("flying-robot-frame",     0)
        p:add_equivalence_constraint("low-density-structure",  0)
        p:add_equivalence_constraint("rocket-fuel",            0)
        p:add_equivalence_constraint("rocket-part",            0)
        p:add_equivalence_constraint("utility-science-pack",   0)
        p:add_equivalence_constraint("electronic-circuit",     0)
        p:add_equivalence_constraint("advanced-circuit",       0)
        p:add_equivalence_constraint("sulfuric-acid",          0)
        p:add_equivalence_constraint("steel-plate",            0)
        p:add_equivalence_constraint("battery",                0)
        p:add_equivalence_constraint("electric-engine-unit",   0)
        p:add_equivalence_constraint("copper-plate",           0)
        p:add_equivalence_constraint("plastic-bar",            0)
        p:add_equivalence_constraint("solid-fuel",             0)
        p:add_equivalence_constraint("light-oil",              0)
        p:add_equivalence_constraint("|limit|rocket-part",          1000 / 60)
        p:add_equivalence_constraint("|limit|utility-science-pack", 1000 / 60)

        -- A matrix: shared intermediates (processing-unit, low-density-
        -- structure) carry contributions from both rocket-part and utility-
        -- science-pack; branch-only intermediates each carry exactly one.
        -- processing-unit
        p:add_subject_term("recipe/rocket-part",          "processing-unit", -0.333333)
        p:add_subject_term("recipe/utility-science-pack", "processing-unit", -0.119048)
        p:add_subject_term("recipe/processing-unit",      "processing-unit",  0.125)
        p:add_subject_term("|surplus_sink|processing-unit", "processing-unit", -1)
        -- flying-robot-frame (only the science branch)
        p:add_subject_term("recipe/utility-science-pack", "flying-robot-frame", -0.059524)
        p:add_subject_term("recipe/flying-robot-frame",   "flying-robot-frame",  0.0625)
        p:add_subject_term("|surplus_sink|flying-robot-frame", "flying-robot-frame", -1)
        -- low-density-structure (shared)
        p:add_subject_term("recipe/rocket-part",          "low-density-structure", -0.333333)
        p:add_subject_term("recipe/utility-science-pack", "low-density-structure", -0.178571)
        p:add_subject_term("recipe/low-density-structure", "low-density-structure", 0.083333)
        p:add_subject_term("|surplus_sink|low-density-structure", "low-density-structure", -1)
        -- rocket-fuel (only the rocket branch)
        p:add_subject_term("recipe/rocket-part",  "rocket-fuel", -0.333333)
        p:add_subject_term("recipe/rocket-fuel",  "rocket-fuel",  0.083333)
        p:add_subject_term("|surplus_sink|rocket-fuel", "rocket-fuel", -1)
        -- targets feed final sinks
        p:add_subject_term("recipe/rocket-part",         "rocket-part",         0.333333)
        p:add_subject_term("|final_sink|rocket-part",    "rocket-part",        -1)
        p:add_subject_term("recipe/utility-science-pack", "utility-science-pack", 0.178571)
        p:add_subject_term("|final_sink|utility-science-pack", "utility-science-pack", -1)
        -- raw inputs <- initial_sources
        p:add_subject_term("recipe/processing-unit",     "electronic-circuit", -2.5)
        p:add_subject_term("recipe/flying-robot-frame",  "electronic-circuit", -0.1875)
        p:add_subject_term("|initial_source|electronic-circuit", "electronic-circuit", 1)
        p:add_subject_term("recipe/processing-unit",     "advanced-circuit",   -0.25)
        p:add_subject_term("|initial_source|advanced-circuit", "advanced-circuit", 1)
        p:add_subject_term("recipe/processing-unit",     "sulfuric-acid",      -0.625)
        p:add_subject_term("|initial_source|sulfuric-acid", "sulfuric-acid",       1)
        p:add_subject_term("recipe/flying-robot-frame",  "steel-plate",        -0.0625)
        p:add_subject_term("recipe/low-density-structure", "steel-plate",      -0.166667)
        p:add_subject_term("|initial_source|steel-plate",  "steel-plate",         1)
        p:add_subject_term("recipe/flying-robot-frame",  "battery",            -0.125)
        p:add_subject_term("|initial_source|battery",      "battery",             1)
        p:add_subject_term("recipe/flying-robot-frame",  "electric-engine-unit", -0.0625)
        p:add_subject_term("|initial_source|electric-engine-unit", "electric-engine-unit", 1)
        p:add_subject_term("recipe/low-density-structure", "copper-plate",     -1.666667)
        p:add_subject_term("|initial_source|copper-plate", "copper-plate",        1)
        p:add_subject_term("recipe/low-density-structure", "plastic-bar",      -0.416667)
        p:add_subject_term("|initial_source|plastic-bar",  "plastic-bar",         1)
        p:add_subject_term("recipe/rocket-fuel",         "solid-fuel",         -0.833333)
        p:add_subject_term("|initial_source|solid-fuel",   "solid-fuel",          1)
        p:add_subject_term("recipe/rocket-fuel",         "light-oil",          -0.833333)
        p:add_subject_term("|initial_source|light-oil",    "light-oil",           1)
        -- lower-bound rows: recipe_rate * out_per_recipe - neg_slack + elastic = limit
        p:add_subject_term("recipe/rocket-part",                       "|limit|rocket-part",  0.333333)
        p:add_subject_term("%negative_slack%|limit|rocket-part",       "|limit|rocket-part", -1)
        p:add_subject_term("|elastic||limit|rocket-part",              "|limit|rocket-part",  1)
        p:add_subject_term("recipe/utility-science-pack",              "|limit|utility-science-pack",  0.178571)
        p:add_subject_term("%negative_slack%|limit|utility-science-pack", "|limit|utility-science-pack", -1)
        p:add_subject_term("|elastic||limit|utility-science-pack",     "|limit|utility-science-pack",  1)

        local state, vars, steps = harness.solve_to_completion(lp, p,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        harness.assert_true(steps < 100, "converged in under 100 iterations (took " .. steps .. ")")

        -- Both branches at their bound, neither shortcut via the elastic.
        harness.assert_near(vars.x["recipe/rocket-part"],          50,         5e-3, "rocket-part rate")
        harness.assert_near(vars.x["recipe/utility-science-pack"], 280 / 3,    5e-3, "utility-science-pack rate")
        harness.assert_near(vars.x["recipe/processing-unit"],      2000 / 9,   5e-3, "processing-unit rate")
        harness.assert_near(vars.x["recipe/flying-robot-frame"],   800 / 9,    5e-3, "flying-robot-frame rate")
        harness.assert_near(vars.x["recipe/low-density-structure"], 400,       5e-3, "low-density-structure rate")
        harness.assert_near(vars.x["recipe/rocket-fuel"],          200,        5e-3, "rocket-fuel rate")

        -- Elastic must stay near zero -- if either bound got absorbed by
        -- elastic, the corresponding recipe primal would also be at zero,
        -- which the rate assertions above already catch. The slack checks
        -- below pin the *mechanism* (no silent infeasibility) on top.
        harness.assert_near(vars.x["|elastic||limit|rocket-part"],          0, 1e-3, "rocket-part elastic idle")
        harness.assert_near(vars.x["|elastic||limit|utility-science-pack"], 0, 1e-3, "science elastic idle")

        -- Shared-intermediate sanity: processing-unit demand is the sum of
        -- both branches' usage, not just one branch's.
        --   demand = 50 * 0.333333 + (280/3) * 0.119048 ≈ 16.667 + 11.111 = 27.778
        --   supply = recipe/processing-unit * 0.125
        --   supply must equal demand for the surplus_sink to stay at zero.
        harness.assert_near(vars.x["|surplus_sink|processing-unit"],       0, 1e-2, "processing-unit not over-produced")
        harness.assert_near(vars.x["|surplus_sink|low-density-structure"], 0, 1e-2, "low-density-structure not over-produced")
    end,
})

return cases
