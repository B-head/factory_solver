---@diagnostic disable: undefined-global
-- Vp-rescue experiment: extend the shipped lexicographic rescue (tier 1 =
-- target, probe_target_rescue.lua) one tier down to tier 2a -- the defeat
-- imports (producible materials bought through |shortage_source| or a
-- deficit-seeded |initial_source|).
--
-- WHY (grade_rescue.txt): tier2a is the largest loss bucket after the target
-- rescue (observer 511, hardgate 481 of 1678). The mechanism mirrors the
-- tier-1 collapse: a single weighted LP trades defeat imports against the
-- collateral they avoid at a FINITE exchange rate -- the soft gate's 256, or
-- the hard gate's classification holes (bootstrap-trapped self-sustaining
-- cycles keep a flat 1024 hatch; over-eager deficit seeds hand out free
-- initial_source) -- so any chain whose collateral-per-unit exceeds the rate
-- is rationally import-defeated, all-or-nothing. The reference minimizes Vp
-- lexicographically (rate = infinity) under its producible classification.
--
-- RESCUE (mirroring reference stage 2a on the SHIP build shape): when the
-- baseline carries priced flow above trigger,
--   stage     re-cost a fresh ship build so the P-approx import hatches
--             (shortage_source, plus initial_source into intermediates;
--             P-approx materials only) are the ONLY objective (recipe/bridge
--             at the 2^-20 face regularizer), under the target budget row
--             -> Vp_min
--   re-solve  ship costs plus BOTH budget rows (target, and
--             sum(priced) <= budget(Vp_min))
-- The target budget row is threaded into BOTH builds even when the target
-- rescue did not fire: the Vp budget forces chains whose makeup can exceed
-- target_cost per target unit (seed_17's ref violation is 3.8e7 > 2^20), so
-- without the row the tier-1 collapse would reappear through this stage.
--
-- P-approx (the probe's stand-in for the reference's joint-fixpoint
-- producibility) = create_problem's OWN reachability verdict (recorded via
-- the research shortage_cost_fn hook on an observer-shaped build; identical
-- for both configs) UNION materials of self-sustaining cyclic SCCs that are
-- export-feasible (observe_price's qualification minus the idle/active
-- conditions: the definition's producibility includes steady-state loops the
-- raw-reachability misses). cls_extra / cls_missing report how this
-- approximation disagrees with the reference's producible set over the
-- materials that actually carry an import hatch.
--
-- Observe-price is NOT run in either config: the stage prices every P-approx
-- hatch at once under a budget, so the per-material price search the fixed
-- point exists for has nothing left to find. Comparing observer rows against
-- rescue_obs.tsv (which ran it) tests that superset hypothesis directly on
-- the 52 problems where it fired.
--
-- Config via env (run_corpus.ps1 passes only the dump path):
--   FS_VP_CONFIG  observer (default) | hardgate
--   FS_VP         on (default) | off   (off = baseline + target rescue only,
--                 classification columns still reported)
--   FS_VF         off (default) | on   Vf rescue = reference stage 2b: with
--                 the target and Vp budgets locked, minimize the makeup
--                 imports (every import hatch the Vp set does not price --
--                 the classification's complement, no extra adjudication),
--                 lock their sum, re-solve at ship costs. The ship costs
--                 price makeup and dumps identically (1024), so the single
--                 weighted solve shuffles makeup against dumps/machines
--                 freely; the definition forbids that (Vf >> Vc >> M) --
--                 that shuffle is the tier2b loss bucket (265 observer
--                 problems in the v3 grading). The Vp budget must thread
--                 into BOTH Vf builds even when the Vp rescue never fired
--                 (lock at the current level): a free P hatch would be the
--                 next tier's whack-a-mole hole.
--   FS_VC         off (default) | oracle | flat | mini   Vc rescue =
--                 reference stage 2c ("consume what you can without buying
--                 extra imports for it"): under the target + Vp + Vf budgets
--                 (the Vf lock is threaded even when the Vf stage never
--                 fired), minimize the priced surplus, lock, re-solve at ship
--                 costs. oracle = price only the reference's consumable
--                 materials; flat = price every |surplus_sink| with no
--                 classification (a non-consumable dump cannot shrink under
--                 the import locks anyway); the flat-vs-oracle gap measured
--                 whether a consumability classifier is needed at all -- it
--                 is (flat leaves 83 of the 169 tier2c losses: cutting a
--                 consumable dump sometimes must GROW a non-consumable one,
--                 and flat's pricing refuses that trade).
--                 mini = the consumability MIRROR of the reference's joint
--                 fixpoint on the surplus side (inject one unit of M;
--                 consumable iff the lines net-absorb it without dumping M
--                 itself) over the FULL sink universe with the reference's
--                 real per-material phase 1, joint demote-one + promotion.
--                 Bit-identical to the oracle on the corpus, but the cost
--                 scales with the sink count and the classification only
--                 depends on the recipe set -- which a real factory
--                 re-shapes on every edit, so it cannot ship (no cache ever
--                 hits). Kept as the in-probe reference implementation.
--                 approx = the SHIPPED-COST candidate: individual tests
--                 only (the reference's phase 1, trustworthy both ways)
--                 over the flowing dumps + one support probe's discoveries;
--                 never-flowed sinks priced wholesale; NO joint phase --
--                 the joint demote-one is what mis-demoted innocents on a
--                 partial universe (the v1 regressions), so dropping it
--                 removes the regression mechanism and the price is the
--                 reference's joint refinements (coupled ties keep both
--                 partners priced = no-headroom misses; phase-3 promotions
--                 stay free). See the rescue_vc comments.
--   FS_POLISH     off (default) | on   The lexicographic machine polish =
--                 reference stage 3: under the target + Vp + Vf + Vc budgets
--                 (every lock threaded at its current level even when its
--                 stage never fired), minimize the machine count -- recipe
--                 variables at 1, bridges at the face regularizer, all else
--                 free. The LOWEST tier: the stage solution IS the final
--                 solution (nothing below it to re-optimize), so the polish
--                 costs exactly one extra solve; the baseline is kept only
--                 when the improvement is numerical noise (the stage is
--                 already paid for, so any real reduction is adopted).
--   FS_RECIPE_EPS <float>   Research override for create_problem's flat
--                 recipe_epsilon tier (shipped 2^-10 ~ 9.8e-4; the per-key
--                 jitter scales with it). The plain-epsilon comparison arm:
--                 the shipped epsilon already presses the degenerate face
--                 toward fewer machines, so how much of the polish's tier-3
--                 win does simply raising it buy, and at what tier-1/2
--                 regression cost (the epsilon trades against violations at
--                 a finite rate ~elastic_cost/eps, the polish at none)?
--   FS_TOL        <float>   Solver tolerance for every probe solve (default
--                 1e-7). Tighter tolerance sharpens the epsilon tie-break
--                 (dust ~ tol/eps) without changing any cost.
--   FS_SOFT_K     <float>   Soft-gate strength for the ship builds. Default
--                 UNSET = no gate at all (reachable and unreachable hatches
--                 both flat elastic_cost). The 2026-06-13 k=1/256/4096 corpus
--                 A/B graded the un-gated cascade best (tie 1530 vs 1522 vs
--                 1510): under the full rescue pipeline the gate is a
--                 solve-count damper, not a quality device, and its price
--                 pressure hides baseline cheats below the mini classifier's
--                 FLOW_TH (seed_78/99 Vp residues). Strengthening starves the
--                 rescue of its detection signal outright (k=4096 broke
--                 tier 1 on seed_124). 256 reproduces the legacy observer
--                 shape for A/Bs. Only the ship builds read this -- the
--                 P-approx recording builds keep SOFT_GATE_K (the recorder
--                 only logs is_reachable; costs never affect the
--                 classification). Ignored under FS_VP_CONFIG=hardgate.
--   FS_VP_CLASS   approx (default) | oracle | mini | miniflat
--                 oracle = the reference's producible set as P-approx: the
--                 mechanism's ceiling with a perfect classifier.
--                 miniflat = round 2's first cut: the reference's 3-phase
--                 joint synthetic-demand fixpoint restricted to the FLOWING
--                 import materials (median 1-2 per problem); every
--                 non-flowing hatch is presumed P and priced wholesale
--                 (hole-safe). Two baked-in failure modes, kept for the A/B:
--                 the non-flowing whack-a-mole partner is invisible (the
--                 generous test over-includes feedstock makeup -- seed_109's
--                 water), and the wholesale pricing budget-caps from-zero
--                 makeup (seed_17 bottoms far above the oracle's 0).
--                 mini = probe-first (round 3): adjudicate the flowing set,
--                 then ONE support probe (members priced, all else free)
--                 reveals the import support the rescue wants -- partners,
--                 from-zero feedstock -- and the union is adjudicated once
--                 more before the stage. Replaces round 2's bottom-retry
--                 loop (mean 12.6 solves: the bottom fired on 56% of flowing
--                 problems and re-ran stage+final each round). The fixpoint's
--                 phase 1 is a joint PRESCREEN: one joint solve passes the
--                 clean materials wholesale, violators pay the individual
--                 screen, and phase 2 only runs when a coupled violator
--                 re-joins. Failed earlier variants, kept for the record: a
--                 graduated outsider price inside the tests contaminates
--                 verdicts at mass scale ~1/delta and balloons the universe
--                 (expansion must come from real-demand probes), and the
--                 bottom-retry shape pays its probe only after wasting a
--                 stage+final on the bottomed pricing.
--
-- Single-shot contract: `<lua> probe_vp_rescue.lua <dump>` -> one row, same
-- 21-column prefix as probe_reference_compare (grade_two_solvers.lua parses
-- it; columns 22+ are extras it ignores).
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_vp_rescue.lua -Collect '^seed=' -Out <tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local problem_dump = require "tests/problem_dump"
local material_cycles = require "solver/material_cycles"
local ref = require "tests/research/reference_solver"
local refcache = require "tests/research/reference_cache"

local CONFIG = (os.getenv("FS_VP_CONFIG") or "observer"):lower()
local VP = (os.getenv("FS_VP") or "on"):lower() ~= "off"
local CLASS = (os.getenv("FS_VP_CLASS") or "approx"):lower()
local VF = (os.getenv("FS_VF") or "off"):lower() == "on"
local VC = (os.getenv("FS_VC") or "off"):lower()
local POLISH = (os.getenv("FS_POLISH") or "off"):lower() == "on"
local RECIPE_EPS = tonumber(os.getenv("FS_RECIPE_EPS") or "") -- nil = shipped 2^-10
assert(CONFIG == "observer" or CONFIG == "hardgate", "FS_VP_CONFIG must be observer|hardgate")
assert(CLASS == "approx" or CLASS == "oracle" or CLASS == "mini" or CLASS == "miniflat",
    "FS_VP_CLASS must be approx|oracle|mini|miniflat")
assert(VC == "off" or VC == "oracle" or VC == "flat" or VC == "mini" or VC == "approx",
    "FS_VC must be off|oracle|flat|mini|approx")

local TOL, ITER = tonumber(os.getenv("FS_TOL") or "") or 1e-7, 800
local SOFT_GATE_K = 256 -- P-approx recording builds only (k-independent classification)
-- Ship builds' gate strength; nil (the default) = un-gated flat. See the
-- FS_SOFT_K header note for the corpus verdict behind the default.
local SHIP_SOFT_K = tonumber(os.getenv("FS_SOFT_K") or "")
local RESCUE_TRIGGER = 1e-6 -- target rescue (mirrors the shipped step)
local VP_TRIGGER = 1e-4     -- below the grader's ABS tie threshold: dust not worth 2 solves
local FLOW_TH = 1e-4        -- mini classifier: an import hatch above this is "flowing"
local FIX_TOL = 1e-4        -- mini fixpoint own-residual dust threshold (= reference's)
local BUDGET_REL, BUDGET_ABS = 1e-3, 1e-6
local EPS_RECIPE = 2 ^ -20

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end

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

local function budget(opt) return opt * (1 + BUDGET_REL) + BUDGET_ABS end

---Hatch-deletion state for the problem being processed: set by rescue_vp's
---final FALLBACKS when the ordinary budget-row final diverges and the stage
---proved Vp_min ~ 0 (see rescue_vp), cleared at the top of solve_shipped.
---Every later build of the SAME problem (Vf / Vc / polish stages and finals)
---must keep the deletion or the ~zero Vp face would have to be re-imposed as
---the numerically hostile budget row. STAGED_RELAY is the deeper fallback:
---ship-cost finals diverge on this problem outright, so every later stage
---adopts its own stage solution (the reference's staged shape) instead of
---re-solving at ship costs.
local HATCH_EXCLUDE = nil
local STAGED_RELAY = false

---One ship build of the configured shape. No observe-price overrides anywhere
---in this probe.
---@param target_budget number?
---@param target_only boolean?
local function build_ship(constraints, lines, target_budget, target_only)
    local opts
    if CONFIG == "hardgate" then
        opts = {}
    else
        -- reachability_soft_gate_k stays absent when SHIP_SOFT_K is nil: the
        -- un-gated flat hatch is the cascade's ship shape (FS_SOFT_K note).
        opts = { reachability_gating = false, reachability_soft_gate_k = SHIP_SOFT_K }
    end
    opts.target_budget = target_budget
    opts.target_only_objective = target_only
    opts.recipe_epsilon = RECIPE_EPS
    opts.hatch_exclude = HATCH_EXCLUDE
    local ok, p = pcall(create_problem.create_problem, "ship", constraints, lines, nil, opts)
    if not ok then return nil end
    return p
end

---Thread every established stage lock (Vp / Vf / Vc) into a build as budget
---rows. Locks are set by their stages at the CURRENT level even when the
---stage never fired (the hole-plugging rule: a free prior tier would be the
---next tier's whack-a-mole hole); absent keys mean the stage's tier is not
---part of this run's configuration.
local function add_lock_rows(p, r)
    if not p then return p end
    if r.vp_lock_keys and r.vp_lock_limit then
        local d = "|research_vp_budget|"
        p:add_upper_limit_constraint(d, r.vp_lock_limit)
        for _, key in ipairs(r.vp_lock_keys) do p:add_subject_term(key, d, 1) end
    end
    if r.vf_lock_keys and r.vf_lock_limit then
        local d = "|research_vf_budget|"
        p:add_upper_limit_constraint(d, r.vf_lock_limit)
        for _, key in ipairs(r.vf_lock_keys) do p:add_subject_term(key, d, 1) end
    end
    if r.vc_lock_keys and r.vc_lock_limit then
        local d = "|research_vc_budget|"
        p:add_upper_limit_constraint(d, r.vc_lock_limit)
        for _, key in ipairs(r.vc_lock_keys) do p:add_subject_term(key, d, 1) end
    end
    return p
end

local function build_solve_ship(constraints, lines, target_budget)
    local p = build_ship(constraints, lines, target_budget)
    if not p then return nil, "build-error", nil, nil end
    local s, v = solve(p)
    if s ~= "finished" then return p, s, nil, nil end
    return p, s, v.x, v.s
end

---The shipped lexicographic target rescue (verbatim from probe_target_rescue).
---@return Problem prob, table x, table? s, number? budget_limit, integer solves, number tmin
local function rescue_target(constraints, lines, prob, x0, s0)
    local T0 = ref.total_of(prob, x0, ref.TARGET_KINDS)
    if T0 <= RESCUE_TRIGGER then return prob, x0, s0, nil, 0, -1 end

    local p1 = build_ship(constraints, lines, nil, true)
    if not p1 then return prob, x0, s0, nil, 0, -1 end
    local s1, v1 = solve(p1)
    if s1 ~= "finished" then return prob, x0, s0, nil, 1, -1 end
    local tmin = ref.total_of(p1, v1.x, ref.TARGET_KINDS)
    if tmin >= T0 then return prob, x0, s0, nil, 1, tmin end -- no headroom; keep baseline

    local limit = budget(tmin)
    local p2, s2, x2, sl2 = build_solve_ship(constraints, lines, limit)
    if s2 ~= "finished" or not x2 then return prob, x0, s0, nil, 2, tmin end
    return p2, x2, sl2, limit, 2, tmin
end

---P-approx: create_problem's own reachability verdict (recorded through the
---research shortage_cost_fn hook; the recording builds are observer-shaped for
---BOTH configs so the classification is config-independent) plus the
---self-sustaining export-feasible cyclic SCC materials.
---
---The hook only fires for materials that carry a hatch, and the deficit-seeded
---ones take the initial_source branch instead -- yet they carry the bulk of
---the corpus defeat mass (seed_17: 731k of 732k Vp rides on seeded
---initial_source of ACYCLIC ref-producible materials like formamide). Raw-only
---reachability (all seeds off) is too strict for them: their chains legally
---feed on OTHER makeup. The right question is leave-one-out -- is the seeded
---material reachable with every seed BUT ITS OWN intact (a seed must not grant
---itself legitimacy) -- asked through the deficit_exclude research option, one
---recording build per seeded intermediate (builds only, no solves).
local function compute_p_approx(constraints, lines, intermediates)
    local reach = {}
    local function recorder(name, is_reachable)
        if is_reachable then reach[name] = true end
        return is_reachable and (create_problem.elastic_cost * SOFT_GATE_K) or create_problem.elastic_cost
    end
    local ok, pa = pcall(create_problem.create_problem, "vp_reach_a", constraints, lines, nil,
        { reachability_gating = false, reachability_soft_gate_k = SOFT_GATE_K, shortage_cost_fn = recorder })

    -- Leave-one-out verdicts for the seeded intermediates of build (a).
    local seeded = {}
    if ok and pa then
        for _, p in pairs(pa.primals) do
            if p.kind == "initial_source" and p.material and intermediates[p.material] then
                seeded[#seeded + 1] = p.material
            end
        end
        table.sort(seeded)
    end
    for _, d in ipairs(seeded) do
        local loo = {}
        pcall(create_problem.create_problem, "vp_reach_loo", constraints, lines, nil,
            { reachability_gating = false, reachability_soft_gate_k = SOFT_GATE_K,
                deficit_exclude = { [d] = true },
                shortage_cost_fn = function(name, is_reachable)
                    if is_reachable then loo[name] = true end
                    return is_reachable and (create_problem.elastic_cost * SOFT_GATE_K) or create_problem.elastic_cost
                end })
        if loo[d] then reach[d] = true end
    end

    local adj = material_cycles.build_material_graph(lines)
    local sccs = material_cycles.find_sccs(adj)
    for _, scc in ipairs(sccs) do
        if material_cycles.is_cyclic_scc(scc, adj) and material_cycles.is_self_sustaining(lines, scc) then
            for _, m in ipairs(scc) do
                if material_cycles.export_feasible(lines, m) then reach[m] = true end
            end
        end
    end
    return reach
end

---One synthetic-demand test solve on the unseeded build: price `priced_set`
---escapes of `priced_kind` at 1, recipes/bridges at the face EPS, ALL else
---free (verbatim reference probe mechanics -- a graduated outsider price was
---tried and contaminates the verdict at mass scale ~1/delta, so outsiders
---stay free and partner discovery is the rescue loop's job, not the test's).
---(priced_kind, demand_sign) selects the mirror, exactly as the reference's
---shared fixpoint engine: ("shortage_source", -1) asks producibility (a sink
---demanding one net-produced unit), ("surplus_sink", +1) asks consumability
---(a source injecting one unit to net-absorb). Returns the per-material
---own-escape residuals over priced_set (nil = unfinished).
local function fix_test(constraints, lines, priced_set, demand_list, priced_kind, demand_sign)
    local ok0, p = pcall(create_problem.create_problem, "vp_fixtest", constraints, lines, nil, ref.OPTS)
    if not ok0 then return nil end
    for _, pr in pairs(p.primals) do
        if pr.kind == priced_kind and priced_set[pr.material] then
            pr.cost = 1
        elseif pr.kind == "recipe" or pr.kind == "bridge" then
            pr.cost = EPS_RECIPE
        else
            pr.cost = 0
        end
    end
    for _, mat in ipairs(demand_list) do
        local probe = "|vp_fixtest_probe|" .. mat
        p:add_objective(probe, 0, false, nil, mat)
        p:add_subject_term(probe, mat, demand_sign)
        local dual = "|vp_fixtest_demand|" .. mat
        p:add_lower_limit_constraint(dual, 1)
        p:add_subject_term(probe, dual, 1)
    end
    local ok, s, v = pcall(solve, p)
    if not ok or s ~= "finished" then return nil end
    local own = {}
    for key, pr in pairs(p.primals) do
        if pr.kind == priced_kind and pr.material and priced_set[pr.material] then
            own[pr.material] = (own[pr.material] or 0) + math.abs(v.x[key] or 0)
        end
    end
    return own
end

---The reference's fixpoint over the universe `U` (a set), phase 1 replaced by
---a joint PRESCREEN: one joint solve over all of U; materials clean there
---pass straight through, and only the violators pay an individual screen
---(verdicts cached in `p1` -- the individual test prices only the material
---itself, so it survives universe growth). Rationale: the joint prices and
---demands a superset of the individual test, so joint-clean is the harder
---certificate (not a strict implication -- a co-demand's chain could in
---principle co-produce an input the individual test lacks; the clsF columns
---watch for drift). Phase 2's demote-one only runs when an individually-
---passing violator re-joins (a coupled tie -- it can push formerly-clean
---members over); when every violator fails individually the surviving member
---set is exactly the joint-clean set, and the member-only joint is an EASIER
---test than the prescreen that already proved them clean, so phase 2 is
---skipped outright. Phase 3 promotion sweeps as in the reference. Returns
---the member set and the solve count spent this call. (priced_kind,
---demand_sign) selects the producibility / consumability mirror (see
---fix_test); the verdict cache `p1` must be per-mirror (the caller owns it).
local function fixpoint_over(constraints, lines, U, p1, priced_kind, demand_sign)
    local mats = {}
    for m in pairs(U) do mats[#mats + 1] = m end
    table.sort(mats)

    local TRACE = os.getenv("FS_FIX_TRACE") ~= nil
    local function trace(fmt, ...) if TRACE then io.stderr:write(("[fix %s] "):format(priced_kind) .. fmt:format(...) .. "\n") end end

    local solves = 0
    local function run(priced_set, demand_list)
        solves = solves + 1
        return fix_test(constraints, lines, priced_set, demand_list, priced_kind, demand_sign)
    end

    local function individual(mat)
        if p1[mat] == nil then
            local own = run({ [mat] = true }, { mat })
            p1[mat] = { pass = own ~= nil and (own[mat] or 0) <= FIX_TOL }
            trace("individual %s %s (own=%s)", mat, p1[mat].pass and "PASS" or "FAIL",
                own and tostring(own[mat] or 0) or "unfinished")
        end
        return p1[mat].pass
    end

    -- Phase 1. For the producibility mirror a joint PRESCREEN stands in:
    -- the joint prices and demands a superset of the individual test, so
    -- joint-clean is the harder certificate, and only the violators pay the
    -- individual screen. For the consumability mirror the prescreen is
    -- unsound in BOTH directions -- a joint injection is free supply to the
    -- other members' absorption chains (seed_104: two reference-
    -- non-consumable sinks read clean in every joint, only the true
    -- individual catches them), while co-pricing closes escape routes
    -- (seed_88's hydrogen-chloride reads own=2 in a partial joint yet
    -- passes individually) -- so there the reference's real per-material
    -- phase 1 runs, and demote-one always follows. The flowing-restricted /
    -- prescreen-accelerated economies of the Vp classifier are all unsound
    -- on the surplus side; what remains IS the reference fixpoint, paid in
    -- full -- but it depends only on the problem STRUCTURE (not the target
    -- or the solution), so a shipped implementation computes it once per
    -- recipe set and caches.
    local members, coupled = {}, false
    if #mats == 1 then
        if individual(mats[1]) then members[mats[1]] = true end
        return members, solves
    end
    if demand_sign > 0 then
        for _, mat in ipairs(mats) do
            if individual(mat) then members[mat] = true end
        end
        coupled = true -- demote-one always runs (reference-faithful)
    else
        local own0 = run(U, mats)
        if own0 then
            for _, mat in ipairs(mats) do
                if (own0[mat] or 0) <= FIX_TOL then
                    members[mat] = true
                    trace("prescreen clean %s (own=%g)", mat, own0[mat] or 0)
                elseif individual(mat) then
                    members[mat] = true
                    coupled = true
                    trace("prescreen violator %s re-joins via individual", mat)
                end
            end
        else
            -- Prescreen unfinished: fall back to full individual screening,
            -- and run phase 2 since no joint certificate exists.
            for _, mat in ipairs(mats) do
                if individual(mat) then members[mat] = true end
            end
            coupled = true
        end
    end

    local function member_list(set)
        local list = {}
        for _, mat in ipairs(mats) do if set[mat] then list[#list + 1] = mat end end
        return list
    end
    local function count(set)
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        return n
    end

    -- Phase 2: joint demote-one, only when a coupled violator re-joined
    -- (couples need >= 2; otherwise the prescreen certificate stands). The
    -- consumability mirror sets `coupled` unconditionally above.
    local tie_demoted = {}
    if coupled and count(members) >= 2 then
        for _ = 1, #mats + 1 do
            local own = run(members, member_list(members))
            if not own then break end
            local worst, wamt = nil, FIX_TOL
            for _, mat in ipairs(mats) do
                local amt = own[mat] or 0
                if members[mat] and amt > wamt then worst, wamt = mat, amt end
            end
            if not worst then break end
            trace("phase2 demote %s (own=%g)", worst, wamt)
            members[worst] = nil
            tie_demoted[#tie_demoted + 1] = worst
        end
    end

    -- Phase 3: promotion sweeps over the phase-2 demotions.
    for _ = 1, #tie_demoted do
        local promoted = false
        for _, mat in ipairs(tie_demoted) do
            if not members[mat] then
                local trial = { [mat] = true }
                for m in pairs(members) do trial[m] = true end
                local own = run(trial, member_list(trial))
                if own then
                    local clean = true
                    for m in pairs(trial) do
                        if (own[m] or 0) > FIX_TOL then clean = false; break end
                    end
                    if clean then
                        members[mat] = true; promoted = true
                        trace("phase3 promote %s", mat)
                    end
                end
            end
        end
        if not promoted then break end
    end

    return members, solves
end

---miniflat (round 2's first cut, kept for the A/B): adjudicate ONLY the
---flowing materials with a free-outsider fixpoint, and wholesale-price every
---non-flowing hatch. Sanity showed both failure modes this bakes in: the
---whack-a-mole partner of a flowing material is usually NOT flowing (the LP
---chose one side), so the generous test over-includes feedstock makeup
---(seed_109's water); and the wholesale pricing budget-caps from-zero makeup
---the rescue chain needs (seed_17 bottoms at 6750 where the oracle reaches 0).
local function classify_miniflat(constraints, lines, intermediates, prob, x0)
    local flowing = {}
    for key, p in pairs(prob.primals) do
        local is_import = p.kind == "shortage_source"
            or (p.kind == "initial_source" and p.material and intermediates[p.material])
        if is_import and p.material and math.abs(x0[key] or 0) > FLOW_TH then
            flowing[p.material] = true
        end
    end
    if not next(flowing) then return nil, { n_flow = 0, fp_solves = 0 } end

    local U = {}
    for m in pairs(flowing) do U[m] = true end
    local p1 = {}
    local members, fp_solves = fixpoint_over(constraints, lines, U, p1, "shortage_source", -1)

    local F, n_flow = {}, 0
    for m in pairs(flowing) do F[#F + 1] = m; n_flow = n_flow + 1 end
    table.sort(F)

    local p_approx = {}
    for _, p in pairs(prob.primals) do
        local is_import = p.kind == "shortage_source"
            or (p.kind == "initial_source" and p.material and intermediates[p.material])
        if is_import and p.material then p_approx[p.material] = true end
    end
    for _, m in ipairs(F) do
        if not members[m] then p_approx[m] = nil end
    end
    return p_approx, { n_flow = n_flow, fp_solves = fp_solves, F = F, members = members, n_univ = n_flow }
end

---Enumerate the import hatches the measurement counts (violation_split's
---is_import): every |shortage_source|, plus |initial_source| into an
---intermediate. Returns the P-approx subset as sorted keys (the stage's
---objective / budget membership) and the full candidate material set (the
---classification-diff denominator).
local function priced_candidates(prob, intermediates, p_approx)
    local keys, cand_mats = {}, {}
    for key, p in pairs(prob.primals) do
        local is_import = p.kind == "shortage_source"
            or (p.kind == "initial_source" and p.material and intermediates[p.material])
        if is_import and p.material then
            cand_mats[p.material] = true
            if p_approx[p.material] then keys[#keys + 1] = key end
        end
    end
    table.sort(keys)
    return keys, cand_mats
end

---The lexicographic Vp rescue. Returns the (possibly replaced) solution plus
---bookkeeping: extra solves, Vp_min, vp_rescued (1 budget applied / -1
---attempted but baseline kept / 0 not triggered), and the baseline priced sum.
local function rescue_vp(constraints, lines, prob, x0, t_limit, priced_keys)
    local vp0 = 0
    for _, key in ipairs(priced_keys) do vp0 = vp0 + math.abs(x0[key] or 0) end
    if not VP or #priced_keys == 0 or vp0 <= VP_TRIGGER then return prob, x0, 0, -1, 0, vp0 end

    -- Stage: P-approx hatches as the only objective, target budget locked.
    local p1 = build_ship(constraints, lines, t_limit)
    if not p1 then return prob, x0, 0, -1, -1, vp0 end
    local priced_set = list_to_set(priced_keys)
    for key, p in pairs(p1.primals) do
        if priced_set[key] then
            p.cost = 1
        elseif p.kind == "recipe" or p.kind == "bridge" then
            p.cost = EPS_RECIPE
        else
            p.cost = 0
        end
    end
    local s1, v1 = solve(p1)
    if s1 ~= "finished" then return prob, x0, 1, -1, -1, vp0 end
    local vpmin = 0
    for _, key in ipairs(priced_keys) do vpmin = vpmin + math.abs(v1.x[key] or 0) end
    -- No-headroom guard, same shape as the Vf/Vc stages: improvements inside
    -- the grading tolerance are not worth the final solve, and the tighter
    -- lock (budget(vpmin) instead of budget(vp0)) would pin the lower tiers
    -- for nothing. Anything the grader can see (> max(ABS, 5e-3 rel)) still
    -- rescues -- the un-gated baseline relies on that.
    if vp0 - vpmin <= math.max(VP_TRIGGER, vp0 * 5e-3) then return prob, x0, 1, vpmin, -1, vp0 end

    -- Re-solve at ship costs under both locked budgets.
    local p2 = build_ship(constraints, lines, t_limit)
    if not p2 then return prob, x0, 1, vpmin, -1, vp0 end
    local dual = "|research_vp_budget|"
    p2:add_upper_limit_constraint(dual, budget(vpmin))
    for _, key in ipairs(priced_keys) do p2:add_subject_term(key, dual, 1) end
    local s2, v2 = solve(p2)
    if s2 == "finished" and v2.x then return p2, v2.x, 2, vpmin, 1, vp0 end

    -- The final diverged -- the corpus finalfail family (seed_17/96/124/26
    -- ...), every one with Vp_min ~ 0: the budget row pins LIVE hatch
    -- variables against sum <= ~1e-6, a face the IPM's interior cannot
    -- approach. Two escalating fallbacks, both only sound when the stage
    -- proved Vp_min ~ 0 (its solution is the witness that the build stays
    -- feasible with no hatch at all):
    --   1. deletion final -- DELETE the priced hatches (HATCH_EXCLUDE) and
    --      re-run the ship-cost final on the structural face; the lock row
    --      disappears with the variables. Fixes the seed_26 shape.
    --   2. staged relay -- on the rest (seed_17/96/124) the ship-cost final
    --      diverges even on the deletion build (the optimum is the full
    --      fabricate cascade, ref machine counts 1e7+, and the 2^20-tier
    --      cost regime cannot converge there; a 4x iteration cap does not
    --      help). Give up on ship-cost finals for this problem entirely:
    --      adopt the Vp stage solution, and let every later stage adopt its
    --      own stage solution too (STAGED_RELAY) -- the exact staged shape
    --      the reference solves these problems with.
    if vpmin > VP_TRIGGER then return prob, x0, 2, vpmin, -1, vp0 end
    local mats = {}
    for _, key in ipairs(priced_keys) do
        local pr = prob.primals[key]
        if pr and pr.material then mats[pr.material] = true end
    end
    HATCH_EXCLUDE = mats
    local p3 = build_ship(constraints, lines, t_limit)
    if p3 then
        local s3, v3 = solve(p3)
        if s3 == "finished" and v3.x then return p3, v3.x, 3, vpmin, 1, vp0 end
    end
    STAGED_RELAY = true
    return p1, v1.x, 3, vpmin, 1, vp0
end

---The lexicographic Vf rescue (reference stage 2b on the ship shape; see the
---FS_VF header note). Reads the Vp lock from `r` (keys + limit -- threaded
---into both builds), prices the complement (the makeup hatches), locks the
---achieved minimum, re-solves at ship costs. Improvements below the grading
---tolerance are not worth the final solve and count as no-headroom.
local function rescue_vf(constraints, lines, intermediates, prob, x, t_limit, r)
    -- The makeup complement and its lock are computed even when the Vf stage
    -- is off: the Vc stage threads the Vf budget regardless ("consume what
    -- you can without buying extra imports for it" -- without the lock, the
    -- Vc stage would buy makeup to consume dumps, the exact inversion the
    -- definition's ordering exists to forbid).
    local vpset = list_to_set(r.vp_lock_keys or {})
    local makeup_keys = {}
    for key, pr in pairs(prob.primals) do
        local is_import = pr.kind == "shortage_source"
            or (pr.kind == "initial_source" and pr.material and intermediates[pr.material])
        if is_import and not vpset[key] then makeup_keys[#makeup_keys + 1] = key end
    end
    table.sort(makeup_keys)
    r.n_makeup = #makeup_keys

    local vf0 = 0
    for _, key in ipairs(makeup_keys) do vf0 = vf0 + math.abs(x[key] or 0) end
    r.vf0 = vf0
    r.vf_lock_keys = makeup_keys
    r.vf_lock_limit = budget(math.max(vf0, 0))

    if not VF or #makeup_keys == 0 or vf0 <= VP_TRIGGER then return prob, x end

    local function with_vp_row(p)
        if p and r.vp_lock_keys and r.vp_lock_limit then
            local dual = "|research_vp_budget|"
            p:add_upper_limit_constraint(dual, r.vp_lock_limit)
            for _, key in ipairs(r.vp_lock_keys) do p:add_subject_term(key, dual, 1) end
        end
        return p
    end

    -- Stage: the makeup hatches as the only objective under both prior budgets.
    local p1 = with_vp_row(build_ship(constraints, lines, t_limit))
    if not p1 then return prob, x end
    local mset = list_to_set(makeup_keys)
    for key, pr in pairs(p1.primals) do
        if mset[key] then
            pr.cost = 1
        elseif pr.kind == "recipe" or pr.kind == "bridge" then
            pr.cost = EPS_RECIPE
        else
            pr.cost = 0
        end
    end
    r.solves = r.solves + 1
    local s1, v1 = solve(p1)
    if s1 ~= "finished" then r.vf_rescued = -1; return prob, x end
    local vfmin = 0
    for _, key in ipairs(makeup_keys) do vfmin = vfmin + math.abs(v1.x[key] or 0) end
    r.vfmin = vfmin
    if STAGED_RELAY then
        -- Ship-cost finals diverge on this problem (see rescue_vp): adopt
        -- the stage solution itself; the later stages restore their tiers.
        r.vf_rescued = 1
        r.vf_lock_limit = budget(vfmin)
        return p1, v1.x
    end
    if vf0 - vfmin <= math.max(VP_TRIGGER, vf0 * 5e-3) then r.vf_rescued = -1; return prob, x end

    -- Final: ship costs under the target + Vp + Vf budgets.
    local p2 = with_vp_row(build_ship(constraints, lines, t_limit))
    if not p2 then r.vf_rescued = -1; return prob, x end
    local dual = "|research_vf_budget|"
    p2:add_upper_limit_constraint(dual, budget(vfmin))
    for _, key in ipairs(makeup_keys) do p2:add_subject_term(key, dual, 1) end
    r.solves = r.solves + 1
    local s2, v2 = solve(p2)
    if s2 ~= "finished" or not v2.x then r.vf_rescued = -1; return prob, x end
    r.vf_rescued = 1
    r.vf_lock_limit = budget(vfmin)
    return p2, v2.x
end

---The lexicographic Vc rescue (reference stage 2c: "consume what you can
---without buying extra imports for it"). Under the target + Vp + Vf budgets,
---minimize the priced surplus, lock the optimum, re-solve at ship costs.
---FS_VC=oracle prices only the reference's consumable materials; FS_VC=flat
---prices every |surplus_sink| with NO classification -- under the import
---locks a non-consumable dump (breeding-loop overflow) cannot shrink anyway,
---so pricing it only adds an irreducible constant to Vc_min. The one case
---where flat and oracle genuinely differ: cutting a consumable dump at the
---price of GROWING a non-consumable one (the reference takes that trade, a
---flat objective refuses it when the growth exceeds the cut) -- the
---flat-vs-oracle corpus gap measures exactly how much that matters, i.e.
---whether a consumability classifier is needed at all. FS_VC=mini replaces
---the oracle with the ship-side reference fixpoint over the full sink
---universe (see the FS_VC header note and the inline comment below for why
---nothing cheaper survives).
local function rescue_vc(constraints, lines, prob, x, t_limit, r, consumable)
    if VC == "off" then return prob, x end

    local function with_locks(p)
        if not p then return p end
        if r.vp_lock_keys and r.vp_lock_limit then
            local d = "|research_vp_budget|"
            p:add_upper_limit_constraint(d, r.vp_lock_limit)
            for _, key in ipairs(r.vp_lock_keys) do p:add_subject_term(key, d, 1) end
        end
        if r.vf_lock_keys and r.vf_lock_limit then
            local d = "|research_vf_budget|"
            p:add_upper_limit_constraint(d, r.vf_lock_limit)
            for _, key in ipairs(r.vf_lock_keys) do p:add_subject_term(key, d, 1) end
        end
        return p
    end

    local entries = {}
    for key, pr in pairs(prob.primals) do
        if pr.kind == "surplus_sink" and pr.material then
            entries[#entries + 1] = { key = key, material = pr.material }
        end
    end
    table.sort(entries, function(a, b) return a.key < b.key end)

    local priced = {}
    if VC == "mini" or VC == "approx" then
        -- The consumability mirror (see the FS_VC header note). Trigger
        -- pre-check on the FLAT sum first: the priced subset can only be
        -- smaller, so below the trigger the adjudication is not worth its
        -- solves (vc0 then reports the flat upper bound).
        local flat0, seen_flow = 0, {}
        r.n_vcflow = 0
        for _, e in ipairs(entries) do
            flat0 = flat0 + math.abs(x[e.key] or 0)
            if not seen_flow[e.material] and math.abs(x[e.key] or 0) > FLOW_TH then
                seen_flow[e.material] = true
                r.n_vcflow = r.n_vcflow + 1
            end
        end
        if flat0 <= VP_TRIGGER or r.n_vcflow == 0 then
            -- Nothing flowing to adjudicate -- but the NEXT tier (the machine
            -- polish) still needs a Vc ceiling, or it freely grows consumable
            -- dumps to shed machines (measured: 384 tie -> tier2c_loss
            -- regressions on the full pipeline; the oracle/flat arms set
            -- their lock before this point and never hit it). Without a
            -- classification the lock is the FLAT sum over every sink:
            -- over-strict on the non-consumable share (which the reference's
            -- stage 3 leaves free), but the whole surplus is ~zero here, so
            -- the freedom lost is only the freedom to grow dumps from
            -- nothing.
            local all_keys = {}
            for _, e in ipairs(entries) do all_keys[#all_keys + 1] = e.key end
            r.vc_lock_keys = all_keys
            r.vc_lock_limit = budget(math.max(flat0, 0))
            r.vc0 = flat0
            return prob, x
        end

        local U, members
        if VC == "approx" then
            -- approx = the shipped-cost candidate: per-material INDIVIDUAL
            -- tests only, over the flowing dumps plus one support probe's
            -- discoveries; never-flowed sinks stay priced wholesale
            -- (hole-safe). Why no joint phase: the individual test is the
            -- reference's own phase 1 -- trustworthy in both directions
            -- (seed_104's prescreen leaks are individual FAILs; seed_88's
            -- hydrogen-chloride is an individual PASS) -- while the joint
            -- demote-one is precisely what mis-demoted innocents on a
            -- partial universe (the v1 regression family: a doomed co-demand
            -- the partial universe cannot demote reads its collateral onto
            -- an innocent member). Dropping the joint removes the regression
            -- MECHANISM rather than patching its symptoms. What is lost is
            -- the reference's joint refinements, in both directions:
            -- EXTRA -- a true coupled tie (a mass-positive pair absorbing
            -- each other's overflow) keeps both partners priced, so the
            -- stage refuses their shuffle = a no-headroom miss, never a
            -- hole; MISSING -- the reference's phase-3 promotions
            -- (individual-FAIL materials revived in a joint context) stay
            -- free here. The corpus arbitrates what either costs; the
            -- classification needs no cache and prices at flowing-count
            -- individual solves plus one probe.
            U, members = {}, {}
            local p1 = {}
            local function individual(mat)
                if p1[mat] == nil then
                    r.vcfp_solves = r.vcfp_solves + 1
                    r.solves = r.solves + 1
                    local own = fix_test(constraints, lines, { [mat] = true }, { mat }, "surplus_sink", 1)
                    p1[mat] = { pass = own ~= nil and (own[mat] or 0) <= FIX_TOL }
                end
                return p1[mat].pass
            end
            for _, e in ipairs(entries) do
                if not U[e.material] and math.abs(x[e.key] or 0) > FLOW_TH then
                    U[e.material] = true
                    if individual(e.material) then members[e.material] = true end
                end
            end
            if next(members) then
                -- Support probe: members priced under the full lock set (the
                -- stage's own environment), all else free; where the
                -- displaced surplus flows is the support to adjudicate.
                local pf = with_locks(build_ship(constraints, lines, t_limit))
                if pf then
                    local member_keys = {}
                    for _, e in ipairs(entries) do
                        if members[e.material] then member_keys[e.key] = true end
                    end
                    for key, pr in pairs(pf.primals) do
                        if member_keys[key] then
                            pr.cost = 1
                        elseif pr.kind == "recipe" or pr.kind == "bridge" then
                            pr.cost = EPS_RECIPE
                        else
                            pr.cost = 0
                        end
                    end
                    r.solves = r.solves + 1
                    local sf, vf2 = solve(pf)
                    if sf == "finished" then
                        for _, e in ipairs(entries) do
                            if not U[e.material] and math.abs(vf2.x[e.key] or 0) > FLOW_TH then
                                U[e.material] = true
                                if individual(e.material) then members[e.material] = true end
                            end
                        end
                    end
                end
            end
            for _, e in ipairs(entries) do
                if members[e.material] or not U[e.material] then
                    priced[#priced + 1] = e.key
                end
            end
        else
            -- mini: the universe is EVERY sink material, not the flowing
            -- subset, and fixpoint_over runs the reference's real
            -- per-material phase 1 for this mirror (see its phase-1 note).
            -- The cheaper variants measured along the way: flowing-restricted
            -- + support probe + never-flowed priced wholesale = tier2c 169 ->
            -- 30 with 4 outright regressions (partial universe mis-demotes:
            -- seed_88's hydrogen-chloride is collateral of a doomed co-demand
            -- the partial universe cannot demote, becomes a zero-price hole,
            -- and the stage dumps 78 units through it); a co-demand CONTEXT
            -- variant (outsiders demanded but not demotable) leaves that
            -- trace bit-identical (the fix requires DEMOTING the doomed
            -- outsider); a full-universe joint prescreen still admits
            -- reference-non-consumable sinks (seed_104) because the
            -- injection joint is generous in a way no member subset cures.
            -- Full universe with real phase 1 retires the support probe, the
            -- wholesale never-flowed pricing, and both misclassification
            -- directions, at a cost scaling with the sink count per build --
            -- which is why FS_VC=approx exists: real factories re-shape the
            -- recipe set on every edit, so a per-recipe-set cache never hits
            -- and the full fixpoint cannot ship as a per-solve cost.
            U = {}
            for _, e in ipairs(entries) do U[e.material] = true end

            local p1 = {}
            local fp
            members, fp = fixpoint_over(constraints, lines, U, p1, "surplus_sink", 1)
            r.vcfp_solves = r.vcfp_solves + fp
            r.solves = r.solves + fp

            for _, e in ipairs(entries) do
                if members[e.material] then priced[#priced + 1] = e.key end
            end
        end
        local F = set_to_list(U)
        r.n_vcuniv = #F
        r.vc_cls_info = { F = F, members = members }
    else
        for _, e in ipairs(entries) do
            if VC == "flat" or (consumable and consumable[e.material]) then
                priced[#priced + 1] = e.key
            end
        end
    end
    table.sort(priced)
    r.n_vcpriced = #priced

    local vc0 = 0
    for _, key in ipairs(priced) do vc0 = vc0 + math.abs(x[key] or 0) end
    r.vc0 = vc0
    -- The Vc lock for the next tier (the machine polish), at the current
    -- level even when this stage does not fire -- same hole-plugging rule as
    -- the Vf lock. The local with_locks above must NOT thread it (it builds
    -- this stage's own problems); only add_lock_rows consumers see it.
    r.vc_lock_keys = priced
    r.vc_lock_limit = budget(math.max(vc0, 0))
    if #priced == 0 or vc0 <= VP_TRIGGER then return prob, x end

    -- Stage: the priced surplus as the only objective under all prior budgets.
    local p1 = with_locks(build_ship(constraints, lines, t_limit))
    if not p1 then return prob, x end
    local pset = list_to_set(priced)
    for key, pr in pairs(p1.primals) do
        if pset[key] then
            pr.cost = 1
        elseif pr.kind == "recipe" or pr.kind == "bridge" then
            pr.cost = EPS_RECIPE
        else
            pr.cost = 0
        end
    end
    r.solves = r.solves + 1
    local s1, v1 = solve(p1)
    if s1 ~= "finished" then r.vc_rescued = -1; return prob, x end
    local vcmin = 0
    for _, key in ipairs(priced) do vcmin = vcmin + math.abs(v1.x[key] or 0) end
    r.vcmin = vcmin
    if STAGED_RELAY then
        -- Ship-cost finals diverge on this problem (see rescue_vp): adopt
        -- the stage solution itself; the polish restores the machine tier.
        r.vc_rescued = 1
        r.vc_lock_limit = budget(vcmin)
        return p1, v1.x
    end
    if vc0 - vcmin <= math.max(VP_TRIGGER, vc0 * 5e-3) then r.vc_rescued = -1; return prob, x end

    -- Final: ship costs under the target + Vp + Vf + Vc budgets.
    local p2 = with_locks(build_ship(constraints, lines, t_limit))
    if not p2 then r.vc_rescued = -1; return prob, x end
    local dual = "|research_vc_budget|"
    p2:add_upper_limit_constraint(dual, budget(vcmin))
    for _, key in ipairs(priced) do p2:add_subject_term(key, dual, 1) end
    r.solves = r.solves + 1
    local s2, v2 = solve(p2)
    if s2 ~= "finished" or not v2.x then r.vc_rescued = -1; return prob, x end
    r.vc_rescued = 1
    r.vc_lock_limit = budget(vcmin)
    return p2, v2.x
end

---The lexicographic machine polish (reference stage 3 on the ship shape; see
---the FS_POLISH header note). Under every established budget -- the target
---row plus the Vp / Vf / Vc locks -- minimize the machine count: recipe
---variables at 1, bridges at the face regularizer (the reference's
---tie-break), everything else free. The LOWEST tier: the stage solution IS
---the final solution (no further tier to re-optimize at ship costs), so the
---polish costs exactly one solve. The baseline is kept only when the
---improvement is numerical noise -- the stage solution is already paid for
---(there is no final to skip), so any real machine reduction is adopted.
local function rescue_polish(constraints, lines, intermediates, prob, x, t_limit, r)
    if not POLISH then return prob, x end
    local m0 = ref.total_of(prob, x, ref.MACHINE_KINDS)
    r.m0 = m0

    local p1 = add_lock_rows(build_ship(constraints, lines, t_limit), r)
    if not p1 then return prob, x end
    for _, pr in pairs(p1.primals) do
        if pr.kind == "recipe" then
            pr.cost = 1
        elseif pr.kind == "bridge" then
            pr.cost = EPS_RECIPE
        else
            pr.cost = 0
        end
    end
    r.solves = r.solves + 1
    local s1, v1 = solve(p1)
    if s1 ~= "finished" or not v1.x then r.polish = -1; return prob, x end
    local mmin = ref.total_of(p1, v1.x, ref.MACHINE_KINDS)
    r.mmin = mmin
    -- Adopt any real improvement: the stage solution is already paid for
    -- (there is no final to skip). The old grading-tolerance threshold
    -- (5e-3, the grader's own REL) parked exactly-at-the-boundary
    -- improvements and turned reachable ties into tier-3 losses (seed_74:
    -- M 38.71 reachable, kept 38.89; the dust-Vp-lock family). Noise floor
    -- only -- but see the tier guard below.
    if m0 - mmin <= 1e-9 * math.max(1, m0) then r.polish = -1; return prob, x end
    -- Zero-escape preservation guard (polish = -2). The budget locks bound
    -- every tier only up to their margin (rel 1e-3 + abs 1e-6), and the
    -- polish prices everything but machines at ZERO, so it happily spends
    -- the whole margin to shave machines. Mostly that is harmless jitter on
    -- escapes that already flow (the grader's 5e-3 REL absorbs it -- a
    -- per-escape absolute guard tried first rejected 609 polishes and blew
    -- tier-3 losses 41 -> 234). The one shape that DOES grade as a loss:
    -- margin spent into an escape the rescue cascade had driven to ZERO
    -- (seed_111: flat Vc lock 20 -> margin 0.02 into an am-241 dump the
    -- reference keeps at 0 = a tier-2c loss bought with a 0.02-machine
    -- win). A zero escape in the rescued input is the ship-side proxy for
    -- "the reference holds this at zero", so: reject only when the TOTAL
    -- growth across the input solution's effectively-zero escapes exceeds
    -- the grader-visible band (10x ABS; per-component thresholds miss
    -- multi-component spends, the sum is what the tier value sees).
    local function escape_map(p, xx)
        local m = {}
        for key, pr in pairs(p.primals) do
            local is_esc = pr.kind == "shortage_source" or pr.kind == "surplus_sink"
                or pr.kind == "elastic"
                or (pr.kind == "initial_source" and pr.material and intermediates[pr.material])
            if is_esc then
                local id = pr.kind .. "|" .. (pr.material or key)
                m[id] = (m[id] or 0) + math.abs(xx[key] or 0)
            end
        end
        return m
    end
    local m_before, m_after = escape_map(prob, x), escape_map(p1, v1.x)
    local TRACE = os.getenv("FS_POLISH_TRACE") ~= nil
    local zero_growth = 0
    for id, v1v in pairs(m_after) do
        local v0v = m_before[id] or 0
        if v0v <= VP_TRIGGER and v1v > v0v then
            zero_growth = zero_growth + (v1v - v0v)
            if TRACE and v1v - v0v > 1e-9 then
                io.stderr:write(("[polish zero-grow] %s %g -> %g\n"):format(id, v0v, v1v))
            end
        end
    end
    if zero_growth > 10 * VP_TRIGGER then
        if TRACE then io.stderr:write(("[polish guard] zero_growth %g > %g: reject\n"):format(zero_growth, 10 * VP_TRIGGER)) end
        r.polish = -2
        return prob, x
    end
    r.polish = 1
    return p1, v1.x
end

---mini (probe-first, round 3): one support probe replaces round 2's
---bottom-retry loop. v2 measured mean 12.6 solves -- the bottom fired on 56%
---of the flowing problems (from-zero makeup is the COMMON case, not the
---exception) and every retry re-ran stage+final. Instead: adjudicate the
---flowing set; when anything is producible, ONE probe solve with just those
---members priced and everything else genuinely free reveals the whole import
---support the rescue wants (whack-a-mole partners like seed_109's CO2,
---from-zero makeup feedstock like seed_17's); the union is adjudicated once
---more and the stage runs straight to the final. The structural-bottom case
---(hard gate) needs no special handling -- the probe leans on nothing new
---and the single pass accepts the floor.
local function rescue_vp_mini(constraints, lines, intermediates, prob0, x0, t_limit, r)
    local function import_entries(p)
        local list = {}
        for key, pr in pairs(p.primals) do
            local is_import = pr.kind == "shortage_source"
                or (pr.kind == "initial_source" and pr.material and intermediates[pr.material])
            if is_import and pr.material then list[#list + 1] = { key = key, material = pr.material } end
        end
        table.sort(list, function(a, b) return a.key < b.key end)
        return list
    end
    local entries = import_entries(prob0)

    local U = {}
    r.n_flow = 0
    for _, e in ipairs(entries) do
        if not U[e.material] and math.abs(x0[e.key] or 0) > FLOW_TH then
            U[e.material] = true
            r.n_flow = r.n_flow + 1
        end
    end
    if r.n_flow == 0 then return prob0, x0 end

    local p1 = {}
    local members, fp = fixpoint_over(constraints, lines, U, p1, "shortage_source", -1)
    r.fp_solves = r.fp_solves + fp
    r.solves = r.solves + fp

    if next(members) then
        -- Support probe: members priced, everything else genuinely free.
        local pf = build_ship(constraints, lines, t_limit)
        if pf then
            local member_keys = {}
            for _, e in ipairs(entries) do
                if members[e.material] then member_keys[e.key] = true end
            end
            for key, pr in pairs(pf.primals) do
                if member_keys[key] then
                    pr.cost = 1
                elseif pr.kind == "recipe" or pr.kind == "bridge" then
                    pr.cost = EPS_RECIPE
                else
                    pr.cost = 0
                end
            end
            r.solves = r.solves + 1
            local sf, vf = solve(pf)
            if sf == "finished" then
                local grew = false
                for _, e in ipairs(entries) do
                    if not U[e.material] and math.abs(vf.x[e.key] or 0) > FLOW_TH then
                        U[e.material] = true
                        grew = true
                    end
                end
                if grew then
                    members, fp = fixpoint_over(constraints, lines, U, p1, "shortage_source", -1)
                    r.fp_solves = r.fp_solves + fp
                    r.solves = r.solves + fp
                end
            end
        end
    end

    -- Priced = adjudicated members plus every never-flowed hatch (default-P);
    -- adjudicated makeup (U minus members) is free.
    local priced_keys = {}
    for _, e in ipairs(entries) do
        if members[e.material] or not U[e.material] then
            priced_keys[#priced_keys + 1] = e.key
        end
    end
    r.n_priced = #priced_keys

    local vsolves, prob2, x2
    prob2, x2, vsolves, r.vpmin, r.vp_rescued, r.vp0 = rescue_vp(constraints, lines, prob0, x0, t_limit, priced_keys)
    r.solves = r.solves + vsolves
    r.vp_lock_keys = priced_keys
    r.vp_lock_limit = r.vp_rescued == 1 and budget(r.vpmin) or budget(math.max(r.vp0, 0))
    if HATCH_EXCLUDE then -- deletion fallback: the face is structural, no lock row
        r.vp_deleted = STAGED_RELAY and 2 or 1
        r.vp_lock_keys, r.vp_lock_limit = nil, nil
    end
    local prob, x = prob0, x0
    if r.vp_rescued == 1 then prob, x = prob2, x2 end

    local F = {}
    for m in pairs(U) do F[#F + 1] = m end
    table.sort(F)
    r.n_univ = #F
    r.cls_info = { F = F, members = members or {} }
    -- The effective classification the stage priced: adjudicated members plus
    -- the default-P unadjudicated hatches.
    local eff = {}
    for _, e in ipairs(entries) do
        if (members and members[e.material]) or not U[e.material] then eff[e.material] = true end
    end
    r.p_approx = eff
    return prob, x
end

---Baseline -> target rescue -> classify -> Vp rescue. The target budget row
---is threaded into every Vp build (stage and final) even when the target
---rescue kept the baseline: see the header note on collapse reappearing
---through the Vp budget. `classify(prob, x0)` returns the P-approx set (nil =
---nothing to price) plus an info table; the mini classifier solves LPs and
---reports them through info.fp_solves.
local function solve_shipped(constraints, lines, intermediates, classify, consumable)
    local r = { solves = 1, rescued = 0, tmin = -1, vp_rescued = 0, vpmin = -1, vp0 = -1,
        n_priced = 0, n_flow = -1, fp_solves = 0, n_univ = -1,
        vf_rescued = 0, vfmin = -1, vf0 = -1, n_makeup = 0,
        vc_rescued = 0, vcmin = -1, vc0 = -1, n_vcpriced = 0,
        n_vcflow = -1, vcfp_solves = 0, n_vcuniv = -1,
        polish = 0, m0 = -1, mmin = -1, vp_deleted = 0 }
    HATCH_EXCLUDE, STAGED_RELAY = nil, false -- per-problem reset (rescue_vp's fallbacks)
    local prob, state, x0, s0 = build_solve_ship(constraints, lines, nil)
    if state ~= "finished" or not x0 then return nil, state, nil, r end

    local budget_limit, rsolves
    prob, x0, s0, budget_limit, rsolves, r.tmin = rescue_target(constraints, lines, prob, x0, s0)
    r.solves = r.solves + rsolves
    r.rescued = budget_limit and 1 or (rsolves > 0 and -1 or 0)

    local t_cur = ref.total_of(prob, x0, ref.TARGET_KINDS)
    local t_limit = budget_limit or budget(t_cur)

    if CLASS == "mini" then
        -- The adaptive pipeline owns its classify/stage/expand loop.
        local cand = {}
        for _, pr in pairs(prob.primals) do
            local is_import = pr.kind == "shortage_source"
                or (pr.kind == "initial_source" and pr.material and intermediates[pr.material])
            if is_import and pr.material then cand[pr.material] = true end
        end
        r.cand_mats = cand
        local prob2, x2 = rescue_vp_mini(constraints, lines, intermediates, prob, x0, t_limit, r)
        if (r.n_flow or 0) <= 0 then r.cand_mats = nil end -- cls denominators are meaningless without flow
        prob2, x2 = rescue_vf(constraints, lines, intermediates, prob2, x2, t_limit, r)
        prob2, x2 = rescue_vc(constraints, lines, prob2, x2, t_limit, r, consumable)
        prob2, x2 = rescue_polish(constraints, lines, intermediates, prob2, x2, t_limit, r)
        return prob2, "finished", x2, r
    end

    local p_approx, cls_info = classify(prob, x0)
    if cls_info then
        r.n_flow = cls_info.n_flow or -1
        r.fp_solves = cls_info.fp_solves or 0
        r.n_univ = cls_info.n_univ or -1
        r.solves = r.solves + r.fp_solves
        r.cls_info = cls_info
    end
    if not p_approx then return prob, "finished", x0, r end

    local priced_keys, cand_mats = priced_candidates(prob, intermediates, p_approx)
    r.n_priced = #priced_keys
    r.cand_mats = cand_mats
    r.p_approx = p_approx

    local vsolves
    prob, x0, vsolves, r.vpmin, r.vp_rescued, r.vp0 = rescue_vp(constraints, lines, prob, x0, t_limit, priced_keys)
    r.solves = r.solves + vsolves
    r.vp_lock_keys = priced_keys
    r.vp_lock_limit = r.vp_rescued == 1 and budget(r.vpmin) or budget(math.max(r.vp0, 0))
    if HATCH_EXCLUDE then -- deletion fallback: the face is structural, no lock row
        r.vp_deleted = STAGED_RELAY and 2 or 1
        r.vp_lock_keys, r.vp_lock_limit = nil, nil
    end

    prob, x0 = rescue_vf(constraints, lines, intermediates, prob, x0, t_limit, r)
    prob, x0 = rescue_vc(constraints, lines, prob, x0, t_limit, r, consumable)
    prob, x0 = rescue_polish(constraints, lines, intermediates, prob, x0, t_limit, r)
    return prob, "finished", x0, r
end

local COLS = { "label", "n_mats", "ref_state", "T_ref", "Vp_ref", "Vc_ref", "Vf_ref", "M_ref", "S_ref", "Nv_ref", "ref_steps", "ref_cached",
    "ship_state", "T_ship", "Vp_ship", "Vc_ship", "Vf_ship", "M_ship", "S_ship", "Nv_ship", "ship_solves",
    "rescued", "T_min", "vp_rescued", "Vp_min", "Vp0", "n_priced", "cls_extra", "cls_missing",
    "n_flow", "fp_solves", "clsF_extra", "clsF_missing", "n_univ",
    "vf_rescued", "Vf_min", "Vf0", "n_makeup",
    "vc_rescued", "Vc_min", "Vc0", "n_vcpriced",
    "n_vcflow", "vcfp_solves", "n_vcuniv", "clsC_extra", "clsC_missing",
    "polish", "M0", "M_min", "vp_deleted" }

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

    -- oracle = the reference's joint-fixpoint producible set (mechanism
    -- ceiling: how much does the lexicographic stage fix when classification
    -- is perfect); approx = round 1's static classifier; mini = round 2's
    -- flowing-restricted fixpoint (needs the baseline solution, so it runs as
    -- a callback inside the pipeline).
    local classify
    if CLASS == "oracle" then
        classify = function() return producible, nil end
    elseif CLASS == "approx" then
        local pa = compute_p_approx(prob.constraints, prob.normalized_lines, intermediates)
        classify = function() return pa, nil end
    elseif CLASS == "miniflat" then
        classify = function(p, x)
            return classify_miniflat(prob.constraints, prob.normalized_lines, intermediates, p, x)
        end
    else
        classify = function() return nil, nil end -- mini: solve_shipped branches internally
    end

    local sp, sstate, sx, info = solve_shipped(prob.constraints, prob.normalized_lines, intermediates, classify, consumable)
    local T_s, Vp_s, Vc_s, Vf_s, M_s, S_s, Nv_s = -1, -1, -1, -1, -1, -1, -1
    if sstate == "finished" and sx then
        T_s = ref.total_of(sp, sx, ref.TARGET_KINDS)
        Vp_s, Vc_s, Vf_s = ref.violation_split(sp, sx, intermediates, producible, consumable)
        M_s = ref.total_of(sp, sx, ref.MACHINE_KINDS)
        S_s = ref.total_of(sp, sx, ref.SURPLUS_KINDS)
        Nv_s = ref.violation_count(sp, sx, intermediates)
    end

    -- Classification diff over the materials that actually carry a hatch.
    local used = info.p_approx or (CLASS == "oracle" and producible) or {}
    local cls_extra, cls_missing = 0, 0
    for m in pairs(info.cand_mats or {}) do
        local pa, pr = used[m] == true, producible[m] == true
        if pa and not pr then cls_extra = cls_extra + 1 end
        if pr and not pa then cls_missing = cls_missing + 1 end
    end

    -- Mini classifier: the same diff restricted to the flowing set it
    -- actually adjudicated (the wholesale-priced non-flowing hatches dominate
    -- cls_extra by construction and carry no signal).
    local clsF_extra, clsF_missing = -1, -1
    if info.cls_info and info.cls_info.F then
        clsF_extra, clsF_missing = 0, 0
        for _, m in ipairs(info.cls_info.F) do
            local pa, pr = info.cls_info.members[m] == true, producible[m] == true
            if pa and not pr then clsF_extra = clsF_extra + 1 end
            if pr and not pa then clsF_missing = clsF_missing + 1 end
        end
    end

    -- Vc mini classifier: the same diff against the reference's consumable
    -- set, over the dump universe it adjudicated.
    local clsC_extra, clsC_missing = -1, -1
    if info.vc_cls_info and info.vc_cls_info.F then
        clsC_extra, clsC_missing = 0, 0
        for _, m in ipairs(info.vc_cls_info.F) do
            local ca, cr = info.vc_cls_info.members[m] == true, consumable[m] == true
            if ca and not cr then clsC_extra = clsC_extra + 1 end
            if cr and not ca then clsC_missing = clsC_missing + 1 end
        end
    end

    emit({ label = label, n_mats = entry.n_mats, ref_state = entry.state, T_ref = entry.T, Vp_ref = entry.Vp,
        Vc_ref = entry.Vc, Vf_ref = entry.Vf, M_ref = entry.M, S_ref = entry.S, Nv_ref = entry.Nv,
        ref_steps = entry.steps, ref_cached = cached and 1 or 0,
        ship_state = sstate, T_ship = T_s, Vp_ship = Vp_s, Vc_ship = Vc_s, Vf_ship = Vf_s,
        M_ship = M_s, S_ship = S_s, Nv_ship = Nv_s, ship_solves = info.solves,
        rescued = info.rescued, T_min = info.tmin,
        vp_rescued = info.vp_rescued, Vp_min = info.vpmin, Vp0 = info.vp0,
        n_priced = info.n_priced, cls_extra = cls_extra, cls_missing = cls_missing,
        n_flow = info.n_flow, fp_solves = info.fp_solves,
        clsF_extra = clsF_extra, clsF_missing = clsF_missing, n_univ = info.n_univ,
        vf_rescued = info.vf_rescued, Vf_min = info.vfmin, Vf0 = info.vf0, n_makeup = info.n_makeup,
        vc_rescued = info.vc_rescued, Vc_min = info.vcmin, Vc0 = info.vc0, n_vcpriced = info.n_vcpriced,
        n_vcflow = info.n_vcflow, vcfp_solves = info.vcfp_solves, n_vcuniv = info.n_vcuniv,
        clsC_extra = clsC_extra, clsC_missing = clsC_missing,
        polish = info.polish, M0 = info.m0, M_min = info.mmin, vp_deleted = info.vp_deleted })
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
