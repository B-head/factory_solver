-- Two upper-bound resource caps both binding at the optimum, with production
-- of a single downstream product (plastic-bar) split across the recipe paths
-- those resources feed. This is the structural counterpart to
-- lp_branched_targets: there the *outputs* branch and share intermediates;
-- here the *inputs* branch and converge on a single output.
--
-- Captured from a vanilla (no Space Age) save with coal pinned at 30 / s and
-- crude-oil pinned at 500 / s (both upper-cap, slack priced high so the LP
-- saturates each cap exactly). The reachable graph includes:
--   crude-oil -[adv-oil-processing]-> {heavy, light, petroleum-gas}@25
--   coal + steam -[coal-liquefaction]-> {heavy, light, petroleum-gas}@25
--   {heavy, light}@25 -[cracking]-> {light, petroleum-gas}@25 (water-consuming)
--   coal + water -[boiler]-> steam@165 (feeds coal-liquefaction's steam input)
-- with temperature bridges connecting the @25 single-temp duals to the
-- @[25,25] range duals that plastic-bar / cracking actually consume.
--
-- The non-trivial property: the LP must use BOTH crude and coal paths to
-- maximise plastic-bar -- advanced-oil-processing alone (500 crude) wouldn't
-- saturate coal, and coal-liquefaction alone would leave crude on the table.
-- A regression that mistakenly drops one source recipe would still satisfy
-- the constraints (the dropped source's cap just goes unused) but the
-- plastic-bar throughput would drop, so we pin both the saturated caps
-- *and* the resulting product rate.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local pg = require "solver/problem_generator"

local cases = {}

table.insert(cases, {
    name = "two upper-bound resource caps both bind; plastic-bar splits across crude / coal paths",
    run = function()
        local p = pg.new("vanilla-oil-coal-to-plastic")

        -- 24 primals.
        p:add_objective("recipe/plastic-bar",                                  0, true)
        p:add_objective("recipe/light-oil-cracking",                           0, true)
        p:add_objective("recipe/heavy-oil-cracking",                           0, true)
        p:add_objective("recipe/advanced-oil-processing",                      0, true)
        p:add_objective("recipe/coal-liquefaction",                            0, true)
        p:add_objective("virtual_recipe/<run>boiler:water",                    0, true)
        p:add_objective("virtual_recipe/|bridge|heavy-oil@25->[25,25]",        0, true)
        p:add_objective("virtual_recipe/|bridge|light-oil@25->[25,25]",        0, true)
        p:add_objective("virtual_recipe/|bridge|petroleum-gas@25->[25,25]",    0, true)
        p:add_objective("virtual_recipe/|bridge|steam@165->[15,5000]",         0, true)

        p:add_objective("|surplus_sink|petroleum-gas@25",        1024, false)
        p:add_objective("|surplus_sink|light-oil@25",            1024, false)
        p:add_objective("|surplus_sink|heavy-oil@25",            1024, false)
        p:add_objective("|surplus_sink|steam@165",               1024, false)
        p:add_objective("|surplus_sink|heavy-oil@[25,25]",       1024, false)
        p:add_objective("|surplus_sink|light-oil@[25,25]",       1024, false)
        p:add_objective("|surplus_sink|petroleum-gas@[25,25]",   1024, false)
        p:add_objective("|surplus_sink|steam@[15,5000]",         1024, false)

        p:add_objective("|final_sink|plastic-bar",   0,   false)
        p:add_objective("|initial_source|coal",        1,   false)
        p:add_objective("|initial_source|water",       0.1, false)
        p:add_objective("|initial_source|crude-oil",   0.1, false)

        p:add_objective("%positive_slack%|limit|crude-oil", 1048576, false)
        p:add_objective("%positive_slack%|limit|coal",      1048576, false)

        -- 14 duals: 8 fluid material rows + 4 item/raw rows + 2 limit rows.
        p:add_equivalence_constraint("petroleum-gas@25",        0)
        p:add_equivalence_constraint("light-oil@25",            0)
        p:add_equivalence_constraint("heavy-oil@25",            0)
        p:add_equivalence_constraint("steam@165",               0)
        p:add_equivalence_constraint("heavy-oil@[25,25]",       0)
        p:add_equivalence_constraint("light-oil@[25,25]",       0)
        p:add_equivalence_constraint("petroleum-gas@[25,25]",   0)
        p:add_equivalence_constraint("steam@[15,5000]",         0)
        p:add_equivalence_constraint("plastic-bar",             0)
        p:add_equivalence_constraint("coal",                    0)
        p:add_equivalence_constraint("water",                   0)
        p:add_equivalence_constraint("crude-oil",               0)
        p:add_equivalence_constraint("|limit|crude-oil",        500)
        p:add_equivalence_constraint("|limit|coal",             30)

        -- petroleum-gas@25 sources / drains
        p:add_subject_term("recipe/light-oil-cracking",      "petroleum-gas@25", 10)
        p:add_subject_term("recipe/advanced-oil-processing", "petroleum-gas@25", 11)
        p:add_subject_term("recipe/coal-liquefaction",       "petroleum-gas@25", 2)
        p:add_subject_term("virtual_recipe/|bridge|petroleum-gas@25->[25,25]", "petroleum-gas@25", -1)
        p:add_subject_term("|surplus_sink|petroleum-gas@25", "petroleum-gas@25", -1)

        -- light-oil@25 sources / drains
        p:add_subject_term("recipe/heavy-oil-cracking",      "light-oil@25", 15)
        p:add_subject_term("recipe/advanced-oil-processing", "light-oil@25", 9)
        p:add_subject_term("recipe/coal-liquefaction",       "light-oil@25", 4)
        p:add_subject_term("virtual_recipe/|bridge|light-oil@25->[25,25]", "light-oil@25", -1)
        p:add_subject_term("|surplus_sink|light-oil@25",     "light-oil@25", -1)

        -- heavy-oil@25 sources / drains
        p:add_subject_term("recipe/advanced-oil-processing", "heavy-oil@25", 5)
        p:add_subject_term("recipe/coal-liquefaction",       "heavy-oil@25", 18)
        p:add_subject_term("virtual_recipe/|bridge|heavy-oil@25->[25,25]", "heavy-oil@25", -1)
        p:add_subject_term("|surplus_sink|heavy-oil@25",     "heavy-oil@25", -1)

        -- steam@165 sources / drains (boiler produces, bridge consumes)
        p:add_subject_term("virtual_recipe/<run>boiler:water",            "steam@165", 60)
        p:add_subject_term("virtual_recipe/|bridge|steam@165->[15,5000]", "steam@165", -1)
        p:add_subject_term("|surplus_sink|steam@165",                     "steam@165", -1)

        -- heavy-oil@[25,25] consumers (heavy-oil-cracking, coal-liquefaction)
        p:add_subject_term("recipe/heavy-oil-cracking", "heavy-oil@[25,25]", -20)
        p:add_subject_term("recipe/coal-liquefaction",  "heavy-oil@[25,25]", -5)
        p:add_subject_term("virtual_recipe/|bridge|heavy-oil@25->[25,25]", "heavy-oil@[25,25]", 1)
        p:add_subject_term("|surplus_sink|heavy-oil@[25,25]", "heavy-oil@[25,25]", -1)

        -- light-oil@[25,25] consumer (light-oil-cracking)
        p:add_subject_term("recipe/light-oil-cracking", "light-oil@[25,25]", -15)
        p:add_subject_term("virtual_recipe/|bridge|light-oil@25->[25,25]", "light-oil@[25,25]", 1)
        p:add_subject_term("|surplus_sink|light-oil@[25,25]", "light-oil@[25,25]", -1)

        -- petroleum-gas@[25,25] consumer (plastic-bar)
        p:add_subject_term("recipe/plastic-bar", "petroleum-gas@[25,25]", -20)
        p:add_subject_term("virtual_recipe/|bridge|petroleum-gas@25->[25,25]", "petroleum-gas@[25,25]", 1)
        p:add_subject_term("|surplus_sink|petroleum-gas@[25,25]", "petroleum-gas@[25,25]", -1)

        -- steam@[15,5000] consumer (coal-liquefaction)
        p:add_subject_term("recipe/coal-liquefaction", "steam@[15,5000]", -10)
        p:add_subject_term("virtual_recipe/|bridge|steam@165->[15,5000]", "steam@[15,5000]", 1)
        p:add_subject_term("|surplus_sink|steam@[15,5000]", "steam@[15,5000]", -1)

        -- plastic-bar production / consumption
        p:add_subject_term("recipe/plastic-bar",     "plastic-bar",  2)
        p:add_subject_term("|final_sink|plastic-bar", "plastic-bar", -1)

        -- coal: consumed by plastic-bar, coal-liquefaction, boiler; sourced by initial_source.
        p:add_subject_term("recipe/plastic-bar",                "coal", -1)
        p:add_subject_term("recipe/coal-liquefaction",          "coal", -2)
        p:add_subject_term("virtual_recipe/<run>boiler:water",  "coal", -0.45)
        p:add_subject_term("|initial_source|coal",                "coal", 1)

        -- water: consumed by cracking + adv-oil-processing + boiler.
        p:add_subject_term("recipe/light-oil-cracking",      "water", -15)
        p:add_subject_term("recipe/heavy-oil-cracking",      "water", -15)
        p:add_subject_term("recipe/advanced-oil-processing", "water", -10)
        p:add_subject_term("virtual_recipe/<run>boiler:water", "water", -6)
        p:add_subject_term("|initial_source|water",            "water", 1)

        -- crude-oil: consumed by advanced-oil-processing.
        p:add_subject_term("recipe/advanced-oil-processing", "crude-oil", -20)
        p:add_subject_term("|initial_source|crude-oil",        "crude-oil", 1)

        -- Upper-cap constraint rows (initial_source + slack = limit).
        p:add_subject_term("|initial_source|crude-oil",            "|limit|crude-oil", 1)
        p:add_subject_term("%positive_slack%|limit|crude-oil",   "|limit|crude-oil", 1)
        p:add_subject_term("|initial_source|coal",                 "|limit|coal", 1)
        p:add_subject_term("%positive_slack%|limit|coal",        "|limit|coal", 1)

        local state, vars, steps = harness.solve_to_completion(lp, p,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        harness.assert_true(steps < 100, "converged in under 100 iterations (took " .. steps .. ")")

        -- Both resource caps saturated exactly (slacks at zero).
        harness.assert_near(vars.x["|initial_source|crude-oil"],            500, 5e-2, "crude saturated")
        harness.assert_near(vars.x["|initial_source|coal"],                  30, 5e-3, "coal saturated")
        harness.assert_near(vars.x["%positive_slack%|limit|crude-oil"],     0, 1e-3, "crude slack idle")
        harness.assert_near(vars.x["%positive_slack%|limit|coal"],          0, 1e-3, "coal slack idle")

        -- Both source recipes contribute -- regression net for "LP drops
        -- one source path" failures.
        harness.assert_near(vars.x["recipe/advanced-oil-processing"], 25,        5e-3, "crude path: adv-oil-processing")
        harness.assert_true(vars.x["recipe/coal-liquefaction"]      > 0.5,
            "coal path: coal-liquefaction must run (got " ..
            tostring(vars.x["recipe/coal-liquefaction"]) .. ")")
        harness.assert_near(vars.x["recipe/coal-liquefaction"],        2.136076, 5e-3, "coal path: coal-liquefaction rate")

        -- Resulting plastic-bar output (sum across both paths).
        harness.assert_near(vars.x["recipe/plastic-bar"],          25.567642, 5e-3, "plastic-bar rate")
        harness.assert_near(vars.x["|final_sink|plastic-bar"],     51.135285, 1e-2, "plastic-bar throughput to final sink")

        -- Cracking + boiler intermediates also pinned -- catches a
        -- regression that finds a different optimum (e.g. ignoring the
        -- boiler and over-paying water surplus instead).
        harness.assert_near(vars.x["recipe/light-oil-cracking"],   23.208070, 5e-3, "light-oil-cracking")
        harness.assert_near(vars.x["recipe/heavy-oil-cracking"],    7.638449, 5e-3, "heavy-oil-cracking")
        harness.assert_near(vars.x["virtual_recipe/<run>boiler:water"], 0.356013, 5e-3, "boiler-water")

        -- All surplus sinks must be zero -- LP should not over-produce
        -- any intermediate when both caps are binding.
        for _, name in ipairs({
            "|surplus_sink|petroleum-gas@25", "|surplus_sink|light-oil@25",
            "|surplus_sink|heavy-oil@25",     "|surplus_sink|steam@165",
            "|surplus_sink|heavy-oil@[25,25]", "|surplus_sink|light-oil@[25,25]",
            "|surplus_sink|petroleum-gas@[25,25]", "|surplus_sink|steam@[15,5000]",
        }) do
            harness.assert_near(vars.x[name], 0, 1e-2, name .. " idle")
        end
    end,
})

return cases
