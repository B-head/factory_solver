-- Gleba (Space Age) agricultural-science-pack chain: a self-referential
-- nutrient/bioflux loop that is the *canonical* reason factory_solver uses
-- an LP solver instead of unrolled BOM math.
--
-- The structural feature this fixture pins:
--   nutrients-from-bioflux: 5 bioflux -> 59.75 nutrients (huge multiplier)
--   bioflux:                0.25 nutrients + 4 jelly + 5 yumako-mash -> 2 bioflux
-- bioflux requires nutrients to be made; nutrients-from-bioflux requires
-- bioflux to be made. The only thing that breaks the chicken-and-egg is
-- the external seed via yumako/jellynut initial_sources (which then feed
-- jellynut-processing / yumako-processing -- both of which themselves
-- consume 0.25 nutrients, making the bootstrap non-trivial). The LP must
-- find a fixed point where:
--   bioflux production = bioflux demand (loop closes)
--   nutrients production = nutrients demand (loop closes)
--   all |shortage_source| stays at zero (no shortage-gate cheat)
-- See solver/create_problem.lua's reachability gating and the
-- [[solver-shortage-source-design]] memory for the design rationale.
--
-- Captured from a real Gleba save with agricultural-science-pack pinned
-- at 30 / min = 0.5 / s via an upper-cap whose slack is priced at 2^20
-- (BIG-M, effectively pinning equality from above).
--
-- The expected optimum:
--   ASP recipe:                       0.5 / 0.75 = 2/3
--   pentapod-egg recipe:              0.5 * 0.5 / (0.2 - some loss) -> 5/3
--   nutrients-from-bioflux recipe:    0.125699 (small, but non-zero --
--                                       nutrients balance forces it)
--   bioflux recipe:                   0.480913
--   jellynut-processing recipe:       0.160304
--   yumako-processing recipe:         0.400761
-- Any regression that makes a shortage_source absorb part of the demand
-- (e.g. "loop too deep, give up and pay the shortage") would show as
-- |shortage_source| > 0 for nutrients or bioflux -- this fixture's
-- shortage-stays-at-zero assertions are the load-bearing checks.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local pg = require "solver/problem_generator"
local cp = require "solver/create_problem"

local function item(name, amount)
    return { type = "item", name = name, quality = "normal", amount_per_second = amount }
end

local function line(recipe_name, products, ingredients)
    return {
        recipe_typed_name = { type = "recipe", name = recipe_name, quality = "normal" },
        products = products,
        ingredients = ingredients,
        power_per_second = 0,
        pollution_per_second = 0,
    }
end

local cases = {}

