---@diagnostic disable: undefined-global
-- Does a recipe-epsilon TIE-BREAK on a degenerate face reach the good
-- (import-CO2 / fabricate) solution? Two faces x several epsilons:
--   QP-gradient face : escapes priced at c'=2*x_q (the QP gradient -> degenerate
--                      face, session start), recipes at eps.
--   symmetric face   : import=dump=1 (compares import vs dump), recipes at eps.
-- eps in {0, 2^-6 (shipped default), 1 (strong min-machines)}.
-- Reference points: GOOD = import CO2(+negasium), psc dump 0, total ~1.72e5, 13
-- recipes. CHEAT = import albumin, total ~3.2e4, 2 recipes.
--
--   luajit tests/research/probe_tiebreak_face.lua [dumpfile]

require "tests/headless_env"
local ref = require "tests/research/reference_solver"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = 1e6

local prob = assert(problem_dump.load_problem(PATH))
for _, c in ipairs(prob.constraints) do c.limit_amount_per_second = BIG end
local producible = ref.producible_set(prob.constraints, prob.normalized_lines)
local consumable = ref.consumable_set(prob.constraints, prob.normalized_lines)
local intermediates = ref.intermediates(prob.normalized_lines)
local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }
local function is_import(p) return p.kind == "shortage_source" or (p.kind == "initial_source" and p.material and intermediates[p.material]) end
local function is_dump(p) return (p.kind == "surplus_sink" or p.kind == "final_sink") and p.material and consumable[p.material] end

local function strip(problem)
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
local function find(problem, x, kind, sub)
    local t = 0
    for k, p in pairs(problem.primals) do if p.kind == kind and p.material and tostring(p.material):find(sub, 1, true) then t = t + math.abs(x[k] or 0) end end
    return t
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
    io.write(string.format("  %-26s state=%-9s recipes=%-3d Vp=%-9.6g Vc=%-9.6g total=%-9.6g | CO2imp=%-8.5g pscDump=%-9.6g albImp=%.5g\n",
        label, st, nrec, Vp, Vc, Vp + Vf + Vc, find(problem, x, "shortage_source", "carbon-dioxide"),
        find(problem, x, "surplus_sink", "psc@[10,10]"), find(problem, x, "shortage_source", "item/albumin")))
end

-- QP solve for x_q (uniform quad on escapes)
local function build_qp()
    local problem = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = 0; problem:set_quad(key, 2)
        elseif FREEK[p.kind] then p.cost = 0; problem:set_quad(key, 0) end
    end
    strip(problem)
    return problem
end
local pq = build_qp()
local xq = solve(pq)

-- linear build: escape cost via fn(key,p), recipe cost = eps
local function build_linear(escape_cost, eps)
    local problem = create_problem.create_problem("lin", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = escape_cost(key, p)
        elseif FREEK[p.kind] then p.cost = 0
        elseif p.kind == "recipe" then p.cost = eps end
    end
    strip(problem)
    return problem
end

io.write("================ TIE-BREAK ON A FACE: does recipe-eps reach the good solution? ================\n")
io.write("reference points:  GOOD = total~1.72e5 / 13 recipes / CO2 imported / psc dump 0\n")
io.write("                   CHEAT = total~3.2e4 / 2 recipes / albumin imported\n")

io.write("\n-- QP-gradient face (escapes priced c'=2*x_q) + recipe eps --\n")
for _, eps in ipairs({ 0, 2 ^ -6, 1 }) do
    local p = build_linear(function(key) return 2 * math.max(0, xq[key] or 0) end, eps)
    local x, st = solve(p)
    report(string.format("eps=%.5g", eps), p, x, st)
end

io.write("\n-- symmetric face (import=dump=1) + recipe eps --\n")
for _, eps in ipairs({ 0, 2 ^ -6, 1 }) do
    local p = build_linear(function() return 1 end, eps)
    local x, st = solve(p)
    report(string.format("eps=%.5g", eps), p, x, st)
end
