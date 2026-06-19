---@diagnostic disable: undefined-global
-- Import<->dump EXCHANGE RATE via a de-lexicographized auxiliary LP. The shipped
-- solver's strict Vp>>Vc makes the trade infinity:1 (the (B) defect). Here we read
-- the FINITE trade as a frontier: minimize total IMPORT subject to total DUMP <= s,
-- sweeping the dump budget s. import is the MINIMIZED objective (cost 1) so it is
-- never wasted; dump is the capped resource. The slope -d(import)/d(s) is the
-- exchange rate = how much import you must pay to remove one unit of dump.
--
-- Two structural readings per problem:
--   i_floor   = min import with dump free      (the unavoidable raw/makeup import, Vf)
--   i_nodump  = min import with dump forced 0   (import needed to avoid ALL dump)
--   the gap (i_nodump - i_floor) over the avoidable dump = the average exchange rate.
--   rate ~ 0  => importing does NOT buy dump avoidance (decoupled; dump is forced).
--   rate high => a little import kills a lot of dump (the (B) "justify the import").
--
--   luajit tests/research/probe_exchange_rate.lua [dumpfile ...]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local BIG = 1e6
local DEFAULT = {}
do
    local dir = (os.getenv("FS_CORPUS_DIR") or "S:/tmp/explore_problems"):gsub("\\", "/")
    for _, v in ipairs({
        "seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly",
        "seed_143_cycle_recipe_vex_sex_p1_noq_tnetneg_coff_h24",
        "seed_143_cycle_recipe_vex_sex_p1_noq_tnetneg_coff_h48",
        "seed_143_cycle_recipe_vex_sex_p1_noq_ttrapdown_coff_h24",
        "seed_143_cycle_recipe_vex_sex_p1_noq_trecipe_con_h24",
        "seed_143_both_recipe_vin_sin_p1_noq_trecipe_con_h12",
    }) do DEFAULT[#DEFAULT + 1] = dir .. "/" .. v .. ".lua" end
end
local PATHS = (#arg > 0) and arg or DEFAULT

local function strip(prob, problem)
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
local function solve(prob, pp)
    local state, it, vars, last, steps = "ready", nil, nil, nil, 0
    repeat
        local ok, s, i2, v = pcall(lp.solve, pp, state, it, vars, prob.meta.tolerance, prob.meta.iterate_limit)
        if not ok then return {}, "errored" end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
    return (last and last.x) or {}, state
end

-- minimize total import (cost 1 on shortage_source), subject to total dump <= cap.
local function build_minimport(prob, all_dump, dump_cap)
    local p = create_problem.create_problem("minimp", prob.constraints, prob.normalized_lines, nil, nil)
    for _, pp in pairs(p.primals) do pp.cost = (pp.kind == "shortage_source") and 1 or 0 end
    strip(prob, p)
    local dual = "|dumpcap|"
    p:add_upper_limit_constraint(dual, dump_cap)
    for _, k in ipairs(all_dump) do if p.primals[k] then p:add_subject_term(k, dual, 1) end end
    return p
end
local function kinds(problem, kind)
    local ks = {}; for k, p in pairs(problem.primals) do if p.kind == kind then ks[#ks + 1] = k end end; return ks
end
local function sumk(x, ks) local s = 0 for _, k in ipairs(ks) do s = s + math.abs(x[k] or 0) end return s end

io.write("=========== import<->dump exchange frontier (min import s.t. dump<=s) ===========\n")
io.write(string.format("%-46s %-7s %-12s %-12s %-12s %-10s\n",
    "variant", "imp", "dump", "i_floor", "i_nodump", "rate"))
for _, path in ipairs(PATHS) do
    local ok, prob = pcall(problem_dump.load_problem, path)
    local tag = (path:match("seed_143_(.-)%.lua")) or path:match("[^/\\]+$")
    if not (ok and prob) then
        io.write(string.format("%-46s  LOAD FAIL\n", tag:sub(1, 46)))
    else
        local p0 = create_problem.create_problem("probe", prob.constraints, prob.normalized_lines, nil, nil)
        strip(prob, p0)
        local all_dump = kinds(p0, "surplus_sink")

        -- floor: min import with dump free -> i_floor and the dump it tolerates (s_max)
        local xf, stf = solve(prob, build_minimport(prob, all_dump, BIG))
        local i_floor = sumk(xf, kinds(p0, "shortage_source"))
        local s_max = sumk(xf, all_dump)

        -- no-dump end: min import with dump forced to 0
        local x0, st0 = solve(prob, build_minimport(prob, all_dump, 0))
        local i_nodump = sumk(x0, kinds(p0, "shortage_source"))

        -- neutral baseline (min total escape) for reference
        local pn = create_problem.create_problem("neu", prob.constraints, prob.normalized_lines, nil, nil)
        for _, pp in pairs(pn.primals) do pp.cost = (pp.kind == "shortage_source" or pp.kind == "surplus_sink") and 1 or 0 end
        strip(prob, pn)
        local xn = solve(prob, pn)
        local nimp, ndump = sumk(xn, kinds(pn, "shortage_source")), sumk(xn, kinds(pn, "surplus_sink"))

        local rate = (s_max > 1e-6 and st0 == "finished") and ((i_nodump - i_floor) / s_max) or 0/0
        io.write(string.format("%-46s %-7.4g %-12.6g %-12.6g %-12.6g %-10.4g  (%s/%s)\n",
            tag:sub(1, 46), nimp, ndump, i_floor, i_nodump, rate, stf, st0))
    end
end
io.write("\nrate = (i_nodump - i_floor)/s_max  [import paid per unit dump avoided]\n")
io.write("  ~0  => decoupled (dump is structurally forced; importing can't avoid it)\n")
io.write("  >0  => a real finite import<->dump trade -- the (B) rate, no longer infinity:1\n")
