-- Regression suite for solver/substitution.lua, the escape-variable row
-- reduction presolve (column-singleton substitution).
--
-- Two layers:
--   1. Gate unit tests on hand-built Problems: a row folds only when it is a
--      limit-0 two-term equality pairing one recipe/bridge with one
--      column-singleton escape variable (final_sink / initial_source /
--      shortage_source) of the opposite sign. surplus_sink, recipe<->recipe
--      doubletons, multi-row escapes, and non-zero-limit rows must NOT fold.
--   2. End-to-end identity on real create_problem outputs: solving the reduced
--      problem and unfolding reproduces the full-problem solution (exactly on
--      unique optima) while actually shrinking the row count.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"
local pg = require "solver/problem_generator"
local sub = require "solver/substitution"

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

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local cases = {}

-- ---------------------------------------------------------------------------
-- Layer 1: gate unit tests on hand-built Problems.
-- ---------------------------------------------------------------------------

table.insert(cases, {
    name = "fold: terminal final_sink singleton is eliminated (cost 0)",
    run = function()
        local p = pg.new("final")
        p:add_objective("recipe/a", 1, true, "recipe")
        p:add_objective("|final_sink|m", 0, false, "final_sink")
        p:add_equivalence_constraint("m", 0)
        p:add_subject_term("recipe/a", "m", 2)       -- a produces 2 m
        p:add_subject_term("|final_sink|m", "m", -1) -- final_sink exports m

        local reduced, recon = sub.reduce(p)
        harness.assert_eq(count(recon.eliminated), 1, "final_sink eliminated")
        local info = recon.eliminated["|final_sink|m"]
        assert(info, "|final_sink|m eliminated")
        harness.assert_eq(info.rep, "recipe/a", "representative is the producer")
        harness.assert_near(info.k, 2, 1e-12, "k = -2/-1 (final_sink = 2*producer)")
        harness.assert_eq(reduced.dual_length, 0, "row removed")
        harness.assert_eq(reduced.primal_length, 1, "escape column removed")
        harness.assert_near(reduced.primals["recipe/a"].cost, 1, 1e-12,
            "cost unchanged (final_sink cost is 0)")
    end,
})

table.insert(cases, {
    name = "fold: raw initial_source singleton folds and transfers its cost",
    run = function()
        local p = pg.new("initial")
        p:add_objective("recipe/a", 1, true, "recipe")
        p:add_objective("|initial_source|m", 5, false, "initial_source")
        p:add_equivalence_constraint("m", 0)
        p:add_subject_term("recipe/a", "m", -3)        -- a consumes 3 m
        p:add_subject_term("|initial_source|m", "m", 1) -- supplied externally

        local reduced, recon = sub.reduce(p)
        local info = recon.eliminated["|initial_source|m"]
        assert(info, "|initial_source|m eliminated")
        harness.assert_near(info.k, 3, 1e-12, "initial_source = 3*consumer")
        -- cost transfers: c_a' = 1 + k*5 = 16.
        harness.assert_near(reduced.primals["recipe/a"].cost, 16, 1e-12, "cost transfer")
    end,
})

table.insert(cases, {
    name = "no fold: surplus_sink is a real slack, not a pinned escape",
    run = function()
        local p = pg.new("surplus")
        p:add_objective("recipe/a", 1, true, "recipe")
        p:add_objective("|surplus_sink|m", 1024, false, "surplus_sink")
        p:add_equivalence_constraint("m", 0)
        p:add_subject_term("recipe/a", "m", 1)
        p:add_subject_term("|surplus_sink|m", "m", -1)

        local _, recon = sub.reduce(p)
        harness.assert_eq(count(recon.eliminated), 0, "surplus_sink not folded")
    end,
})

table.insert(cases, {
    name = "no fold: recipe<->recipe doubleton (only escape singletons fold)",
    run = function()
        local p = pg.new("recrec")
        p:add_objective("recipe/a", 1, true, "recipe")
        p:add_objective("recipe/b", 1, true, "recipe")
        p:add_equivalence_constraint("m", 0)
        p:add_subject_term("recipe/a", "m", 2)
        p:add_subject_term("recipe/b", "m", -1)

        local _, recon = sub.reduce(p)
        harness.assert_eq(count(recon.eliminated), 0, "recipe-recipe row not folded")
    end,
})

table.insert(cases, {
    name = "no fold: escape that appears in a second row is not a column singleton",
    run = function()
        local p = pg.new("multirow")
        p:add_objective("recipe/a", 1, true, "recipe")
        p:add_objective("|initial_source|m", 1, false, "initial_source")
        p:add_equivalence_constraint("m", 0)
        p:add_equivalence_constraint("|limit|m", 5) -- a second registered row
        p:add_subject_term("recipe/a", "m", -1)
        p:add_subject_term("|initial_source|m", "m", 1)
        p:add_subject_term("|initial_source|m", "|limit|m", 1) -- escape in 2 rows

        local _, recon = sub.reduce(p)
        harness.assert_eq(count(recon.eliminated), 0, "multi-row escape not folded")
    end,
})

table.insert(cases, {
    name = "no fold: non-zero limit row",
    run = function()
        local p = pg.new("limit")
        p:add_objective("recipe/a", 1, true, "recipe")
        p:add_objective("|final_sink|m", 0, false, "final_sink")
        p:add_equivalence_constraint("m", 5) -- limit != 0
        p:add_subject_term("recipe/a", "m", 1)
        p:add_subject_term("|final_sink|m", "m", -1)

        local _, recon = sub.reduce(p)
        harness.assert_eq(count(recon.eliminated), 0, "non-zero limit row not folded")
    end,
})

