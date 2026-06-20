---@diagnostic disable: undefined-global
-- The chosen L2 fix: scale-both (raise recipe_eps & quad TOGETHER, argmin-invariant
-- for the recipe/violation balance, so building stays preferred -- no import
-- collapse) PLUS a small linear floor c_v on the violation elastics (the elastic-net
-- L1 admixture that kills the quad's zero-marginal-at-origin dust). Every costable
-- column then has a reduced-cost floor above sqrt(mu), so the existing zero-purify
-- (s > x) fires. Sweep (eps, quad, c_v) and report dust + the answer.
--
--   lua tests/research/probe_l2_full.lua [dump]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local prob = assert(problem_dump.load_problem(PATH))

local function solve(pp, tol)
    local state, it, vars, last, steps = "ready", nil, nil, nil, 0
    repeat
        local ok, s, i2, v = pcall(lp.solve, pp, state, it, vars, tol, prob.meta.iterate_limit)
        if not ok then state = "errored"; break end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
    return last, state, it
end

local function build(recipe_eps, quad, c_v)
    local problem = create_problem.create_problem("l2", prob.constraints, prob.normalized_lines, nil,
        { reachability_gating = false, recipe_epsilon = recipe_eps })
    for key, p in pairs(problem.primals) do
        if p.kind == "shortage_source" or p.kind == "surplus_sink" then
            p.cost = c_v
            problem:set_quad(key, quad)
        elseif p.kind == "initial_source" or p.kind == "final_sink" then
            p.cost = 0
        end
    end
    return problem
end

local function phys(problem, key, x)
    local p = problem.primals[key]
    local t = problem.subject_terms[key]
    local c = (p.material and t and t[p.material]) or 1
    return math.abs(c * (x[key] or 0))
end

-- Count per (kind) the |x| band distribution: exact0 / (0,1e-6) / [1e-6,1e-4) /
-- [1e-4,1e-2) / [1e-2,inf). "reach 0" = exact0 high, mid-bands low.
local function bandof(v)
    if v == 0 then return 1 elseif v < 1e-6 then return 2
    elseif v < 1e-4 then return 3 elseif v < 1e-2 then return 4 else return 5 end
end
local function summarize(label, problem, vars, it, state)
    local x = vars.x
    local rec, imp_b, dmp_b = { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }
    local sviol2, imp, dmp = 0, 0, 0
    for key, p in pairs(problem.primals) do
        local v = math.abs(x[key] or 0)
        local bi = bandof(v)
        if p.kind == "recipe" then
            rec[bi] = rec[bi] + 1
        elseif p.kind == "shortage_source" then
            imp_b[bi] = imp_b[bi] + 1; imp = imp + phys(problem, key, x); sviol2 = sviol2 + v * v
        elseif p.kind == "surplus_sink" then
            dmp_b[bi] = dmp_b[bi] + 1; dmp = dmp + phys(problem, key, x); sviol2 = sviol2 + v * v
        end
    end
    local function b(t) return string.format("[%d|%d|%d|%d|%d]", t[1], t[2], t[3], t[4], t[5]) end
    io.write(string.format("%-32s rec%s imp%s dmp%s  Σviol²=%-10.6g it=%-3s %s\n",
        label, b(rec), b(imp_b), b(dmp_b), sviol2, tostring(it), state))
end

io.write(string.format("L2 FULL FIX  %s  tol=%g\n\n", PATH:match("[^/]+$"), prob.meta.tolerance))

local configs = {
    { "shipped (2^-20, q2, c0)",        2 ^ -20, 2,      0 },
    { "scaleboth k2^10 (e2^-10,q2^11)", 2 ^ -10, 2 ^ 11, 0 },
    { "  + c_v=2^-8",                   2 ^ -10, 2 ^ 11, 2 ^ -8 },
    { "scaleboth k2^14 (e2^-6,q2^15)",  2 ^ -6,  2 ^ 15, 0 },
    { "  + c_v=2^-8",                   2 ^ -6,  2 ^ 15, 2 ^ -8 },
}
for _, c in ipairs(configs) do
    local p = build(c[2], c[3], c[4])
    local v, st, it = solve(p, prob.meta.tolerance)
    if v then summarize(c[1], p, v, it, st) end
end
