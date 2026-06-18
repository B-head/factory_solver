---@diagnostic disable: undefined-global
-- SINGLE-SHOT: lightweight FIXPOINT-FREE cascade -- the reference's budget-locked
-- staging without the expensive producible/consumable greatest fixpoints. The
-- staging (each stage's optimum locked as a budget for the next) is what stops the
-- cheat drift the flat IRL1 penalty suffered; dropping the fixpoint just means we
-- LUMP the import tiers (minimize total imports instead of Vp then Vf -- the
-- structurally forced makeup stays at its floor, the avoidable defeat goes to 0
-- on its own) and approximate dumps as surplus_sink only.
--   stage 1  minimize target violation (is_target)            -> lock T budget
--   stage 2  minimize all imports (shortage + initial-into-intermediate) -> lock
--   stage 3  minimize all dumps (surplus_sink)                -> lock
--   stage 4  minimize machines (recipes)                      -> final
-- Reuses the reference's build_stage shape (M.OPTS, EPS_RECIPE, budget margin) so
-- TARGET handling matches the reference exactly (fixes the nil-amount artifacts).
-- 4 LP solves, no fixpoint, measured against the cached reference.
--
--   lua tests/research/lightweight_cascade.lua <dump>

local NAME = (arg[1] or "?"):match("[^/\\]+$") or "?"
local EPS_RECIPE = 2 ^ -20
local function setlist(s) local t = {} for k in pairs(s) do t[#t + 1] = k end table.sort(t) return t end
local function listset(l) local s = {} for _, k in ipairs(l or {}) do s[k] = true end return s end

local ok, line = pcall(function()
    require "tests/headless_env"
    local create_problem = require "solver/create_problem"
    local problem_dump = require "tests/problem_dump"
    local ref = require "tests/research/reference_solver"
    local refcache = require "tests/research/reference_cache"
    local lp = require "solver/linear_programming"
    local harness = require "tests/harness"
    local prob = assert(problem_dump.load_problem(arg[1]))
    local intermediates = ref.intermediates(prob.normalized_lines)

    -- cached reference (yardstick + producible/consumable for the split)
    local entry = refcache.load(arg[1])
    if not entry then
        local r = ref.solve_reference(prob.constraints, prob.normalized_lines)
        local Nv = (r.state == "finished" and r.x) and ref.violation_count(r.problem, r.x, intermediates) or -1
        entry = { state = r.state, n_mats = r.n_mats, T = r.T, Vp = r.Vp, Vc = r.Vc, Vf = r.Vf, M = r.M,
            S = r.S, Nv = Nv, steps = r.steps, producible = setlist(r.producible), consumable = setlist(r.consumable) }
        refcache.store(arg[1], entry)
    end
    local producible, consumable = listset(entry.producible), listset(entry.consumable)

    local TOL, ITER = 1e-7, 800
    local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
    local function budget(opt) return opt * (1 + ref.BUDGET_REL) + ref.BUDGET_ABS end

    local function build_stage(unit_fn, budgets)
        local problem = create_problem.create_problem("lwc", prob.constraints, prob.normalized_lines, nil, ref.OPTS)
        for _, p in pairs(problem.primals) do
            if unit_fn(p) then p.cost = 1
            elseif p.kind == "recipe" or p.kind == "bridge" then p.cost = EPS_RECIPE
            else p.cost = 0 end
        end
        for i, b in ipairs(budgets or {}) do
            local dual = "|lwc_budget|" .. i
            problem:add_upper_limit_constraint(dual, b.limit)
            for key, p in pairs(problem.primals) do if b.fn(p) then problem:add_subject_term(key, dual, 1) end end
        end
        return problem
    end
    local function sum_if(problem, x, fn)
        local s = 0 for key, p in pairs(problem.primals) do if fn(p) then s = s + math.abs(x[key] or 0) end end return s
    end

    -- fixpoint-free stage selectors
    local is_target = function(p) return p.kind == "elastic" or p.kind == "headroom" end
    local is_import = function(p) return p.kind == "shortage_source"
        or (p.kind == "initial_source" and p.material and intermediates[p.material]) end
    local is_dump = function(p) return p.kind == "surplus_sink" end
    local is_machine = function(p) return p.kind == "recipe" end

    local solves, budgets, state = 0, {}, "finished"
    local function stage(unit_fn, name)
        local p = build_stage(unit_fn, budgets); local s, v = solve(p); solves = solves + 1
        if s ~= "finished" or not v then state = name .. "-" .. s; return nil, nil end
        return p, v.x
    end

    local p1, x1 = stage(is_target, "s1"); if not p1 then error(state) end
    budgets[#budgets + 1] = { fn = is_target, limit = budget(sum_if(p1, x1, is_target)) }
    local p2, x2 = stage(is_import, "s2"); if not p2 then error(state) end
    budgets[#budgets + 1] = { fn = is_import, limit = budget(sum_if(p2, x2, is_import)) }
    local p3, x3 = stage(is_dump, "s3"); if not p3 then error(state) end
    budgets[#budgets + 1] = { fn = is_dump, limit = budget(sum_if(p3, x3, is_dump)) }
    local p4, x4 = stage(is_machine, "s4"); if not p4 then error(state) end

    local function disp_esc(pp, xx)
        local s, s2 = 0, 0
        for k, p in pairs(pp.primals) do if p.kind == "shortage_source" or p.kind == "surplus_sink" then
            local v = math.abs(xx[k] or 0); s = s + v; s2 = s2 + v * v end end
        return (s2 > 0) and (s * s / s2) or 0
    end
    local Nv = ref.violation_count(p4, x4, intermediates)
    local Vp, Vc, Vf = ref.violation_split(p4, x4, intermediates, producible, consumable)
    local Mm = ref.total_of(p4, x4, ref.MACHINE_KINDS)

    return string.format(
        "RESULT\tname=%s\tref_state=%s\tlw_state=finished\tsolves=%d"
        .. "\tNv_ref=%s\tVp_ref=%.6g\tVc_ref=%.6g\tVf_ref=%.6g\tM_ref=%.6g\tref_steps=%s"
        .. "\tNv_lw=%d\tVp_lw=%.6g\tVc_lw=%.6g\tVf_lw=%.6g\tM_lw=%.6g\tPResc_lw=%.4g",
        NAME, entry.state, solves,
        tostring(entry.Nv), entry.Vp, entry.Vc, entry.Vf, entry.M, tostring(entry.steps),
        Nv, Vp, Vc, Vf, Mm, disp_esc(p4, x4))
end)

io.write((ok and line or string.format("RESULT\tname=%s\tref_state=NA\tlw_state=error\terr=%s",
    NAME, tostring(line):gsub("%s+", " "):sub(1, 100))) .. "\n")
