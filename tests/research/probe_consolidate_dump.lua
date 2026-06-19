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
local dissect = require "tests/research/dissect"
local research_lib = require "tests/research/research_lib"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e6

local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }

local prob = assert(problem_dump.load_problem(PATH))

-- SCC tags over the material graph (recipes + bridges), C01.. by size
local p0 = create_problem.create_problem("t", prob.constraints, prob.normalized_lines, nil, nil)
local mat_scc = dissect.cyclic_sccs(dissect.all_lines(prob.normalized_lines, p0)).tag
local function tag(material) return material and (mat_scc[material] or "-") or "?" end

-- build: targets -> hard equality at BIG (elastic/slacks stripped), violations=1,
-- raw/final free. Matches probe_consolidate.lua round 0.
local problem = create_problem.create_problem("cd", prob.constraints, prob.normalized_lines, nil, nil)
for key, p in pairs(problem.primals) do
    if VIO[p.kind] then p.cost = 1
    elseif FREEK[p.kind] then p.cost = 0 end
end
research_lib.harden_targets(problem, prob.constraints, BIG)

local x, st, steps = research_lib.drive_solve(problem, prob.meta)

-- threshold
local thr = dissect.solved_threshold(problem, x)

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
