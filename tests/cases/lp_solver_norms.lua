-- The per-solution shipping norms (manage/pre_solve.lua dispatch) reduce to
-- problem shaping over the same un-gated baseline, so the headless suite pins
-- the shaping that create_problem / shape_minmax apply -- the in-game stage
-- machinery (M.linf_step) is smoke-tested. Three norms shape the build:
--   "l1"   the plain ungated baseline (linear elastic_cost) -- pure LP.
--   "l2"   create_problem's violation_quad: the violation elastics
--          (|shortage_source| + |surplus_sink|) go to cost 0 + a diagonal
--          quadratic, so the optimum minimizes the L2 norm of the imbalance.
--   "linf" create_problem.shape_minmax: a peak primal t with one cap row per
--          violation (t >= each), minimized (stage "minmax"), then capped
--          (stage "capped").
-- ("legacy" is the pre-existing hard-gate + two-pass path, pinned elsewhere.)

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"
local pg = require "solver/problem_generator"
local vk = require "solver/var_key"

local function it(name, amount)
    return { type = "item", name = name, quality = "normal", amount_per_second = amount }
end
local function line(recipe, products, ingredients)
    return {
        recipe_typed_name = { type = "recipe", name = recipe, quality = "normal" },
        products = products, ingredients = ingredients,
        power_per_second = 0, pollution_per_second = 0,
    }
end

-- The target-rescue collapse loop: meeting 1 T forces ~3000 units of surplus
-- through |surplus_sink| (see tests/cases/lp_target_rescue.lua). A target_budget
-- keeps the target met so the violation actually flows, which is what the norms
-- act on.
local function surplus_fixture()
    local lines = {
        line("r_t", { it("T", 1), it("J", 3000) }, { it("Jin", 1) }),
        line("r_x", { it("Jin", 1) }, { it("J", 1) }),
        line("r_b", { it("Jin", 0.001) }, {}),
    }
    local constraints = {
        { type = "item", name = "T", quality = "normal",
            limit_type = "equal", limit_amount_per_second = 1 },
    }
    return lines, constraints
end

local function solve(problem)
    return harness.solve_to_completion(lp, problem, { tolerance = 1e-7, iterate_limit = 600 })
end

local VIOLATION = { shortage_source = true, surplus_sink = true }

---Max |x| over the violation elastic columns, and their summed |x|.
local function violation_stats(problem, vars)
    local maxv, sumv = 0, 0
    for key, p in pairs(problem.primals) do
        if VIOLATION[p.kind] then
            local v = math.abs(vars.x[key] or 0)
            sumv = sumv + v
            if v > maxv then maxv = v end
        end
    end
    return maxv, sumv
end

local cases = {}

--------------------------------------------------------------------------------
-- L2: the QP least-norm the "balanced" norm relies on.
--------------------------------------------------------------------------------

table.insert(cases, {
    name = "L2 (QP) splits a fixed total evenly across two equal channels",
    run = function()
        -- Minimize a^2 + b^2 (= sum of 1/2 * 2 * x^2) subject to a + b = 2.
        -- The L2 optimum is the unique even split a = b = 1; a linear (L1) cost
        -- would be indifferent across the whole a+b=2 face.
        local problem = pg.new("l2-least-norm")
        problem:add_objective("a", 0, true)
        problem:add_objective("b", 0, true)
        problem:set_quad("a", 2)
        problem:set_quad("b", 2)
        problem:add_equivalence_constraint("c", 2)
        problem:add_subject_term("a", "c", 1)
        problem:add_subject_term("b", "c", 1)
        harness.assert_true(problem.has_quad, "set_quad flips has_quad (QP path)")

        local state, vars = solve(problem)
        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables")
        harness.assert_near(vars.x.a, 1, 1e-3, "a (even split)")
        harness.assert_near(vars.x.b, 1, 1e-3, "b (even split)")
    end,
})

