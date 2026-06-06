-- Tie-break fixtures: multiple recipes that produce the same product, where
-- the LP has more than one optimal solution. They pin down which ties the
-- solver breaks and which it leaves degenerate.
--
-- Background: the LP carries no per-recipe cost (the historical
-- make_recipe_cost, 8b31e76, was removed once reachability gating, elastic
-- sinks, active-line pruning, and the long-step IPM made its stabilisation
-- role redundant). With every recipe at cost 0, recipes that can each satisfy
-- the constraint would form a degenerate optimum and the interior-point method
-- would converge to the analytic centre (flow split evenly). A small
-- source_cost on |initial_source| (external material supply) restores a
-- meaningful tie-break along the one axis the project's cost-location
-- principle sanctions: raw input drawn, not recipe identity.
--
-- The three scenarios separate the cases:
--   1. different conversion ratios -- source_cost breaks the tie: the LP runs
--      only the material-efficient recipe (the chain drawing less raw input).
--   2. different craft times -- still degenerate: source_cost is blind to
--      machine count (both draw the same raw input per unit of product) and
--      there is no machine-count cost. Recorded as the current behaviour.
--   3. identical copies -- no information to break the tie; symmetric split.

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

local function solve(lines, constraints)
    local problem = cp.create_problem("tiebreak", constraints, lines)
    local state, vars = harness.solve_to_completion(lp, problem,
        { tolerance = 1e-6, iterate_limit = 400 })
    return state, vars
end

local function rx(vars, name)
    return (vars and vars.x and vars.x["recipe/" .. name .. "/normal"]) or 0
end

local function demand(name, amount)
    return { type = "item", name = name, quality = "normal",
             limit_type = "equal", limit_amount_per_second = amount }
end

local cases = {}

-- Scenario 1: two recipes make B from A at different ratios --
-- convert-efficient is 1 A -> 1 B, convert-wasteful is 2 A -> 1 B. A is an
-- ingredient with no producer, so create_problem supplies it through a
-- |initial_source| at source_cost. The wasteful recipe draws twice the A and so
-- costs twice as much at the source, so the LP runs only the efficient recipe.
-- (Before source_cost this optimum was degenerate and the IPM split the 10 B/s
-- demand roughly evenly, ~4.97 / ~5.03.)
table.insert(cases, {
    name = "different ratios: source_cost makes the LP prefer the efficient recipe",
    run = function()
        local state, vars = solve(
            {
                line("convert-efficient", { item("B", 1) }, { item("A", 1) }),
                line("convert-wasteful",  { item("B", 1) }, { item("A", 2) }),
            },
            { demand("B", 10) })

        harness.assert_eq(state, "finished", "solver_state")
        harness.assert_near(rx(vars, "convert-efficient"), 10, 0.1,
            "efficient recipe carries the whole demand")
        harness.assert_near(rx(vars, "convert-wasteful"), 0, 0.1,
            "wasteful recipe is left idle")
    end,
})

-- Scenario 2: two recipes make B from A at the same 1:1 material ratio but
-- different per-line throughput -- convert-fast does 2 A -> 2 B per line,
-- convert-slow does 1 A -> 1 B. Reaching 10 B/s takes 5 fast lines or 10 slow
-- lines, consuming 10 A either way, so source_cost (material efficiency) is
-- indifferent. recipe_epsilon breaks the tie: it costs the same tiny amount per
-- line, so 5 fast lines (activity 5) beat 10 slow lines (activity 10) and the
-- LP collapses onto convert-fast -- the fewer-machine solution a machine-count
-- objective would want. (Before recipe_epsilon this optimum was degenerate and
-- the IPM split flow across both recipes; this scenario was recorded to
-- anticipate exactly this collapse.)
table.insert(cases, {
    name = "different craft times: recipe_epsilon collapses onto the fewer-line recipe",
    run = function()
        local state, vars = solve(
            {
                line("convert-fast", { item("B", 2) }, { item("A", 2) }),
                line("convert-slow", { item("B", 1) }, { item("A", 1) }),
            },
            { demand("B", 10) })

        harness.assert_eq(state, "finished", "solver_state")
        local fast, slow = rx(vars, "convert-fast"), rx(vars, "convert-slow")
        -- B output must meet the constraint: 2 per fast line + 1 per slow line.
        harness.assert_near(2 * fast + slow, 10, 0.01, "B output meets demand")
        -- recipe_epsilon prefers fewer lines: all demand via convert-fast
        -- (5 lines for 10 B), convert-slow driven to ~0.
        harness.assert_near(fast, 5, 0.01, "convert-fast carries the whole demand")
        harness.assert_near(slow, 0, 0.01, "convert-slow driven to zero")
    end,
})

-- Scenario 3: two byte-identical 1 A -> 1 B recipes. There is no information
-- to distinguish them, so the only sensible behaviour is a symmetric split.
-- The IPM's analytic-centre solution gives exactly that (5 / 5).
table.insert(cases, {
    name = "identical copies: symmetric split is the only sensible solution",
    run = function()
        local state, vars = solve(
            {
                line("convert-a", { item("B", 1) }, { item("A", 1) }),
                line("convert-b", { item("B", 1) }, { item("A", 1) }),
            },
            { demand("B", 10) })

        harness.assert_eq(state, "finished", "solver_state")
        local a, b = rx(vars, "convert-a"), rx(vars, "convert-b")
        harness.assert_near(a + b, 10, 0.01, "combined output meets demand")
        harness.assert_near(a, b, 0.01,
            string.format("copies split symmetrically (a=%g b=%g)", a, b))
    end,
})

return cases
