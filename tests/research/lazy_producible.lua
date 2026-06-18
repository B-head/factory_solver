---@diagnostic disable: undefined-global
-- SINGLE-SHOT: cheap Vp/Vf split WITHOUT the producible greatest-fixpoint.
--
-- The reference's cost is dominated by producible_set / consumable_set: each is
-- ONE LP solve PER MATERIAL (phase-1 individual screen) over ALL shortage-carrying
-- materials -- hundreds of solves x2 = the ~65s. But the staged cascade only ever
-- IMPORTS a handful of materials (Nv ~ 6). So producibility is only needed where
-- the solution actually imports. This drives three variants of the import stage,
-- all measured against the cached reference's FULL producible/consumable yardstick:
--
--   lump : T >> (ALL imports) >> (all surplus dumps) >> machines.  [baseline]
--   A    : T >> (LAZY-producible imports = defeat) >> (rest = makeup)
--          >> dumps >> machines.  producible discovered by running the reference's
--          phase-1 test ONLY on materials the solution imports, iterated until no
--          new producible import surfaces (O(Nv) producibility solves, not O(#mats)).
--   B    : same split but producible = one-hop "has a producing recipe" (a linear
--          scan, no LP). Negative control: too shallow for shortage materials?
--
-- Only the IMPORT stage differs across the three -- target / dump / machine stages
-- are identical -- so A-vs-lump isolates the Vp/Vf split and A-vs-B isolates the
-- lazy-LP test vs the one-hop heuristic.
--
--   lua tests/research/lazy_producible.lua <dump>

local NAME = (arg[1] or "?"):match("[^/\\]+$") or "?"
local EPS_RECIPE = 2 ^ -20
local PROD_TOL = 1e-4   -- reference phase-1 membership threshold
local MAXROUND = 5      -- lazy discovery rounds for A
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
    local tn = require "manage/typed_name"
    local prob = assert(problem_dump.load_problem(arg[1]))
    local intermediates = ref.intermediates(prob.normalized_lines)

    -- cached reference: yardstick (Vp/Vc/Vf/M) + the FULL producible/consumable
    -- sets used to MEASURE every variant honestly (the lazy sets only DRIVE A).
    local entry = refcache.load(arg[1])
    if not entry then
        local r = ref.solve_reference(prob.constraints, prob.normalized_lines)
        local Nv = (r.state == "finished" and r.x) and ref.violation_count(r.problem, r.x, intermediates) or -1
        entry = { state = r.state, n_mats = r.n_mats, T = r.T, Vp = r.Vp, Vc = r.Vc, Vf = r.Vf, M = r.M,
            S = r.S, Nv = Nv, steps = r.steps, producible = setlist(r.producible), consumable = setlist(r.consumable) }
        refcache.store(arg[1], entry)
    end
    local producible_ref, consumable_ref = listset(entry.producible), listset(entry.consumable)

    local TOL, ITER = 1e-7, 800
    local solves = 0
    local function solve(p) solves = solves + 1; return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
    local function budget(opt) return opt * (1 + ref.BUDGET_REL) + ref.BUDGET_ABS end

    -- structural import / dump selectors (fixpoint-free, same as the lump cascade)
    local is_import = function(p) return p.kind == "shortage_source"
        or (p.kind == "initial_source" and p.material and intermediates[p.material]) end
    local is_dump = function(p) return p.kind == "surplus_sink" end
    local is_target = function(p) return p.kind == "elastic" or p.kind == "headroom" end
    local is_machine = function(p) return p.kind == "recipe" end

    -- materials that carry a shortage_source under ref.OPTS == the reference's
    -- producibility test domain; one-hop "produced by some line" for variant B.
    local has_shortage, produced = {}, {}
    do
        local p0 = create_problem.create_problem("scan", prob.constraints, prob.normalized_lines, nil, ref.OPTS)
        for _, p in pairs(p0.primals) do
            if p.kind == "shortage_source" and p.material then has_shortage[p.material] = true end
        end
    end
    for _, ln in ipairs(prob.normalized_lines) do
        for _, prd in ipairs(ln.products) do produced[tn.typed_name_to_variable_name(prd)] = true end
        if ln.fuel_burnt_result then produced[tn.typed_name_to_variable_name(ln.fuel_burnt_result)] = true end
    end

    -- reference phase-1 producibility test for a SINGLE material (price only its
    -- shortage, demand 1 unit, recipes at the face regularizer, all else free).
    local function producible_test(mat)
        local p = create_problem.create_problem("fixtest", prob.constraints, prob.normalized_lines, nil, ref.OPTS)
        for _, pr in pairs(p.primals) do
            if pr.kind == "shortage_source" and pr.material == mat then pr.cost = 1
            elseif pr.kind == "recipe" or pr.kind == "bridge" then pr.cost = EPS_RECIPE
            else pr.cost = 0 end
        end
        local probe = "|lp_probe|" .. mat
        p:add_objective(probe, 0, false, nil, mat)
        p:add_subject_term(probe, mat, -1)
        local dual = "|lp_demand|" .. mat
        p:add_lower_limit_constraint(dual, 1)
        p:add_subject_term(probe, dual, 1)
        local s, v = solve(p)
        if s ~= "finished" or not v then return false end
        local own = 0
        for key, pr in pairs(p.primals) do
            if pr.kind == "shortage_source" and pr.material == mat then own = own + math.abs(v.x[key] or 0) end
        end
        return own <= PROD_TOL
    end

    -- one budget-locked cascade with the import stage split by `defeat_fn`
    -- (a material-name set test). When `defeat_fn` is nil, imports are a single
    -- stage (the lump). Returns the final problem + x + the per-stage budgets.
    local function build_stage(unit_fn, budgets)
        local problem = create_problem.create_problem("lp", prob.constraints, prob.normalized_lines, nil, ref.OPTS)
        for _, p in pairs(problem.primals) do
            if unit_fn(p) then p.cost = 1
            elseif p.kind == "recipe" or p.kind == "bridge" then p.cost = EPS_RECIPE
            else p.cost = 0 end
        end
        for i, b in ipairs(budgets or {}) do
            local dual = "|lp_budget|" .. i
            problem:add_upper_limit_constraint(dual, b.limit)
            for key, p in pairs(problem.primals) do if b.fn(p) then problem:add_subject_term(key, dual, 1) end end
        end
        return problem
    end
    local function sum_if(problem, x, fn)
        local s = 0 for key, p in pairs(problem.primals) do if fn(p) then s = s + math.abs(x[key] or 0) end end return s
    end

    -- run the cascade once for a given producible-material set (empty = lump).
    -- returns final problem, x, ok-flag.
    local function run_cascade(defeat_set)
        local budgets = {}
        local function stage(unit_fn)
            local p = build_stage(unit_fn, budgets); local s, v = solve(p)
            if s ~= "finished" or not v then return nil, nil end
            return p, v.x
        end
        local p1, x1 = stage(is_target); if not p1 then return nil end
        budgets[#budgets + 1] = { fn = is_target, limit = budget(sum_if(p1, x1, is_target)) }
        if defeat_set then
            local is_defeat = function(p) return is_import(p) and p.material and defeat_set[p.material] end
            local is_makeup = function(p) return is_import(p) and not (p.material and defeat_set[p.material]) end
            local p2, x2 = stage(is_defeat); if not p2 then return nil end
            budgets[#budgets + 1] = { fn = is_defeat, limit = budget(sum_if(p2, x2, is_defeat)) }
            local p2b, x2b = stage(is_makeup); if not p2b then return nil end
            budgets[#budgets + 1] = { fn = is_makeup, limit = budget(sum_if(p2b, x2b, is_makeup)) }
        else
            local p2, x2 = stage(is_import); if not p2 then return nil end
            budgets[#budgets + 1] = { fn = is_import, limit = budget(sum_if(p2, x2, is_import)) }
        end
        local p3, x3 = stage(is_dump); if not p3 then return nil end
        budgets[#budgets + 1] = { fn = is_dump, limit = budget(sum_if(p3, x3, is_dump)) }
        local p4, x4 = stage(is_machine); if not p4 then return nil end
        return p4, x4
    end

    -- imported materials with nonzero flow in x (restricted to the producibility
    -- test domain -- materials without a shortage_source are non-producible by
    -- the reference's definition, so never a defeat).
    local function imported_mats(p, x)
        local seen = {}
        for key, pr in pairs(p.primals) do
            if is_import(pr) and pr.material and has_shortage[pr.material] and math.abs(x[key] or 0) > PROD_TOL then
                seen[pr.material] = true
            end
        end
        return seen
    end

    local function disp_esc(pp, xx)
        local s, s2 = 0, 0
        for k, p in pairs(pp.primals) do if p.kind == "shortage_source" or p.kind == "surplus_sink" then
            local v = math.abs(xx[k] or 0); s = s + v; s2 = s2 + v * v end end
        return (s2 > 0) and (s * s / s2) or 0
    end
    local function measure(p, x)
        local Nv = ref.violation_count(p, x, intermediates)
        local Vp, Vc, Vf = ref.violation_split(p, x, intermediates, producible_ref, consumable_ref)
        local Mm = ref.total_of(p, x, ref.MACHINE_KINDS)
        return Nv, Vp, Vc, Vf, Mm, disp_esc(p, x)
    end

    -- ===== variant lump =====
    local pL, xL = run_cascade(nil); if not pL then error("lump-unfinished") end
    local NvL, VpL, VcL, VfL, ML, prL = measure(pL, xL)

    -- ===== variant A: lazy-producible discovery =====
    local solves_lumpA = solves
    local defeat, tested, rounds = {}, {}, 0
    local pA, xA = run_cascade(defeat)
    if pA then
        for r = 1, MAXROUND do
            rounds = r
            local imp = imported_mats(pA, xA)
            local grew = false
            for mat in pairs(imp) do
                if not tested[mat] then
                    tested[mat] = true
                    if producible_test(mat) then defeat[mat] = true; grew = true end
                end
            end
            if not grew then break end
            pA, xA = run_cascade(defeat); if not pA then break end
        end
    end
    local n_defeat = 0; for _ in pairs(defeat) do n_defeat = n_defeat + 1 end
    local NvA, VpA, VcA, VfA, MA, prA = -1, -1, -1, -1, -1, -1
    if pA then NvA, VpA, VcA, VfA, MA, prA = measure(pA, xA) end
    local solves_A = solves - solves_lumpA

    -- ===== variant B: one-hop producible (no LP test, static) =====
    local solves_preB = solves
    local pB, xB = run_cascade(produced)
    local NvB, VpB, VcB, VfB, MB, prB = -1, -1, -1, -1, -1, -1
    if pB then NvB, VpB, VcB, VfB, MB, prB = measure(pB, xB) end
    local solves_B = solves - solves_preB

    return string.format(
        "RESULT\tname=%s\tref_state=%s\tref_steps=%s"
        .. "\tNv_ref=%s\tVp_ref=%.6g\tVc_ref=%.6g\tVf_ref=%.6g\tM_ref=%.6g"
        .. "\tNv_L=%d\tVp_L=%.6g\tVc_L=%.6g\tVf_L=%.6g\tM_L=%.6g\tPR_L=%.4g"
        .. "\tNv_A=%d\tVp_A=%.6g\tVc_A=%.6g\tVf_A=%.6g\tM_A=%.6g\tPR_A=%.4g\trounds=%d\tndefeat=%d\tsolvesA=%d"
        .. "\tNv_B=%d\tVp_B=%.6g\tVc_B=%.6g\tVf_B=%.6g\tM_B=%.6g\tPR_B=%.4g\tsolvesB=%d"
        .. "\tA_state=%s",
        NAME, entry.state, tostring(entry.steps),
        tostring(entry.Nv), entry.Vp, entry.Vc, entry.Vf, entry.M,
        NvL, VpL, VcL, VfL, ML, prL,
        NvA, VpA, VcA, VfA, MA, prA, rounds, n_defeat, solves_A,
        NvB, VpB, VcB, VfB, MB, prB, solves_B,
        pA and "finished" or "unfinished")
end)

io.write((ok and line or string.format("RESULT\tname=%s\tref_state=NA\terr=%s",
    NAME, tostring(line):gsub("%s+", " "):sub(1, 100))) .. "\n")
