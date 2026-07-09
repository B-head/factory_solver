---@diagnostic disable: undefined-global
-- Static per-SCC features (NO solves -- just create_problem + Tarjan), to join
-- against the fk2/fs2 corpus scan and test what predicts kept>=2 SCCs:
--   nbase  distinct base materials in the SCC (the pressured-air/nitrogen pair
--          suggests kept ~ independent imbalance axes ~ base materials)
--   nrec   recipes with >=1 consumed AND >=1 produced material inside the SCC
--          (internal-edge carriers; nrec vs size gives a rank-deficiency proxy)
--   pf/cf/xf as in probe_fork_necessity2 (internal prod/cons forks, boundary)
-- Join key: (seed, size, pf, cf, xf) -- SCC ids are pairs-order unstable.
-- One 'ss' line per nontrivial SCC.
--   luajit tests/research/probe_sccstat.lua <dump>
require "tests/headless_env"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"
local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("ss ERR=load seed=" .. fid .. "\n"); return end

local function norm_mat(m)
    m = m:gsub("@%[.-%]$", "")
    local t, rest = m:match("^([^/]+)/(.+)$")
    if t == "item" then rest = rest:gsub("/[^/]+$", "") end
    return (t or "?") .. "/" .. (rest or m)
end

local anchor = {}
for _, c in ipairs(prob.constraints) do
    anchor[#anchor + 1] = { type = c.type, name = c.name, quality = c.quality,
        limit_type = "lower", limit_amount_per_second = 0 }
end
local ok, p = pcall(cp.create_problem, "l2", anchor, prob.normalized_lines, nil,
    { reachability_gating = false, deficit_seeding = false, catalyst_closure = false,
        surplus_sink_gating = false, recipe_epsilon = 2 ^ -10 })
if not ok or not p then io.write("ss ERR=build seed=" .. fid .. "\n"); return end

local free = {}
for _, pr in pairs(p.primals) do
    if (pr.kind == "initial_source" or pr.kind == "final_sink") and pr.material then
        free[pr.material] = true
    end
end
local adj, rprods, rcons = {}, {}, {}
for key, pr in pairs(p.primals) do
    if pr.kind == "recipe" or pr.kind == "bridge" then
        local ps, is = {}, {}
        for cname, coef in pairs(p.subject_terms[key] or {}) do
            if cname:sub(1, 1) ~= "|" then
                if coef > 0 then ps[#ps + 1] = cname elseif coef < 0 then is[#is + 1] = cname end
            end
        end
        rprods[key], rcons[key] = ps, is
        for _, a in ipairs(is) do
            if not free[a] then
                adj[a] = adj[a] or {}
                for _, b in ipairs(ps) do if not free[b] then adj[a][b] = true end end
            end
        end
    end
end
local nodes = {}
for a in pairs(adj) do
    nodes[a] = true
    for b in pairs(adj[a]) do nodes[b] = true end
end
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
                    if not idx[w] then
                        work[#work + 1] = { w, false }; pushed = true; break
                    elseif instk[w] and idx[w] < low[v] then low[v] = idx[w] end
                end
            end
            if not pushed then
                if adj[v] then
                    for w in pairs(adj[v]) do
                        if instk[w] and low[w] < low[v] then low[v] = low[w] end
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

local sccPF, sccCF, sccXF, sccREC = {}, {}, {}, {}
for key in pairs(rprods) do
    local byscc_p, byscc_c = {}, {}
    for _, m in ipairs(rprods[key]) do
        local id = sccid[m]
        if id and sccsize[id] >= 2 then byscc_p[id] = (byscc_p[id] or 0) + 1 end
    end
    for _, m in ipairs(rcons[key]) do
        local id = sccid[m]
        if id and sccsize[id] >= 2 then byscc_c[id] = (byscc_c[id] or 0) + 1 end
    end
    for id, n in pairs(byscc_p) do
        if n >= 2 then sccPF[id] = (sccPF[id] or 0) + 1 end
        if #rprods[key] > n then sccXF[id] = (sccXF[id] or 0) + 1 end
        if byscc_c[id] then sccREC[id] = (sccREC[id] or 0) + 1 end
    end
    for id, n in pairs(byscc_c) do
        if n >= 2 then sccCF[id] = (sccCF[id] or 0) + 1 end
    end
end
local members = {}
for m, id in pairs(sccid) do
    if sccsize[id] >= 2 then
        members[id] = members[id] or {}
        members[id][#members[id] + 1] = m
    end
end
for id, ms in pairs(members) do
    local bases = {}
    for _, m in ipairs(ms) do bases[norm_mat(m)] = true end
    local nbase = 0
    for _ in pairs(bases) do nbase = nbase + 1 end
    io.write(("ss size=%d nbase=%d nrec=%d pf=%d cf=%d xf=%d seed=%s\n")
        :format(#ms, nbase, sccREC[id] or 0, sccPF[id] or 0, sccCF[id] or 0, sccXF[id] or 0, fid))
end