table.insert(cases, {
    name = "shape_l2 zeroes the violation linear cost + adds the quad, and frees the ports",
    run = function()
        local lines, constraints = surplus_fixture()
        -- Baseline (L1): violations carry the flat linear elastic_cost, no quad;
        -- the legitimate ports carry source_cost / 0.
        local l1 = cp.create_problem("norm-l1", constraints, lines, nil,
            { reachability_gating = false })
        harness.assert_true(not l1.has_quad, "L1 baseline stays a pure LP")
        for _, p in pairs(l1.primals) do
            if VIOLATION[p.kind] then
                harness.assert_near(p.cost, cp.elastic_cost, 1e-9, "L1 violation priced at elastic_cost")
            end
        end
        -- L2: shape_l2 drops the violation linear cost to 0 and adds the quad
        -- (so the QP minimizes the L2 norm of the imbalance), and frees the ports
        -- (so building beats the quadratic import -- the cheat guard).
        local l2 = cp.create_problem("norm-l2", constraints, lines, nil,
            { reachability_gating = false })
        cp.shape_l2(l2, 2)
        harness.assert_true(l2.has_quad, "shape_l2 flips has_quad")
        local seen_surplus = false
        for _, p in pairs(l2.primals) do
            if VIOLATION[p.kind] then
                harness.assert_near(p.cost, 0, 1e-12, "L2 violation linear cost zeroed")
                harness.assert_near(p.quad or 0, 2, 1e-12, "L2 violation quad set")
                if p.kind == "surplus_sink" then seen_surplus = true end
            elseif p.kind == "initial_source" or p.kind == "final_sink" then
                harness.assert_near(p.cost, 0, 1e-12, "L2 frees the legitimate ports")
            end
        end
        harness.assert_true(seen_surplus, "the dump side got the quad too")
    end,
})

table.insert(cases, {
    name = "L2 builds a buildable chain instead of importing it (the cheat guard)",
    run = function()
        -- raw -> ore -> widget, raw a legitimate initial ingredient (no producer).
        -- The whole chain should be BUILT; ore is the intermediate L2 could cheat
        -- by importing. With the ports left at source_cost (the first bug) the
        -- quadratic import undercut the build and L2 leaked imports; freeing the
        -- ports + a tiny recipe tier makes L2 build it like L1.
        local lines = {
            line("mk_widget", { it("widget", 1) }, { it("ore", 1) }),
            line("mk_ore", { it("ore", 1) }, { it("raw", 1) }),
        }
        local constraints = {
            { type = "item", name = "widget", quality = "normal",
                limit_type = "equal", limit_amount_per_second = 1 },
        }
        -- The L2 build: ungated, tiny recipe tier (the leak-killer), then shape_l2.
        local problem = cp.create_problem("l2-buildable", constraints, lines, nil,
            { reachability_gating = false, recipe_epsilon = 2 ^ -20 })
        cp.shape_l2(problem, 2)
        local state, vars = solve(problem)
        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables")
        -- No shortage import should flow: ore is built, not imported.
        local shortage = 0
        for key, p in pairs(problem.primals) do
            if p.kind == "shortage_source" then shortage = shortage + math.abs(vars.x[key] or 0) end
        end
        harness.assert_near(shortage, 0, 1e-3, "L2 builds the chain, imports nothing buildable")
        harness.assert_near(vars.x["recipe/mk_widget/normal"], 1, 1e-3, "widget recipe runs")
        harness.assert_near(vars.x["recipe/mk_ore/normal"], 1, 1e-3, "ore recipe runs in full")
    end,
})

