---@diagnostic disable: undefined-global
-- Drill ONE case: what did the recipe-anchored escape consolidation trade?
-- Solves the QP base (x_q) and the proximal-anchored IRL1 consolidation (x_c) at
-- a single kappa0, then diffs the elastic escapes (which DIED / GREW / are NEW)
-- split into imports (shortage_source) vs dumps (surplus_sink), and lists the
-- recipes that moved the most between r_q and x_c. Use to see whether a consolidation
-- that raised imports is a genuine import-vs-fabricate structural call.
--
--   luajit tests/research/probe_drill_consolidate.lua [dumpfile] [kappa0]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_117_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local KAPPA = tonumber(arg[2]) or 1e2
-- IMPMULT: extra base weight on shortage_source (import) escapes in the IRL1
-- consolidation, so the count-minimizer respects Vp >> Vc (never trade a cheap
-- dump for a dearer import). 1 = priority-blind (the original).
local IMPMULT = tonumber(arg[3]) or 1
local EPS, ITERS, BIG = 1.0, 6, 1e6
local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }

local prob = assert(problem_dump.load_problem(PATH))

local function remove_targets(problem)
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

local function build_qp()
    local problem = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = 0; problem:set_quad(key, 2)
        elseif FREEK[p.kind] then p.cost = 0; problem:set_quad(key, 0) end
    end
    remove_targets(problem); reindex(problem)
    return problem
end
local pq = build_qp()
local xq, stq = solve(pq)

local recipe_keys, vio_keys = {}, {}
for k, p in pairs(pq.primals) do
    if p.kind == "recipe" or p.kind == "bridge" then recipe_keys[#recipe_keys + 1] = k
    elseif VIO[p.kind] then vio_keys[#vio_keys + 1] = k end
end
local rq, kind_of, mat_of = {}, {}, {}
for _, k in ipairs(vio_keys) do kind_of[k] = pq.primals[k].kind; mat_of[k] = pq.primals[k].material end
local maxr = 0
for _, k in ipairs(recipe_keys) do rq[k] = math.abs(xq[k] or 0); if rq[k] > maxr then maxr = rq[k] end end
local THR = math.max(1e-9, maxr * 1e-6)
local RFLOOR = math.max(THR, maxr * 1e-3)

local function build_anchored(weights, kappa0)
    local problem = create_problem.create_problem("anc", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = weights[key] or (1 / EPS)
        elseif FREEK[p.kind] then p.cost = 0 end
    end
    remove_targets(problem); reindex(problem)
    if kappa0 > 0 then
        for _, k in ipairs(recipe_keys) do
            local p = problem.primals[k]
            if p then
                local t = rq[k] or 0
                local kqv = kappa0 / (math.max(t, RFLOOR) ^ 2)
                problem:set_quad(k, kqv); p.cost = -kqv * t
            end
        end
    end
    return problem
end

-- IRL1 to "convergence" at KAPPA
local xprev = xq
local xc
for _ = 1, ITERS do
    local w = {}
    for _, k in ipairs(vio_keys) do
        local base = (kind_of[k] == "shortage_source") and IMPMULT or 1
        w[k] = base / (math.abs(xprev[k] or 0) + EPS)
    end
    local x = solve(build_anchored(w, KAPPA))
    xc = x; xprev = x
end

-- ---- escape diff ----------------------------------------------------------
local function sumkind(x, kind)
    local s = 0 for _, k in ipairs(vio_keys) do if kind_of[k] == kind then s = s + math.abs(x[k] or 0) end end return s
end
io.write(string.format("================ DRILL %s  kappa0=%g ================\n", PATH:match("[^/]+$"), KAPPA))
io.write(string.format("QP   : state=%s  import(short)=%.6g  dump(surplus)=%.6g\n", stq, sumkind(xq, "shortage_source"), sumkind(xq, "surplus_sink")))
io.write(string.format("CONS : import(short)=%.6g  dump(surplus)=%.6g\n\n", sumkind(xc, "shortage_source"), sumkind(xc, "surplus_sink")))

local rows = {}
for _, k in ipairs(vio_keys) do
    local a, b = math.abs(xq[k] or 0), math.abs(xc[k] or 0)
    if a > THR or b > THR then
        local note = (a > THR and b <= THR) and "DIED" or (a <= THR and b > THR) and "NEW"
            or (b > a * 1.01) and "GREW" or (b < a * 0.99) and "shrank" or "same"
        rows[#rows + 1] = { kind = kind_of[k], mat = mat_of[k] or k, a = a, b = b, d = b - a, note = note }
    end
end
table.sort(rows, function(p, q) return math.abs(p.d) > math.abs(q.d) end)
io.write("-- elastic escapes active in QP or CONS, by |delta| --\n")
io.write(string.format("  %-15s %-32s %12s %12s %12s  %s\n", "kind", "material", "x_qp", "x_cons", "delta", "note"))
for _, r in ipairs(rows) do
    io.write(string.format("  %-15s %-32s %12.6g %12.6g %12.6g  %s\n", r.kind, tostring(r.mat):sub(1, 32), r.a, r.b, r.d, r.note))
end

-- ---- recipe movers --------------------------------------------------------
local rrows = {}
for _, k in ipairs(recipe_keys) do
    local a, b = rq[k] or 0, math.abs(xc[k] or 0)
    if math.abs(b - a) > THR * 10 then rrows[#rrows + 1] = { k = k, a = a, b = b, d = b - a } end
end
table.sort(rrows, function(p, q) return math.abs(p.d) > math.abs(q.d) end)
io.write(string.format("\n-- recipes that moved most (|x_cons - r_q| > %.3g), top 15 --\n", THR * 10))
io.write(string.format("  %-46s %12s %12s %12s\n", "recipe", "r_q", "x_cons", "delta"))
for i = 1, math.min(#rrows, 15) do
    local r = rrows[i]
    io.write(string.format("  %-46s %12.6g %12.6g %12.6g\n", r.k:gsub("^recipe/", ""):sub(1, 46), r.a, r.b, r.d))
end