table.insert(cases, {
    name = "Gleba ASP loop closes without firing any shortage_source",
    run = function()
        local p = pg.new("gleba-asp-loop")

        -- 23 primals.
        p:add_objective("recipe/agricultural-science-pack", 0, true)
        p:add_objective("recipe/pentapod-egg",              0, true)
        p:add_objective("recipe/nutrients-from-bioflux",    0, true)
        p:add_objective("recipe/bioflux",                   0, true)
        p:add_objective("recipe/jellynut-processing",       0, true)
        p:add_objective("recipe/yumako-processing",         0, true)

        -- Every loop material gets a surplus_sink AND shortage_source
        -- pair at elastic cost. The shortage_source is what create_problem
        -- adds when reachability gating concludes the material participates
        -- in a producer cycle; the LP should resolve the cycle via real
        -- recipes and leave shortage_source idle.
        for _, mat in ipairs({
            "pentapod-egg", "nutrients", "bioflux", "jelly", "yumako-mash",
        }) do
            p:add_objective("|surplus_sink|"     .. mat, 1024, false)
            p:add_objective("|shortage_source|"  .. mat, 1024, false)
        end

        p:add_objective("|final_sink|agricultural-science-pack", 0,   false)
        p:add_objective("|final_sink|jellynut-seed",             0,   false)
        p:add_objective("|final_sink|yumako-seed",               0,   false)
        p:add_objective("|initial_source|water",                   0.1, false)
        p:add_objective("|initial_source|jellynut",                1,   false)
        p:add_objective("|initial_source|yumako",                  1,   false)
        p:add_objective("%positive_slack%|limit|agricultural-science-pack",
                        1048576, false)

        -- 12 duals.
        p:add_equivalence_constraint("pentapod-egg", 0)
        p:add_equivalence_constraint("nutrients",    0)
        p:add_equivalence_constraint("bioflux",      0)
        p:add_equivalence_constraint("jelly",        0)
        p:add_equivalence_constraint("yumako-mash",  0)
        p:add_equivalence_constraint("agricultural-science-pack", 0)
        p:add_equivalence_constraint("jellynut-seed", 0)
        p:add_equivalence_constraint("yumako-seed",   0)
        p:add_equivalence_constraint("water",         0)
        p:add_equivalence_constraint("jellynut",      0)
        p:add_equivalence_constraint("yumako",        0)
        p:add_equivalence_constraint("|limit|agricultural-science-pack", 0.5)

        -- pentapod-egg balance
        p:add_subject_term("recipe/agricultural-science-pack", "pentapod-egg", -0.5)
        p:add_subject_term("recipe/pentapod-egg",              "pentapod-egg",  0.2)
        p:add_subject_term("|surplus_sink|pentapod-egg",       "pentapod-egg", -1)
        p:add_subject_term("|shortage_source|pentapod-egg",    "pentapod-egg",  1)

        -- nutrients balance -- the loop-critical row.
        p:add_subject_term("recipe/agricultural-science-pack", "nutrients", -0.25)
        p:add_subject_term("recipe/pentapod-egg",              "nutrients", -4.25)
        p:add_subject_term("recipe/nutrients-from-bioflux",    "nutrients", 59.75)
        p:add_subject_term("recipe/bioflux",                   "nutrients", -0.25)
        p:add_subject_term("recipe/jellynut-processing",       "nutrients", -0.25)
        p:add_subject_term("recipe/yumako-processing",         "nutrients", -0.25)
        p:add_subject_term("|surplus_sink|nutrients",          "nutrients", -1)
        p:add_subject_term("|shortage_source|nutrients",       "nutrients",  1)

        -- bioflux balance -- the other side of the cycle.
        p:add_subject_term("recipe/agricultural-science-pack", "bioflux", -0.5)
        p:add_subject_term("recipe/nutrients-from-bioflux",    "bioflux", -5)
        p:add_subject_term("recipe/bioflux",                   "bioflux",  2)
        p:add_subject_term("|surplus_sink|bioflux",            "bioflux", -1)
        p:add_subject_term("|shortage_source|bioflux",         "bioflux",  1)

        -- jelly balance
        p:add_subject_term("recipe/bioflux",              "jelly", -4)
        p:add_subject_term("recipe/jellynut-processing",  "jelly", 12)
        p:add_subject_term("|surplus_sink|jelly",         "jelly", -1)
        p:add_subject_term("|shortage_source|jelly",      "jelly",  1)

        -- yumako-mash balance
        p:add_subject_term("recipe/bioflux",              "yumako-mash", -5)
        p:add_subject_term("recipe/yumako-processing",    "yumako-mash",  6)
        p:add_subject_term("|surplus_sink|yumako-mash",   "yumako-mash", -1)
        p:add_subject_term("|shortage_source|yumako-mash","yumako-mash",  1)

        -- ASP output to final sink
        p:add_subject_term("recipe/agricultural-science-pack", "agricultural-science-pack", 0.75)
        p:add_subject_term("|final_sink|agricultural-science-pack", "agricultural-science-pack", -1)

        -- seed by-products to final sinks
        p:add_subject_term("recipe/jellynut-processing", "jellynut-seed", 0.06)
        p:add_subject_term("|final_sink|jellynut-seed",  "jellynut-seed", -1)
        p:add_subject_term("recipe/yumako-processing",   "yumako-seed", 0.06)
        p:add_subject_term("|final_sink|yumako-seed",    "yumako-seed", -1)

        -- raw inputs <- initial_source (uncapped)
        p:add_subject_term("recipe/pentapod-egg",         "water", -8)
        p:add_subject_term("|initial_source|water",         "water",  1)
        p:add_subject_term("recipe/jellynut-processing",  "jellynut", -2)
        p:add_subject_term("|initial_source|jellynut",      "jellynut",  1)
        p:add_subject_term("recipe/yumako-processing",    "yumako",   -2)
        p:add_subject_term("|initial_source|yumako",        "yumako",    1)

        -- ASP upper-cap row: 0.75 * recipe + slack = 0.5.
        p:add_subject_term("recipe/agricultural-science-pack",
                           "|limit|agricultural-science-pack", 0.75)
        p:add_subject_term("%positive_slack%|limit|agricultural-science-pack",
                           "|limit|agricultural-science-pack", 1)

        local state, vars, steps = harness.solve_to_completion(lp, p,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        harness.assert_true(steps < 100, "converged in under 100 iterations (took " .. steps .. ")")

        -- ASP pinned at target (0.75 * recipe = 0.5).
        harness.assert_near(vars.x["recipe/agricultural-science-pack"], 2 / 3, 1e-4, "ASP recipe rate")
        harness.assert_near(vars.x["|final_sink|agricultural-science-pack"], 0.5, 1e-4, "ASP throughput")
        harness.assert_near(vars.x["%positive_slack%|limit|agricultural-science-pack"], 0, 1e-3,
            "ASP cap slack idle")

        -- Loop participants from the captured optimum.
        harness.assert_near(vars.x["recipe/pentapod-egg"],           5 / 3,    1e-4, "pentapod-egg rate")
        harness.assert_near(vars.x["recipe/nutrients-from-bioflux"], 0.125699, 5e-4, "nutrients-from-bioflux rate")
        harness.assert_near(vars.x["recipe/bioflux"],                0.480913, 5e-4, "bioflux rate")
        harness.assert_near(vars.x["recipe/jellynut-processing"],    0.160304, 5e-4, "jellynut-processing rate")
        harness.assert_near(vars.x["recipe/yumako-processing"],      0.400761, 5e-4, "yumako-processing rate")

        -- Raw inputs scale to the chain.
        harness.assert_near(vars.x["|initial_source|water"],    40 / 3,   1e-3, "water uptake (= 8 * 5/3)")
        harness.assert_near(vars.x["|initial_source|jellynut"], 0.320609, 5e-4, "jellynut uptake")
        harness.assert_near(vars.x["|initial_source|yumako"],   0.801522, 5e-4, "yumako uptake")

        -- THE load-bearing assertion: every shortage_source must stay at
        -- zero. A non-zero shortage_source means the LP found it cheaper
        -- to "cheat" by paying the elastic shortage cost than to close
        -- the loop via real recipes -- exactly the regression the cost-
        -- tier balancing in create_problem.lua is designed to prevent.
        for _, mat in ipairs({
            "pentapod-egg", "nutrients", "bioflux", "jelly", "yumako-mash",
        }) do
            harness.assert_near(vars.x["|shortage_source|" .. mat], 0, 1e-3,
                "shortage_source|" .. mat .. " must stay zero (loop must close via real recipes)")
            harness.assert_near(vars.x["|surplus_sink|" .. mat], 0, 1e-3,
                "surplus_sink|" .. mat .. " must stay zero (loop must close cleanly)")
        end
    end,
})

table.insert(cases, {
    name = "Gleba loop with <grow> seed cycles must not get a spurious |initial_source|bioflux",
    -- Integration test (drives create_problem, not a hand-built Problem) for
    -- the upstream bug the bioflux trace exposed: once the yumako / jellynut
    -- seed->plant->fruit->seed loops are closed by <grow> recipes, those
    -- materials stop being external inputs and the {bioflux, nutrients, jelly,
    -- yumako-mash, yumako, yumako-seed, jellynut, jellynut-seed} SCC becomes a
    -- *source* SCC (no inbound edge from outside). material_cycles.
    -- find_deficit_materials then runs its uniform-rate + 50% threshold over
    -- that SCC and flags bioflux as a deficit:
    --   bioflux net at unit rates = +2 (bioflux recipe) - 5 (nutrients-from-
    --   bioflux) = -3, consumption = 5, ratio = -0.6 < -0.5 -> deficit.
    -- create_problem then gives bioflux a free |initial_source| at source_cost,
    -- and because that undercuts the recipe chain's effective raw cost
    -- (~1.166 / bioflux through yumako+jellynut), the LP zeros out the entire
    -- recipe chain and pulls all bioflux from the spurious initial_source.
    --
    -- This is a false positive: the seed loops are mass-*positive*
    -- (one seed grows into ~50 fruit, which processes back into >1 seed), so
    -- the chain closes internally and needs no external bioflux supply at all.
    -- The uniform-rate snapshot can't see that because it never scales the
    -- <grow> virtuals up to their true ~50x ratio (the "deliberately coarse"
    -- caveat in material_cycles.lua).
    --
    -- Fixed by the self-sustaining gate in find_deficit_materials: the SCC
    -- admits a positive recipe-rate vector that balances every internal
    -- material (cone_feasible), so it is recognised as needing no external
    -- supply and bioflux is no longer flagged. Asserted below: the recipe
    -- chain runs and no bioflux is drawn from a initial_source.
    run = function()
        local lines = {
            line("agricultural-science-pack",
                { item("agricultural-science-pack", 0.75) },
                { item("pentapod-egg", 0.5), item("nutrients", 0.25), item("bioflux", 0.5) }),
            line("pentapod-egg",
                { item("pentapod-egg", 0.2) },
                { item("nutrients", 4.25), item("water", 8) }),
            line("nutrients-from-bioflux",
                { item("nutrients", 59.75) },
                { item("bioflux", 5) }),
            line("bioflux",
                { item("bioflux", 2) },
                { item("nutrients", 0.25), item("yumako-mash", 5), item("jelly", 4) }),
            line("yumako-processing",
                { item("yumako-mash", 6), item("yumako-seed", 0.06) },
                { item("yumako", 2), item("nutrients", 0.25) }),
            -- <grow> recipes: tiny seed input, large fruit output (mass gain).
            line("grow-yumako-tree",
                { item("yumako", 0.166667) },
                { item("yumako-seed", 0.003333) }),
            line("jellynut-processing",
                { item("jelly", 12), item("jellynut-seed", 0.06) },
                { item("jellynut", 2), item("nutrients", 0.25) }),
            line("grow-jellystem",
                { item("jellynut", 0.166667) },
                { item("jellynut-seed", 0.003333) }),
        }
        local constraints = {
            { type = "item", name = "agricultural-science-pack", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 0.5 },
        }

        local problem = cp.create_problem("gleba-grow-loop", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")

        -- DESIRED: no spurious external bioflux. The seed/plant loops are
        -- mass-positive, so the whole chain should close through real
        -- recipes with bioflux produced by recipe/bioflux.
        harness.assert_near(vars.x["|initial_source|item/bioflux/normal"] or 0, 0, 1e-3,
            "bioflux must not get a spurious initial_source (find_deficit_materials false positive)")
        harness.assert_true(
            (vars.x["recipe/bioflux/normal"] or 0) > 0.1,
            "recipe/bioflux must run to supply the chain (got " ..
            tostring(vars.x["recipe/bioflux/normal"]) .. ")")
    end,
})

table.insert(cases, {
    name = "Gleba <grow> loops with EXTERNAL nutrients: chain closes, no spurious initial_source (control for the deficit bug)",
    -- The control that isolates the find_deficit_materials false positive in
    -- the xfail case above. Same <grow> seed cycles, same ASP target, but
    -- nutrients-from-bioflux is removed -- nutrients now has no producer
    -- recipe, so create_problem correctly makes it a |initial_source| (genuine
    -- external input).
    --
    -- Why this passes where the xfail fails: with nutrients external, the
    -- edge nutrients -> yumako-seed (yumako-processing consumes nutrients,
    -- produces seed) enters the {yumako, yumako-seed} cycle from outside, so
    -- that SCC is NOT a source SCC and find_deficit_materials skips it.
    -- Likewise for jellynut, and bioflux is now acyclic (nothing it feeds
    -- produces bioflux back). Nothing gets flagged as a deficit, every loop
    -- material gets the correct |shortage_source| gate, and the whole chain
    -- runs on real recipes.
    --
    -- Conclusion the pair establishes: the <grow> loops alone do NOT trigger
    -- the bug. It fires only when nutrients-from-bioflux folds nutrients +
    -- bioflux into the seed SCC and makes the combined component a source SCC.
    run = function()
        local lines = {
            line("agricultural-science-pack",
                { item("agricultural-science-pack", 0.75) },
                { item("pentapod-egg", 0.5), item("nutrients", 0.25), item("bioflux", 0.5) }),
            line("pentapod-egg",
                { item("pentapod-egg", 0.2) },
                { item("nutrients", 4.25), item("water", 8) }),
            -- No nutrients-from-bioflux: nutrients has no producer ->
            -- create_problem adds |initial_source|nutrients.
            line("bioflux",
                { item("bioflux", 2) },
                { item("nutrients", 0.25), item("yumako-mash", 5), item("jelly", 4) }),
            line("yumako-processing",
                { item("yumako-mash", 6), item("yumako-seed", 0.06) },
                { item("yumako", 2), item("nutrients", 0.25) }),
            line("grow-yumako-tree",
                { item("yumako", 0.166667) },
                { item("yumako-seed", 0.003333) }),
            line("jellynut-processing",
                { item("jelly", 12), item("jellynut-seed", 0.06) },
                { item("jellynut", 2), item("nutrients", 0.25) }),
            line("grow-jellystem",
                { item("jellynut", 0.166667) },
                { item("jellynut-seed", 0.003333) }),
        }
        local constraints = {
            { type = "item", name = "agricultural-science-pack", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 0.5 },
        }

        local problem = cp.create_problem("gleba-grow-external-nutrients", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")

        -- ASP at target, chain running on real recipes.
        harness.assert_near(vars.x["recipe/agricultural-science-pack/normal"], 2 / 3, 1e-3, "ASP recipe rate")
        harness.assert_near(vars.x["recipe/bioflux/normal"],                   1 / 6, 1e-3, "bioflux recipe runs")
        harness.assert_near(vars.x["recipe/yumako-processing/normal"],         0.138889, 1e-3, "yumako-processing runs")
        harness.assert_near(vars.x["recipe/grow-yumako-tree/normal"],          5 / 3, 1e-3, "grow-yumako-tree runs")
        harness.assert_near(vars.x["recipe/jellynut-processing/normal"],       0.055556, 1e-3, "jellynut-processing runs")
        harness.assert_near(vars.x["recipe/grow-jellystem/normal"],            2 / 3, 1e-3, "grow-jellystem runs")

        -- Only nutrients is a legitimate initial_source (no producer recipe).
        harness.assert_near(vars.x["|initial_source|item/nutrients/normal"], 7.340278, 1e-2,
            "nutrients supplied externally (the one legit initial_source)")

        -- The deficit-prone materials must NOT get a initial_source here.
        for _, mat in ipairs({ "bioflux", "yumako", "jellynut", "yumako-seed", "jellynut-seed" }) do
            harness.assert_near(vars.x["|initial_source|item/" .. mat .. "/normal"] or 0, 0, 1e-9,
                "|initial_source|" .. mat .. " must not exist (not a deficit when nutrients is external)")
        end

        -- Every shortage_source stays at zero: loop closes via real recipes.
        for _, mat in ipairs({
            "pentapod-egg", "bioflux", "yumako-seed", "yumako-mash", "yumako",
            "jellynut-seed", "jelly", "jellynut",
        }) do
            harness.assert_near(vars.x["|shortage_source|item/" .. mat .. "/normal"] or 0, 0, 1e-3,
                "shortage_source|" .. mat .. " must stay zero")
        end
    end,
})

return cases
