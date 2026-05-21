-- Regression: a constraint on a bare fluid (no temperature info) must bind
-- the corresponding LP variables even though the production-line side always
-- carries a temperature suffix (single T or [lo,hi] range). Before the fix
-- the constraint's `|limit|fluid/<X>` dual had no subject terms feeding into
-- it and silently did nothing.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local function item(name, amount)
    return { type = "item", name = name, quality = "normal", amount_per_second = amount }
end

local function fluid_single(name, temperature, amount)
    return {
        type = "fluid",
        name = name,
        quality = "normal",
        temperature = temperature,
        amount_per_second = amount,
    }
end

local function fluid_range(name, min, max, amount)
    return {
        type = "fluid",
        name = name,
        quality = "normal",
        minimum_temperature = min,
        maximum_temperature = max,
        amount_per_second = amount,
    }
end

local function recipe(name, products, ingredients)
    return {
        recipe_typed_name = { type = "recipe", name = name, quality = "normal" },
        products = products,
        ingredients = ingredients,
        power_per_second = 0,
        pollution_per_second = 0,
    }
end

local cases = {}

table.insert(cases, {
    name = "bare-fluid upper constraint caps single-temperature production",
    -- boiler emits steam@165; the user constrains "fluid/steam <= 3/s" without
    -- thinking about temperature. The LP must honour it.
    run = function()
        local lines = {
            recipe("boiler",
                { fluid_single("steam", 165, 1) },
                { item("water", 1) }),
        }
        local constraints = {
            { type = "fluid", name = "steam", quality = "normal",
              limit_type = "upper", limit_amount_per_second = 3 },
        }

        local problem = cp.create_problem("bare-upper", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        -- Recipe is 1:1, so boiler rate equals steam production rate. With
        -- target_cost pulling toward the upper bound and recipe cost being a
        -- mild negative, the optimum sits right at the cap.
        harness.assert_near(vars.x["recipe/boiler/normal"], 3, 0.1, "boiler rate hits cap")
    end,
})

table.insert(cases, {
    name = "bare-fluid equal constraint pins range-temperature ingredient",
    -- generator consumes steam@[15,1000]; the user requests "fluid/steam == 2/s".
    -- Without a producer recipe in the line set the |basic_source| supplies it,
    -- and the bare-fluid limit must aggregate that source flow.
    run = function()
        local lines = {
            recipe("generator",
                { item("power", 1) },
                { fluid_range("steam", 15, 1000, 1) }),
        }
        local constraints = {
            { type = "fluid", name = "steam", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 2 },
        }

        local problem = cp.create_problem("bare-equal", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_near(vars.x["recipe/generator/normal"], 2, 0.1, "generator rate matches steam==2/s")
    end,
})

table.insert(cases, {
    name = "bare-fluid upper constraint aggregates across temperatures",
    -- Two boilers produce steam at different temperatures; "fluid/steam <= 4/s"
    -- must bound the sum, not each variant individually.
    run = function()
        local lines = {
            recipe("boiler-low",
                { fluid_single("steam", 165, 1) },
                { item("water-low", 1) }),
            recipe("boiler-high",
                { fluid_single("steam", 500, 1) },
                { item("water-high", 1) }),
            -- Pull on each variant individually so both recipes want to run.
            recipe("sink-low",
                { item("p-low", 1) },
                { fluid_single("steam", 165, 1) }),
            recipe("sink-high",
                { item("p-high", 1) },
                { fluid_single("steam", 500, 1) }),
        }
        local constraints = {
            -- Lower bounds on the downstream items push each chain to run.
            { type = "item", name = "p-low", quality = "normal",
              limit_type = "lower", limit_amount_per_second = 10 },
            { type = "item", name = "p-high", quality = "normal",
              limit_type = "lower", limit_amount_per_second = 10 },
            -- Bare-fluid cap aggregates both boilers.
            { type = "fluid", name = "steam", quality = "normal",
              limit_type = "upper", limit_amount_per_second = 4 },
        }

        local problem = cp.create_problem("bare-aggregate", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        local total = vars.x["recipe/boiler-low/normal"] + vars.x["recipe/boiler-high/normal"]
        harness.assert_true(total <= 4 + 0.1,
            "sum of boiler rates respects bare-fluid cap (got " .. tostring(total) .. ")")
    end,
})

table.insert(cases, {
    name = "temperature-specific constraint still binds only its variant",
    -- Two boilers emit different temperatures. A constraint on steam@165 must
    -- cap only the low boiler; the high boiler should be free to scale up.
    run = function()
        local lines = {
            recipe("boiler-low",
                { fluid_single("steam", 165, 1) },
                { item("water-low", 1) }),
            recipe("boiler-high",
                { fluid_single("steam", 500, 1) },
                { item("water-high", 1) }),
            recipe("sink-low",
                { item("p-low", 1) },
                { fluid_single("steam", 165, 1) }),
            recipe("sink-high",
                { item("p-high", 1) },
                { fluid_single("steam", 500, 1) }),
        }
        local constraints = {
            -- Pin both downstream products. The temperature-specific cap then
            -- forces |surplus_sink| / |basic_source| to absorb the mismatch
            -- on the low-steam side without dragging the high-steam side.
            { type = "item", name = "p-low", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 10 },
            { type = "item", name = "p-high", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 10 },
            -- Only the low boiler should be capped.
            { type = "fluid", name = "steam", quality = "normal",
              temperature = 165,
              limit_type = "upper", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("temp-specific", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_near(vars.x["recipe/boiler-low/normal"], 1, 0.1,
            "low boiler at its cap")
        harness.assert_near(vars.x["recipe/boiler-high/normal"], 10, 0.1,
            "high boiler scales freely past the low-cap")
    end,
})

table.insert(cases, {
    name = "range-T constraint caps the range variable's inflow",
    -- boiler -> steam@165 -> (auto bridge) -> steam@[15,1000] -> generator.
    -- A constraint on steam@[15,1000] binds the bridge product side: it caps
    -- the throughput of fluid being routed as that range, which transitively
    -- caps the upstream boiler in a 1:1 chain.
    run = function()
        local lines = {
            recipe("boiler",
                { fluid_single("steam", 165, 1) },
                { item("water", 1) }),
            recipe("generator",
                { item("power", 1) },
                { fluid_range("steam", 15, 1000, 1) }),
        }
        local constraints = {
            { type = "fluid", name = "steam", quality = "normal",
              minimum_temperature = 15, maximum_temperature = 1000,
              limit_type = "upper", limit_amount_per_second = 2 },
        }

        local problem = cp.create_problem("range-cap", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_near(vars.x["recipe/boiler/normal"], 2, 0.1,
            "boiler transitively capped by the range constraint")
        harness.assert_near(vars.x["recipe/generator/normal"], 2, 0.1,
            "generator runs at the cap")
    end,
})

table.insert(cases, {
    name = "bare-fluid limit must not double-count bridge throughput",
    -- Regression for the bare-fluid aggregation rule: a bridge re-labels the
    -- same fluid, so its product side must NOT contribute to |limit|fluid/<X>
    -- on top of the upstream real recipe. Without the bridge skip the LP would
    -- see total = boiler + bridge = 2 * boiler and pin the chain at half rate.
    run = function()
        local lines = {
            recipe("boiler",
                { fluid_single("steam", 165, 1) },
                { item("water", 1) }),
            recipe("generator",
                { item("power", 1) },
                { fluid_range("steam", 15, 1000, 1) }),
        }
        local constraints = {
            { type = "fluid", name = "steam", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 5 },
        }

        local problem = cp.create_problem("bare-no-double", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        -- With the bridge skip, the bare-fluid limit sees only the boiler:
        -- boiler == 5/s. Without it, the LP would settle at boiler == 2.5/s.
        harness.assert_near(vars.x["recipe/boiler/normal"], 5, 0.1,
            "boiler matches the bare-fluid total (no double counting)")
        harness.assert_near(vars.x["recipe/generator/normal"], 5, 0.1,
            "generator matches the boiler in the 1:1 chain")
    end,
})

return cases
