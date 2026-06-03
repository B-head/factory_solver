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

-- A point temperature is the degenerate range [T,T] in the range-only model.
local function fluid_single(name, temperature, amount)
    return {
        type = "fluid",
        name = name,
        quality = "normal",
        minimum_temperature = temperature,
        maximum_temperature = temperature,
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

-- A point producer is the degenerate range [temperature,temperature].
local function bridge_primal_key(fluid, temperature, min, max)
    return string.format(
        "virtual_recipe/|bridge|fluid/%s@[%g,%g]->[%g,%g]/normal",
        fluid, temperature, temperature, min, max
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
    name = "overproduced bridged fluid surfaces on the point, not the range",
    -- Physically fluid leaves the factory at a definite temperature, never "a
    -- range" -- the range variable (steam@[15,1000]) is a pure consumer-side
    -- acceptance abstraction that only ever exists as a bridge target. So it
    -- must NOT get a |surplus_sink|, while the physical point (steam@[165,165])
    -- keeps its own. Without this the LP is indifferent between leaving surplus
    -- on the point or the range (both at elastic_cost) and the interior-point
    -- solver centers it across both, leaking a range temperature into Final
    -- Products. Here the boiler is forced to run at 2 while the generator only
    -- draws 1 steam: the 1 unit of surplus must land entirely on the point.
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
            { type = "recipe", name = "boiler", quality = "normal",
              limit_type = "lower", limit_amount_per_second = 2 },
            { type = "item", name = "power", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("bridge-surplus", constraints, lines)

        -- Structural: the consumer-range variable has no surplus_sink; the
        -- physical point variable keeps its own.
        harness.assert_true(
            problem.primals["|surplus_sink|fluid/steam@[15,1000]"] == nil,
            "range variable must have no surplus_sink")
        harness.assert_true(
            problem.primals["|surplus_sink|fluid/steam@[165,165]"] ~= nil,
            "point variable keeps its surplus_sink")

        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })
        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")

        -- Behavioral: the surplus steam lands on the point, and the bridge
        -- carries exactly the generator's draw (the range never overproduces).
        harness.assert_near(vars.x["|surplus_sink|fluid/steam@[165,165]"], 1, 0.05,
            "surplus on the point variable")
        harness.assert_near(vars.x[bridge_primal_key("steam", 165, 15, 1000)], 1, 0.05,
            "bridge carries only the consumed amount")
    end,
})

table.insert(cases, {
    name = "single out of range -> no bridge primal is created",
    -- boiler produces steam@500, generator requires steam@[15,200]. 500 is
    -- not in [15,200]; the bridge primal must not exist. (The LP itself is
    -- intentionally unbounded in this scenario: steam@500 only has free
    -- final_sink and steam@[15,200] only has free initial_source, so the
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
        harness.assert_eq(names[1], "|bridge|fluid/steam@[165,165]->[15,1000]")
        harness.assert_eq(names[2], "|bridge|fluid/steam@[500,500]->[15,1000]")
        harness.assert_eq(names[3], "|bridge|fluid/water@[50,50]->[0,100]")
    end,
})

-- Collect the generated bridge names into a set for membership checks.
-- Tests the bridge-generation logic directly (like the deterministic-order
-- case) to bypass compute_active_lines pruning, which would drop every line
-- in a constraint-less fixture.
local function bridge_name_set(lines)
    local set = {}
    for _, b in ipairs(cp.create_temperature_bridges(lines)) do
        set[b.recipe_typed_name.name] = true
    end
    return set
end

table.insert(cases, {
    name = "one single feeding two overlapping ranges -> a bridge to each",
    -- steam@165 is consumed by two generators with ranges [15,200] and
    -- [100,300]. 165 falls inside both, so the inner single x range loop must
    -- emit a separate bridge per range (not just the first match).
    run = function()
        local names = bridge_name_set({
            recipe("pump", { fluid_single("steam", 165, 1) }, { item("w", 1) }),
            recipe("gen-a", { item("pa", 1) }, { fluid_range("steam", 15, 200, 1) }),
            recipe("gen-b", { item("pb", 1) }, { fluid_range("steam", 100, 300, 1) }),
        })
        harness.assert_true(names["|bridge|fluid/steam@[165,165]->[15,200]"], "bridge 165 -> [15,200] exists")
        harness.assert_true(names["|bridge|fluid/steam@[165,165]->[100,300]"], "bridge 165 -> [100,300] exists")
    end,
})

table.insert(cases, {
    name = "range membership is inclusive at both endpoints",
    -- steam@200 feeds a range that ends at 200 ([15,200], t == max) and one
    -- that starts at 200 ([200,300], t == min). The `min <= t and t <= max`
    -- test is inclusive, so both bridges must be created.
    run = function()
        local names = bridge_name_set({
            recipe("pump", { fluid_single("steam", 200, 1) }, { item("w", 1) }),
            recipe("gen-lo", { item("pa", 1) }, { fluid_range("steam", 15, 200, 1) }),
            recipe("gen-hi", { item("pb", 1) }, { fluid_range("steam", 200, 300, 1) }),
        })
        harness.assert_true(names["|bridge|fluid/steam@[200,200]->[15,200]"], "t == max boundary bridges")
        harness.assert_true(names["|bridge|fluid/steam@[200,200]->[200,300]"], "t == min boundary bridges")
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
            "|bridge|fluid/steam@[500,500]->[15,1000]", "bridge name")
        harness.assert_eq(#bridge.ingredients, 1, "bridge has one ingredient")
        harness.assert_eq(bridge.ingredients[1].minimum_temperature, 500, "ingredient point min")
        harness.assert_eq(bridge.ingredients[1].maximum_temperature, 500, "ingredient point max")
        harness.assert_eq(#bridge.products, 1, "bridge has one product")
        harness.assert_eq(bridge.products[1].minimum_temperature, 15, "product range min")
        harness.assert_eq(bridge.products[1].maximum_temperature, 1000, "product range max")
    end,
})

return cases
