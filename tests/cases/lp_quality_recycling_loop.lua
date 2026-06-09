-- Recycling-loop quality fixtures: the headline "kovarex / quality recycling
-- on Space Age" pattern in miniature. A producer recipe emits a cascade of
-- its product across qualities, and a recycler recipe takes that product back
-- and returns the ingredients (also cascaded), creating a multi-tier loop
-- where mass flows up the quality chain on each cycle. The recycler returns
-- 1/4 of input by Factorio convention (matches Space Age recipe-recycling).
--
-- These shapes are the simplest LPs that reproduce the structural difficulty
-- the mod exists to handle. The full 5-tier Space Age case (the headline
-- workload for this mod) lives at the bottom of this file — it used to sit
-- in a separate lp_deep_recycling_xfail file documenting an IPM convergence
-- wall, but the IPM rewrite (long-step path-following with data-scaled cold
-- start, relative residual tests, and retry-on-NaN Cholesky regularisation)
-- now converges it from a fresh start in ~20 iterations.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local fixture = require "tests/cases/fixture"
local QUALITY = fixture.QUALITY
local item, line, cascade = fixture.item, fixture.line, fixture.cascade

local cases = {}

table.insert(cases, {
    name = "2-tier producer + 2-tier recycler upgrade loop converges",
    -- iron-mining:       (no ingredients) -> ore/n   (bootstrap)
    -- iron-plate/normal: ore -> [n 0.9, u 0.1] plate
    -- recycler/normal:   plate/n -> [n 0.225, u 0.025] ore   (1/4 return)
    -- recycler/uncommon: plate/u -> [u 0.225, r 0.025] ore   (cascade from u)
    --
    -- The iron-mining line is what makes ore/normal reachable; without it
    -- the recycler-loop forms a closed cycle that compute_reachable_materials
    -- can't bootstrap, and the LP would resort to |shortage_source| (the
    -- reachability gate adds it for every material that has no path from
    -- a raw input). Real Factorio chains always have an entry like this
    -- (mining drill / pumpjack / asteroid collector).
    --
    -- Constraint: produce 0.1 iron-plate/uncommon/s. LP should run the
    -- producer at ~1 machine; routing normal byproduct through recycler or
    -- to surplus depends on cost weights, so the assertion is convergence
    -- + the producer actually running + the constraint being met.
    run = function()
        local lines = {
            line("iron-mining", "normal",
                { item("iron-ore", "normal", 1) },
                {}),
            line("iron-plate", "normal",
                cascade("iron-plate", 1, "normal", 2),
                { item("iron-ore", "normal", 1) }),
            line("iron-plate-recycling", "normal",
                cascade("iron-ore", 0.25, "normal", 2),
                { item("iron-plate", "normal", 1) }),
            line("iron-plate-recycling", "uncommon",
                cascade("iron-ore", 0.25, "uncommon", 2),
                { item("iron-plate", "uncommon", 1) }),
        }
        local constraints = {
            { type = "item", name = "iron-plate", quality = "uncommon",
              limit_type = "equal", limit_amount_per_second = 0.1 },
        }

        local problem = cp.create_problem("recycling-2t", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_true(
            vars.x["recipe/iron-plate/normal"] > 0.5,
            "iron-plate producer runs (got " .. tostring(vars.x["recipe/iron-plate/normal"]) .. ")"
        )
        -- positive_slack on the uncommon-plate limit should be ~0: the LP
        -- met the user constraint exactly.
        harness.assert_near(
            vars.x["%positive_slack%|limit|item/iron-plate/uncommon"] or 0,
            0, 0.01, "positive_slack on uncommon constraint")
    end,
})

