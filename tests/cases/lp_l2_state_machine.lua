-- The L2 two-stage violation-lock STATE MACHINE (manage/pre_solve.lua
-- forwerd_solve + target_rescue_step + l2_lock_step), driven end-to-end
-- headless. The lock shaping itself (plan_violation_locks /
-- apply_violation_locks) is exercised through the pump here; what this file
-- pins is the tick-pump orchestration -- the measurement -> locked rebuild,
-- the ll_restart preserve threading (the linf-livelock class), and the
-- eps*M-vs-quad regression the two stages exist for.
--
-- Regression (2026-07-08, the PyBlock guar report): the single weighted L2
-- objective trades the recipe tier against the violation quad at the finite
-- rate eps*M, so a chain needing ~1e5 machines per unit of target (guar-mk02:
-- 9.8e-6/craft) imported ~5% of an Exact target through |shortage_source|
-- instead of building the chain -- violating the problem definition's V >> M
-- lexicography. The two-stage solve measures the violation optimum at a tiny
-- face-regularizer epsilon, then re-solves at ship costs with each violation
-- group capped at that optimum. Corpus A/B in
-- tests/research/probe_l2_twostage.lua (1678/1678 converged).
--
-- forwerd_solve is headless-safe except for the production-line normalizer
-- (prototype reads), so each case stubs pre_solve.to_normalized_production_lines
-- to hand back the already-normalized fixture lines -- the same shape the
-- create_problem-level cases feed directly (mirrors lp_linf_state_machine.lua).

local harness = require "tests/harness"
local pre_solve = require "manage/pre_solve"

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

---Drive forwerd_solve to a terminal state exactly as the on_tick pump does,
---with the normalizer stubbed to return `lines` as-is. Returns the settled
---solution plus the number of "ready" rebuilds consumed (the livelock
---detector: the l2 pipeline is at most measurement + 3 rescue solves + the
---locked stage + the compress re-solve).
---@return table solution, integer rebuilds
local function drive(norm, lines, constraints, max_steps)
    max_steps = max_steps or 5000
    local solution = {
        name = "l2-pump",
        constraints = constraints,
        production_lines = {},
        solver_state = "ready",
        solver_norm = norm,
    }
    local force_data = { research_bonuses = nil }

    local saved = pre_solve.to_normalized_production_lines
    pre_solve.to_normalized_production_lines = function() return lines end
    local rebuilds, steps = 0, 0
    local ok, err = pcall(function()
        while solution.solver_state == "ready" or solution.solver_state == "calculating" do
            if solution.solver_state == "ready" then rebuilds = rebuilds + 1 end
            pre_solve.forwerd_solve(force_data, solution)
            steps = steps + 1
            assert(steps <= max_steps,
                string.format("l2 pump did not settle after %d steps / %d rebuilds (livelock)",
                    steps, rebuilds))
        end
    end)
    pre_solve.to_normalized_production_lines = saved
    if not ok then error(err, 0) end
    return solution, rebuilds
end

local function sum_kind(problem, vars, kind)
    local total = 0
    for key, p in pairs(problem.primals) do
        if p.kind == kind then total = total + math.abs(vars.x[key] or 0) end
    end
    return total
end

-- The machine-heavy fixture (the guar shape, minimized): mk_T needs 1e5
-- crafts per unit of T, so at the ship epsilon the chain's marginal cost is
-- eps * 1e5 ~ 0.1 per unit -- far above the violation quad's marginal near 0.
-- A single-stage L2 build rationally imports ~0.05/s of the 1 T/s target
-- (machines buying violation); the two-stage pump must not.
local heavy_lines = {
    line("mk_T", { it("T", 1e-5) }, { it("raw", 1) }),
    line("eat_T", { it("W", 1) }, { it("T", 1) }),
}
local heavy_constraints = {
    { type = "item", name = "T", quality = "normal",
        limit_type = "equal", limit_amount_per_second = 1 },
}

local cases = {}

