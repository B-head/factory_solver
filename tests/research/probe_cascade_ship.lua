---@diagnostic disable: undefined-global
-- Corpus equivalence driver for the SHIPPED cascade (solver/cascade.lua).
--
-- The cascade is a re-expression of probe_vp_rescue.lua's solve_shipped /
-- rescue_* synchronous loop as the event-driven state machine that the in-game
-- pump (manage/pre_solve.lua M.cascade_step) drives across ticks. This driver
-- runs that state machine over a corpus and emits the SAME column prefix as
-- probe_vp_rescue, so the two TSVs can be diffed column-for-column: a faithful
-- port reproduces probe_vp_rescue's ship-config numbers
-- (FS_VP_CLASS=mini FS_VF=on FS_VC=approx FS_POLISH=on, un-gated) within the
-- self-diff noise band. This is the 1:1-port safety net for the wiring.
--
-- The build shapes here mirror cascade.build_options / cascade.shape_problem
-- (which is what pre_solve calls). FS_WARM selects the start strategy:
--   off (default) -- every build COLD: the reference-equivalent path.
--   on            -- the PRODUCTION path: cold the classification builds
--                    (cascade.is_cold -- fix tests + support probes), warm the
--                    heavy stage/final/polish off the immediately preceding
--                    solve, exactly as pre_solve's pump does (M.arm_cascade_build
--                    nulls solution.raw_variables for cold builds). Verdict-stable
--                    against cold within the self-diff noise band (the cold
--                    classification builds are the verdict-drift fix).
--   on + FS_WARM_ALL -- the production PRE-FIX path (warm EVERY build): the bug
--                    the fix removes -- warming the classification builds drifts
--                    their degenerate vertex off cold/ref and corrupts the
--                    producibility/consumability verdicts (nondeterministically).
--
-- Single-shot contract: `<lua> probe_cascade_ship.lua <dump>` -> one row.
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_cascade_ship.lua -Collect '^seed=' -Out <tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local problem_dump = require "tests/problem_dump"
local ref = require "tests/research/reference_solver"
local refcache = require "tests/research/reference_cache"
local cascade = require "solver/cascade"
local substitution = require "solver/substitution"
local problem_generator = require "solver/problem_generator"

-- FS_TIE: heavy-build tie-break magnitude (solver/problem_generator), applied per
-- build (0 on cascade.is_cold builds, FS_TIE on the heavy / baseline builds) to
-- check whether collapsing the degenerate face to a unique vertex preserves the
-- reference 5-tier grading (it should: the perturbation is << the recipe cost 1).
local TIE = tonumber(os.getenv("FS_TIE") or "") or 0
-- FS_TIESCALE=on enables C-2 magnitude normalization of the heavy-build tie-break
-- (solver/problem_generator.set_tie_scale): each variable's tie-break is divided
-- by an estimate of |x_k*| from the baseline ship solve, so a single small
-- (tier-safe) FS_TIE breaks both big and small degenerate ties uniformly instead
-- of the flat tie-break's leverage growing with magnitude. This driver GRADES the
-- result against the reference 5-tier optimum -- the decisive test of whether the
-- normalization keeps the tie-break below the cost tiers (vs the flat 1e-2 that
-- perturbs the Vp/target escapes). FS_TIEFLOOR caps the division.
-- off=flat | on=baseline-solution magnitude | struct=per-build least-norm
-- (lp.least_norm_magnitude) structural magnitude (objective-independent,
-- vertex-stable, captures amplification bridges the optimum leaves at zero).
local TIESCALE = (os.getenv("FS_TIESCALE") or "off"):lower()
local TIEFLOOR = tonumber(os.getenv("FS_TIEFLOOR") or "") or 1e-3
-- FS_TIE_KINDS: comma-separated PrimalKinds to restrict the tie-break to (e.g.
-- "recipe,bridge" to keep it off the tier-carrying source/sink/elastic escapes).
-- Empty/unset = every non-slack variable (the original behaviour).
local TIE_KINDS = nil
do local s = os.getenv("FS_TIE_KINDS")
    if s and s ~= "" then TIE_KINDS = {}; for k in s:gmatch("[^,]+") do TIE_KINDS[k] = true end end
end
problem_generator.set_tie_kinds(TIE_KINDS)