table.insert(cases, {
    name = "3-tier recycling chain with per-tier producers and recyclers converges",
    -- A slightly deeper loop than the 2-tier case: producer and recycler at
    -- normal/uncommon/rare. Reaches rare via either the producer's cascade
    -- or repeated recycling. Constraint puts a small demand on rare plate.
    run = function()
        local lines = {
            line("iron-mining", "normal",
                { item("iron-ore", "normal", 1) },
                {}),
            line("iron-plate", "normal",
                cascade("iron-plate", 1, "normal", 3),
                { item("iron-ore", "normal", 1) }),
            line("iron-plate-recycling", "normal",
                cascade("iron-ore", 0.25, "normal", 3),
                { item("iron-plate", "normal", 1) }),
            line("iron-plate-recycling", "uncommon",
                cascade("iron-ore", 0.25, "uncommon", 3),
                { item("iron-plate", "uncommon", 1) }),
            line("iron-plate-recycling", "rare",
                cascade("iron-ore", 0.25, "rare", 3),
                { item("iron-plate", "rare", 1) }),
        }
        local constraints = {
            { type = "item", name = "iron-plate", quality = "rare",
              limit_type = "equal", limit_amount_per_second = 0.01 },
        }

        local problem = cp.create_problem("recycling-3t", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_true(
            vars.x["recipe/iron-plate/normal"] > 0.01,
            "iron-plate producer runs (got " .. tostring(vars.x["recipe/iron-plate/normal"]) .. ")"
        )
        harness.assert_near(
            vars.x["%positive_slack%|limit|item/iron-plate/rare"] or 0,
            0, 0.01, "positive_slack on rare constraint")
    end,
})

table.insert(cases, {
    name = "5-tier electronic-circuit recycling chain (legendary upper bound) converges",
    -- The full Space Age quality recycling workload: producers for
    -- iron-plate, copper-cable, and electronic-circuit at every quality
    -- tier, recyclers at every tier except legendary (recycling legendary
    -- has nowhere to upgrade), with an upper-bound constraint on legendary
    -- electronic-circuit. Iron-ore and copper-plate are not produced --
    -- create_problem.lua bridges them through |initial_source| (matches the
    -- in-game shape where mining drills feed the chain from outside the
    -- solver's view). Reachable in ~20 iterations with the long-step IPM.
    run = function()
        local lines = {}

        table.insert(lines, line("iron-plate", "normal",
            cascade("iron-plate", 1, "normal", 5),
            { item("iron-ore", "normal", 1) }))
        table.insert(lines, line("copper-cable", "normal",
            cascade("copper-cable", 2, "normal", 5),
            { item("copper-plate", "normal", 1) }))

        for i, q in ipairs(QUALITY) do
            local tiers = #QUALITY - i + 1
            table.insert(lines, line("electronic-circuit", q,
                cascade("electronic-circuit", 1, q, tiers),
                { item("iron-plate", q, 1), item("copper-cable", q, 3) }))
        end

        for i = 1, #QUALITY - 1 do
            local q = QUALITY[i]
            local tiers = #QUALITY - i + 1
            local rec_products = {}
            for _, ingredient_amount in ipairs({
                { "iron-plate", 1 * 0.25 },
                { "copper-cable", 3 * 0.25 },
            }) do
                for _, amt in ipairs(cascade(ingredient_amount[1], ingredient_amount[2], q, tiers)) do
                    table.insert(rec_products, amt)
                end
            end
            table.insert(lines, line("electronic-circuit-recycling", q,
                rec_products,
                { item("electronic-circuit", q, 1) }))
        end

        local constraints = {
            { type = "item", name = "electronic-circuit", quality = "legendary",
              limit_type = "upper", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("deep-recycling", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")

        -- The legendary EC recipe must run: it is the only producer of the
        -- constrained material. The recycler cascade can lift mass from
        -- lower tiers but cannot create the final tier directly.
        harness.assert_true(
            (vars.x["recipe/electronic-circuit/legendary"] or 0) > 0,
            "legendary electronic-circuit recipe runs (got "
                .. tostring(vars.x["recipe/electronic-circuit/legendary"]) .. ")"
        )
        -- The constraint is upper-bound at 1; |final_sink| is the LP variable
        -- absorbing all constrained output, so its value reports how much of
        -- the legendary circuit demand is met.
        harness.assert_near(
            vars.x["|final_sink|item/electronic-circuit/legendary"] or 0,
            1, 0.01, "legendary electronic-circuit final_sink meets constraint")
        -- positive_slack is the LP's escape valve when the constraint can't
        -- be met from the recipes; a healthy solve uses none of it.
        harness.assert_near(
            vars.x["%positive_slack%|limit|item/electronic-circuit/legendary"] or 0,
            0, 0.01, "no positive_slack consumed on the legendary constraint")
    end,
})

table.insert(cases, {
    name = "5-tier all-in-cycle: solver auto-promotes cu/normal + ir/normal to initial_source",
    -- Same fixture as the test above but with iron-plate / copper-cable
    -- producer recipes removed: the chain has no open boundary and every
    -- material has a producer recipe in the line set, so the existing
    -- reachability seed is empty. Without deficit promotion the LP could
    -- only satisfy the constraint via |shortage_source| at penalty cost;
    -- with it, material_cycles.find_deficit_materials picks cu/normal and
    -- ir/normal as the cycle's natural entry points and the LP recovers
    -- the cascade solution. The assertions check both convergence and
    -- the LP variable presence so a future regression that pushes the
    -- deficit promotion to higher qualities (the over-detection bug the
    -- source-SCC gate exists to prevent) fails the test.
    run = function()
        local lines = {}
        for i, q in ipairs(QUALITY) do
            local tiers = #QUALITY - i + 1
            table.insert(lines, line("electronic-circuit", q,
                cascade("electronic-circuit", 1, q, tiers),
                { item("iron-plate", q, 1), item("copper-cable", q, 3) }))
        end
        for i = 1, #QUALITY - 1 do
            local q = QUALITY[i]
            local tiers = #QUALITY - i + 1
            local rec_products = {}
            for _, ingredient_amount in ipairs({
                { "iron-plate", 1 * 0.25 },
                { "copper-cable", 3 * 0.25 },
            }) do
                for _, amt in ipairs(cascade(ingredient_amount[1], ingredient_amount[2], q, tiers)) do
                    table.insert(rec_products, amt)
                end
            end
            table.insert(lines, line("electronic-circuit-recycling", q,
                rec_products,
                { item("electronic-circuit", q, 1) }))
        end

        local constraints = {
            { type = "item", name = "electronic-circuit", quality = "legendary",
              limit_type = "upper", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("all-in-cycle", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")

        -- The promoted deficits must be present as LP variables and
        -- carry positive flow.
        harness.assert_true(
            (vars.x["|initial_source|item/copper-cable/normal"] or 0) > 0,
            "copper-cable/normal initial_source is active (got " ..
                tostring(vars.x["|initial_source|item/copper-cable/normal"]) .. ")"
        )
        harness.assert_true(
            (vars.x["|initial_source|item/iron-plate/normal"] or 0) > 0,
            "iron-plate/normal initial_source is active (got " ..
                tostring(vars.x["|initial_source|item/iron-plate/normal"]) .. ")"
        )

        -- Higher-quality initial_sources must NOT exist: the source-SCC
        -- gate keeps them out of the deficit set so the LP variable is
        -- never created.
        for i = 2, #QUALITY do
            local q = QUALITY[i]
            harness.assert_true(
                vars.x["|initial_source|item/copper-cable/" .. q] == nil,
                "copper-cable/" .. q .. " initial_source must not exist"
            )
            harness.assert_true(
                vars.x["|initial_source|item/iron-plate/" .. q] == nil,
                "iron-plate/" .. q .. " initial_source must not exist"
            )
        end

        -- The user constraint must actually be met by the cascade, not
        -- by penalised slack.
        harness.assert_near(
            vars.x["|final_sink|item/electronic-circuit/legendary"] or 0,
            1, 0.01, "legendary electronic-circuit final_sink meets constraint")
        harness.assert_near(
            vars.x["%positive_slack%|limit|item/electronic-circuit/legendary"] or 0,
            0, 0.01, "no positive_slack consumed on the legendary constraint")
    end,
})

return cases
