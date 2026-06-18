---@diagnostic disable: undefined-global
-- Single SYMMETRIC solve: import (shortage_source / initial-into-intermediate)
-- and dump (surplus_sink / final-of-consumable) at the SAME cost 1; genuine raw
-- and terminal byproduct free; targets BIG hard. Then classify the result with
-- the reference's producible/consumable sets to report Vp/Vf/Vc, and check the
-- two cases of interest: does it IMPORT CO2 / stop DUMPING psc (the trade the
-- lexicographic order forbids), or does it just re-open the albumin import cheat?
--
--   luajit tests/research/probe_symmetric_classified.lua [dumpfile] [BIG]

require "tests/headless_env"
local ref = require "tests/research/reference_solver"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e6

local prob = assert(problem_dump.load_problem(PATH))
for _, c in ipairs(prob.constraints) do c.limit_amount_per_second = BIG end

local producible = ref.producible_set(prob.constraints, prob.normalized_lines)
local consumable = ref.consumable_set(prob.constraints, prob.normalized_lines)
local intermediates = ref.intermediates(prob.normalized_lines)

local function is_import(p)
    return p.kind == "shortage_source" or (p.kind == "initial_source" and p.material and intermediates[p.material])
end
local function is_dump(p)
    return (p.kind == "surplus_sink" or p.kind == "final_sink") and p.material and consumable[p.material]
end

-- symmetric build: every violation outlet costs 1, genuine raw/final free
local problem = create_problem.create_problem("sym", prob.constraints, prob.normalized_lines, nil, nil)
for _, p in pairs(problem.primals) do
    if is_import(p) or is_dump(p) then p.cost = 1
    elseif p.kind == "initial_source" or p.kind == "final_sink" or p.kind == "surplus_sink" then p.cost = 0 end
end
do
    local rm = {}
    for _, c in ipairs(prob.constraints) do
        local dual = vk.limit(tn.typed_name_to_variable_name(c))
        if problem.duals[dual] then problem.duals[dual].limit = BIG end
        rm[vk.elastic(dual)] = true; rm[vk.pos_slack(dual)] = true; rm[vk.neg_slack(dual)] = true
    end
    for key, p in pairs(problem.primals) do if p.kind == "elastic" or p.kind == "headroom" then rm[key] = true end end
    for key in pairs(rm) do if problem.primals[key] then problem.primals[key] = nil; problem.subject_terms[key] = nil end end
    local keys = {}; for k in pairs(problem.primals) do keys[#keys + 1] = k end; table.sort(keys)
    for i, k in ipairs(keys) do problem.primals[k].index = i end
    problem.primal_length = #keys
end

local function solve(pp)
    local state, it, vars, last, steps = "ready", nil, nil, nil, 0
    repeat
        local ok, s, i2, v = pcall(lp.solve, pp, state, it, vars, prob.meta.tolerance, prob.meta.iterate_limit)
        if not ok then state = "errored"; break end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
    return (last and last.x) or {}, state, steps
end
local x, st, steps = solve(problem)

local maxr = 0
for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
local thr = math.max(1e-9, maxr * 1e-6)

local Vp, Vf, Vc, nrec = 0, 0, 0, 0
local imports, dumps = {}, {}
for k, p in pairs(problem.primals) do
    local v = math.abs(x[k] or 0)
    if p.kind == "recipe" and v > thr then nrec = nrec + 1 end
    if v > thr then
        if is_import(p) then
            if producible[p.material] then Vp = Vp + v; imports[#imports + 1] = { m = p.material, v = v, t = "Vp" }
            else Vf = Vf + v; imports[#imports + 1] = { m = p.material, v = v, t = "Vf" } end
        elseif is_dump(p) then Vc = Vc + v; dumps[#dumps + 1] = { m = p.material, v = v } end
    end
end

io.write("================ SYMMETRIC solve (import = dump = cost 1) ================\n")
io.write(string.format("state=%s steps=%d  active recipes=%d\n", st, steps, nrec))
io.write(string.format("Vp(producible import=DEFEAT)=%.6g  Vf(makeup import)=%.6g  Vc(consumable dump)=%.6g\n", Vp, Vf, Vc))
io.write(string.format("total violation (import+dump) = %.6g\n", Vp + Vf + Vc))

table.sort(imports, function(a, b) return a.v > b.v end)
table.sort(dumps, function(a, b) return a.v > b.v end)
io.write(string.format("\n-- IMPORTS (%d) --\n", #imports))
for _, e in ipairs(imports) do io.write(string.format("  %-4s %-13.6g %s\n", e.t, e.v, e.m)) end
io.write(string.format("\n-- DUMPS (%d) --\n", #dumps))
for _, e in ipairs(dumps) do io.write(string.format("  %-13.6g %s\n", e.v, e.m)) end

-- the two cases of interest
local function find(list, sub) for _, e in ipairs(list) do if tostring(e.m):find(sub, 1, true) then return e.v end end return 0 end
io.write("\n== cases of interest ==\n")
io.write(string.format("  CO2 imported?      %.6g\n", find(imports, "carbon-dioxide")))
io.write(string.format("  psc dumped?        %.6g\n", find(dumps, "psc@[10,10]")))
io.write(string.format("  albumin imported?  %.6g  (the fabricate-cheat tell)\n", find(imports, "item/albumin")))