-- FS_SUBST=on folds the cascade STAGE / lock / fix-test / final builds through
-- proportional row reduction before the IPM solves them (off = the shipped
-- behaviour, which skips the fold for cascade builds). The baseline / target-
-- rescue builds are left untouched in BOTH arms, so the on-vs-off delta isolates
-- exactly the effect of folding the cascade builds. Substitution conserves the
-- objective exactly (escape-singleton cost folds onto the kept recipe; lock-row
-- escapes are multi-row and never folded; surplus_sink is never folded), so any
-- difference is a degenerate-face shift, not a different optimum.
local SUBST = (os.getenv("FS_SUBST") or "off"):lower() == "on"
-- FS_WARM=on chains each cascade build's solve off the PREVIOUS solve's packed
-- result (warm start) instead of a cold Mehrotra start. The A2 experiment:
-- fix-tests rewrite the cost vector wholesale (priced=1 / recipe=eps / else 0)
-- but share the constraint matrix, so the previous solve's x MAY seed the next
-- near-optimally. Measured via ship_steps (total IPM iterations) cold vs warm.
-- FS_WARM=on is the PRODUCTION-FAITHFUL warm path: it warm-starts every cascade
-- build off the immediately preceding solve EXCEPT the classification-determining
-- builds (cascade.is_cold -- fix tests + support probes), which it colds, exactly
-- as manage/pre_solve.lua M.arm_cascade_build does (it nulls solution.raw_variables
-- for those). Off = cold every build (the reference-equivalent path Round 9
-- validated). The cold classification builds are the verdict-drift fix: their
-- nonzero set is read vertex-dependently and a warm seed picks a different
-- degenerate vertex than cold/ref.
local WARM = (os.getenv("FS_WARM") or "off"):lower() == "on"
-- FS_WARM_SUPPORT=on force-warms the SUPPORT probes too (not the fix tests),
-- reproducing one half of the pre-fix verdict-drift bug for A/B measurement.
local WARM_SUPPORT = (os.getenv("FS_WARM_SUPPORT") or "off"):lower() == "on"
-- FS_WARM_ALL=on warms EVERY build (ignores cascade.is_cold) off the immediately
-- preceding solve -- the FAITHFUL production-PRE-FIX path (pre_solve kept
-- solution.raw_variables across every cascade build, fix tests and support
-- probes included). This is the bug the fix removes; A/B it against FS_WARM=on
-- (production-fixed) and FS_WARM=off (cold) to size the verdict drift.
local WARM_ALL = (os.getenv("FS_WARM_ALL") or "off"):lower() == "on"
-- FS_WARM_INDIV=on force-warms the INDIVIDUAL (single-material) fix tests but
-- keeps the support probes and JOINT fix tests (prescreen/demote/promote) cold.
-- The hypothesis: an individual test's verdict reads x[mat_import], which AT the
-- optimum equals the priced objective (the unique minimum), so it is vertex-
-- INDEPENDENT and safe to warm -- only the support/joint reads are the
-- irreducibly center-defined (degenerate) ones.
local WARM_INDIV = (os.getenv("FS_WARM_INDIV") or "off"):lower() == "on"
-- FS_TRACE_X=on prints each cascade build's solve phase + the relative L2
-- distance of its x from the baseline and from the previous build (cold
-- solves), to stderr. Reveals which solves cluster -- the observation that the
-- builds' optima are NOT unrelated, so a well-chosen warm seed may yet help.
local TRACE_X = (os.getenv("FS_TRACE_X") or "off"):lower() == "on"
local function reldiff(a, b)
    local num, den = 0, 0
    for k, va in pairs(a) do
        local vb = b[k] or 0
        num = num + (va - vb) * (va - vb)
        den = den + va * va
    end
    return den > 0 and math.sqrt(num / den) or 0
end

local TOL, ITER = 1e-7, 800
local RESCUE_TRIGGER = 1e-6
local BUDGET_REL, BUDGET_ABS = 1e-3, 1e-6

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function budget(opt) return opt * (1 + BUDGET_REL) + BUDGET_ABS end

