-- One upper-bound INPUT cap (crude-oil <= 500/s) and one lower-bound OUTPUT
-- target (plastic-bar >= 60/s = 1/s scale of the in-game user case). Same
-- vanilla oil + coal chemistry chain as lp_dual_resource_caps, but the
-- constraint roles are asymmetric: coal is no longer capped, so the LP can
-- freely scale coal-liquefaction up to whatever extra plastic-bar throughput
-- the crude path alone can't deliver.
--
-- Why this is its own fixture, not a parametrisation of lp_dual_resource_caps:
-- the |limit|plastic-bar row has a structurally different shape -- it
-- couples a *recipe* primal (recipe/plastic-bar at +2) to a %negative_slack%
-- and an |elastic| primal, whereas upper-cap rows couple a *initial_source*
-- primal to a %positive_slack%. The LP must drive both the negative_slack
-- AND the elastic to zero for the lower bound to bind exactly. A regression
-- that lets elastic absorb the bound (the failure mode lp_lower_limit was
-- written for) would still satisfy KKT, so the elastic-stays-at-zero
-- assertion is load-bearing.
--
-- Captured from the same vanilla save as lp_dual_resource_caps after the
-- user changed constraints to crude=500 upper + plastic-bar=60 lower.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local pg = require "solver/problem_generator"

local cases = {}

