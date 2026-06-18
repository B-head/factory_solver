---@diagnostic disable: undefined-global
-- Two-pass reweighting experiment. PASS 1: uniform quadratic on the elastic
-- escapes (objective (QUAD0/2)*x^2). Classify each elastic escape by its solved
-- |x| vs the park threshold. PASS 2: rebuild with the elastic quadratic set to
-- HI (1024) for escapes that were active in pass 1, LO (1) for escapes that were
-- near 0; re-solve. Target stays a hard equality at BIG.
--
-- MODE selects which kinds count as "elastic" (reweighted):
--   ss  (default) -> shortage_source + surplus_sink only; initial/final FREE.
--   all           -> all four escape kinds reweighted; nothing free.
--
--   luajit tests/research/probe_quad_reweight.lua [ss|all] [dumpfile] [BIG]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local material_cycles = require "solver/material_cycles"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local MODE = arg[1] or "ss"
local PATH = arg[2] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[3]) or 1e6
local QUAD0, HI, LO = 2, 1024, 1

local ELASTIC = (MODE == "all")
    and { initial_source = true, shortage_source = true, surplus_sink = true, final_sink = true }
    or { shortage_source = true, surplus_sink = true }
local FREEK = (MODE == "all") and {} or { initial_source = true, final_sink = true }

local prob = assert(problem_dump.load_problem(PATH))

-- material graph (with bridges) for SCC tags
local function scc_tags()
    local p0 = create_problem.create_problem("t", prob.constraints, prob.normalized_lines, nil, nil)
    local lines = {}
    for _, l in ipairs(prob.normalized_lines) do lines[#lines + 1] = l end
    for _, l in ipairs(p0.bridges) do lines[#lines + 1] = l end
    local adj = material_cycles.build_material_graph(lines)
    local sccs = material_cycles.find_sccs(adj)
    local cyc = {}
    for _, s in ipairs(sccs) do if material_cycles.is_cyclic_scc(s, adj) then cyc[#cyc + 1] = s end end
    table.sort(cyc, function(a, b) if #a ~= #b then return #a > #b end return a[1] < b[1] end)
    local m = {}
    for i, s in ipairs(cyc) do for _, mm in ipairs(s) do m[mm] = string.format("C%02d", i) end end
    return m
end
local mat_scc = scc_tags()
local function tag(material) return material and (mat_scc[material] or "-") or "?" end

local function build(quad_for)
    local problem = create_problem.create_problem("rw", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if ELASTIC[p.kind] then p.cost = 0; problem:set_quad(key, quad_for(key))
        elseif FREEK[p.kind] then p.cost = 0; problem:set_quad(key, 0) end
    end
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
local function is_elastic(p) return ELASTIC[p.kind] end
local function masses(problem, x)
    local em, rm, lin, quad = 0, 0, 0, 0
    for k, p in pairs(problem.primals) do
        local v = math.abs(x[k] or 0)
        if is_elastic(p) then em = em + v elseif p.kind == "recipe" then rm = rm + v end
        lin = lin + (p.cost or 0) * v
        if p.quad and p.quad ~= 0 then quad = quad + 0.5 * p.quad * v * v end
    end
    return em, rm, lin, quad
end

-- PASS 1: uniform quad
local p1 = build(function() return QUAD0 end)
local x1, st1, steps1 = solve(p1)
local thr1 = park_threshold(p1, x1)
local active1 = {}
local nact, nnear = 0, 0
for k, p in pairs(p1.primals) do
    if is_elastic(p) then
        if math.abs(x1[k] or 0) > thr1 then active1[k] = true; nact = nact + 1 else nnear = nnear + 1 end
    end
end

-- PASS 2: HI for pass-1-active, LO for pass-1-near-0
local p2 = build(function(k) return active1[k] and HI or LO end)
local x2, st2, steps2 = solve(p2)
local thr2 = park_threshold(p2, x2)

local em1, rm1, lin1, q1 = masses(p1, x1)
local em2, rm2, lin2, q2 = masses(p2, x2)

io.write("================ TWO-PASS REWEIGHT ================\n")
io.write(string.format("MODE=%s  elastic kinds={%s}  BIG=%g  HI=%g LO=%g\n",
    MODE, MODE == "all" and "init,short,surplus,final" or "short,surplus", BIG, HI, LO))
io.write(string.format("PASS1 (uniform quad %g): state=%s steps=%d  thr=%.6g\n", QUAD0, st1, steps1, thr1))
io.write(string.format("   active elastic=%d  near0 elastic=%d  | escape_mass=%.6g recipe_mass=%.6g  obj(lin+quad)=%.6g+%.6g\n",
    nact, nnear, em1, rm1, lin1, q1))
io.write(string.format("PASS2 (HI=1024 active / LO=1 near0): state=%s steps=%d  thr=%.6g\n", st2, steps2, thr2))
io.write(string.format("   escape_mass=%.6g recipe_mass=%.6g  obj(lin+quad)=%.6g+%.6g\n", em2, rm2, lin2, q2))

-- transitions
local stayed, collapsed, rose = 0, 0, 0
local rows = {}
for k, p in pairs(p1.primals) do
    if is_elastic(p) then
        local v1, v2 = math.abs(x1[k] or 0), math.abs(x2[k] or 0)
        local q = active1[k] and HI or LO
        local a1, a2 = v1 > thr1, v2 > thr2
        if a1 and a2 then stayed = stayed + 1 elseif a1 and not a2 then collapsed = collapsed + 1
        elseif (not a1) and a2 then rose = rose + 1 end
        if a1 or a2 then
            rows[#rows + 1] = { k = k, kind = p.kind, scc = tag(p.material), q = q, v1 = v1, v2 = v2,
                note = (a1 and a2) and "stay" or (a1 and "COLLAPSE") or "RISE" }
        end
    end
end
io.write(string.format("\ntransitions among elastic escapes (relative to park thr):\n"))
io.write(string.format("   pass1-active that STAYED active in pass2 : %d\n", stayed))
io.write(string.format("   pass1-active that COLLAPSED to ~0        : %d\n", collapsed))
io.write(string.format("   pass1-near0 that ROSE to active          : %d\n", rose))

table.sort(rows, function(a, b) return a.v1 > b.v1 end)
io.write("\n-- elastic escapes active in pass1 and/or pass2 --  [SCC|kind|quad|x1|x2|note]\n")
for _, r in ipairs(rows) do
    io.write(string.format("  {%-4s} [%-15s] q=%-4d x1=%-13.6g x2=%-13.6g %s  %s\n",
        r.scc, r.kind, r.q, r.v1, r.v2, r.note, r.k))
end
