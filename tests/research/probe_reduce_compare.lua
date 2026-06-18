---@diagnostic disable: undefined-global
-- After a uniform-quadratic PASS 1, reduce the problem by the pass-1-INACTIVE
-- elastic escapes two ways, keeping the pass-1-ACTIVE ones at the baseline 1*x^2:
--   DELETE : remove the near-0 elastic variables from the problem entirely.
--   COST0  : keep them but set their cost to 0 (free; linear 0, quad 0).
-- Re-solve each and compare to PASS 1 (soundness: same solution? numerically
-- cleaner? do freed channels activate?). elastic = shortage_source+surplus_sink;
-- initial_source/final_sink stay FREE in every pass.
--   luajit tests/research/probe_reduce_compare.lua [dumpfile] [BIG]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e6
local QUAD0 = 2

local ELASTIC = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }

local prob = assert(problem_dump.load_problem(PATH))

-- build with a disposition function: for each elastic key it returns
--   "active"  -> baseline quad QUAD0
--   "free"    -> cost 0, quad 0   (COST0 pattern, near-0 keys)
--   "delete"  -> remove the variable (DELETE pattern, near-0 keys)
local function build(disp)
    local problem = create_problem.create_problem("rc", prob.constraints, prob.normalized_lines, nil, nil)
    local rm = {}
    for key, p in pairs(problem.primals) do
        if ELASTIC[p.kind] then
            local d = disp(key)
            if d == "delete" then
                rm[key] = true
            elseif d == "free" then
                p.cost = 0; problem:set_quad(key, 0)
            else
                p.cost = 0; problem:set_quad(key, QUAD0)
            end
        elseif FREEK[p.kind] then
            p.cost = 0; problem:set_quad(key, 0)
        end
    end
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

local function park_threshold(problem, x)
    local maxr = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
    return math.max(1e-9, maxr * 1e-6)
end
local function stats(problem, x)
    local em, rm, lin, quad, nr = 0, 0, 0, 0, 0
    for k, p in pairs(problem.primals) do
        local v = math.abs(x[k] or 0)
        if ELASTIC[p.kind] then em = em + v elseif p.kind == "recipe" then rm = rm + v end
        lin = lin + (p.cost or 0) * v
        if p.quad and p.quad ~= 0 then quad = quad + 0.5 * p.quad * v * v end
    end
    return em, rm, lin, quad
end

-- PASS 1 ---------------------------------------------------------------------
local p1 = build(function() return "active" end)
local x1, st1, steps1 = solve(p1)
local thr1 = park_threshold(p1, x1)
local active1, near0 = {}, {}
for k, p in pairs(p1.primals) do
    if ELASTIC[p.kind] then
        if math.abs(x1[k] or 0) > thr1 then active1[k] = true else near0[k] = true end
    end
end
local nact, nnear = 0, 0
for _ in pairs(active1) do nact = nact + 1 end
for _ in pairs(near0) do nnear = nnear + 1 end

-- comparison helpers vs pass1
local function compare(label, problem, x, state, steps)
    local em, rm, lin, quad = stats(problem, x)
    -- max relative deviation on pass1-ACTIVE elastic keys + on recipes
    local maxdev_act, arg_act = 0, ""
    for k in pairs(active1) do
        local a, b = x1[k] or 0, x[k] or 0
        local d = math.abs(a - b) / (math.abs(a) + 1)
        if d > maxdev_act then maxdev_act = d; arg_act = k end
    end
    local maxdev_rec, arg_rec = 0, ""
    for k, p in pairs(p1.primals) do
        if p.kind == "recipe" then
            local a, b = x1[k] or 0, x[k] or 0
            local d = math.abs(a - b) / (math.abs(a) + 1)
            if d > maxdev_rec then maxdev_rec = d; arg_rec = k end
        end
    end
    -- previously-near0 elastic that activated now (only meaningful when kept)
    local risen = {}
    local thr = park_threshold(problem, x)
    for k in pairs(near0) do
        if problem.primals[k] and math.abs(x[k] or 0) > thr then
            risen[#risen + 1] = { k = k, v = math.abs(x[k] or 0) }
        end
    end
    table.sort(risen, function(a, b) return a.v > b.v end)
    io.write(string.format("\n## %s : state=%s steps=%d\n", label, state, steps))
    io.write(string.format("   escape_mass=%.6g recipe_mass=%.6g  obj(lin+quad)=%.6g+%.6g\n", em, rm, lin, quad))
    io.write(string.format("   max rel-dev vs PASS1 : active-elastic=%.3g (%s) ; recipe=%.3g (%s)\n",
        maxdev_act, arg_act, maxdev_rec, arg_rec))
    io.write(string.format("   previously-near0 elastic that ROSE to active: %d\n", #risen))
    for i = 1, math.min(#risen, 12) do io.write(string.format("      %-12.6g %s\n", risen[i].v, risen[i].k)) end
end

local em1, rm1, lin1, q1 = stats(p1, x1)
io.write("================ REDUCE COMPARISON (elastic = shortage+surplus) ================\n")
io.write(string.format("PASS1 (uniform quad %g): state=%s steps=%d thr=%.6g\n", QUAD0, st1, steps1, thr1))
io.write(string.format("   active elastic=%d  near0 elastic=%d  primals=%d\n", nact, nnear, p1.primal_length))
io.write(string.format("   escape_mass=%.6g recipe_mass=%.6g  obj(lin+quad)=%.6g+%.6g\n", em1, rm1, lin1, q1))

-- PATTERN DELETE -------------------------------------------------------------
local pD = build(function(k) return near0[k] and "delete" or "active" end)
local xD, stD, stepsD = solve(pD)
io.write(string.format("\n[DELETE] removed %d near0 elastic; primals %d -> %d\n",
    nnear, p1.primal_length, pD.primal_length))
compare("DELETE", pD, xD, stD, stepsD)

-- PATTERN COST0 --------------------------------------------------------------
local pC = build(function(k) return near0[k] and "free" or "active" end)
local xC, stC, stepsC = solve(pC)
io.write(string.format("\n[COST0] freed %d near0 elastic; primals=%d\n", nnear, pC.primal_length))
compare("COST0", pC, xC, stC, stepsC)
