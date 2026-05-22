-- Verify that create_problem auto-emits temperature bridge recipes that
-- connect single-temperature fluid outputs to range-temperature fluid
-- inputs. These are the LP-internal conversion lines described in the
-- Phase 2 implementation plan; users never see them in the UI.

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

local function bridge_primal_key(fluid, temperature, min, max)
    return string.format(
        "virtual_recipe/|bridge|fluid/%s@%g->[%g,%g]/normal",
        fluid, temperature, min, max
    )
end

local cases = {}

table.insert(cases, {
    name = "single in range -> bridge connects boiler to generator",
    -- water --[boiler]--> steam@165 --[bridge]--> steam@[15,1000] --[generator]--> power
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
            { type = "item", name = "power", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("bridge-basic", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")

        harness.assert_near(vars.x["recipe/boiler/normal"], 1, 0.05, "boiler rate")
        harness.assert_near(vars.x["recipe/generator/normal"], 1, 0.05, "generator rate")

        local bridge_key = bridge_primal_key("steam", 165, 15, 1000)
        harness.assert_true(
            vars.x[bridge_key] and vars.x[bridge_key] > 0.5,
            "bridge active (" .. tostring(vars.x[bridge_key]) .. ")"
        )
    end,
})

table.insert(cases, {
    name = "single out of range -> no bridge primal is created",
    -- boiler produces steam@500, generator requires steam@[15,200]. 500 is
    -- not in [15,200]; the bridge primal must not exist. (The LP itself is
    -- intentionally unbounded in this scenario: steam@500 only has free
    -- final_sink and steam@[15,200] only has free basic_source, so the
    -- combination of negative recipe cost + cost-0 slacks does not converge.
    -- That outcome belongs to a higher layer; here we only assert the bridge
    -- gating.)
    run = function()
        local lines = {
            recipe("boiler",
                { fluid_single("steam", 500, 1) },
                { item("water", 1) }),
            recipe("generator",
                { item("power", 1) },
                { fluid_range("steam", 15, 200, 1) }),
        }

        local problem = cp.create_problem("bridge-mismatch", {}, lines)

        local mismatched_bridge = bridge_primal_key("steam", 500, 15, 200)
        harness.assert_true(
            problem.primals[mismatched_bridge] == nil,
            "no bridge created for out-of-range temperature"
        )
    end,
})

table.insert(cases, {
    name = "two singles both in range -> two bridges",
    -- Two boilers produce steam@165 and steam@500; one generator accepts
    -- steam@[15,1000]. Both bridges must exist as primals (we don't pin
    -- which one the LP activates).
    run = function()
        local lines = {
            recipe("boiler-low",
                { fluid_single("steam", 165, 1) },
                { item("water", 1) }),
            recipe("boiler-high",
                { fluid_single("steam", 500, 1) },
                { item("water", 1) }),
            recipe("generator",
                { item("power", 1) },
                { fluid_range("steam", 15, 1000, 1) }),
        }
        local constraints = {
            { type = "item", name = "power", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("bridge-two-singles", constraints, lines)
        local state, _ = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        harness.assert_true(
            problem.primals[bridge_primal_key("steam", 165, 15, 1000)] ~= nil,
            "bridge from 165 exists"
        )
        harness.assert_true(
            problem.primals[bridge_primal_key("steam", 500, 15, 1000)] ~= nil,
            "bridge from 500 exists"
        )
    end,
})

table.insert(cases, {
    name = "bridge is not flagged as is_result (not surfaced to UI)",
    -- A Constraint is required to keep the chain active after the
    -- compute_active_lines pruning; without one all lines (including
    -- bridges) collapse to inactive and the LP is empty.
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
            { type = "item", name = "power", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }
        local problem = cp.create_problem("bridge-hidden", constraints, lines)

        local bridge_key = bridge_primal_key("steam", 165, 15, 1000)
        local primal = problem.primals[bridge_key]
        harness.assert_true(primal ~= nil, "bridge primal exists")
        harness.assert_eq(primal.is_result, false, "bridge is_result")
    end,
})

table.insert(cases, {
    name = "bridge generation is deterministic (sorted fluid names + temps)",
    -- Insert lines in reverse-sorted order to confirm we sort.
    run = function()
        local lines = {
            recipe("gen-water",
                { item("p1", 1) },
                { fluid_range("water", 0, 100, 1) }),
            recipe("gen-steam",
                { item("p2", 1) },
                { fluid_range("steam", 15, 1000, 1) }),
            recipe("pump-water",
                { fluid_single("water", 50, 1) },
                { item("i1", 1) }),
            recipe("pump-steam",
                { fluid_single("steam", 500, 1) },
                { item("i2", 1) }),
            recipe("pump-steam-low",
                { fluid_single("steam", 165, 1) },
                { item("i3", 1) }),
        }
        local bridges = cp.create_temperature_bridges(lines)
        local names = {}
        for _, b in ipairs(bridges) do
            names[#names + 1] = b.recipe_typed_name.name
        end
        -- Expected order: steam comes before water alphabetically; within
        -- steam, 165 comes before 500 numerically.
        harness.assert_eq(#names, 3, "three bridges")
        harness.assert_eq(names[1], "|bridge|fluid/steam@165->[15,1000]")
        harness.assert_eq(names[2], "|bridge|fluid/steam@500->[15,1000]")
        harness.assert_eq(names[3], "|bridge|fluid/water@50->[0,100]")
    end,
})

table.insert(cases, {
    name = "create_problem attaches bridge lines to the resulting Problem",
    run = function()
        local lines = {
            recipe("boiler",
                { fluid_single("steam", 500, 1) },
                { fluid_range("water", 0, 100, 1) }),
            recipe("generator",
                { item("p", 1) },
                { fluid_range("steam", 15, 1000, 1) }),
        }
        local problem = cp.create_problem("attach-bridges", {}, lines)
        harness.assert_eq(#problem.bridges, 1, "one bridge attached")
        local bridge = problem.bridges[1]
        harness.assert_eq(bridge.recipe_typed_name.name,
            "|bridge|fluid/steam@500->[15,1000]", "bridge name")
        harness.assert_eq(#bridge.ingredients, 1, "bridge has one ingredient")
        harness.assert_eq(bridge.ingredients[1].temperature, 500, "ingredient single temp")
        harness.assert_eq(#bridge.products, 1, "bridge has one product")
        harness.assert_eq(bridge.products[1].minimum_temperature, 15, "product range min")
        harness.assert_eq(bridge.products[1].maximum_temperature, 1000, "product range max")
    end,
})

return cases
