---@diagnostic disable: undefined-global
-- Cross-seed L-infinity behaviour. For every dump passed as an arg, measure the
-- worst-case single escape under three within-face selection rules:
--   peakL1   = max escape when minimizing sum |esc|        (concentrate)
--   peakL2   = max escape when minimizing sum esc^2 (QP)    (spread by fabricate)
--   peakLinf = the min-max value t = min over the face of (max esc)  (equalize peak)
-- All builds zero non-escape costs so the objective is the pure escape norm (the
-- machine-cost tier would otherwise dominate min-t -- the bug that made an earlier
-- Linf return a peak ABOVE L2). Targets pinned hard at BIG, raw/final free.
--
-- Sanity gate: peakLinf must be <= peakL1 (the L1 solution is always Linf-feasible
-- with t = its own peak). A row with peakLinf > peakL1 flags a non-converged solve
-- and is marked BAD.
--
--   luajit tests/research/probe_linf_seeds.lua <dumpfile> [<dumpfile> ...]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local BIG = 1e6
local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }

local function strip(prob, problem)
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
local function solve(prob, pp)
    local state, it, vars, last, steps = "ready", nil, nil, nil, 0
    repeat
        local ok, s, i2, v = pcall(lp.solve, pp, state, it, vars, prob.meta.tolerance, prob.meta.iterate_limit)
        if not ok then return {}, "errored" end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
    return (last and last.x) or {}, state
end
local function vio_list(problem)
    local ks = {}; for k, p in pairs(problem.primals) do if VIO[p.kind] then ks[#ks + 1] = k end end
    table.sort(ks); return ks
end
local function peak(x, ks) local m = 0 for _, k in ipairs(ks) do local v = math.abs(x[k] or 0); if v > m then m = v end end return m end
local function nrec(problem, x)
    local maxr = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
    local thr = math.max(1e-9, maxr * 1e-6); local n = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" and math.abs(x[k] or 0) > thr then n = n + 1 end end
    return n
end

local function build_lin(prob)
    local p = create_problem.create_problem("lin", prob.constraints, prob.normalized_lines, nil, nil)
    for _, pp in pairs(p.primals) do pp.cost = VIO[pp.kind] and 1 or 0 end
    strip(prob, p); return p
end
local function build_qp(prob)
    local p = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil, nil)
    for key, pp in pairs(p.primals) do
        pp.cost = 0
        if VIO[pp.kind] then p:set_quad(key, 2) elseif FREEK[pp.kind] then p:set_quad(key, 0) end
    end
    strip(prob, p); return p
end
local function build_linf(prob, eps)
    local p = create_problem.create_problem("linf", prob.constraints, prob.normalized_lines, nil, nil)
    for _, pp in pairs(p.primals) do pp.cost = VIO[pp.kind] and (eps or 0) or 0 end
    strip(prob, p)
    local tkey = "|linf_t|"
    p:add_objective(tkey, 1, false, "linf_t")
    for _, k in ipairs(vio_list(p)) do
        local dual = "|linf_cap|" .. k
        p:add_upper_limit_constraint(dual, 0)
        p:add_subject_term(k, dual, 1)
        p:add_subject_term(tkey, dual, -1)
    end
    return p, tkey
end
local function seedid(path) return (path:match("seed_%d+")) or (path:match("[^/\\]+$")) end

io.write("# cross-seed L-infinity peak study\n")
for i = 1, #arg do
    local path = arg[i]
    local ok, prob = pcall(problem_dump.load_problem, path)
    if ok and prob then
        local pl = build_lin(prob); local xl, stl = solve(prob, pl); local kl = vio_list(pl)
        local pkL1 = peak(xl, kl)

        local pq = build_qp(prob); local xq, stq = solve(prob, pq)
        local pkL2 = (stq == "finished") and peak(xq, vio_list(pq)) or -1

        local pf, tk = build_linf(prob, 1e-4); local xf, stf = solve(prob, pf)
        local pkLinf = xf[tk] or peak(xf, vio_list(pf))

        local ratio = pkL1 > 0 and (pkLinf / pkL1) or 0
        local bad = (pkLinf > pkL1 * 1.001) and " BAD_nonconverged" or ""
        io.write(string.format(
            "seed=%s nesc=%d peakL1=%.6g peakL2=%.6g peakLinf=%.6g ratio=%.4f nrecL1=%d nrecLinf=%d stL1=%s stL2=%s stLinf=%s%s\n",
            seedid(path), #kl, pkL1, pkL2, pkLinf, ratio, nrec(pl, xl), nrec(pf, xf), stl, stq, stf, bad))
        io.flush()
    end
end
