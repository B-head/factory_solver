---@diagnostic disable: undefined-global
-- SINGLE-SHOT corpus driver: recipe-anchored consolidation with a LEXICOGRAPHIC
-- Vp >> Vf >> Vc escape tier vs the flat 2-tier soft (IMPMULT) version, so we can
-- see whether the strict order fixes the few BADTRADEs at the cost of the
-- over-rigidity the B work found (strict Vp>>Vc forbids a dump-forced producible
-- import). FS_TIER selects:
--   soft (default): shortage=IMPMULT(100), surplus=1               (current)
--   lex           : Vp(producible import)=1e6 >> Vf(non-prod import)=1e3
--                   >> Vc(consumable dump)=1 > Vfree(non-consumable dump)=1e-2
-- Reports the Vp/Vf/Vc split (problem-definition terms) for QP and consolidated.
-- Producibility/consumability are the reference solver's greatest fixpoints,
-- computed only when the QP shows a violation (clean files skip the cost).
--
-- Config: BIG=1e3 + recipe_epsilon=2^-6*BIG/1e6 (the answer-preserving conditioning
-- fix), KAPPA=1e2, IMPMULT=100, ITERS=5, EPS=BIG*1e-6.

local TIER = (os.getenv("FS_TIER") or "soft"):lower()
local BIG = tonumber(os.getenv("FS_BIG")) or 1e3
local KAPPA, IMPMULT, ITERS = 1e2, 100, 5
local EPS = BIG * 1e-6
local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }
local NAME = (arg[1] or "?"):match("[^/\\]+$") or "?"

local ok, line = pcall(function()
    require "tests/headless_env"
    local create_problem = require "solver/create_problem"
    local problem_dump = require "tests/problem_dump"
    local reference = require "tests/research/reference_solver"
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

    -- stage 1: QP -> r_q (ratio-preserving recipe_epsilon)
    local pq = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil,
        { recipe_epsilon = (2 ^ -6) * BIG / 1e6 })
    for key, p in pairs(pq.primals) do
        if VIO[p.kind] then p.cost = 0; pq:set_quad(key, 2)
        elseif FREEK[p.kind] then p.cost = 0; pq:set_quad(key, 0) end
    end
    remove_targets(pq); reindex(pq)
    local xq, stq = solve(pq)

    local recipe_keys, vio_keys, kind_of, mat_of = {}, {}, {}, {}
    for k, p in pairs(pq.primals) do
        if p.kind == "recipe" or p.kind == "bridge" then recipe_keys[#recipe_keys + 1] = k
        elseif VIO[p.kind] then vio_keys[#vio_keys + 1] = k; kind_of[k] = p.kind; mat_of[k] = p.material end
    end
    local rq, maxr = {}, 0
    for _, k in ipairs(recipe_keys) do rq[k] = math.abs(xq[k] or 0); if rq[k] > maxr then maxr = rq[k] end end
    local THR = math.max(1e-9, maxr * 1e-6)
    local RFLOOR = math.max(THR, maxr * 1e-3)

    -- producibility / consumability fixpoints -- only when there is a violation.
    local function nesc(x) local n = 0 for _, k in ipairs(vio_keys) do if math.abs(x[k] or 0) > THR then n = n + 1 end end return n end
    local producible, consumable = {}, {}
    local has_viol = stq == "finished" and nesc(xq) > 0
    if has_viol then
        producible = reference.producible_set(prob.constraints, prob.normalized_lines)
        consumable = reference.consumable_set(prob.constraints, prob.normalized_lines)
    end

    -- escape base weight by tier
    local function base_of(key)
        local kind, mat = kind_of[key], mat_of[key]
        if TIER == "lex" then
            if kind == "shortage_source" then return producible[mat] and 1e6 or 1e3
            else return consumable[mat] and 1 or 1e-2 end
        else
            return (kind == "shortage_source") and IMPMULT or 1
        end
    end

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

    local xprev, xc, stc = xq, xq, "n/a"
    if has_viol then
        for _ = 1, ITERS do
            local w = {}
            for _, k in ipairs(vio_keys) do w[k] = base_of(k) / (math.abs(xprev[k] or 0) + EPS) end
            local x, s = solve(build(w))
            xc, stc, xprev = x, s, x
        end
    else
        stc = stq
    end

    -- split Vp / Vf / Vc (problem-definition terms)
    local function split(x)
        local esc, vp, vf, vc = 0, 0, 0, 0
        for _, k in ipairs(vio_keys) do
            local v = math.abs(x[k] or 0)
            if v > THR then esc = esc + 1 end
            if kind_of[k] == "shortage_source" then
                if producible[mat_of[k]] then vp = vp + v else vf = vf + v end
            else
                if consumable[mat_of[k]] then vc = vc + v end
            end
        end
        return esc, vp, vf, vc
    end
    local qe, qvp, qvf, qvc = split(xq)
    local ce, cvp, cvf, cvc = split(xc)
    return string.format(
        "RESULT\tname=%s\ttier=%s\tqp_state=%s\tc_state=%s\tqp_esc=%d\tc_esc=%d\tqp_vp=%.6g\tqp_vf=%.6g\tqp_vc=%.6g\tc_vp=%.6g\tc_vf=%.6g\tc_vc=%.6g",
        NAME, TIER, stq, stc, qe, ce, qvp, qvf, qvc, cvp, cvf, cvc)
end)

io.write((ok and line or string.format("RESULT\tname=%s\ttier=%s\tqp_state=error\tc_state=error\terr=%s",
    NAME, TIER, tostring(line):gsub("%s+", " "):sub(1, 100))) .. "\n")
