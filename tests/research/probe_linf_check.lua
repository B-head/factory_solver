---@diagnostic disable: undefined-global
-- Diagnose why L-infinity returned a peak (t) ABOVE the L2 max escape, which is
-- impossible for a correct min-max over the same feasible set. Two suspects:
--   (a) the cap formulation is wrong (t does not actually bound the escapes), or
--   (b) each norm calls create_problem separately, so hash-seed pairs-order makes
--       the shortage_source COLUMN SET differ build-to-build -> different feasible
--       sets -> L2 and Linf are not comparable.
-- Tests: escape-count stability across fresh builds; and whether t <= maxesc_qp is
-- feasible in a Linf built on the SAME object that produced maxesc.
--
--   luajit tests/research/probe_linf_check.lua [dumpfile]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = 1e6
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
        if not ok then return {}, "errored", steps end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
    return (last and last.x) or {}, state, steps
end
local function vio_list(problem)
    local ks = {}; for k, p in pairs(problem.primals) do if VIO[p.kind] then ks[#ks + 1] = k end end
    table.sort(ks); return ks
end
local function vio_set(problem)
    local s = {}; for k, p in pairs(problem.primals) do if VIO[p.kind] then s[k] = true end end; return s
end
local function maxesc(x, ks) local m = 0 for _, k in ipairs(ks) do local v = math.abs(x[k] or 0); if v > m then m = v end end return m end

-- ---- test 1: is the escape column set stable across fresh builds? ----
io.write("== test 1: escape-column-set stability across 4 fresh create_problem calls ==\n")
local counts, firstset = {}, nil
for i = 1, 4 do
    local p = create_problem.create_problem("stab" .. i, prob.constraints, prob.normalized_lines, nil, nil)
    strip(p)
    local set = vio_set(p)
    local n = 0; for _ in pairs(set) do n = n + 1 end
    counts[i] = n
    if not firstset then firstset = set else
        local diff = 0
        for k in pairs(set) do if not firstset[k] then diff = diff + 1 end end
        for k in pairs(firstset) do if not set[k] then diff = diff + 1 end end
        io.write(string.format("   build%d: %d escapes, symdiff vs build1 = %d\n", i, n, diff))
    end
end
io.write(string.format("   build1: %d escapes\n", counts[1]))

-- ---- test 2: QP max vs Linf t, and t<=maxesc_qp feasibility on the SAME column set ----
io.write("\n== test 2: QP max vs Linf peak, and is a lower peak feasible? ==\n")
local function build_qp()
    local p = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil, nil)
    for key, pp in pairs(p.primals) do
        if VIO[pp.kind] then pp.cost = 0; p:set_quad(key, 2)
        elseif FREEK[pp.kind] then pp.cost = 0; p:set_quad(key, 0) end
    end
    strip(p); return p
end
-- Linf on a FRESH pure-LP object; optional hard cap t <= tcap to probe feasibility.
-- ALL non-t costs are zeroed (recipe machine costs would otherwise dominate the
-- objective and drown out min-t -> the solver minimizes machines, not the peak).
local function build_linf(eps, tcap)
    local p = create_problem.create_problem("linf", prob.constraints, prob.normalized_lines, nil, nil)
    for key, pp in pairs(p.primals) do
        pp.cost = VIO[pp.kind] and (eps or 0) or 0
    end
    strip(p)
    local tkey = "|linf_t|"
    p:add_objective(tkey, 1, false, "linf_t")
    for _, k in ipairs(vio_list(p)) do
        local dual = "|linf_cap|" .. k
        p:add_upper_limit_constraint(dual, 0)
        p:add_subject_term(k, dual, 1)
        p:add_subject_term(tkey, dual, -1)
    end
    if tcap then
        p:add_upper_limit_constraint("|linf_tcap|", tcap)
        p:add_subject_term(tkey, "|linf_tcap|", 1)
    end
    return p, tkey
end

local pq = build_qp(); local xq, stq = solve(pq); local mq = maxesc(xq, vio_list(pq))
io.write(string.format("QP:        state=%s  max escape = %.6g  (escapes=%d)\n", stq, mq, #vio_list(pq)))

local pf, tk = build_linf(1e-4); local xf, stf = solve(pf)
io.write(string.format("Linf:      state=%s  t = %.6g  max escape = %.6g  (escapes=%d)\n",
    stf, xf[tk] or 0, maxesc(xf, vio_list(pf)), #vio_list(pf)))

-- probe: force t <= maxesc_qp*(1+small). If feasible -> the unforced Linf was
-- non-optimal; if infeasible -> a lower peak genuinely is not reachable here.
for _, frac in ipairs({ 1.0001, 0.95, 0.8 }) do
    local cap = mq * frac
    local pc, tkc = build_linf(1e-4, cap)
    local xc, stc, steps = solve(pc)
    io.write(string.format("Linf t<=%.6g (%.2fx QP max): state=%-10s t=%.6g max esc=%.6g steps=%d\n",
        cap, frac, stc, xc[tkc] or 0, maxesc(xc, vio_list(pc)), steps))
end
