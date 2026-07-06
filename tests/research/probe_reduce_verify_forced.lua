---@diagnostic disable: undefined-global
-- PRE-REDUCE-AND-VERIFY on the FORCED-RECIPE setup (2026-07-06). Same idea as
-- probe_reduce_verify.lua but on the structural setup where n_min ~ nscc was
-- measured: drop the target (constraints kept as non-binding reachability anchors),
-- force every real recipe to run (machine count >= 1). Then greedily strip the
-- active base-material elastic groups to a minimal feasible set (smallest first,
-- commit a removal only if the re-solve stays finished) and VERIFY the reduced
-- problem is still feasible -- and at what machine cost (unlike the target-locked
-- version, here fabrication is already pinned by the >=1 floor, so reducing the
-- elastics need not blow up machines the same way).
-- Emit one 'rf' line per dump.
--   lua tests/research/probe_reduce_verify_forced.lua <dump>   (run_corpus.ps1 -Collect '^rf')
require "tests/headless_env"
local R = require "tests/research/research_lib"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local EPS, PROBE_CAP = 2 ^ -10, 80
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"
local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("rf ERR=load seed=" .. fid .. "\n"); return end

local function mat_base(m) return (m:gsub("@%[.-%]$", "")) end
local function phys(p, k, x)
    local pr, t = p.primals[k], p.subject_terms[k]
    local c = (pr and pr.material and t and t[pr.material]) or 1
    return math.abs(c * (x[k] or 0))
end
local anchor = {}
for _, c in ipairs(prob.constraints) do
    anchor[#anchor + 1] = { type = c.type, name = c.name, quality = c.quality, limit_type = "lower", limit_amount_per_second = 0 }
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
local function machines(p, x) local s = 0 for k, pr in pairs(p.primals) do if pr.kind == "recipe" then s = s + math.abs(x[k] or 0) end end return s end
local function ngroups(p, x)
    local seen, n = {}, 0
    for k, pr in pairs(p.primals) do
        if (pr.kind == "shortage_source" or pr.kind == "surplus_sink") and phys(p, k, x) > 1e-6 then
            local b = mat_base(pr.material or "?"); if not seen[b] then seen[b] = true; n = n + 1 end
        end
    end
    return n
end

local base = build()
local x0, st0 = R.drive_solve(base, prob.meta)
if st0 ~= "finished" then io.write(("rf st=%s seed=%s\n"):format(tostring(st0), fid)); return end
local mach0, grp0 = machines(base, x0), ngroups(base, x0)

local groups, order, gphys = {}, {}, {}
for k, pr in pairs(base.primals) do
    if (pr.kind == "shortage_source" or pr.kind == "surplus_sink") and phys(base, k, x0) > 1e-6 then
        local b = mat_base(pr.material or "?")
        if not groups[b] then groups[b] = {}; order[#order + 1] = b; gphys[b] = 0 end
        groups[b][#groups[b] + 1] = k; gphys[b] = gphys[b] + phys(base, k, x0)
    end
end
table.sort(order, function(a, b) return gphys[a] < gphys[b] end)
local trunc = (#order > PROBE_CAP) and 1 or 0
local probe_list = {}
for i = 1, math.min(#order, PROBE_CAP) do probe_list[i] = order[i] end

local removed, nrem = {}, 0
for _, b in ipairs(probe_list) do
    local trial = {}
    for _, k in ipairs(removed) do trial[#trial + 1] = k end
    for _, k in ipairs(groups[b]) do trial[#trial + 1] = k end
    local p = build(); del(p, trial)
    local _, st = R.drive_solve(p, prob.meta)
    if st == "finished" then
        for _, k in ipairs(groups[b]) do removed[#removed + 1] = k end
        nrem = nrem + 1
    end
end

local pf = build(); del(pf, removed)
local xf, stf = R.drive_solve(pf, prob.meta)
if stf ~= "finished" then
    io.write(("rf FINAL_INFEAS grp0=%d nrem=%d trunc=%d seed=%s\n"):format(grp0, nrem, trunc, fid)); return
end
io.write(string.format("rf final_st=%s grp0=%d grp1=%d nrem=%d mach0=%.6g machf=%.6g trunc=%d seed=%s\n",
    stf, grp0, ngroups(pf, xf), nrem, mach0, machines(pf, xf), trunc, fid))
