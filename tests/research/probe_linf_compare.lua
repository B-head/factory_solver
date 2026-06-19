---@diagnostic disable: undefined-global
-- L1 / L2 / rec / Linf raw comparison, NO reference metric. Just factory quantities
-- (physical): total import, total dump, recipe activity, count of active imports,
-- largest-single-import share (concentration), and the violation peak (max escape).
--   lp    = L1   (min sum of violations, linear)
--   qp    = L2   (min sum of squares, quadratic)
--   rec   = reciprocal amount-bake (a=1/x_q on active; heavy cost on large)
--   linf  = Linf (min the MAX violation): aux var t, escape_k <= t for all escapes,
--           minimize t (only t carries cost; a tiny eps on escapes picks the
--           min-total point on the otherwise-degenerate Linf face).
--
--   lua tests/research/probe_linf_compare.lua [dump] [BIG]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e3
local QUAD0, FLOOR, RECTHR, LINF_EPS = 2, 1e-9, 1e-2, 1e-4
local VIO = { shortage_source = true, surplus_sink = true }
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
-- L1: linear cost 1 on violations
local function build_l1()
    local problem = create_problem.create_problem("l1", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = 1 elseif FREEK[p.kind] then p.cost = 0 end
    end
    striptargets(problem); reindex(problem); return problem
end
-- quad (L2) build with optional escape amount scaling
local function build_quad(scale_fn)
    local problem = create_problem.create_problem("q", prob.constraints, prob.normalized_lines, nil,
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
    striptargets(problem); reindex(problem); return problem
end
-- Linf: minimize the max violation via aux var t and escape_k <= t
local function build_linf()
    local problem = create_problem.create_problem("linf", prob.constraints, prob.normalized_lines, nil, nil)
    for _, p in pairs(problem.primals) do p.cost = 0 end -- zero ALL costs (recipe cost ruins min-t)
    striptargets(problem)
    local TKEY = "|linf|t"
    problem:add_objective(TKEY, 1, false, "linf_t", nil)
    local i = 0
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then
            p.cost = LINF_EPS -- tiny: pick the min-total point on the Linf face
            i = i + 1
            local dk = "|linf_cap|" .. i
            problem:add_upper_limit_constraint(dk, 0)        -- escape_k - t <= 0
            problem:add_subject_term(key, dk, 1)
            problem:add_subject_term(TKEY, dk, -1)
        end
    end
    reindex(problem)
    return problem, TKEY
end

-- physical balance flow of an escape; recipe -> value
local function phys(problem, key, x)
    local p = problem.primals[key]
    if not p then return 0 end
    if VIO[p.kind] then
        local t = problem.subject_terms[key]
        local c = (p.material and t and t[p.material]) or 1
        return c * (x[key] or 0)
    end
    return x[key] or 0
end
local function summary(problem, x)
    local imp, dmp, rec, nimp, maximp, peak = 0, 0, 0, 0, 0, 0
    for key, p in pairs(problem.primals) do
        if p.kind == "shortage_source" then
            local v = math.abs(phys(problem, key, x)); imp = imp + v
            if v > 1e-6 then nimp = nimp + 1 end; if v > maximp then maximp = v end
            if v > peak then peak = v end
        elseif p.kind == "surplus_sink" then
            local v = math.abs(phys(problem, key, x)); dmp = dmp + v; if v > peak then peak = v end
        elseif p.kind == "recipe" then
            rec = rec + math.abs(x[key] or 0)
        end
    end
    return imp, dmp, rec, nimp, (imp > 0 and maximp / imp or 0), peak
end

local pq = build_quad(nil); local xq, sq = solve(pq)
local maxxq = 0
for key, p in pairs(pq.primals) do if VIO[p.kind] then local v = math.abs(xq[key] or 0); if v > maxxq then maxxq = v end end end
local thr = maxxq * RECTHR
local plp = build_l1(); local xlp, slp = solve(plp)
local pr = build_quad(function(key) local s = math.abs(xq[key] or 0); if s > thr then return 1 / s else return 1 end end)
local xr, sr = solve(pr)
local pli = build_linf(); local xli, sli = solve(pli)

io.write(string.format("L1/L2/rec/Linf  %s  BIG=%g  (physical, no reference)\n", PATH:match("[^/]+$"), BIG))
io.write(string.format("  %-6s %-8s %-12s %-12s %-12s %-6s %-9s %-10s\n",
    "appr", "state", "import", "dump", "recipe", "n_imp", "top_share", "peak(max viol)"))
local function row(name, st, problem, x)
    local imp, dmp, rec, nimp, share, peak = summary(problem, x)
    io.write(string.format("  %-6s %-8s %-12.6g %-12.6g %-12.6g %-6d %-9.3f %-10.6g\n",
        name, st, imp, dmp, rec, nimp, share, peak))
end
row("L1", slp, plp, xlp)
row("L2", sq, pq, xq)
row("rec", sr, pr, xr)
row("Linf", sli, pli, xli)