table.insert(cases, {
    name = "l2_baseline pump: machines can no longer buy target-item imports",
    run = function()
        local solution, rebuilds = drive("l2_baseline", heavy_lines, heavy_constraints)
        harness.assert_eq(solution.solver_state, "finished", "solver_state")
        harness.assert_eq(solution.l2_lock and solution.l2_lock.phase, "done", "lock settled")
        -- Exactly the measurement + the locked stage; no rescue (the target is
        -- met either way, so t0 = 0) and no fallback.
        harness.assert_true(rebuilds <= 2,
            "pipeline is measurement + locked stage, got " .. rebuilds .. " rebuilds")
        assert(solution.raw_variables, "expected packed variables")
        local x = solution.raw_variables.x
        -- The chain runs in full; the import stays at the stage-1 optimum
        -- (~5e-5, the floor-vs-eps crossover) instead of the single-stage
        -- equilibrium (~0.05 = eps * 1e5 / quad, a 1000x difference).
        harness.assert_near((x["recipe/mk_T/normal"] or 0) * 1e-5, 1, 1e-2,
            "the machine-heavy chain carries the target")
        harness.assert_true((x["|shortage_source|item/T/normal"] or 0) <= 1e-3,
            "target-item import stays at the violation optimum, got "
            .. tostring(x["|shortage_source|item/T/normal"]))
        -- The caps survive on the settled sentinel (the l2 fold rebuild needs
        -- them; l2_baseline just carries them).
        harness.assert_true(solution.l2_lock.caps ~= nil, "caps kept on the done sentinel")
    end,
})

table.insert(cases, {
    name = "l2 pump: lock stage settles before the mode compression",
    run = function()
        local solution, rebuilds = drive("l2", heavy_lines, heavy_constraints)
        harness.assert_eq(solution.solver_state, "finished", "solver_state")
        harness.assert_eq(solution.l2_lock and solution.l2_lock.phase, "done", "lock settled")
        harness.assert_eq(solution.l2_compress and solution.l2_compress.phase, "done",
            "compression settled after the lock")
        -- Nothing folds on this fixture (no multi-member violation group), so
        -- the compression plans "done" with no extra solve.
        harness.assert_true(rebuilds <= 3,
            "measurement + locked (+ no compress solve), got " .. rebuilds .. " rebuilds")
        assert(solution.raw_variables, "expected packed variables")
        harness.assert_true(
            (solution.raw_variables.x["|shortage_source|item/T/normal"] or 0) <= 1e-3,
            "locked import survives the compression step")
    end,
})

table.insert(cases, {
    name = "l2_baseline pump on a rescue-firing problem: budget rides both stages",
    run = function()
        -- lp_target_rescue's collapse fixture: meeting 1 T/s forces ~3000
        -- units/s of penalised surplus, so the measurement build abandons the
        -- target and the rescue fires -- BEFORE the lock stages. ll_restart
        -- must preserve the settled rescue or stage 1 re-arms mid-pipeline
        -- (the linf livelock class).
        local lines = {
            line("r_t", { it("T", 1), it("J", 3000) }, { it("Jin", 1) }),
            line("r_x", { it("Jin", 1) }, { it("J", 1) }),
            line("r_b", { it("Jin", 0.001) }, {}),
        }
        local constraints = {
            { type = "item", name = "T", quality = "normal",
                limit_type = "equal", limit_amount_per_second = 1 },
        }
        local solution, rebuilds = drive("l2_baseline", lines, constraints)
        harness.assert_eq(solution.solver_state, "finished", "solver_state")
        harness.assert_eq(solution.l2_lock and solution.l2_lock.phase, "done", "lock settled")
        harness.assert_true(rebuilds <= 6,
            "measurement + rescue (2) + locked stage, got " .. rebuilds .. " rebuilds")
        assert(solution.raw_variables, "expected packed variables")
        -- The locked stage carried the rescued budget: the target is met and
        -- the forced surplus is actually paid, not dodged by re-collapsing.
        harness.assert_near(solution.raw_variables.x["recipe/r_t/normal"] or 0, 1, 1e-2,
            "target recipe runs at the requested rate in the locked answer")
        harness.assert_true(
            sum_kind(solution.problem, solution.raw_variables, "elastic") <= 2e-6,
            "target relaxation stays under the rescued budget")
        harness.assert_eq(solution.target_rescue and solution.target_rescue.phase, "done",
            "rescue sentinel survived the lock rebuilds")
    end,
})

return cases
