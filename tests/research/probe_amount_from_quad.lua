---@diagnostic disable: undefined-global
-- "Bake the QP solution into amount_per_second, re-solve the SAME QP" probe.
--
-- Sibling of probe_tilt_from_quad.lua. That one took x_q and put it on the LINEAR
-- cost (c' = q*x_q, the gradient) -- verdict: curvature can't ride a linear cost,
-- the point isn't reproduced. This one instead puts x_q on the CONSTRAINT
-- coefficient a (the amount_per_second the synthetic escape contributes to its
-- balance/limit rows), and re-solves with the SAME uniform quadratic cost.
--
-- PASS Q (QP): uniform (QUAD0/2)*x^2 on the elastic escapes (shortage_source +
--   surplus_sink); initial/final FREE; hard targets at BIG. Solve -> x_q.
--
-- PASS A (amount-baked QP): rebuild the SAME structure (same QUAD0 on the escapes),
--   but scale every elastic escape's subject terms by a_k' = a_k * x_q[k] (the
--   amount_lever: a synthetic source's amount_per_second is free; here it is set
--   from the QP solution). Same quadratic cost. Solve -> x_a.
--
-- What this is, algebraically: with a_k' = a_k*x_q and quad on the VARIABLE x, the
-- physical import p_k = a_k' * x_k = (a_k x_q) x_k and the objective is sum x_k^2 =
-- sum (p_k / (a_k x_q))^2 -- i.e. a weighted least-norm on the PHYSICAL imports
-- with weight 1/(a_k x_q)^2. Escapes already large in x_q get a tiny weight, so
-- physical mass is cheap to pile there. So this is ONE reweighting step (toward
-- sparser/concentrated, IRLS-flavoured) and the question is which way the physical
-- solution and the recipe activity move relative to the even-split x_q.
--
--   luajit tests/research/probe_amount_from_quad.lua [dumpfile] [BIG]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e6
local QUAD0 = 2
local FLOOR = 1e-9 -- coeff floor so a near-0 x_q escape becomes an inert (not literally zero) column

local ELASTIC = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }

local prob = assert(problem_dump.load_problem(PATH))

-- common reduction shared by all passes: hard-equality targets at BIG, strip
-- target elastic/headroom + slacks, reindex primals contiguously.
local function strip_and_reindex(problem)
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

local function build_qp()
    local problem = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if ELASTIC[p.kind] then p.cost = 0; problem:set_quad(key, QUAD0)
        elseif FREEK[p.kind] then p.cost = 0; problem:set_quad(key, 0) end
    end
    strip_and_reindex(problem)
    return problem
end

