---@diagnostic disable: undefined-global
-- Per-variable solutions of L1 / L2 / sq / Linf for ONE problem, written to a TSV,
-- plus a one-line raw-totals summary to stdout. For checking whether the sq-cost
-- advantage over L1 holds across problem families or is cycle-specific. All four
-- pin recipes at recipe_epsilon (so the recipe columns are comparable). No metric.
--   L1   = linear cost 1 on escapes
--   L2   = quad 2 on escapes (least-norm)
--   sq   = linear cost max(x_q^2, SQ_FLOOR) on escapes
--   Linf = min peak -> (cap) min total violation -> min machines  (faithful, 2-stage)
--
--   lua tests/research/probe_family_compare.lua <dump> [BIG] [outfile]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e3
local NAME = PATH:match("([^/\\]+)%.lua$") or "dump"
local OUT = arg[3] or ("S:/tmp/var_family_" .. NAME .. ".tsv")
local QUAD0 = 2
local RECIPE_EPS = (2 ^ -6) * BIG / 1e6
local SQ_FLOOR = tonumber(os.getenv("FS_SQ_FLOOR")) or 1e-2
local LINF_EPS = 1e-4
local TKEY = "|linf|t"
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
local function new(mode) return create_problem.create_problem(mode, prob.constraints, prob.normalized_lines, nil,
        { recipe_epsilon = RECIPE_EPS }) end
local function build_l1()
    local p = new("l1"); for k, pr in pairs(p.primals) do
        if VIO[pr.kind] then pr.cost = 1 elseif FREEK[pr.kind] then pr.cost = 0 end end
    striptargets(p); reindex(p); return p
end
local function build_l2()
    local p = new("l2"); for k, pr in pairs(p.primals) do
        if VIO[pr.kind] then pr.cost = 0; p:set_quad(k, QUAD0) elseif FREEK[pr.kind] then pr.cost = 0; p:set_quad(k, 0) end end
    striptargets(p); reindex(p); return p
end
local function build_sq(xq)
    local p = new("sq"); for k, pr in pairs(p.primals) do
        if VIO[pr.kind] then local s = math.abs(xq[k] or 0); pr.cost = math.max(s * s, SQ_FLOOR)
        elseif FREEK[pr.kind] then pr.cost = 0 end end
    striptargets(p); reindex(p); return p
end
local function build_linf(tcost, esc_cost, recipe_cost, tcap)
    local p = create_problem.create_problem("linf", prob.constraints, prob.normalized_lines, nil, nil)
    for _, pr in pairs(p.primals) do pr.cost = 0 end
    striptargets(p)
    p:add_objective(TKEY, tcost, false, "linf_t", nil)
    local i = 0
    for k, pr in pairs(p.primals) do
        if VIO[pr.kind] then pr.cost = esc_cost; i = i + 1
            local dk = "|linf_cap|" .. i
            p:add_upper_limit_constraint(dk, 0); p:add_subject_term(k, dk, 1); p:add_subject_term(TKEY, dk, -1)
        elseif (pr.kind == "recipe" or pr.kind == "bridge") and recipe_cost ~= 0 then pr.cost = recipe_cost end
    end
    if tcap then p:add_upper_limit_constraint("|linf|tcap", tcap); p:add_subject_term(TKEY, "|linf|tcap", 1) end
    reindex(p); return p
end
local function val(problem, key, x)
    local p = problem.primals[key]; if not p then return 0 end
    if ESC[p.kind] then local t = problem.subject_terms[key]
        local c = (p.material and t and t[p.material]) or 1; return c * (x[key] or 0) end
    return x[key] or 0
end
local function totals(problem, x)
    local imp, dmp, rec, nrec = 0, 0, 0, 0
    for key, p in pairs(problem.primals) do
        if p.kind == "shortage_source" then imp = imp + math.abs(val(problem, key, x))
        elseif p.kind == "surplus_sink" then dmp = dmp + math.abs(val(problem, key, x))
        elseif p.kind == "recipe" then local v = math.abs(x[key] or 0); rec = rec + v; if v > 1e-6 then nrec = nrec + 1 end end
    end
    return imp, dmp, rec, nrec
end

local pl1 = build_l1(); local x1, s1 = solve(pl1)
local pq = build_l2(); local xq, s2 = solve(pq)
local ps = build_sq(xq); local xs, ss = solve(ps)
-- faithful Linf: stage A peak, stage B cap + min total violation + min machines
local pA = build_linf(1, LINF_EPS, 0, nil); local xA, sA = solve(pA)
local tstar = 0
for k, p in pairs(pA.primals) do if VIO[p.kind] then local v = math.abs(val(pA, k, xA)); if v > tstar then tstar = v end end end
local pli = build_linf(0, 1, RECIPE_EPS, tstar * (1 + 1e-6)); local xli, sli = solve(pli)
sli = (sA == "finished") and sli or sA

local function tline(n, st, p, x) local i, d, r, nr = totals(p, x)
    io.write(string.format("  %-5s %-9s import=%-10.5g dump=%-10.5g recipe=%-10.5g nrec=%d\n", n, st, i, d, r, nr)) end
io.write(string.format("%s  BIG=%g  (physical; recipes pinned at recipe_epsilon)\n", NAME, BIG))
tline("L1", s1, pl1, x1); tline("L2", s2, pq, xq); tline("sq", ss, ps, xs); tline("Linf", sli, pli, xli)

local rows = {}
for key, p in pairs(pq.primals) do
    local a, b, c, d = val(pl1, key, x1), val(pq, key, xq), val(ps, key, xs), val(pli, key, xli)
    if math.max(math.abs(a), math.abs(b), math.abs(c), math.abs(d)) > 1e-9 then
        rows[#rows + 1] = { kind = p.kind, material = p.material or "", l1 = a, l2 = b, sq = c, linf = d,
            key = key, mag = math.max(math.abs(a), math.abs(b), math.abs(c), math.abs(d)) }
    end
end
local ko = { recipe = 1, bridge = 2, shortage_source = 3, surplus_sink = 4, initial_source = 5, final_sink = 6 }
table.sort(rows, function(u, v) local ku, kv = ko[u.kind] or 9, ko[v.kind] or 9
    if ku ~= kv then return ku < kv end; return u.mag > v.mag end)
local f = assert(io.open(OUT, "w"))
f:write(string.format("# %s  BIG=%g  L1=%s L2=%s sq=%s(floor %.3g) Linf=%s\n", NAME, BIG, s1, s2, ss, SQ_FLOOR, sli))
f:write("# recipe/bridge=machine count; shortage/initial=+import; surplus/final=-dump (physical)\n")
f:write("kind\tmaterial\tL1\tL2\tsq\tLinf\tkey\n")
for _, r in ipairs(rows) do
    f:write(string.format("%s\t%s\t%.6g\t%.6g\t%.6g\t%.6g\t%s\n", r.kind, r.material, r.l1, r.l2, r.sq, r.linf, r.key))
end
f:close()
io.write(string.format("  wrote %d rows -> %s\n", #rows, OUT))
