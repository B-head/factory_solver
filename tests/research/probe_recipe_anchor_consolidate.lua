---@diagnostic disable: undefined-global
-- "Keep QP's even RECIPE usage, consolidate the elastic escapes to minimal support."
--
-- The missing ingredient vs probe_consolidate / probe_irl1: those reweight the
-- elastic escapes (shortage_source + surplus_sink) but leave RECIPES free, so the
-- consolidation pressure leaks into recipe space as the cheat drift (import
-- fattening / killing the dump-forced small imports). Here we instead PIN the
-- recipes to the QP recipe vector r_q with a hard box [r_q*(1-delta), r_q*(1+delta)]
-- (inactive recipes pinned to ~0), then run IRL1 on the escapes ONLY. Because the
-- QP solution x_q is itself inside the box for any delta>=0, feasibility is
-- guaranteed; consolidation can only move along the feasible elastic face.
--
-- delta sweeps the recipe trust radius: 0 = recipes locked exactly to r_q (escapes
-- nearly determined, only redundant outlets / washes can die); large = recipes
-- free (reproduces the probe_irl1 cheat-drift as the negative control).
--
--   luajit tests/research/probe_recipe_anchor_consolidate.lua [dumpfile] [EPS] [ITERS]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local EPS = tonumber(arg[2]) or 1.0
local ITERS = tonumber(arg[3]) or 5
-- IMPMULT: extra base weight on shortage_source (import) escapes in the IRL1
-- consolidation so the count-minimizer respects Vp >> Vc (never trade a cheap
-- dump for a dearer import). 1 = priority-blind original.
local IMPMULT = tonumber(arg[4]) or 1
local BIG = 1e6

local VIO = { shortage_source = true, surplus_sink = true } -- the elastic escapes
local FREEK = { initial_source = true, final_sink = true }   -- raw / final = free

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

-- ===== stage 1: QP (the desirable spread + even recipe usage) ================
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

