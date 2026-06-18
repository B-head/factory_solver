---@diagnostic disable: undefined-global
-- SINGLE-SHOT corpus driver for recipe-anchored escape consolidation.
-- Contract: `lua tests/research/consolidate_corpus.lua <dumpfile>` solves one
-- problem and prints ONE machine-readable RESULT line; tests/research/run_corpus.ps1
-- fans this across cores. Emits RAW numbers only (no verdict) so aggregation stays
-- bias-free: QP baseline vs the proximal-anchored + Vp-weighted IRL1 consolidation.
--
--   stage1 QP   : quad on elastic (shortage/surplus), recipes ~linear -> r_q.
--   stage2 IRL1 : escape weights w = base/(|x|+EPS) with base = IMPMULT on imports
--                 (Vp>>Vc), recipes proximal-anchored to r_q via ½·kq·(x-r_q)²,
--                 kq = KAPPA / max(r_q, RFLOOR)² (scale-invariant relative penalty).
--
-- Fixed at the swept sweet spot: KAPPA=1e2, IMPMULT=100, ITERS=5, EPS=1.

-- BIG (target RHS) is env-configurable: BIG=1e6 was a probe artifact that inflated
-- recipe activity to ~1e8 and made the least-norm QP Cholesky-singular ~31% of the
-- time (qp_conditioning.lua). EPS (the IRL1 small-escape floor) scales WITH BIG so
-- the reweighting dynamics stay equivalent across scales.
local BIG = tonumber(os.getenv("FS_BIG")) or 1e6
local KAPPA, IMPMULT, ITERS = 1e2, 100, 5
local EPS = BIG * 1e-6
local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }

local NAME = (arg[1] or "?"):match("[^/\\]+$") or "?"

-- Everything below is guarded so a bad file still emits a RESULT (state=error).
local ok, line = pcall(function()
    require "tests/headless_env"
    local create_problem = require "solver/create_problem"
    local problem_dump = require "tests/problem_dump"
    local tn = require "manage/typed_name"
    local vk = require "solver/var_key"
    local lp = require "solver/linear_programming"

    local prob = assert(problem_dump.load_problem(arg[1]))

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
            local s_ok, s, i2, v = pcall(lp.solve, pp, state, it, vars, prob.meta.tolerance, prob.meta.iterate_limit)
            if not s_ok then state = "errored"; break end
            state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
        until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
        return (last and last.x) or {}, state
    end

    -- stage 1: QP -> r_q.  recipe_epsilon scales WITH BIG (2^-6 at BIG=1e6) to hold
    -- the escape-quad / recipe-linear ratio constant: without this, a smaller BIG
    -- makes escapes relatively cheaper than recipes and the QP invents imports/dumps
    -- (350 clean->violation flips observed at a flat 2^-6). Answer-preserving.
    local pq = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil,
        { recipe_epsilon = (2 ^ -6) * BIG / 1e6 })
    for key, p in pairs(pq.primals) do
        if VIO[p.kind] then p.cost = 0; pq:set_quad(key, 2)
        elseif FREEK[p.kind] then p.cost = 0; pq:set_quad(key, 0) end
    end
    remove_targets(pq); reindex(pq)
    local xq, stq = solve(pq)

    local recipe_keys, vio_keys, kind_of = {}, {}, {}
    for k, p in pairs(pq.primals) do
        if p.kind == "recipe" or p.kind == "bridge" then recipe_keys[#recipe_keys + 1] = k
        elseif VIO[p.kind] then vio_keys[#vio_keys + 1] = k; kind_of[k] = p.kind end
    end
    local rq, maxr = {}, 0
    for _, k in ipairs(recipe_keys) do rq[k] = math.abs(xq[k] or 0); if rq[k] > maxr then maxr = rq[k] end end
    local THR = math.max(1e-9, maxr * 1e-6)
    local RFLOOR = math.max(THR, maxr * 1e-3)

    local function build(weights)
        local problem = create_problem.create_problem("anc", prob.constraints, prob.normalized_lines, nil, nil)
        for key, p in pairs(problem.primals) do
            if VIO[p.kind] then p.cost = weights[key] or (1 / EPS)
            elseif FREEK[p.kind] then p.cost = 0 end
        end
        remove_targets(problem); reindex(problem)
        for _, k in ipairs(recipe_keys) do
            local p = problem.primals[k]
            if p then
                local t = rq[k] or 0
                local kqv = KAPPA / (math.max(t, RFLOOR) ^ 2)
                problem:set_quad(k, kqv); p.cost = -kqv * t
            end
        end
        return problem
    end

    -- stage 2: IRL1 to ITERS
    local xprev, xc, stc = xq, nil, "n/a"
    for _ = 1, ITERS do
        local w = {}
        for _, k in ipairs(vio_keys) do
            local base = (kind_of[k] == "shortage_source") and IMPMULT or 1
            w[k] = base / (math.abs(xprev[k] or 0) + EPS)
        end
        local x, s = solve(build(w))
        xc, stc, xprev = x, s, x
    end

    local function stats(x)
        local esc, imp, dmp, l1 = 0, 0, 0, 0
        for _, k in ipairs(vio_keys) do
            local v = math.abs(x[k] or 0); l1 = l1 + v
            if v > THR then esc = esc + 1 end
            if kind_of[k] == "shortage_source" then imp = imp + v else dmp = dmp + v end
        end
        return esc, imp, dmp, l1
    end
    local function recipe_move()
        local s = 0 for _, k in ipairs(recipe_keys) do s = s + ((math.abs(xc[k] or 0) - (rq[k] or 0)) ^ 2) end return math.sqrt(s)
    end

    local qe, qi, qd, ql = stats(xq)
    local ce, ci, cd, cl = stats(xc)
    return string.format(
        "RESULT\tname=%s\tqp_state=%s\tc_state=%s\tnvio=%d\tqp_esc=%d\tqp_imp=%.6g\tqp_dump=%.6g\tqp_escL1=%.6g\tc_esc=%d\tc_imp=%.6g\tc_dump=%.6g\tc_escL1=%.6g\trdevL2=%.6g",
        NAME, stq, stc, #vio_keys, qe, qi, qd, ql, ce, ci, cd, cl, recipe_move())
end)

if ok then
    io.write(line .. "\n")
else
    io.write(string.format("RESULT\tname=%s\tqp_state=error\tc_state=error\terr=%s\n", NAME, tostring(line):gsub("%s+", " "):sub(1, 120)))
end
