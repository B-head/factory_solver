---@diagnostic disable: undefined-global
-- STRUCTURAL elastic-necessity probe (2026-07-06). Tests the long-standing
-- "one elastic per cycle + per parallel path" infeasibility hypothesis against
-- an empirical count of structurally-forced violations.
--
-- Setup (user's diagnostic): drop the target (constraints kept only as reachability
-- anchors, made non-binding via limit_type "lower"/amount 0), force EVERY real
-- recipe to run (machine count >= 1). Then, per BASE-MATERIAL group of active
-- elastics, delete the whole group (all temperature variants + import/dump twins)
-- and re-solve: infeasible => that material's violation is structurally UNAVOIDABLE
-- (cannot balance internally even with all recipes running); feasible => avoidable.
-- (Necessity is a group property -- single hatches always substitute via recipe-
-- level freedom and temperature siblings -- so we remove whole base-material groups.)
--
-- Alongside the empirical n_unavoid, emit STRUCTURAL predictors on the INTERMEDIATE
-- material graph (free raws/outputs excluded -- flow leaves there for free, so they
-- break cycles):
--   cyclo  = circuit rank (undirected) = E - V + WCC   -- "independent cycles"
--   nscc   = # nontrivial SCCs (size>=2 or self-loop)  -- cyclic material clusters
--   ncyc   = # intermediate materials inside those SCCs
--   parP   = sum over materials of max(0, producers-1) -- "parallel producers"
--   parC   = sum over materials of max(0, consumers-1) -- "parallel consumers"
-- Then agg checks whether n_unavoid tracks cyclo / parP+parC / something else.
--   lua tests/research/probe_forced_necessity.lua <dump>   (run_corpus.ps1 -Collect '^fn')
require "tests/headless_env"
local R = require "tests/research/research_lib"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local EPS, PROBE_CAP = 2 ^ -10, 50
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"
local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("fn ERR=load seed=" .. fid .. "\n"); return end

local function mat_base(m) return (m:gsub("@%[.-%]$", "")) end
local function bmat(v) return (v.type or "?") .. "/" .. (v.name or "?") end
local function phys(p, k, x)
    local pr, t = p.primals[k], p.subject_terms[k]
    local c = (pr and pr.material and t and t[pr.material]) or 1
    return math.abs(c * (x[k] or 0))
end

