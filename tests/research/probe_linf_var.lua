---@diagnostic disable: undefined-global
-- Per-variable solutions of L1 / L2 / rec / Linf written to a TSV. One row per
-- variable active in any approach. Values are the actual factory quantity:
--   recipe / bridge  -> machine count
--   shortage/initial -> physical import flow (+)
--   surplus/final    -> physical dump flow   (-)
-- (escape values are physical = balance coeff * value, so rec's amount-scaling is
-- folded back in and all columns are directly comparable). The Linf aux var t and
-- its cap slacks are excluded (solver artifacts, not factory variables).
--
--   lua tests/research/probe_linf_var.lua [dump] [BIG] [outfile]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e3
local NAME = PATH:match("([^/\\]+)%.lua$") or "dump"
local OUT = arg[3] or ("S:/tmp/var_solutions_" .. NAME .. ".tsv")
local QUAD0, RECTHR, LINF_EPS = 2, 1e-2, 1e-4
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
local function build_l1()
    local problem = create_problem.create_problem("l1", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = 1 elseif FREEK[p.kind] then p.cost = 0 end
    end
    striptargets(problem); reindex(problem); return problem
end
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
local TKEY = "|linf|t"
local RECIPE_EPS = (2 ^ -6) * BIG / 1e6
-- L∞ caps: escape_k - t <= 0 for every violation escape. tcost = cost on t,
-- esc_cost = cost on the elastic escapes, recipe_cost = cost on recipe/bridge,
-- tcap = optional hard cap on t (<=tcap).
local function build_linf(tcost, esc_cost, recipe_cost, tcap)
    local problem = create_problem.create_problem("linf", prob.constraints, prob.normalized_lines, nil, nil)
    for _, p in pairs(problem.primals) do p.cost = 0 end
    striptargets(problem)
    problem:add_objective(TKEY, tcost, false, "linf_t", nil)
    local i = 0
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then
            p.cost = esc_cost; i = i + 1
            local dk = "|linf_cap|" .. i
            problem:add_upper_limit_constraint(dk, 0)
            problem:add_subject_term(key, dk, 1)
            problem:add_subject_term(TKEY, dk, -1)
        elseif (p.kind == "recipe" or p.kind == "bridge") and recipe_cost ~= 0 then
            p.cost = recipe_cost
        end
    end
    if tcap then
        problem:add_upper_limit_constraint("|linf|tcap", tcap)
        problem:add_subject_term(TKEY, "|linf|tcap", 1)
    end
    reindex(problem); return problem
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

local pq = build_quad(nil); local xq, sq = solve(pq)
local maxxq = 0
for key, p in pairs(pq.primals) do if VIO[p.kind] then local v = math.abs(xq[key] or 0); if v > maxxq then maxxq = v end end end
local thr = maxxq * RECTHR
local plp = build_l1(); local xlp, slp = solve(plp)
local pr = build_quad(function(key) local s = math.abs(xq[key] or 0); if s > thr then return 1 / s else return 1 end end)
local xr, sr = solve(pr)
-- L∞ stage A: min t (peak), escapes get a tiny picker, recipes free -> t* (the
-- peak is well-defined; recipe/sub-peak distribution is degenerate here, unused).
local pliA = build_linf(1, LINF_EPS, 0, nil); local xliA, sliA = solve(pliA)
local tstar = 0
for key, p in pairs(pliA.primals) do
    if VIO[p.kind] then local v = math.abs(val(pliA, key, xliA)); if v > tstar then tstar = v end end
end
-- L∞ stage B: cap t <= t*, then minimize TOTAL violation (elastic cost 1) with
-- recipe at recipe_epsilon (futile-cycle pin / machine tie-break). So the faithful
-- L∞ point is: min peak, then min total violation, then min machines.
local pli = build_linf(0, 1, RECIPE_EPS, tstar * (1 + 1e-6)); local xli, sli = solve(pli)
sli = sliA == "finished" and sli or sliA

-- iterate over the common variable set (the L2 problem's primals)
local rows = {}
for key, p in pairs(pq.primals) do
    local l1, l2, rc, li = val(plp, key, xlp), val(pq, key, xq), val(pr, key, xr), val(pli, key, xli)
    if math.max(math.abs(l1), math.abs(l2), math.abs(rc), math.abs(li)) > 1e-9 then
        rows[#rows + 1] = { kind = p.kind, material = p.material or "", l1 = l1, l2 = l2, rec = rc, linf = li,
            key = key, mag = math.max(math.abs(l1), math.abs(l2), math.abs(rc), math.abs(li)) }
    end
end
local kind_order = { recipe = 1, bridge = 2, shortage_source = 3, surplus_sink = 4, initial_source = 5, final_sink = 6 }
table.sort(rows, function(u, v)
    local ku, kv = kind_order[u.kind] or 9, kind_order[v.kind] or 9
    if ku ~= kv then return ku < kv end
    return u.mag > v.mag
end)

local f = assert(io.open(OUT, "w"))
f:write(string.format("# %s  BIG=%g  states: L1=%s L2=%s rec=%s Linf=%s\n", NAME, BIG, slp, sq, sr, sli))
f:write("# recipe/bridge = machine count; shortage/initial = +import flow; surplus/final = -dump flow (physical)\n")
f:write("kind\tmaterial\tL1\tL2\trec\tLinf\tkey\n")
for _, row in ipairs(rows) do
    f:write(string.format("%s\t%s\t%.6g\t%.6g\t%.6g\t%.6g\t%s\n",
        row.kind, row.material, row.l1, row.l2, row.rec, row.linf, row.key))
end
f:close()
io.write(string.format("wrote %d rows -> %s  (L1=%s L2=%s rec=%s Linf=%s)\n", #rows, OUT, slp, sq, sr, sli))
