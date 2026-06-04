-- Two non-practical solutions on the pyanodon 'Nuc Sample' purex / plutonium
-- subset. Both are pinned against the practicality criterion the maintainer uses:
--
--   A solution is very likely practical when it draws on at least one
--   |initial_source| (a declared external import) AND empties at least one
--   |final_sink| (a genuine product leaving the factory) -- and conjures nothing
--   from |shortage_source|. A solution with no final_sink only makes material to
--   dump it back as penalized |surplus_sink|; one with a shortage_source
--   fabricates an ingredient the user cannot actually supply. Neither builds.
--
-- Practicality is decided in the problem formalization (create_problem /
-- material_cycles), not in the IPM (which solves every variant here correctly)
-- and not in the display. These recipes are verbatim from the in-game
-- create_problem dump (power/pollution dropped -- the LP ignores them).
--
-- The two cases fail for DIFFERENT reasons and are fixed by different changes;
-- NS2 is fixed today, NS1 is still xfail:
--
--   NS2 used to fabricate pu-238 via |shortage_source| because the antimony
--   recycling loop never became reachable. The loop turns on a catalyst,
--   sb-oxide, that purex-antimony-void produces and antimony-phosphate consumes
--   at the SAME rate (net = 0). find_deficit_materials' net-flow test can never
--   flag a net-zero material, so the catalyst was never seeded with an
--   |initial_source|, the reachability BFS stalled, and pu-238 fell through to
--   fabrication. (plastic-bar compounded it: net -0.1 sits exactly on the
--   -0.5*production threshold and the strict `<` let it slip too.) FIXED:
--   find_deficit_materials now also returns net-zero catalysts of a
--   non-self-sustaining cycle as `seed_candidates`, and create_problem seeds the
--   ones that stay unreachable as |initial_source| (a reachability-driven
--   bootstrap primer); the threshold also became `<=` so plastic-bar is claimed
--   as a mass-losing cycle input. The whole chain now runs with zero shortage.
--   This was the fourth failure mode of the same heuristic
--   (cf. lp_masslosing_cycle_import.lua).
--
--   NS1 pins an intermediate (sb-phosphate-1) that already has a consumer recipe
--   in the set, so create_problem routes the pinned output to |surplus_sink|
--   (penalized waste) and never gives it a |final_sink|. The solution makes
--   exactly 0.5/s and dumps all of it -- no product leaves. The catalyst fix
--   does NOT touch this (verified: still zero final_sink after it); a
--   user-pinned material needs to be final-sinkable in its own right.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local function it(name, amount)
    return { type = "item", name = name, quality = "normal", amount_per_second = amount }
end
local function fl(name, amount, tmin, tmax)
    return { type = "fluid", name = name, quality = "normal", amount_per_second = amount,
        minimum_temperature = tmin, maximum_temperature = tmax }
end
local function line(recipe, products, ingredients, fuel)
    return {
        recipe_typed_name = { type = "recipe", name = recipe, quality = "normal" },
        products = products, ingredients = ingredients, fuel_ingredient = fuel,
        power_per_second = 0, pollution_per_second = 0,
    }
end

-- The 'Nuc Sample' purex / plutonium subset. The antimony catalyst loop closes
-- through temperature-bridged fluids (sb-phosphate-2 @10,10 produced /
-- @10,1000 consumed, etc.), so it only materialises once create_problem injects
-- its temperature bridges.
local function make_lines()
    return {
        line("fuel-cell-dissolve",
            { fl("sb-phosphate-1", 6.666666666666667, 10, 10) },
            { it("depleted-uranium-fuel-cell", 0.3333333333333333), it("sodium-hydroxide", 1),
              fl("water", 16.666666666666668, 15, 500), fl("sulfuric-acid", 16.666666666666668, 25, 25) }),
        line("antimony-phosphate",
            { it("sb-hpo-pu", 0.1), fl("purex-concentrate-1", 1, 10, 10) },
            { it("sb-oxide", 0.05), fl("sb-phosphate-1", 0.05, 10, 1000), fl("phosphoric-acid", 2.5, 10, 100) }),
        line("plutonium-oxidation",
            { fl("plutonium-peroxide", 1, 10, 10), fl("sb-phosphate-2", 1, 10, 10) },
            { it("sb-hpo-pu", 0.05), fl("hydrogen-peroxide", 2.5, 10, 100) }),
        line("purex-antimony-void",
            { it("sb-oxide", 0.05), it("plastic-bar", 0.2), fl("phosphorous-acid", 12, 10, 10) },
            { it("plastic-bar", 0.3), fl("sb-phosphate-2", 6, 10, 1000), fl("purex-concentrate-1", 3, 10, 1000) }),
        line("phosphoric-acid",
            { fl("phosphoric-acid", 4, 10, 10), fl("phosphine-gas", 2, 15, 15), fl("hydrofluoric-acid", 2, 10, 10) },
            { it("wood", 2), fl("phosphorous-acid", 8, 10, 100), fl("steam", 24, 15, 2000) }),
        line("phosphoric-acid2",
            { fl("phosphoric-acid", 8, 10, 10) },
            { fl("phosphine-gas", 10, 15, 100) }),
        line("plutonium",
            { it("plutonium-oxide", 5) },
            { fl("plutonium-peroxide", 50, 10, 1000), fl("ethanol", 25, 10, 100) }),
        line("plutonium-seperation",
            { it("pu-238", 0.06), it("pu-239", 1.59), it("pu-240", 0.75), it("pu-241", 0.45), it("pu-242", 1.5) },
            { it("plutonium-oxide", 1) }),
        line("nuclear-sample",
            { it("nuclear-sample", 0.24000000059604645) },
            { it("automation-science-pack", 0.2), it("pu-238", 0.2), fl("boric-acid", 20, 0, 10),
              fl("industrial-solvent", 20, 10, 100), fl("aromatics", 10, 10, 100) }),
        line("plutonium-shuffle-2",
            { it("pu-238", 0.0049299999999999997), it("pu-242", 0.0049299999999999997) },
            { it("pu-239", 0.0049299999999999997), it("pu-240", 0.0049299999999999997),
              fl("plutonium-peroxide", 0.17254999999999998, 10, 1000) },
            fl("boric-acid", 2.0005989074707031, 0, 10)),
        line("industrial-solvent",
            { fl("industrial-solvent", 10, 10, 10) },
            { fl("organic-solvent", 20, 10, 100), fl("soda-ash", 20, 10, 100), fl("syngas", 20, 15, 100) }),
        line("soda-ash",
            { fl("soda-ash", 40, 10, 10) },
            { it("ash", 10), fl("water", 50, 15, 500), fl("water-saline", 50, 25, 100) }),
        line("cool-steam-250-to-150",
            { fl("steam", 34, 150, 150) },
            { fl("steam", 20, 250, 2000), fl("water", 15, 15, 500) }),
        line("electric-boiler-water-to-steam",
            { fl("steam", 60, 250, 250) },
            { fl("water", 60, 15, 500) }),
        line("log-wood-fast",
            { it("wood", 40) },
            { it("log", 4) }),
    }
