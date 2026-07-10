---@diagnostic disable: undefined-global
-- Dissect the law-placement guard failures (probe_scc_compress v=law):
-- reproduce the placement and the guard loop to exhaustion, then
--   1. print the final per-group physical table (base vs restricted),
--   2. for every still-dropped group, restore it ALONE on top of the final
--      state and re-solve -- ranking which single restoration repairs the
--      ratio (the "culprit" whose absence forces the amplification),
--   3. also solve with ALL still-dropped restored (sanity: ratio -> ~1?).
-- Culprit structure (SCC member? junction output? chain link? window
-- variant?) is what a static avoidance rule would need to see.
--   luajit tests/research/probe_law_dissect.lua <dump> [guard] [addk]
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

local adj, nodes, junctions, coprod, cocons = {}, {}, {}, {}, {}
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
                coprod[m] = true
                local b = norm_mat(m)
                if groups[b] and not seen[b] then seen[b] = true; outs[#outs + 1] = b end
            end
            if #outs >= 1 then junctions[#junctions + 1] = { outs = outs } end
        end
        if #is >= 2 then for _, m in ipairs(is) do cocons[m] = true end end
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

local base = build(true)
local x0, st0 = R.drive_solve(base, prob.meta)
assert(st0 == "finished", "base not finished")
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
local scc_reps, jun_reps = {}, {}
for _, members in pairs(units) do
    local r = rep_of(members)
    if r then scc_reps[r] = true end
end
for _, j in ipairs(junctions) do
    local members = {}
    for _, b in ipairs(j.outs) do members[b] = true end
    local r = rep_of(members)
    if r then jun_reps[r] = true end
end

local dropped, status = {}, {}
for _, b in ipairs(gorder) do
    local keep = scc_reps[b] or jun_reps[b]
    dropped[b] = { short = not keep, surp = not keep }
    status[b] = keep and (scc_reps[b] and "sccrep" or "junrep") or "drop"
end
local function trial_keys(extra_restore)
    local t = {}
    for _, b in ipairs(gorder) do
        local d, g = dropped[b], groups[b]
        local restore = extra_restore and extra_restore[b]
        if d.short and not restore then for _, k in ipairs(g.short) do t[#t + 1] = k end end
        if d.surp and not restore then for _, k in ipairs(g.surp) do t[#t + 1] = k end end
    end
    table.sort(t)
    return t
end

-- guard to exhaustion
local rounds, S1, st1, ratio = 0, nil, "?", -1
while true do
    local restr = build(true)
    del(restr, trial_keys())
    local x1
    x1, st1 = R.drive_solve(restr, prob.meta)
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
    for _, r in ipairs(ranked) do
        if added >= ADDK then break end
        local d = dropped[r.b]
        if d.short or d.surp then
            d.short, d.surp = false, false
            status[r.b] = "widen" .. rounds
            added = added + 1
        end
    end
    if added == 0 then break end
end
io.write(("== %s  final ratio=%.3g st=%s base_tot=%.4g\n"):format(fid, ratio, tostring(st1), base_tot))

-- 1. final physical table (top by restricted phys)
local rowsv = {}
for _, b in ipairs(gorder) do
    local rp = S1 and S1.gp[b] or -1
    if (S0.gp[b] or 0) > 1e-6 or rp > 1e-6 then
        rowsv[#rowsv + 1] = { b = b, bp = S0.gp[b] or 0, rp = rp }
    end
end
table.sort(rowsv, function(a, c) return a.rp > c.rp end)
io.write(("  %-40s %-8s %12s %12s  scc jun cop coc\n"):format("group", "status", "base", "restr"))
for i = 1, math.min(14, #rowsv) do
    local r = rowsv[i]
    local g = groups[r.b]
    local in_scc, is_cop, is_coc = false, false, false
    for m in pairs(g.vars) do
        local id = sccid[m]
        if (id and sccsize[id] >= 2) or (adj[m] and adj[m][m]) or selfloop_base[r.b] then in_scc = true end
        if coprod[m] then is_cop = true end
        if cocons[m] then is_coc = true end
    end
    io.write(("  %-40s %-8s %12.5g %12.5g  %s   %s   %s   %s\n"):format(
        r.b, status[r.b], r.bp, r.rp,
        in_scc and "y" or ".", jun_reps[r.b] and "y" or ".",
        is_cop and "y" or ".", is_coc and "y" or "."))
end

-- 2. single-restoration ranking over still-dropped groups
local still = {}
for _, b in ipairs(gorder) do
    if dropped[b].short or dropped[b].surp then still[#still + 1] = b end
end
io.write(("  still-dropped: %d groups; single-restoration solves:\n"):format(#still))
local results = {}
for _, b in ipairs(still) do
    local restr = build(true)
    del(restr, trial_keys({ [b] = true }))
    local x1, s1 = R.drive_solve(restr, prob.meta)
    local rr = -1
    if s1 == "finished" then
        local S = group_stats(restr, x1)
        rr = base_tot > 1e-9 and (S.imp + S.dmp) / base_tot or 1
    end
    results[#results + 1] = { b = b, r = rr, st = s1 }
end
table.sort(results, function(a, c)
    local ra = (a.r >= 0) and a.r or 1e9
    local rc = (c.r >= 0) and c.r or 1e9
    return ra < rc
end)
local unit_of = {}
for uid, members in pairs(units) do
    for b in pairs(members) do
        unit_of[b] = unit_of[b] or {}
        unit_of[b][#unit_of[b] + 1] = uid
    end
end
for i = 1, math.min(10, #results) do
    local r = results[i]
    local ann = {}
    for _, uid in ipairs(unit_of[r.b] or {}) do
        local rep = rep_of(units[uid])
        ann[#ann + 1] = ("scc[%s] rep=%s"):format(tostring(uid), rep or "?")
    end
    local g = groups[r.b]
    for m in pairs(g.vars) do
        if coprod[m] then ann[#ann + 1] = "coprod"; break end
    end
    io.write(("    restore %-40s -> ratio %s (%s)  %s\n"):format(r.b,
        (r.r >= 0) and string.format("%.3g", r.r) or "-", tostring(r.st),
        table.concat(ann, "; ")))
end

-- 3. all still-dropped restored (sanity)
do
    local all = {}
    for _, b in ipairs(still) do all[b] = true end
    local restr = build(true)
    del(restr, trial_keys(all))
    local x1, s1 = R.drive_solve(restr, prob.meta)
    if s1 == "finished" then
        local S = group_stats(restr, x1)
        io.write(("  all-restored sanity: ratio %.3g\n"):format(
            base_tot > 1e-9 and (S.imp + S.dmp) / base_tot or 1))
    else
        io.write(("  all-restored sanity: st=%s\n"):format(tostring(s1)))
    end
end
