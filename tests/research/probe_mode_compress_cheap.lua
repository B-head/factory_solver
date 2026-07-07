---@diagnostic disable: undefined-global
-- CHEAP MODE-COMPRESSION: skip the per-elastic perturbation solves (2026-07-07).
-- The guarded pipeline (probe_mode_compress_budget.lua) spends ~PERTCAP=60 solves
-- per dump on quad-free perturbations whose ONLY surviving use is direction
-- clustering -- yet the G guard then restricts deletion to same-base subgroups
-- anyway. Hypothesis: grouping active elastics DIRECTLY by base material (free
-- metadata, no solves) reaches the same deletions, cutting the per-dump cost from
-- ~2+n+nmulti+1 solves to ~2+nmulti+1. Four variants, cheapest last:
--   bg  : same-base groups, union-free solve per group, winner = union phys
--   bg2 : same-(base,kind) groups, union-free solve per group (no imp<->dump fold)
--   bx  : same-base groups, NO union solve, winner = max baseline xv
--   bx2 : same-(base,kind) groups, NO union solve, winner = max baseline xv
-- Target-rescue lock identical to the budget probe. Emits one 'mc' line per dump
-- with the mb-compatible fields per variant PLUS raw physical totals (total
-- import phys, total dump phys, machine count) -- machines are REPORT-ONLY, not a
-- quality axis (cheats also shrink machine count). Join with mb_c*.txt by seed to
-- compare clean rates against the perturbation-clustered G guard.
--   lua tests/research/probe_mode_compress_cheap.lua <dump>
require "tests/headless_env"
local R = require "tests/research/research_lib"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local RS = require "tests/research/reference_solver"
local D = R.dissect

local VQ, VF, EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"

local function mat_base(m) return (m:gsub("@%[.-%]$", "")) end

local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("mc ERR=load seed=" .. fid .. "\n"); return end

local solves = 0
local BUDGET = nil
local function build()
    local opts = { reachability_gating = false, deficit_seeding = false, catalyst_closure = false,
        surplus_sink_gating = false, recipe_epsilon = EPS }
    if BUDGET then opts.target_budget = BUDGET end
    local p = create_problem.create_problem("l2", prob.constraints, prob.normalized_lines, nil, opts)
    create_problem.shape_l2(p, VQ, VF); return p
end
local function solve(p)
    solves = solves + 1
    return R.drive_solve(p, prob.meta)
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

-- Stage 1: unlocked baseline for T0, then the locked baseline (shipped rescue).
local base0 = build()
local x0u, st0u = solve(base0)
if st0u ~= "finished" then io.write("mc ERR=baseline seed=" .. fid .. "\n"); return end
local T0 = 0
for k, p in pairs(base0.primals) do
    if p.kind == "elastic" or p.kind == "headroom" then T0 = T0 + math.abs(x0u[k] or 0) end
end
BUDGET = T0 * (1 + 1e-3) + 1e-6
local base = build()
local x0, st0 = solve(base)
if st0 ~= "finished" then io.write("mc ERR=baseline_locked seed=" .. fid .. "\n"); return end

local function tmass(problem, x)
    local s = 0
    for k, p in pairs(problem.primals) do
        if p.kind == "elastic" or p.kind == "headroom" then s = s + math.abs(x[k] or 0) end
    end
    return s
end
local function count_active(problem, x)
    local n = 0
    for k, p in pairs(problem.primals) do
        if (p.kind == "shortage_source" or p.kind == "surplus_sink") and phys(problem, k, x) > 1e-6 then n = n + 1 end
    end
    return n
end
-- Raw physical totals: mixed-unit sums (same convention as the violation masses).
local function totals(problem, x)
    local imp, dmp, mach = 0, 0, 0
    for k, p in pairs(problem.primals) do
        if p.kind == "shortage_source" then imp = imp + phys(problem, k, x)
        elseif p.kind == "surplus_sink" then dmp = dmp + phys(problem, k, x)
        elseif p.kind == "recipe" then mach = mach + math.abs(x[k] or 0) end
    end
    return imp, dmp, mach
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
if #active == 0 then io.write("mc NOACTIVE seed=" .. fid .. "\n"); return end
table.sort(active, function(a, b) return a.xv > b.xv end)
local n0 = #active

