---@diagnostic disable: undefined-global
-- IIS-style enumeration of the minimal elastic set, replacing the greedy.
-- Direction is inverted: START with every active violation group CLOSED
-- (all deleted), then repeatedly solve the full Phase-I (always-feasible LP,
-- artificials on every row); while sum(art) > 0 its support names the
-- unfillable balances -- OPEN the group of the max-artificial material row
-- and repeat. Feasibility is reached after ~n_min openings, so the count is
-- ~n_min+1 solves instead of the greedy's n_groups solves.
-- The greedy runs alongside for truth; afterwards each opened group is closed
-- back solo to confirm irreducibility (every opened group is truly needed).
--   luajit tests/research/probe_iis_enum.lua <dump>
require "tests/headless_env"
local harness = require "tests/harness"
local R = require "tests/research/research_lib"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local EPS, PROBE_CAP, MAX_ITER = 2 ^ -10, 50, 60
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

-- base solve: active groups (same protocol as fn2 / the greedy probes)
local base = build(true)
local x0, st0 = R.drive_solve(base, prob.meta)
assert(st0 == "finished")
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
io.write(("== %s  groups=%d\n"):format(fid, #order2))

-- recipe key -> material rows (for the forcerec-support fallback)
local plain = build(false)
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

-- ============ greedy (truth), counted separately ============
local greedy_solves = 0
local greedy_kept = {}
do
    local removed = {}
    for i, b in ipairs(order2) do
        if i > PROBE_CAP then break end
        local trial = {}
        for _, k in ipairs(removed) do trial[#trial + 1] = k end
        for _, k in ipairs(groups[b]) do trial[#trial + 1] = k end
        local p = build(true); del(p, trial)
        local _, st = R.drive_solve(p, prob.meta)
        greedy_solves = greedy_solves + 1
        if st == "finished" then
            for _, k in ipairs(groups[b]) do removed[#removed + 1] = k end
        else
            greedy_kept[#greedy_kept + 1] = b
        end
    end
end

-- ============ IIS enumeration ============
local F = {} -- base -> true (closed)
for _, b in ipairs(order2) do F[b] = true end
local opened = {}
local function trial_keys()
    local t = {}
    for b in pairs(F) do
        for _, k in ipairs(groups[b]) do t[#t + 1] = k end
    end
    table.sort(t)
    return t
end
local iter = 0
while iter < MAX_ITER do
    iter = iter + 1
    local tot, support = full_phase1(trial_keys())
    if not tot then io.write("!! phase1 did not converge\n"); break end
    if tot <= 1e-3 then
        io.write(("iis done: feasible after %d openings (sumArt=%.3g)\n"):format(#opened, tot))
        break
    end
    -- pick: max-art material row whose base is still closed
    table.sort(support, function(a, b) return a.art > b.art end)
    local pick
    for _, s in ipairs(support) do
        if s.row:sub(1, 1) ~= "|" and not s.row:find("^forcerec/") then
            local b = norm_mat(s.row)
            if F[b] then pick = b break end
        end
    end
    if not pick then
        -- fallback: forcerec support -> that recipe's material rows
        local bestphys = -1
        for _, s in ipairs(support) do
            local rk = s.row:match("^forcerec/(.+)$")
            if rk and recRows[rk] then
                for _, cname in ipairs(recRows[rk]) do
                    local b = norm_mat(cname)
                    if F[b] and (gphys[b] or 0) > bestphys then pick, bestphys = b, gphys[b] or 0 end
                end
            end
        end
    end
    if not pick then
        io.write("!! no closed group found in support; support rows:\n")
        for i = 1, math.min(8, #support) do io.write("   ", support[i].row, " ", support[i].art, "\n") end
        break
    end
    F[pick] = nil
    opened[#opened + 1] = pick
    io.write(("  open %-40s (sumArt was %.4g)\n"):format(pick, tot))
end

-- ============ irreducibility check ============
local confirmed = 0
for _, b in ipairs(opened) do
    F[b] = true
    local tot = full_phase1(trial_keys())
    F[b] = nil
    if tot and tot > 1e-3 then confirmed = confirmed + 1 end
end

table.sort(opened)
table.sort(greedy_kept)
local same = table.concat(opened, ",") == table.concat(greedy_kept, ",")
io.write(("-- IIS opened=%d (%d solves)  greedy kept=%d (%d solves)  sets %s  irreducible %d/%d\n")
    :format(#opened, solves, #greedy_kept, greedy_solves,
        same and "EQUAL" or "DIFFER", confirmed, #opened))
if not same then
    io.write("   iis:    ", table.concat(opened, " , "), "\n")
    io.write("   greedy: ", table.concat(greedy_kept, " , "), "\n")
end
