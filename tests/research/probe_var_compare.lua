---@diagnostic disable: undefined-global
-- Per-variable comparison of qp / amt / rec, written to a TSV file. One row per
-- variable that is active in any approach. Values are the actual factory quantity:
--   recipe / bridge  -> machine count (the variable value)
--   shortage/initial -> physical import flow  (+, = balance coeff * value)
--   surplus/final    -> physical dump  flow   (-, = balance coeff * value)
-- (escape values are physical, NOT the rescaled variable -- coeff is read back from
-- the scaled subject terms, so amt/rec magnitudes are comparable to qp directly.)
--
--   lua tests/research/probe_var_compare.lua [dump] [BIG] [outfile]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e3
local NAME = PATH:match("([^/\\]+)%.lua$") or "dump"
local OUT = arg[3] or ("S:/tmp/var_compare_" .. NAME .. ".tsv")
local QUAD0, FLOOR, RECTHR = 2, 1e-9, 1e-2
local VIO = { shortage_source = true, surplus_sink = true }
local ESC = { shortage_source = true, surplus_sink = true, initial_source = true, final_sink = true }
local FREEK = { initial_source = true, final_sink = true }
local prob = assert(problem_dump.load_problem(PATH))

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
    return (last and last.x) or {}, state
end
local function build(scale_fn)
    local problem = create_problem.create_problem("p", prob.constraints, prob.normalized_lines, nil,
        { recipe_epsilon = (2 ^ -6) * BIG / 1e6 })
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then
            p.cost = 0; problem:set_quad(key, QUAD0)
            if scale_fn then
                local a = scale_fn(key)
                local terms = problem.subject_terms[key]
                if terms then for d, c in pairs(terms) do terms[d] = c * a end end
            end
        elseif FREEK[p.kind] then p.cost = 0; problem:set_quad(key, 0) end
    end
    strip(problem)
    return problem
end
-- factory quantity: escapes -> signed physical balance flow; recipe/bridge -> value
local function val(problem, key, x)
    local p = problem.primals[key]
    if not p then return 0 end
    if ESC[p.kind] then
        local t = problem.subject_terms[key]
        local c = (p.material and t and t[p.material]) or 1
        return c * (x[key] or 0)
    end
    return x[key] or 0
end

local pq = build(nil); local xq, sq = solve(pq)
local maxxq = 0
for key, p in pairs(pq.primals) do if VIO[p.kind] then local v = math.abs(xq[key] or 0); if v > maxxq then maxxq = v end end end
local thr = maxxq * RECTHR
local pa = build(function(key) local s = math.abs(xq[key] or 0); return s < FLOOR and FLOOR or s end)
local xa, sa = solve(pa)
local pr = build(function(key) local s = math.abs(xq[key] or 0); if s > thr then return 1 / s else return 1 end end)
local xr, sr = solve(pr)

-- union of keys, pulled from the qp problem (same structure across all three)
local rows = {}
for key, p in pairs(pq.primals) do
    local q, a, r = val(pq, key, xq), val(pa, key, xa), val(pr, key, xr)
    if math.abs(q) > 1e-9 or math.abs(a) > 1e-9 or math.abs(r) > 1e-9 then
        rows[#rows + 1] = { kind = p.kind, material = p.material or "", q = q, a = a, r = r, key = key,
            mag = math.max(math.abs(q), math.abs(a), math.abs(r)) }
    end
end
-- sort by kind, then largest magnitude first
local kind_order = { recipe = 1, bridge = 2, shortage_source = 3, surplus_sink = 4, initial_source = 5, final_sink = 6 }
table.sort(rows, function(u, v)
    local ku, kv = kind_order[u.kind] or 9, kind_order[v.kind] or 9
    if ku ~= kv then return ku < kv end
    return u.mag > v.mag
end)

local f = assert(io.open(OUT, "w"))
f:write(string.format("# %s  BIG=%g  states: qp=%s amt=%s rec=%s\n", NAME, BIG, sq, sa, sr))
f:write("# recipe/bridge = machine count; shortage/initial = +import flow; surplus/final = -dump flow (physical)\n")
f:write("kind\tmaterial\tqp\tamt\trec\tkey\n")
for _, row in ipairs(rows) do
    f:write(string.format("%s\t%s\t%.6g\t%.6g\t%.6g\t%s\n", row.kind, row.material, row.q, row.a, row.r, row.key))
end
f:close()
io.write(string.format("wrote %d rows -> %s  (qp=%s amt=%s rec=%s)\n", #rows, OUT, sq, sa, sr))
