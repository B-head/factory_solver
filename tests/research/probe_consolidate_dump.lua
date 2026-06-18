---@diagnostic disable: undefined-global
-- Full solution dump of the CONSOLIDATED solve, with the REAL targets (no BIG
-- override), so the solution can be inspected against the problem definition
-- (T >> Vp >> Vf >> Vc >> M).
--
-- Setup (faithful single-LP rendering of the definition):
--   * targets: real limit_amount_per_second, elastic kept at target_cost (so the
--     target tier is honored; elastic ~0 means the target is met).
--   * shortage_source + surplus_sink (the violations): uniform cost 1.
--   * initial_source + final_sink (raw / final product): FREE (definition: usage
--     does not matter).
--   * recipes: left at create_problem's recipe_epsilon tie-break.
--
--   luajit tests/research/probe_consolidate_dump.lua [dumpfile]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local material_cycles = require "solver/material_cycles"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e6

local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }

local prob = assert(problem_dump.load_problem(PATH))

-- SCC tags over the material graph (recipes + bridges)
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

-- build: targets -> hard equality at BIG (elastic/slacks stripped), violations=1,
-- raw/final free. Matches probe_consolidate.lua round 0.
local problem = create_problem.create_problem("cd", prob.constraints, prob.normalized_lines, nil, nil)
for key, p in pairs(problem.primals) do
    if VIO[p.kind] then p.cost = 1
    elseif FREEK[p.kind] then p.cost = 0 end
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

-- threshold
local maxr = 0
for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
local thr = math.max(1e-9, maxr * 1e-6)

-- collect by kind
local groups = {}
local function add(kind, key, p) groups[kind] = groups[kind] or {}; local g = groups[kind]; g[#g + 1] = { k = key, v = math.abs(x[key] or 0), m = p.material } end
for k, p in pairs(problem.primals) do
    local v = math.abs(x[k] or 0)
    if v > thr then add(p.kind, k, p) end
end
local function dump_group(kind, label)
    local g = groups[kind]
    io.write(string.format("\n-- %s (%d) --\n", label, g and #g or 0))
    if not g then return end
    table.sort(g, function(a, b) return a.v > b.v end)
    for _, e in ipairs(g) do io.write(string.format("  {%-4s} %-15.7g %s\n", tag(e.m), e.v, e.k)) end
end

io.write("================ CONSOLIDATED SOLUTION (targets forced to BIG, hard) ================\n")
io.write(string.format("file=%s\nstate=%s steps=%d  thr=%.3g  BIG=%g\n", PATH:match("[^/]+$"), st, steps, thr, BIG))

-- TARGETS: each constraint is forced to BIG/s as a hard equality (elastics stripped)
io.write("\n-- TARGETS (all forced to BIG/s, hard equality) --\n")
for _, c in ipairs(prob.constraints) do
    io.write(string.format("  %-8s  %s\n", c.limit_type, tn.typed_name_to_variable_name(c)))
end

dump_group("recipe", "RECIPES that run (machine flow/s)")
dump_group("initial_source", "RAW imports (free)")
dump_group("final_sink", "FINAL outputs (free)")
dump_group("shortage_source", "VIOLATION: intermediate shortage (import)")
dump_group("surplus_sink", "VIOLATION: intermediate surplus (dump)")
dump_group("bridge", "bridges")

-- totals
local vio_total, raw_total, fin_total, rec_total = 0, 0, 0, 0
for k, p in pairs(problem.primals) do
    local v = math.abs(x[k] or 0)
    if VIO[p.kind] then vio_total = vio_total + v
    elseif p.kind == "initial_source" then raw_total = raw_total + v
    elseif p.kind == "final_sink" then fin_total = fin_total + v
    elseif p.kind == "recipe" then rec_total = rec_total + v end
end
io.write(string.format("\n== totals ==\n  total violation (shortage+surplus) = %.6g\n  raw import total = %.6g   final out total = %.6g\n  recipe (machine) total = %.6g\n",
    vio_total, raw_total, fin_total, rec_total))
