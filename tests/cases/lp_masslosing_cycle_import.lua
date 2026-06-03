-- A mass-losing cycle whose materials have NO producer outside the cycle must be
-- supplied by |initial_source| (a declared external import) so the recipes run --
-- NOT fabricated by |shortage_source| while every recipe parks at zero.
--
-- This pins the per-material refinement of find_deficit_materials' source-SCC
-- gate (solver/material_cycles.lua). The old gate skipped a cyclic SCC wholesale
-- the moment ANY external edge entered it, on the assumption that the inflow
-- supplies the SCC's materials. That is false when the inflow feeds a DIFFERENT
-- SCC material than the one in deficit: the genuine deficit then fell through to
-- |shortage_source| and the LP returned an impractical solution that conjured
-- material the user cannot supply (build nothing / fabricate the target).
--
-- The fix checks per material whether it has an external producer; a material
-- whose every producer is inside the cycle is flagged as a deficit and gets a
-- cheap |initial_source| (= "import this"), so the LP runs the real recipes.
-- Practicality is decided here, in the problem formalization -- not in the IPM
-- (which solved both the old and new problem correctly) and not in the display.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"
local mc = require "solver/material_cycles"

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

local function sum_shortage(vars)
    local total = 0
    for k, v in pairs(vars.x) do
        if k:find("|shortage_source|", 1, true) then total = total + math.abs(v) end
    end
    return total
end

local cases = {}

-- Minimal synthetic case: M is the deficit inside a NON-source SCC.
--   A: 2 M + 1 X -> 1 P
--   B: 1 P -> 0.5 M + 1 T      (net M = 0.5 - 2 = -1.5 per cycle: mass-losing)
-- The SCC {M, P} is non-source because X -> P enters from outside. X feeds P's
-- production, NOT M, so M (every producer of which is recipe B, inside the SCC)
-- genuinely needs external supply. find_deficit_materials must flag M.
table.insert(cases, {
    name = "deficit in a non-source SCC gets |initial_source|, not |shortage_source| (recipes run)",
    run = function()
        local lines = {
            line("A", { it("P", 1) }, { it("M", 2), it("X", 1) }),
            line("B", { it("M", 0.5), it("T", 1) }, { it("P", 1) }),
        }
        local constraints = {
            { type = "item", name = "T", quality = "normal", limit_type = "equal", limit_amount_per_second = 1 },
        }

        -- The structural decision under test: M flagged, P (fed by external X) not.
        local deficits = mc.find_deficit_materials(lines)
        harness.assert_true(deficits["item/M/normal"] == true,
            "M must be flagged as a deficit (every producer inside the cycle)")
        harness.assert_true(deficits["item/P/normal"] == nil,
            "P must NOT be flagged (X supplies it from outside the SCC)")

        local problem = cp.create_problem("nonsource-scc-deficit", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables")

        -- The factory runs on real recipes, importing the deficit material.
        harness.assert_near(vars.x["recipe/A/normal"], 1, 1e-3, "recipe A runs")
        harness.assert_near(vars.x["recipe/B/normal"], 1, 1e-3, "recipe B runs (makes the target)")
        harness.assert_near(vars.x["|initial_source|item/M/normal"], 1.5, 1e-3,
            "M imported via initial_source (= the declared external input)")
        harness.assert_near(sum_shortage(vars), 0, 1e-3,
            "nothing is fabricated by shortage_source")
    end,
})

-- Real pyanodon case ('Solution 3'): target ash = 0.5/s over a mass-losing ash
-- loop. vacuum + steam feed INTO the {coke, ash, residual-mixture, residual-oil}
-- SCC, so the old whole-SCC gate skipped it and ash was fabricated by
-- |shortage_source| with every recipe at zero. With the per-material fix the
-- cycle's external inputs (residual-mixture, vacuum, steam) become
-- |initial_source| imports and the recipes run -- a buildable factory.
table.insert(cases, {
    name = "pyanodon ash loop runs via imports instead of fabricating the target",
    run = function()
        local lines = {
            line("coal-gas-from-coke",
                { it("ash", 0.1), fl("coal-gas", 2, 15, 15), fl("tar", 2, 10, 10) },
                { it("coke", 2) },
                it("charcoal-briquette", 0.0011111111111111112)),
            line("residual-mixture-distillation",
                { it("coke", 5), fl("residual-oil", 6.25, 10, 10), fl("hot-residual-mixture", 3.125, 10, 10) },
                { fl("residual-mixture", 25, 10, 100), fl("vacuum", 25, 15, 100) },
                it("charcoal-briquette", 0.0011111111111111112)),
            line("residual-mixture",
                { fl("residual-mixture", 25, 10, 10) },
                { it("ash", 2.5), fl("residual-oil", 50, 10, 100), fl("steam", 50, 15, 2000) }),
        }
        local constraints = {
            { type = "item", name = "ash", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 0.5 },
        }

        local problem = cp.create_problem("masslosing-ash", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables")

        -- THE load-bearing change: ash is no longer fabricated, and the recipe
        -- that emits the target ash actually runs (0.1/craft * 5 = 0.5/s target).
        harness.assert_near(vars.x["|shortage_source|item/ash/normal"] or 0, 0, 1e-3,
            "ash must NOT be fabricated by shortage_source")
        harness.assert_near(vars.x["recipe/coal-gas-from-coke/normal"], 5, 1e-2,
            "the ash-emitting recipe runs at the target rate")
        harness.assert_true((vars.x["recipe/residual-mixture-distillation/normal"] or 0) > 1e-3,
            "the distillation recipe runs")
        harness.assert_true((vars.x["recipe/residual-mixture/normal"] or 0) > 1e-3,
            "the residual-mixture recipe runs")
    end,
})

return cases
