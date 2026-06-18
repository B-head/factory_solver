---@diagnostic disable: undefined-global
-- "Perfect tilted cost from a QP solve" check.
--
-- PASS Q (QP): uniform quadratic (QUAD0/2)*x^2 on the elastic escapes
--   (shortage_source + surplus_sink); initial/final FREE; targets hard equality
--   at BIG. Solve -> x_q (the least-norm, spread solution).
--
-- PASS T (tilted linear): rebuild the SAME structure but put a PER-ESCAPE LINEAR
--   cost c'[key] = QUAD0 * x_q[key] on each elastic escape (= the gradient of the
--   quadratic objective at x_q). No quad. Solve -> x_t.
--
-- KKT says x_q is AN optimum of the tilted linear LP. This measures whether our
-- IPM actually lands back on x_q, or drifts to another point of the optimal face
-- (vertex / analytic center), and whether the even-split structure survives or
-- collapses. Also evaluates the tilted objective on both vectors: obj(x_t) much
-- below obj(x_q) would mean x_q is NOT reproduced (face slide / free wash).
--
--   luajit tests/research/probe_tilt_from_quad.lua [dumpfile] [BIG]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e6
local QUAD0 = 2

local ELASTIC = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }

local prob = assert(problem_dump.load_problem(PATH))

-- common reduction shared by both passes: hard-equality targets at BIG, strip
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