-- bake x_q into the amount coefficient: a_k -> a_k * x_q[k] on ALL subject terms
-- of each elastic escape (balance + limit + bare_limit, the way amount_lever does).
-- Same quadratic cost. near-0 x_q escapes keep an inert FLOOR coeff (not a literal
-- zero column).
local function build_amount(xq)
    local problem = create_problem.create_problem("aq", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if ELASTIC[p.kind] then
            p.cost = 0; problem:set_quad(key, QUAD0)
            local s = math.max(0, xq[key] or 0)
            if s < FLOOR then s = FLOOR end
            local terms = problem.subject_terms[key]
            if terms then for dual, coeff in pairs(terms) do terms[dual] = coeff * s end end
        elseif FREEK[p.kind] then
            p.cost = 0; problem:set_quad(key, 0)
        end
    end
    strip_and_reindex(problem)
    return problem
end

-- bake the QP-ACTIVE escapes (a_k -> a_k*x_q), and DELETE the QP-near-0 ones
-- outright (vs. floored). Mirrors tilt_from_quad's tilt_delete: tests whether
-- removing the free-wash columns rather than flooring them changes the result.
local function build_amount_delete(xq, thr)
    local problem = create_problem.create_problem("ad", prob.constraints, prob.normalized_lines, nil, nil)
    local rm = {}
    for key, p in pairs(problem.primals) do
        if ELASTIC[p.kind] then
            local s = math.max(0, xq[key] or 0)
            if s > thr then
                p.cost = 0; problem:set_quad(key, QUAD0)
                local terms = problem.subject_terms[key]
                if terms then for dual, coeff in pairs(terms) do terms[dual] = coeff * s end end
            else
                rm[key] = true
            end
        elseif FREEK[p.kind] then
            p.cost = 0; problem:set_quad(key, 0)
        end
    end
    for key in pairs(rm) do problem.primals[key] = nil; problem.subject_terms[key] = nil end
    strip_and_reindex(problem)
    return problem
end

local function solve(problem)
    local state, it, vars, last, steps = "ready", nil, nil, nil, 0
    repeat
        local ok, s, i2, v = pcall(lp.solve, problem, state, it, vars, prob.meta.tolerance, prob.meta.iterate_limit)
        if not ok then state = "errored"; break end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
    return (last and last.x) or {}, state, steps
end

local function park_threshold(problem, x)
    local maxr = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
    return math.max(1e-9, maxr * 1e-6)
end

-- physical contribution of an escape = its balance-row coefficient * value.
-- the balance dual key is the escape's .material (see create_problem add_objective).
local function phys(problem, key, x)
    local p = problem.primals[key]
    local terms = problem.subject_terms[key]
    local coeff = (p and p.material and terms and terms[p.material]) or 0
    return math.abs(coeff * (x[key] or 0))
end

-- ============================================================================
local pQ = build_qp()
local xQ, stQ, stepsQ = solve(pQ)
local thrQ = park_threshold(pQ, xQ)

local pA = build_amount(xQ)
local xA, stA, stepsA = solve(pA)

local pD = build_amount_delete(xQ, thrQ)
local xD, stD, stepsD = solve(pD)

-- masses (variable space) and physical (constraint space) per pass --------------
local function summarize(problem, x)
    local var_e, var_r = 0, 0          -- escape variable mass, recipe mass
    local phys_sh, phys_su = 0, 0       -- physical shortage import, physical surplus dump
    for k, p in pairs(problem.primals) do
        if ELASTIC[p.kind] then
            var_e = var_e + math.abs(x[k] or 0)
            if p.kind == "shortage_source" then phys_sh = phys_sh + phys(problem, k, x)
            else phys_su = phys_su + phys(problem, k, x) end
        elseif p.kind == "recipe" then
            var_r = var_r + math.abs(x[k] or 0)
        end
    end
    return var_e, var_r, phys_sh, phys_su
end

local veQ, vrQ, shQ, suQ = summarize(pQ, xQ)
local veA, vrA, shA, suA = summarize(pA, xA)
local veD, vrD, shD, suD = summarize(pD, xD)

io.write("============ AMOUNT-BAKED FROM QP (re-solve same QP with a_k = x_q) ============\n")
io.write(string.format("file=%s  BIG=%g  quad=%g  floor=%g\n", PATH:match("[^/]+$"), BIG, QUAD0, FLOOR))
io.write(string.format("PASS Q (uniform quad)            : state=%s steps=%d  thr=%.6g\n", stQ, stepsQ, thrQ))
io.write(string.format("   var: escape=%.6g recipe=%.6g   phys: import=%.6g dump=%.6g\n", veQ, vrQ, shQ, suQ))
io.write(string.format("PASS A (a_k=x_q, floored, same q): state=%s steps=%d\n", stA, stepsA))
io.write(string.format("   var: escape=%.6g recipe=%.6g   phys: import=%.6g dump=%.6g\n", veA, vrA, shA, suA))
io.write(string.format("PASS D (a_k=x_q active, delete~0): state=%s steps=%d  primals %d->%d\n",
    stD, stepsD, pQ.primal_length, pD.primal_length))
io.write(string.format("   var: escape=%.6g recipe=%.6g   phys: import=%.6g dump=%.6g\n", veD, vrD, shD, suD))

-- concentration of physical imports (Herfindahl on shortage escapes): higher =
-- more concentrated onto few escapes; ~1/N_active = evenly spread.
local function herfindahl(problem, x, kind)
    local vals, total = {}, 0
    for k, p in pairs(problem.primals) do
        if p.kind == kind then local v = phys(problem, k, x); if v > 0 then vals[#vals + 1] = v; total = total + v end end
    end
    if total <= 0 then return 0, 0, #vals end
    local h, mx = 0, 0
    for _, v in ipairs(vals) do local s = v / total; h = h + s * s; if s > mx then mx = s end end
    return h, mx, #vals
end
local hQ, mxQ, nQ = herfindahl(pQ, xQ, "shortage_source")
local hA, mxA, nA = herfindahl(pA, xA, "shortage_source")
local hD, mxD, nD = herfindahl(pD, xD, "shortage_source")
io.write("\nphysical-import concentration on shortage_source (Herfindahl, max-share, n>0):\n")
io.write(string.format("   Q: H=%.4f max=%.4f n=%d   A: H=%.4f max=%.4f n=%d   D: H=%.4f max=%.4f n=%d\n",
    hQ, mxQ, nQ, hA, mxA, nA, hD, mxD, nD))
io.write("   (H rises toward 1 = mass concentrating onto fewer escapes; ~1/n = evenly spread)\n")

-- deviation of a candidate vs x_q on escapes (variable space) and recipes --------
local function devs(xother, probother, kindset)
    local maxd, argk, l2 = 0, "", 0
    for k, p in pairs(pQ.primals) do
        local match = (type(kindset) == "function") and kindset(p) or kindset[p.kind]
        if match then
            local a, b = math.abs(xQ[k] or 0), math.abs(xother[k] or 0)
            local d = math.abs(a - b) / (math.abs(a) + 1)
            if d > maxd then maxd = d; argk = k end
            l2 = l2 + (a - b) * (a - b)
        end
    end
    return maxd, argk, math.sqrt(l2)
end
local function report_dev(label, xother, probother)
    local md_r, ak_r, l2_r = devs(xother, probother, { recipe = true })
    io.write(string.format("%s recipe-vs-x_q: max rel-dev=%.4g (%s)  L2=%.6g\n", label, md_r, ak_r, l2_r))
end
io.write("\nrecipe activity drift (does baking a_k change WHICH recipes run / how much?):\n")
report_dev("   A", xA, pA)
report_dev("   D", xD, pD)

-- per-escape physical comparison, top by physical_Q ----------------------------
local rows = {}
for k, p in pairs(pQ.primals) do
    if p.kind == "shortage_source" then
        local pq = phys(pQ, k, xQ)
        if pq > thrQ then
            rows[#rows + 1] = { k = k, mat = p.material or "?", pq = pq,
                pa = phys(pA, k, xA), pd = phys(pD, k, xD),
                xq = xQ[k] or 0, xa = xA[k] or 0 }
        end
    end
end
table.sort(rows, function(a, b) return a.pq > b.pq end)
io.write("\ntop active shortage_source: physical import Q vs A vs D, and var x_q vs x_a\n")
io.write(string.format("   %-13s %-13s %-13s | %-13s %-13s  material\n", "phys_Q", "phys_A", "phys_D", "x_q", "x_a"))
for i = 1, math.min(#rows, 20) do
    local r = rows[i]
    io.write(string.format("   %-13.6g %-13.6g %-13.6g | %-13.6g %-13.6g  %s\n",
        r.pq, r.pa, r.pd, r.xq, r.xa, r.mat))
end
if #rows == 0 then io.write("   (no active shortage_source above threshold)\n") end
