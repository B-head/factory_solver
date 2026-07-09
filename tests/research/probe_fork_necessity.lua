---@diagnostic disable: undefined-global
-- Corpus aggregation of the fork-necessity identity check (one line per dump).
-- Same forced-recipe greedy minimal-set as probe_forced_necessity.lua, with the
-- KEY FIX: one normalized material key everywhere (the original's free-material
-- exclusion never matched items, so its nscc was computed on a graph that
-- wrongly kept free items as cycle-carrying nodes).
-- Classifies every kept (= necessary in the greedy set) group:
--   kScc   inside a nontrivial SCC (size>=2 or self-loop) of the free-excluded
--          intermediate digraph
--   kFork  acyclic but co-produced or co-consumed with other non-free materials
--          (a rigid multi-output/multi-input junction branch)
--   kOther neither -- the residual the SCC+fork law does not explain
-- Plus per-SCC kept tallies (sccK0/K1/K2p) for "at most ~1 per SCC", and the
-- same classification denominators over REMOVED groups (fork precision).
--   luajit tests/research/probe_fork_necessity.lua <dump>
require "tests/headless_env"
local R = require "tests/research/research_lib"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local EPS, PROBE_CAP = 2 ^ -10, 50
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"
local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("fk ERR=load seed=" .. fid .. "\n"); return end

local function norm_mat(m)
    m = m:gsub("@%[.-%]$", "")
    local t, rest = m:match("^([^/]+)/(.+)$")
    if t == "item" then rest = rest:gsub("/[^/]+$", "") end
    return (t or "?") .. "/" .. (rest or m)
end
local function bmat(v) return (v.type or "?") .. "/" .. (v.name or "?") end
local function phys(p, k, x)
    local pr, t = p.primals[k], p.subject_terms[k]
    local c = (pr and pr.material and t and t[pr.material]) or 1
    return math.abs(c * (x[k] or 0))
end

local anchor = {}
for _, c in ipairs(prob.constraints) do
    anchor[#anchor + 1] = { type = c.type, name = c.name, quality = c.quality,
        limit_type = "lower", limit_amount_per_second = 0 }
