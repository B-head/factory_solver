---@diagnostic disable: undefined-global
-- Guarded batch placement: batch Phase-I placement (probe_batch_iis.lua),
-- then a try-and-verify loop on the PHYSICAL totals -- if the restricted L2's
-- import+dump total exceeds GUARD x the all-elastic L2's, open the next ADDK
-- physically-largest base-active groups and re-solve. This targets the
-- ratio-amplification tail (tbp 913 / purex 6088): a small set is fine at the
-- median, but an elastic far (in stoichiometric gain) from the imbalance
-- multiplies the physical flow, and only a solved solution reveals it.
-- A restricted L2 that fails to converge counts as a guard failure too
-- (shipped form would fall back to the all-elastic L2).
--   luajit tests/research/probe_batch_guarded.lua <dump> [guard] [addk]
require "tests/headless_env"
local harness = require "tests/harness"
local R = require "tests/research/research_lib"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local EPS, MAX_ITER, MAX_ROUNDS = 2 ^ -10, 12, 4
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

-- ======== base L2 ========
local base = build(true)
local x0, st0 = R.drive_solve(base, prob.meta)
if st0 ~= "finished" then io.write(("bg st=base_%s seed=%s\n"):format(tostring(st0), fid)); return end
local function group_stats(p, x)
    local act6, imp, dmp, gp = 0, 0, 0, {}
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
        imp = imp + s_imp; dmp = dmp + s_dmp
        gp[b] = s_imp + s_dmp
    end
    return { act6 = act6, imp = imp, dmp = dmp, gp = gp }
end
local S0 = group_stats(base, x0)
local base_tot = S0.imp + S0.dmp

-- ======== batch Phase-I placement ========
local F = {}
for _, b in ipairs(gorder) do F[b] = true end
local opened = {}
local function trial_keys()
    local t = {}
    for b in pairs(F) do
        for _, k in ipairs(groups[b]) do t[#t + 1] = k end
    end
    table.sort(t)
    return t
end
local iters = 0
while iters < MAX_ITER do
    iters = iters + 1
    local tot, support = full_phase1(trial_keys())
    if not tot then io.write(("bg st=phase1_stuck seed=%s\n"):format(fid)); return end
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
    if #batch == 0 then io.write(("bg st=no_batch seed=%s\n"):format(fid)); return end
    for _, b in ipairs(batch) do F[b] = nil; opened[#opened + 1] = b end
end
local n_placed = #opened

-- ======== guard loop: verify physical totals, widen on failure ========
local ranked = {}
for _, b in ipairs(gorder) do
    if S0.gp[b] > 1e-6 then ranked[#ranked + 1] = { b = b, t = S0.gp[b] } end
end
table.sort(ranked, function(a, c) return a.t > c.t end)

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
        if F[r.b] then F[r.b] = nil; opened[#opened + 1] = r.b; added = added + 1 end
    end
    if added == 0 then break end
end

io.write(string.format(
    "bg guard=%.2f n_grp=%d base_act=%d n_placed=%d n_final=%d rounds=%d p1solves=%d l2solves=%d st=%s r_act=%s ratio=%s base_tot=%.4g r_imp=%s r_dmp=%s seed=%s\n",
    GUARD, #gorder, S0.act6, n_placed, #opened, rounds, p1solves, l2solves, tostring(st1),
    S1 and tostring(S1.act6) or "-",
    (ratio >= 0) and string.format("%.3g", ratio) or "-",
    base_tot,
    S1 and string.format("%.4g", S1.imp) or "-",
    S1 and string.format("%.4g", S1.dmp) or "-", fid))
