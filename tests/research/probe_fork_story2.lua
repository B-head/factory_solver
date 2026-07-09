---@diagnostic disable: undefined-global
-- v2 identity check. Differences from probe_fork_story.lua:
--   * The material graph is built from the LP's subject_terms (recipe+bridge
--     primals, coef>0 = produce / coef<0 = consume), NOT from the lines'
--     products/ingredients arrays. This captures fuel/burnt_result edges and
--     every temperature-window variant node exactly as the LP sees them.
--   * Nodes are window-level variants (no base folding); a greedy group (base
--     material) is classified over ALL its variant nodes.
--   * Fork siblings include FREE materials (a rigid junction constrains a
--     branch even when its siblings can escape for free).
-- Per-SCC stats for the "2+ elastics <=> SCC contains a different-material
-- parallel path" hypothesis: for every nontrivial SCC report kept count,
-- internal fork recipes (producing/consuming >=2 mats inside the SCC), and
-- boundary fork recipes (co-producing SCC + non-SCC materials).
--   luajit tests/research/probe_fork_story2.lua <dump> [quiet]
require "tests/headless_env"
local R = require "tests/research/research_lib"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local EPS, PROBE_CAP = 2 ^ -10, 50
local PATH = arg[1]
local QUIET = arg[2] == "quiet"
local fid = (PATH or "?"):match("[^/\\]+$") or "?"
local prob = assert(problem_dump.load_problem(PATH))

local function norm_mat(m)
    m = m:gsub("@%[.-%]$", "")
    local t, rest = m:match("^([^/]+)/(.+)$")
    if t == "item" then rest = rest:gsub("/[^/]+$", "") end
    return (t or "?") .. "/" .. (rest or m)
end
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
if st0 ~= "finished" then io.write(("fs2 st=%s seed=%s\n"):format(tostring(st0), fid)); return end

local free = {}
for _, pr in pairs(base.primals) do
    if (pr.kind == "initial_source" or pr.kind == "final_sink") and pr.material then
        free[pr.material] = true
    end
end

