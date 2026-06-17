---@diagnostic disable: undefined-global
-- Prevalence probe for the reference's final_sink-of-consumable dump case in the
-- SHIPPED cascade's own solutions. The reference's is_dump counts a consumable
-- material trashed through its free pinned |final_sink| as a tier-2c (Vc) defeat;
-- the cascade's Vc only adjudicates |surplus_sink|. This measures how often the
-- gap can even bite: over the corpus, does the cascade's FINAL solution leave a
-- flowing |final_sink| whose material is an intermediate (produced AND consumed
-- in-set, the necessary condition for the dump to be a real defeat rather than a
-- terminal byproduct)? If ~0, porting the reference's dump-side classifier to the
-- cascade Vc is moot on this corpus.
--
-- Single-shot: `<lua> probe_cascade_finalsink.lua <dump>` -> one row.
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_cascade_finalsink.lua -Collect '^seed=' -Out <tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local problem_dump = require "tests/problem_dump"
local observe_price = require "solver/observe_price"
local cascade = require "solver/cascade"

local TOL, ITER = 1e-7, 800
local RESCUE_TRIGGER = 1e-6
local TR_REL, TR_ABS = 1e-3, 1e-6
local FLOW_TH = 1e-4

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

local function solve_via_cascade(constraints, lines)
    local prob = build_ship(constraints, lines, nil)
    if not prob then return "build-error", nil, nil end
    local s, v = solve(prob)
    if s ~= "finished" then return s, nil, nil end
    local p, x, sl, rescue_budget = rescue_target(constraints, lines, prob, v.x, v.s)
    local raw = { x = x, s = sl }
    local cc = cascade.begin(p, raw, lines, rescue_budget)
    local prev_any = raw
    local guard = 0
    while cc.build do
        guard = guard + 1
        if guard > 2000 then return "cascade-stuck", nil, nil end
        local b = cc.build
        local bp = build_cascade(constraints, lines, b)
        if not bp then
            cascade.advance(cc, p, nil, "unfeasible")
        else
            local seed = (not cascade.is_cold(b)) and prev_any or nil
            local bs, bv = solve(bp, seed)
            if bs == "finished" and bv then prev_any = bv end
            cascade.advance(cc, bp, bv, bs)
            if cc.phase == "restore" then
                local rp = build_cascade(constraints, lines, cc.build)
                return "finished", rp or bp, cc.adopted_raw.x
            end
        end
    end
    local fp = build_cascade(constraints, lines, cc.adopted_build)
    return "finished", fp, cc.adopted_raw.x
end

local path = assert(arg[1], "usage: lua probe_cascade_finalsink.lua <dump>")
local name = path:gsub("[\\/]+$", ""):match("([^\\/]+)%.lua$") or path
local prob = problem_dump.load_problem(path)
if not prob then print(string.format("seed=%s\tLOAD-ERROR", name)); return end

local ok, st, sp, sx = pcall(solve_via_cascade, prob.constraints, prob.normalized_lines)
if not ok or st ~= "finished" or not sx then
    print(string.format("seed=%s\tstate=%s\tfs_inter=0\tfs_inter_mats=0\tfs_any=0", name, ok and tostring(st) or "ERR"))
    return
end

local intermediates = cascade.intermediates(prob.normalized_lines)
-- final_sink flows in the cascade's final solution: total, and the share whose
-- material is an intermediate (the necessary condition for a dump-side defeat).
local fs_any, fs_inter, fs_inter_mats = 0, 0, 0
local seen = {}
for key, p in pairs(sp.primals) do
    if p.kind == "final_sink" and p.material then
        local v = math.abs(sx[key] or 0)
        if v > FLOW_TH then
            fs_any = fs_any + v
            if intermediates[p.material] then
                fs_inter = fs_inter + v
                if not seen[p.material] then seen[p.material] = true; fs_inter_mats = fs_inter_mats + 1 end
            end
        end
    end
end
print(string.format("seed=%s\tstate=finished\tfs_inter=%.6g\tfs_inter_mats=%d\tfs_any=%.6g", name, fs_inter, fs_inter_mats, fs_any))
