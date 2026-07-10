---@diagnostic disable: undefined-global
-- Static placement + physical guard, NO Phase-I anywhere: the fully
-- solve-free placement (reachability fixpoints + fork-law R1 from
-- probe_static_reduce2.lua) driven through the try-and-verify guard of
-- probe_batch_guarded.lua. The guard also self-heals the rare (4/1474)
-- statically-unsafe placements: an infeasible restricted L2 comes back
-- unfinished, which counts as a guard failure and widens the set.
-- Pipeline cost: 1 all-elastic L2 + 1 restricted L2 + 1 per guard round.
--   luajit tests/research/probe_static_guarded.lua <dump> [guard] [addk]
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
local recs, coprod = {}, {}
for key, pr in pairs(plain.primals) do
    if pr.kind == "recipe" or pr.kind == "bridge" then
        local ps, is = {}, {}
        for cname, coef in pairs(plain.subject_terms[key] or {}) do
            if cname:sub(1, 1) ~= "|" and not cname:find("^forcerec/") then
                if coef > 0 then ps[#ps + 1] = cname
                elseif coef < 0 then is[#is + 1] = cname end
            end
        end
        recs[#recs + 1] = { prods = ps, cons = is }
        if #ps >= 2 then for _, m in ipairs(ps) do coprod[m] = true end end
    end
end
local P, C = {}, {}
for m in pairs(free_src) do P[m] = true end
for m in pairs(free_snk) do C[m] = true end
local changed = true
while changed do
    changed = false
    for _, r in ipairs(recs) do
        local in_ok, out_ok = true, true
        for _, m in ipairs(r.cons) do if not P[m] then in_ok = false; break end end
        for _, m in ipairs(r.prods) do if not C[m] then out_ok = false; break end end
        if in_ok then
            for _, m in ipairs(r.prods) do if not P[m] then P[m] = true; changed = true end end
        end
        if out_ok then
            for _, m in ipairs(r.cons) do if not C[m] then C[m] = true; changed = true end end
        end
    end
end

-- ======== base L2 ========
local base = build(true)
local x0, st0 = R.drive_solve(base, prob.meta)
if st0 ~= "finished" then io.write(("sg st=base_%s seed=%s\n"):format(tostring(st0), fid)); return end
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

-- ======== static r1 placement: per-side drops ========
local dropped = {} -- base -> {short=bool, surp=bool}
local n_placed = 0
for _, b in ipairs(gorder) do
    local g = groups[b]
    local prod_all, cons_all, is_coprod = true, true, false
    for m in pairs(g.vars) do
        if not P[m] then prod_all = false end
        if not C[m] then cons_all = false end
        if coprod[m] then is_coprod = true end
    end
    local d = { short = prod_all, surp = cons_all and not is_coprod }
    dropped[b] = d
    if not (d.short and d.surp) then n_placed = n_placed + 1 end
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

-- ======== guard loop (physical verify, widen by base-phys rank) ========
local ranked = {}
for _, b in ipairs(gorder) do
    if S0.gp[b] > 1e-6 then ranked[#ranked + 1] = { b = b, t = S0.gp[b] } end
end
table.sort(ranked, function(a, c) return a.t > c.t end)

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
    for _, r in ipairs(ranked) do
        if added >= ADDK then break end
        local d = dropped[r.b]
        if d.short or d.surp then
            if d.short and d.surp then n_final = n_final + 1 end
            d.short, d.surp = false, false
            added = added + 1
        end
    end
    if added == 0 then break end
end

io.write(string.format(
    "sg guard=%.2f n_grp=%d base_act=%d n_placed=%d n_final=%d rounds=%d l2solves=%d st=%s r_act=%s ratio=%s base_tot=%.4g r_imp=%s r_dmp=%s seed=%s\n",
    GUARD, #gorder, S0.act6, n_placed, n_final, rounds, l2solves, tostring(st1),
    S1 and tostring(S1.act6) or "-",
    (ratio >= 0) and string.format("%.3g", ratio) or "-",
    base_tot,
    S1 and string.format("%.4g", S1.imp) or "-",
    S1 and string.format("%.4g", S1.dmp) or "-", fid))
