-- Solver-level invariants and degenerate-input behaviour, as opposed to the
-- factory-shaped fixtures in the other lp_* files. These pin properties a
-- researcher needs to be able to rely on while changing the IPM or the
-- problem builder:
--   * determinism (bit-identical output for identical input -- the lockstep
--     invariant; a stray math.random / os.clock in the solver would break it),
--   * graceful infeasibility (the soft elastic/shortage/surplus structure
--     means the LP is ALWAYS feasible and bounded -- impossible demands are
--     absorbed by penalty variables, never returned as an error state or NaN),
--   * independence (two materially-disjoint sub-problems solved in one LP do
--     not contaminate each other),
--   * the zero optimum (a constraint of 0, or no pull at all, converges to the
--     origin cleanly rather than stalling or producing NaN).

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local pg = require "solver/problem_generator"
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
    name = "determinism: identical input solves to bit-identical output",
    -- The solver must be a pure function of its input -- no RNG, no wall
    -- clock, no global mutable state leaking between solves. In Factorio's
    -- lockstep VM a single non-deterministic float would desync the session.
    -- Build the same small loop twice, solve both cold, and require every
    -- packed variable to match with exact == (not assert_near).
    run = function()
        local function build()
            local p = pg.new("determinism")
            -- m1 -[r1]-> m2 -[r2]-> m3, pin m3 == 5.
            p:add_objective("r1", 0, true)
            p:add_objective("r2", 0, true)
            p:add_objective("src", 1, false)
            p:add_equivalence_constraint("m1", 0)
            p:add_equivalence_constraint("m2", 0)
            p:add_equivalence_constraint("m3", 5)
            p:add_subject_term("r1", "m1", -1)
            p:add_subject_term("src", "m1", 1)
            p:add_subject_term("r1", "m2", 1)
            p:add_subject_term("r2", "m2", -1)
            p:add_subject_term("r2", "m3", 1)
            return p
        end

        local s1, v1 = harness.solve_to_completion(lp, build(), { tolerance = 1e-7, iterate_limit = 300 })
        local s2, v2 = harness.solve_to_completion(lp, build(), { tolerance = 1e-7, iterate_limit = 300 })

        harness.assert_eq(s1, "finished", "first solve state")
        harness.assert_eq(s2, "finished", "second solve state")
        assert(v1 and v2, "both solves returned variables")
        for _, group in ipairs({ "x", "y", "s" }) do
            for k, val in pairs(v1[group]) do
                if v2[group][k] ~= val then
                    error(string.format("non-deterministic %s[%q]: %.17g vs %.17g",
                        group, k, val, v2[group][k]), 2)
                end
            end
        end
    end,
})

table.insert(cases, {
    name = "graceful infeasibility: an impossible demand is absorbed by elastic, not returned as an error",
    -- make-B converts A -> B 1:1; A is capped at 3/s (upper limit on the raw
    -- input) but B is demanded at 10/s. No feasible point satisfies both, so a
    -- hard LP would be infeasible. The soft structure must instead converge
    -- with the |elastic| on B's limit absorbing the 7/s shortfall -- a usable
    -- answer the UI can surface, not an error state.
    run = function()
        local lines = { line("make-B", { item("B", 1) }, { item("A", 1) }) }
        local constraints = {
            { type = "item", name = "A", quality = "normal",
              limit_type = "upper", limit_amount_per_second = 3 },
            { type = "item", name = "B", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 10 },
        }
        local problem = cp.create_problem("infeasible-demand", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "still reaches a terminal feasible state")
        assert(vars, "packed variables returned")
        -- A cap binds: make-B can only run at 3.
        harness.assert_near(vars.x["recipe/make-B/normal"], 3, 0.05, "make-B capped by A supply")
        harness.assert_near(vars.x["|basic_source|item/A/normal"], 3, 0.05, "A drawn at its cap")
        -- The 7/s shortfall on B is carried by the elastic, not by NaN/error.
        local elastic = vars.x["|elastic||limit|item/B/normal"] or 0
        harness.assert_true(elastic > 6.5,
            "B's elastic absorbs the shortfall (got " .. tostring(elastic) .. ")")
    end,
})

table.insert(cases, {
    name = "independence: two materially-disjoint chains solve correctly in one LP",
    -- Block A: a1 -[ra]-> a2, pin a2 == 5.  Block B: b1 -[rb]-> b2, pin
    -- b2 == 3.  The two share no material, so the LP is block-diagonal; each
    -- block must reach its own target with no cross-contamination.
    run = function()
        local lines = {
            line("ra", { item("a2", 1) }, { item("a1", 1) }),
            line("rb", { item("b2", 1) }, { item("b1", 1) }),
        }
        local constraints = {
            { type = "item", name = "a2", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 5 },
            { type = "item", name = "b2", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 3 },
        }
        local problem = cp.create_problem("two-blocks", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        harness.assert_near(vars.x["recipe/ra/normal"], 5, 0.05, "block A at its own target")
        harness.assert_near(vars.x["recipe/rb/normal"], 3, 0.05, "block B at its own target")
        harness.assert_near(vars.x["|basic_source|item/a1/normal"], 5, 0.05, "block A raw draw")
        harness.assert_near(vars.x["|basic_source|item/b1/normal"], 3, 0.05, "block B raw draw")
    end,
})

table.insert(cases, {
    name = "zero optimum: a constraint of 0 converges to the origin without stalling",
    -- m1 -[r1]-> m2, pin m2 == 0. The only feasible (and optimal) answer is
    -- the all-zero vector. The IPM stays strictly interior so values won't be
    -- exactly 0, but they must converge to a small neighbourhood and the solve
    -- must terminate cleanly (no NaN, no iterate-limit blow-up).
    run = function()
        local p = pg.new("zero-optimum")
        p:add_objective("r1", 0, true)
        p:add_objective("src", 1, false)
        p:add_equivalence_constraint("m1", 0)
        p:add_equivalence_constraint("m2", 0)
        p:add_subject_term("r1", "m1", -1)
        p:add_subject_term("src", "m1", 1)
        p:add_subject_term("r1", "m2", 1)

        local state, vars, steps = harness.solve_to_completion(lp, p,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        harness.assert_near(vars.x.r1, 0, 1e-3, "r1 converges to zero")
        harness.assert_near(vars.x.src, 0, 1e-3, "src converges to zero")
        harness.assert_true(steps < 300, "terminated within the iterate budget")
    end,
})

return cases