-- ---------------------------------------------------------------------------
-- Layer 2: end-to-end identity on real create_problem outputs.
-- ---------------------------------------------------------------------------

local function solve_full(problem, tag, limit)
    local state, vars = harness.solve_to_completion(lp, problem,
        { tolerance = 1e-6, iterate_limit = limit or 400 })
    harness.assert_eq(state, "finished", tag .. " state")
    assert(vars, tag .. ": expected vars")
    return state, vars
end

local function solve_reduced(problem, tag, limit)
    local reduced, recon = sub.reduce(problem)
    local state, vars = harness.solve_to_completion(lp, reduced,
        { tolerance = 1e-6, iterate_limit = limit or 400 })
    harness.assert_eq(state, "finished", tag .. " reduced state")
    assert(vars, tag .. ": expected reduced vars")
    return state, sub.unfold(vars, recon), reduced
end

---Assert the two solutions agree on every full primal key. An activity floor
---skips the interior-point "dust" (recipes parked at ~tolerance/epsilon rather
---than exactly 0), whose residual is solver-path dependent and not part of the
---optimum.
local function assert_same_solution(full_problem, x_full, x_reduced, tag)
    local floor = 1e-2
    local mismatches = {}
    for key in pairs(full_problem.primals) do
        local va = x_full[key] or 0
        local vb = x_reduced[key] or 0
        if math.max(math.abs(va), math.abs(vb)) >= floor then
            local diff = math.abs(va - vb)
            local denom = math.max(math.abs(va), floor)
            if diff / denom > 1e-3 then
                table.insert(mismatches, string.format(
                    "  %s: full=%g reduced=%g (rel diff %g)", key, va, vb, diff / denom))
            end
        end
    end
    if #mismatches > 0 then
        table.sort(mismatches)
        error(tag .. ": reduced+unfold solution diverged from full:\n"
            .. table.concat(mismatches, "\n"), 2)
    end
end

table.insert(cases, {
    name = "identity: linear chain folds raw + terminal escapes, stays exact",
    run = function()
        local lines = {
            line("r1", { item("m2", 1) }, { item("m1", 1) }),
            line("r2", { item("m3", 1) }, { item("m2", 1) }),
        }
        local constraints = {
            { type = "item", name = "m3", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 5 },
        }

        local full = cp.create_problem("chain-full", constraints, lines)
        local _, vars_full = solve_full(full, "chain")
        local _, vars_reduced, reduced = solve_reduced(
            cp.create_problem("chain-red", constraints, lines), "chain")

        -- m1 (raw -> initial_source) and m3 (terminal -> final_sink) are
        -- escape-singleton rows, so both fold out.
        harness.assert_true(reduced.dual_length < full.dual_length,
            string.format("reduced rows %d < full rows %d",
                reduced.dual_length, full.dual_length))
        -- Unique optimum -> exact match.
        assert_same_solution(full, vars_full.x, vars_reduced.x, "chain")
        harness.assert_near(vars_reduced.x["recipe/r1/normal"], 5, 0.1, "r1 rate")
        harness.assert_near(vars_reduced.x["recipe/r2/normal"], 5, 0.1, "r2 rate")
        -- The folded escapes are reconstructed in full space.
        harness.assert_near(vars_reduced.x["|initial_source|item/m1/normal"], 5, 0.1,
            "raw supply reconstructed")
        harness.assert_near(vars_reduced.x["|final_sink|item/m3/normal"], 5, 0.1,
            "final output reconstructed")
    end,
})

table.insert(cases, {
    name = "identity: recycling loop stays exact under reduce+unfold",
    run = function()
        local lines = {
            line("iron-mining", { item("iron-ore", 1) }, {}),
            line("iron-plate", { item("iron-plate", 1) }, { item("iron-ore", 1) }),
            line("iron-plate-recycling",
                { item("iron-ore", 0.25) }, { item("iron-plate", 1) }),
        }
        local constraints = {
            { type = "item", name = "iron-plate", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 4 },
        }

        local full = cp.create_problem("loop-full", constraints, lines)
        local _, vars_full = solve_full(full, "loop")
        local _, vars_reduced = solve_reduced(
            cp.create_problem("loop-red", constraints, lines), "loop")

        assert_same_solution(full, vars_full.x, vars_reduced.x, "loop")
    end,
})

table.insert(cases, {
    name = "determinism: reduce twice yields identical structure and order",
    run = function()
        local lines = {
            line("r1", { item("m2", 1) }, { item("m1", 1) }),
            line("r2", { item("m3", 2) }, { item("m2", 1) }),
            line("r3", { item("m4", 1) }, { item("m3", 1) }),
        }
        local constraints = {
            { type = "item", name = "m4", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 3 },
        }

        local r1, recon1 = sub.reduce(cp.create_problem("det-a", constraints, lines))
        local r2, recon2 = sub.reduce(cp.create_problem("det-b", constraints, lines))

        harness.assert_eq(#recon1.order, #recon2.order, "elimination count")
        for i = 1, #recon1.order do
            harness.assert_eq(recon1.order[i], recon2.order[i],
                "elimination order [" .. i .. "]")
        end
        harness.assert_eq(r1:dump_subject_matrix(), r2:dump_subject_matrix(),
            "reduced subject matrix is bit-identical across runs")
    end,
})

return cases
