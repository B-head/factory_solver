-- spent_fluid (fluid fuel residue) fixture: the fluid counterpart of
-- lp_fuel_burnt_result. A fluid-burning machine burns a fuel fluid and, via the
-- spent_fluid mechanism (FluidPrototype / FluidEnergySource / Generator, 2.1.9),
-- emits a residue FLUID as a trailing pseudo-product -- acc.normalize_production_line
-- sets line.fuel_spent_fluid; create_problem's each_product feeds it into the LP
-- as production, exactly as it does the item burnt_result. A reprocessing recipe
-- consumes the residue back into the fuel fluid, closing the loop:
--
--   fuel-fluid-source: () -> fuel-fluid                       (bootstrap seed)
--   generator: fuel-fluid (fuel) -> heat + spent-fluid@[500]  (fuel_spent_fluid, 1:1)
--   reprocess: spent-fluid -> 0.6 fuel-fluid
--
-- The residue differs from a burnt_result in one load-bearing way: it is a FLUID
-- at a point temperature, so unlike the always-item spent cell it flows through
-- create_temperature_bridges. The two cases pin both paths:
--
--   * "direct": reprocess consumes spent-fluid@[500,500] -- same LP variable as the
--     generator's output, so the loop closes with no bridge.
--   * "bridged": reprocess consumes spent-fluid@[400,600] -- a wider acceptance
--     range, so the loop closes only if the point-temperature residue is bridged up
--     to it (the behaviour a burnt_result, being an item, never exercises).
--
-- Without spent_fluid handling the residue is never produced, so the reprocessing
-- ingredient becomes a producer-less boundary material (it would pick up a
-- |initial_source| / |shortage_source|) and the loop would not close.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local function item(name, amount)
    return { type = "item", name = name, quality = "normal", amount_per_second = amount }
end

local function fluid(name, amount, min_t, max_t)
    return {
        type = "fluid",
        name = name,
        quality = "normal",
        amount_per_second = amount,
        minimum_temperature = min_t,
        maximum_temperature = max_t,
    }
end

local function line(recipe_name, products, ingredients, fuel_ingredient, fuel_spent_fluid)
    return {
        recipe_typed_name = { type = "recipe", name = recipe_name, quality = "normal" },
        products = products,
        ingredients = ingredients,
        fuel_ingredient = fuel_ingredient,
        fuel_spent_fluid = fuel_spent_fluid,
        power_per_second = 0,
        pollution_per_second = 0,
    }
end

-- Shared solve + assertions for both cases. `reprocess_ingredient` is the only
-- thing that differs (exact point vs wider acceptance range).
local function run_case(reprocess_ingredient)
    local lines = {
        -- bootstrap: makes fuel-fluid reachable from a raw boundary so the loop is
        -- not entirely closed (see tests/run.lua bootstrap rule).
        line("fuel-fluid-source", { fluid("fuel-fluid", 1) }, {}),
        -- generator: heat is the real product; the spent fluid rides along as
        -- fuel_spent_fluid (1:1 with the consumed fuel fluid), emitted at 500 deg.
        line("generator",
            { item("heat", 1) },
            {},
            fluid("fuel-fluid", 1),
            fluid("spent-fluid", 1, 500, 500)),
        line("reprocess",
            { fluid("fuel-fluid", 0.6) },
            { reprocess_ingredient }),
    }
    local constraints = {
        { type = "item", name = "heat", quality = "normal",
          limit_type = "equal", limit_amount_per_second = 1 },
    }

    local problem = cp.create_problem("spent-fluid-loop", constraints, lines)
    local state, vars = harness.solve_to_completion(lp, problem,
        { tolerance = 1e-6, iterate_limit = 400 })

    harness.assert_eq(state, "finished", "solver_state")
    assert(vars, "expected packed variables on finished state")

    -- The generator runs ~1 to meet the heat=1 demand, emitting ~1 spent fluid/s.
    harness.assert_near(vars.x["recipe/generator/normal"] or 0, 1, 0.01,
        "generator runs to meet heat demand")

    -- The reprocessing recipe must run to absorb the produced spent fluid (leaving
    -- it unconsumed would cost surplus_sink at elastic price).
    harness.assert_true((vars.x["recipe/reprocess/normal"] or 0) > 0.5,
        "reprocess runs (got " .. tostring(vars.x["recipe/reprocess/normal"]) .. ")")

    -- The spent fluid is produced internally by the generator, so its emitted
    -- point-temperature variable must NOT acquire a boundary source (that would mean
    -- the solver treated the residue as raw input -- the pre-spent_fluid behaviour).
    harness.assert_true(
        (vars.x["|initial_source|fluid/spent-fluid@[500,500]"] or 0) < 1e-6,
        "spent fluid is produced, not sourced as raw (got "
            .. tostring(vars.x["|initial_source|fluid/spent-fluid@[500,500]"]) .. ")")
    harness.assert_true(
        (vars.x["|shortage_source|fluid/spent-fluid@[500,500]"] or 0) < 1e-6,
        "no shortage_source on the spent fluid at its emitted temperature")

    -- The heat constraint is met without penalised slack.
    harness.assert_near(
        vars.x["%positive_slack%|limit|item/heat/normal"] or 0,
        0, 0.01, "no positive_slack on the heat constraint")

    return vars
end

local cases = {}

table.insert(cases, {
    name = "spent-fluid loop closes through fuel spent_fluid (direct, no bridge)",
    run = function()
        run_case(fluid("spent-fluid", 1, 500, 500))
    end,
})

table.insert(cases, {
    name = "spent-fluid loop closes through a temperature bridge",
    run = function()
        -- reprocess accepts the wider [400,600] range; the generator's [500,500]
        -- residue reaches it only via create_temperature_bridges, so the wider
        -- acceptance variable must also stay off any boundary source.
        local vars = run_case(fluid("spent-fluid", 1, 400, 600))
        harness.assert_true(
            (vars.x["|initial_source|fluid/spent-fluid@[400,600]"] or 0) < 1e-6,
            "reprocess's accepted spent fluid is bridged, not sourced as raw (got "
                .. tostring(vars.x["|initial_source|fluid/spent-fluid@[400,600]"]) .. ")")
    end,
})

return cases
