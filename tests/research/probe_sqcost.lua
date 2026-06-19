---@diagnostic disable: undefined-global
-- "L2-solution-squared as a linear LP cost" experiment. Solve the L2 (least-norm)
-- QP -> x_q, then solve a pure LP whose linear cost on each violation escape is
-- c_k = x_q[k]^2 (recipes pinned at recipe_epsilon, free I/O at 0). Reports raw
-- factory quantities (physical) for L2 and the sq-cost LP, and writes a per-variable
-- TSV. No reference metric, no derived score.
--
--   lua tests/research/probe_sqcost.lua [dump] [BIG] [outfile]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e3
local NAME = PATH:match("([^/\\]+)%.lua$") or "dump"
local OUT = arg[3] or ("S:/tmp/var_sqcost_" .. NAME .. ".tsv")
local QUAD0 = 2
local RECIPE_EPS = (2 ^ -6) * BIG / 1e6
local VIO = { shortage_source = true, surplus_sink = true }
local ESC = { shortage_source = true, surplus_sink = true, initial_source = true, final_sink = true }
local FREEK = { initial_source = true, final_sink = true }
local prob = assert(problem_dump.load_problem(PATH))

local function striptargets(problem)
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
-- L2 (least-norm QP)
local function build_l2()
    local problem = create_problem.create_problem("l2", prob.constraints, prob.normalized_lines, nil,
        { recipe_epsilon = RECIPE_EPS })
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = 0; problem:set_quad(key, QUAD0)
        elseif FREEK[p.kind] then p.cost = 0; problem:set_quad(key, 0) end
    end
    striptargets(problem); reindex(problem); return problem
end
-- sq-cost LP: linear cost c_k = max(x_q[k]^2, SQ_FLOOR) on escapes (the floor stops
-- the near-0-x_q escapes from being cost-0 free-wash channels), recipe at recipe_epsilon
local SQ_FLOOR = tonumber(os.getenv("FS_SQ_FLOOR")) or 1e-3
local function build_sq(xq)
    local problem = create_problem.create_problem("sq", prob.constraints, prob.normalized_lines, nil,
        { recipe_epsilon = RECIPE_EPS })
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then local s = math.abs(xq[key] or 0); p.cost = math.max(s * s, SQ_FLOOR)
        elseif FREEK[p.kind] then p.cost = 0 end
    end
    striptargets(problem); reindex(problem); return problem
end
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
local function summary(problem, x)
    local imp, dmp, rec, nimp, maximp = 0, 0, 0, 0, 0
    for key, p in pairs(problem.primals) do
        if p.kind == "shortage_source" then
            local v = math.abs(val(problem, key, x)); imp = imp + v
            if v > 1e-6 then nimp = nimp + 1 end; if v > maximp then maximp = v end
        elseif p.kind == "surplus_sink" then dmp = dmp + math.abs(val(problem, key, x))
        elseif p.kind == "recipe" then rec = rec + math.abs(x[key] or 0) end
    end
    return imp, dmp, rec, nimp, (imp > 0 and maximp / imp or 0)
end

local pq = build_l2(); local xq, sq2 = solve(pq)
local ps = build_sq(xq); local xs, ss = solve(ps)

io.write(string.format("L2 vs sq-cost(c=x_q^2)  %s  BIG=%g  (physical)\n", NAME, BIG))
io.write(string.format("  %-6s %-8s %-12s %-12s %-12s %-6s %-9s\n", "appr", "state", "import", "dump", "recipe", "n_imp", "top_share"))
local function row(n, st, p, x) local i, d, r, ni, sh = summary(p, x)
    io.write(string.format("  %-6s %-8s %-12.6g %-12.6g %-12.6g %-6d %-9.3f\n", n, st, i, d, r, ni, sh)) end
row("L2", sq2, pq, xq)
row("sq", ss, ps, xs)

-- per-variable file
local rows = {}
for key, p in pairs(pq.primals) do
    local a, b = val(pq, key, xq), val(ps, key, xs)
    if math.abs(a) > 1e-9 or math.abs(b) > 1e-9 then
        rows[#rows + 1] = { kind = p.kind, material = p.material or "", l2 = a, sq = b, key = key,
            mag = math.max(math.abs(a), math.abs(b)) }
    end
end
local ko = { recipe = 1, bridge = 2, shortage_source = 3, surplus_sink = 4, initial_source = 5, final_sink = 6 }
table.sort(rows, function(u, v) local ku, kv = ko[u.kind] or 9, ko[v.kind] or 9
    if ku ~= kv then return ku < kv end; return u.mag > v.mag end)
local f = assert(io.open(OUT, "w"))
f:write(string.format("# %s  BIG=%g  L2=%s sq=%s   sq cost on escapes = x_q^2\n", NAME, BIG, sq2, ss))
f:write("# recipe/bridge=machine count; shortage/initial=+import; surplus/final=-dump (physical)\n")
f:write("kind\tmaterial\tL2\tsq\tkey\n")
for _, r in ipairs(rows) do f:write(string.format("%s\t%s\t%.6g\t%.6g\t%s\n", r.kind, r.material, r.l2, r.sq, r.key)) end
f:close()
io.write(string.format("wrote %d rows -> %s\n", #rows, OUT))