-- tilted linear cost on each escape = gradient of (QUAD0/2)x^2 at x_q = QUAD0*x_q.
local function build_tilt(xq)
    local problem = create_problem.create_problem("tl", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if ELASTIC[p.kind] then p.cost = QUAD0 * math.max(0, xq[key] or 0) -- no quad
        elseif FREEK[p.kind] then p.cost = 0 end
    end
    strip_and_reindex(problem)
    return problem
end

-- tilt the QP-ACTIVE escapes with c'=QUAD0*x_q, and DELETE the QP-near-0 ones
-- (the free-wash directions). Tests whether removing the free directions lets the
-- frozen-gradient linear cost reproduce x_q.
local function build_tilt_delete(xq, thr)
    local problem = create_problem.create_problem("td", prob.constraints, prob.normalized_lines, nil, nil)
    local rm = {}
    for key, p in pairs(problem.primals) do
        if ELASTIC[p.kind] then
            if math.abs(xq[key] or 0) > thr then p.cost = QUAD0 * math.max(0, xq[key])
            else rm[key] = true end
        elseif FREEK[p.kind] then p.cost = 0 end
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

-- ============================================================================
local pQ = build_qp()
local xQ, stQ, stepsQ = solve(pQ)
local thrQ = park_threshold(pQ, xQ)

local pT = build_tilt(xQ)
local xT, stT, stepsT = solve(pT)
local thrT = park_threshold(pT, xT)

local pD = build_tilt_delete(xQ, thrQ)
local xD, stD, stepsD = solve(pD)
local thrD = park_threshold(pD, xD)

-- masses / objective evaluated under the TILTED linear cost (pT.primals[k].cost)
local function masses(problem, x)
    local em, rm = 0, 0
    for k, p in pairs(problem.primals) do
        local v = math.abs(x[k] or 0)
        if ELASTIC[p.kind] then em = em + v elseif p.kind == "recipe" then rm = rm + v end
    end
    return em, rm
end
local function tilt_obj(x)
    local o = 0
    for k, p in pairs(pT.primals) do o = o + (p.cost or 0) * math.abs(x[k] or 0) end
    return o
end

local emQ, rmQ = masses(pQ, xQ)
local emT, rmT = masses(pT, xT)

io.write("================ TILTED COST FROM QP (reproduce x_q with a linear LP?) ================\n")
io.write(string.format("file=%s  BIG=%g  quad=%g\n", PATH:match("[^/]+$"), BIG, QUAD0))
io.write(string.format("PASS Q (uniform quad): state=%s steps=%d  thr=%.6g\n", stQ, stepsQ, thrQ))
io.write(string.format("   escape_mass=%.6g recipe_mass=%.6g\n", emQ, rmQ))
io.write(string.format("PASS T (tilted linear c'=%g*x_q): state=%s steps=%d  thr=%.6g\n", QUAD0, stT, stepsT, thrT))
io.write(string.format("   escape_mass=%.6g recipe_mass=%.6g\n", emT, rmT))
local emD, rmD = masses(pD, xD)
io.write(string.format("PASS TD (tilt active + DELETE near-0): state=%s steps=%d  thr=%.6g  primals %d->%d\n",
    stD, stepsD, thrD, pQ.primal_length, pD.primal_length))
io.write(string.format("   escape_mass=%.6g recipe_mass=%.6g\n", emD, rmD))

-- objective comparison under c'
local oQ, oT = tilt_obj(xQ), tilt_obj(xT)
io.write(string.format("\ntilted objective c'^T x :  at x_q = %.8g   at x_t = %.8g   (ratio x_t/x_q = %.6f)\n",
    oQ, oT, oQ ~= 0 and (oT / oQ) or 0))
io.write("   (x_t much below x_q => x_q NOT reproduced: linear slid to a cheaper face point / free wash)\n")

-- deviation of a candidate vector from x_q on escapes and recipes -----------
local function devs(xother, kindset)
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
local function report_dev(label, xother)
    local md_e, ak_e, l2_e = devs(xother, ELASTIC)
    local md_r, ak_r, l2_r = devs(xother, { recipe = true })
    io.write(string.format("\n%s vs x_q deviation:\n", label))
    io.write(string.format("   escapes : max rel-dev=%.4g (%s)  L2=%.6g\n", md_e, ak_e, l2_e))
    io.write(string.format("   recipes : max rel-dev=%.4g (%s)  L2=%.6g\n", md_r, ak_r, l2_r))
end
report_dev("x_t (tilt-all)", xT)
report_dev("x_d (tilt+delete)", xD)
io.write(string.format("\ntilt+delete objective check: c'^T x_q=%.8g  c'^T x_d=%.8g\n",
    (function() local o = 0 for k, p in pairs(pD.primals) do o = o + (p.cost or 0) * math.abs(xQ[k] or 0) end return o end)(),
    (function() local o = 0 for k, p in pairs(pD.primals) do o = o + (p.cost or 0) * math.abs(xD[k] or 0) end return o end)()))

-- active-set comparison on escapes -----------------------------------------
local function active_escapes(problem, x, thr)
    local s = {}
    for k, p in pairs(problem.primals) do
        if ELASTIC[p.kind] and math.abs(x[k] or 0) > thr then s[k] = math.abs(x[k] or 0) end
    end
    return s
end
local aQ = active_escapes(pQ, xQ, thrQ)
local aT = active_escapes(pT, xT, thrT)
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local onlyQ, onlyT = {}, {}
for k in pairs(aQ) do if not aT[k] then onlyQ[#onlyQ + 1] = k end end
for k in pairs(aT) do if not aQ[k] then onlyT[#onlyT + 1] = k end end
table.sort(onlyQ); table.sort(onlyT)
io.write(string.format("\nactive escapes: QP=%d  tilted=%d  (only-in-QP=%d, only-in-tilted=%d)\n",
    count(aQ), count(aT), #onlyQ, #onlyT))
for i = 1, math.min(#onlyQ, 12) do io.write(string.format("   QP-only   %-12.6g %s\n", aQ[onlyQ[i]], onlyQ[i])) end
for i = 1, math.min(#onlyT, 12) do io.write(string.format("   tilt-only %-12.6g %s\n", aT[onlyT[i]], onlyT[i])) end

-- even-split survival: per material, QP near-equal groups (>=2 escapes) -----
local by_mat = {}
for k, p in pairs(pQ.primals) do
    if ELASTIC[p.kind] and (xQ[k] or 0) > thrQ then
        local m = p.material or "?"
        by_mat[m] = by_mat[m] or {}
        by_mat[m][#by_mat[m] + 1] = k
    end
end
io.write("\neven-split survival (materials with >=2 active escapes in QP):\n")
local printed = 0
local mats = {}
for m in pairs(by_mat) do mats[#mats + 1] = m end
table.sort(mats)
for _, m in ipairs(mats) do
    local ks = by_mat[m]
    if #ks >= 2 then
        printed = printed + 1
        io.write(string.format("  %s  (%d escapes)\n", m, #ks))
        table.sort(ks)
        for _, k in ipairs(ks) do
            io.write(string.format("     QP=%-13.6g  tilt=%-13.6g  %s\n", xQ[k] or 0, xT[k] or 0, k))
        end
    end
end
if printed == 0 then io.write("   (none)\n") end
