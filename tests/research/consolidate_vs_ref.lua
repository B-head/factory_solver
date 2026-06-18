---@diagnostic disable: undefined-global
-- SINGLE-SHOT corpus driver: recipe-anchor consolidation vs the problem-definition
-- REFERENCE, measured with the SAME yardstick (reference_solver's Nv escape count,
-- Vp/Vf/Vc violation split, M machine count). Both solve the REAL targets (hard
-- equality), so the numbers are comparable. The reference is the lexicographic
-- gold answer (optimal Vp>>Vf>>Vc>>M); the question is whether consolidation buys
-- fewer escapes (Nv) and at what Vp/Vf/Vc cost. RAW numbers only.
--
--   lua tests/research/consolidate_vs_ref.lua <dump>

-- Reference solves REAL targets (its Nv escape count is scale-invariant, so it is
-- directly comparable). The consolidation needs BIG=1e3 + ratio-preserving
-- recipe_epsilon to converge (real-target scale makes its stage-2 recipe quad
-- ill-conditioned). We compare Nv (counts, scale-free) and the Vp:Vf:Vc
-- composition (fractions, scale-free); absolute violation magnitudes are NOT
-- comparable across the two target scales and are reported raw with that caveat.
local BIG = 1e3
local KAPPA, IMPMULT, ITERS = 1e2, 100, 5
local EPS = BIG * 1e-6
local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }
local NAME = (arg[1] or "?"):match("[^/\\]+$") or "?"

local function setlist(s) local t = {} for k in pairs(s) do t[#t + 1] = k end table.sort(t) return t end
local function listset(l) local s = {} for _, k in ipairs(l or {}) do s[k] = true end return s end

local ok, line = pcall(function()
    require "tests/headless_env"
    local create_problem = require "solver/create_problem"
    local problem_dump = require "tests/problem_dump"
    local ref = require "tests/research/reference_solver"
    local refcache = require "tests/research/reference_cache"
    local tn = require "manage/typed_name"
    local vk = require "solver/var_key"
    local lp = require "solver/linear_programming"
    local prob = assert(problem_dump.load_problem(arg[1]))
    local intermediates = ref.intermediates(prob.normalized_lines)

    -- reference (cached): tiers + producible/consumable + Nv
    local entry = refcache.load(arg[1])
    if not entry then
        local r = ref.solve_reference(prob.constraints, prob.normalized_lines)
        local Nv = (r.state == "finished" and r.x) and ref.violation_count(r.problem, r.x, intermediates) or -1
        entry = { state = r.state, n_mats = r.n_mats, T = r.T, Vp = r.Vp, Vc = r.Vc, Vf = r.Vf, M = r.M,
            S = r.S, Nv = Nv, steps = r.steps, producible = setlist(r.producible), consumable = setlist(r.consumable) }
        refcache.store(arg[1], entry)
    end
    local producible, consumable = listset(entry.producible), listset(entry.consumable)

    -- consolidation targets: hard equality at BIG (the converging conditioning
    -- regime); reference is real-target but Nv/composition stay comparable.
    local function hard_targets(problem)
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

    -- stage 1 QP -> r_q  (recipe_epsilon scales with BIG: the answer-preserving fix)
    local pq = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil,
        { recipe_epsilon = (2 ^ -6) * BIG / 1e6 })
    for key, p in pairs(pq.primals) do
        if VIO[p.kind] then p.cost = 0; pq:set_quad(key, 2)
        elseif FREEK[p.kind] then p.cost = 0; pq:set_quad(key, 0) end
    end
    hard_targets(pq); reindex(pq)
    local xq, stq = solve(pq)

    local recipe_keys, vio_keys, kind_of = {}, {}, {}
    for k, p in pairs(pq.primals) do
        if p.kind == "recipe" or p.kind == "bridge" then recipe_keys[#recipe_keys + 1] = k
        elseif VIO[p.kind] then vio_keys[#vio_keys + 1] = k; kind_of[k] = p.kind end
    end
    local rq, maxr = {}, 0
    for _, k in ipairs(recipe_keys) do rq[k] = math.abs(xq[k] or 0); if rq[k] > maxr then maxr = rq[k] end end
    local RFLOOR = math.max(1e-9, maxr * 1e-3)

    local function build(weights)
        local problem = create_problem.create_problem("anc", prob.constraints, prob.normalized_lines, nil, nil)
        for key, p in pairs(problem.primals) do
            if VIO[p.kind] then p.cost = weights[key] or (1 / EPS)
            elseif FREEK[p.kind] then p.cost = 0 end
        end
        hard_targets(problem); reindex(problem)
        for _, k in ipairs(recipe_keys) do
            local p = problem.primals[k]
            if p then local t = rq[k] or 0; local kqv = KAPPA / (math.max(t, RFLOOR) ^ 2)
                problem:set_quad(k, kqv); p.cost = -kqv * t end
        end
        return problem
    end

    local xprev, pc, xc, stc = xq, pq, xq, stq
    for _ = 1, ITERS do
        local w = {}
        for _, k in ipairs(vio_keys) do
            local base = (kind_of[k] == "shortage_source") and IMPMULT or 1
            w[k] = base / (math.abs(xprev[k] or 0) + EPS)
        end
        local p = build(w); local x, s = solve(p)
        pc, xc, stc, xprev = p, x, s, x
    end

    local Nv_c, Vp_c, Vc_c, Vf_c, M_c = -1, -1, -1, -1, -1
    if stc == "finished" then
        Nv_c = ref.violation_count(pc, xc, intermediates)
        Vp_c, Vc_c, Vf_c = ref.violation_split(pc, xc, intermediates, producible, consumable)
        M_c = ref.total_of(pc, xc, ref.MACHINE_KINDS)
    end

    return string.format(
        "RESULT\tname=%s\tref_state=%s\tNv_ref=%s\tVp_ref=%.6g\tVc_ref=%.6g\tVf_ref=%.6g\tM_ref=%.6g"
        .. "\tqp_state=%s\tc_state=%s\tNv_c=%d\tVp_c=%.6g\tVc_c=%.6g\tVf_c=%.6g\tM_c=%.6g",
        NAME, entry.state, tostring(entry.Nv), entry.Vp, entry.Vc, entry.Vf, entry.M,
        stq, stc, Nv_c, Vp_c, Vc_c, Vf_c, M_c)
end)

io.write((ok and line or string.format("RESULT\tname=%s\tref_state=error\tc_state=error\terr=%s",
    NAME, tostring(line):gsub("%s+", " "):sub(1, 100))) .. "\n")
