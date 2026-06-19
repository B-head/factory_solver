---@diagnostic disable: undefined-global
-- SINGLE-SHOT: place the "amount-baked QP" on the cheat->ideal axis, measured
-- with the reference yardstick (Nv escape count, Vp/Vf/Vc split). Sibling of
-- consolidate_spectrum.lua -- same plainLP / qp / ref anchors, but the middle
-- approach is:
--   amt   solve QP (least-norm) -> x_q, then bake a_k = a_k * x_q[k] into every
--         elastic escape's subject terms (amount_per_second lever) and RE-SOLVE
--         the SAME quadratic. The question is which DIRECTION this re-solve moves:
--         toward the ideal (ref: tiny Vp, low Nv) or toward the cheat (plainLP:
--         sparse, Vp-heavy)?
--
-- The amt solution is graded in PHYSICAL space: the re-solve scales the escape
-- coefficients, so its variable values are ~normalized and NOT the physical
-- import/dump amounts. violation_count/split read x[key] directly, so amt's x is
-- converted to physical (coeff * value) before measuring, keeping it comparable to
-- plainLP/qp/ref (whose escape coeff is 1, so value == physical).
--
--   plainLP  L1 linear escapes (sparse vertex = the cheat baseline)
--   qp       least-norm QP (the amount-bake's starting point)
--   amt      QP then a_k=x_q re-solve (the approach under test)
--   ref      lexicographic gold (ideal)                         [cached]
-- plainLP/qp/amt at BIG=1e3 (converging regime); ref at real targets. Nv and the
-- defeat fraction Vp/(Vp+Vf+Vc) are scale-free; absolute magnitudes are not.
--
--   lua tests/research/probe_amount_spectrum.lua <dump>

local BIG = 1e3
local EPS = BIG * 1e-6
local QUAD0 = 2
local FLOOR = 1e-9
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
        entry = { state = r.state, n_mats = r.n_mats, T = r.T, Vp = r.Vp, Vc = r.Vc, Vf = r.Vf, M = r.M,
            S = r.S, Nv = Nv, steps = r.steps, producible = setlist(r.producible), consumable = setlist(r.consumable) }
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
    local function measure(problem, x)
        local Nv = ref.violation_count(problem, x, intermediates)
        local Vp, Vc, Vf = ref.violation_split(problem, x, intermediates, producible, consumable)
        return Nv, Vp, Vc, Vf
    end

    -- plainLP: L1 linear escapes, no quad (the sparse cheat)
    local plp = create_problem.create_problem("lp", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(plp.primals) do
        if VIO[p.kind] then p.cost = 1 elseif FREEK[p.kind] then p.cost = 0 end
    end
    big_targets(plp); reindex(plp)
    local xlp, slp = solve(plp)
    local Nv_lp, Vp_lp, Vc_lp, Vf_lp = -1, -1, -1, -1
    if slp == "finished" then Nv_lp, Vp_lp, Vc_lp, Vf_lp = measure(plp, xlp) end

    -- QP least-norm (amount-bake start)
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

    -- amount-baked: a_k = a_k * x_q[k] on every elastic escape, same quad, re-solve
    local pa = create_problem.create_problem("amt", prob.constraints, prob.normalized_lines, nil,
        { recipe_epsilon = (2 ^ -6) * BIG / 1e6 })
    for key, p in pairs(pa.primals) do
        if VIO[p.kind] then
            p.cost = 0; pa:set_quad(key, QUAD0)
            local s = math.max(0, xq[key] or 0); if s < FLOOR then s = FLOOR end
            local terms = pa.subject_terms[key]
            if terms then for dual, coeff in pairs(terms) do terms[dual] = coeff * s end end
        elseif FREEK[p.kind] then p.cost = 0; pa:set_quad(key, 0) end
    end
    big_targets(pa); reindex(pa)
    local xa, sta = solve(pa)
    -- convert amt variable values -> physical amounts (coeff * value) on escapes;
    -- recipes / free sources are unscaled, so copy through.
    local x_phys = {}
    for key, p in pairs(pa.primals) do
        if VIO[p.kind] then
            local terms = pa.subject_terms[key]
            local coeff = (p.material and terms and terms[p.material]) or 1
            x_phys[key] = math.abs(coeff) * math.abs(xa[key] or 0)
        else
            x_phys[key] = xa[key] or 0
        end
    end
    local Nv_a, Vp_a, Vc_a, Vf_a = -1, -1, -1, -1
    if sta == "finished" then Nv_a, Vp_a, Vc_a, Vf_a = measure(pq, x_phys) end

    return string.format("RESULT\tname=%s\tref_state=%s\tlp_state=%s\tqp_state=%s\tamt_state=%s"
        .. "\tNv_ref=%s\tVp_ref=%.6g\tVc_ref=%.6g\tVf_ref=%.6g"
        .. "\tNv_lp=%d\tVp_lp=%.6g\tVc_lp=%.6g\tVf_lp=%.6g"
        .. "\tNv_qp=%d\tVp_qp=%.6g\tVc_qp=%.6g\tVf_qp=%.6g"
        .. "\tNv_amt=%d\tVp_amt=%.6g\tVc_amt=%.6g\tVf_amt=%.6g",
        NAME, entry.state, slp, stq, sta,
        tostring(entry.Nv), entry.Vp, entry.Vc, entry.Vf,
        Nv_lp, Vp_lp, Vc_lp, Vf_lp, Nv_qp, Vp_qp, Vc_qp, Vf_qp, Nv_a, Vp_a, Vc_a, Vf_a)
end)

io.write((ok and line or string.format("RESULT\tname=%s\tref_state=error\terr=%s",
    NAME, tostring(line):gsub("%s+", " "):sub(1, 100))) .. "\n")
