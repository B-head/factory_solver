-- Regression suite for solver/substitution.lua, the proportional row-reduction
-- presolve (singleton / doubleton variable elimination).
--
-- Two layers of coverage:
--   1. Gate unit tests on hand-built Problems (problem_generator directly):
--      fold only when limit == 0, exactly two terms, both recipe/bridge, and
--      opposite-signed coefficients. Anything else must be left untouched.
--   2. End-to-end identity tests on real create_problem outputs: solving the
--      reduced problem and unfolding must reproduce the full-problem solution
--      for every variable, while actually shrinking the row count.

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

---Count entries in a (possibly sparse) key->value table.
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
    name = "fold: opposite-sign two-recipe equality row at limit 0 is eliminated",
    run = function()
        local p = pg.new("fold")
        p:add_objective("recipe/a", 1, true, "recipe")
        p:add_objective("recipe/b", 1, true, "recipe")
        p:add_equivalence_constraint("|limit|m", 0)
        p:add_subject_term("recipe/a", "|limit|m", 2)  -- a produces 2 m
        p:add_subject_term("recipe/b", "|limit|m", -1) -- b consumes 1 m

        local reduced, recon = sub.reduce(p)

        harness.assert_eq(count(recon.eliminated), 1, "one variable eliminated")
        -- rep = lexicographically smaller key = recipe/a; elim = recipe/b.
        local info = recon.eliminated["recipe/b"]
        assert(info, "recipe/b should be eliminated")
        harness.assert_eq(info.rep, "recipe/a", "representative")
        -- b = k*a with 2a - b = 0 => b = 2a => k = 2.
        harness.assert_near(info.k, 2, 1e-12, "k = -a_rep/a_elim = -2/-1")
        harness.assert_eq(reduced.dual_length, 0, "the only row was removed")
        harness.assert_eq(reduced.primal_length, 1, "elim column removed")
        -- Cost transfers: c_rep' = 1 + k*1 = 3.
        harness.assert_near(reduced.primals["recipe/a"].cost, 3, 1e-12, "cost transfer")
    end,
})

table.insert(cases, {
    name = "no fold: same-sign coefficients (k would be negative)",
    run = function()
        local p = pg.new("samesign")
        p:add_objective("recipe/a", 1, true, "recipe")
        p:add_objective("recipe/b", 1, true, "recipe")
        p:add_equivalence_constraint("|limit|m", 0)
        p:add_subject_term("recipe/a", "|limit|m", 1)
        p:add_subject_term("recipe/b", "|limit|m", 1)

        local _, recon = sub.reduce(p)
        harness.assert_eq(count(recon.eliminated), 0, "same-sign row not folded")
    end,
})

table.insert(cases, {
    name = "no fold: non-zero limit row",
    run = function()
        local p = pg.new("limit")
        p:add_objective("recipe/a", 1, true, "recipe")
        p:add_objective("recipe/b", 1, true, "recipe")
        p:add_equivalence_constraint("|limit|m", 5) -- limit != 0
        p:add_subject_term("recipe/a", "|limit|m", 1)
        p:add_subject_term("recipe/b", "|limit|m", -1)

        local _, recon = sub.reduce(p)
        harness.assert_eq(count(recon.eliminated), 0, "non-zero limit row not folded")
    end,
})

table.insert(cases, {
    name = "no fold: row containing an escape variable",
    run = function()
        local p = pg.new("escape")
        p:add_objective("recipe/a", 1, true, "recipe")
        p:add_objective("|initial_source|m", 1, false, "initial_source")
        p:add_equivalence_constraint("|limit|m", 0)
        p:add_subject_term("recipe/a", "|limit|m", -1)
        p:add_subject_term("|initial_source|m", "|limit|m", 1)

        local _, recon = sub.reduce(p)
        harness.assert_eq(count(recon.eliminated), 0, "escape-bearing row not folded")
    end,
})

table.insert(cases, {
    name = "no fold: three-term row",
    run = function()
        local p = pg.new("triple")
        p:add_objective("recipe/a", 1, true, "recipe")
        p:add_objective("recipe/b", 1, true, "recipe")
        p:add_objective("recipe/c", 1, true, "recipe")
        p:add_equivalence_constraint("|limit|m", 0)
        p:add_subject_term("recipe/a", "|limit|m", 1)
        p:add_subject_term("recipe/b", "|limit|m", -1)
        p:add_subject_term("recipe/c", "|limit|m", -1)

        local _, recon = sub.reduce(p)
        harness.assert_eq(count(recon.eliminated), 0, "three-term row not folded")
    end,
})

table.insert(cases, {
    name = "fixpoint: folding one row exposes the next (chain collapse)",
    run = function()
        -- a -> b (row m1), b -> c (row m2). Folding m1 rewrites m2 in terms of
        -- the survivor, which then folds too. Both b and c get eliminated.
        local p = pg.new("chain")
        p:add_objective("recipe/a", 1, true, "recipe")
        p:add_objective("recipe/b", 1, true, "recipe")
        p:add_objective("recipe/c", 1, true, "recipe")
        p:add_equivalence_constraint("|limit|m1", 0)
        p:add_equivalence_constraint("|limit|m2", 0)
        p:add_subject_term("recipe/a", "|limit|m1", 1)
        p:add_subject_term("recipe/b", "|limit|m1", -1)
        p:add_subject_term("recipe/b", "|limit|m2", 1)
        p:add_subject_term("recipe/c", "|limit|m2", -1)

        local reduced, recon = sub.reduce(p)
        harness.assert_eq(count(recon.eliminated), 2, "two variables eliminated")
        harness.assert_eq(reduced.dual_length, 0, "both rows removed")
        harness.assert_eq(reduced.primal_length, 1, "only the root survives")
    end,
})

