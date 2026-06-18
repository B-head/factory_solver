---@diagnostic disable: undefined-global
-- SINGLE-SHOT: quantify DISPERSION (the L2-interior "spread" that escape COUNT
-- Nv hides) for the four approaches. The handle-ability question is not "how many
-- escapes cross a threshold" but "is the flow concentrated on a few variables (a
-- clean vertex) or smeared across many (a dispersed interior point)".
-- Participation ratio PR = (sum|x|)^2 / sum(x^2) = the EFFECTIVE number of active
-- variables (1 if all mass on one, N if N equal); scale-free. Measured on recipes
-- AND escapes for plainLP (L1 vertex) / QP (least-norm interior) / cons / ref.
-- Also the escape "smear": nonzero-but-sub-threshold escapes Nv never counts.
--
--   lua tests/research/consolidate_dispersion.lua <dump>

local BIG = 1e3
local KAPPA, IMPMULT, ITERS = 1e2, 100, 5
local EPS = BIG * 1e-6
local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }
local REC = { recipe = true, bridge = true }
local NAME = (arg[1] or "?"):match("[^/\\]+$") or "?"

local ok, line = pcall(function()
    require "tests/headless_env"
    local create_problem = require "solver/create_problem"
    local problem_dump = require "tests/problem_dump"
    local ref = require "tests/research/reference_solver"
    local tn = require "manage/typed_name"
    local vk = require "solver/var_key"
    local lp = require "solver/linear_programming"
    local prob = assert(problem_dump.load_problem(arg[1]))

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

    -- PR + counts for recipes and escapes (scale-free dispersion).
    local function disp(problem, x)
        local sr, sr2, mr = 0, 0, 0
        for k, p in pairs(problem.primals) do if REC[p.kind] then
            local v = math.abs(x[k] or 0); sr = sr + v; sr2 = sr2 + v * v; if v > mr then mr = v end end end
        local thr = math.max(1e-12, mr * 1e-6)
        local dust = math.max(1e-15, mr * 1e-12)
        local nrec, PRr = 0, (sr2 > 0) and (sr * sr / sr2) or 0
        for k, p in pairs(problem.primals) do if REC[p.kind] and math.abs(x[k] or 0) > thr then nrec = nrec + 1 end end
        local se, se2, na, nz = 0, 0, 0, 0
        for k, p in pairs(problem.primals) do if VIO[p.kind] then
            local v = math.abs(x[k] or 0); se = se + v; se2 = se2 + v * v
            if v > thr then na = na + 1 end; if v > dust then nz = nz + 1 end end end
        local PRe = (se2 > 0) and (se * se / se2) or 0
        return nrec, PRr, na, nz, PRe
    end

    -- plainLP (L1 vertex)
    local plp = create_problem.create_problem("lp", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(plp.primals) do if VIO[p.kind] then p.cost = 1 elseif FREEK[p.kind] then p.cost = 0 end end
    big_targets(plp); reindex(plp)
    local xlp, slp = solve(plp)

    -- QP least-norm
    local pq = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil,
        { recipe_epsilon = (2 ^ -6) * BIG / 1e6 })
    for key, p in pairs(pq.primals) do
        if VIO[p.kind] then p.cost = 0; pq:set_quad(key, 2)
        elseif FREEK[p.kind] then p.cost = 0; pq:set_quad(key, 0) end
    end
    big_targets(pq); reindex(pq)
    local xq, stq = solve(pq)

    -- consolidation
    local recipe_keys, vio_keys, kind_of = {}, {}, {}
    for k, p in pairs(pq.primals) do
        if REC[p.kind] then recipe_keys[#recipe_keys + 1] = k
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
        big_targets(problem); reindex(problem)
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
        local p = build(w); local x, s = solve(p); pc, xc, stc, xprev = p, x, s, x
    end

    -- reference (fresh: need its solution vector for dispersion)
    local r = ref.solve_reference(prob.constraints, prob.normalized_lines)

    local function row(tag, problem, x, st)
        if st ~= "finished" or not problem then return string.format("%s=NA", tag) end
        local nr, PRr, na, nz, PRe = disp(problem, x)
        return string.format("%s_nrec=%d\t%s_PRrec=%.4g\t%s_Nv=%d\t%s_esnz=%d\t%s_PResc=%.4g",
            tag, nr, tag, PRr, tag, na, tag, nz, tag, PRe)
    end

    return string.format("RESULT\tname=%s\t%s\t%s\t%s\t%s",
        NAME,
        row("lp", plp, xlp, slp),
        row("qp", pq, xq, stq),
        row("c", pc, xc, stc),
        row("ref", r.problem, r.x, r.state))
end)

io.write((ok and line or string.format("RESULT\tname=%s\terr=%s", NAME, tostring(line):gsub("%s+", " "):sub(1, 100))) .. "\n")
