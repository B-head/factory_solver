-- User-controlled infinite source / sink virtual recipes (manage/virtual.lua,
-- create_problem.lua). These are plain virtual recipes the user adds to the
-- production line:
--   <source>X : no ingredients, emits 1 X per craft. Priced at source_cost on
--               its product so the LP draws on it like a declared external
--               input -- cheap enough to bypass a wasteful producer chain, but
--               not free, so an efficient chain still wins.
--   <sink>X   : consumes 1 X per craft, emits nothing. Free (slack_cost = 0),
--               so it out-competes the automatic |surplus_sink| (elastic_cost)
--               for absorbing byproduct surplus.
--
-- create_problem detects these by the is_source / is_sink flags that normalize
-- propagates from the VirtualRecipe in-game; headless fixtures set them directly
-- via the `line` helper's opts, so the <source>/<sink> names stay only as
-- human-readable labels.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local function item(name, amount)
    return { type = "item", name = name, quality = "normal", amount_per_second = amount }
end

---@param recipe_type "recipe"|"virtual_recipe"
---@param opts { is_source: boolean?, is_sink: boolean? }?
local function line(recipe_type, recipe_name, products, ingredients, opts)
    opts = opts or {}
    return {
        recipe_typed_name = { type = recipe_type, name = recipe_name, quality = "normal" },
        products = products,
        ingredients = ingredients,
        power_per_second = 0,
        pollution_per_second = 0,
        -- Set explicitly because headless fixtures skip normalize, which is what
        -- propagates these from the VirtualRecipe in-game.
        is_source = opts.is_source,
        is_sink = opts.is_sink,
    }
end

local function solve(lines, constraints)
    local problem = cp.create_problem("source_sink", constraints, lines)
    local state, vars = harness.solve_to_completion(lp, problem,
        { tolerance = 1e-6, iterate_limit = 400 })
    return state, vars
end

local function rx(vars, name)
    return (vars and vars.x and vars.x["recipe/" .. name .. "/normal"]) or 0
end

local function vrx(vars, name)
    return (vars and vars.x and vars.x["virtual_recipe/" .. name .. "/normal"]) or 0
end

local function demand(name, amount)
    return { type = "item", name = name, quality = "normal",
             limit_type = "equal", limit_amount_per_second = amount }
end

local cases = {}

-- A bare source can satisfy demand on its own: with no producer chain present,
-- the LP runs the source recipe at exactly the demanded rate (one craft == one
-- unit/sec because virtual.lua emits amount 1 with crafting_speed_cap 1).
table.insert(cases, {
    name = "source alone satisfies demand",
    run = function()
        local state, vars = solve(
            { line("virtual_recipe", "<source>item/plate", { item("plate", 1) }, {}, { is_source = true }) },
            { demand("plate", 10) })

        harness.assert_eq(state, "finished", "solver_state")
        harness.assert_near(vrx(vars, "<source>item/plate"), 10, 0.01,
            "source carries the whole demand")
    end,
})

-- source_cost makes the source a cheap boundary that bypasses a wasteful chain:
-- smelting is 2 ore -> 1 plate, so the chain costs 2 source units of ore per
-- plate, while the source costs 1 per plate. The LP runs only the source.
table.insert(cases, {
    name = "source (source_cost) bypasses a wasteful producer chain",
    run = function()
        local state, vars = solve(
            {
                line("recipe", "smelt", { item("plate", 1) }, { item("ore", 2) }),
                line("virtual_recipe", "<source>item/plate", { item("plate", 1) }, {}, { is_source = true }),
            },
            { demand("plate", 10) })

        harness.assert_eq(state, "finished", "solver_state")
        harness.assert_near(vrx(vars, "<source>item/plate"), 10, 0.1,
            "source supplies the plate")
        harness.assert_near(rx(vars, "smelt"), 0, 0.1,
            "the wasteful chain is left idle")
    end,
})

-- The source is priced, not free: when the chain is efficient (1 ore ->
-- 2 plate, costing 0.5 ore per plate) it beats the source (1 per plate), so
-- the LP runs the chain and leaves the source idle. This is the guard that the
-- source did not collapse into a free fountain.
table.insert(cases, {
    name = "source is priced: an efficient chain beats it",
    run = function()
        local state, vars = solve(
            {
                line("recipe", "smelt", { item("plate", 2) }, { item("ore", 1) }),
                line("virtual_recipe", "<source>item/plate", { item("plate", 1) }, {}, { is_source = true }),
            },
            { demand("plate", 10) })

        harness.assert_eq(state, "finished", "solver_state")
        harness.assert_near(rx(vars, "smelt"), 5, 0.1,
            "the efficient chain runs (5 crafts -> 10 plate)")
        harness.assert_near(vrx(vars, "<source>item/plate"), 0, 0.1,
            "the priced source is left idle")
    end,
})

-- A free sink out-competes the automatic |surplus_sink| for byproduct surplus:
-- react is 1 A -> 1 B + 3 C, demand B = 10 forces 30 C/s of surplus. The
-- explicit <sink>C (cost 0) absorbs all of it instead of the elastic-cost
-- automatic surplus sink.
table.insert(cases, {
    name = "free sink absorbs byproduct surplus",
    run = function()
        local state, vars = solve(
            {
                line("recipe", "react", { item("B", 1), item("C", 3) }, { item("A", 1) }),
                line("virtual_recipe", "<sink>item/C", {}, { item("C", 1) }, { is_sink = true }),
            },
            { demand("B", 10) })

        harness.assert_eq(state, "finished", "solver_state")
        harness.assert_near(rx(vars, "react"), 10, 0.1,
            "react runs to meet the B demand")
        harness.assert_near(vrx(vars, "<sink>item/C"), 30, 0.1,
            "the free sink swallows all 30 C/s of surplus")
    end,
})

return cases