-- ---------------------------------------------------------------------------
-- Layer 2: end-to-end identity on real create_problem outputs.
-- ---------------------------------------------------------------------------

---Solve `problem` cold to completion, asserting it finishes.
local function solve_full(problem, tag, limit)
    local state, vars = harness.solve_to_completion(lp, problem,
        { tolerance = 1e-6, iterate_limit = limit or 400 })
    harness.assert_eq(state, "finished", tag .. " state")
    assert(vars, tag .. ": expected vars")
    return state, vars
end

---Reduce `problem`, solve the reduced LP cold, then unfold into full space.
local function solve_reduced(problem, tag, limit)
    local reduced, recon = sub.reduce(problem)
    local state, vars = harness.solve_to_completion(lp, reduced,
        { tolerance = 1e-6, iterate_limit = limit or 400 })
    harness.assert_eq(state, "finished", tag .. " reduced state")
    assert(vars, tag .. ": expected reduced vars")
    return state, sub.unfold(vars, recon), reduced
end

---Assert the two solutions agree on every full primal key. A small activity
---floor skips the recipe_epsilon "dust" on recipes driven toward zero, whose
---residual (~tolerance/epsilon) is solver-path dependent and not part of the
---optimum (see the activity_floor note in lp_scale_invariance.lua).
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

-- NOTE on real create_problem chains: every internal material balance row
-- carries a |surplus_sink| (and terminals a |final_sink|, raws an
-- |initial_source|), so a plain producer->consumer chain is NOT a pure
-- doubleton and is left unfolded. These identity cases therefore mainly assert
-- the *safety* property -- reduce + unfold is a faithful no-op (or exact fold)
-- whatever the topology -- rather than a row-count win. The synthetic gate
-- tests above prove the folding mechanics; bridge-target rows (which get no
-- surplus_sink) are where folding actually fires on real problems.

table.insert(cases, {
    name = "identity: linear chain m1->m2->m3 pinned at m3==5 stays exact",
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

        -- m2 is a clean pass-through intermediate, so create_problem now emits
        -- it as an equality (no surplus_sink) and substitution folds the row out:
        -- the reduced problem is strictly smaller.
        harness.assert_true(reduced.dual_length < full.dual_length,
            string.format("reduced rows %d < full rows %d",
                reduced.dual_length, full.dual_length))
        assert_same_solution(full, vars_full.x, vars_reduced.x, "chain")
        -- Sanity: both recipes run at 5/s in the unfolded solution.
        harness.assert_near(vars_reduced.x["recipe/r1/normal"], 5, 0.1, "r1 rate")
        harness.assert_near(vars_reduced.x["recipe/r2/normal"], 5, 0.1, "r2 rate")
    end,
})

table.insert(cases, {
    name = "identity: 5-link chain stays exact under reduce+unfold",
    run = function()
        local lines = {
            line("r1", { item("m2", 1) }, { item("m1", 1) }),
            line("r2", { item("m3", 2) }, { item("m2", 1) }),
            line("r3", { item("m4", 1) }, { item("m3", 1) }),
            line("r4", { item("m5", 3) }, { item("m4", 1) }),
            line("r5", { item("m6", 1) }, { item("m5", 1) }),
        }
        local constraints = {
            { type = "item", name = "m6", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 12 },
        }

        local full = cp.create_problem("chain5-full", constraints, lines)
        local _, vars_full = solve_full(full, "chain5", 600)
        local _, vars_reduced, reduced = solve_reduced(
            cp.create_problem("chain5-red", constraints, lines), "chain5", 600)

        -- Interior materials m2..m5 are clean pass-through intermediates -> they
        -- fold, removing several rows.
        harness.assert_true(reduced.dual_length <= full.dual_length - 3,
            string.format("expected >=3 rows folded, full=%d reduced=%d",
                full.dual_length, reduced.dual_length))
        assert_same_solution(full, vars_full.x, vars_reduced.x, "chain5")
    end,
})

table.insert(cases, {
    name = "identity: recycling loop (escape/loop rows preserved) stays exact",
    run = function()
        -- Mirrors the 2-tier shape from lp_scale_invariance: a self-loop with a
        -- bootstrap miner. Most rows here are NOT pure doubletons (recyclers
        -- emit cascades, the loop material has multiple producers/consumers), so
        -- this exercises that folding the few foldable rows still reproduces the
        -- full solution exactly.
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
        -- The matrix dump is index-ordered, so identical structure => identical
        -- string. This pins the stable-sort determinism the LP relies on.
        harness.assert_eq(r1:dump_subject_matrix(), r2:dump_subject_matrix(),
            "reduced subject matrix is bit-identical across runs")
    end,
})

return cases