local function set_to_list(set)
    local t = {}
    for k in pairs(set) do t[#t + 1] = k end
    table.sort(t)
    return t
end
local function list_to_set(list)
    local s = {}
    for _, k in ipairs(list) do s[k] = true end
    return s
end

-- The un-gated ship baseline / target-only build, matching probe_vp_rescue's
-- build_ship for the observer config with SHIP_SOFT_K unset.
local function build_ship(constraints, lines, target_budget, target_only)
    local opts = { reachability_gating = false, target_budget = target_budget,
        target_only_objective = target_only }
    local ok, p = pcall(create_problem.create_problem, "ship", constraints, lines, nil, opts)
    if not ok then return nil end
    return p
end

-- A cascade stage build, exactly as pre_solve assembles it.
local function build_cascade(constraints, lines, build)
    local ok, p = pcall(create_problem.create_problem, "cascade",
        constraints, lines, nil, cascade.build_options(build))
    if not ok then return nil end
    cascade.shape_problem(p, build)
    return p
end

-- Solve a cascade build, folding it through substitution when FS_SUBST=on
-- (the experiment) -- exactly the reduce / solve-reduced / unfold path
-- manage/pre_solve.lua runs for the baseline. The cascade reads full-space x,
-- so the result is always unfolded back. The fold runs AFTER shape_problem, so
-- the lock rows are already in place and their escapes stay multi-row (unfolded).
local function solve_cascade(p, warm)
    if not SUBST then return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }, warm) end
    local reduced, reconstruction = substitution.reduce(p)
    local s, v, steps = harness.solve_to_completion(lp, reduced, { tolerance = TOL, iterate_limit = ITER }, warm)
    if s ~= "finished" or not v then return s, v, steps end
    return s, substitution.unfold(v, reconstruction), steps
end

-- The shipped lexicographic target rescue (verbatim from probe_vp_rescue /
-- probe_target_rescue). Returns the (possibly rescued) problem + solution and
-- the locked target budget (nil when none).
local function rescue_target(constraints, lines, prob, x0, s0)
    local T0 = ref.total_of(prob, x0, ref.TARGET_KINDS)
    if T0 <= RESCUE_TRIGGER then return prob, x0, s0, nil, 0 end
    local p1 = build_ship(constraints, lines, nil, true)
    if not p1 then return prob, x0, s0, nil, 0 end
    local s1, v1 = solve(p1)
    if s1 ~= "finished" then return prob, x0, s0, nil, 1 end
    local tmin = ref.total_of(p1, v1.x, ref.TARGET_KINDS)
    if tmin >= T0 then return prob, x0, s0, nil, 1 end
    local limit = budget(tmin)
    local p2 = build_ship(constraints, lines, limit)
    if not p2 then return prob, x0, s0, nil, 2 end
    local s2, v2 = solve(p2)
    if s2 ~= "finished" or not v2.x then return prob, x0, s0, nil, 2 end
    return p2, v2.x, v2.s, limit, 2
end

