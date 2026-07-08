-- Two-stage L2 A/B over one explorer-dumped problem (fanned by run_corpus.ps1).
--
-- Hypothesis under test (guar / PyBlock finding, 2026-07-08): the shipped
-- single-objective L2 shaping lets the recipe tier buy violation units on
-- machine-heavy chains (eps*M vs quad marginal equilibrium), violating the
-- lexicographic problem definition (V >> M). The candidate fix is a two-stage
-- solve: stage 1 measures the violation optimum with a tiny face-regularizer
-- epsilon (2^-20, the target_rescue_epsilon precedent), stage 2 re-solves with
-- the SHIPPED epsilon (tie-break + futile-cycle suppression intact) plus one
-- upper-bound row per violation column locking it at its stage-1 value +
-- margin. Per-variable pinning is sound because the quad is strictly convex in
-- the violation columns, so the optimal violation VECTOR is unique even where
-- the recipe face is degenerate.
--
-- Emits one machine-readable line (all numbers raw, no verdicts):
--   RESULT\t<file>\tA=<state>/<steps> S1=... S2=...\tsumV_A/2, sumV2_A/2,
--   nV_A/2 (violation columns > 1e-6), sumR_A/2 (recipe-flow total, the eps
--   ledger), tgt_A/2 (target elastic+headroom total).
-- sumV/sumV2 are in SLOT units (the violation variables' own scale) -- valid
-- for A-vs-2 comparison on the same problem, not across problems.
--
-- Usage: lua tests/research/probe_l2_twostage.lua <dump.lua>
--        pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_l2_twostage.lua

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local problem_dump = require "tests/problem_dump"
local rl = require "tests/research/research_lib"

local QUAD, FLOOR = 2 ^ 11, 2 ^ -8
local SHIPPED_EPS = 2 ^ -10
local STAGE1_EPS = 2 ^ -20
local LOCK_REL, LOCK_ABS = 1e-3, 1e-6

local path = assert(arg[1], "usage: lua tests/research/probe_l2_twostage.lua <dump.lua>")
local prob = rl.load(path)
local name = path:match("([^/\\]+)%.lua$") or path

local function build(eps)
    local problem = create_problem.create_problem("l2ab", prob.constraints, prob.normalized_lines, nil, {
        reachability_gating = false,
        deficit_seeding = false,
        catalyst_closure = false,
        surplus_sink_gating = false,
        recipe_epsilon = eps,
    })
    create_problem.shape_l2(problem, QUAD, FLOOR)
    return problem
end

---Aggregate a solved (problem, vars) into the reported raw numbers.
local function measure(problem, vars)
    local sumV, sumV2, nV, sumR, tgt = 0, 0, 0, 0, 0
    if not (vars and vars.x) then return sumV, sumV2, nV, sumR, tgt end
    for key, p in pairs(problem.primals) do
        local x = vars.x[key] or 0
        if p.kind == "shortage_source" or p.kind == "surplus_sink" then
            sumV = sumV + x
            sumV2 = sumV2 + x * x
            if x > 1e-6 then nV = nV + 1 end
        elseif p.kind == "recipe" then
            sumR = sumR + x
        elseif p.kind == "elastic" or p.kind == "headroom" then
            tgt = tgt + x
        end
    end
    return sumV, sumV2, nV, sumR, tgt
end

-- A: shipped single-stage L2.
local pA = build(SHIPPED_EPS)
local stateA, stepsA, varsA = problem_dump.solve_dumped(lp, pA, prob.meta)
local sumV_A, sumV2_A, nV_A, sumR_A, tgt_A = measure(pA, varsA)

-- Stage 1: violation measurement at tiny eps.
local p1 = build(STAGE1_EPS)
local state1, steps1, vars1 = problem_dump.solve_dumped(lp, p1, prob.meta)

local state2, steps2 = "skipped", 0
local sumV_2, sumV2_2, nV_2, sumR_2, tgt_2 = -1, -1, -1, -1, -1
if state1 == "finished" and vars1 and vars1.x then
    -- Stage 2: shipped eps + per-violation lock rows at v* + margin.
    local p2 = build(SHIPPED_EPS)
    for key, p in pairs(p1.primals) do
        if p.kind == "shortage_source" or p.kind == "surplus_sink" then
            local v = vars1.x[key] or 0
            local cap = v + math.max(v * LOCK_REL, LOCK_ABS)
            local row = "|stage_lock|" .. key
            p2:add_upper_limit_constraint(row, cap)
            p2:add_subject_term(key, row, 1)
        end
    end
    local vars2
    state2, steps2, vars2 = problem_dump.solve_dumped(lp, p2, prob.meta)
    sumV_2, sumV2_2, nV_2, sumR_2, tgt_2 = measure(p2, vars2)
end

print(string.format(
    "RESULT\t%s\tA=%s/%d\tS1=%s/%d\tS2=%s/%d\tsumV_A=%.8g\tsumV_2=%.8g\tsumV2_A=%.8g\tsumV2_2=%.8g\tnV_A=%d\tnV_2=%d\tsumR_A=%.8g\tsumR_2=%.8g\ttgt_A=%.8g\ttgt_2=%.8g",
    name, tostring(stateA), stepsA, tostring(state1), steps1, tostring(state2), steps2,
    sumV_A, sumV_2, sumV2_A, sumV2_2, nV_A, nV_2, sumR_A, sumR_2, tgt_A, tgt_2))
