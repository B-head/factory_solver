---@diagnostic disable: undefined-global
-- QP -> amount-baked re-solve: raw observation probe.
--
-- PASS Q: uniform (QUAD0/2)*x^2 on elastic escapes (shortage_source + surplus_sink),
--   free (cost=0, quad=0) on initial_source/final_sink, hard targets at BIG.
--
-- PASS A: SAME structure & quadratic cost, but each elastic escape's constraint
--   coefficients are multiplied by x_q[key] (the "amount lever": a_k -> a_k * x_q).
--   Near-zero x_q escapes get floor=1e-9 instead of literal 0.
--
-- Output: two separate files. --out-q <path> and --out-a <path>.
-- Each file has a header row, then one line per active variable.
-- Columns: kind, key, x (the variable value in that pass's solution)
--
--   lua tests/research/probe_amt_raw.lua <dump> --out-q <path> --out-a <path>

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH, OUT_Q, OUT_A
do
    local i = 1
    while arg[i] do
        if arg[i] == "--out-q" then i = i + 1; OUT_Q = arg[i]
        elseif arg[i] == "--out-a" then i = i + 1; OUT_A = arg[i]
        elseif not PATH then PATH = arg[i]
        end
        i = i + 1
    end
end
PATH = PATH or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
OUT_Q = OUT_Q or "S:/tmp/amt_pass_q.tsv"
OUT_A = OUT_A or "S:/tmp/amt_pass_a.tsv"

local BIG = 1e3
local QUAD0 = 2
local FLOOR = 1e-9
local ELASTIC = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }

local prob = assert(problem_dump.load_problem(PATH))

local function big_targets(problem)
    local rm = {}
    for _, c in ipairs(prob.constraints) do
        local dual = vk.limit(tn.typed_name_to_variable_name(c))
        if problem.duals[dual] then problem.duals[dual].limit = BIG end
        rm[vk.elastic(dual)] = true; rm[vk.pos_slack(dual)] = true; rm[vk.neg_slack(dual)] = true
    end
    for key, p in pairs(problem.primals) do if p.kind == "elastic" or p.kind == "headroom" then rm[key] = true end end
    for key in pairs(rm) do if problem.primals[key] then problem.primals[key] = nil; problem.subject_terms[key] = nil end end
end
local function reindex(problem)
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
    return (last and last.x) or {}, state
end

local function dump_solution(problem, x, path, description)
    local f = assert(io.open(path, "w"))
    f:write("# " .. description .. "\n")
    f:write("kind\tkey\tx\n")
    local maxr = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
    local thr = math.max(1e-9, maxr * 1e-6)
    local rows = {}
    for k, p in pairs(problem.primals) do
        local v = x[k] or 0
        if math.abs(v) > thr then
            rows[#rows + 1] = { kind = p.kind, key = k, x = v }
        end
    end
    table.sort(rows, function(a, b) return a.key < b.key end)
    for _, r in ipairs(rows) do
        f:write(string.format("%s\t%s\t%.6g\n", r.kind, r.key, r.x))
    end
    f:close()
    io.write(string.format("wrote %d rows to %s\n", #rows, path))
end

-- PASS Q: uniform quad on escapes
local pq = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil,
    { recipe_epsilon = (2 ^ -6) * BIG / 1e6 })
for key, p in pairs(pq.primals) do
    if ELASTIC[p.kind] then p.cost = 0; pq:set_quad(key, QUAD0)
    elseif FREEK[p.kind] then p.cost = 0; pq:set_quad(key, 0) end
end
big_targets(pq); reindex(pq)
local xq, stq = solve(pq)
assert(stq == "finished", "pass Q did not converge: " .. stq)

dump_solution(pq, xq, OUT_Q,
    "Pass Q: min sum (QUAD0/2)*x^2 on shortage_source+surplus_sink, cost=0 on initial_source+final_sink, recipe_eps on recipes. Targets hard at BIG=" .. BIG)

-- PASS A: bake a_k = x_q[k] into escape coefficients, same quad
local pa = create_problem.create_problem("amt", prob.constraints, prob.normalized_lines, nil,
    { recipe_epsilon = (2 ^ -6) * BIG / 1e6 })
for key, p in pairs(pa.primals) do
    if ELASTIC[p.kind] then
        p.cost = 0; pa:set_quad(key, QUAD0)
        local s = math.max(0, xq[key] or 0); if s < FLOOR then s = FLOOR end
        local terms = pa.subject_terms[key]
        if terms then for dual, coeff in pairs(terms) do terms[dual] = coeff * s end end
    elseif FREEK[p.kind] then p.cost = 0; pa:set_quad(key, 0) end
end
big_targets(pa); reindex(pa)
local xa, sta = solve(pa)
assert(sta == "finished", "pass A did not converge: " .. sta)

dump_solution(pa, xa, OUT_A,
    "Pass A: same QP as Q, but each elastic escape's constraint coefficients multiplied by x_q[key]. floor=" .. FLOOR)
