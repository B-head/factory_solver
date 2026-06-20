---@diagnostic disable: undefined-global
-- Numerical-stability probe for the SHIPPED L-infinity ("leveled") norm.
--
-- Unlike probe_linf_seeds.lua (which builds a custom min-max to study the peak
-- VALUE across the face), this driver replicates the in-engine dispatch for
-- solution.solver_norm == "linf" byte-for-byte enough to measure whether the
-- IPM actually CONVERGES on every stage across the corpus -- the open question
-- in project_practical_optimum_multivalued ("L2(QP)/L∞ の corpus 非収束率は未測").
--
-- The shipped flow (manage/pre_solve.lua forwerd_solve + target_rescue_step +
-- linf_step), reproduced here on one dumped problem:
--   0. baseline   un-gated plain build, cold solve.
--   1. rescue     if the baseline relaxed a target, run the lexicographic target
--                 rescue (stage1 target-only -> budget -> resolve/restore), each
--                 warm-started from the prior stage (the engine preserves
--                 solution.raw_variables across re-prepares).
--   2. minmax     re-build with the rescued target_budget threaded in + shape_minmax
--                 "minmax" (peak primal t cost 1, one cap row t>=x_v per violation,
--                 everything else dropped to the recipe_epsilon floor). Warm-started
--                 from the rescued baseline. The solve's t is the least peak t_min.
--   3. capped     re-build + shape_minmax "capped" (peak under t_budget = t_min+margin,
--                 L1 elastic_cost back on the violations). Warm-started from minmax.
--
-- Each stage's terminal state is "finished" (converged or QP-stall-accepted) /
-- "unfinished" (hit iterate_limit) / "singular" (Cholesky NaN) / "errored"
-- (solve raised). Only the min-max and capped stages are the L-infinity-specific
-- numerics; the baseline/rescue are the shared L1 path and are reported only to
-- attribute a failure correctly.
--
--   luajit tests/research/probe_linf_ship.lua <dumpfile>
-- Driver contract: single dump arg, prints one "RESULT ..." line, exit 0.
-- Fan out with tests/research/run_corpus.ps1 -Driver tests/research/probe_linf_ship.lua

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local problem_dump = require "tests/problem_dump"
local vk = require "solver/var_key"

-- Shipped tier-1 / L-infinity constants (manage/pre_solve.lua, kept in sync).
local TARGET_RESCUE_TRIGGER = 1e-6
local TARGET_BUDGET_REL, TARGET_BUDGET_ABS = 1e-3, 1e-6
local LINF_BUDGET_REL, LINF_BUDGET_ABS = 1e-3, 1e-6

local BASE_OPTIONS = {
    reachability_gating = false,
    deficit_seeding = false,
    catalyst_closure = false,
    surplus_sink_gating = false,
}

local function opts(extra)
    local o = {}
    for k, v in pairs(BASE_OPTIONS) do o[k] = v end
    if extra then for k, v in pairs(extra) do o[k] = v end end
    return o
end

---Sum |x| over target (elastic / headroom) columns -- observe_price.target_relax.
local function target_relax(primals, x)
    local s = 0
    for key, p in pairs(primals) do
        if p.kind == "elastic" or p.kind == "headroom" then
            s = s + math.abs(x[key] or 0)
        end
    end
    return s
end

---Largest |x| over recipe columns -- the blow-up detector (the QP divergence
---symptom was a recipe column sliding to ~1e15).
local function max_recipe(primals, x)
    local m = 0
    for key, p in pairs(primals) do
        if p.kind == "recipe" then
            local v = math.abs(x[key] or 0)
            if v > m then m = v end
        end
    end
    return m
end