-- graph from subject_terms over recipe+bridge primals
local producers, consumers, coP, coC, adj = {}, {}, {}, {}, {}
local rprods, rcons = {}, {} -- recipe key -> array of material nodes
for key, pr in pairs(base.primals) do
    if pr.kind == "recipe" or pr.kind == "bridge" then
        local ps, is = {}, {}
        for cname, coef in pairs(base.subject_terms[key] or {}) do
            if cname:sub(1, 1) ~= "|" and not cname:find("^forcerec/") then
                if coef > 0 then ps[#ps + 1] = cname
                elseif coef < 0 then is[#is + 1] = cname end
            end
        end
        rprods[key], rcons[key] = ps, is
        for _, m in ipairs(ps) do
            producers[m] = producers[m] or {}; producers[m][key] = true
            coP[m] = coP[m] or {}
            for _, s in ipairs(ps) do if s ~= m then coP[m][s] = true end end
        end
        for _, m in ipairs(is) do
            consumers[m] = consumers[m] or {}; consumers[m][key] = true
            coC[m] = coC[m] or {}
            for _, s in ipairs(is) do if s ~= m then coC[m][s] = true end end
        end
        for _, a in ipairs(is) do
            if not free[a] then
                adj[a] = adj[a] or {}
                for _, b in ipairs(ps) do if not free[b] then adj[a][b] = true end end
            end
        end
    end
end
local function count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end return n end

-- Self-loop patch: subject_terms hold NET coefficients, so a recipe consuming
-- and producing the same material (growth loops like moss-mk04r 0.02->0.05,
-- perfect catalysts like quartz-tube 0.3333->0.3333 whose net-0 term vanishes
-- entirely) loses its self-edge. Recover it from the raw lines at base level.
local selfloop_base = {}
for _, line in ipairs(prob.normalized_lines) do
    if not line.is_bridge then
        local pb = {}
        for _, v in ipairs(line.products or {}) do pb[(v.type or "?") .. "/" .. (v.name or "?")] = true end
        for _, v in ipairs(line.ingredients or {}) do
            local b = (v.type or "?") .. "/" .. (v.name or "?")
            if pb[b] then selfloop_base[b] = true end
        end
    end
end

local nodes, basenodes = {}, {}
local function reg(m)
    nodes[m] = true
    local b = norm_mat(m)
    basenodes[b] = basenodes[b] or {}
    basenodes[b][m] = true
end
for m in pairs(producers) do reg(m) end
for m in pairs(consumers) do reg(m) end

-- Tarjan over free-excluded digraph
local idx, low, stk, instk, order, sccid, sccsize = {}, {}, {}, {}, 0, {}, {}
local nscc_all = 0
for s in pairs(nodes) do
    if not free[s] and not idx[s] then
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
local function in_cycle(m)
    local id = sccid[m]
    return (id and sccsize[id] >= 2) or (adj[m] and adj[m][m] and true)
        or selfloop_base[norm_mat(m)] or false
end

-- per-SCC internal/boundary fork stats
local sccPF, sccCF, sccXF = {}, {}, {} -- sccid -> counts of fork recipes
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
        if n >= 1 and #rprods[key] > n then sccXF[id] = (sccXF[id] or 0) + 1 end
    end
    for id, n in pairs(byscc_c) do
        if n >= 2 then sccCF[id] = (sccCF[id] or 0) + 1 end
    end
end

-- greedy over base groups (unchanged protocol)
local groups, order2, gphys = {}, {}, {}
for k, pr in pairs(base.primals) do
    if (pr.kind == "shortage_source" or pr.kind == "surplus_sink") and phys(base, k, x0) > 1e-6 then
        local b = norm_mat(pr.material or "?")
        if not groups[b] then groups[b] = {}; order2[#order2 + 1] = b; gphys[b] = 0 end
        groups[b][#groups[b] + 1] = k
        gphys[b] = gphys[b] + phys(base, k, x0)
    end
end
table.sort(order2, function(a, b) return gphys[a] < gphys[b] end)

local function classify(b)
    for m in pairs(basenodes[b] or {}) do if in_cycle(m) then return "scc" end end
    for m in pairs(basenodes[b] or {}) do
        if count(coP[m]) > 0 or count(coC[m]) > 0 then return "fork" end
    end
    return "other"
end

io.write(("== %s  groups=%d\n"):format(fid, #order2))
local removed, keptlist = {}, {}
local per_scc = {}
for i, b in ipairs(order2) do
    if i > PROBE_CAP then break end
    local trial = {}
    for _, k in ipairs(removed) do trial[#trial + 1] = k end
    for _, k in ipairs(groups[b]) do trial[#trial + 1] = k end
    local p = build(); del(p, trial)
    local _, st = R.drive_solve(p, prob.meta)
    local cls = classify(b)
    if st == "finished" then
        for _, k in ipairs(groups[b]) do removed[#removed + 1] = k end
        if not QUIET then io.write(("  removed %-40s %-6s phys=%.4g\n"):format(b, cls, gphys[b])) end
    else
        keptlist[#keptlist + 1] = b
        io.write(("  KEPT    %-40s %-6s phys=%.4g\n"):format(b, cls, gphys[b]))
        for m in pairs(basenodes[b] or {}) do
            if in_cycle(m) then per_scc[sccid[m]] = (per_scc[sccid[m]] or 0) + 1; break end
        end
    end
end
io.write(("-- n_min=%d  cls: scc=%d fork=%d other=%d\n"):format(#keptlist,
    (function() local n = 0 for _, b in ipairs(keptlist) do if classify(b) == "scc" then n = n + 1 end end return n end)(),
    (function() local n = 0 for _, b in ipairs(keptlist) do if classify(b) == "fork" then n = n + 1 end end return n end)(),
    (function() local n = 0 for _, b in ipairs(keptlist) do if classify(b) == "other" then n = n + 1 end end return n end)()))
for id, sz in pairs(sccsize) do
    if sz >= 2 then
        io.write(("-- SCC %d size=%d kept=%d prodFork=%d consFork=%d extFork=%d\n")
            :format(id, sz, per_scc[id] or 0, sccPF[id] or 0, sccCF[id] or 0, sccXF[id] or 0))
    end
end
