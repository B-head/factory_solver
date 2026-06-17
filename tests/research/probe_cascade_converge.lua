---@diagnostic disable: undefined-global
-- Convergence-only driver for the SHIPPED cascade (solver/cascade.lua): drives
-- the state machine to settlement over a corpus and reports ONLY the terminal
-- state, solve count, and which divergence FALLBACK fired (deletion final /
-- staged relay). No reference solve -- this isolates the cascade's own
-- convergence so a budget-floor change (M.BUDGET_ABS) can be A/B'd without the
-- 45-min reference recompute the refcache pays after a create_problem edit.
--
-- A baseline + budget-row finals can diverge when a stage optimum is ~0 (the
-- budget row pins live variables against Sum <= ABS, a face the IPM interior
-- cannot approach); the cascade then escalates to the deletion final or the
-- staged relay. So "ship_state=finished with relay=1" is a fallback rescue, not
-- a clean direct convergence -- both columns matter when sizing BUDGET_ABS.
--
-- Single-shot: `<lua> probe_cascade_converge.lua <dump>` -> one row.
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_cascade_converge.lua -Collect '^seed=' -Out <tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local problem_dump = require "tests/problem_dump"
local observe_price = require "solver/observe_price"
local cascade = require "solver/cascade"

local TOL, ITER = 1e-7, 800
-- The target rescue's own budget floor (manage/pre_solve.lua target_budget_abs);
-- left at the shipped value so this probe measures only the cascade's BUDGET_ABS.
local RESCUE_TRIGGER = 1e-6
local TR_REL, TR_ABS = 1e-3, 1e-6

local function solve(p, warm) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }, warm) end

local function build_ship(constraints, lines, target_budget, target_only)
    local opts = { reachability_gating = false, target_budget = target_budget, target_only_objective = target_only }
    local ok, p = pcall(create_problem.create_problem, "ship", constraints, lines, nil, opts)
    if not ok then return nil end
    return p
end

local function build_cascade(constraints, lines, build)
    local ok, p = pcall(create_problem.create_problem, "cascade", constraints, lines, nil, cascade.build_options(build))
    if not ok then return nil end
    cascade.shape_problem(p, build)
    return p
end

-- The shipped lexicographic target rescue (mirrors manage/pre_solve.lua's step,
-- target_relax now counting headroom). Returns prob, x, s, locked budget.
local function rescue_target(constraints, lines, prob, x0, s0)
    local t0 = observe_price.target_relax(prob.primals, x0)
    if t0 <= RESCUE_TRIGGER then return prob, x0, s0, nil end
    local p1 = build_ship(constraints, lines, nil, true)
    if not p1 then return prob, x0, s0, nil end
    local s1, v1 = solve(p1)
    if s1 ~= "finished" then return prob, x0, s0, nil end
    local tmin = observe_price.target_relax(p1.primals, v1.x)
    if tmin >= t0 - RESCUE_TRIGGER then return prob, x0, s0, nil end
    local limit = tmin * (1 + TR_REL) + TR_ABS
    local p2 = build_ship(constraints, lines, limit)
    if not p2 then return prob, x0, s0, nil end
    local s2, v2 = solve(p2)
    if s2 ~= "finished" or not v2.x then return prob, x0, s0, nil end
    return p2, v2.x, v2.s, limit
end

-- Drive the cascade to settlement, production-faithful warm policy (cold the
-- classification builds, warm the heavy stage/final/polish off the preceding
-- solve) -- exactly manage/pre_solve.lua's pump.
local function solve_via_cascade(constraints, lines)
    local prob = build_ship(constraints, lines, nil)
    if not prob then return "build-error", 0, nil end
    local s, v = solve(prob)
    if s ~= "finished" then return s, 1, nil end
    local solves = 1

    local p, x, sl, rescue_budget = rescue_target(constraints, lines, prob, v.x, v.s)
    local raw = { x = x, s = sl }
    local cc = cascade.begin(p, raw, lines, rescue_budget)
    local prev_any = raw
    local guard = 0
    while cc.build do
        guard = guard + 1
        if guard > 2000 then return "cascade-stuck", solves, cc end
        local b = cc.build
        local bp = build_cascade(constraints, lines, b)
        if not bp then
            cascade.advance(cc, p, nil, "unfeasible")
        else
            local seed = (not cascade.is_cold(b)) and prev_any or nil
            local bs, bv = solve(bp, seed)
            solves = solves + 1
            if bs == "finished" and bv then prev_any = bv end
            cascade.advance(cc, bp, bv, bs)
            if cc.phase == "restore" then return "finished", solves, cc end
        end
    end
    return "finished", solves, cc
end

local path = assert(arg[1], "usage: lua probe_cascade_converge.lua <dump>")
local name = path:gsub("[\\/]+$", ""):match("([^\\/]+)%.lua$") or path
local prob = problem_dump.load_problem(path)
if not prob then print(string.format("seed=%s\tLOAD-ERROR", name)); return end

local ok, st, solves, cc = pcall(solve_via_cascade, prob.constraints, prob.normalized_lines)
if not ok then
    print(string.format("seed=%s\tstate=PCALL-ERR\tsolves=0\trelay=0\tdeleted=0\terr=%s", name, tostring(st)))
    return
end
local relay = (cc and cc.relay) and 1 or 0
local deleted = (cc and cc.vp_deleted) or 0
print(string.format("seed=%s\tstate=%s\tsolves=%d\trelay=%d\tdeleted=%d", name, st, solves or 0, relay, deleted))
