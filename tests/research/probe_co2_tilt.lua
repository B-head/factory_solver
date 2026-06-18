---@diagnostic disable: undefined-global
-- Verify the per-material tilt lever on seed_143's psc/CO2 case.
-- Single LP, fabricate-biased: intermediate import (shortage_source) priced HIGH
-- so clean materials get fabricated (no albumin cheat); dump (surplus_sink)
-- priced at DUMP so a forced byproduct dump actually costs something; raw/final
-- free. Two modes:
--   A : every intermediate import = HI            (no exception)
--   B : every intermediate import = HI, EXCEPT carbon-dioxide = LO (cheap import)
-- Hypothesis: B imports CO2, the 6.78M psc dump collapses, albumin stays
-- FABRICATED, total violation drops far below A. If A already imports albumin
-- (cheat) HI is too low; if B still dumps psc the lever fails.
--
--   luajit tests/research/probe_co2_tilt.lua [dumpfile] [HI] [DUMP] [LO]

require "tests/headless_env"
local ref = require "tests/research/reference_solver"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local HI = tonumber(arg[2]) or 1024
local DUMP = tonumber(arg[3]) or 1
local LO = tonumber(arg[4]) or 1
local BIG = 1e6

local prob = assert(problem_dump.load_problem(PATH))
for _, c in ipairs(prob.constraints) do c.limit_amount_per_second = BIG end

local producible = ref.producible_set(prob.constraints, prob.normalized_lines)
local consumable = ref.consumable_set(prob.constraints, prob.normalized_lines)
local intermediates = ref.intermediates(prob.normalized_lines)
local function is_import(p) return p.kind == "shortage_source" or (p.kind == "initial_source" and p.material and intermediates[p.material]) end
local function is_dump(p) return (p.kind == "surplus_sink" or p.kind == "final_sink") and p.material and consumable[p.material] end

local function build(co2_cheap)
    local problem = create_problem.create_problem("co2", prob.constraints, prob.normalized_lines, nil, nil)
    for _, p in pairs(problem.primals) do
        if p.kind == "shortage_source" then
            local cheap = co2_cheap and p.material and tostring(p.material):find("carbon-dioxide", 1, true)
            p.cost = cheap and LO or HI
        elseif p.kind == "surplus_sink" then p.cost = DUMP
        elseif p.kind == "initial_source" or p.kind == "final_sink" then p.cost = 0 end
    end
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
    return problem
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

local function find_mat(problem, x, kind, sub)
    local total = 0
    for k, p in pairs(problem.primals) do
        if p.kind == kind and p.material and tostring(p.material):find(sub, 1, true) then total = total + math.abs(x[k] or 0) end
    end
    return total
end

local function report(label, problem, x, st)
    local maxr = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
    local thr = math.max(1e-9, maxr * 1e-6)
    local Vp, Vf, Vc, nrec = 0, 0, 0, 0
    for k, p in pairs(problem.primals) do
        local v = math.abs(x[k] or 0)
        if p.kind == "recipe" and v > thr then nrec = nrec + 1 end
        if v > thr then
            if is_import(p) then if producible[p.material] then Vp = Vp + v else Vf = Vf + v end
            elseif is_dump(p) then Vc = Vc + v end
        end
    end
    io.write(string.format("\n## %s : state=%s recipes=%d\n", label, st, nrec))
    io.write(string.format("   Vp(producible import)=%.6g  Vf(makeup)=%.6g  Vc(consumable dump)=%.6g  total=%.6g\n",
        Vp, Vf, Vc, Vp + Vf + Vc))
    io.write(string.format("   CO2 import(shortage)=%.6g   psc dump(surplus)=%.6g\n",
        find_mat(problem, x, "shortage_source", "carbon-dioxide"), find_mat(problem, x, "surplus_sink", "psc@[10,10]")))
    io.write(string.format("   albumin import=%.6g   albumin fabricate x(albumin-1)=%.6g\n",
        find_mat(problem, x, "shortage_source", "item/albumin"), math.abs(x["recipe/albumin-1/normal"] or 0)))
end

-- does a CO2 shortage_source variable even exist?
local pA = build(false)
local has_co2 = 0
for k, p in pairs(pA.primals) do if p.kind == "shortage_source" and p.material and tostring(p.material):find("carbon-dioxide", 1, true) then has_co2 = has_co2 + 1 end end
io.write(string.format("================ CO2 TILT (HI=%g DUMP=%g LO=%g) ================\n", HI, DUMP, LO))
io.write(string.format("CO2 shortage_source variables present: %d\n", has_co2))

local xA, stA = solve(pA)
report("A: no exception (all imports HI)", pA, xA, stA)

local pB = build(true)
local xB, stB = solve(pB)
report("B: CO2 import cheap (LO)", pB, xB, stB)
