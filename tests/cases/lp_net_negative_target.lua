-- A target material that is net-NEGATIVE in its own production loop: the solver
-- cannot produce it with any non-negative recipe scaling, so it falls back to
-- the |shortage_source| escape hatch and returns a DEGENERATE solution -- target
-- "met", but every real recipe parked at zero (no factory is built).
--
-- Captured verbatim from a real pyanodon solve ('Solution 3'): target ash = 0.5/s
-- equal, over three recipes that form an ash loop:
--   coal-gas-from-coke:           2 coke           -> 0.1 ash + coal-gas + tar
--   residual-mixture-distillation:25 residual-mixture + 25 vacuum
--                                                  -> 5 coke + residual-oil + ...
--   residual-mixture:             2.5 ash + 50 residual-oil + 50 steam
--                                                  -> 25 residual-mixture
-- Let a/b/c be the three recipe rates. coke balance gives a = 2.5b, residual-
-- mixture balance gives c = b, so the net ash made by the loop is
--   0.1a - 2.5c = 0.25b - 2.5b = -2.25b,
-- negative for every b > 0. There is NO non-negative recipe vector producing net
-- ash, so demanding 0.5/s is structurally infeasible. This is NOT a solver bug:
-- create_problem keeps the |shortage_source| gate for materials stuck in a mass-
-- losing loop (solver/create_problem.lua, the "dead-end cycle" branch) precisely
-- so the LP stays feasible and returns a graceful answer instead of all-zero-or-
-- nothing. The point of pinning it here is to lock the SHAPE of that answer:
--   * solver_state = finished (always feasible via the soft slacks)
--   * |shortage_source|ash = 0.5 (the whole target fabricated)
--   * |surplus_sink|ash    = 0.5 (the ash balance row dumps the fabricated mass)
--   * every recipe rate     = 0  (the degenerate signal: nothing actually runs)
-- A regression that let a recipe carry flow here, or that dropped the shortage
-- gate (returning unfeasible / all-zero), would break one of these.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local function it(name, amount)
    return { type = "item", name = name, quality = "normal", amount_per_second = amount }
end
local function fl(name, amount, tmin, tmax)
    return { type = "fluid", name = name, quality = "normal", amount_per_second = amount,
        minimum_temperature = tmin, maximum_temperature = tmax }
end

local cases = {}

table.insert(cases, {
    name = "net-negative target falls back to a degenerate shortage solution (no recipe runs)",
    run = function()
        local lines = {
            {
                recipe_typed_name = { type = "recipe", name = "coal-gas-from-coke", quality = "normal" },
                products = { it("ash", 0.1), fl("coal-gas", 2, 15, 15), fl("tar", 2, 10, 10) },
                ingredients = { it("coke", 2) },
                fuel_ingredient = it("charcoal-briquette", 0.0011111111111111112),
                power_per_second = 0,
                pollution_per_second = 0,
            },
            {
                recipe_typed_name = { type = "recipe", name = "residual-mixture-distillation", quality = "normal" },
                products = { it("coke", 5), fl("residual-oil", 6.25, 10, 10), fl("hot-residual-mixture", 3.125, 10, 10) },
                ingredients = { fl("residual-mixture", 25, 10, 100), fl("vacuum", 25, 15, 100) },
                fuel_ingredient = it("charcoal-briquette", 0.0011111111111111112),
                power_per_second = 0,
                pollution_per_second = 0,
            },
            {
                recipe_typed_name = { type = "recipe", name = "residual-mixture", quality = "normal" },
                products = { fl("residual-mixture", 25, 10, 10) },
                ingredients = { it("ash", 2.5), fl("residual-oil", 50, 10, 100), fl("steam", 50, 15, 2000) },
                power_per_second = 1033333.3333333334,
                pollution_per_second = 0.0009999999999999998,
            },
        }
        local constraints = {
            { type = "item", name = "ash", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 0.5 },
        }

        local problem = cp.create_problem("net-negative-ash", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state (always feasible via soft slacks)")
        assert(vars, "expected packed variables on finished state")

        -- The whole target is fabricated and immediately dumped: a degenerate
        -- "solution" that builds no factory.
        harness.assert_near(vars.x["|shortage_source|item/ash/normal"], 0.5, 1e-4,
            "target ash fabricated entirely by shortage_source")
        harness.assert_near(vars.x["|surplus_sink|item/ash/normal"], 0.5, 1e-4,
            "fabricated ash dumped by surplus_sink to balance the ash row")

        -- THE degenerate signal: no real recipe carries any flow. A mass-losing
        -- loop cannot make net ash, so the LP runs nothing rather than spinning
        -- the loop (which would only consume MORE ash).
        for _, rn in ipairs({ "coal-gas-from-coke", "residual-mixture-distillation", "residual-mixture" }) do
            harness.assert_near(vars.x["recipe/" .. rn .. "/normal"] or 0, 0, 1e-4,
                "recipe/" .. rn .. " must stay parked (degenerate shortage solution)")
        end
    end,
})

return cases
