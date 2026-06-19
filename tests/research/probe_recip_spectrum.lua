---@diagnostic disable: undefined-global
-- Reciprocal-amount probe. Sibling of probe_amount_spectrum.lua: same lp/qp/ref
-- anchors, but adds two middle approaches that bake the QP solution x_q into the
-- escape amount coefficient in OPPOSITE directions, graded in PHYSICAL space on the
-- reference yardstick (Nv, Vp/Vf/Vc):
--   amt   a_k = x_q[k]        -> physical-cost weight q/a^2 ~ 1/x_q^2  (large violations CHEAP -> concentrate, L1-ward)
--   rec   a_k = 1/max(x_q,fl) -> physical-cost weight q/a^2 ~ x_q^2    (large violations HEAVY -> equalize, Linf-ward)
-- The question (user's "balance" intent): does rec push large imports DOWN toward
-- fabricate/spread (more practical), or does it over-kill genuine raw imports
-- (infeasible / over-fabricate)?  Empirical, no verdict label.
--
-- inactive escapes (x_q ~ 0) get a 1/x_q blow-up, so x_q is floored at
-- REC_FLOOR * max active x_q before the reciprocal (keeps their weight nonzero =
-- no free-wash). FS_REC_FLOOR overrides (default 1e-2).
--
--   lua tests/research/probe_recip_spectrum.lua <dump>

local BIG = 1e3
local EPS = BIG * 1e-6
local QUAD0 = 2
local FLOOR = 1e-9
local REC_FLOOR = tonumber(os.getenv("FS_REC_FLOOR")) or 1e-2
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

    local entry = refcache.load(arg[1])
    if not entry then
        local r = ref.solve_reference(prob.constraints, prob.normalized_lines)
        local Nv = (r.state == "finished" and r.x) and ref.violation_count(r.problem, r.x, intermediates) or -1
        entry = { state = r.state, Vp = r.Vp, Vc = r.Vc, Vf = r.Vf, Nv = Nv,
            producible = setlist(r.producible), consumable = setlist(r.consumable) }
        refcache.store(arg[1], entry)
    end
    local producible, consumable = listset(entry.producible), listset(entry.consumable)

    local function big_targets(problem)
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
    -- grade in physical space: physical p = (scaled balance coeff) * value
    local function measure(problem, x)
        local xphys = {}
        for key, p in pairs(problem.primals) do
            if VIO[p.kind] then
                local terms = problem.subject_terms[key]
                local coeff = (p.material and terms and terms[p.material]) or 1
                xphys[key] = math.abs(coeff) * math.abs(x[key] or 0)
            else xphys[key] = x[key] or 0 end
        end
        local Nv = ref.violation_count(problem, xphys, intermediates)
        local Vp, Vc, Vf = ref.violation_split(problem, xphys, intermediates, producible, consumable)
        return Nv, Vp, Vc, Vf
    end

    -- plainLP (L1)
    local plp = create_problem.create_problem("lp", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(plp.primals) do
        if VIO[p.kind] then p.cost = 1 elseif FREEK[p.kind] then p.cost = 0 end
    end
    big_targets(plp); reindex(plp)
    local xlp, slp = solve(plp)
    local Nv_lp, Vp_lp, Vc_lp, Vf_lp = -1, -1, -1, -1
    if slp == "finished" then Nv_lp, Vp_lp, Vc_lp, Vf_lp = measure(plp, xlp) end

    -- QP (L2)
    local pq = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil,
        { recipe_epsilon = (2 ^ -6) * BIG / 1e6 })
    for key, p in pairs(pq.primals) do
        if VIO[p.kind] then p.cost = 0; pq:set_quad(key, QUAD0)
        elseif FREEK[p.kind] then p.cost = 0; pq:set_quad(key, 0) end
    end
    big_targets(pq); reindex(pq)
    local xq, stq = solve(pq)
    local Nv_qp, Vp_qp, Vc_qp, Vf_qp = -1, -1, -1, -1
    if stq == "finished" then Nv_qp, Vp_qp, Vc_qp, Vf_qp = measure(pq, xq) end

    -- max active x_q over escapes (for the reciprocal floor)
    local maxxq = 0
    for key, p in pairs(pq.primals) do
        if VIO[p.kind] then local v = math.abs(xq[key] or 0); if v > maxxq then maxxq = v end end
    end
    local rfloor = math.max(1e-12, maxxq * REC_FLOOR)

    -- build a quad problem whose escape amounts are scaled by scale_fn(key)
    local function build_scaled(scale_fn)
        local problem = create_problem.create_problem("sc", prob.constraints, prob.normalized_lines, nil,
            { recipe_epsilon = (2 ^ -6) * BIG / 1e6 })
        for key, p in pairs(problem.primals) do
            if VIO[p.kind] then
                p.cost = 0; problem:set_quad(key, QUAD0)
                local a = scale_fn(key)
                local terms = problem.subject_terms[key]
                if terms then for dual, coeff in pairs(terms) do terms[dual] = coeff * a end end
            elseif FREEK[p.kind] then p.cost = 0; problem:set_quad(key, 0) end
        end
        big_targets(problem); reindex(problem)
        return problem
    end

    -- amt: a = x_q (floored), large violations cheap
    local pa = build_scaled(function(key) local s = math.abs(xq[key] or 0); return s < FLOOR and FLOOR or s end)
    local xa, sta = solve(pa)
    local Nv_a, Vp_a, Vc_a, Vf_a = -1, -1, -1, -1
    if sta == "finished" then Nv_a, Vp_a, Vc_a, Vf_a = measure(pa, xa) end

    -- rec: a = 1/x_q on ACTIVE escapes (heavy cost on large), inactive left at base
    -- (a=1) so the 1/x_q blow-up can't turn near-0 escapes into cheap high-leverage
    -- free-wash channels. Active = x_q above REC_FLOOR * max active x_q.
    local pr = build_scaled(function(key)
        local s = math.abs(xq[key] or 0)
        if s > rfloor then return 1 / s else return 1 end
    end)
    local xr, str = solve(pr)
    local Nv_r, Vp_r, Vc_r, Vf_r = -1, -1, -1, -1
    if str == "finished" then Nv_r, Vp_r, Vc_r, Vf_r = measure(pr, xr) end

    return string.format("RESULT\tname=%s\tref_state=%s\tlp_state=%s\tqp_state=%s\tamt_state=%s\trec_state=%s"
        .. "\tNv_ref=%s\tVp_ref=%.6g\tVc_ref=%.6g\tVf_ref=%.6g"
        .. "\tNv_lp=%d\tVp_lp=%.6g\tVc_lp=%.6g\tVf_lp=%.6g"
        .. "\tNv_qp=%d\tVp_qp=%.6g\tVc_qp=%.6g\tVf_qp=%.6g"
        .. "\tNv_amt=%d\tVp_amt=%.6g\tVc_amt=%.6g\tVf_amt=%.6g"
        .. "\tNv_rec=%d\tVp_rec=%.6g\tVc_rec=%.6g\tVf_rec=%.6g",
        NAME, entry.state, slp, stq, sta, str,
        tostring(entry.Nv), entry.Vp, entry.Vc, entry.Vf,
        Nv_lp, Vp_lp, Vc_lp, Vf_lp, Nv_qp, Vp_qp, Vc_qp, Vf_qp,
        Nv_a, Vp_a, Vc_a, Vf_a, Nv_r, Vp_r, Vc_r, Vf_r)
end)

io.write((ok and line or string.format("RESULT\tname=%s\tref_state=error\terr=%s",
    NAME, tostring(line):gsub("%s+", " "):sub(1, 100))) .. "\n")
