---@diagnostic disable: undefined-global
-- Iterate the amount-bake (affine-scaling / IRLS-by-the-constraint): solve QP,
-- bake a_k <- a_k * x_k, re-solve, repeat. Track per iteration the reference-yardstick
-- axes Nv (escape count) and defeat fraction f = Vp/(Vp+Vf+Vc), plus the convergence
-- gauge max|x-1| over active escapes (->0 at the fixpoint). The question: does f trend
-- toward ref (down) or toward the sparse cheat vertex (up)?
--
--   lua tests/research/probe_amount_iterate.lua <dump> [iters]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local ref = require "tests/research/reference_solver"
local refcache = require "tests/research/reference_cache"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local ITERS = tonumber(arg[2]) or 8
local BIG, QUAD0, FLOOR = 1e3, 2, 1e-9
local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }
local function setlist(s) local t = {} for k in pairs(s) do t[#t + 1] = k end table.sort(t) return t end
local function listset(l) local s = {} for _, k in ipairs(l or {}) do s[k] = true end return s end

local prob = assert(problem_dump.load_problem(PATH))
local intermediates = ref.intermediates(prob.normalized_lines)
local entry = refcache.load(PATH)
if not entry then
    local r = ref.solve_reference(prob.constraints, prob.normalized_lines)
    local Nv = (r.state == "finished" and r.x) and ref.violation_count(r.problem, r.x, intermediates) or -1
    entry = { state = r.state, Vp = r.Vp, Vc = r.Vc, Vf = r.Vf, Nv = Nv,
        producible = setlist(r.producible), consumable = setlist(r.consumable) }
    refcache.store(PATH, entry)
end
local producible, consumable = listset(entry.producible), listset(entry.consumable)

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
-- build with a per-escape amount scale (relative to native coeff); QUAD0 quad.
local function build(scale)
    local problem = create_problem.create_problem("it", prob.constraints, prob.normalized_lines, nil,
        { recipe_epsilon = (2 ^ -6) * BIG / 1e6 })
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then
            p.cost = 0; problem:set_quad(key, QUAD0)
            local s = scale[key] or 1; if s < FLOOR then s = FLOOR end
            local terms = problem.subject_terms[key]
            if terms then for dual, coeff in pairs(terms) do terms[dual] = coeff * s end end
        elseif FREEK[p.kind] then p.cost = 0; problem:set_quad(key, 0) end
    end
    strip(problem)
    return problem
end
-- grade in physical space: physical p = (scaled coeff) * value; measure on that.
local function grade(problem, x)
    local xphys = {}
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then
            local terms = problem.subject_terms[key]
            local coeff = (p.material and terms and terms[p.material]) or 1
            xphys[key] = math.abs(coeff) * math.abs(x[key] or 0)
        else xphys[key] = x[key] or 0 end
    end
    local Nv = ref.violation_count(problem, xphys, intermediates)
    local Vp, Vc, Vf = ref.violation_split(problem, xphys, intermediates, producible, consumable)
    local d = Vp + Vc + Vf
    return Nv, (d > 0 and Vp / d or 0), Vp, Vc, Vf
end
-- convergence gauge: how far active escape variable values are from 1.
local function maxdev1(problem, x)
    local md = 0
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then
            local v = math.abs(x[key] or 0)
            if v > 1e-3 then local d = math.abs(v - 1); if d > md then md = d end end
        end
    end
    return md
end

io.write(string.format("== amount-bake ITERATION  %s  (ref: Nv=%s f=%.3f) ==\n",
    PATH:match("[^/]+$"), tostring(entry.Nv),
    (function() local d = entry.Vp + entry.Vc + entry.Vf return d > 0 and entry.Vp / d or 0 end)()))
io.write(string.format("  %-4s %-7s %-8s %-7s %-11s %s\n", "it", "state", "Nv", "f", "max|x-1|", "Vp/Vc/Vf"))

-- iter 0: plain QP (scale = 1)
local scale = {}
local prob0 = build(scale)
local x, st = solve(prob0)
local Nv, f, vp, vc, vf = grade(prob0, x)
io.write(string.format("  %-4d %-7s %-8d %-7.3f %-11.4g %.4g/%.4g/%.4g\n", 0, st, Nv, f, maxdev1(prob0, x), vp, vc, vf))

for it = 1, ITERS do
    -- accumulate the affine scale: a_new = a_old * x  (so the new variable is 1 at the previous physical point)
    for key, p in pairs(prob0.primals) do
        if VIO[p.kind] then scale[key] = (scale[key] or 1) * math.max(0, x[key] or 0) end
    end
    local pi = build(scale)
    x, st = solve(pi)
    Nv, f, vp, vc, vf = grade(pi, x)
    io.write(string.format("  %-4d %-7s %-8d %-7.3f %-11.4g %.4g/%.4g/%.4g\n", it, st, Nv, f, maxdev1(pi, x), vp, vc, vf))
    prob0 = pi
end