-- Drive solver/cascade.lua to settlement (COLD by default; FS_WARM=on chains
-- each build off the previous solve), exactly as the pump would but
-- synchronously. Returns (problem, state, x, solves, total_steps). total_steps
-- = baseline + cascade-build IPM iterations (rescue solves excluded: they are
-- cold in both arms, so the cold-vs-warm delta isolates the cascade builds).
local function solve_via_cascade(constraints, lines)
    -- Baseline + rescue stay tie-break-FREE: the baseline is only a seed (the
    -- cascade refines it) and the target-only rescue is a MEASUREMENT build whose
    -- 2^-20 target_rescue_epsilon a >=1e-3 tie-break would swamp (corrupting the
    -- measured tmin, exactly as it swamps a fix-test's EPS). The tie-break is
    -- applied only to the adopted heavy builds (stage/final/polish) in the loop.
    problem_generator.set_tie_break(0)
    problem_generator.set_tie_scale(nil)
    local prob = build_ship(constraints, lines, nil)
    if not prob then return nil, "build-error", nil, 0, 0 end
    local s, v, steps0 = solve(prob)
    if s ~= "finished" then return prob, s, nil, 1, steps0 end
    local solves, total_steps = 1, steps0
    -- C-2: per-variable magnitude estimate from the baseline (cold) solution,
    -- used to normalize the heavy-build tie-break leverage (applied per build).
    local scale_map = nil
    if TIESCALE == "on" then
        scale_map = {}
        for k, val in pairs(v.x) do scale_map[k] = val end
    end

    local p, x, sl, rescue_budget, rsolves = rescue_target(constraints, lines, prob, v.x, v.s)
    solves = solves + rsolves

    local raw = { x = x, s = sl }
    local cc = cascade.begin(p, raw, lines, rescue_budget)
    -- Warm seed (FS_WARM=on, production-faithful): the (target-rescued) baseline
    -- answer feeds the first cascade build; each finished build seeds the next off
    -- the immediately preceding solve, mirroring production keeping the result in
    -- solution.raw_variables. The classification builds (cascade.is_cold) cold-
    -- start (production nulls raw_variables for them) -- the verdict-drift fix.
    -- Cost differs build to build but the constraint matrix is shared, so prev x
    -- is a feasible candidate once the freshly added lock-row slacks are derived
    -- (problem_generator.make_primal_variables feasible-slack).
    local prev_any = WARM and raw or nil    -- immediately preceding result (the warm seed; mirrors solution.raw_variables)
    local x_base, x_prev = raw.x, raw.x -- trace references
    local guard = 0
    while cc.build do
        guard = guard + 1
        if guard > 2000 then return p, "cascade-stuck", x, solves, total_steps end
        local b = cc.build
        local ph = cc.phase
        local bp = build_cascade(constraints, lines, b)
        if not bp then
            -- A build error is a terminal non-finished state for advance.
            cascade.advance(cc, p, nil, "unfeasible")
        else
            -- cascade.is_cold marks the classification-determining builds (fix
            -- tests + support probes) that must not warm: their nonzero set is
            -- read vertex-dependently (verdict / universe growth), so a warm seed
            -- picks a different degenerate vertex than cold/ref and corrupts the
            -- classification. FS_WARM_SUPPORT force-warms the support probes (not
            -- the fix tests) to reproduce the bug. The heavy stage/final/polish
            -- builds warm off the immediately preceding solve, exactly as
            -- production does (it keeps solution.raw_variables across those builds).
            local is_cold_build = cascade.is_cold(b)
            -- Tie-break heavy builds only (classification keeps EPS clean).
            local heavy = not is_cold_build
            problem_generator.set_tie_break(heavy and TIE or 0)
            local smap = nil
            if heavy and TIESCALE == "struct" then smap = lp.least_norm_magnitude(bp)
            elseif heavy and TIESCALE == "on" then smap = scale_map end
            problem_generator.set_tie_scale(smap, TIEFLOOR)
            if WARM_ALL then is_cold_build = false end
            if WARM_SUPPORT and b.cold and not b.fix then is_cold_build = false end
            if WARM_INDIV and b.fix and #b.fix.priced == 1 then is_cold_build = false end
            local seed = (not is_cold_build) and prev_any or nil
            local bs, bv, bsteps = solve_cascade(bp, seed)
            solves = solves + 1
            total_steps = total_steps + (bsteps or 0)
            if TRACE_X and bv and bv.x then
                -- Warm-seed feasibility: relative primal residual ||A·x_seed - b||
                -- of the ACTUAL seed used (prev_any) against THIS build's matrix.
                -- Large => the warm point is outside this build's constraints (the
                -- infeasible-start the reflection explosion looks like). -1 = cold.
                local wr = -1
                if seed then
                    local A = bp:generate_subject_matrix()
                    local bvec = bp:generate_limit_vector()
                    local xw = bp:make_primal_variables(seed)
                    wr = (A * xw - bvec):euclidean_norm() / (1 + bvec:euclidean_norm())
                end
                -- The build's stage OBJECTIVE (sum of priced/stage_keys |x|): the
                -- minimized quantity, UNIQUE at any optimum. Compare cold vs warm
                -- here: equal objective + different x = pure degeneracy (the verdict
                -- reads a non-unique vertex); worse warm objective = a warm-start
                -- convergence failure (the deeper bug).
                local obj = -1
                if b.stage_keys then
                    obj = 0
                    for _, k in ipairs(b.stage_keys) do obj = obj + math.abs(bv.x[k] or 0) end
                end
                io.stderr:write(string.format("  %-18s%s steps=%-4d obj=%.8g d_base=%.4g d_prev=%.4g warm_resid=%.4g\n",
                    tostring(ph), is_cold_build and " COLD" or "    ", bsteps or 0, obj,
                    reldiff(bv.x, x_base), reldiff(bv.x, x_prev), wr))
                x_prev = bv.x
            end
            -- The next build warms off this result (production keeps it in
            -- solution.raw_variables); a cold build then nulls it before solving.
            if WARM and bs == "finished" and bv then prev_any = bv end
            cascade.advance(cc, bp, bv, bs)
            if cc.phase == "restore" then
                local rp = build_cascade(constraints, lines, cc.build)
                return rp or bp, "finished", cc.adopted_raw.x, solves, total_steps
            end
        end
    end
    local fp = build_cascade(constraints, lines, cc.adopted_build)
    return fp, "finished", cc.adopted_raw.x, solves, total_steps