-- non-binding anchor constraints (keep recipe set active, no target)
local anchor = {}
for _, c in ipairs(prob.constraints) do
    anchor[#anchor + 1] = { type = c.type, name = c.name, quality = c.quality, limit_type = "lower", limit_amount_per_second = 0 }
end
local function build()
    local p = cp.create_problem("l2", anchor, prob.normalized_lines, nil,
        { reachability_gating = false, deficit_seeding = false, catalyst_closure = false,
          surplus_sink_gating = false, recipe_epsilon = EPS })
    -- collect recipe keys FIRST (add_lower_limit_constraint mutates p.primals via
    -- its neg_slack, so adding inside a pairs(p.primals) loop corrupts iteration)
    local recs = {}
    for k, pr in pairs(p.primals) do if pr.kind == "recipe" then recs[#recs + 1] = k end end
    for _, k in ipairs(recs) do -- real recipes only (bridge is a separate kind)
        local dual = "forcerec/" .. k
        p:add_lower_limit_constraint(dual, 1)
        p:add_subject_term(k, dual, 1)
    end
    cp.shape_l2(p, 2 ^ 11, 2 ^ -8)
    return p
end
local function del(p, keys)
    for _, k in ipairs(keys) do p:set_quad(k, 0); p.primals[k] = nil; p.subject_terms[k] = nil end
    local ks = {}
    for k in pairs(p.primals) do ks[#ks + 1] = k end
    table.sort(ks)
    for i, k in ipairs(ks) do p.primals[k].index = i end
    p.primal_length = #ks
end

local base = build()
local x0, st0 = R.drive_solve(base, prob.meta)
if st0 ~= "finished" then io.write(("fn st=%s seed=%s\n"):format(tostring(st0), fid)); return end

-- free materials (raw source / final sink) -- excluded from the intermediate graph
local free = {}
for _, pr in pairs(base.primals) do
    if (pr.kind == "initial_source" or pr.kind == "final_sink") and pr.material then
        free[mat_base(pr.material)] = true
    end
end

-- intermediate material graph from real lines
local nodes = {}                            -- base material -> true (intermediates)
local producers, consumers = {}, {}         -- base material -> count of distinct recipes
local edges = {}                            -- "a|b" undirected simple edge set
local adj = {}                              -- directed adjacency ingredient->product
local function node(m) if not free[m] then nodes[m] = true end end
for _, line in ipairs(prob.normalized_lines) do
    if not line.is_bridge then
        local prods, ings = {}, {}
        for _, v in ipairs(line.products or {}) do local m = bmat(v); if not free[m] then prods[m] = true end end
        for _, v in ipairs(line.ingredients or {}) do local m = bmat(v); if not free[m] then ings[m] = true end end
        for m in pairs(prods) do node(m); producers[m] = (producers[m] or 0) + 1 end
        for m in pairs(ings) do node(m); consumers[m] = (consumers[m] or 0) + 1 end
        for a in pairs(ings) do
            for b in pairs(prods) do
                adj[a] = adj[a] or {}; adj[a][b] = true
                local e = (a < b) and (a .. "|" .. b) or (b .. "|" .. a)
                edges[e] = true
            end
        end
    end
end
local V, E = 0, 0
for _ in pairs(nodes) do V = V + 1 end
for _ in pairs(edges) do E = E + 1 end
-- weakly-connected components (union-find on undirected edges)
local uf = {}
local function find(a) while uf[a] and uf[a] ~= a do uf[a] = uf[uf[a]] or uf[a]; a = uf[a] end return a end
for m in pairs(nodes) do uf[m] = m end
for e in pairs(edges) do local a, b = e:match("^(.-)|(.+)$"); local ra, rb = find(a), find(b); if ra ~= rb then uf[ra] = rb end end
local wcc = {}
for m in pairs(nodes) do wcc[find(m)] = true end
local WCC = 0; for _ in pairs(wcc) do WCC = WCC + 1 end
local cyclo = E - V + WCC
-- Tarjan SCC (iterative) for nontrivial cyclic clusters
local idx, low, onst, stk, instk, order, sccid = {}, {}, {}, {}, {}, 0, {}
local nscc_all = 0
local sccsize = {}
local function selfloop(m) return adj[m] and adj[m][m] end
for s in pairs(nodes) do
    if not idx[s] then
        local work = { { s, false } }
        while #work > 0 do
            local top = work[#work]
            local v, started = top[1], top[2]
            if not started then
                order = order + 1; idx[v] = order; low[v] = order; stk[#stk + 1] = v; instk[v] = true; top[2] = true
            end
            local pushed = false
            if adj[v] then
                for w in pairs(adj[v]) do
                    if not idx[w] then
                        top._w = w; work[#work + 1] = { w, false }; pushed = true; break
                    elseif instk[w] and idx[w] < low[v] then low[v] = idx[w] end
                end
            end
            if not pushed then
                -- returned from children: relax lows
                if adj[v] then for w in pairs(adj[v]) do if instk[w] and low[w] < low[v] then low[v] = low[w] end end end
                if low[v] == idx[v] then
                    nscc_all = nscc_all + 1
                    local sz = 0
                    while true do local u = stk[#stk]; stk[#stk] = nil; instk[u] = false; sccid[u] = nscc_all; sz = sz + 1; if u == v then break end end
                    sccsize[nscc_all] = sz
                end
                work[#work] = nil
            end
        end
    end
end
local nscc, ncyc = 0, 0
for id, sz in pairs(sccsize) do
    if sz >= 2 then nscc = nscc + 1; ncyc = ncyc + sz end
end
-- also count self-loop singletons as cyclic
for m in pairs(nodes) do if selfloop(m) and sccsize[sccid[m]] == 1 then nscc = nscc + 1; ncyc = ncyc + 1 end end
local parP, parC = 0, 0
for m in pairs(nodes) do parP = parP + math.max(0, (producers[m] or 0) - 1); parC = parC + math.max(0, (consumers[m] or 0) - 1) end

-- empirical: base-material group necessity under forced recipes.
-- Two measures, both in one pass:
--   n_unavoid = groups whose SOLO removal (all others present) is infeasible =
--               "definitely necessary" (in every feasible set) -- a LOWER bound.
--   n_min     = size of a MINIMAL necessary set found by greedy cumulative removal
--               (smallest group first, keep each removal that stays feasible) --
--               an UPPER bound on the true minimum elastics needed.
local groups, order2, gphys = {}, {}, {}
for k, pr in pairs(base.primals) do
    if (pr.kind == "shortage_source" or pr.kind == "surplus_sink") and phys(base, k, x0) > 1e-6 then
        local b = mat_base(pr.material or "?")
        if not groups[b] then groups[b] = {}; order2[#order2 + 1] = b; gphys[b] = 0 end
        groups[b][#groups[b] + 1] = k
        gphys[b] = gphys[b] + phys(base, k, x0)
    end
end
local n_grp = #order2
local trunc = (n_grp > PROBE_CAP) and 1 or 0
table.sort(order2, function(a, b) return gphys[a] < gphys[b] end) -- smallest first
local probe_list = {}
for i = 1, math.min(n_grp, PROBE_CAP) do probe_list[i] = order2[i] end

-- solo removals (lower bound)
local n_unavoid = 0
for _, b in ipairs(probe_list) do
    local p = build(); del(p, groups[b])
    local _, st = R.drive_solve(p, prob.meta)
    if st ~= "finished" then n_unavoid = n_unavoid + 1 end
end
-- greedy cumulative removal (minimal set)
local removed = {}
local n_kept = 0
for _, b in ipairs(probe_list) do
    local trial = {}
    for _, k in ipairs(removed) do trial[#trial + 1] = k end
    for _, k in ipairs(groups[b]) do trial[#trial + 1] = k end
    local p = build(); del(p, trial)
    local _, st = R.drive_solve(p, prob.meta)
    if st == "finished" then
        for _, k in ipairs(groups[b]) do removed[#removed + 1] = k end
    else
        n_kept = n_kept + 1 -- this group could not be removed => necessary in this greedy set
    end
end
local n_min = n_kept + (n_grp - #probe_list) -- untested groups (beyond cap) counted as kept

io.write(string.format(
    "fn n_rec=%d n_mat=%d n_grp=%d n_unavoid=%d n_min=%d trunc=%d cyclo=%d nscc=%d ncyc=%d parP=%d parC=%d E=%d V=%d seed=%s\n",
    (function() local n = 0 for _, pr in pairs(base.primals) do if pr.kind == "recipe" then n = n + 1 end end return n end)(),
    V, n_grp, n_unavoid, n_min, trunc, cyclo, nscc, ncyc, parP, parC, E, V, fid))
