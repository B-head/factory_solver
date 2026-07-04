---@diagnostic disable: undefined-global
-- MODE-COMPRESSION pipeline, corpus driver (2026-07-04). Per dump:
--   1. baseline L2 solve
--   2. per-active-elastic quad-free perturbation solves (cap PERTCAP by phys
--      desc; trunc flagged -- no silent caps)
--   3. greedy |cos|>=0.85 clustering of dx over REAL-recipe components
--   4. per multi-member cluster: union-free solve -> winner (largest phys)
--   5. delete every non-winner member (quads untouched), ONE re-solve
--   6. grade: channel count, rdist, newRaw, and problem-definition classes
--      T (target elastics), Vp/Vc/Vf via reference_solver's fixpoint sets
--      (variable-space sums, per-kind normalized; same-dump before/after only)
-- Emits one 'md' line per dump (run via run_corpus.ps1 -Collect '^md').
--   lua tests/research/probe_mode_compress.lua <dump>
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

local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("md ERR=load seed=" .. fid .. "\n"); return end

local function build()
    local p = create_problem.create_problem("l2", prob.constraints, prob.normalized_lines, nil,
        { reachability_gating = false, deficit_seeding = false, catalyst_closure = false,
          surplus_sink_gating = false, recipe_epsilon = EPS })
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

local base = build()
local x0, st0 = R.drive_solve(base, prob.meta)
if st0 ~= "finished" then io.write("md ERR=baseline seed=" .. fid .. "\n"); return end

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
        if (p.kind == "shortage_source" or p.kind == "surplus_sink") and phys(problem, k, x) > 1e-6 then
            n = n + 1
        end
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
if #active == 0 then io.write("md NOACTIVE seed=" .. fid .. "\n"); return end
table.sort(active, function(a, b) return a.xv > b.xv end)
local n0 = #active
local trunc = 0
if #active > PERTCAP then trunc = 1 end

-- perturbation solves
local resp, pdiv = {}, 0
for i = 1, math.min(#active, PERTCAP) do
    local e = active[i]
    local problem = build(); problem:set_quad(e.key, 0)
    local x1, st1 = R.drive_solve(problem, prob.meta)
    if st1 ~= "finished" then pdiv = pdiv + 1
    else
        local dx = dxof(x1)
        resp[#resp + 1] = { e = e, dx = dx, rnorm = real_norm(dx) }
    end
end
table.sort(resp, function(a, b) return a.rnorm > b.rnorm end)

-- clustering
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

-- union winners + collect deletions
local all_del, nmulti, udiv = {}, 0, 0
for _, cl in ipairs(clusters) do
    if cl.n >= 2 then
        nmulti = nmulti + 1
        local pu = build()
        for _, m in ipairs(cl.members) do pu:set_quad(m.e.key, 0) end
        local xu, stu = R.drive_solve(pu, prob.meta)
        if stu ~= "finished" then udiv = udiv + 1 end
        local winner, wv = nil, -1
        for _, m in ipairs(cl.members) do
            local v = (stu == "finished") and phys(pu, m.e.key, xu) or m.e.xv
            if v > wv then wv = v; winner = m end
        end
        for _, m in ipairs(cl.members) do
            if m ~= winner then all_del[#all_del + 1] = m.e.key end
        end
    end
end

if #all_del == 0 then
    io.write(("md NODEL n0=%d ncl=%d trunc=%d pdiv=%d seed=%s\n"):format(n0, #clusters, trunc, pdiv, fid))
    return
end

-- classification sets (fixpoints) for the grade
local inter = RS.intermediates(prob.normalized_lines)
local producible = RS.producible_set(prob.constraints, prob.normalized_lines)
local consumable = RS.consumable_set(prob.constraints, prob.normalized_lines)
local vp0, vc0, vf0 = RS.violation_split(base, x0, inter, producible, consumable)
local t0 = tmass(base, x0)

-- delete + one re-solve
local pd = build()
delete_keys(pd, all_del)
local xd, std = R.drive_solve(pd, prob.meta)
if std ~= "finished" then
    io.write(("md st=%s n0=%d ndel=%d ncl=%d nmulti=%d trunc=%d pdiv=%d udiv=%d seed=%s\n")
        :format(tostring(std), n0, #all_del, #clusters, nmulti, trunc, pdiv, udiv, fid))
    return
end
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
local t1 = tmass(pd, xd)

io.write(string.format(
    "md st=ok n0=%d n1=%d ndel=%d ncl=%d nmulti=%d trunc=%d pdiv=%d udiv=%d rdist=%.4g newRaw=%.4g" ..
    " T0=%.6g T1=%.6g Vp0=%.6g Vp1=%.6g Vc0=%.6g Vc1=%.6g Vf0=%.6g Vf1=%.6g seed=%s\n",
    n0, count_active(pd, xd), #all_del, #clusters, nmulti, trunc, pdiv, udiv,
    rdist / base_machines, nraw / base_machines, t0, t1, vp0, vp1, vc0, vc1, vf0, vf1, fid))
