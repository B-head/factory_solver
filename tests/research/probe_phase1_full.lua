---@diagnostic disable: undefined-global
-- Definitive re-check of the greedy oracle's "unfinished == infeasible" rule.
-- At every KEPT step, build the SAME deleted problem but as a textbook
-- Phase-I: plain build (linear costs, no quad), every primal cost zeroed,
-- one artificial pair (+1/-1, cost 1) on EVERY dual row. This LP is feasible
-- by construction, so the IPM should always finish; its optimum decides:
--   sum(artificials) ~ 0  -> the deleted problem IS feasible => the original
--                            "unfinished" was a solver failure, not
--                            infeasibility (greedy kept a removable group);
--   sum(artificials) > 0  -> truly infeasible, and the rows whose artificials
--                            stay positive are the unfillable balances (the
--                            Farkas/IIS support, from the IPM itself).
--   luajit tests/research/probe_phase1_full.lua <dump>
require "tests/headless_env"
local harness = require "tests/harness"
local R = require "tests/research/research_lib"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local EPS, PROBE_CAP = 2 ^ -10, 50
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

local function full_phase1(trial)
    local p = build(false) -- linear, no quad
    del(p, trial)
    for _, pr in pairs(p.primals) do pr.cost = 0 end
    local arts = {}
    local dkeys = {}
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
    if st ~= "finished" or not vars then return "solver_" .. tostring(st), nil, nil end
    local tot, support = 0, {}
    for _, a in ipairs(arts) do
        local v = math.abs(vars.x[a[1]] or 0) + math.abs(vars.x[a[2]] or 0)
        tot = tot + v
        if v > 1e-4 then support[#support + 1] = ("%s(%.4g)"):format(a[3], v) end
    end
    return (tot > 1e-3) and "infeasible" or "feasible", tot, support
end

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
table.sort(order2, function(a, b) return a and gphys[a] < gphys[b] end)
io.write(("== %s\n"):format(fid))

local removed = {}
for i, b in ipairs(order2) do
    if i > PROBE_CAP then break end
    local trial = {}
    for _, k in ipairs(removed) do trial[#trial + 1] = k end
    for _, k in ipairs(groups[b]) do trial[#trial + 1] = k end
    local p = build(true); del(p, trial)
    local _, st = R.drive_solve(p, prob.meta)
    if st == "finished" then
        for _, k in ipairs(groups[b]) do removed[#removed + 1] = k end
    else
        local v, tot, support = full_phase1(trial)
        io.write(("KEPT %-36s LP=%-10s fullPh1=%-10s sumArt=%s\n")
            :format(b, tostring(st), tostring(v), tostring(tot)))
        if support and #support > 0 then
            table.sort(support)
            io.write("      unfillable rows: ", table.concat(support, " , "), "\n")
        end
    end
end
