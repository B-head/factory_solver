-- Tie-break fixtures: multiple recipes that produce the same product, where
-- the LP has more than one optimal solution. These exist to document what the
-- solver does when the objective is genuinely indifferent between recipes.
--
-- Background: until this branch the LP carried a small negative per-recipe
-- cost (make_recipe_cost, introduced in 8b31e76). It was removed once the
-- structural machinery -- reachability gating, elastic sinks, active-line
-- pruning, the long-step IPM -- made its stabilisation role redundant. Removing
-- it exposes the fact that the LP no longer breaks ties between equivalent
-- producers: with every recipe at cost 0, a set of recipes that can each
-- satisfy the constraint forms a degenerate optimum, and the interior-point
-- method converges to the analytic centre (flow split roughly evenly) rather
-- than committing to one recipe.
--
-- The three scenarios separate the cases:
--   1. different conversion ratios   -- a tie-break is genuinely desirable
--      (prefer the material-efficient recipe), and is the one xfail here.
--   2. different craft times         -- legacy made the *wrong* choice (more
--      machines); degeneracy is recorded as the current behaviour.
--   3. identical copies              -- no information to break the tie;
--      symmetric split is the only sensible behaviour.
--
-- Where a tie-break is actually wanted (scenario 1), the right lever per the
-- project's cost-location principle is a cost on the *source* of the wasted
-- material, not a per-recipe term -- so scenario 1 is written as the spec we
-- would satisfy that way, and marked xfail until such a cost exists.

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

-- Scenario 1 (xfail): two recipes make B from A at different ratios --
-- convert-efficient is 1 A -> 1 B, convert-wasteful is 2 A -> 1 B. A is an
-- ingredient with no producer, so create_problem supplies it through a free
-- |basic_source|. With the source free, wasting A costs the LP nothing, so
-- both recipes are optimal and the IPM splits the 10 B/s demand roughly
-- evenly (~4.97 / ~5.03). The behaviour we *want* is to run only the
-- efficient recipe; achieving it requires a cost on the A source, which the
-- LP does not have today. Marked xfail until that cost exists.
table.insert(cases, {
    name = "different ratios: LP should prefer the material-efficient recipe",
    xfail = true,
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

-- Scenario 2: two recipes make B from A at the same 1:1 ratio but different
-- per-line throughput -- convert-fast does 2 A -> 2 B per line, convert-slow
-- does 1 A -> 1 B. Reaching 10 B/s takes 5 fast lines or 10 slow lines. The
-- objective is indifferent (no machine-count cost), so the optimum is
-- degenerate and the IPM splits the flow; both recipes carry positive flow.
-- (The removed legacy cost actually preferred the *slow* recipe here -- more
-- lines, lower per-line cost summed larger in magnitude -- which is the
-- opposite of what a machine-count objective would want. Recorded so a future
-- machine-count cost, which should collapse this onto convert-fast, changes
-- the assertion visibly.)
table.insert(cases, {
    name = "different craft times: degenerate optimum splits flow (no machine-count cost)",
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
        harness.assert_true(fast > 0.1 and slow > 0.1,
            string.format("both recipes carry flow (fast=%g slow=%g) -- degenerate, no tie-break",
                fast, slow))
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
