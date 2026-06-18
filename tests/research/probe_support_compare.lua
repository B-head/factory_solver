---@diagnostic disable: undefined-global
-- Compare the ACTIVE SUPPORT (which recipes / escapes carry flow) between the
-- linear and quadratic escape-cost framings, same structure otherwise. Tests
-- "does the quadratic reveal a superset including the linear's active set?".
--   luajit tests/research/probe_support_compare.lua [dumpfile] [BIG]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e6
local QUAD_KINDS = { shortage_source = true, surplus_sink = true }
local FREE_KINDS = { initial_source = true, final_sink = true }

local function build_solve(mode)
    local prob = assert(problem_dump.load_problem(PATH))
    local problem = create_problem.create_problem("cmp", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if QUAD_KINDS[p.kind] then
            if mode == "linear" then p.cost = 1 else p.cost = 0; problem:set_quad(key, 2) end
        elseif FREE_KINDS[p.kind] then p.cost = 0; problem:set_quad(key, 0) end
    end
    local to_remove = {}
    for _, c in ipairs(prob.constraints) do
        local dual = vk.limit(tn.typed_name_to_variable_name(c))
        if problem.duals[dual] then problem.duals[dual].limit = BIG end
        to_remove[vk.elastic(dual)] = true; to_remove[vk.pos_slack(dual)] = true; to_remove[vk.neg_slack(dual)] = true
    end
    for key, p in pairs(problem.primals) do if p.kind == "elastic" or p.kind == "headroom" then to_remove[key] = true end end
    for key in pairs(to_remove) do if problem.primals[key] then problem.primals[key] = nil; problem.subject_terms[key] = nil end end
    local keys = {}; for k in pairs(problem.primals) do keys[#keys + 1] = k end; table.sort(keys)
    for i, k in ipairs(keys) do problem.primals[k].index = i end
    problem.primal_length = #keys
    local state, it, vars, last, steps = "ready", nil, nil, nil, 0
    repeat
        local ok, s, i2, v = pcall(lp.solve, problem, state, it, vars, prob.meta.tolerance, prob.meta.iterate_limit)
        if not ok then break end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
    return problem, (last and last.x) or {}, state, steps
end

-- active sets relative to per-kind park threshold (1e-6 of max recipe flow)
local function active_sets(problem, x)
    local maxr = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
    local thr = math.max(1e-9, maxr * 1e-6)
    local recipes, escapes = {}, {}
    for k, p in pairs(problem.primals) do
        local a = math.abs(x[k] or 0)
        if a > thr then
            if p.kind == "recipe" then recipes[k] = a
            elseif QUAD_KINDS[p.kind] then escapes[k] = a end
        end
    end
    return recipes, escapes, thr
end

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function only_in(a, b) local out = {} for k in pairs(a) do if not b[k] then out[#out + 1] = k end end table.sort(out) return out end

local pL, xL, stateL, stepsL = build_solve("linear")
local pQ, xQ, stateQ, stepsQ = build_solve("quad")
local rL, eL = active_sets(pL, xL)
local rQ, eQ = active_sets(pQ, xQ)

io.write(string.format("LINEAR : state=%s steps=%d  active recipes=%d  active escapes=%d\n", stateL, stepsL, count(rL), count(eL)))
io.write(string.format("QUAD   : state=%s steps=%d  active recipes=%d  active escapes=%d\n", stateQ, stepsQ, count(rQ), count(eQ)))

local rL_not_rQ = only_in(rL, rQ)
local rQ_not_rL = only_in(rQ, rL)
io.write(string.format("\nrecipes active in LINEAR but NOT in QUAD: %d\n", #rL_not_rQ))
for _, k in ipairs(rL_not_rQ) do io.write("   - " .. k .. string.format("  (lin=%.6g)\n", rL[k])) end
io.write(string.format("recipes active in QUAD but NOT in LINEAR: %d\n", #rQ_not_rL))
for _, k in ipairs(rQ_not_rL) do io.write("   + " .. k .. string.format("  (quad=%.6g)\n", rQ[k])) end

local eL_not_eQ = only_in(eL, eQ)
io.write(string.format("\nescapes active in LINEAR but NOT in QUAD: %d\n", #eL_not_eQ))
for _, k in ipairs(eL_not_eQ) do io.write("   - " .. k .. "\n") end
io.write(string.format("(escapes active in QUAD but NOT in LINEAR: %d)\n", #only_in(eQ, eL)))
