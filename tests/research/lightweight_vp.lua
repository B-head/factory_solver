---@diagnostic disable: undefined-global
-- lightweight_cascade + the producible-import (Vp) split, the piece it dropped to
-- be fixpoint-free. The reference's gap-fillers (Asteroid up cycleing, Quality
-- loop -- import-collapse cases) need to know which imports are PRODUCIBLE defeats
-- so the lexicographic Vp >> Vf >> M drives them to fabrication instead of letting
-- machine-minimization collapse the loop. That classification is structural (a
-- greatest fixpoint), but its phase 1 is cheapened by RECURSIVE all-batch
-- (tests/research/producible_fast -- verdict-identical to per-material, ~6.6
-- solves on bundle16 vs ~30 naive).
--
--   probe: classify producible imports (fast)         -> ~2-27 solves
--   stage 1  minimize target violation (is_target)
--   stage 2a minimize PRODUCIBLE imports (Vp = defeat)
--   stage 2b minimize makeup imports (Vf)
--   stage 3  minimize dumps (surplus + final_sink-of-intermediate)
--   stage 4  minimize machines
-- 5 cascade solves + the probe. Measured against the cached reference yardstick.
--   On bundle16 this reaches 16/16 (vs 14/16 for the lump lightweight_cascade).
--
--   lua tests/research/lightweight_vp.lua <dump>

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
    local pf = require "tests/research/producible_fast"
    local lp = require "solver/linear_programming"
    local harness = require "tests/harness"
    local prob = assert(problem_dump.load_problem(arg[1]))
    local intermediates = ref.intermediates(prob.normalized_lines)

    local entry = refcache.load(arg[1])
    if not entry then
        local r = ref.solve_reference(prob.constraints, prob.normalized_lines)
        local Nv = (r.state == "finished" and r.x) and ref.violation_count(r.problem, r.x, intermediates) or -1
        entry = { state = r.state, n_mats = r.n_mats, T = r.T, Vp = r.Vp, Vc = r.Vc, Vf = r.Vf, M = r.M,
            S = r.S, Nv = Nv, steps = r.steps, producible = setlist(r.producible), consumable = setlist(r.consumable) }
        refcache.store(arg[1], entry)
    end
    local producible_ref, consumable_ref = listset(entry.producible), listset(entry.consumable)

    -- the FAST producibility classification (drives the Vp split)
    local producible, probe_solves = pf.producible_set(prob.constraints, prob.normalized_lines)

    local TOL, ITER = 1e-7, 800
    local solves = 0
    local function solve(p) solves = solves + 1; return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
    local function budget(opt) return opt * (1 + ref.BUDGET_REL) + ref.BUDGET_ABS end

    local is_target = function(p) return p.kind == "elastic" or p.kind == "headroom" end
    local is_import = function(p) return p.kind == "shortage_source"
        or (p.kind == "initial_source" and p.material and intermediates[p.material]) end
    local is_vp = function(p) return is_import(p) and p.material and producible[p.material] end
    local is_vf = function(p) return is_import(p) and not (p.material and producible[p.material]) end
    local is_dump = function(p) return p.kind == "surplus_sink"
        or (p.kind == "final_sink" and p.material and intermediates[p.material]) end
    local is_machine = function(p) return p.kind == "recipe" end

    local function build_stage(unit_fn, budgets)
        local problem = create_problem.create_problem("lwv", prob.constraints, prob.normalized_lines, nil, ref.OPTS)
        for _, p in pairs(problem.primals) do
            if unit_fn(p) then p.cost = 1
            elseif p.kind == "recipe" or p.kind == "bridge" then p.cost = EPS_RECIPE
            else p.cost = 0 end
        end
        for i, b in ipairs(budgets or {}) do
            local dual = "|lwv_budget|" .. i
            problem:add_upper_limit_constraint(dual, b.limit)
            for key, p in pairs(problem.primals) do if b.fn(p) then problem:add_subject_term(key, dual, 1) end end
        end
        return problem
    end
    local function sum_if(problem, x, fn)
        local s = 0 for key, p in pairs(problem.primals) do if fn(p) then s = s + math.abs(x[key] or 0) end end return s
    end

    local budgets, state = {}, "finished"
    local function stage(unit_fn, name)
        local p = build_stage(unit_fn, budgets); local s, v = solve(p)
        if s ~= "finished" or not v then state = name .. "-" .. s; return nil, nil end
        return p, v.x
    end
    local p1, x1 = stage(is_target, "s1"); if not p1 then error(state) end
    budgets[#budgets + 1] = { fn = is_target, limit = budget(sum_if(p1, x1, is_target)) }
    local pa, xa = stage(is_vp, "vp"); if not pa then error(state) end
    budgets[#budgets + 1] = { fn = is_vp, limit = budget(sum_if(pa, xa, is_vp)) }
    local pb, xb = stage(is_vf, "vf"); if not pb then error(state) end
    budgets[#budgets + 1] = { fn = is_vf, limit = budget(sum_if(pb, xb, is_vf)) }
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
    local Vp, Vc, Vf = ref.violation_split(p4, x4, intermediates, producible_ref, consumable_ref)
    local Mm = ref.total_of(p4, x4, ref.MACHINE_KINDS)

    return string.format(
        "RESULT\tname=%s\tref_state=%s\tlw_state=finished\tsolves=%d\tprobe_solves=%d\tcascade_solves=%d"
        .. "\tNv_ref=%s\tVp_ref=%.6g\tVc_ref=%.6g\tVf_ref=%.6g\tM_ref=%.6g\tref_steps=%s"
        .. "\tNv_lw=%d\tVp_lw=%.6g\tVc_lw=%.6g\tVf_lw=%.6g\tM_lw=%.6g\tPResc_lw=%.4g",
        NAME, entry.state, probe_solves + solves, probe_solves, solves,
        tostring(entry.Nv), entry.Vp, entry.Vc, entry.Vf, entry.M, tostring(entry.steps),
        Nv, Vp, Vc, Vf, Mm, disp_esc(p4, x4))
end)

io.write((ok and line or string.format("RESULT\tname=%s\tref_state=NA\tlw_state=error\terr=%s",
    NAME, tostring(line):gsub("%s+", " "):sub(1, 100))) .. "\n")
