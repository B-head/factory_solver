---@diagnostic disable: undefined-global
-- STRUCTURAL feature probe for the concentration/ideal question (2026-07-04,
-- user-proposed candidates): per active violation-elastic, emit graph-position
-- features that the ct data does not have yet. NO perturbation solves -- one
-- baseline L2 solve + BFS on the material graph. Joined offline with the
-- conc2_c*.txt responses on (seed, mat, kind).
--   dT   = BFS hops (ingredient<->product edges, undirected, bridges included)
--          from E's material to the NEAREST TARGET material (-1 unreachable)
--   sccT = 1 if E's material shares a cyclic SCC with any target material
--   dV   = BFS hops to the nearest OTHER active violation material (-1 none)
--   shRV = # of lines touching E's material that also touch another active
--          violation material ("connected by which recipes" -- shared-recipe count)
--   nbV  = # of distinct other active violation materials at distance 1
--   run via run_corpus.ps1 -Collect '^cf'
require "tests/headless_env"
local R = require "tests/research/research_lib"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local D = R.dissect

local VQ, VF, EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"
local function vname(t) return tn.typed_name_to_variable_name(t) end

local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("cf ERR=load seed=" .. fid .. "\n"); return end

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

local base = build()
local x0, st0 = R.drive_solve(base, prob.meta)
if st0 ~= "finished" then io.write("cf ERR=baseline seed=" .. fid .. "\n"); return end

local lines = D.all_lines(prob.normalized_lines, base)
local scc = D.cyclic_sccs(lines)

-- material adjacency (ingredient<->product through a line, undirected) and the
-- per-line material sets for shRV
local adj, line_mats = {}, {}
for li, line in ipairs(lines) do
    local prods, ings = {}, {}
    for _, p in ipairs(line.products) do prods[#prods + 1] = vname(p) end
    if line.fuel_burnt_result then prods[#prods + 1] = vname(line.fuel_burnt_result) end
    for _, ig in ipairs(line.ingredients) do ings[#ings + 1] = vname(ig) end
    if line.fuel_ingredient then ings[#ings + 1] = vname(line.fuel_ingredient) end
    local mats = {}
    for _, m in ipairs(prods) do mats[m] = true end
    for _, m in ipairs(ings) do mats[m] = true end
    line_mats[li] = mats
    for _, mi in ipairs(ings) do
        for _, mp in ipairs(prods) do
            if mi ~= mp then
                local a = adj[mi]; if not a then a = {}; adj[mi] = a end; a[mp] = true
                local b = adj[mp]; if not b then b = {}; adj[mp] = b end; b[mi] = true
            end
        end
    end
end

-- target materials: primals of kind elastic/headroom carry .material
local target_mats = {}
for _, p in pairs(base.primals) do
    if (p.kind == "elastic" or p.kind == "headroom") and p.material then target_mats[p.material] = true end
end

-- active violation elastics
local active = {}
local viol_mats = {}
for k, p in pairs(base.primals) do
    if (p.kind == "shortage_source" or p.kind == "surplus_sink") then
        local v = phys(base, k, x0)
        if v > 1e-6 then
            active[#active + 1] = { key = k, mat = p.material, kind = p.kind, xv = v }
            viol_mats[p.material] = true
        end
    end
end
if #active == 0 then io.write("cf NOACTIVE seed=" .. fid .. "\n"); return end

local function bfs(src)
    local dist = { [src] = 0 }
    local q, qi = { src }, 1
    while qi <= #q do
        local m = q[qi]; qi = qi + 1
        local a = adj[m]
        if a then
            for n in pairs(a) do
                if dist[n] == nil then dist[n] = dist[m] + 1; q[#q + 1] = n end
            end
        end
    end
    return dist
end

-- one BFS per distinct active material (imp+dump share it)
local bfs_cache = {}
for _, e in ipairs(active) do
    if not bfs_cache[e.mat] then bfs_cache[e.mat] = bfs(e.mat) end
end

for _, e in ipairs(active) do
    local dist = bfs_cache[e.mat]
    local dT, dV = -1, -1
    for m in pairs(target_mats) do
        local d = dist[m]
        if d and (dT < 0 or d < dT) then dT = d end
    end
    for m in pairs(viol_mats) do
        if m ~= e.mat then
            local d = dist[m]
            if d and (dV < 0 or d < dV) then dV = d end
        end
    end
    local tag = scc.tag[e.mat]
    local sccT = 0
    if tag then
        for m in pairs(target_mats) do if scc.tag[m] == tag then sccT = 1; break end end
    end
    local shRV = 0
    for li in ipairs(lines) do
        local mats = line_mats[li]
        if mats[e.mat] then
            for m in pairs(mats) do
                if m ~= e.mat and viol_mats[m] then shRV = shRV + 1; break end
            end
        end
    end
    local nbV = 0
    local a = adj[e.mat]
    if a then for m in pairs(a) do if viol_mats[m] then nbV = nbV + 1 end end end
    io.write(string.format("cf dT=%d sccT=%d dV=%d shRV=%d nbV=%d xv=%.6g kind=%d seed=%s mat=%s\n",
        dT, sccT, dV, shRV, nbV, e.xv, e.kind == "surplus_sink" and 1 or 0, fid, e.mat))
end
