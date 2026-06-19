---@diagnostic disable: undefined-global
-- Raw solution comparison of qp / amt / rec, NO reference metric. Just the actual
-- factory quantities (physical, ref-independent): total physical import, total
-- physical dump, total recipe activity, count of active imports, and the largest
-- single import's share (concentration). The question: does rec (heavy cost on the
-- large violations) balance / shift to fabrication, or does it blow the totals up?
--
--   lua tests/research/probe_recip_raw.lua [dump] [BIG]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e3
local QUAD0, FLOOR, RECTHR = 2, 1e-9, 1e-2
local VIO = { shortage_source = true, surplus_sink = true }
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
-- physical balance flow of an escape = balance coeff * value
local function phys(problem, key, x)
    local p = problem.primals[key]
    local t = problem.subject_terms[key]
    local c = (p.material and t and t[p.material]) or 1
    return math.abs(c * (x[key] or 0))
end
local function summary(problem, x)
    local imp, dmp, rec, nimp, maximp = 0, 0, 0, 0, 0
    for key, p in pairs(problem.primals) do
        if p.kind == "shortage_source" then
            local v = phys(problem, key, x)
            imp = imp + v; if v > 1e-6 then nimp = nimp + 1 end; if v > maximp then maximp = v end
        elseif p.kind == "surplus_sink" then
            dmp = dmp + phys(problem, key, x)
        elseif p.kind == "recipe" then
            rec = rec + math.abs(x[key] or 0)
        end
    end
    return imp, dmp, rec, nimp, (imp > 0 and maximp / imp or 0)
end

local pq = build(nil); local xq, sq = solve(pq)
local maxxq = 0
for key, p in pairs(pq.primals) do if VIO[p.kind] then local v = math.abs(xq[key] or 0); if v > maxxq then maxxq = v end end end
local thr = maxxq * RECTHR

local pa = build(function(key) local s = math.abs(xq[key] or 0); return s < FLOOR and FLOOR or s end)
local xa, sa = solve(pa)
local pr = build(function(key) local s = math.abs(xq[key] or 0); if s > thr then return 1 / s else return 1 end end)
local xr, sr = solve(pr)

io.write(string.format("RAW solution totals  %s  BIG=%g  (physical, no reference)\n", PATH:match("[^/]+$"), BIG))
io.write(string.format("  %-5s %-8s %-13s %-13s %-13s %-7s %-8s\n",
    "appr", "state", "import_phys", "dump_phys", "recipe_mass", "n_imp", "top_share"))
local function row(name, st, problem, x)
    local imp, dmp, rec, nimp, share = summary(problem, x)
    io.write(string.format("  %-5s %-8s %-13.6g %-13.6g %-13.6g %-7d %-8.3f\n", name, st, imp, dmp, rec, nimp, share))
end
row("qp", sq, pq, xq)
row("amt", sa, pa, xa)
row("rec", sr, pr, xr)
