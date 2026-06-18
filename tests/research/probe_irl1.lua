---@diagnostic disable: undefined-global
-- IRL1 (iteratively reweighted L1) + proximal guard, seeded from the QP solution,
-- to consolidate the QP's spread escapes into FEWER outlets while staying in the
-- good basin. Each iteration solves an LP minimizing sum(w_i * x_i) over the
-- violation escapes, w_i = 1/(|x_prev_i| + EPS) (small escapes get expensive ->
-- driven to 0; large stay cheap). Proximal guard: x_i <= x_qp_i*(1+RHO) so imports
-- cannot grow past the QP basis toward the cheat. RHO sweeps the trust radius.
-- Targets hard at BIG, raw/final free.
--
--   luajit tests/research/probe_irl1.lua [dumpfile] [EPS] [ITERS]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local EPS = tonumber(arg[2]) or 1.0
local ITERS = tonumber(arg[3]) or 5
local BIG = 1e6
local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }

local prob = assert(problem_dump.load_problem(PATH))

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

-- QP base
local function build_qp()
    local problem = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = 0; problem:set_quad(key, 2)
        elseif FREEK[p.kind] then p.cost = 0; problem:set_quad(key, 0) end
    end
    remove_targets(problem); reindex(problem)
    return problem
end
local pq = build_qp()
local xq = solve(pq)
local vio_keys = {}
for k, p in pairs(pq.primals) do if VIO[p.kind] then vio_keys[#vio_keys + 1] = k end end

local function metrics(problem, x)
    local maxr = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
    local thr = math.max(1e-9, maxr * 1e-6)
    local nesc, l1, nrec = 0, 0, 0
    for _, k in ipairs(vio_keys) do local v = math.abs(x[k] or 0); l1 = l1 + v; if v > thr then nesc = nesc + 1 end end
    for k, p in pairs(problem.primals) do if p.kind == "recipe" and math.abs(x[k] or 0) > thr then nrec = nrec + 1 end end
    return nesc, l1, nrec, thr
end
local function findv(problem, x, kind, sub)
    local t = 0 for k, p in pairs(problem.primals) do if p.kind == kind and p.material and tostring(p.material):find(sub, 1, true) then t = t + math.abs(x[k] or 0) end end return t
end

local q_nesc, q_l1, q_nrec = metrics(pq, xq)
io.write("================ IRL1 + proximal guard (QP-seeded) ================\n")
io.write(string.format("file=%s  EPS=%g ITERS=%d\n", PATH:match("[^/]+$"), EPS, ITERS))
io.write(string.format("QP start: active escapes=%d  L1=%.6g  recipes=%d  albumin import=%.6g\n\n",
    q_nesc, q_l1, q_nrec, findv(pq, xq, "shortage_source", "item/albumin")))

-- IRL1 build with weights + proximal box U_i = x_qp_i*(1+RHO)
local function build_irl1(weights, RHO)
    local problem = create_problem.create_problem("irl1", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = weights[key] or (1 / EPS)
        elseif FREEK[p.kind] then p.cost = 0 end
    end
    remove_targets(problem); reindex(problem)
    -- proximal upper bounds on the violation escapes
    for _, key in ipairs(vio_keys) do
        if problem.primals[key] then
            local dual = "|prox|" .. key
            local slack = problem:add_upper_limit_constraint(dual, (math.abs(xq[key] or 0)) * (1 + RHO) + 1e-9)
            problem:add_subject_term(key, dual, 1)
        end
    end
    return problem
end

for _, RHO in ipairs({ 0, 0.25, 1.0 }) do
    io.write(string.format("-- RHO=%.2g (escape cap = x_qp*(1+RHO)) --\n", RHO))
    local xprev = xq
    local nesc, l1, nrec, alb
    for it = 1, ITERS do
        local w = {}
        for _, k in ipairs(vio_keys) do w[k] = 1 / (math.abs(xprev[k] or 0) + EPS) end
        local p = build_irl1(w, RHO)
        local x, st = solve(p)
        nesc, l1, nrec = metrics(p, x)
        alb = findv(p, x, "shortage_source", "item/albumin")
        io.write(string.format("   iter%d: state=%s active escapes=%d  L1=%.6g (%.3gx QP)  recipes=%d  albumin=%.6g\n",
            it, st, nesc, l1, l1 / q_l1, nrec, alb))
        xprev = x
    end
    io.write("\n")
end
