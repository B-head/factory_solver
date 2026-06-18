---@diagnostic disable: undefined-global
-- Dump the IRL1 (rho=0.25) consolidated solution's escapes vs the QP start, with
-- producible/consumable classification, to see whether consolidation preserved
-- QP's character or drifted toward the cheat (grew producible imports = defeats).
--
--   luajit tests/research/probe_irl1_dump.lua [dumpfile] [RHO] [EPS]

require "tests/headless_env"
local ref = require "tests/research/reference_solver"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local RHO = tonumber(arg[2]) or 0.25
local EPS = tonumber(arg[3]) or 1.0
local ITERS, BIG = 5, 1e6
local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }

local prob = assert(problem_dump.load_problem(PATH))
local producible = ref.producible_set(prob.constraints, prob.normalized_lines)
local consumable = ref.consumable_set(prob.constraints, prob.normalized_lines)

local function remove_targets(problem)
    local rm = {}
    for _, c in ipairs(prob.constraints) do
        local dual = vk.limit(tn.typed_name_to_variable_name(c))
        if problem.duals[dual] then problem.duals[dual].limit = BIG end
        rm[vk.elastic(dual)] = true; rm[vk.pos_slack(dual)] = true; rm[vk.neg_slack(dual)] = true
    end
    for key, p in pairs(problem.primals) do if p.kind == "elastic" or p.kind == "headroom" then rm[key] = true end end
    for key in pairs(rm) do if problem.primals[key] then problem.primals[key] = nil; problem.subject_terms[key] = nil end end
end
local function reindex(problem)
    local keys = {}; for k in pairs(problem.primals) do keys[#keys + 1] = k end; table.sort(keys)
    for i, k in ipairs(keys) do problem.primals[k].index = i end
    problem.primal_length = #keys
end
local function solve(pp)
    local state, it, vars, last, steps = "ready", nil, nil, nil, 0
    repeat
        local ok, s, i2, v = pcall(lp.solve, pp, state, it, vars, prob.meta.tolerance, prob.meta.iterate_limit)
        if not ok then state = "errored"; break end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
    return (last and last.x) or {}, state
end

local function build_qp()
    local problem = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = 0; problem:set_quad(key, 2)
        elseif FREEK[p.kind] then p.cost = 0; problem:set_quad(key, 0) end
    end
    remove_targets(problem); reindex(problem); return problem
end
local pq = build_qp(); local xq = solve(pq)
local vio = {}  -- key -> {kind, material}
for k, p in pairs(pq.primals) do if VIO[p.kind] then vio[k] = { kind = p.kind, material = p.material } end end

local function build_irl1(weights)
    local problem = create_problem.create_problem("irl1", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = weights[key] or (1 / EPS)
        elseif FREEK[p.kind] then p.cost = 0 end
    end
    remove_targets(problem); reindex(problem)
    for key in pairs(vio) do
        if problem.primals[key] then
            local dual = "|prox|" .. key
            problem:add_upper_limit_constraint(dual, math.abs(xq[key] or 0) * (1 + RHO) + 1e-9)
            problem:add_subject_term(key, dual, 1)
        end
    end
    return problem
end
local xprev = xq
for _ = 1, ITERS do
    local w = {}; for k in pairs(vio) do w[k] = 1 / (math.abs(xprev[k] or 0) + EPS) end
    local p = build_irl1(w); local x = solve(p); xprev = x
end
local xi = xprev

local function cls(info)
    if info.kind == "shortage_source" then return producible[info.material] and "Vp DEFEAT(prod import)" or "Vf makeup" end
    return consumable[info.material] and "Vc dump(consumable)" or "free dump" end

-- max recipe for threshold
local maxr = 0
for k, p in pairs(pq.primals) do if p.kind == "recipe" then local a = math.abs(xq[k] or 0); if a > maxr then maxr = a end end end
local thr = math.max(1e-9, maxr * 1e-6)

io.write(string.format("======= IRL1 (rho=%.2g) consolidated solution vs QP start =======\n", RHO))
io.write(string.format("file=%s\n\n", PATH:match("[^/]+$")))

local rows = {}
for k, info in pairs(vio) do
    local q, i = math.abs(xq[k] or 0), math.abs(xi[k] or 0)
    if q > thr or i > thr then
        local status = (q > thr and i <= thr) and "KILLED" or (i > q * 1.05 and "grew") or (i < q * 0.95 and "shrank") or "kept"
        rows[#rows + 1] = { k = k, m = info.material, c = cls(info), q = q, i = i, st = status }
    end
end
table.sort(rows, function(a, b) return a.i > b.i end)
io.write(string.format("%-26s %-22s %-12s %-12s %s\n", "material", "class", "QP", "IRL1", "status"))
for _, r in ipairs(rows) do
    io.write(string.format("%-26s %-22s %-12.6g %-12.6g %s\n", r.m, r.c, r.q, r.i, r.st))
end

-- summaries by class
local function tot(x, pred)
    local s = 0 for k, info in pairs(vio) do if pred(info) then s = s + math.abs(x[k] or 0) end end return s end
local Vp = function(i) return i.kind == "shortage_source" and producible[i.material] end
local Vf = function(i) return i.kind == "shortage_source" and not producible[i.material] end
local Vc = function(i) return i.kind == "surplus_sink" and consumable[i.material] end
io.write(string.format("\n             Vp(defeat import)   Vf(makeup)   Vc(consumable dump)\n"))
io.write(string.format("QP    :      %-18.6g %-12.6g %-12.6g\n", tot(xq, Vp), tot(xq, Vf), tot(xq, Vc)))
io.write(string.format("IRL1  :      %-18.6g %-12.6g %-12.6g\n", tot(xi, Vp), tot(xi, Vf), tot(xi, Vc)))
local nk, ng = 0, 0
for _, r in ipairs(rows) do if r.st == "KILLED" then nk = nk + 1 elseif r.st == "grew" then ng = ng + 1 end end
io.write(string.format("\nescapes killed=%d  grew=%d  (active: QP=%d -> IRL1=%d)\n",
    nk, ng, (function() local n = 0 for _, r in ipairs(rows) do if r.q > thr then n = n + 1 end end return n end)(),
    (function() local n = 0 for _, r in ipairs(rows) do if r.i > thr then n = n + 1 end end return n end)()))
