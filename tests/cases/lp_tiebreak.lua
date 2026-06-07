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

-- Scenario 3: two byte-identical 1 A -> 1 B recipes. There is no *material*
-- information to distinguish them, so source_cost is indifferent and the optimal
-- face is degenerate -- the IPM would otherwise return its analytic-centre split
-- (5 / 5). The per-recipe recipe_epsilon jitter (a deterministic hash of each
-- recipe's variable key, see create_problem.lua) gives the two copies fractionally
-- different epsilons, collapsing the face to a single canonical vertex: the LP
-- routes the whole demand through one copy and drives the other to zero. The
-- choice is arbitrary but reproducible -- same problem, same winner, every solve
-- and on every client (the jitter is a pure function of the key, not RNG).
table.insert(cases, {
    name = "identical copies: epsilon jitter picks one canonical copy, deterministically",
    run = function()
        local lines = {
            line("convert-a", { item("B", 1) }, { item("A", 1) }),
            line("convert-b", { item("B", 1) }, { item("A", 1) }),
        }
        local state, vars = solve(lines, { demand("B", 10) })

        harness.assert_eq(state, "finished", "solver_state")
        local a, b = rx(vars, "convert-a"), rx(vars, "convert-b")
        harness.assert_near(a + b, 10, 0.01, "combined output meets demand")
        -- Canonical, not split: one copy carries the bulk of the load while the
        -- other is driven toward zero (it parks at a small IPM residual rather
        -- than exactly 0 -- the same dust the recipe_epsilon note documents -- so
        -- the bar is "decisively broken", not "exactly 10/0").
        local hi, lo = math.max(a, b), math.min(a, b)
        harness.assert_true(hi >= 9.5,
            string.format("one copy carries the demand (a=%g b=%g)", a, b))
        harness.assert_true(lo <= 0.5,
            string.format("the other copy is driven toward zero (a=%g b=%g)", a, b))

        -- Reproducible: re-solving picks the same winner, not a coin flip.
        local _, vars2 = solve(lines, { demand("B", 10) })
        harness.assert_near(rx(vars2, "convert-a"), a, 1e-9, "convert-a stable across solves")
        harness.assert_near(rx(vars2, "convert-b"), b, 1e-9, "convert-b stable across solves")
    end,
})

return cases