-- recipe targets r_q and the elastic-escape key list, taken from the QP solve.
local recipe_keys, vio_keys = {}, {}
for k, p in pairs(pq.primals) do
    if p.kind == "recipe" or p.kind == "bridge" then recipe_keys[#recipe_keys + 1] = k
    elseif VIO[p.kind] then vio_keys[#vio_keys + 1] = k end
end
local rq = {}
for _, k in ipairs(recipe_keys) do rq[k] = math.abs(xq[k] or 0) end

local function thr_of(problem, x)
    local maxr = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
    return math.max(1e-9, maxr * 1e-6)
end
local THR_Q = thr_of(pq, xq)

-- metrics: escape support + L1, recipe support, recipe deviation from r_q,
-- import L1 (cheat magnitude), albumin import (the seed_143 cheat tell).
local function metrics(problem, x)
    local thr = thr_of(problem, x)
    local nesc, l1, imp_l1, nrec = 0, 0, 0, 0
    for _, k in ipairs(vio_keys) do
        local v = math.abs(x[k] or 0); l1 = l1 + v
        if v > thr then nesc = nesc + 1 end
        local p = problem.primals[k]; if p and p.kind == "shortage_source" then imp_l1 = imp_l1 + v end
    end
    local maxdev, devarg, l2dev = 0, "", 0
    for _, k in ipairs(recipe_keys) do
        local v = math.abs(x[k] or 0)
        -- count an active recipe well above the box near-0 floor (thr ~ maxr*1e-6),
        -- so QP-inactive recipes pinned at the box edge don't inflate the count.
        if v > thr * 1000 then nrec = nrec + 1 end
        local d = math.abs(v - (rq[k] or 0)) / (math.abs(rq[k] or 0) + 1)
        if d > maxdev then maxdev = d; devarg = k end
        l2dev = l2dev + (v - (rq[k] or 0)) ^ 2
    end
    return { nesc = nesc, l1 = l1, imp_l1 = imp_l1, nrec = nrec, maxdev = maxdev, devarg = devarg, l2dev = math.sqrt(l2dev) }
end
local function findv(problem, x, kind, sub)
    local t = 0
    for k, p in pairs(problem.primals) do
        if p.kind == kind and p.material and tostring(p.material):find(sub, 1, true) then t = t + math.abs(x[k] or 0) end
    end
    return t
end

-- ===== stage 2: IRL1 on escapes, recipes PROXIMAL-ANCHORED to r_q ============
-- Soft, scale-invariant proximal quadratic pulling each recipe toward its QP
-- level r_q: add ½·kq·(x-r_q)² with kq = kappa0 / max(r_q, RFLOOR)². The
-- normalization makes the penalty ≈ ½·kappa0·(relative deviation)², so kappa0 is
-- one dimensionless anchor strength comparable across recipes and cases, and it
-- penalizes PROPORTION drift (= even recipe usage) rather than absolute units.
-- Expand ½kq(x-r_q)² = ½kq·x² (set_quad) - kq·r_q·x (linear cost) + const.
-- kappa0 = 0 means no anchor (recipes free = IRL1 control). Feasibility always
-- holds (soft anchor, no hard bound; the escapes absorb any residual).
local maxr = 0
for _, k in ipairs(recipe_keys) do if (rq[k] or 0) > maxr then maxr = rq[k] end end
local RFLOOR = math.max(THR_Q, maxr * 1e-3)

local function proximal_recipe(problem, k, kappa0)
    local p = problem.primals[k]
    if not p then return end
    local target = rq[k] or 0
    local kq = kappa0 / (math.max(target, RFLOOR) ^ 2)
    problem:set_quad(k, kq)
    p.cost = -kq * target
end

local function build_anchored(weights, kappa0)
    local problem = create_problem.create_problem("anc", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = weights[key] or (1 / EPS)
        elseif FREEK[p.kind] then p.cost = 0 end
    end
    remove_targets(problem); reindex(problem)
    if kappa0 > 0 then
        for _, k in ipairs(recipe_keys) do proximal_recipe(problem, k, kappa0) end
    end
    return problem
end

io.write("================ RECIPE-ANCHORED ESCAPE CONSOLIDATION ================\n")
io.write(string.format("file=%s  EPS=%g ITERS=%d\n", PATH:match("[^/]+$"), EPS, ITERS))
local mq = metrics(pq, xq)
io.write(string.format("QP start : escapes=%d  L1=%.6g  import_L1=%.6g  recipes=%d  albumin_import=%.6g\n\n",
    mq.nesc, mq.l1, mq.imp_l1, mq.nrec, findv(pq, xq, "shortage_source", "item/albumin")))

io.write("kappa0 = proximal anchor strength (big=recipes held to r_q, 0=free=irl1 control)\n")
io.write(string.format("%-7s | %-7s %-10s %-10s | %-7s %-9s %-9s | %s\n",
    "kappa0", "escapes", "esc_L1", "import_L1", "recipes", "rdev_max", "rdev_L2", "albumin"))
io.write(string.rep("-", 96) .. "\n")

for _, kappa0 in ipairs({ 1e8, 1e6, 1e4, 1e2, 1, 0 }) do
    local xprev = xq
    local m, alb, st
    for it = 1, ITERS do
        local w = {}
        for _, k in ipairs(vio_keys) do
            local base = (pq.primals[k].kind == "shortage_source") and IMPMULT or 1
            w[k] = base / (math.abs(xprev[k] or 0) + EPS)
        end
        local p = build_anchored(w, kappa0)
        local x, s = solve(p)
        st = s; m = metrics(p, x); alb = findv(p, x, "shortage_source", "item/albumin")
        xprev = x
    end
    local dname = (kappa0 == 0) and "free" or string.format("%.0g", kappa0)
    io.write(string.format("%-7s | %-7d %-10.6g %-10.6g | %-7d %-9.4g %-9.6g | %.6g  [%s]\n",
        dname, m.nesc, m.l1, m.imp_l1, m.nrec, m.maxdev, m.l2dev, alb, st))
end

io.write("\nread: escapes/esc_L1 small = consolidated & low violation; import_L1/albumin small = no cheat drift;\n")
io.write("      rdev_max within delta = recipe evenness held. The win is a row that drops escapes vs QP\n")
io.write("      WITHOUT import_L1/albumin rising (which the free row should show rising = the old failure).\n")
