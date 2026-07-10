---@diagnostic disable: undefined-global
-- Seeded batch Phase-I: take the all-elastic L2 (the solve the shipped
-- pipeline already pays for), keep the physically-largest active groups as
-- the seed placement (cumulative-share threshold), then run the batch
-- Phase-I completion (probe_batch_iis.lua) to add whatever is still
-- structurally required. Sketches the set-size vs physical-inflation
-- tradeoff between "all candidates" (share=1) and "pure batch" (share=0).
--   luajit tests/research/probe_batch_seeded.lua <dump> <share0..1> [verbose]
require "tests/headless_env"
local harness = require "tests/harness"
local R = require "tests/research/research_lib"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local EPS, MAX_ITER = 2 ^ -10, 12
local PATH = arg[1]
local SHARE = tonumber(arg[2]) or 0.9
local VERBOSE = arg[3] == "verbose"
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
        if not groups[b] then groups[b] = {}; gorder[#gorder + 1] = b end
        groups[b][#groups[b] + 1] = k
    end
end
table.sort(gorder)
local recRows = {}
for k, pr in pairs(plain.primals) do
    if pr.kind == "recipe" then
        local t = {}
        for cname in pairs(plain.subject_terms[k] or {}) do
            if cname:sub(1, 1) ~= "|" and not cname:find("^forcerec/") then t[#t + 1] = cname end
        end
        recRows[k] = t
    end
end

local solves = 0
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
    solves = solves + 1
    if st ~= "finished" or not vars then return nil, nil end
    local tot, support = 0, {}
    for _, a in ipairs(arts) do
        local v = math.abs(vars.x[a[1]] or 0) + math.abs(vars.x[a[2]] or 0)
        tot = tot + v
        if v > 1e-4 then support[#support + 1] = { row = a[3], art = v } end
    end
    return tot, support
end

-- ======== base L2 (the solve the pipeline already pays) ========
local base = build(true)
local x0, st0 = R.drive_solve(base, prob.meta)
if st0 ~= "finished" then io.write(("bs st=base_%s seed=%s\n"):format(tostring(st0), fid)); return end
local function group_stats(p, x)
    local act6, act3, imp, dmp, gp = 0, 0, 0, 0, {}
    for _, b in ipairs(gorder) do
        local s_imp, s_dmp = 0, 0
        for _, k in ipairs(groups[b]) do
            if p.primals[k] then
                local v = phys(p, k, x)
                if p.primals[k].kind == "shortage_source" then s_imp = s_imp + v
                else s_dmp = s_dmp + v end
            end
        end
        if s_imp + s_dmp > 1e-6 then act6 = act6 + 1 end
        if s_imp + s_dmp > 1e-3 then act3 = act3 + 1 end
        imp = imp + s_imp; dmp = dmp + s_dmp
        gp[b] = { imp = s_imp, dmp = s_dmp }
    end
    return { act6 = act6, act3 = act3, imp = imp, dmp = dmp, gp = gp }
end
local S0 = group_stats(base, x0)

-- ======== seed: largest actives until cumulative physical share ========
local ranked = {}
for _, b in ipairs(gorder) do
    local t = S0.gp[b].imp + S0.gp[b].dmp
    if t > 1e-6 then ranked[#ranked + 1] = { b = b, t = t } end
end
table.sort(ranked, function(a, c) return a.t > c.t end)
local totphys = S0.imp + S0.dmp
local F, opened, nseed = {}, {}, 0
for _, b in ipairs(gorder) do F[b] = true end
local cum = 0
for _, r in ipairs(ranked) do
    if totphys <= 0 or cum / totphys >= SHARE then break end
    F[r.b] = nil; opened[#opened + 1] = r.b; nseed = nseed + 1
    cum = cum + r.t
end

-- ======== batch completion ========
local function trial_keys()
    local t = {}
    for b in pairs(F) do
        for _, k in ipairs(groups[b]) do t[#t + 1] = k end
    end
    table.sort(t)
    return t
end
local iters, final_tot = 0, nil
while iters < MAX_ITER do
    iters = iters + 1
    local tot, support = full_phase1(trial_keys())
    if not tot then io.write(("bs st=phase1_stuck seed=%s\n"):format(fid)); return end
    final_tot = tot
    if tot <= 1e-3 then break end
    local batch, seen = {}, {}
    for _, s in ipairs(support) do
        if s.row:sub(1, 1) ~= "|" and not s.row:find("^forcerec/") then
            local b = norm_mat(s.row)
            if F[b] and not seen[b] then seen[b] = true; batch[#batch + 1] = b end
        end
    end
    if #batch == 0 then
        for _, s in ipairs(support) do
            local rk = s.row:match("^forcerec/(.+)$")
            if rk and recRows[rk] then
                for _, cname in ipairs(recRows[rk]) do
                    local b = norm_mat(cname)
                    if F[b] and not seen[b] then seen[b] = true; batch[#batch + 1] = b end
                end
            end
        end
    end
    if #batch == 0 then io.write(("bs st=no_batch seed=%s\n"):format(fid)); return end
    for _, b in ipairs(batch) do F[b] = nil; opened[#opened + 1] = b end
end

-- ======== restricted L2 on the final placement ========
local restr = build(true)
del(restr, trial_keys())
local x1, st1 = R.drive_solve(restr, prob.meta)
local S1 = (st1 == "finished") and group_stats(restr, x1) or nil

io.write(string.format(
    "bs share=%.2f n_grp=%d base_act=%d/%d nseed=%d opened=%d p1solves=%d st=%s r_act=%s/%s base_imp=%.4g base_dmp=%.4g r_imp=%s r_dmp=%s seed=%s\n",
    SHARE, #gorder, S0.act6, S0.act3, nseed, #opened, solves, tostring(st1),
    S1 and tostring(S1.act6) or "-", S1 and tostring(S1.act3) or "-",
    S0.imp, S0.dmp,
    S1 and string.format("%.4g", S1.imp) or "-",
    S1 and string.format("%.4g", S1.dmp) or "-", fid))

if VERBOSE and S1 then
    local vs = {}
    for _, b in ipairs(gorder) do
        local a, c = S0.gp[b], S1.gp[b]
        if a.imp + a.dmp > 1e-9 or c.imp + c.dmp > 1e-9 then vs[#vs + 1] = { b = b, a = a, c = c } end
    end
    table.sort(vs, function(p_, q_) return (p_.c.imp + p_.c.dmp) > (q_.c.imp + q_.c.dmp) end)
    io.write(("  %-44s %12s %12s | %12s %12s\n")
        :format("group", "base_imp", "base_dmp", "open_imp", "open_dmp"))
    for _, v in ipairs(vs) do
        io.write(("  %-44s %12.5g %12.5g | %12.5g %12.5g\n")
            :format(v.b, v.a.imp, v.a.dmp, v.c.imp, v.c.dmp))
    end
end
