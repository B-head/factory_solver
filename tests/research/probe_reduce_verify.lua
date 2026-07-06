---@diagnostic disable: undefined-global
-- PRE-REDUCE-AND-VERIFY (2026-07-06). Act on the structural finding that L2 opens
-- ~7x more elastic channels than needed: on the REAL target-locked problem, greedily
-- strip the active elastic groups down to a minimal feasible set and check it never
-- goes infeasible and the target still holds.
--
-- Per dump: build target-locked L2 (shipped-style rescue lock), take the active
-- base-material elastic groups, and greedily remove them smallest-first -- keeping
-- each removal only if the re-solve stays finished (the budget row auto-holds T<=T0,
-- so "finished" == target preserved). The kept groups are the minimal feasible set.
-- Emit before/after: group count, machines, and the reference Vp/Vc/Vf split, plus
-- the final solve status (must be finished == not infeasible).
--   lua tests/research/probe_reduce_verify.lua <dump>   (run_corpus.ps1 -Collect '^rd')
require "tests/headless_env"
local R = require "tests/research/research_lib"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local RS = require "tests/research/reference_solver"
local VQ, VF, EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"
local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("rd ERR=load seed=" .. fid .. "\n"); return end

local function mat_base(m) return (m:gsub("@%[.-%]$", "")) end
local function phys(p, k, x)
    local pr, t = p.primals[k], p.subject_terms[k]
    local c = (pr and pr.material and t and t[pr.material]) or 1
    return math.abs(c * (x[k] or 0))
end
local BUDGET
local function build()
    local o = { reachability_gating = false, deficit_seeding = false, catalyst_closure = false,
        surplus_sink_gating = false, recipe_epsilon = EPS }
    if BUDGET then o.target_budget = BUDGET end
    local p = cp.create_problem("l2", prob.constraints, prob.normalized_lines, nil, o)
    cp.shape_l2(p, VQ, VF); return p
end
local function del(p, keys)
    for _, k in ipairs(keys) do p:set_quad(k, 0); p.primals[k] = nil; p.subject_terms[k] = nil end
    local ks = {}
    for k in pairs(p.primals) do ks[#ks + 1] = k end
    table.sort(ks)
    for i, k in ipairs(ks) do p.primals[k].index = i end
    p.primal_length = #ks
end
local function tmass(p, x) local s = 0 for k, pr in pairs(p.primals) do if pr.kind == "elastic" or pr.kind == "headroom" then s = s + math.abs(x[k] or 0) end end return s end
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

-- unlocked baseline -> T0 -> lock
local b0 = build()
local x0u, s0u = R.drive_solve(b0, prob.meta)
if s0u ~= "finished" then io.write(("rd st=%s seed=%s\n"):format(tostring(s0u), fid)); return end
local T0 = tmass(b0, x0u)
BUDGET = T0 * (1 + 1e-3) + 1e-6
local base = build()
local x0, st0 = R.drive_solve(base, prob.meta)
if st0 ~= "finished" then io.write(("rd st=lockfail seed=%s\n"):format(fid)); return end

local inter = RS.intermediates(prob.normalized_lines)
local producible = RS.producible_set(prob.constraints, prob.normalized_lines)
local consumable = RS.consumable_set(prob.constraints, prob.normalized_lines)
local vp0, vc0, vf0 = RS.violation_split(base, x0, inter, producible, consumable)
local mach0 = machines(base, x0)
local grp0 = ngroups(base, x0)

-- active base-material groups, smallest total-phys first
local groups, order, gphys = {}, {}, {}
for k, pr in pairs(base.primals) do
    if (pr.kind == "shortage_source" or pr.kind == "surplus_sink") and phys(base, k, x0) > 1e-6 then
        local b = mat_base(pr.material or "?")
        if not groups[b] then groups[b] = {}; order[#order + 1] = b; gphys[b] = 0 end
        groups[b][#groups[b] + 1] = k; gphys[b] = gphys[b] + phys(base, k, x0)
    end
end
table.sort(order, function(a, b) return gphys[a] < gphys[b] end)

-- greedy cumulative removal; commit a removal only if the re-solve stays finished
local removed, nremoved, infeas_hits = {}, 0, 0
for _, b in ipairs(order) do
    local trial = {}
    for _, k in ipairs(removed) do trial[#trial + 1] = k end
    for _, k in ipairs(groups[b]) do trial[#trial + 1] = k end
    local p = build(); del(p, trial)
    local _, st = R.drive_solve(p, prob.meta)
    if st == "finished" then
        for _, k in ipairs(groups[b]) do removed[#removed + 1] = k end
        nremoved = nremoved + 1
    else
        infeas_hits = infeas_hits + 1 -- this group could not be dropped (kept)
    end
end

-- final reduced solve
local pf = build(); del(pf, removed)
local xf, stf = R.drive_solve(pf, prob.meta)
if stf ~= "finished" then
    io.write(("rd FINAL_INFEAS grp0=%d nrem=%d seed=%s\n"):format(grp0, nremoved, fid)); return
end
local vp1, vc1, vf1 = RS.violation_split(pf, xf, inter, producible, consumable)
io.write(string.format(
    "rd final_st=%s grp0=%d grp1=%d nrem=%d T0=%.6g Tf=%.6g mach0=%.6g machf=%.6g" ..
    " Vp0=%.6g Vpf=%.6g Vc0=%.6g Vcf=%.6g Vf0=%.6g Vff=%.6g seed=%s\n",
    stf, grp0, ngroups(pf, xf), nremoved, T0, tmass(pf, xf), mach0, machines(pf, xf),
    vp0, vp1, vc0, vc1, vf0, vf1, fid))
