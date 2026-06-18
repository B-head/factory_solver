---@diagnostic disable: undefined-global
-- SINGLE-SHOT: the MIRROR of lazy_producible -- cheap Vc (consumable-dump) split
-- WITHOUT the consumable greatest-fixpoint, since the lump's residual gap to the
-- reference is Vc-dominated (203/344 material-gap files vs 36 for Vp).
--
-- The reference's dump tier minimizes ONLY consumable surplus_sink (non-consumable
-- breeding surplus is gratuitous = free). The lump approximates it by minimizing
-- ALL surplus, which both over-penalizes breeding surplus AND can leave a
-- consumable dump the reference would consume. Mirror fix: discover the consumable
-- set LAZILY -- test only the materials the solution actually dumps -- and minimize
-- those alone, freeing the rest. Mirror of lazy_producible exactly (priced_kind =
-- surplus_sink, demand_sign = +1 = inject a unit to absorb).
--
--   lump : T >> (all imports) >> (ALL surplus dumps) >> machines.          [baseline]
--   C    : T >> (all imports) >> (LAZY-consumable dumps only) >> machines.  [mirror]
--   F    : T >> (Vp) >> (Vf) >> (Vc) >> machines, BOTH splits lazy.   [full reinvent]
--
-- Only the dump stage differs C-vs-lump (isolates the Vc axis); F adds the lazy
-- producible import split on top (the full fixpoint-free reference). All measured
-- against the cached reference's FULL producible/consumable yardstick.
--
--   lua tests/research/lazy_consumable.lua <dump>

