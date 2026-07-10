---@diagnostic disable: undefined-global
-- Candidate-restricted L2: delete every elastic group whose base material is
-- NOT in the v2 static candidate set (SCC member at variant level, or fork
-- sibling incl. free), then solve L2 once. Measures the "superset placement"
-- approach: is it feasible, how many elastics ACTIVATE under L2 spread, and
-- how do the physical import/dump totals compare with the all-elastic L2?
-- No greedy/minimal solve here -- join n_min from fk2_c*.txt by seed instead.
--   luajit tests/research/probe_candidate_l2.lua <dump> [verbose]
require "tests/headless_env"
local R = require "tests/research/research_lib"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local EPS = 2 ^ -10
local PATH = arg[1]
local VERBOSE = arg[2] == "verbose"
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

-- ======== baseline: all elastics ========
local base = build()
local x0, st0 = R.drive_solve(base, prob.meta)
if st0 ~= "finished" then io.write(("cl2 st_base=%s seed=%s\n"):format(tostring(st0), fid)); return end

-- ======== v2 graph + classifier (verbatim from probe_fork_necessity2) ========
local free = {}
for _, pr in pairs(base.primals) do
    if (pr.kind == "initial_source" or pr.kind == "final_sink") and pr.material then
        free[pr.material] = true
    end
end
local producers, consumers, coP, coC, adj = {}, {}, {}, {}, {}
for key, pr in pairs(base.primals) do
    if pr.kind == "recipe" or pr.kind == "bridge" then
        local ps, is = {}, {}
        for cname, coef in pairs(base.subject_terms[key] or {}) do
            if cname:sub(1, 1) ~= "|" and not cname:find("^forcerec/") then
                if coef > 0 then ps[#ps + 1] = cname
                elseif coef < 0 then is[#is + 1] = cname end
            end
        end
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
local function classify(b)
    for m in pairs(basenodes[b] or {}) do if in_cycle(m) then return "scc" end end
    for m in pairs(basenodes[b] or {}) do
        if count(coP[m]) > 0 or count(coC[m]) > 0 then return "fork" end
    end
    return "other"
end

-- ======== ALL elastic groups (not just base-active ones) ========
local groups, gorder = {}, {}
for k, pr in pairs(base.primals) do
    if pr.kind == "shortage_source" or pr.kind == "surplus_sink" then
        local b = norm_mat(pr.material or "?")
        if not groups[b] then groups[b] = {}; gorder[#gorder + 1] = b end
        groups[b][#groups[b] + 1] = k
    end
end
table.sort(gorder)

local cand, noncand_keys = {}, {}
local n_cand = 0
for _, b in ipairs(gorder) do
    local cls = classify(b)
    if cls == "scc" or cls == "fork" then
        cand[b] = cls
        n_cand = n_cand + 1
    else
        for _, k in ipairs(groups[b]) do noncand_keys[#noncand_keys + 1] = k end
    end
end

-- ======== restricted solve ========
local restr = build()
del(restr, noncand_keys)
local x1, st1 = R.drive_solve(restr, prob.meta)

-- ======== group-level stats on both solves ========
local function group_stats(p, x)
    local act6, act3, imp, dmp = 0, 0, 0, 0
    local gp = {}
    for _, b in ipairs(gorder) do
        local s_imp, s_dmp = 0, 0
        for _, k in ipairs(groups[b]) do
            if p.primals[k] then
                local v = phys(p, k, x)
                if p.primals[k].kind == "shortage_source" then s_imp = s_imp + v
                else s_dmp = s_dmp + v end
            end
        end
        local tot = s_imp + s_dmp
        if tot > 1e-6 then act6 = act6 + 1 end
        if tot > 1e-3 then act3 = act3 + 1 end
        imp = imp + s_imp; dmp = dmp + s_dmp
        gp[b] = { imp = s_imp, dmp = s_dmp }
    end
    return { act6 = act6, act3 = act3, imp = imp, dmp = dmp, gp = gp }
end
local S0 = group_stats(base, x0)
local S1 = (st1 == "finished") and group_stats(restr, x1) or nil

io.write(string.format(
    "cl2 n_grp=%d n_cand=%d st=%s base_act=%d/%d cand_act=%s/%s base_imp=%.4g base_dmp=%.4g cand_imp=%s cand_dmp=%s seed=%s\n",
    #gorder, n_cand, tostring(st1),
    S0.act6, S0.act3,
    S1 and tostring(S1.act6) or "-", S1 and tostring(S1.act3) or "-",
    S0.imp, S0.dmp,
    S1 and string.format("%.4g", S1.imp) or "-",
    S1 and string.format("%.4g", S1.dmp) or "-", fid))

if VERBOSE and S1 then
    local vs = {}
    for _, b in ipairs(gorder) do
        local a, c = S0.gp[b], S1.gp[b]
        if a.imp + a.dmp > 1e-9 or c.imp + c.dmp > 1e-9 then
            vs[#vs + 1] = { b = b, a = a, c = c }
        end
    end
    table.sort(vs, function(p_, q_) return (p_.c.imp + p_.c.dmp) > (q_.c.imp + q_.c.dmp) end)
    io.write(("  %-44s %-5s %12s %12s | %12s %12s\n")
        :format("group", "cls", "base_imp", "base_dmp", "cand_imp", "cand_dmp"))
    for _, v in ipairs(vs) do
        io.write(("  %-44s %-5s %12.5g %12.5g | %12.5g %12.5g\n")
            :format(v.b, cand[v.b] or "OUT", v.a.imp, v.a.dmp, v.c.imp, v.c.dmp))
    end
end
