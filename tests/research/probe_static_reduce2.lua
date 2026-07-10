---@diagnostic disable: undefined-global
-- Static reduction v2: reachability fixpoints (probe_static_reduce.lua's (a);
-- the coupled (b) proved identical on all 1677 dumps -- qualitative coupling
-- is vacuous, only RATIOS couple) plus fork-law amendments. The 488 unsafe
-- dumps of v1 concentrated on rigid co-product junctions (pyanodon slaughter:
-- bones/brain/skin/... in fixed ratios), i.e. the fork-necessity law's
-- "different-material parallel path" -- so never drop the elastic side that
-- the law says a rigid junction may need:
--   R1  a net output of a multi-output recipe keeps its surplus side
--   R2  a net input of a multi-input recipe keeps its shortage side
-- Variants evaluated: r1 (R1 only), r12 (R1+R2). Each: Phase-I safety oracle
-- + restricted L2 vs all-elastic L2.
--   luajit tests/research/probe_static_reduce2.lua <dump>
require "tests/headless_env"
local harness = require "tests/harness"
local R = require "tests/research/research_lib"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local EPS = 2 ^ -10
local PATH = arg[1]
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

local recs, coprod, cocons = {}, {}, {}
for key, pr in pairs(plain.primals) do
    if pr.kind == "recipe" or pr.kind == "bridge" then
        local ps, is = {}, {}
        for cname, coef in pairs(plain.subject_terms[key] or {}) do
            if cname:sub(1, 1) ~= "|" and not cname:find("^forcerec/") then
                if coef > 0 then ps[#ps + 1] = cname
                elseif coef < 0 then is[#is + 1] = cname end
            end
        end
        recs[#recs + 1] = { key = key, prods = ps, cons = is }
        if #ps >= 2 then for _, m in ipairs(ps) do coprod[m] = true end end
        if #is >= 2 then for _, m in ipairs(is) do cocons[m] = true end end
    end
end

local function fixpoints()
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
                for _, m in ipairs(r.prods) do
                    if not P[m] then P[m] = true; changed = true end
                end
            end
            if out_ok then
                for _, m in ipairs(r.cons) do
                    if not C[m] then C[m] = true; changed = true end
                end
            end
        end
    end
    return P, C
end
local P, C = fixpoints()

local p1solves = 0
local function full_phase1(trial)
    local p = build(false)
    del(p, trial)
    for _, pr in pairs(p.primals) do pr.cost = 0 end
    local arts, dkeys = {}, {}
    for dkey in pairs(p.duals) do dkeys[#dkeys + 1] = dkey end
    table.sort(dkeys)
    for _, dkey in ipairs(dkeys) do
        local tp, tm = "art+/" .. dkey, "art-/" .. dkey
        p:add_objective(tp, 1, false, "slack")
        p:add_subject_term(tp, dkey, 1)
        p:add_objective(tm, 1, false, "slack")
        p:add_subject_term(tm, dkey, -1)
        arts[#arts + 1] = { tp, tm, dkey }
    end
    local st, vars = harness.solve_to_completion(lp, p, { tolerance = 1e-7, iterate_limit = 1200 })
    p1solves = p1solves + 1
    if st ~= "finished" or not vars then return nil, nil end
    local tot, support = 0, {}
    for _, a in ipairs(arts) do
        local v = math.abs(vars.x[a[1]] or 0) + math.abs(vars.x[a[2]] or 0)
        tot = tot + v
        if v > 1e-4 then support[#support + 1] = { row = a[3], art = v } end
    end
    return tot, support
end
local function group_stats(p, x)
    local act6, imp, dmp = 0, 0, 0
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
    end
    return { act6 = act6, imp = imp, dmp = dmp }
end

local base = build(true)
local x0, st0 = R.drive_solve(base, prob.meta)
if st0 ~= "finished" then io.write(("s2 st=base_%s seed=%s\n"):format(tostring(st0), fid)); return end
local S0 = group_stats(base, x0)
local base_tot = S0.imp + S0.dmp

local function evaluate(tag, use_r2)
    local trial, kept_any = {}, 0
    for _, b in ipairs(gorder) do
        local g = groups[b]
        local prod_all, cons_all, is_coprod, is_cocons = true, true, false, false
        for m in pairs(g.vars) do
            if not P[m] then prod_all = false end
            if not C[m] then cons_all = false end
            if coprod[m] then is_coprod = true end
            if cocons[m] then is_cocons = true end
        end
        local drop_short = prod_all and not (use_r2 and is_cocons)
        local drop_surp = cons_all and not is_coprod
        if drop_short then
            for _, k in ipairs(g.short) do trial[#trial + 1] = k end
        end
        if drop_surp then
            for _, k in ipairs(g.surp) do trial[#trial + 1] = k end
        end
        if not (drop_short and drop_surp) then kept_any = kept_any + 1 end
    end
    table.sort(trial)
    local tot, support = full_phase1(trial)
    local safe = tot and tot <= 1e-3
    local st1, S1, ratio = "-", nil, -1
    if safe then
        local restr = build(true)
        del(restr, trial)
        local x1
        x1, st1 = R.drive_solve(restr, prob.meta)
        if st1 == "finished" then
            S1 = group_stats(restr, x1)
            ratio = base_tot > 1e-9 and (S1.imp + S1.dmp) / base_tot or 1
        end
    end
    local supnames = {}
    if not safe and support then
        table.sort(support, function(a, b) return a.art > b.art end)
        for i = 1, math.min(4, #support) do
            supnames[#supnames + 1] = support[i].row:gsub("@%[.-%]$", ""):gsub("^[a-z]+/", "")
        end
    end
    io.write(string.format(
        "s2 v=%s n_grp=%d kept=%d safe=%s base_act=%d r_act=%s ratio=%s st=%s base_tot=%.4g sup=%s seed=%s\n",
        tag, #gorder, kept_any,
        tot and (safe and "1" or "0") or "stuck",
        S0.act6, S1 and tostring(S1.act6) or "-",
        (ratio >= 0) and string.format("%.3g", ratio) or "-",
        tostring(st1), base_tot,
        (#supnames > 0) and table.concat(supnames, ",") or "-", fid))
end

evaluate("r1", false)
evaluate("r12", true)
