---@diagnostic disable: undefined-global
-- SINGLE-SHOT: a LIGHTWEIGHT reinvention of the reference, pure LP only.
-- The reference's cost is dominated by the producible/consumable greatest
-- fixpoints (~65s/file). This drops them entirely: a pure-LP IRL1 cascade at the
-- REAL targets (so it converges without the QP conditioning hacks, and compares to
-- the reference at the SAME scale -> absolute Vp/Vc/M are directly comparable).
--   each iter (pure LP): escape cost = base/(|esc_prev|+EPS), base=IMPMULT on
--   imports (drive avoidable defeats to fabrication, keep the structurally forced
--   makeup), 1 on dumps; recipes carry only the tie-break. IRL1 over K iters
--   concentrates the escapes. No QP, no fixpoint -> K LP solves total.
-- Measured against the reference (cached) with the definition yardstick + the
-- participation-ratio dispersion. The question: how close to ref quality, how cheap.
--
--   lua tests/research/lightweight_ref.lua <dump> [K] [IMPMULT]

local K = tonumber(arg[2]) or 8
local IMPMULT = tonumber(arg[3]) or 100
local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }
local REC = { recipe = true, bridge = true }
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

    local function hard_targets(problem)  -- real targets, hard equality
        local rm = {}
        for _, c in ipairs(prob.constraints) do
            local dual = vk.limit(tn.typed_name_to_variable_name(c))
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

    local vio_keys, kind_of = {}, {}
    do
        local p0 = create_problem.create_problem("scan", prob.constraints, prob.normalized_lines, nil, nil)
        for k, p in pairs(p0.primals) do if VIO[p.kind] then vio_keys[#vio_keys + 1] = k; kind_of[k] = p.kind end end
    end
    local function base(k) return (kind_of[k] == "shortage_source") and IMPMULT or 1 end

    local function build(weights)  -- pure LP, no quad
        local problem = create_problem.create_problem("lwr", prob.constraints, prob.normalized_lines, nil, nil)
        for key, p in pairs(problem.primals) do
            if VIO[p.kind] then p.cost = weights[key] or base(key)
            elseif FREEK[p.kind] then p.cost = 0 end
        end
        hard_targets(problem); reindex(problem)
        return problem
    end

    -- iter 1: uniform import-weighted L1 (the cheat-resistant starting LP)
    local x, st = solve(build({}))
    local solves, EPS = 1, nil
    if st == "finished" then
        local maxe = 0
        for _, k in ipairs(vio_keys) do local v = math.abs(x[k] or 0); if v > maxe then maxe = v end end
        EPS = math.max(1e-9, maxe * 1e-4)
        for _ = 2, K do
            if st ~= "finished" then break end
            local w = {}
            for _, k in ipairs(vio_keys) do w[k] = base(k) / (math.abs(x[k] or 0) + EPS) end
            x, st = solve(build(w)); solves = solves + 1
        end
    end

    -- measure final vs reference
    local prob_final = build({})  -- structural copy for measurement (kinds/materials)
    local function disp_esc(pp, xx)
        local s, s2 = 0, 0
        for k, p in pairs(pp.primals) do if VIO[p.kind] then local v = math.abs(xx[k] or 0); s = s + v; s2 = s2 + v * v end end
        return (s2 > 0) and (s * s / s2) or 0
    end
    local Nv_l, Vp_l, Vc_l, Vf_l, M_l, PRe_l = -1, -1, -1, -1, -1, -1
    if st == "finished" then
        Nv_l = ref.violation_count(prob_final, x, intermediates)
        Vp_l, Vc_l, Vf_l = ref.violation_split(prob_final, x, intermediates, producible, consumable)
        M_l = ref.total_of(prob_final, x, ref.MACHINE_KINDS)
        PRe_l = disp_esc(prob_final, x)
    end

    return string.format(
        "RESULT\tname=%s\tref_state=%s\tlw_state=%s\tsolves=%d"
        .. "\tNv_ref=%s\tVp_ref=%.6g\tVc_ref=%.6g\tVf_ref=%.6g\tM_ref=%.6g\tref_steps=%s"
        .. "\tNv_lw=%d\tVp_lw=%.6g\tVc_lw=%.6g\tVf_lw=%.6g\tM_lw=%.6g\tPResc_lw=%.4g",
        NAME, entry.state, st, solves,
        tostring(entry.Nv), entry.Vp, entry.Vc, entry.Vf, entry.M, tostring(entry.steps),
        Nv_l, Vp_l, Vc_l, Vf_l, M_l, PRe_l)
end)

io.write((ok and line or string.format("RESULT\tname=%s\tref_state=error\terr=%s",
    NAME, tostring(line):gsub("%s+", " "):sub(1, 100))) .. "\n")
