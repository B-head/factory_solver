---@diagnostic disable: undefined-global
-- Just DUMP amt's actual solution for one problem, next to qp's, in physical terms.
-- No metric, no labels. recipes / shortage_source(import) / surplus_sink(dump) /
-- initial_source / final_sink, every active entry, qp value vs amt physical value.
--
--   lua tests/research/probe_amount_dump.lua [dump] [BIG]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e3
local QUAD0, FLOOR = 2, 1e-9
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
local function build_qp()
    local problem = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil,
        { recipe_epsilon = (2 ^ -6) * BIG / 1e6 })
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = 0; problem:set_quad(key, QUAD0)
        elseif FREEK[p.kind] then p.cost = 0; problem:set_quad(key, 0) end
    end
    strip(problem); return problem
end
local function build_amt(xq)
    local problem = create_problem.create_problem("amt", prob.constraints, prob.normalized_lines, nil,
        { recipe_epsilon = (2 ^ -6) * BIG / 1e6 })
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then
            p.cost = 0; problem:set_quad(key, QUAD0)
            local s = math.max(0, xq[key] or 0); if s < FLOOR then s = FLOOR end
            local terms = problem.subject_terms[key]
            if terms then for dual, coeff in pairs(terms) do terms[dual] = coeff * s end end
        elseif FREEK[p.kind] then p.cost = 0; problem:set_quad(key, 0) end
    end
    strip(problem); return problem
end

local pq = build_qp(); local xq = solve(pq)
local pa = build_amt(xq); local xa, sa = solve(pa)

-- physical value of a key under a problem (escape: coeff*value; else value)
local function phys(problem, key, x)
    local p = problem.primals[key]
    if VIO[p.kind] then
        local t = problem.subject_terms[key]
        local c = (p.material and t and t[p.material]) or 1
        return c * (x[key] or 0)
    end
    return x[key] or 0
end

io.write(string.format("DUMP %s  BIG=%g  amt_state=%s\n", PATH:match("[^/]+$"), BIG, sa))

local function section(title, kind)
    local rows = {}
    for key, p in pairs(pq.primals) do
        if p.kind == kind then
            local q = phys(pq, key, xq)
            local a = pa.primals[key] and phys(pa, key, xa) or 0
            local xav = (VIO[kind] and pa.primals[key]) and (xa[key] or 0) or nil
            if math.abs(q) > 1e-6 or math.abs(a) > 1e-6 then
                rows[#rows + 1] = { k = key, q = q, a = a, xav = xav, mat = p.material }
            end
        end
    end
    table.sort(rows, function(u, v) return math.abs(u.a) > math.abs(v.a) end)
    io.write(string.format("\n== %s (%d active) ==\n", title, #rows))
    if VIO[kind] then
        io.write(string.format("   %-14s %-14s %-10s  %s\n", "qp_phys", "amt_phys", "amt_xvar", "key"))
        for _, r in ipairs(rows) do
            io.write(string.format("   %-14.6g %-14.6g %-10.4g  %s\n", r.q, r.a, r.xav or 0, r.k))
        end
    else
        io.write(string.format("   %-14s %-14s  %s\n", "qp", "amt", "key"))
        for _, r in ipairs(rows) do
            io.write(string.format("   %-14.6g %-14.6g  %s\n", r.q, r.a, r.k))
        end
    end
end

section("RECIPES", "recipe")
section("IMPORT  shortage_source", "shortage_source")
section("DUMP    surplus_sink", "surplus_sink")
section("initial_source", "initial_source")
section("final_sink", "final_sink")