-- Group by base / (base,kind); deterministic member order (xv desc from `active`).
local function group_by(keyfn)
    local groups, order = {}, {}
    for _, e in ipairs(active) do
        local kk = keyfn(e)
        if not groups[kk] then groups[kk] = {}; order[#order + 1] = kk end
        table.insert(groups[kk], e)
    end
    local multi = {}
    for _, kk in ipairs(order) do
        if #groups[kk] >= 2 then multi[#multi + 1] = groups[kk] end
    end
    return multi, #order
end
local bykey = function(e) return mat_base(e.mat or "?") end
local bykey2 = function(e) return (e.kind or "?") .. "|" .. mat_base(e.mat or "?") end
local multi_bg, nbg = group_by(bykey)
local multi_bg2, nbg2 = group_by(bykey2)

-- Winner selection. Union variant: free every member's quad together, let the LP
-- pick (winner = largest union phys; solve failure falls back to baseline xv).
-- Cheap variant: winner = largest baseline xv, no solve.
local udiv = 0
local function del_union(multi)
    local del = {}
    for _, grp in ipairs(multi) do
        local pu = build()
        for _, e in ipairs(grp) do pu:set_quad(e.key, 0) end
        local xu, stu = solve(pu)
        if stu ~= "finished" then udiv = udiv + 1 end
        local w, wv = nil, -1
        for _, e in ipairs(grp) do
            local v = (stu == "finished") and phys(pu, e.key, xu) or e.xv
            if v > wv then wv = v; w = e end
        end
        for _, e in ipairs(grp) do if e ~= w then del[#del + 1] = e.key end end
    end
    return del
end
local function del_xv(multi)
    local del = {}
    for _, grp in ipairs(multi) do
        -- `active` is xv-sorted desc, so grp[1] is the max-xv member.
        for i = 2, #grp do del[#del + 1] = grp[i].key end
    end
    return del
end

local inter = RS.intermediates(prob.normalized_lines)
local producible = RS.producible_set(prob.constraints, prob.normalized_lines)
local consumable = RS.consumable_set(prob.constraints, prob.normalized_lines)
local vp0, vc0, vf0 = RS.violation_split(base, x0, inter, producible, consumable)
local t0m = tmass(base, x0)
local imp0, dmp0, mach0 = totals(base, x0)

local function grade(del)
    if #del == 0 then
        return { st = "nodel", n1 = n0, ndel = 0, rdist = 0, nraw = 0, t1 = t0m,
            vp1 = vp0, vc1 = vc0, vf1 = vf0, imp1 = imp0, dmp1 = dmp0, mach1 = mach0 }
    end
    local pd = build()
    delete_keys(pd, del)
    local xd, std = solve(pd)
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
    local imp1, dmp1, mach1 = totals(pd, xd)
    return { st = "ok", n1 = count_active(pd, xd), ndel = #del, rdist = rdist / base_machines,
        nraw = nraw / base_machines, t1 = tmass(pd, xd), vp1 = vp1, vc1 = vc1, vf1 = vf1,
        imp1 = imp1, dmp1 = dmp1, mach1 = mach1 }
end

local bg = grade(del_union(multi_bg))
local bg2 = grade(del_union(multi_bg2))
local bx = grade(del_xv(multi_bg))
local bx2 = grade(del_xv(multi_bg2))

local function vfmt(p, g)
    return string.format(
        " %s_st=%s %s_ndel=%d %s_n1=%d %s_rdist=%.4g %s_newRaw=%.4g %s_T1=%.6g %s_Vp1=%.6g %s_Vc1=%.6g %s_Vf1=%.6g" ..
        " %s_imp1=%.6g %s_dmp1=%.6g %s_mach1=%.6g",
        p, g.st, p, g.ndel or 0, p, g.n1 or 0, p, g.rdist or 0, p, g.nraw or 0, p, g.t1 or 0,
        p, g.vp1 or 0, p, g.vc1 or 0, p, g.vf1 or 0, p, g.imp1 or 0, p, g.dmp1 or 0, p, g.mach1 or 0)
end
io.write(string.format(
    "mc n0=%d nbg=%d nbg2=%d nmbg=%d nmbg2=%d udiv=%d solves=%d" ..
    " T0=%.6g Vp0=%.6g Vc0=%.6g Vf0=%.6g imp0=%.6g dmp0=%.6g mach0=%.6g",
    n0, nbg, nbg2, #multi_bg, #multi_bg2, udiv, solves,
    t0m, vp0, vc0, vf0, imp0, dmp0, mach0)
    .. vfmt("bg", bg) .. vfmt("bg2", bg2) .. vfmt("bx", bx) .. vfmt("bx2", bx2)
    .. " seed=" .. fid .. "\n")
