---@diagnostic disable: undefined-global
-- MODE-COMPRESSION guard with a SHIPPED-STYLE TARGET-RESCUE LOCK (2026-07-05).
-- Identical pipeline to probe_mode_compress_guard.lua (UG / G / G2 deletion sets)
-- but every build carries target_budget = baseline T0 (the shipped target-rescue
-- lock), so no solve may trade the target away. Motivation: without the lock the
-- plain-L2 probe let channel deletion COLLAPSE the target (seed_118: soil stops
-- at 17 not 30, T 0->0.43) purely because the quadratic import penalty exceeds
-- the soft target's worth once a spreading channel is removed -- a probe artifact
-- the shipped solver never hits (it locks the target). With the lock the same
-- deletion instead forces the remaining channel UP, so the damage reappears as
-- Vp/Vf import growth (VPREG) rather than target collapse (TREG). This run
-- measures how the clean rate and failure mix change under the faithful lock.
-- Emits one 'mb' line per dump (run via run_corpus.ps1 -Collect '^mb').
--   lua tests/research/probe_mode_compress_budget.lua <dump>
require "tests/headless_env"
local R = require "tests/research/research_lib"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local RS = require "tests/research/reference_solver"
local D = R.dissect

local VQ, VF, EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10
local COS_TH, PERTCAP = 0.85, 60
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"

local function mat_base(m) return (m:gsub("@%[.-%]$", "")) end

local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("mb ERR=load seed=" .. fid .. "\n"); return end

-- Set after the first (unlocked) baseline solve computes T0; nil => unlocked.
local BUDGET = nil
local function build()
    local opts = { reachability_gating = false, deficit_seeding = false, catalyst_closure = false,
        surplus_sink_gating = false, recipe_epsilon = EPS }
    if BUDGET then opts.target_budget = BUDGET end
    local p = create_problem.create_problem("l2", prob.constraints, prob.normalized_lines, nil, opts)
    create_problem.shape_l2(p, VQ, VF); return p
end
local function phys(problem, key, x)
    local p, t = problem.primals[key], problem.subject_terms[key]
    local c = (p and p.material and t and t[p.material]) or 1
    return math.abs(c * (x[key] or 0))