table.insert(cases, {
    name = "L2 (QP) warm-started from a prior solution still converges (no divergence)",
    run = function()
        -- Regression: switching a solution's norm to "l2" (or editing it under
        -- l2) re-solves the QP WARM-STARTED from the previous packed solution
        -- (save.update_solver_norm keeps solution.raw_variables). The QP Newton
        -- path destabilised from that external warm point -- it nearly converged,
        -- then a free recipe column slid to ~1e15 and the solve ran to the iterate
        -- limit, reporting a fabricated all-zero result (observed in-game on the
        -- "Begining" Fulgora-starter problem after a legacy->l2 switch). The fix
        -- (linear_programming.solve: the QP discards the iteration-1 external
        -- warm-start and cold-starts via mehrotra) must make the warm re-solve
        -- converge to the SAME optimum as the cold solve. The BIG-M target/elastic
        -- cost scale of surplus_fixture is what drove the warm-start clamp off the
        -- QP central path, so it is the reproduction vehicle here.
        local lines, constraints = surplus_fixture()
        local function build()
            local p = cp.create_problem("l2-warm", constraints, lines, nil,
                { reachability_gating = false, recipe_epsilon = 2 ^ -20, target_budget = 1e-6 })
            cp.shape_l2(p, 2)
            return p
        end

        local cold = build()
        local cs, cv = solve(cold)
        harness.assert_eq(cs, "finished", "cold solve finishes")
        assert(cv, "expected packed variables (cold)")
        local cold_max = violation_stats(cold, cv)

        -- Warm-start the SAME problem from the cold optimum (the norm-switch flow).
        local warm = build()
        local ws, wv = harness.solve_to_completion(lp, warm,
            { tolerance = 1e-7, iterate_limit = 600 }, cv)
        harness.assert_eq(ws, "finished", "warm solve finishes (did not diverge)")
        assert(wv, "expected packed variables (warm)")
        -- The fabricated-divergence symptom was x exploding to ~1e15; assert the
        -- warm solve stays at the cold scale, not blown up.
        local warm_max = violation_stats(warm, wv)
        harness.assert_near(warm_max, cold_max, math.max(1e-2, 1e-2 * cold_max),
            "warm violation peak matches the cold solve (no blow-up)")
        for key, p in pairs(warm.primals) do
            if p.kind == "recipe" then
                harness.assert_true(math.abs(wv.x[key] or 0) < 1e6,
                    "no recipe column ran away to ~1e15 (" .. key .. ")")
            end
        end
    end,
})

--------------------------------------------------------------------------------
-- L-infinity: the min-max shaping.
--------------------------------------------------------------------------------

table.insert(cases, {
    name = "shape_minmax 'minmax' pulls the peak primal up to the largest violation",
    run = function()
        local lines, constraints = surplus_fixture()
        -- Ungated baseline with the target locked so the violation flows.
        local problem = cp.create_problem("norm-linf-minmax", constraints, lines, nil,
            { reachability_gating = false, target_budget = 1e-6 })
        cp.shape_minmax(problem, "minmax", nil)
        harness.assert_true(problem.primals[vk.linf_peak()] ~= nil, "peak primal added")

        local state, vars = solve(problem)
        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables")
        local peak = math.abs(vars.x[vk.linf_peak()] or 0)
        local maxv = violation_stats(problem, vars)
        -- The peak caps every violation (t >= each) and is minimized to the max.
        harness.assert_true(peak >= maxv - 1e-3, "peak bounds the largest violation")
        harness.assert_near(peak, maxv, math.max(1e-3, 1e-2 * maxv),
            "peak settles at the largest violation, not above")
        -- This fixture forces a ~3000-unit dump, so the peak is that order.
        harness.assert_true(peak > 1000, "the forced dump shows up as the peak")
    end,
})

table.insert(cases, {
    name = "shape_minmax 'capped' holds the peak under the locked budget",
    run = function()
        local lines, constraints = surplus_fixture()
        -- First measure the least peak.
        local mm = cp.create_problem("norm-linf-mm2", constraints, lines, nil,
            { reachability_gating = false, target_budget = 1e-6 })
        cp.shape_minmax(mm, "minmax", nil)
        local s0, v0 = solve(mm)
        harness.assert_eq(s0, "finished", "minmax solver_state")
        assert(v0, "expected packed variables")
        local t_min = math.abs(v0.x[vk.linf_peak()] or 0)

        -- Then cap at t_min (plus the IPM margin) and re-solve: feasible, and the
        -- peak stays under the cap.
        local t_cap = t_min * (1 + 1e-3) + 1e-6
        local capped = cp.create_problem("norm-linf-capped", constraints, lines, nil,
            { reachability_gating = false, target_budget = 1e-6 })
        cp.shape_minmax(capped, "capped", t_cap)
        local s1, v1 = solve(capped)
        harness.assert_eq(s1, "finished", "capped solver_state")
        assert(v1, "expected packed variables")
        local peak = math.abs(v1.x[vk.linf_peak()] or 0)
        harness.assert_true(peak <= t_cap + math.max(1e-3, 1e-2 * t_cap),
            "peak held under the locked cap")
        -- The target is still met (the cap did not collapse it).
        local elastic = 0
        for key, p in pairs(capped.primals) do
            if p.kind == "elastic" or p.kind == "headroom" then
                elastic = elastic + math.abs(v1.x[key] or 0)
            end
        end
        harness.assert_true(elastic <= 1e-2, "target stays met under the cap")
    end,
})

return cases
