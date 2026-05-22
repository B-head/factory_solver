-- Regression net for the "Line isolated from any Constraint" gating logic.
-- compute_active_lines should prune lines whose recipe variable is not
-- graph-connected to any Constraint's |limit| dual; the LP then never sees
-- them (no primal variable, no spurious 2^52 quantities) and the solver
-- exposes the dropped recipes via problem.inactive_recipe_variables so the
-- UI can gray them out.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
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
    -- Without gating the LP would have no upper anchor on r1 (recipe_cost is
    -- always negative) and the IPM would push it to the 2^52 clamp ceiling,
    -- producing the "1e15 machines" UI bug. With gating r1 is dropped from
    -- the LP entirely and is reported as inactive.
    name = "lines with empty constraints are all inactive",
    run = function()
        local lines = {
            line("r1", { item("m2", 2) }, { item("m1", 1) }),
        }
        local constraints = {}

        local problem = cp.create_problem("empty-constraints", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 200 })

        harness.assert_eq(state, "finished", "solver_state")
        harness.assert_true(
            problem.inactive_recipe_variables["recipe/r1/normal"] == true,
            "r1 should be inactive when no constraints exist"
        )
        harness.assert_true(
            problem.primals["recipe/r1/normal"] == nil,
            "r1 primal should not exist in the LP"
        )
        if vars then
            harness.assert_true(
                vars.x["recipe/r1/normal"] == nil,
                "r1 should not appear in solved variables"
            )
        end
    end,
})

table.insert(cases, {
    -- A constraint anchored on m3 pulls in r2 (which produces m3) and r1
    -- (which produces m3's ingredient m2). An unrelated copper-cable Line
    -- shares no material with the chain and is therefore inactive.
    name = "lines outside the constraint chain are inactive",
    run = function()
        local lines = {
            line("r1",   { item("m2", 1) },           { item("m1", 1) }),
            line("r2",   { item("m3", 1) },           { item("m2", 1) }),
            line("cu",   { item("copper-cable", 2) }, { item("copper-plate", 1) }),
        }
        local constraints = {
            { type = "item", name = "m3", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 5 },
        }

        local problem = cp.create_problem("partial-chain", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        harness.assert_true(
            problem.inactive_recipe_variables["recipe/cu/normal"] == true,
            "copper-cable line should be inactive"
        )
        harness.assert_true(
            not problem.inactive_recipe_variables["recipe/r1/normal"],
            "r1 (chain ingredient producer) should be active"
        )
        harness.assert_true(
            not problem.inactive_recipe_variables["recipe/r2/normal"],
            "r2 (constrained product producer) should be active"
        )
        assert(vars, "expected packed variables on finished state")
        harness.assert_near(vars.x["recipe/r1/normal"], 5, 0.1, "r1 rate")
        harness.assert_near(vars.x["recipe/r2/normal"], 5, 0.1, "r2 rate")
        harness.assert_true(
            vars.x["recipe/cu/normal"] == nil,
            "copper-cable variable should not be in the LP"
        )
    end,
})

table.insert(cases, {
    -- A constraint on a recipe variable (not a material) still anchors that
    -- recipe through the |limit|<recipe> dual that non-bridge lines link to.
    -- Downstream consumers of the recipe's product also pull into the active
    -- set via the shared material.
    name = "recipe-typed constraint anchors its line and downstream consumers",
    run = function()
        local lines = {
            line("r1", { item("m2", 1) }, { item("m1", 1) }),
            line("r2", { item("m3", 1) }, { item("m2", 1) }),
        }
        local constraints = {
            { type = "recipe", name = "r1", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 3 },
        }

        local problem = cp.create_problem("recipe-anchor", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        harness.assert_true(
            not problem.inactive_recipe_variables["recipe/r1/normal"],
            "r1 (constrained recipe) should be active"
        )
        harness.assert_true(
            not problem.inactive_recipe_variables["recipe/r2/normal"],
            "r2 (m2 consumer) should be active"
        )
        assert(vars, "expected packed variables on finished state")
        harness.assert_near(vars.x["recipe/r1/normal"], 3, 0.1, "r1 rate pinned by recipe constraint")
    end,
})

return cases