end

local COLS = { "label", "n_mats", "ref_state", "T_ref", "Vp_ref", "Vc_ref", "Vf_ref", "M_ref", "S_ref",
    "Nv_ref", "ref_steps", "ref_cached",
    "ship_state", "T_ship", "Vp_ship", "Vc_ship", "Vf_ship", "M_ship", "S_ship", "Nv_ship", "ship_solves", "ship_steps" }

local function process(prob, label, path, emit)
    local intermediates = ref.intermediates(prob.normalized_lines)

    local entry = refcache.load(path)
    local cached = entry ~= nil
    if not entry then
        local r = ref.solve_reference(prob.constraints, prob.normalized_lines)
        local Nv_r = (r.state == "finished" and r.x)
            and ref.violation_count(r.problem, r.x, intermediates) or -1
        entry = {
            state = r.state, n_mats = r.n_mats,
            T = r.T, Vp = r.Vp, Vc = r.Vc, Vf = r.Vf, M = r.M, S = r.S,
            Nv = Nv_r, steps = r.steps,
            producible = set_to_list(r.producible),
            consumable = set_to_list(r.consumable),
        }
        refcache.store(path, entry)
    end
    local producible = list_to_set(entry.producible)
    local consumable = list_to_set(entry.consumable)

    local sp, sstate, sx, solves, ssteps = solve_via_cascade(prob.constraints, prob.normalized_lines)
    local T_s, Vp_s, Vc_s, Vf_s, M_s, S_s, Nv_s = -1, -1, -1, -1, -1, -1, -1
    if sstate == "finished" and sx then
        T_s = ref.total_of(sp, sx, ref.TARGET_KINDS)
        Vp_s, Vc_s, Vf_s = ref.violation_split(sp, sx, intermediates, producible, consumable)
        M_s = ref.total_of(sp, sx, ref.MACHINE_KINDS)
        S_s = ref.total_of(sp, sx, ref.SURPLUS_KINDS)
        Nv_s = ref.violation_count(sp, sx, intermediates)
    end

    emit({ label = label, n_mats = entry.n_mats, ref_state = entry.state, T_ref = entry.T, Vp_ref = entry.Vp,
        Vc_ref = entry.Vc, Vf_ref = entry.Vf, M_ref = entry.M, S_ref = entry.S, Nv_ref = entry.Nv,
        ref_steps = entry.steps, ref_cached = cached and 1 or 0,
        ship_state = sstate, T_ship = T_s, Vp_ship = Vp_s, Vc_ship = Vc_s, Vf_ship = Vf_s,
        M_ship = M_s, S_ship = S_s, Nv_ship = Nv_s, ship_solves = solves, ship_steps = ssteps })
end

-- ---- main -------------------------------------------------------------------
local out_path, manifest_path, files = nil, nil, {}
do local i = 1; while arg[i] do local a = arg[i]
    if a == "--out" then i = i + 1; out_path = arg[i]
    elseif a == "--manifest" then i = i + 1; manifest_path = arg[i]
    else files[#files + 1] = a end; i = i + 1 end end
if manifest_path then for line in io.lines(manifest_path) do line = line:gsub("%s+$", ""); if line ~= "" then files[#files + 1] = line end end end

local sink = io.write; local out_file = nil
if out_path then out_file = assert(io.open(out_path, "w")); sink = function(s) out_file:write(s) end end
local function fmt(v) if v == nil then return "NA" end if type(v) == "number" then return string.format("%.6g", v) end return tostring(v) end
if out_path then sink("#" .. table.concat(COLS, "\t") .. "\n") end
local function emit(r) local o = {}; for _, k in ipairs(COLS) do o[#o + 1] = fmt(r[k]) end; sink(table.concat(o, "\t") .. "\n") end

for _, path in ipairs(files) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local label = "seed=" .. tostring(prob.meta and prob.meta.seed) .. "|" .. (path:match("([^/\\]+)%.lua$") or path)
        local ok, err = pcall(process, prob, label, path, emit)
        if not ok then sink("# ERROR " .. label .. ": " .. tostring(err) .. "\n") end
    end
end
if out_file then out_file:close() end
