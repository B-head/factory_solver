-- create_problem coverage for two material kinds the other lp_* fixtures
-- never exercise: a recipe's burner fuel_ingredient, and the <heat> virtual
-- material whose |initial_source| cost is scaled away from the item default.
-- Both are translation-layer behaviours (how create_problem turns a
-- NormalizedProductionLine into LP rows), so they go through create_problem
-- rather than a hand-built Problem.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local fixture = require "tests/cases/fixture"
local item = fixture.item

local cases = {}

table.insert(cases, {
    name = "fuel_ingredient is treated as a consumed material with its own initial_source",
    -- create_problem.each_ingredient yields line.fuel_ingredient as a trailing
    -- pseudo-ingredient, so the burner fuel must flow through the LP exactly
    -- like a real ingredient: it gets a |initial_source| (no producer here) and
    -- its consumption scales with the recipe rate. A smelt recipe burning coal
    -- to turn iron-ore into iron-plate, pinned at 10 plate/s.
    run = function()
        local smelt = {
            recipe_typed_name = { type = "recipe", name = "smelt", quality = "normal" },
            products = { item("iron-plate", 1) },
            ingredients = { item("iron-ore", 1) },
            fuel_ingredient = item("coal", 0.05),
            power_per_second = 0,
            pollution_per_second = 0,
        }
        local constraints = {
            { type = "item", name = "iron-plate", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 10 },
        }

        local problem = cp.create_problem("fuel", constraints, { smelt })
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        harness.assert_near(vars.x["recipe/smelt/normal"], 10, 0.05, "smelt runs at the plate demand")
        harness.assert_near(vars.x["|initial_source|item/iron-ore/normal"], 10, 0.05, "iron-ore drawn 1:1")
        -- The load-bearing assertion: fuel is consumed and sourced, scaling
        -- with recipe rate (0.05 coal/run * 10 runs = 0.5/s).
        harness.assert_near(vars.x["|initial_source|item/coal/normal"], 0.5, 0.01,
            "coal fuel sourced at recipe_rate * fuel_amount")
    end,
})

table.insert(cases, {
    name = "<heat> initial_source uses the heat-scaled amount_weight so a heat-fed chain does not collapse",
    -- create_problem.amount_weight_of scales an |initial_source| (and every other
    -- escape / elastic variable) per material kind ON ITS COEFFICIENT: item = 1,
    -- fluid = 10, <heat> = 10e6/100 = 1e5 (heat is in joules at ~10 MW scale).
    -- The variable is denominated in normalized slot-units (physical flow =
    -- amount_weight * x), so a uniform per-class cost weighs one slot-unit equally
    -- across kinds. The scaling is load-bearing: without it an item-scale weight on
    -- <heat> would dominate the objective by seven orders of magnitude and the LP
    -- would collapse to the all-zero solution whenever heat is sourced externally.
    --
    -- This fixture is chosen so item-scale pricing WOULD collapse it: a recipe
    -- consumes 1e7 heat to make 1 hot-item, demanded at 1/s. With the heat
    -- amount_weight the source variable carries 1e7/1e5 = 100 slot-units at cost
    -- 1 = objective 100 (far below the 2^20 elastic on the demand, so the LP
    -- produces); at item scale (weight 1) it would carry 1e7 slot-units = objective
    -- 1e7 -- above the ~1.05e6 elastic, so the LP would rather drop the demand and
    -- park the recipe at zero. Asserting the recipe RUNS pins the heat scaling:
    -- regress amount_weight_heat to the item default and this fails with
    -- recipe ~ 0 / elastic ~ 1.
    run = function()
        local function heat(amount)
            return { type = "virtual_material", name = "<heat>", quality = "normal",
                     amount_per_second = amount }
        end
        local exchanger = {
            recipe_typed_name = { type = "recipe", name = "heat-exchanger", quality = "normal" },
            products = { item("hot-item", 1) },
            ingredients = { heat(1e7) },
            power_per_second = 0,
            pollution_per_second = 0,
        }
        local constraints = {
            { type = "item", name = "hot-item", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("heat-source", constraints, { exchanger })
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 500 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        -- The chain runs rather than collapsing to the elastic.
        harness.assert_near(vars.x["recipe/heat-exchanger/normal"], 1, 0.01,
            "heat-exchanger runs (heat-scaled source_cost keeps it viable)")
        -- The variable is in normalized slot-units: 1e7 physical / amount_weight
        -- 1e5 = 100. Physical heat sourced = amount_weight_heat * x = 1e7.
        harness.assert_near(vars.x["|initial_source|virtual_material/<heat>/normal"], 100, 0.1,
            "heat sourced at the recipe's draw (100 slot-units = 1e7 physical)")
        harness.assert_near(vars.x["|elastic||limit|item/hot-item/normal"] or 0, 0, 1e-3,
            "demand met by production, not absorbed by the elastic (no collapse)")
    end,
})

return cases
