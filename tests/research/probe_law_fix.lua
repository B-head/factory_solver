---@diagnostic disable: undefined-global
-- Fixes for the law-placement guard failures (probe_law_dissect.lua found all
-- five to be non-representative members of a PLACED SCC unit -- the "1 rep
-- per SCC" compression hitting the kept>=2 SCCs):
--   all    place every member of every SCC unit (the law's safe upper bound
--          "<= nbase per SCC"), junctions still one representative.
--   smart  keep 1 rep per SCC, but widen by structure instead of phys rank:
--          on a failed guard round restore the still-dropped SCC/junction
--          partners of the top inflation carriers (restricted-minus-base
--          phys delta); on an unfinished L2 restore every still-dropped SCC
--          member; fall back to phys rank when neither adds anything.
--   luajit tests/research/probe_law_fix.lua <dump> [guard] [addk]
require "tests/headless_env"
local R = require "tests/research/research_lib"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local EPS, MAX_ROUNDS = 2 ^ -10, 4
local PATH = arg[1]
local GUARD = tonumber(arg[2]) or 1.5
local ADDK = tonumber(arg[3]) or 6
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
local function build(l2)
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
    if l2 then cp.shape_l2(p, 2 ^ 11, 2 ^ -8) end
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

local plain = build(false)
local groups, gorder = {}, {}
for k, pr in pairs(plain.primals) do
    if pr.kind == "shortage_source" or pr.kind == "surplus_sink" then
        local b = norm_mat(pr.material or "?")
        if not groups[b] then
            groups[b] = { short = {}, surp = {}, vars = {} }
            gorder[#gorder + 1] = b
        end
        local g = groups[b]
        if pr.kind == "shortage_source" then g.short[#g.short + 1] = k
        else g.surp[#g.surp + 1] = k end
        g.vars[pr.material] = true
    end
end
table.sort(gorder)

local free_src, free_snk = {}, {}
for _, pr in pairs(plain.primals) do
    if pr.kind == "initial_source" and pr.material then free_src[pr.material] = true end
    if pr.kind == "final_sink" and pr.material then free_snk[pr.material] = true end
end
local free = {}
for m in pairs(free_src) do free[m] = true end
for m in pairs(free_snk) do free[m] = true end

local adj, nodes, junctions = {}, {}, {}
for key, pr in pairs(plain.primals) do
    if pr.kind == "recipe" or pr.kind == "bridge" then
        local ps, is = {}, {}
        for cname, coef in pairs(plain.subject_terms[key] or {}) do
            if cname:sub(1, 1) ~= "|" and not cname:find("^forcerec/") then
                if coef > 0 then ps[#ps + 1] = cname
                elseif coef < 0 then is[#is + 1] = cname end
            end
        end
        if #ps >= 2 then
            local outs, seen = {}, {}
            for _, m in ipairs(ps) do
                local b = norm_mat(m)
                if groups[b] and not seen[b] then seen[b] = true; outs[#outs + 1] = b end
            end
            if #outs >= 1 then junctions[#junctions + 1] = { outs = outs } end
        end
        for _, m in ipairs(ps) do nodes[m] = true end
        for _, m in ipairs(is) do nodes[m] = true end
        for _, a in ipairs(is) do
            if not free[a] then
                adj[a] = adj[a] or {}
                for _, b in ipairs(ps) do if not free[b] then adj[a][b] = true end end
            end
        end
    end
end
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

local units = {}
for _, b in ipairs(gorder) do
    local g = groups[b]
    for m in pairs(g.vars) do
        local id = sccid[m]
        if id and sccsize[id] >= 2 then
            units[id] = units[id] or {}
            units[id][b] = true
        end
        if (adj[m] and adj[m][m]) or selfloop_base[b] then
            units["self/" .. b] = { [b] = true }
        end
    end
end
local unit_of, jun_of = {}, {}
for uid, members in pairs(units) do
    for b in pairs(members) do
        unit_of[b] = unit_of[b] or {}
        unit_of[b][#unit_of[b] + 1] = uid
    end
end
for ji, j in ipairs(junctions) do
    for _, b in ipairs(j.outs) do
        jun_of[b] = jun_of[b] or {}
        jun_of[b][#jun_of[b] + 1] = ji
    end
end

local base = build(true)
local x0, st0 = R.drive_solve(base, prob.meta)
if st0 ~= "finished" then io.write(("lf st=base_%s seed=%s\n"):format(tostring(st0), fid)); return end
local function group_stats(p, x)
    local act6, imp, dmp, gp = 0, 0, 0, {}
    for _, b in ipairs(gorder) do
        local s = 0
        local g = groups[b]
        for _, k in ipairs(g.short) do
            if p.primals[k] then local v = phys(p, k, x); s = s + v; imp = imp + v end
        end
        for _, k in ipairs(g.surp) do
            if p.primals[k] then local v = phys(p, k, x); s = s + v; dmp = dmp + v end
        end
        if s > 1e-6 then act6 = act6 + 1 end
        gp[b] = s
    end
    return { act6 = act6, imp = imp, dmp = dmp, gp = gp }
end
local S0 = group_stats(base, x0)
local base_tot = S0.imp + S0.dmp
local ranked = {}
for _, b in ipairs(gorder) do
    if S0.gp[b] > 1e-6 then ranked[#ranked + 1] = { b = b, t = S0.gp[b] } end
end
table.sort(ranked, function(a, c) return a.t > c.t end)
local function rep_of(members)
    local best, bphys
    for b in pairs(members) do
        local v = S0.gp[b] or 0
        if not best or v > bphys or (v == bphys and b < best) then best, bphys = b, v end
    end
    return best
end

local function make_placement(all_scc)
    local keep = {}
    for _, members in pairs(units) do
        if all_scc then
            for b in pairs(members) do keep[b] = true end
        else
            local r = rep_of(members)
            if r then keep[r] = true end
        end
    end
    for _, j in ipairs(junctions) do
        local members = {}
        for _, b in ipairs(j.outs) do members[b] = true end
        local r = rep_of(members)
        if r then keep[r] = true end
    end
    local dropped = {}
    for _, b in ipairs(gorder) do
        dropped[b] = { short = not keep[b], surp = not keep[b] }
    end
    return dropped
end

local function run(tag, dropped, smart)
    local n_placed = 0
    for _, b in ipairs(gorder) do
        if not (dropped[b].short and dropped[b].surp) then n_placed = n_placed + 1 end
    end
    local function trial_keys()
        local t = {}
        for _, b in ipairs(gorder) do
            local d, g = dropped[b], groups[b]
            if d.short then for _, k in ipairs(g.short) do t[#t + 1] = k end end
            if d.surp then for _, k in ipairs(g.surp) do t[#t + 1] = k end end
        end
        table.sort(t)
        return t
    end
    local function restore(b)
        local d = dropped[b]
        if d.short or d.surp then d.short, d.surp = false, false; return 1 end
        return 0
    end
    local n_final = n_placed
    local rounds, l2solves, S1, st1, ratio = 0, 0, nil, "?", -1
    while true do
        local restr = build(true)
        del(restr, trial_keys())
        local x1
        x1, st1 = R.drive_solve(restr, prob.meta)
        l2solves = l2solves + 1
        if st1 == "finished" then
            S1 = group_stats(restr, x1)
            ratio = base_tot > 1e-9 and (S1.imp + S1.dmp) / base_tot or 1
            if ratio <= GUARD then break end
        else
            S1, ratio = nil, -1
        end
        if rounds >= MAX_ROUNDS then break end
        rounds = rounds + 1
        local added = 0
        if smart then
            if S1 then
                -- structural widening: SCC/junction partners of the top
                -- inflation carriers (restricted-minus-base phys delta)
                local carriers = {}
                for _, b in ipairs(gorder) do
                    local dlt = (S1.gp[b] or 0) - (S0.gp[b] or 0)
                    if dlt > 1e-6 then carriers[#carriers + 1] = { b = b, d = dlt } end
                end
                table.sort(carriers, function(a, c) return a.d > c.d end)
                for i = 1, math.min(3, #carriers) do
                    local cb = carriers[i].b
                    for _, uid in ipairs(unit_of[cb] or {}) do
                        for m in pairs(units[uid]) do added = added + restore(m) end
                    end
                    for _, ji in ipairs(jun_of[cb] or {}) do
                        for _, m in ipairs(junctions[ji].outs) do added = added + restore(m) end
                    end
                end
            else
                -- unfinished: restore every still-dropped SCC member
                for _, members in pairs(units) do
                    for m in pairs(members) do added = added + restore(m) end
                end
            end
        end
        if added == 0 then
            for _, r in ipairs(ranked) do
                if added >= ADDK then break end
                added = added + restore(r.b)
            end
        end
        n_final = n_final + added
        if added == 0 then break end
    end
    io.write(string.format(
        "lf v=%s n_grp=%d base_act=%d n_placed=%d n_final=%d rounds=%d l2solves=%d st=%s r_act=%s ratio=%s base_tot=%.4g seed=%s\n",
        tag, #gorder, S0.act6, n_placed, n_final, rounds, l2solves, tostring(st1),
        S1 and tostring(S1.act6) or "-",
        (ratio >= 0) and string.format("%.3g", ratio) or "-",
        base_tot, fid))
end

run("all", make_placement(true), false)
run("smart", make_placement(false), true)
