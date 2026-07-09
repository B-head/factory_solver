---@diagnostic disable: undefined-global
-- Both shapes on a REAL explorer dump, target-locked:
--   shape A (non-minimal) = plain shipped-style L2, every hatch open.
--   shape B (minimal)     = greedy: delete active violation channels smallest-
--                           first, keep a deletion when the re-solve stays
--                           feasible AND the target holds; repeat until no
--                           active channel can be deleted. The survivors are a
--                           minimal feasible elastic set (upper bound, greedy).
-- Output: per-material physical import/dump for both shapes + recipe-machine
-- movers, so the two factories can be READ side by side. Machines reported
-- only, never judged. No verdict labels -- raw numbers.
--   lua tests/research/probe_min_vs_spread.lua <dump.lua>
require "tests/headless_env"
local R = require "tests/research/research_lib"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local EPS = 2 ^ -10

local prob = assert(problem_dump.load_problem(arg[1]))
local fid = arg[1]:match("[^/\\]+$")

local function phys(p, k, x)
    local pr, t = p.primals[k], p.subject_terms[k]
    local c = (pr and pr.material and t and t[pr.material]) or 1
    return math.abs(c * (x[k] or 0))
end
local function tmass(p, x)
    local s = 0
    for k, pr in pairs(p.primals) do
        if pr.kind == "elastic" or pr.kind == "headroom" then s = s + math.abs(x[k] or 0) end
    end
    return s
end

local BUDGET
local function build()
    local o = { reachability_gating = false, deficit_seeding = false,
        catalyst_closure = false, surplus_sink_gating = false, recipe_epsilon = EPS }
    if BUDGET then o.target_budget = BUDGET end
    local p = cp.create_problem("l2", prob.constraints, prob.normalized_lines, nil, o)
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
local sk = function(k)
    return (k:gsub("|shortage_source|", "IMP "):gsub("|surplus_sink|", "DUMP "):gsub("/normal$", ""))
end

-- T0 unlocked, then lock the target for every build (shipped-rescue analogue).
local p0 = build()
local x0u = R.drive_solve(p0, prob.meta)
local T0 = tmass(p0, x0u)
BUDGET = T0 * (1 + 1e-3) + 1e-6

-- Shape A: plain L2 under the lock.
local base = build()
local xA, stA = R.drive_solve(base, prob.meta)
assert(stA == "finished", "baseline did not converge")
local TA = tmass(base, xA)

local active = {}
for k, pr in pairs(base.primals) do
    if (pr.kind == "shortage_source" or pr.kind == "surplus_sink") and phys(base, k, xA) > 1e-6 then
        active[#active + 1] = { k = k, v = phys(base, k, xA) }
    end
end
table.sort(active, function(a, b) return a.v < b.v end) -- smallest first for greedy

io.write(("== %s   T0=%.4g  activeA=%d\n"):format(fid, T0, #active))

-- Shape B: greedy deletion, smallest-first, keep-if-feasible-and-target-holds.
local deleted, kept = {}, {}
local solves = 2
local pB, xB = base, xA
for _, e in ipairs(active) do
    local trial = {}
    for _, d in ipairs(deleted) do trial[#trial + 1] = d end
    trial[#trial + 1] = e.k
    local p = build()
    del(p, trial)
    local x, st = R.drive_solve(p, prob.meta)
    solves = solves + 1
    local ok = (st == "finished") and tmass(p, x) <= T0 * (1 + 1e-2) + 1e-6
    if ok then
        deleted[#deleted + 1] = e.k
        pB, xB = p, x
    else
        kept[#kept + 1] = { k = e.k, why = tostring(st) }
    end
end

-- Survivors actually active in shape B.
local function collect(p, x)
    local imp, dmp = {}, {}
    for k, pr in pairs(p.primals) do
        local v = phys(p, k, x)
        if v > 1e-6 then
            if pr.kind == "shortage_source" then imp[#imp + 1] = { k = k, v = v }
            elseif pr.kind == "surplus_sink" then dmp[#dmp + 1] = { k = k, v = v } end
        end
    end
    table.sort(imp, function(a, b) return a.v > b.v end)
    table.sort(dmp, function(a, b) return a.v > b.v end)
    return imp, dmp
end
local impA, dmpA = collect(base, xA)
local impB, dmpB = collect(pB, xB)

local function show(tag, list)
    io.write(tag, " (", #list, ")\n")
    for _, e in ipairs(list) do io.write(("  %-56s %.6g\n"):format(sk(e.k), e.v)) end
end
io.write(("-- shape A: plain L2 (T=%.4g, solves so far n/a)\n"):format(TA))
show("A imports", impA)
show("A dumps", dmpA)
io.write(("-- shape B: greedy-minimal (deleted=%d, kept-forced=%d, T=%.4g, %d solves)\n")
    :format(#deleted, #kept, tmass(pB, xB), solves))
show("B imports", impB)
show("B dumps", dmpB)

-- Recipe movers between the two shapes (machines: reported only).
local movers, totA, totB = {}, 0, 0
for k, pr in pairs(base.primals) do
    if pr.kind == "recipe" then
        local a = math.abs(xA[k] or 0)
        local b = math.abs(xB[k] or 0)
        totA = totA + a; totB = totB + b
        if math.abs(a - b) > math.max(1e-3, 0.05 * math.max(a, b)) then
            movers[#movers + 1] = { k = k, a = a, b = b, d = math.abs(a - b) }
        end
    end
end
table.sort(movers, function(x1, x2) return x1.d > x2.d end)
io.write(("-- machines total A=%.6g B=%.6g (report only)\n"):format(totA, totB))
io.write("-- recipe movers (|A-B| top 15)\n")
for i = 1, math.min(15, #movers) do
    local m = movers[i]
    io.write(("  %-56s A=%-10.5g B=%-10.5g\n"):format(m.k:gsub("/normal$", ""), m.a, m.b))
end
