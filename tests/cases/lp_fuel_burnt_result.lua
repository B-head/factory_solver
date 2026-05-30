-- burnt_result (spent fuel cell) fixture: the nuclear reprocessing loop in
-- miniature. A reactor burns a fuel cell and, via the fuel item's burnt_result,
-- emits a spent cell as a trailing pseudo-product (acc.normalize_production_line
-- sets line.fuel_burnt_result; create_problem's each_product feeds it into the
-- LP as production). A reprocessing recipe consumes the spent cell back into
-- the fissile material, closing the loop:
--
--   u238-mining:  () -> uranium-238                         (bootstrap seed)
--   fuel-cell:    uranium-238 -> fuel-cell
--   reactor:      fuel-cell (fuel) -> heat  + used-up-cell  (burnt_result)
--   reprocessing: used-up-cell -> 0.6 uranium-238
--
-- Without burnt_result handling the spent cell is never produced, so the
-- reprocessing ingredient would be a producer-less boundary material (it would
-- pick up a |basic_source|) and the loop would not close. The assertions guard
-- exactly that: the spent cell is produced internally (no basic_source), the
-- reprocessing recipe runs to absorb it instead of paying surplus_sink, and the
-- reactor meets the heat demand.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local function item(name, quality, amount)
    return { type = "item", name = name, quality = quality or "normal", amount_per_second = amount }
end

local function line(recipe_name, products, ingredients, fuel_ingredient, fuel_burnt_result)
    return {
        recipe_typed_name = { type = "recipe", name = recipe_name, quality = "normal" },
        products = products,
        ingredients = ingredients,
        fuel_ingredient = fuel_ingredient,
        fuel_burnt_result = fuel_burnt_result,
        power_per_second = 0,
        pollution_per_second = 0,
    }
end

local cases = {}

table.insert(cases, {
    name = "nuclear reprocessing loop closes through fuel burnt_result",
    run = function()
        local lines = {
            -- bootstrap: makes uranium-238 reachable from a raw boundary so the
            -- loop is not entirely closed (see tests/run.lua bootstrap rule).
            line("u238-mining",
                { item("uranium-238", "normal", 1) },
                {}),
            line("fuel-cell",
                { item("fuel-cell", "normal", 1) },
                { item("uranium-238", "normal", 1) }),
            -- reactor: heat is the real product; the spent cell rides along as
            -- fuel_burnt_result (1:1 with the consumed fuel cell).
            line("reactor",
                { item("heat", "normal", 1) },
                {},
                item("fuel-cell", "normal", 1),
                item("used-up-cell", "normal", 1)),
            line("reprocessing",
                { item("uranium-238", "normal", 0.6) },
                { item("used-up-cell", "normal", 1) }),
        }
        local constraints = {
            { type = "item", name = "heat", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("burnt-result-loop", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")

        -- The reactor runs ~1 to meet the heat=1 demand, emitting ~1 spent
        -- cell/s as its burnt_result.
        harness.assert_near(vars.x["recipe/reactor/normal"] or 0, 1, 0.01,
            "reactor runs to meet heat demand")

        -- The reprocessing recipe must run to absorb the produced spent cells
        -- (leaving them unconsumed would cost surplus_sink at elastic price).
        harness.assert_true((vars.x["recipe/reprocessing/normal"] or 0) > 0.5,
            "reprocessing runs (got " .. tostring(vars.x["recipe/reprocessing/normal"]) .. ")")

        -- The spent cell is produced internally by the reactor, so it must NOT
        -- acquire a |basic_source| (that would mean the solver treated it as a
        -- raw boundary input -- the pre-burnt_result behaviour this guards).
        harness.assert_true(
            (vars.x["|basic_source|item/used-up-cell/normal"] or 0) < 1e-6,
            "spent cell is produced, not sourced as raw (got "
                .. tostring(vars.x["|basic_source|item/used-up-cell/normal"]) .. ")")
        -- Nor a |shortage_source|: it is reachable through the reactor.
        harness.assert_true(
            (vars.x["|shortage_source|item/used-up-cell/normal"] or 0) < 1e-6,
            "no shortage_source on the spent cell")

        -- The heat constraint is met without penalised slack.
        harness.assert_near(
            vars.x["%positive_slack%|limit|item/heat/normal"] or 0,
            0, 0.01, "no positive_slack on the heat constraint")
    end,
})

return cases
