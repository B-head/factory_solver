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
-- (which is what pre_solve calls), so the only difference from the in-game path
-- is that these solves are COLD (the pump warm-starts) -- a degenerate-face
-- difference within the solver's tolerance, the same one the baseline already
-- has between probe and ship.
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
local WARM = (os.getenv("FS_WARM") or "off"):lower() == "on"
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
    local prob = build_ship(constraints, lines, nil)
    if not prob then return nil, "build-error", nil, 0, 0 end
    local s, v, steps0 = solve(prob)
    if s ~= "finished" then return prob, s, nil, 1, steps0 end
    local solves, total_steps = 1, steps0

    local p, x, sl, rescue_budget, rsolves = rescue_target(constraints, lines, prob, v.x, v.s)
    solves = solves + rsolves

    local raw = { x = x, s = sl }
    local cc = cascade.begin(p, raw, lines, rescue_budget)
    -- Warm seed: the (target-rescued) baseline answer feeds the first cascade
    -- build; each finished build then seeds the next. Cost differs build to
    -- build but the constraint matrix is shared, so prev x is a candidate.
    -- Phase-aware warm seed (FS_WARM=on): the trace showed fix-tests solve
    -- cheaply cold and warming them from the previous optimum hurts (different
    -- active set = boundary warm off the central path), while stage/final/polish
    -- builds are the heavy ones AND sit almost on top of each other (vf_stage
    -- d_prev 0.04 off vp_final, polish 0.0007 off vc_stage). So fix-tests stay
    -- cold; only the stage chain warms, off the PREVIOUS stage/final (skipping
    -- the fix-tests in between).
    local prev_stage = WARM and raw or nil
    local x_base, x_prev = raw.x, raw.x -- trace references
    local stage_seed_trace = raw -- prev stage/final answer, tracked even when cold (for the residual)
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
            local is_fix = b.fix ~= nil
            local seed = (not is_fix) and prev_stage or nil
            local bs, bv, bsteps = solve_cascade(bp, seed)
            solves = solves + 1
            total_steps = total_steps + (bsteps or 0)
            if TRACE_X and bv and bv.x then
                -- Warm-seed feasibility: relative primal residual ||A·x_seed - b||
                -- of the PREVIOUS stage/final answer against THIS build's matrix.
                -- Large => the warm point is outside this build's constraints (the
                -- infeasible-start the reflection explosion looks like).
                local wr = -1
                if not is_fix then
                    local A = bp:generate_subject_matrix()
                    local bvec = bp:generate_limit_vector()
                    local xw = bp:make_primal_variables(stage_seed_trace)
                    wr = (A * xw - bvec):euclidean_norm() / (1 + bvec:euclidean_norm())
                end
                io.stderr:write(string.format("  %-18s steps=%-4d d_base=%.4g d_prev=%.4g warm_resid=%.4g\n",
                    tostring(ph), bsteps or 0, reldiff(bv.x, x_base), reldiff(bv.x, x_prev), wr))
                x_prev = bv.x
                if not is_fix then stage_seed_trace = bv end
            end
            if WARM and not is_fix and bs == "finished" and bv then prev_stage = bv end
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