local NAME = (arg[1] or "?"):match("[^/\\]+$") or "?"
local EPS_RECIPE = 2 ^ -20
local TESTTOL = 1e-4   -- reference phase-1 membership threshold
local MAXROUND = 5
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

    local is_import = function(p) return p.kind == "shortage_source"
        or (p.kind == "initial_source" and p.material and intermediates[p.material]) end
    local is_dump = function(p) return p.kind == "surplus_sink" end
    local is_target = function(p) return p.kind == "elastic" or p.kind == "headroom" end
    local is_machine = function(p) return p.kind == "recipe" end

    -- test domains (materials with the relevant escape under ref.OPTS)
    local has_shortage, has_surplus = {}, {}
    do
        local p0 = create_problem.create_problem("scan", prob.constraints, prob.normalized_lines, nil, ref.OPTS)
        for _, p in pairs(p0.primals) do
            if p.kind == "shortage_source" and p.material then has_shortage[p.material] = true end
            if p.kind == "surplus_sink" and p.material then has_surplus[p.material] = true end
        end
    end

    -- reference phase-1 membership test for ONE material. kind/sign select the
    -- mirror: ("shortage_source",-1)=producible, ("surplus_sink",+1)=consumable.
    local function member_test(mat, kind, sign)
        local p = create_problem.create_problem("fixtest", prob.constraints, prob.normalized_lines, nil, ref.OPTS)
        for _, pr in pairs(p.primals) do
            if pr.kind == kind and pr.material == mat then pr.cost = 1
            elseif pr.kind == "recipe" or pr.kind == "bridge" then pr.cost = EPS_RECIPE
            else pr.cost = 0 end
        end
        local probe = "|mt_probe|" .. mat
        p:add_objective(probe, 0, false, nil, mat)
        p:add_subject_term(probe, mat, sign)
        local dual = "|mt_demand|" .. mat
        p:add_lower_limit_constraint(dual, 1)
        p:add_subject_term(probe, dual, 1)
        local s, v = solve(p)
        if s ~= "finished" or not v then return false end
        local own = 0
        for key, pr in pairs(p.primals) do
            if pr.kind == kind and pr.material == mat then own = own + math.abs(v.x[key] or 0) end
        end
        return own <= TESTTOL
    end

    local function build_stage(unit_fn, budgets)
        local problem = create_problem.create_problem("lc", prob.constraints, prob.normalized_lines, nil, ref.OPTS)
        for _, p in pairs(problem.primals) do
            if unit_fn(p) then p.cost = 1
            elseif p.kind == "recipe" or p.kind == "bridge" then p.cost = EPS_RECIPE
            else p.cost = 0 end
        end
        for i, b in ipairs(budgets or {}) do
            local dual = "|lc_budget|" .. i
            problem:add_upper_limit_constraint(dual, b.limit)
            for key, p in pairs(problem.primals) do if b.fn(p) then problem:add_subject_term(key, dual, 1) end end
        end
        return problem
    end
    local function sum_if(problem, x, fn)
        local s = 0 for key, p in pairs(problem.primals) do if fn(p) then s = s + math.abs(x[key] or 0) end end return s
    end

    -- run the cascade. defeat_set splits imports (Vp>>Vf) when non-nil. cons_set
    -- drives the dump stage; dmode picks how:
    --   nil cons_set        -> all surplus_sink (the lump).
    --   "split"             -> (surplus OR final_sink) of consumables only; the
    --                          reference's exact dump tier (non-consumable FREE).
    --   "augment"           -> ALL surplus_sink (lump-conservative) PLUS the
    --                          final_sink of consumables -- plugs the final_sink
    --                          leak without freeing non-consumable surplus, so a
    --                          missed consumable degrades to lump behaviour.
    local function run_cascade(defeat_set, cons_set, dmode)
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
            local pa, xa = stage(is_defeat); if not pa then return nil end
            budgets[#budgets + 1] = { fn = is_defeat, limit = budget(sum_if(pa, xa, is_defeat)) }
            local pb, xb = stage(is_makeup); if not pb then return nil end
            budgets[#budgets + 1] = { fn = is_makeup, limit = budget(sum_if(pb, xb, is_makeup)) }
        else
            local p2, x2 = stage(is_import); if not p2 then return nil end
            budgets[#budgets + 1] = { fn = is_import, limit = budget(sum_if(p2, x2, is_import)) }
        end
        if cons_set then
            -- a consumable dump leaves through surplus_sink OR a pinned final_sink
            -- (the free requested-output hatch) -- both are the tier-2c defeat. The
            -- lump's surplus_sink-only dump stage misses the final_sink channel.
            local is_cdump
            if dmode == "augment" then
                is_cdump = function(p) return p.kind == "surplus_sink"
                    or (p.kind == "final_sink" and p.material and cons_set[p.material]) end
            else
                is_cdump = function(p) return (p.kind == "surplus_sink" or p.kind == "final_sink")
                    and p.material and cons_set[p.material] end
            end
            local pd, xd = stage(is_cdump); if not pd then return nil end
            budgets[#budgets + 1] = { fn = is_cdump, limit = budget(sum_if(pd, xd, is_cdump)) }
        else
            local p3, x3 = stage(is_dump); if not p3 then return nil end
            budgets[#budgets + 1] = { fn = is_dump, limit = budget(sum_if(p3, x3, is_dump)) }
        end
        local p4, x4 = stage(is_machine); if not p4 then return nil end
        return p4, x4
    end

    -- a consumable dump can leave through surplus_sink OR a pinned final_sink, so
    -- discovery must surface both (restricted to the consumability test domain).
    local function dumped_mats(p, x)
        local seen = {}
        for key, pr in pairs(p.primals) do
            if (pr.kind == "surplus_sink" or pr.kind == "final_sink") and pr.material
                and has_surplus[pr.material] and math.abs(x[key] or 0) > TESTTOL then
                seen[pr.material] = true
            end
        end
        return seen
    end
    -- imports may flow through initial_source too (intermediate deficit), but the
    -- producibility domain is shortage-carrying materials only.
    local function imported_mats(p, x)
        local seen = {}
        for key, pr in pairs(p.primals) do
            if is_import(pr) and pr.material and has_shortage[pr.material] and math.abs(x[key] or 0) > TESTTOL then
                seen[pr.material] = true
            end
        end
        return seen
    end

    -- lazy discovery: grow `set` by phase-1 testing the materials `active(p,x)`
    -- surfaces, re-running the cascade each round until nothing new appears.
    local function discover(set, active, kind, sign, make_cascade)
        local tested, rounds = {}, 0
        local p, x = make_cascade(set)
        if not p then return set, p, x, 0 end
        for r = 1, MAXROUND do
            rounds = r
            local grew = false
            for mat in pairs(active(p, x)) do
                if not tested[mat] then
                    tested[mat] = true
                    if member_test(mat, kind, sign) then set[mat] = true; grew = true end
                end
            end
            if not grew then break end
            p, x = make_cascade(set); if not p then break end
        end
        return set, p, x, rounds
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

    -- ===== lump =====
    local pL, xL = run_cascade(nil, nil); if not pL then error("lump-unfinished") end
    local NvL, VpL, VcL, VfL, ML, prL = measure(pL, xL)

    -- ===== C: lazy-consumable dump SPLIT (reference structure: non-consumable free) =====
    local s0 = solves
    local cons, pC, xC, crounds = discover({}, dumped_mats,
        "surplus_sink", 1, function(set) return run_cascade(nil, set, "split") end)
    local n_cons = 0; for _ in pairs(cons) do n_cons = n_cons + 1 end
    local NvC, VpC, VcC, VfC, MC, prC = -1, -1, -1, -1, -1, -1
    if pC then NvC, VpC, VcC, VfC, MC, prC = measure(pC, xC) end
    local solves_C = solves - s0

    -- ===== C2: AUGMENT (lump all-surplus + final_sink-of-consumable) -- reuses C's set =====
    local s2 = solves
    local pC2, xC2 = run_cascade(nil, cons, "augment")
    local NvC2, VpC2, VcC2, VfC2, MC2, prC2 = -1, -1, -1, -1, -1, -1
    if pC2 then NvC2, VpC2, VcC2, VfC2, MC2, prC2 = measure(pC2, xC2) end
    local solves_C2 = solves - s2

    -- ===== F: full lazy reference (lazy producible import + lazy consumable dump) =====
    local s1 = solves
    local defeat, frounds_i
    defeat, _, _, frounds_i = discover({}, imported_mats, "shortage_source", -1,
        function(set) return run_cascade(set, nil) end)
    local n_defeat = 0; for _ in pairs(defeat) do n_defeat = n_defeat + 1 end
    local pF, xF = run_cascade(defeat, cons)
    local NvF, VpF, VcF, VfF, MF, prF = -1, -1, -1, -1, -1, -1
    if pF then NvF, VpF, VcF, VfF, MF, prF = measure(pF, xF) end
    local solves_F = solves - s1

    return string.format(
        "RESULT\tname=%s\tref_state=%s\tref_steps=%s"
        .. "\tNv_ref=%s\tVp_ref=%.6g\tVc_ref=%.6g\tVf_ref=%.6g\tM_ref=%.6g"
        .. "\tNv_L=%d\tVp_L=%.6g\tVc_L=%.6g\tVf_L=%.6g\tM_L=%.6g\tPR_L=%.4g"
        .. "\tNv_C=%d\tVp_C=%.6g\tVc_C=%.6g\tVf_C=%.6g\tM_C=%.6g\tPR_C=%.4g\tcrounds=%d\tncons=%d\tsolvesC=%d"
        .. "\tNv_C2=%d\tVp_C2=%.6g\tVc_C2=%.6g\tVf_C2=%.6g\tM_C2=%.6g\tPR_C2=%.4g\tsolvesC2=%d\tC2_state=%s"
        .. "\tNv_F=%d\tVp_F=%.6g\tVc_F=%.6g\tVf_F=%.6g\tM_F=%.6g\tPR_F=%.4g\tndefeat=%d\tsolvesF=%d"
        .. "\tF_state=%s",
        NAME, entry.state, tostring(entry.steps),
        tostring(entry.Nv), entry.Vp, entry.Vc, entry.Vf, entry.M,
        NvL, VpL, VcL, VfL, ML, prL,
        NvC, VpC, VcC, VfC, MC, prC, crounds, n_cons, solves_C,
        NvC2, VpC2, VcC2, VfC2, MC2, prC2, solves_C2, pC2 and "finished" or "unfinished",
        NvF, VpF, VcF, VfF, MF, prF, n_defeat, solves_F,
        pF and "finished" or "unfinished")
end)

io.write((ok and line or string.format("RESULT\tname=%s\tref_state=NA\terr=%s",
    NAME, tostring(line):gsub("%s+", " "):sub(1, 100))) .. "\n")
