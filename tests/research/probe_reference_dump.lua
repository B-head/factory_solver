---@diagnostic disable: undefined-global
-- Full dump of the REFERENCE solver's solution = the problem DEFINITION's gold
-- answer (T >> Vp >> Vf >> Vc >> M, reference_solver.lua). Each active escape is
-- classified the same way the reference scores it:
--   Vp  producible import  = the DEFEAT (could make it, outsourced it)
--   Vf  non-producible import = legitimate makeup boundary
--   Vc  consumable dump    = the dual DEFEAT (could consume it, trashed it)
--   raw / final / free-dump = not violations (raw in, terminal byproduct, brood)
-- Targets forced to BIG to match the earlier flat-cost dump (scale-invariant).
--
--   luajit tests/research/probe_reference_dump.lua [dumpfile] [BIG]

require "tests/headless_env"
local ref = require "tests/research/reference_solver"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local material_cycles = require "solver/material_cycles"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e6

local prob = assert(problem_dump.load_problem(PATH))
for _, c in ipairs(prob.constraints) do c.limit_amount_per_second = BIG end

-- SCC tags
local function scc_tags()
    local p0 = create_problem.create_problem("t", prob.constraints, prob.normalized_lines, nil, nil)
    local lines = {}
    for _, l in ipairs(prob.normalized_lines) do lines[#lines + 1] = l end
    for _, l in ipairs(p0.bridges) do lines[#lines + 1] = l end
    local adj = material_cycles.build_material_graph(lines)
    local sccs = material_cycles.find_sccs(adj)
    local cyc = {}
    for _, s in ipairs(sccs) do if material_cycles.is_cyclic_scc(s, adj) then cyc[#cyc + 1] = s end end
    table.sort(cyc, function(a, b) if #a ~= #b then return #a > #b end return a[1] < b[1] end)
    local m = {}
    for i, s in ipairs(cyc) do for _, mm in ipairs(s) do m[mm] = string.format("C%02d", i) end end
    return m
end
local mat_scc = scc_tags()
local function tag(material) return material and (mat_scc[material] or "-") or "?" end

local r = ref.solve_reference(prob.constraints, prob.normalized_lines)
io.write("================ REFERENCE (definition) SOLUTION ================\n")
io.write(string.format("file=%s\nstate=%s  steps=%d  BIG=%g\n", PATH:match("[^/]+$"), r.state, r.steps or -1, BIG))
io.write(string.format("T=%.6g  Vp=%.6g  Vf=%.6g  Vc=%.6g  M=%.6g  S(all surplus)=%.6g\n",
    r.T, r.Vp, r.Vf, r.Vc, r.M, r.S))
if r.state ~= "finished" then return end

local problem, x = r.problem, r.x
local producible, consumable = r.producible, r.consumable
local intermediates = ref.intermediates(prob.normalized_lines)

local function is_import(p)
    return p.kind == "shortage_source"
        or (p.kind == "initial_source" and p.material and intermediates[p.material])
end
local function is_dump(p)
    return (p.kind == "surplus_sink" or p.kind == "final_sink") and p.material and consumable[p.material]
end
local function classify(p)
    if p.kind == "recipe" then return "RECIPE" end
    if p.kind == "bridge" then return "bridge" end
    if is_import(p) then return producible[p.material] and "Vp DEFEAT (producible import)" or "Vf makeup import (non-producible)" end
    if is_dump(p) then return "Vc DEFEAT (consumable dump)" end
    if p.kind == "initial_source" then return "raw in (free)" end
    if p.kind == "final_sink" then return "final/byproduct out (free)" end
    if p.kind == "surplus_sink" then return "free dump (non-consumable: brood/byproduct)" end
    return p.kind
end

-- threshold
local maxr = 0
for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
local thr = math.max(1e-9, maxr * 1e-6)

local cats, order = {}, {}
for k, p in pairs(problem.primals) do
    local v = math.abs(x[k] or 0)
    if v > thr then
        local c = classify(p)
        if not cats[c] then cats[c] = {}; order[#order + 1] = c end
        cats[c][#cats[c] + 1] = { v = v, k = k, m = p.material }
    end
end
-- print defeats first, then makeup, then free, then recipes/bridges
local rank = {
    ["Vp DEFEAT (producible import)"] = 1, ["Vc DEFEAT (consumable dump)"] = 2,
    ["Vf makeup import (non-producible)"] = 3, ["raw in (free)"] = 4,
    ["free dump (non-consumable: brood/byproduct)"] = 5, ["final/byproduct out (free)"] = 6,
    ["RECIPE"] = 7, ["bridge"] = 8,
}
table.sort(order, function(a, b) return (rank[a] or 9) < (rank[b] or 9) end)
for _, c in ipairs(order) do
    local g = cats[c]
    table.sort(g, function(a, b) return a.v > b.v end)
    io.write(string.format("\n-- %s (%d) --\n", c, #g))
    for _, e in ipairs(g) do io.write(string.format("  {%-4s} %-15.7g %s\n", tag(e.m), e.v, e.k)) end
end