end
local function delete_keys(problem, keys)
    for _, k in ipairs(keys) do
        problem:set_quad(k, 0)
        problem.primals[k] = nil
        problem.subject_terms[k] = nil
    end
    local ks = {}
    for k in pairs(problem.primals) do ks[#ks + 1] = k end
    table.sort(ks)
    for i, k in ipairs(ks) do problem.primals[k].index = i end
    problem.primal_length = #ks
end

-- Stage 1: unlocked baseline solve to read T0 (least achievable target
-- violation; target_cost=2^20 dominates so plain L2 already minimizes it).
local base0 = build()
local x0u, st0u = R.drive_solve(base0, prob.meta)
if st0u ~= "finished" then io.write("mb ERR=baseline seed=" .. fid .. "\n"); return end
local T0 = 0
for k, p in pairs(base0.primals) do
    if p.kind == "elastic" or p.kind == "headroom" then T0 = T0 + math.abs(x0u[k] or 0) end
end
-- Lock every subsequent build at the shipped rescue budget (t_min slack).
BUDGET = T0 * (1 + 1e-3) + 1e-6
local base = build()
local x0, st0 = R.drive_solve(base, prob.meta)
if st0 ~= "finished" then io.write("mb ERR=baseline_locked seed=" .. fid .. "\n"); return end

local lines = D.all_lines(prob.normalized_lines, base)
local nL = #lines
local rkey, is_br = {}, {}
for j, line in ipairs(lines) do
    rkey[j] = D.recipe_key(line); is_br[j] = line.is_bridge == true
end
local function dxof(x1)
    local dx = {}
    for j = 1, nL do dx[j] = (x1[rkey[j]] or 0) - (x0[rkey[j]] or 0) end
    return dx
end
local function cosine(a, b)
    local s, na, nb = 0, 0, 0
    for j = 1, nL do
        if not is_br[j] then
            local x, y = a[j] or 0, b[j] or 0
            s = s + x * y; na = na + x * x; nb = nb + y * y
        end
    end
    if na == 0 or nb == 0 then return 0 end
    return s / math.sqrt(na * nb)
end
local function real_norm(dx)
    local n = 0
    for j = 1, nL do if not is_br[j] then n = n + (dx[j] or 0) ^ 2 end end
    return math.sqrt(n)
end
local function count_active(problem, x)
    local n = 0
    for k, p in pairs(problem.primals) do
        if (p.kind == "shortage_source" or p.kind == "surplus_sink") and phys(problem, k, x) > 1e-6 then n = n + 1 end
    end
    return n
end
local function tmass(problem, x)
    local s = 0
    for k, p in pairs(problem.primals) do
        if p.kind == "elastic" or p.kind == "headroom" then s = s + math.abs(x[k] or 0) end
    end
    return s
end
local base_machines = 0
for k, p in pairs(base.primals) do if p.kind == "recipe" then base_machines = base_machines + math.abs(x0[k] or 0) end end
if base_machines < 1e-9 then base_machines = 1e-9 end

local active = {}
for k, p in pairs(base.primals) do
    if (p.kind == "shortage_source" or p.kind == "surplus_sink") and phys(base, k, x0) > 1e-6 then
        active[#active + 1] = { key = k, mat = p.material, kind = p.kind, xv = phys(base, k, x0) }
    end
end
if #active == 0 then io.write("mb NOACTIVE seed=" .. fid .. "\n"); return end
table.sort(active, function(a, b) return a.xv > b.xv end)
local n0 = #active
local trunc = (#active > PERTCAP) and 1 or 0

local resp, pdiv = {}, 0
for i = 1, math.min(#active, PERTCAP) do
    local e = active[i]
    local problem = build(); problem:set_quad(e.key, 0)
    local x1, st1 = R.drive_solve(problem, prob.meta)
    if st1 ~= "finished" then pdiv = pdiv + 1
    else
        resp[#resp + 1] = { e = e, dx = dxof(x1), rnorm = real_norm(dxof(x1)) }
    end
end
table.sort(resp, function(a, b) return a.rnorm > b.rnorm end)

local clusters = {}
for _, r in ipairs(resp) do
    if r.rnorm >= 1e-6 then
        local bestc, bestcos = nil, COS_TH
        for ci, cl in ipairs(clusters) do
            local c = cosine(r.dx, cl.cen)
            if math.abs(c) > bestcos then bestc, bestcos = ci, math.abs(c) end
        end
        if bestc then
            local cl = clusters[bestc]
            local sgn = cosine(r.dx, cl.cen) >= 0 and 1 or -1
            for j = 1, nL do cl.cen[j] = cl.cen[j] + sgn * r.dx[j] end
            cl.n = cl.n + 1; cl.members[#cl.members + 1] = r
        else
            local cen = {}
            for j = 1, nL do cen[j] = r.dx[j] end
            clusters[#clusters + 1] = { cen = cen, n = 1, members = { r } }
        end
    end
end

-- union winners; build UG, G (same base), and G2 (same base AND same kind) sets
local ug_del, g_del, g2_del, nmulti, udiv, ncross = {}, {}, {}, 0, 0, 0
local function fold_by(cl, keyfn, uphys, out)
    local groups = {}
    for _, m in ipairs(cl.members) do
        local kk = keyfn(m)
        groups[kk] = groups[kk] or {}
        table.insert(groups[kk], m)
    end
    for _, grp in pairs(groups) do
        if #grp >= 2 then
            local gw, gwv = nil, -1
            for _, m in ipairs(grp) do local v = uphys(m); if v > gwv then gwv = v; gw = m end end
            for _, m in ipairs(grp) do if m ~= gw then out[#out + 1] = m.e.key end end
        end
    end
end
for _, cl in ipairs(clusters) do
    if cl.n >= 2 then
        nmulti = nmulti + 1
        local pu = build()
        for _, m in ipairs(cl.members) do pu:set_quad(m.e.key, 0) end
        local xu, stu = R.drive_solve(pu, prob.meta)
        if stu ~= "finished" then udiv = udiv + 1 end
        local function uphys(m) return (stu == "finished") and phys(pu, m.e.key, xu) or m.e.xv end
        -- UG: single cluster winner
        local winner, wv = nil, -1
        for _, m in ipairs(cl.members) do local v = uphys(m); if v > wv then wv = v; winner = m end end
        for _, m in ipairs(cl.members) do if m ~= winner then ug_del[#ug_del + 1] = m.e.key end end
        -- G: per base-material subgroup; G2: per (base,kind) subgroup
        fold_by(cl, function(m) return mat_base(m.e.mat or "?") end, uphys, g_del)
        fold_by(cl, function(m) return (m.e.kind or "?") .. "|" .. mat_base(m.e.mat or "?") end, uphys, g2_del)
        -- count cross-material deletions the UG set makes (deleted base != winner base)
        for _, m in ipairs(cl.members) do
            if m ~= winner and mat_base(m.e.mat or "?") ~= mat_base(winner.e.mat or "?") then
                ncross = ncross + 1
            end
        end
    end
end

local inter = RS.intermediates(prob.normalized_lines)
local producible = RS.producible_set(prob.constraints, prob.normalized_lines)
local consumable = RS.consumable_set(prob.constraints, prob.normalized_lines)
local vp0, vc0, vf0 = RS.violation_split(base, x0, inter, producible, consumable)
local t0 = tmass(base, x0)

local function grade(del)
    if #del == 0 then
        return { st = "nodel", n1 = n0, ndel = 0, rdist = 0, nraw = 0, t1 = t0, vp1 = vp0, vc1 = vc0, vf1 = vf0 }
    end
    local pd = build()
    delete_keys(pd, del)
    local xd, std = R.drive_solve(pd, prob.meta)
    if std ~= "finished" then return { st = tostring(std), ndel = #del } end
    local rdist, nraw = 0, 0
    for k, p in pairs(pd.primals) do
        if p.kind == "recipe" then rdist = rdist + math.abs((xd[k] or 0) - (x0[k] or 0)) end
    end
    for k, p in pairs(base.primals) do
        if p.kind == "initial_source" and pd.primals[k] then
            local inc = phys(pd, k, xd) - phys(base, k, x0)
            if inc > 0 then nraw = nraw + inc end
        end
    end
    local vp1, vc1, vf1 = RS.violation_split(pd, xd, inter, producible, consumable)
    return { st = "ok", n1 = count_active(pd, xd), ndel = #del, rdist = rdist / base_machines,
        nraw = nraw / base_machines, t1 = tmass(pd, xd), vp1 = vp1, vc1 = vc1, vf1 = vf1 }
end

local ug, g, g2 = grade(ug_del), grade(g_del), grade(g2_del)
io.write(string.format(
    "mb n0=%d ncl=%d nmulti=%d ncross=%d trunc=%d pdiv=%d udiv=%d T0=%.6g Vp0=%.6g Vc0=%.6g Vf0=%.6g" ..
    " ug_st=%s ug_ndel=%d ug_n1=%d ug_rdist=%.4g ug_newRaw=%.4g ug_T1=%.6g ug_Vp1=%.6g ug_Vc1=%.6g ug_Vf1=%.6g" ..
    " g_st=%s g_ndel=%d g_n1=%d g_rdist=%.4g g_newRaw=%.4g g_T1=%.6g g_Vp1=%.6g g_Vc1=%.6g g_Vf1=%.6g" ..
    " g2_st=%s g2_ndel=%d g2_n1=%d g2_rdist=%.4g g2_newRaw=%.4g g2_T1=%.6g g2_Vp1=%.6g g2_Vc1=%.6g g2_Vf1=%.6g seed=%s\n",
    n0, #clusters, nmulti, ncross, trunc, pdiv, udiv, t0, vp0, vc0, vf0,
    ug.st, ug.ndel or 0, ug.n1 or 0, ug.rdist or 0, ug.nraw or 0, ug.t1 or 0, ug.vp1 or 0, ug.vc1 or 0, ug.vf1 or 0,
    g.st, g.ndel or 0, g.n1 or 0, g.rdist or 0, g.nraw or 0, g.t1 or 0, g.vp1 or 0, g.vc1 or 0, g.vf1 or 0,
    g2.st, g2.ndel or 0, g2.n1 or 0, g2.rdist or 0, g2.nraw or 0, g2.t1 or 0, g2.vp1 or 0, g2.vc1 or 0, g2.vf1 or 0, fid))
