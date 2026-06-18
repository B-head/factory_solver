---@diagnostic disable: undefined-global
-- What does the QP actually minimize, and is the all-cheat ALSO a minimum?
-- QP minimizes sum(escape^2) (L2 of intermediate imbalance) with hard BIG targets,
-- raw/final free. The "cheat" (import intermediates wholesale) is what the LINEAR
-- (sum|escape|) framing falls into. Evaluate BOTH objectives on BOTH solutions:
--   if  L2(x_qp) < L2(x_cheat)  then the cheat is NOT a QP minimum.
-- Also report whether the QP spontaneously imports CO2 / avoids the psc dump
-- (i.e. whether the L2 penalty itself does the import-vs-dump trade).
--
--   luajit tests/research/probe_qp_minimizes.lua [dumpfile] [BIG]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e6
local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }

local prob = assert(problem_dump.load_problem(PATH))

local function strip(problem)
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
    strip(problem); return problem
end
local function build_lin()
    local problem = create_problem.create_problem("lin", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = 1
        elseif FREEK[p.kind] then p.cost = 0 end
    end
    strip(problem); return problem
end

-- escape vars are the same set in both builds; collect their keys once
local function escape_keys(problem)
    local ks = {}
    for k, p in pairs(problem.primals) do if VIO[p.kind] then ks[#ks + 1] = k end end
    return ks
end
local function L1(keys, x) local s = 0 for _, k in ipairs(keys) do s = s + math.abs(x[k] or 0) end return s end
local function L2(keys, x) local s = 0 for _, k in ipairs(keys) do local v = x[k] or 0; s = s + v * v end return s end
local function recipes(problem, x)
    local maxr = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
    local thr = math.max(1e-9, maxr * 1e-6); local n = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" and math.abs(x[k] or 0) > thr then n = n + 1 end end
    return n
end
local function findv(problem, x, kind, sub)
    local t = 0 for k, p in pairs(problem.primals) do if p.kind == kind and p.material and tostring(p.material):find(sub, 1, true) then t = t + math.abs(x[k] or 0) end end return t
end

local pq = build_qp(); local xq = solve(pq)
local pl = build_lin(); local xl = solve(pl)
local kq = escape_keys(pq)

io.write("================ WHAT DOES QP MINIMIZE? is the cheat also a minimum? ================\n")
io.write(string.format("file=%s  BIG=%g\n\n", PATH:match("[^/]+$"), BIG))
io.write(string.format("%-18s %-14s %-14s %-7s %-12s %-12s %-12s\n", "solution", "L1 |esc|", "L2 esc^2", "recipes", "psc dump", "CO2 import", "albumin imp"))
io.write(string.format("%-18s %-14.6g %-14.6g %-7d %-12.6g %-12.6g %-12.6g\n", "QP (min L2)",
    L1(kq, xq), L2(kq, xq), recipes(pq, xq), findv(pq, xq, "surplus_sink", "psc@[10,10]"),
    findv(pq, xq, "shortage_source", "carbon-dioxide"), findv(pq, xq, "shortage_source", "item/albumin")))
io.write(string.format("%-18s %-14.6g %-14.6g %-7d %-12.6g %-12.6g %-12.6g\n", "LINEAR/cheat (L1)",
    L1(kq, xl), L2(kq, xl), recipes(pl, xl), findv(pl, xl, "surplus_sink", "psc@[10,10]"),
    findv(pl, xl, "shortage_source", "carbon-dioxide"), findv(pl, xl, "shortage_source", "item/albumin")))

io.write("\n-- the test --\n")
io.write(string.format("L2(QP)=%.6g  vs  L2(cheat)=%.6g\n", L2(kq, xq), L2(kq, xl)))
if L2(kq, xq) < L2(kq, xl) then
    io.write("=> cheat has HIGHER sum(esc^2): the all-cheat is NOT a QP minimum. QP's L2 penalty\n")
    io.write("   rejects the concentrated wholesale import.\n")
else
    io.write("=> cheat is at/below QP on L2: the cheat IS (near) a QP minimum -- surprising, investigate.\n")
end
io.write(string.format("L1(QP)=%.6g  vs  L1(cheat)=%.6g  (linear sees the cheat as %s)\n",
    L1(kq, xq), L1(kq, xl), L1(kq, xl) < L1(kq, xq) and "BETTER -> why linear cheats" or "worse"))