end

-- The maintainer's practicality signature: a buildable solution imports through
-- some |initial_source|, ships product through some |final_sink|, and fabricates
-- nothing via |shortage_source|.
local function source_sink_usage(vars)
    local has_initial, has_final, shortage = false, false, 0
    for k, v in pairs(vars.x) do
        if math.abs(v) > 1e-6 then
            if k:find("|initial_source|", 1, true) then has_initial = true end
            if k:find("|final_sink|", 1, true) then has_final = true end
            if k:find("|shortage_source|", 1, true) then shortage = shortage + math.abs(v) end
        end
    end
    return has_initial, has_final, shortage
end

local cases = {}

-- NS2: demand the loop's downstream product (nuclear-sample upper 0.5). A
-- practical solution runs the real plutonium chain and imports the catalyst;
-- the current solver fabricates pu-238 instead. xfail until the catalyst is
-- promoted to a deficit in material_cycles.
table.insert(cases, {
    name = "catalyst loop bootstraps instead of fabricating pu-238 (Nuc Sample 2)",
    run = function()
        local lines = make_lines()
        local constraints = {
            { type = "item", name = "nuclear-sample", quality = "normal",
              limit_type = "upper", limit_amount_per_second = 0.5 },
        }

        local problem = cp.create_problem("nuc-sample-2", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 1000 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables")

        local has_initial, has_final, shortage = source_sink_usage(vars)
        harness.assert_true(has_initial, "imports declared external inputs")
        harness.assert_true(has_final, "ships a genuine final output (nuclear-sample)")
        harness.assert_near(shortage, 0, 1e-3,
            "pu-238 must come from the real chain, not |shortage_source|")

        -- The chain that should make pu-238 actually runs.
        harness.assert_true((vars.x["recipe/plutonium-seperation/normal"] or 0) > 1e-3,
            "plutonium-seperation runs (makes pu-238)")
        harness.assert_true((vars.x["recipe/purex-antimony-void/normal"] or 0) > 1e-3,
            "the antimony recycling loop runs")
        harness.assert_true((vars.x["recipe/antimony-phosphate/normal"] or 0) > 1e-3,
            "antimony-phosphate runs (consumes the imported catalyst)")
    end,
})

-- NS1: pin an intermediate (sb-phosphate-1 upper 0.5). Today the solver makes
-- exactly 0.5/s and dumps all of it to |surplus_sink| -- no |final_sink|, so by
-- the criterion the solution is not practical. A user-pinned material should be
-- shippable as a genuine output. xfail until create_problem grants the pinned
-- material a final_sink (the catalyst fix does not address this).
table.insert(cases, {
    name = "pinned intermediate ships via final_sink instead of dumping as surplus (Nuc Sample 1)",
    xfail = true,
    run = function()
        local lines = make_lines()
        local constraints = {
            { type = "fluid", name = "sb-phosphate-1", quality = "normal",
              limit_type = "upper", limit_amount_per_second = 0.5,
              minimum_temperature = 10, maximum_temperature = 10 },
        }

        local problem = cp.create_problem("nuc-sample-1", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 800 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables")

        local has_initial, has_final, shortage = source_sink_usage(vars)
        harness.assert_near(shortage, 0, 1e-3, "nothing fabricated")
        harness.assert_true(has_initial, "imports declared external inputs")
        harness.assert_true(has_final,
            "the pinned sb-phosphate-1 must leave via a |final_sink|, " ..
            "not be produced only to be dumped back as penalized |surplus_sink|")
    end,
})

return cases