table.insert(cases, {
    name = "input cap + output target: chain bridges crude=500 cap to plastic-bar=60 target",
    run = function()
        local p = pg.new("vanilla-oil-coal-to-plastic-target")

        -- 25 primals.
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

        -- Upper-cap slack on crude; lower-target slack + elastic on plastic-bar.
        p:add_objective("%positive_slack%|limit|crude-oil",   1048576, false)
        p:add_objective("%negative_slack%|limit|plastic-bar", 0,       false)
        p:add_objective("|elastic||limit|plastic-bar",        1048576, false)

        -- 14 duals.
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
        p:add_equivalence_constraint("|limit|plastic-bar",      60)

        -- petroleum-gas@25
        p:add_subject_term("recipe/light-oil-cracking",      "petroleum-gas@25", 10)
        p:add_subject_term("recipe/advanced-oil-processing", "petroleum-gas@25", 11)
        p:add_subject_term("recipe/coal-liquefaction",       "petroleum-gas@25", 2)
        p:add_subject_term("virtual_recipe/|bridge|petroleum-gas@25->[25,25]", "petroleum-gas@25", -1)
        p:add_subject_term("|surplus_sink|petroleum-gas@25", "petroleum-gas@25", -1)

        -- light-oil@25
        p:add_subject_term("recipe/heavy-oil-cracking",      "light-oil@25", 15)
        p:add_subject_term("recipe/advanced-oil-processing", "light-oil@25", 9)
        p:add_subject_term("recipe/coal-liquefaction",       "light-oil@25", 4)
        p:add_subject_term("virtual_recipe/|bridge|light-oil@25->[25,25]", "light-oil@25", -1)
        p:add_subject_term("|surplus_sink|light-oil@25",     "light-oil@25", -1)

        -- heavy-oil@25
        p:add_subject_term("recipe/advanced-oil-processing", "heavy-oil@25", 5)
        p:add_subject_term("recipe/coal-liquefaction",       "heavy-oil@25", 18)
        p:add_subject_term("virtual_recipe/|bridge|heavy-oil@25->[25,25]", "heavy-oil@25", -1)
        p:add_subject_term("|surplus_sink|heavy-oil@25",     "heavy-oil@25", -1)

        -- steam@165
        p:add_subject_term("virtual_recipe/<run>boiler:water",            "steam@165", 60)
        p:add_subject_term("virtual_recipe/|bridge|steam@165->[15,5000]", "steam@165", -1)
        p:add_subject_term("|surplus_sink|steam@165",                     "steam@165", -1)

        -- heavy-oil@[25,25]
        p:add_subject_term("recipe/heavy-oil-cracking", "heavy-oil@[25,25]", -20)
        p:add_subject_term("recipe/coal-liquefaction",  "heavy-oil@[25,25]", -5)
        p:add_subject_term("virtual_recipe/|bridge|heavy-oil@25->[25,25]", "heavy-oil@[25,25]", 1)
        p:add_subject_term("|surplus_sink|heavy-oil@[25,25]", "heavy-oil@[25,25]", -1)

        -- light-oil@[25,25]
        p:add_subject_term("recipe/light-oil-cracking", "light-oil@[25,25]", -15)
        p:add_subject_term("virtual_recipe/|bridge|light-oil@25->[25,25]", "light-oil@[25,25]", 1)
        p:add_subject_term("|surplus_sink|light-oil@[25,25]", "light-oil@[25,25]", -1)

        -- petroleum-gas@[25,25]
        p:add_subject_term("recipe/plastic-bar", "petroleum-gas@[25,25]", -20)
        p:add_subject_term("virtual_recipe/|bridge|petroleum-gas@25->[25,25]", "petroleum-gas@[25,25]", 1)
        p:add_subject_term("|surplus_sink|petroleum-gas@[25,25]", "petroleum-gas@[25,25]", -1)

        -- steam@[15,5000]
        p:add_subject_term("recipe/coal-liquefaction", "steam@[15,5000]", -10)
        p:add_subject_term("virtual_recipe/|bridge|steam@165->[15,5000]", "steam@[15,5000]", 1)
        p:add_subject_term("|surplus_sink|steam@[15,5000]", "steam@[15,5000]", -1)

        -- plastic-bar production / final sink
        p:add_subject_term("recipe/plastic-bar",      "plastic-bar",  2)
        p:add_subject_term("|final_sink|plastic-bar", "plastic-bar", -1)

        -- coal balance: consumed by plastic-bar / coal-liquefaction / boiler;
        -- supplied by initial_source (uncapped this time).
        p:add_subject_term("recipe/plastic-bar",                "coal", -1)
        p:add_subject_term("recipe/coal-liquefaction",          "coal", -2)
        p:add_subject_term("virtual_recipe/<run>boiler:water",  "coal", -0.45)
        p:add_subject_term("|initial_source|coal",                "coal", 1)

        -- water balance
        p:add_subject_term("recipe/light-oil-cracking",      "water", -15)
        p:add_subject_term("recipe/heavy-oil-cracking",      "water", -15)
        p:add_subject_term("recipe/advanced-oil-processing", "water", -10)
        p:add_subject_term("virtual_recipe/<run>boiler:water", "water", -6)
        p:add_subject_term("|initial_source|water",            "water", 1)

        -- crude-oil balance (single consumer, the only capped input)
        p:add_subject_term("recipe/advanced-oil-processing", "crude-oil", -20)
        p:add_subject_term("|initial_source|crude-oil",        "crude-oil", 1)

        -- Upper-cap row: initial_source + slack = limit.
        p:add_subject_term("|initial_source|crude-oil",          "|limit|crude-oil", 1)
        p:add_subject_term("%positive_slack%|limit|crude-oil", "|limit|crude-oil", 1)

        -- Lower-target row: 2 * recipe_rate - negative_slack + elastic = 60.
        -- Same shape as lp_lower_limit's target column, just on a different
        -- chain.
        p:add_subject_term("recipe/plastic-bar",                "|limit|plastic-bar",  2)
        p:add_subject_term("%negative_slack%|limit|plastic-bar","|limit|plastic-bar", -1)
        p:add_subject_term("|elastic||limit|plastic-bar",       "|limit|plastic-bar",  1)

        local state, vars, steps = harness.solve_to_completion(lp, p,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        harness.assert_true(steps < 100, "converged in under 100 iterations (took " .. steps .. ")")

        -- Crude cap tight, plastic-bar target met exactly, both slacks zero.
        harness.assert_near(vars.x["|initial_source|crude-oil"],          500, 5e-2, "crude saturated")
        harness.assert_near(vars.x["%positive_slack%|limit|crude-oil"],   0, 1e-3, "crude slack idle")
        harness.assert_near(vars.x["%negative_slack%|limit|plastic-bar"], 0, 1e-3, "plastic-bar over-target slack idle")
        harness.assert_near(vars.x["|elastic||limit|plastic-bar"],        0, 1e-3,
            "elastic must stay at zero -- lower target should bind structurally, not via the elastic")

        -- Both source recipes must run: crude path saturates at advanced-
        -- oil-processing = 500/20 = 25, coal path picks up the rest.
        harness.assert_near(vars.x["recipe/advanced-oil-processing"], 25,         5e-3, "adv-oil-processing at the crude cap")
        harness.assert_near(vars.x["recipe/coal-liquefaction"],       10.074627,  5e-3, "coal-liquefaction picks up the slack")

        -- Plastic-bar at the target rate (60/2 = 30 recipe executions).
        harness.assert_near(vars.x["recipe/plastic-bar"],        30,        5e-3, "plastic-bar at target")
        harness.assert_near(vars.x["|final_sink|plastic-bar"],   60,        5e-2, "plastic-bar throughput hits the lower bound")

        -- Coal demand rises naturally: 30 (plastic-bar) + 2 * 10.074627
        -- (coal-liquefaction) + 0.45 * 1.679104 (boiler) = 50.904851.
        harness.assert_near(vars.x["|initial_source|coal"], 50.904851, 5e-2, "coal scales to meet the target")

        -- Cracking + boiler intermediates pinned at the captured optimum.
        harness.assert_near(vars.x["recipe/light-oil-cracking"],   30.485075, 5e-3, "light-oil-cracking")
        harness.assert_near(vars.x["recipe/heavy-oil-cracking"],   12.798507, 5e-3, "heavy-oil-cracking")
        harness.assert_near(vars.x["virtual_recipe/<run>boiler:water"], 1.679104, 5e-3, "boiler-water")

        -- All surplus sinks must be zero.
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
