---@diagnostic disable: undefined-global
-- "Consolidate the I/O points without raising total violation."
--
-- The violation escapes are shortage_source + surplus_sink (uniform cost 1 =
-- flat violation). initial_source/final_sink (raw / final product) are FREE per
-- the problem definition. Targets are hard equality at BIG (tier-1 met exactly).
--
-- BASELINE: uniform cost 1 -> minimal total violation V0, with some number of
-- active escape points.
-- THEN iterate: reprice each escape by w = 1/(|x_prev| + EPS) and re-solve. Small
-- escapes get expensive and die; large ones get cheap and survive -> the violation
-- consolidates into fewer outlets. We watch BOTH the count AND the true uniform
-- violation total Sum|x| each round, to see whether consolidation is free (stays
-- on the violation-optimal face) or costs violation.
--
--   luajit tests/research/probe_consolidate.lua [dumpfile] [EPS] [ROUNDS]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local EPS = tonumber(arg[2]) or 1.0
local ROUNDS = tonumber(arg[3]) or 6
local BIG = 1e6

local VIO = { shortage_source = true, surplus_sink = true } -- the violation outlets
local FREEK = { initial_source = true, final_sink = true }   -- raw / final = free

local prob = assert(problem_dump.load_problem(PATH))

local function strip_and_reindex(problem)
    local rm = {}
    for _, c in ipairs(prob.constraints) do
        local dual = vk.limit(tn.typed_name_to_variable_name(c))
        if problem.duals[dual] then problem.duals[dual].limit = BIG end
        rm[vk.elastic(dual)] = true; rm[vk.pos_slack(dual)] = true; rm[vk.neg_slack(dual)] = true
    end
    for key, p in pairs(problem.primals) do if p.kind == "elastic" or p.kind == "headroom" then rm[key] = true end end
    for key in pairs(rm) do if problem.primals[key] then problem.primals[key] = nil; problem.subject_terms[key] = nil end end
    local keys = {}; for k in pairs(problem.primals) do keys[#keys + 1] = k end; table.sort(keys)
    for i, k in ipairs(keys) do problem.primals[k].index = i end
    problem.primal_length = #keys
end

-- cost_for(key) returns the per-escape cost for VIO escapes (FREE escapes -> 0).
local function build(cost_for)
    local problem = create_problem.create_problem("cn", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = cost_for(key)
        elseif FREEK[p.kind] then p.cost = 0 end
    end
    strip_and_reindex(problem)
    return problem
end

local function solve(problem)
    local state, it, vars, last, steps = "ready", nil, nil, nil, 0
    repeat
        local ok, s, i2, v = pcall(lp.solve, problem, state, it, vars, prob.meta.tolerance, prob.meta.iterate_limit)
        if not ok then state = "errored"; break end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
    return (last and last.x) or {}, state, steps
end

-- count active escapes + true uniform violation total, relative to recipe-scaled thr
local function summarize(problem, x)
    local maxr = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
    local thr = math.max(1e-9, maxr * 1e-6)
    local count, vio, recipe = 0, 0, 0
    local active = {}
    for k, p in pairs(problem.primals) do
        local v = math.abs(x[k] or 0)
        if VIO[p.kind] then
            vio = vio + v
            if v > thr then count = count + 1; active[k] = v end
        elseif p.kind == "recipe" then recipe = recipe + v end
    end
    return count, vio, recipe, active, thr
end

io.write("================ CONSOLIDATE I/O POINTS (seed_143) ================\n")
io.write(string.format("file=%s  EPS=%g  rounds=%d\n", PATH:match("[^/]+$"), EPS, ROUNDS))
io.write("violation outlets = shortage_source + surplus_sink ; raw/final = free ; targets hard\n\n")

-- round 0: uniform cost 1
local problem = build(function() return 1 end)
local x, st, steps = solve(problem)
local count, vio, recipe, active = summarize(problem, x)
local v0 = vio
io.write(string.format("round 0 (uniform cost 1): state=%s  outlets=%2d  total_violation=%.6g  recipe_mass=%.6g\n",
    st, count, vio, recipe))

local prev = x
for r = 1, ROUNDS do
    local pr = prev
    problem = build(function(key) return 1 / (math.abs(pr[key] or 0) + EPS) end)
    x, st, steps = solve(problem)
    count, vio, recipe, active = summarize(problem, x)
    io.write(string.format("round %d (reprice 1/(x+%g)): state=%s  outlets=%2d  total_violation=%.6g (%.3gx V0)  recipe_mass=%.6g\n",
        r, EPS, st, count, vio, vio / v0, recipe))
    prev = x
end

-- final surviving outlets
io.write("\nsurviving outlets (final round), largest first:\n")
local rows = {}
for k, v in pairs(active) do rows[#rows + 1] = { k = k, v = v } end
table.sort(rows, function(a, b) return a.v > b.v end)
for _, r in ipairs(rows) do io.write(string.format("   %-13.6g %s\n", r.v, r.k)) end