end
local function build()
    local p = cp.create_problem("l2", anchor, prob.normalized_lines, nil,
        { reachability_gating = false, deficit_seeding = false, catalyst_closure = false,
            surplus_sink_gating = false, recipe_epsilon = EPS })
    local recs = {}
    for k, pr in pairs(p.primals) do if pr.kind == "recipe" then recs[#recs + 1] = k end end
    for _, k in ipairs(recs) do
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
if st0 ~= "finished" then io.write(("fk st=%s seed=%s\n"):format(tostring(st0), fid)); return end

local free = {}
for _, pr in pairs(base.primals) do
    if (pr.kind == "initial_source" or pr.kind == "final_sink") and pr.material then
        free[norm_mat(pr.material)] = true
    end
end

local producers, consumers, coP, coC, adj = {}, {}, {}, {}, {}
for _, line in ipairs(prob.normalized_lines) do
    if not line.is_bridge then
        local rname = line.recipe_typed_name and line.recipe_typed_name.name or "?"
        local prods, ings = {}, {}
        for _, v in ipairs(line.products or {}) do prods[bmat(v)] = true end
        for _, v in ipairs(line.ingredients or {}) do ings[bmat(v)] = true end
        for m in pairs(prods) do
            producers[m] = producers[m] or {}; producers[m][rname] = true
            coP[m] = coP[m] or {}
            for s in pairs(prods) do if s ~= m and not free[s] then coP[m][s] = true end end
        end
        for m in pairs(ings) do
            consumers[m] = consumers[m] or {}; consumers[m][rname] = true
            coC[m] = coC[m] or {}
            for s in pairs(ings) do if s ~= m and not free[s] then coC[m][s] = true end end
        end
        for a in pairs(ings) do
            if not free[a] then
                adj[a] = adj[a] or {}
                for b in pairs(prods) do if not free[b] then adj[a][b] = true end end
            end
        end
    end
end
local function count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end return n end

local nodes = {}
for m in pairs(producers) do if not free[m] then nodes[m] = true end end
for m in pairs(consumers) do if not free[m] then nodes[m] = true end end
local idx, low, stk, instk, order, sccid, sccsize = {}, {}, {}, {}, 0, {}, {}
local nscc_all = 0
for s in pairs(nodes) do
    if not idx[s] then
        local work = { { s, false } }
        while #work > 0 do
            local top = work[#work]
            local v, started = top[1], top[2]
            if not started then
                order = order + 1; idx[v] = order; low[v] = order
                stk[#stk + 1] = v; instk[v] = true; top[2] = true
            end
            local pushed = false
            if adj[v] then
                for w in pairs(adj[v]) do
                    if nodes[w] then
                        if not idx[w] then
                            work[#work + 1] = { w, false }; pushed = true; break
                        elseif instk[w] and idx[w] < low[v] then low[v] = idx[w] end
                    end
                end
            end
            if not pushed then
                if adj[v] then
                    for w in pairs(adj[v]) do
                        if nodes[w] and instk[w] and low[w] < low[v] then low[v] = low[w] end
                    end
                end
                if low[v] == idx[v] then
                    nscc_all = nscc_all + 1
                    while true do
                        local u = stk[#stk]; stk[#stk] = nil; instk[u] = false
                        sccid[u] = nscc_all
                        sccsize[nscc_all] = (sccsize[nscc_all] or 0) + 1
                        if u == v then break end
                    end
                end
                work[#work] = nil
            end
        end
    end
end
local function in_cycle(m)
    local id = sccid[m]
    return (id and sccsize[id] >= 2) or (adj[m] and adj[m][m] and true) or false
end
local nsccG = 0
for id, sz in pairs(sccsize) do
    if sz >= 2 then nsccG = nsccG + 1 end
end
for m in pairs(nodes) do
    if adj[m] and adj[m][m] and sccsize[sccid[m]] == 1 then nsccG = nsccG + 1 end
end

local groups, order2, gphys = {}, {}, {}
for k, pr in pairs(base.primals) do
    if (pr.kind == "shortage_source" or pr.kind == "surplus_sink") and phys(base, k, x0) > 1e-6 then
        local b = norm_mat(pr.material or "?")
        if not groups[b] then groups[b] = {}; order2[#order2 + 1] = b; gphys[b] = 0 end
        groups[b][#groups[b] + 1] = k
        gphys[b] = gphys[b] + phys(base, k, x0)
    end
end
local n_grp = #order2
local trunc = (n_grp > PROBE_CAP) and 1 or 0
table.sort(order2, function(a, b) return gphys[a] < gphys[b] end)

local function classify(b)
    if in_cycle(b) then return "scc" end
    if count(coP[b]) > 0 or count(coC[b]) > 0 then return "fork" end
    return "other"
end

local removed, kept = {}, {}
local rCls, kCls = { scc = 0, fork = 0, other = 0 }, { scc = 0, fork = 0, other = 0 }
local per_scc = {}
for i, b in ipairs(order2) do
    if i > PROBE_CAP then break end
    local trial = {}
    for _, k in ipairs(removed) do trial[#trial + 1] = k end
    for _, k in ipairs(groups[b]) do trial[#trial + 1] = k end
    local p = build(); del(p, trial)
    local _, st = R.drive_solve(p, prob.meta)
    if st == "finished" then
        for _, k in ipairs(groups[b]) do removed[#removed + 1] = k end
        rCls[classify(b)] = rCls[classify(b)] + 1
    else
        kept[#kept + 1] = b
        kCls[classify(b)] = kCls[classify(b)] + 1
        if in_cycle(b) and sccid[b] then per_scc[sccid[b]] = (per_scc[sccid[b]] or 0) + 1 end
    end
end
local sccK0, sccK1, sccK2p = 0, 0, 0
for id, sz in pairs(sccsize) do
    if sz >= 2 then
        local n = per_scc[id] or 0
        if n == 0 then sccK0 = sccK0 + 1 elseif n == 1 then sccK1 = sccK1 + 1 else sccK2p = sccK2p + 1 end
    end
end
-- kept fork/other material names for later story reads (comma list, no spaces)
local knames = {}
for _, b in ipairs(kept) do
    local c = classify(b)
    if c ~= "scc" then knames[#knames + 1] = b:gsub("^%w+/", "") .. ":" .. c end
end
io.write(string.format(
    "fk n_grp=%d n_min=%d kScc=%d kFork=%d kOther=%d rScc=%d rFork=%d rOther=%d nsccG=%d sccK0=%d sccK1=%d sccK2p=%d trunc=%d knames=%s seed=%s\n",
    n_grp, #kept + (n_grp - math.min(n_grp, PROBE_CAP)),
    kCls.scc, kCls.fork, kCls.other, rCls.scc, rCls.fork, rCls.other,
    nsccG, sccK0, sccK1, sccK2p, trunc,
    (#knames > 0) and table.concat(knames, ",") or "-", fid))