---Drive the IPM to a terminal state from an optional warm seed. Mirrors
---problem_dump.solve_dumped but threads a warm `raw_variables` in (the engine
---preserves solution.raw_variables across the linf stage re-prepares, so each
---stage warm-starts from the previous one's packed result).
---@return string state, integer steps, table? packed
local function solve_stage(problem, meta, warm)
    local state, iteration, vars = "ready", nil, warm
    local steps = 0
    repeat
        local ok, s, it, v = pcall(lp.solve, problem, state, iteration, vars,
            meta.tolerance, meta.iterate_limit)
        if not ok then return "errored", steps, nil end
        state, iteration, vars = s, it, v
        steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > meta.step_cap
    return state, steps, vars
end

local path = arg[1]
if not path then
    io.stderr:write("usage: luajit tests/research/probe_linf_ship.lua <dumpfile>\n")
    os.exit(2)
end

local prob, kind = problem_dump.load_problem(path)
if not prob then
    print("RESULT file=" .. tostring(path) .. " verdict=LOAD_FAIL kind=" .. tostring(kind))
    os.exit(0)
end
local meta = prob.meta
local seedid = (path:match("seed_%d+")) or "?"
local fname = (path:match("[^/\\]+$")) or path

local function build(extra)
    local ok, p = pcall(create_problem.create_problem, "linf",
        prob.constraints, prob.normalized_lines, nil, opts(extra))
    if not ok then return nil end
    return p
end

-- 0. baseline (cold).
local p0 = build(nil)
if not p0 then
    print(string.format("RESULT seed=%s file=%s verdict=BUILD_FAIL", seedid, fname))
    os.exit(0)
end
local st0, _, x0 = solve_stage(p0, meta, nil)
if st0 ~= "finished" then
    print(string.format("RESULT seed=%s file=%s base=%s verdict=BASE_FAIL", seedid, fname, st0))
    os.exit(0)
end

-- 1. lexicographic target rescue (only when the baseline relaxed a target).
local t0 = target_relax(p0.primals, x0.x)
local budget = nil          -- the rescued target_budget threaded into linf builds
local rescued = 0
local warm = x0             -- warm seed carried into the next stage
if t0 > TARGET_RESCUE_TRIGGER then
    rescued = 1
    local p1 = build({ target_only_objective = true })
    local st1, _, x1 = solve_stage(p1, meta, warm)
    if st1 == "finished" then
        local t_min_t = target_relax(p1.primals, x1.x)
        warm = x1
        if t_min_t < t0 - TARGET_RESCUE_TRIGGER then
            budget = t_min_t * (1 + TARGET_BUDGET_REL) + TARGET_BUDGET_ABS
            local pR = build({ target_budget = budget })
            local _, _, xR = solve_stage(pR, meta, warm)
            if xR then warm = xR end
        else
            local pRest = build(nil)
            local _, _, xRest = solve_stage(pRest, meta, warm)
            if xRest then warm = xRest end
        end
    end
end

-- 2. min-max stage: minimize the peak violation. Cold-started (warm = nil):
-- the shipped M.linf_step drops solution.raw_variables when arming this stage,
-- because warm-starting it from the L1-objective baseline diverges (see the fn).
-- `warm` (the rescued baseline) is intentionally NOT passed here.
local _ = warm
local mm_extra = budget and { target_budget = budget } or nil
local p_mm = build(mm_extra)
create_problem.shape_minmax(p_mm, "minmax", nil)
local st_mm, it_mm, x_mm = solve_stage(p_mm, meta, nil)
local peak = (st_mm == "finished" and x_mm) and math.abs(x_mm.x[vk.linf_peak()] or 0) or -1
local mm_maxrec = (st_mm == "finished" and x_mm) and max_recipe(p_mm.primals, x_mm.x) or -1

-- 3. capped stage: minimize total violation under t <= t_budget.
local st_cap, it_cap, cap_peak, cap_maxrec = "n/a", 0, -1, -1
if st_mm == "finished" then
    local t_budget = peak * (1 + LINF_BUDGET_REL) + LINF_BUDGET_ABS
    local p_cap = build(mm_extra)
    create_problem.shape_minmax(p_cap, "capped", t_budget)
    -- Cold-started too (warm = nil): same rationale -- the capped build re-costs
    -- back to the L1 elastic_cost, a different objective than the min-max it follows.
    local s_cap, i_cap, x_cap = solve_stage(p_cap, meta, nil)
    st_cap, it_cap = s_cap, i_cap
    if s_cap == "finished" and x_cap then
        cap_peak = math.abs(x_cap.x[vk.linf_peak()] or 0)
        cap_maxrec = max_recipe(p_cap.primals, x_cap.x)
    end
end

local verdict
if st_mm ~= "finished" then
    verdict = "MM_FAIL"
elseif st_cap ~= "finished" then
    verdict = "CAP_FAIL"
else
    verdict = "OK"
end

print(string.format(
    "RESULT seed=%s file=%s base=%s resc=%d mm=%s mm_it=%d peak=%.6g mm_maxrec=%.6g "
    .. "cap=%s cap_it=%d cap_peak=%.6g cap_maxrec=%.6g verdict=%s",
    seedid, fname, st0, rescued, st_mm, it_mm, peak, mm_maxrec,
    st_cap, it_cap, cap_peak, cap_maxrec, verdict))
os.exit(0)
