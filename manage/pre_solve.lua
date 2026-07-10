local flib_table = require "__flib__/table"
local acc = require "manage/accessor"
local create_problem = require "solver/create_problem"
local linear_programming = require "solver/linear_programming"
local substitution = require "solver/substitution"
local observe_price = require "solver/observe_price"
local cascade = require "solver/cascade"
local mode_compress = require "solver/mode_compress"
local placement = require "solver/placement"
local vk = require "solver/var_key"

local iterate_limit = 600

-- The shipped solver dispatch (2026-06-20) is per-solution: solution.solver_norm
-- picks how the import/dump imbalance is balanced. All five user-selectable norms
-- run on the SAME un-gated baseline build and differ only in problem shaping:
--   "l1"          concentrate -- the plain ungated baseline (linear elastic_cost),
--                 one solve. The L1 norm: the imbalance piles onto few channels.
--   "l2"          balanced -- the baseline with the violation elastics repriced to
--                 a pure quadratic (create_problem's violation_quad), one (QP)
--                 solve, THEN the mode-compression fold (M.l2_compress_step):
--                 sibling violation channels collapse to one per group and the
--                 problem re-solves without the losers. The L2 norm: the
--                 imbalance spreads evenly.
--   "l2_baseline" the identical L2 QP shaping as "l2", but WITHOUT the
--                 compression fold -- the pre-fold answer, exposed so it can be
--                 compared side by side against "l2" on the same solution.
--   "linf"        leveled -- a two-stage min-max (M.linf_step): minimize the peak
--                 violation, then minimize total under that cap. The L-infinity
--                 norm.
--   "legacy"      the old hard reachability gate + two-pass diagnose (the
--                 rollback path, kept as a conservative default).
-- "cascade" is the retired staged rescue (solver/cascade.lua), kept dispatchable
-- but NOT offered in the UI, so its fixtures keep validating it. The target
-- rescue (M.target_rescue_step) runs in front of every norm: targets are tier-1.
-- L2 cost scale. The IPM converges to the analytic centre of the optimal face,
-- so a 0-optimal variable parks at the "dust" residual x ~ mu/s* (mu ~ tol at
-- termination, s* its reduced cost). The dual-certified zero-purification
-- (linear_programming.certify_zeros) only snaps a variable it can prove zero --
-- s_i > x_i, equivalently x_i < sqrt(mu) -- so a 0-optimal column is reachable by
-- purify only if its s* clears sqrt(mu) ~ sqrt(1e-7) ~ 2^-11.6. The earlier L2
-- build priced its violation elastics at 0 + a quad=2 (zero marginal cost at the
-- origin -> s* -> 0) and its recipe tier at a tiny 2^-20 (s* ~ 2^-20), so EVERY
-- 0-optimal column sat far below the purify threshold and L2 snapped nothing to 0
-- (it left tens of recipes / imports / dumps parked at 1e-4..1e-1).
--
-- The fix raises the recipe tier and the violation quad TOGETHER (a uniform scale
-- of the {recipe, violation} objective by 2^10, so the build-vs-import crossover
-- eps/quad stays at 2^-21 and the L2 optimum is argmin-invariant -- verified:
-- sum(viol^2), the genuine recipe set, and the import/dump totals are preserved),
-- and adds a small linear floor on the violation elastics (the elastic-net L1
-- admixture). Now every costable column's reduced cost clears sqrt(mu): the recipe
-- zeros park near 0 (s* = eps = 2^-10, well above sqrt(mu)) and the violation zeros
-- snap to EXACTLY 0 (the floor carries their purify certificate). The quad must be
-- raised, not just the linear floor: without it the now-material recipe tier is
-- undercut by the cheap quad import and an over-cycling chain collapses to importing
-- its completed intermediates (the L1 cheat); the leak point is kept at 2^-21 so
-- building still wins at the margin.
--
-- The scale factor (2^10) is deliberately kept SMALL: the quad sits just above the
-- target tier (2^11 vs target_cost 2^10) so it prevents the collapse and pulls the
-- violations to the purify floor WITHOUT dominating the target tier and over-firing
-- the rescue. (An earlier cut scaled by 2^14 -- quad 2^15, 32x the target tier --
-- which cleaned the pathological deep-cycle recipe dust to EXACTLY 0 too, but made
-- the baseline relax targets for tiny forced violations; this trades a little of
-- that recipe-dust cleaning -- those zeros now park at ~1e-4, below the report
-- threshold rather than exactly 0 -- for a quad that respects the tier order.)
-- sqrt(mu) is the IPM zero floor, NOT a constant we can lower without re-tuning
-- tolerance / conditioning.
local VIOLATION_QUAD = 2 ^ 11 -- L2 norm curvature, scaled with L2_RECIPE_EPS (was 2)
local VIOLATION_FLOOR = 2 ^ -8 -- elastic-net linear floor on the violation elastics (> sqrt(mu))
local L2_RECIPE_EPS = 2 ^ -10
-- L2 two-stage violation lock (M.l2_lock_step). The single weighted L2
-- objective trades the recipe tier against the violation quad at the finite
-- rate eps*M (M = machines per product unit), so on machine-heavy chains the
-- machine tier BUYS violation: the crossover eps*M/quad reaches ~0.05/s at
-- M ~ 1e5 machines per unit/s (pyanodon scale -- the PyBlock guar report had
-- 11% of an Exact target imported). That breaks the problem definition's
-- V >> M lexicography, so the L2 norms solve in two stages: stage 1 measures
-- the violation optimum with the recipe tier dropped to a pure face
-- regularizer (the target_rescue_epsilon precedent -- it only bounds futile
-- cycles for the IPM, and cycles are violation-neutral so the measured caps
-- are unaffected by its mushy enforcement), then stage 2 re-solves at ship
-- costs with each violation GROUP capped at its measured optimum + margin
-- (create_problem.plan_violation_locks / apply_violation_locks). Corpus A/B
-- (tests/research/probe_l2_twostage.lua, all 1678 explorer dumps, 2026-07-08):
-- every stage converged, ~2x solve cost, violations dropped to the stage-1
-- optimum wherever the single stage had bought them (297 problems >10%
-- better), targets unmoved (max drift 1.6e-5 = tolerance noise); the only
-- "regressions" were violation columns parking at the abs margin floor.
-- Margins mirror the rescue budget (IPM relative residual + abs floor when
-- the optimum is 0).
local L2_STAGE1_EPS = 2 ^ -20
local l2_lock_rel, l2_lock_abs = 1e-3, 1e-6
-- L-infinity capped-stage peak budget: relative slack for the IPM's relative
-- residual plus an absolute floor when the peak is 0 (the target-rescue values).
local linf_budget_rel, linf_budget_abs = 1e-3, 1e-6

-- Lexicographic target rescue (M.target_rescue_step). The single weighted LP
-- trades the target against violations at the finite exchange rate
-- target_cost / elastic_cost = 2^10, so a target whose chain forces more than
-- 1024 violation units per target unit is rationally abandoned -- and since
-- the trade is linear it is all-or-nothing (the all-zero collapse; 30/1678
-- explorer corpus problems, the identical set under the hard and the soft
-- gate). The rescue restores the problem definition's tier-1 absolutism (a
-- reachable target is met no matter the violation bill) with two extra
-- solves, paid only when the baseline actually relaxed a target: stage 1
-- re-solves with a target-only objective (-> T_min, the least violation the
-- build can structurally reach), then sum(elastic) <= budget(T_min) rides
-- every later build as a hard row. Validated corpus-wide by
-- tests/research/probe_target_rescue.lua: tier-1 losses 30 -> 0 under the
-- soft gate (30 -> 2 under the legacy hard gate; those 2 are structural --
-- the gate denied an escape the chain needs, so stage 1 itself cannot reach
-- the target and the rescue correctly restores the baseline).
local target_rescue_trigger = 1e-6
-- Budget margin over the stage-1 optimum: relative slack for the IPM's
-- relative-residual convergence plus an absolute floor when T_min = 0. Same
-- values as the reference solver's stage budgets.
local target_budget_rel, target_budget_abs = 1e-3, 1e-6

-- Sparse elastic placement (solver_norm "batch" / "smart"; see
-- solver/placement.lua and M.placement_step). Both norms first solve the
-- all-elastic L2 base (the guard reference), then re-solve the L2 restricted
-- to a sparse placement -- measured by Phase-I feasibility solves ("batch",
-- research probe_batch_iis.lua: mean 2.2 Phase-I solves, activation -52%) or
-- derived statically from the necessity law ("smart",
-- probe_scc_compress.lua/probe_law_fix.lua: no extra solves, -30%). The guard
-- compares the restricted solve's PHYSICAL import+dump total against the
-- base's and widens the placement while the ratio exceeds PLACEMENT_GUARD
-- (research: a sparse set placed away from the true imbalance amplifies
-- physically through stoichiometric chains -- up to 430x unguarded; the
-- guarded corpus runs end with 0 failures at max ratio 1.5). Constants match
-- the corpus-validated probes.
local PLACEMENT_GUARD = 1.5 -- accepted physical inflation over the base solve
local PLACEMENT_ADDK = 6 -- groups added per rank-widening round
local PLACEMENT_MAX_ROUNDS = 4 -- guard widening rounds before standing / restoring
local PLACEMENT_MAX_P1 = 12 -- Phase-I iteration backstop (corpus max: 4)
local placement_art_tol = 1e-3 -- Phase-I "feasible" threshold on the summed artificials
local placement_support_tol = 1e-4 -- per-row artificial support threshold

-- Proportional row reduction: fold provably surplus-free producer/consumer
-- doubletons out of the LP before the IPM solves it, then reconstruct the
-- eliminated variables. The IPM works on the smaller reduced problem; the full
-- problem stays the canonical variable space that filter_result / diagnose /
-- report read. Flip to false to solve the full problem directly (immediate
-- rollback to the pre-substitution behaviour). See solver/substitution.lua.
local substitution_enabled = true

local M = {}

---comment
---@return ForceLocalData?
---@return Solution?
function M.find_the_need_for_solve()
    for _, force in pairs(game.forces) do
        local force_data = storage.forces[force.index]
        if not force_data then
            goto continue
        end

        for _, solution in pairs(force_data.solutions) do
            if solution.solver_state == "calculating" or solution.solver_state == "ready" then
                return force_data, solution
            end
        end

        ::continue::
    end
    return nil, nil
end

---comment
---@param force_data ForceLocalData
---@param solution Solution
function M.forwerd_solve(force_data, solution)
    local bonuses = force_data.research_bonuses

    -- Normalized lines are needed by create_problem on a "ready" rebuild and by
    -- the two-pass diagnose below. Compute lazily and share the result so a tick
    -- that does both never normalizes twice.
    local normalized = nil
    local function get_normalized()
        if not normalized then
            normalized = M.to_normalized_production_lines(solution.production_lines, bonuses)
        end
        return normalized
    end

    if solution.solver_state == "ready" then
        -- A fresh "ready" (edit / migration / new solution) drops in-flight
        -- target-rescue state so the next solve restarts from a clean baseline.
        -- The rescue's own restarts set tr_restart; the downstream loops'
        -- restarts (op_restart / reclassify_pending / cc_restart / lf_restart /
        -- lc_restart) keep the settled budget so their re-solves stay locked on
        -- the rescued target. lf_restart in particular must preserve the "done"
        -- sentinel: dropping it made target_rescue_step re-measure the min-max /
        -- capped solutions and re-arm stage 1 mid-linf, destroying solution.linf
        -- and livelocking rescue<->linf on any problem where the rescue fires.
        -- lc_restart likewise keeps the compress re-solve locked on the rescued
        -- target (an unlocked channel deletion can trade the target away past
        -- the 2^10 exchange-rate ceiling). ll_restart (the L2 two-stage lock)
        -- sits here for the same reason: the locked stage-2 build must carry
        -- the rescued budget, and target_rescue_step's "done" sentinel must
        -- survive the stage rebuild or it re-arms stage 1 mid-pipeline (the
        -- linf livelock class).
        if not (solution.tr_restart or solution.op_restart or solution.reclassify_pending
                or solution.cc_restart or solution.lf_restart or solution.lc_restart
                or solution.ll_restart or solution.pm_restart) then
            solution.target_rescue = nil
        end
        solution.tr_restart = nil

        local norm = solution.solver_norm or "legacy"
        local options = nil
        -- The cascade build in flight this tick (nil = the un-gated baseline).
        -- A cascade build is shaped after create_problem and skips the
        -- substitution fold (its objective is overwritten). Set only on the
        -- retained "cascade" norm.
        local cc_build = nil
        -- The L-infinity stage shaping this build (nil unless norm == "linf").
        local linf_stage = nil
        -- Whether to apply the L2 cost shaping after construction (norm == "l2").
        local apply_l2 = false
        -- Whether to shape this build into the sparse-placement Phase-I
        -- feasibility LP (norm == "batch", placement phase "phase1").
        local phase1_shape = false
        if norm == "cascade" then
            -- Retained (UI-hidden) staged rescue: un-gated baseline, then the
            -- cascade (M.cascade_step) owns every later build. A fresh "ready"
            -- drops in-flight cascade state; the loop's OWN restart keeps it.
            if not solution.cc_restart then solution.cascade = nil end
            solution.cc_restart = nil
            solution.observe_price = nil
            solution.forced_imports = nil
            solution.reclassify_pending = nil
            solution.linf = nil
            solution.lf_restart = nil
            solution.l2_compress = nil
            solution.lc_restart = nil
            solution.l2_lock = nil
            solution.ll_restart = nil
            solution.placement = nil
            solution.pm_restart = nil

            local cc = solution.cascade
            if cc and cc.build then
                cc_build = cc.build
                options = cascade.build_options(cc_build)
            else
                -- The baseline: the PLAIN problem -- un-gated and with no
                -- cycle-entry seeding -- matching the reference the cascade
                -- approximates. The cascade's stages, not a gate or seeding, do
                -- the rescue work. (Earlier this named only reachability_gating
                -- and silently inherited the gated deficit / catalyst seeding
                -- from create_problem's old default -- a bug, now stated in full.)
                options = {
                    reachability_gating = false,
                    deficit_seeding = false,
                    catalyst_closure = false,
                }
            end
        else
            -- The five shipping norms share the un-gated baseline; clear the
            -- retained loops' in-flight state so a switch INTO one of these
            -- starts clean.
            solution.cascade = nil
            solution.cc_restart = nil
            solution.observe_price = nil
            solution.op_restart = nil

            -- l1 / l2 / l2_baseline / linf are FULLY un-gated: every
            -- create_problem gate and cycle-entry heuristic is explicitly OFF
            -- (only legacy turns them on).
            -- Stated in full so the dispatch reads the whole option set, not the
            -- create_problem defaults.
            if norm == "l1" then
                solution.forced_imports = nil
                solution.reclassify_pending = nil
                solution.linf = nil
                solution.lf_restart = nil
                solution.l2_compress = nil
                solution.lc_restart = nil
                solution.l2_lock = nil
                solution.ll_restart = nil
                solution.placement = nil
                solution.pm_restart = nil
                options = {
                    reachability_gating = false,
                    deficit_seeding = false,
                    catalyst_closure = false,
                    surplus_sink_gating = false,
                }
            elseif norm == "l2" then
                solution.forced_imports = nil
                solution.reclassify_pending = nil
                solution.linf = nil
                solution.lf_restart = nil
                solution.placement = nil
                solution.pm_restart = nil
                -- A fresh "ready" (edit / norm switch) drops the in-flight mode
                -- compression; the compress step's OWN restart (lc_restart)
                -- keeps it so this rebuild omits the folded channels. lc_restart
                -- also rode the target-rescue preserve list above: the compress
                -- build must stay locked on the rescued target (deleting a
                -- spreading channel raises the survivors' quadratic marginal
                -- cost, and an unlocked re-solve can rationally trade the
                -- target away past the 2^10 exchange-rate ceiling).
                if not solution.lc_restart then solution.l2_compress = nil end
                -- The two-stage violation lock: the stage's OWN restart
                -- (ll_restart) keeps it, and so does the compress restart --
                -- the compressed rebuild re-applies the group locks below, or
                -- the fold would re-open the eps-vs-quad trade the lock closed.
                if not (solution.ll_restart or solution.lc_restart) then
                    solution.l2_lock = nil
                end
                solution.ll_restart = nil
                solution.lc_restart = nil
                -- L2: un-gated, shaped by shape_l2 below (violation quad +
                -- linear floor), solved in two stages (M.l2_lock_step). The
                -- FIRST build (no l2_lock state yet) is the violation
                -- measurement: its recipe tier drops to a pure face
                -- regularizer so eps*M cannot buy violation (see
                -- L2_STAGE1_EPS). Every later build runs at the ship tier --
                -- raised to clear the purify zero-floor sqrt(mu) (see
                -- L2_RECIPE_EPS) -- with the measured group caps re-applied.
                options = {
                    reachability_gating = false,
                    deficit_seeding = false,
                    catalyst_closure = false,
                    surplus_sink_gating = false,
                    recipe_epsilon = solution.l2_lock and L2_RECIPE_EPS or L2_STAGE1_EPS,
                }
                -- The compressed rebuild: omit the sibling channels the plan
                -- folded away (import losers via hatch_exclude, dump losers via
                -- sink_exclude). The QP handoff cold-starts this solve on its
                -- own (linear_programming.qp_warm_strategy = "cold").
                local lc = solution.l2_compress
                if lc and lc.phase == "compress" then
                    options.hatch_exclude = lc.hatch
                    options.sink_exclude = lc.sink
                end
                apply_l2 = true
            elseif norm == "l2_baseline" then
                -- L2 baseline: the identical QP shaping and two-stage
                -- violation lock as "l2" (same un-gated options, same staged
                -- recipe_epsilon, same shape_l2 + lock application below) but
                -- the mode-compression fold never runs -- l2_compress stays
                -- permanently nil so the UI can show this side by side with
                -- "l2" to see what the fold changed.
                solution.forced_imports = nil
                solution.reclassify_pending = nil
                solution.linf = nil
                solution.lf_restart = nil
                solution.l2_compress = nil
                solution.lc_restart = nil
                solution.placement = nil
                solution.pm_restart = nil
                if not solution.ll_restart then solution.l2_lock = nil end
                solution.ll_restart = nil
                options = {
                    reachability_gating = false,
                    deficit_seeding = false,
                    catalyst_closure = false,
                    surplus_sink_gating = false,
                    recipe_epsilon = solution.l2_lock and L2_RECIPE_EPS or L2_STAGE1_EPS,
                }
                apply_l2 = true
            elseif norm == "linf" then
                solution.forced_imports = nil
                solution.reclassify_pending = nil
                -- A fresh "ready" drops the in-flight L-infinity state; the
                -- stage's OWN restart (lf_restart) keeps it so the rebuild stays
                -- on the same stage.
                if not solution.lf_restart then solution.linf = nil end
                solution.lf_restart = nil
                solution.l2_compress = nil
                solution.lc_restart = nil
                solution.l2_lock = nil
                solution.ll_restart = nil
                solution.placement = nil
                solution.pm_restart = nil
                options = {
                    reachability_gating = false,
                    deficit_seeding = false,
                    catalyst_closure = false,
                    surplus_sink_gating = false,
                }
                linf_stage = solution.linf and solution.linf.phase or nil
                -- Thread the settled target budget (M.linf_step's t_limit) into
                -- both min-max stages, so meeting the targets stays tier-1 above
                -- the peak / capped objectives. Load-bearing on the capped stage:
                -- it re-costs the violations back to the L1 elastic_cost, so
                -- without the budget row it re-enters the baseline's collapse
                -- economics (target_cost / elastic_cost = 1024) and abandons the
                -- very target the rescue just restored. Matches the corpus-
                -- validated probe (tests/research/probe_linf_ship.lua) and the
                -- lp_solver_norms fixtures, which both carry target_budget on
                -- the minmax AND capped builds.
                if solution.linf and solution.linf.t_limit then
                    options.target_budget = solution.linf.t_limit
                end
            elseif norm == "batch" or norm == "smart" then
                solution.forced_imports = nil
                solution.reclassify_pending = nil
                solution.linf = nil
                solution.lf_restart = nil
                solution.l2_compress = nil
                solution.lc_restart = nil
                solution.l2_lock = nil
                solution.ll_restart = nil
                -- A fresh "ready" (edit / norm switch) drops the in-flight
                -- placement; the step's OWN restart (pm_restart) keeps it so
                -- the rebuild stays on the same phase. pm_restart also rides
                -- the target-rescue preserve list above (the linf livelock
                -- class): every placement build must keep the rescued budget.
                if not solution.pm_restart then solution.placement = nil end
                solution.pm_restart = nil
                -- Sparse placement: the same un-gated baseline as "l2". The
                -- FIRST build (no placement state yet) is the all-elastic L2
                -- base -- the guard's physical reference. Later builds carry
                -- the placement exclusions: the Phase-I feasibility LP
                -- ("batch" only; shaped below) or the restricted L2.
                options = {
                    reachability_gating = false,
                    deficit_seeding = false,
                    catalyst_closure = false,
                    surplus_sink_gating = false,
                    recipe_epsilon = L2_RECIPE_EPS,
                }
                local pm = solution.placement
                if pm and (pm.phase == "phase1" or pm.phase == "restricted") then
                    options.hatch_exclude, options.sink_exclude =
                        placement.excludes(pm.groups, pm.placed)
                    -- Thread the settled target budget (the linf t_limit move)
                    -- into every placement build: the Phase-I must measure the
                    -- material imbalance GIVEN the targets stay met (or the
                    -- collapse economics relax them and the support names
                    -- nothing), and the restricted L2 must not trade a target
                    -- away when the sparse placement makes it expensive. The
                    -- generic rescue threading below overwrites this with the
                    -- rescue's own budget when one settled -- the same value
                    -- pm.t_limit was seeded from.
                    if pm.t_limit then
                        options.target_budget = pm.t_limit
                    end
                end
                if pm and pm.phase == "phase1" then
                    phase1_shape = true
                else
                    apply_l2 = true
                end
            else
                -- "legacy": the original gated solver -- the hard reachability
                -- gate plus deficit / catalyst cycle-entry seeding and the
                -- two-pass diagnose. surplus_sink_gating stays OFF: it breaks IPM
                -- convergence on the Fulgora recycling problems (and legacy is the
                -- default norm), matching the create_problem doc that ships it off.
                -- A fresh "ready" drops forced imports left from a previous
                -- reclassify pass; the two-pass restart sets reclassify_pending.
                if not solution.reclassify_pending then
                    solution.forced_imports = nil
                end
                solution.reclassify_pending = nil
                solution.linf = nil
                solution.lf_restart = nil
                solution.l2_compress = nil
                solution.lc_restart = nil
                solution.l2_lock = nil
                solution.ll_restart = nil
                solution.placement = nil
                solution.pm_restart = nil
                options = {
                    reachability_gating = true,
                    deficit_seeding = true,
                    catalyst_closure = true,
                    surplus_sink_gating = false,
                }
            end
        end

        -- Target-rescue build shaping (config-independent; see
        -- M.target_rescue_step): stage 1 measures T_min with a target-only
        -- objective; once the budget is locked, EVERY later rebuild (observe /
        -- verify / two-pass restarts included) carries the budget row so no
        -- re-solve can fall back into the target collapse. Skipped for a
        -- cascade build: the rescue settles BEFORE the cascade begins, and the
        -- cascade's own builds carry the target budget through build_options.
        if not cc_build then
            local rescue = solution.target_rescue
            if rescue and rescue.phase == "stage1" then
                options = options or {}
                options.target_only_objective = true
            elseif rescue and rescue.budget then
                options = options or {}
                options.target_budget = rescue.budget
            end
        end

        solution.problem = create_problem.create_problem(
            solution.name,
            solution.constraints,
            get_normalized(),
            solution.forced_imports,
            options
        )

        -- A cascade stage build shapes the problem after construction: cost
        -- overrides (stage objective / fix-test prices) plus the budget-lock
        -- and synthetic-demand rows. See solver/cascade.lua M.shape_problem.
        if cc_build then
            cascade.shape_problem(solution.problem, cc_build)
        elseif apply_l2 and not options.target_only_objective then
            -- L2 ("balanced"): violation elastics -> quadratic + a small linear
            -- floor (the elastic-net admixture that lets purify reach 0), ports free.
            -- NOT applied to the target-rescue stage-1 build: target_only_objective
            -- re-costs every non-target column to a measurement epsilon, and
            -- re-quadding the violations on top of it made stage 1 pay the full
            -- violation bill -- so on a collapse problem (surplus >> the
            -- target's linear worth) stage 1 collapsed too, measured "no
            -- headroom", and the rescue silently restored the collapsed
            -- baseline. Stage 1 must stay the pure target-only LP the other
            -- norms measure with (caught by lp_l2_state_machine's rescue case).
            create_problem.shape_l2(solution.problem, VIOLATION_QUAD, VIOLATION_FLOOR)
            -- Stage 2 (and every later l2 rebuild, the compress re-solve
            -- included): cap each violation group at its measured stage-1
            -- optimum. The fallback build carries no caps (l2_lock.caps nil).
            local ll = solution.l2_lock
            if ll and ll.caps then
                create_problem.apply_violation_locks(solution.problem, ll.caps)
            end
        elseif linf_stage == "minmax" then
            -- L-infinity stage 1: re-cost to min-max (add the peak primal + cap
            -- rows). See create_problem.shape_minmax / M.linf_step.
            create_problem.shape_minmax(solution.problem, "minmax", nil)
        elseif linf_stage == "capped" then
            -- L-infinity stage 2: cap the peak at the locked t_budget and keep
            -- the build's normal L1 costs.
            create_problem.shape_minmax(solution.problem, "capped", solution.linf.t_budget)
        elseif phase1_shape then
            -- Sparse-placement Phase-I ("batch"): every cost to 0, a ±
            -- artificial pair on every row. The art keys are held on the
            -- placement state so the step can read the support back.
            solution.placement.arts = placement.shape_phase1(solution.problem)
        end
        -- Mirror the inactive-recipe set onto the solution so save / UI lookups
        -- (which see solution, not problem) can gray out isolated lines without
        -- reaching through solution.problem (which is nil after migrations).
        solution.inactive_recipe_variables = solution.problem.inactive_recipe_variables

        -- Fold proportional doubletons out once per "ready" rebuild. The reduced
        -- problem (and its reconstruction map) ride on solution.problem so they
        -- persist across the per-tick "calculating" IPM steps; the IPM never
        -- re-reduces. Stored as plain tables -- the reduced Problem gets its
        -- metatable re-attached on load alongside solution.problem (see
        -- manage/save.lua resetup_force_data_metatable).
        -- Cascade stage builds are folded too. The fold runs AFTER shape_problem,
        -- so it conserves the OVERRIDDEN stage cost (escape-singleton cost folds
        -- onto the kept recipe; surplus_sink and the lock-row escapes are
        -- multi-row and never folded), and the unfold below reconstructs the
        -- priced-escape values the cascade reads back. Measured (FS_SUBST in
        -- tests/research/probe_cascade_ship.lua): 3.5x wall-clock on the pyanodon
        -- slice with bit-identical reference grading; the SA30 buckets stayed
        -- inside the off-vs-off degenerate-face noise band (two un-folded runs
        -- already varied tie 349<->343). The earlier worry that folding would
        -- corrupt the stage objective was wrong -- reduce reads the live
        -- (overridden) cost, not the original.
        -- Classification fix-test builds (cascade.is_cold) are NOT folded: their
        -- verdict reads which priced escape still flows -- a degenerate-vertex read
        -- -- and the fold shifts that vertex onto a different reduced structure than
        -- the full, canonicalized problem the headless drivers validate the verdict
        -- on. Folding here reintroduced the engine-only producibility misclassification
        -- (Asteroid up-cycling: a non-producible import read as producible -> wrong
        -- Vp lock -> polish pinned at M=258 vs the reachable 221) because the reduced
        -- problem is solved with its own build-order column layout, bypassing
        -- ensure_canonical on the full problem. The heavy stage / final / polish
        -- builds still fold (the 3.5x speedup is theirs; their objective is the
        -- machine count, not a vertex-read verdict).
        -- The L-infinity shaped builds are not folded: shape_minmax adds the
        -- peak primal and one cap row per violation after construction, so the
        -- violation columns are multi-row and the simple doubleton fold would
        -- not match the post-shape structure cleanly. linf is opt-in and only
        -- two solves, so skipping the fold costs little.
        -- The L2 / L-infinity shaped builds are not folded: shape_l2 puts a
        -- quadratic on the (singleton) violation escapes and shape_minmax adds
        -- cap rows, so the doubleton fold (which folds singleton escapes onto a
        -- recipe) would drop the quad / not match the post-shape structure.
        -- The Phase-I build is not folded either: the artificial columns sit
        -- on every row, so no escape is a singleton the doubleton fold could
        -- take, and the build is a cheap one-shot LP anyway.
        local fold = substitution_enabled
            and not (cc_build and cascade.is_cold(cc_build))
            and linf_stage == nil
            and not apply_l2
            and not phase1_shape
        if fold then
            local reduced, reconstruction = substitution.reduce(solution.problem)
            solution.problem.reduced = reduced
            solution.problem.reconstruction = reconstruction
        else
            solution.problem.reduced = nil
            solution.problem.reconstruction = nil
        end
        -- raw_variables intentionally preserved across re-prepares: constraint
        -- and line edits change b (and sometimes the variable set), but recipe
        -- x values from the previous converged solve are near the new optimum
        -- and let the IPM warm-start instead of restarting from the default.
        -- make_primal_variables falls back to the default for keys missing from
        -- prev_x, so added/removed lines are handled automatically.
    end

    local problem = assert(solution.problem)

    -- Solve the reduced problem when one was built; otherwise the full problem.
    -- solution.raw_variables is kept in FULL variable-key space: the reduced
    -- problem's keys are a subset of the full keys, so make_*_variables warm-
    -- starts straight from it (the eliminated keys are simply ignored), and
    -- unfold() turns the reduced result back into full space (filling each
    -- eliminated x via x_elim = k * x_rep) so filter_result / diagnose / report
    -- below all see the complete variable set.
    local solve_problem = problem.reduced or problem
    local state, iteration, raw = linear_programming.solve(
        solve_problem,
        solution.solver_state,
        solution.solver_iteration,
        solution.raw_variables,
        acc.tolerance,
        iterate_limit
    )
    solution.solver_state = state
    solution.solver_iteration = iteration
    if problem.reconstruction then
        solution.raw_variables = substitution.unfold(raw, problem.reconstruction)
    else
        solution.raw_variables = raw
    end

    solution.quantity_of_machines_required = problem:filter_result(solution.raw_variables)

    -- The lexicographic target rescue sits between the baseline and either
    -- downstream loop: while it has a solve in flight (stage 1 / budget
    -- re-solve / restore) the loops below wait for the rescued baseline.
    if solution.solver_state == "finished" and M.target_rescue_step(solution) then
        return
    end

    local norm = solution.solver_norm or "legacy"
    if norm == "cascade" then
        -- The retained (UI-hidden) cascade staged rescue. Each stage is a full
        -- incremental solve; advancing it sets solver_state="ready" + cc_restart
        -- so the rebuild above stays on the same cascade build. Driven on ANY
        -- terminal state, not just "finished": a stage CAN diverge (the
        -- deletion-final / staged-relay fallbacks exist for exactly that), so
        -- cascade_step must run to advance the fallback chain rather than stall.
        local st = solution.solver_state
        if st ~= "ready" and st ~= "calculating" then
            M.cascade_step(solution, get_normalized())
        end
    elseif norm == "linf" then
        -- L-infinity two-stage min-max. Each stage is a full incremental solve;
        -- advancing it sets solver_state="ready" + lf_restart so the rebuild
        -- above stays on the same stage. See M.linf_step.
        if solution.solver_state == "finished" then
            M.linf_step(solution)
        end
    elseif norm == "l2" or norm == "l2_baseline" then
        -- L2 pipeline: the two-stage violation lock settles first (measurement
        -- solve -> group-capped ship re-solve; see M.l2_lock_step), then -- on
        -- the "l2" norm only -- the mode compression folds sibling channels
        -- and re-solves under the same caps. Both are driven on ANY terminal
        -- state, not just "finished": a non-finished stage must advance to its
        -- fallback / baseline restore rather than stall.
        local st = solution.solver_state
        if st ~= "ready" and st ~= "calculating" then
            if M.l2_lock_step(solution) then
                return
            end
            if norm == "l2" then
                M.l2_compress_step(solution)
            end
        end
    elseif norm == "batch" or norm == "smart" then
        -- Sparse elastic placement (base -> [Phase-I loop] -> restricted +
        -- guard). Driven on ANY terminal state: a non-finished stage must
        -- advance to its widening / restore fallback rather than stall.
        local st = solution.solver_state
        if st ~= "ready" and st ~= "calculating" then
            M.placement_step(solution, norm, get_normalized())
        end
    elseif norm == "legacy" then
        -- Legacy two-pass diagnose-then-reclassify. When the FIRST pass
        -- converges, re-seed every avoidable export-feasible cheat as a forced
        -- import and restart once, warm-started. forced_imports is nil through
        -- pass 1 so this fires exactly once per solve cycle.
        if solution.solver_state == "finished"
            and solution.forced_imports == nil
            and solution.raw_variables
            and solution.problem then
            local avoidable = create_problem.diagnose_avoidable_cheats(
                solution.raw_variables.x, solution.problem.primals, get_normalized())
            if next(avoidable) ~= nil then
                solution.forced_imports = avoidable
                solution.reclassify_pending = true
                solution.solver_state = "ready"
                solution.solver_iteration = nil
                -- raw_variables kept as the pass-2 warm start.
            end
        end
    end
    -- "l1": the baseline (plus the target rescue above) is the answer; no
    -- downstream loop.
end

---Advance the L2 two-stage violation lock one step after a terminal solve
---(solver_norm == "l2" / "l2_baseline"). The target rescue settles first
---(targets are tier-1); then:
---  measurement finished (no l2_lock state yet; the build ran at
---    L2_STAGE1_EPS) -> measure the per-group violation caps off its optimum
---    (create_problem.plan_violation_locks) and arm the "locked" re-solve at
---    ship costs; the caps ride every later l2 rebuild.
---  "locked" finished -> the answer stands ("done"); the caps stay on the
---    settled state so the mode-compression re-solve rebuilds under them.
---  measurement or "locked" NOT finished (diverged / iterate limit) -> arm
---    "fallback": a plain ship-cost re-solve with no caps -- exactly the
---    pre-two-stage single solve -- rather than standing on a failed stage or
---    on the measurement's non-ship epsilon. Convergence robustness only: no
---    corpus problem needed it (1678/1678 stages converged, see L2_STAGE1_EPS).
---  "fallback" terminal -> whatever it reached stands ("done").
---Mutates solution.l2_lock and, when another solve is needed, re-arms
---solver_state="ready" with ll_restart set so the rebuild keeps the lock state
---AND the settled target rescue (ll_restart sits in both preserve lists; see
---the linf livelock note on the rescue preserve condition).
---Returns true while a lock-stage solve is in flight, so the caller defers the
---mode compression to the locked answer.
---@param solution Solution
---@return boolean restarted
function M.l2_lock_step(solution)
    if not solution.problem then return false end
    local ll = solution.l2_lock
    if ll and ll.phase == "done" then return false end

    local function restart()
        solution.ll_restart = true
        solution.solver_state = "ready"
        solution.solver_iteration = nil
        -- solution.raw_variables stays as-is: the QP handoff discards the warm
        -- seed on its own (linear_programming.qp_warm_strategy = "cold").
    end

    if not ll then
        -- The measurement build just terminated.
        if solution.solver_state ~= "finished" or not solution.raw_variables then
            solution.l2_lock = { phase = "fallback" }
            restart()
            return true
        end
        solution.l2_lock = {
            phase = "locked",
            caps = create_problem.plan_violation_locks(
                solution.problem, solution.raw_variables.x, l2_lock_rel, l2_lock_abs),
        }
        restart()
        return true
    elseif ll.phase == "locked" then
        if solution.solver_state ~= "finished" then
            ll.phase = "fallback"
            ll.caps = nil
            restart()
            return true
        end
        ll.phase = "done"
        return false
    end
    -- "fallback" just terminated: whatever state it reached stands.
    ll.phase = "done"
    return false
end

---Advance the lexicographic target rescue one step after a finished solve.
---Phases: a baseline that finished with active target relaxation arms
---"stage1" (re-solve with create_problem's target_only_objective); stage 1
---finished locks the budget and arms "resolve" (re-solve at ship costs under
---it), or "restore" (plain re-solve) when stage 1 found no headroom -- the
---stage-1 answer itself must never stand, its costs are not the ship's.
---Mutates solution.target_rescue and, when another solve is needed, re-arms
---solver_state="ready" with tr_restart set so the rebuild keeps the state.
---Returns true while a rescue solve is in flight, so the caller defers the
---downstream loops (observe-price / two-pass) to the rescued baseline.
---@param solution Solution
---@return boolean restarted
function M.target_rescue_step(solution)
    if not solution.raw_variables or not solution.problem then return false end
    local rescue = solution.target_rescue
    if rescue and rescue.phase == "done" then return false end
    local primals = solution.problem.primals
    local x = solution.raw_variables.x

    local function restart()
        solution.tr_restart = true
        solution.solver_state = "ready"
        solution.solver_iteration = nil
    end

    if not rescue then
        -- The baseline just finished. No active target relaxation: park a
        -- "done" sentinel so later finishes in this solve cycle skip the check.
        local t0 = observe_price.target_relax(primals, x)
        if t0 <= target_rescue_trigger then
            solution.target_rescue = { phase = "done" }
            return false
        end
        solution.target_rescue = { phase = "stage1", t0 = t0 }
        restart()
        return true
    elseif rescue.phase == "stage1" then
        local t_min = observe_price.target_relax(primals, x)
        if t_min < rescue.t0 - target_rescue_trigger then
            rescue.budget = t_min * (1 + target_budget_rel) + target_budget_abs
            rescue.phase = "resolve"
        else
            -- No headroom: the target really is this far unreachable (e.g. the
            -- hard gate denied an escape the chain needs). Re-solve plain to
            -- restore the baseline answer.
            rescue.phase = "restore"
        end
        restart()
        return true
    end
    -- "resolve" / "restore" just finished: the rescued (or restored) baseline
    -- stands and the downstream loops may proceed on it this tick.
    rescue.phase = "done"
    return false
end

---Advance the L-infinity ("leveled") two-stage min-max one step after a finished
---solve (solver_norm == "linf"). The target rescue settles first (targets are
---tier-1); then:
---  baseline finished -> arm "minmax" (re-solve under create_problem.shape_minmax
---    "minmax", which minimizes the peak violation t). The settled target budget
---    (t_limit) threads into BOTH stage builds as create_problem's target_budget
---    row, so the min-max and capped solves keep the targets met.
---  "minmax" finished -> read the least peak t_min, lock t_budget = t_min + margin,
---    arm "capped" (re-solve minimizing total violation under t <= t_budget).
---  "capped" finished -> the leveled answer stands.
---Mutates solution.linf and, when another solve is needed, re-arms
---solver_state="ready" with lf_restart set so the rebuild keeps the stage (AND
---the settled target_rescue -- lf_restart sits in the rebuild's preserve list,
---which both threads the rescued budget and keeps target_rescue_step's "done"
---sentinel alive so it cannot re-arm stage 1 mid-linf).
---@param solution Solution
function M.linf_step(solution)
    if not solution.raw_variables or not solution.problem then return end
    local linf = solution.linf
    if linf and linf.phase == "done" then return end

    -- Each L-infinity stage is solved COLD -- the warm seed (the prior stage's
    -- solution.raw_variables) is dropped so the IPM restarts from the cold
    -- Mehrotra central path. Same rationale as the cascade (M.arm_cascade_build):
    -- the min-max and capped builds carry a DIFFERENT objective than the build
    -- they follow (the baseline's L1 cost, then the min-max peak cost), so the
    -- previous stage's optimum is a boundary point OFF this build's central path,
    -- and warm-starting an interior-point method from it walks the duality measure
    -- the wrong way. Measured on the explorer corpus: warm-starting the min-max
    -- stage diverged (mu climbing, a free import column running to ~4e11, hitting
    -- the iterate limit) on seed_121 / seed_131 tnetneg cycles -- and did so only
    -- under the pairs-order one headless VM happened to assemble the LP in, so it
    -- read as a flaky 2/1678 non-convergence. Cold-starting converges them in
    -- 23-25 iterations, identically across VMs, AND is faster than the warm solves
    -- that did limp through (32-34 iterations). The baseline + target-rescue
    -- stages are NOT cold-started here (they run before linf_step and keep their
    -- iteration-saving warm-start; they share the L1 objective across edits).
    local function restart()
        solution.lf_restart = true
        solution.solver_state = "ready"
        solution.solver_iteration = nil
        solution.raw_variables = nil
    end

    if not linf then
        -- The baseline (target-rescued) just finished. Arm the min-max stage,
        -- threading the settled target budget. When no rescue fired (or it
        -- restored with no headroom), lock the stages at the baseline's own
        -- achieved relaxation instead -- the cascade's `rescue_budget or
        -- M.budget(T)` move (solver/cascade.lua begin) -- so the capped stage's
        -- return to L1 costs can never shed the target below what the baseline
        -- held (target_cost / elastic_cost caps out at 1024 violation units
        -- per target unit, the same collapse economics the rescue exists for).
        local t_limit = solution.target_rescue and solution.target_rescue.budget
        if not t_limit then
            local t0 = observe_price.target_relax(solution.problem.primals, solution.raw_variables.x)
            t_limit = t0 * (1 + target_budget_rel) + target_budget_abs
        end
        solution.linf = { phase = "minmax", t_limit = t_limit }
        restart()
    elseif linf.phase == "minmax" then
        -- The peak primal's value is the least achievable peak violation; lock it
        -- (with the IPM relative-residual margin) and re-solve under the cap.
        local t_min = math.abs(solution.raw_variables.x[vk.linf_peak()] or 0)
        linf.t_budget = t_min * (1 + linf_budget_rel) + linf_budget_abs
        linf.phase = "capped"
        restart()
    else
        -- "capped" just finished: the leveled solution stands.
        linf.phase = "done"
    end
end

---Advance the L2 mode compression one step after a terminal solve
---(solver_norm == "l2"). The target rescue settles first; then:
---  baseline finished -> plan the fold (solver/mode_compress.lua: group the
---    active violation channels by base material AND kind, keep each group's
---    max-flow winner). Nothing to fold -> "done" at zero extra cost. Otherwise
---    hold the baseline answer aside and arm the "compress" re-solve, whose
---    rebuild omits the folded channels (hatch_exclude / sink_exclude).
---  "compress" finished -> the compressed answer stands.
---  "compress" NOT finished (diverged / unbounded / iterate limit) -> restore
---    the held baseline verbatim -- problem, raw variables, machine counts --
---    with no third solve. This is convergence robustness only, NOT a quality
---    gate: no corpus problem needed it (1676/1676 compress solves converged),
---    and no in-code verdict judges the compressed answer's quality (verify-
---    gate thresholds are unvalidated, so none ship).
---Mutates solution.l2_compress and, when the compress solve is needed, re-arms
---solver_state="ready" with lc_restart set so the rebuild keeps the compress
---state and the settled target rescue.
---@param solution Solution
function M.l2_compress_step(solution)
    if not solution.problem then return end
    local lc = solution.l2_compress
    if lc and lc.phase == "done" then return end

    if not lc then
        -- The baseline (target-rescued) just terminated. If it failed, leave
        -- the terminal state for the UI -- there is nothing to compress.
        if solution.solver_state ~= "finished" or not solution.raw_variables then
            solution.l2_compress = { phase = "done" }
            return
        end
        local plan = mode_compress.plan(solution.problem, solution.raw_variables.x)
        if not plan then
            solution.l2_compress = { phase = "done" }
            return
        end
        solution.l2_compress = {
            phase = "compress",
            hatch = plan.hatch,
            sink = plan.sink,
            -- Hold the finished baseline so a non-finished compress solve
            -- restores it without solving again. The problem rides storage as
            -- plain tables; manage/save.lua re-attaches its metatable on load.
            saved = {
                problem = solution.problem,
                raw_variables = solution.raw_variables,
                machines = solution.quantity_of_machines_required,
            },
        }
        solution.lc_restart = true
        solution.solver_state = "ready"
        solution.solver_iteration = nil
        -- solution.raw_variables stays as-is: the QP handoff discards the warm
        -- seed on its own (linear_programming.qp_warm_strategy = "cold").
        return
    end

    -- phase == "compress": the folded re-solve reached a terminal state.
    if solution.solver_state ~= "finished" and lc.saved then
        local saved = lc.saved
        solution.problem = saved.problem
        solution.raw_variables = saved.raw_variables
        solution.quantity_of_machines_required = saved.machines
        solution.inactive_recipe_variables = saved.problem.inactive_recipe_variables
        solution.solver_state = "finished"
        solution.solver_iteration = nil
    end
    lc.saved = nil
    lc.phase = "done"
end

---Advance the sparse elastic placement one step after a terminal solve
---(solver_norm == "batch" / "smart"; see solver/placement.lua for the shared
---machinery and the research provenance). The target rescue settles first
---(targets are tier-1); then:
---  base (all-elastic L2) finished -> index the violation groups, record the
---    physical totals (the guard reference) and hold the answer aside (the
---    restore fallback). "smart" derives its static placement here and arms
---    the restricted re-solve; "batch" arms the Phase-I loop.
---  "phase1" ("batch" only) finished -> read the artificial support; feasible
---    (sum ~ 0) arms the restricted re-solve, otherwise open every
---    support-named group and re-measure. A diverged Phase-I or an empty
---    support falls back to placing everything (= the plain L2).
---  "restricted" finished -> compare the physical import+dump total against
---    the base. Within PLACEMENT_GUARD (or out of widening rounds) the sparse
---    answer stands; otherwise widen the placement -- "batch" by physical
---    rank, "smart" structurally (the SCC / junction partners of the inflated
---    carriers; every SCC member when the solve did not even converge) -- and
---    re-solve. A restricted solve that cannot be widened back to convergence
---    restores the held base answer verbatim (no extra solve).
---Every placement re-solve is COLD (the warm seed is dropped): the stages
---swap objectives (L2 <-> Phase-I <-> restricted L2), and warm-starting an
---IPM across an objective swap walks the duality measure the wrong way (the
---linf lesson; the QP handoff additionally cold-starts on its own).
---Mutates solution.placement and, when another solve is needed, re-arms
---solver_state="ready" with pm_restart set so the rebuild keeps the in-flight
---placement AND the settled target rescue (pm_restart sits in the rebuild's
---preserve list).
---@param solution Solution
---@param norm SolverNorm "batch" | "smart"
---@param lines NormalizedProductionLine[]
function M.placement_step(solution, norm, lines)
    if not solution.problem then return end
    local pm = solution.placement
    if pm and pm.phase == "done" then return end
    local finished = solution.solver_state == "finished" and solution.raw_variables ~= nil

    local function restart()
        solution.pm_restart = true
        solution.solver_state = "ready"
        solution.solver_iteration = nil
        solution.raw_variables = nil
    end

    if not pm then
        -- The base (all-elastic L2, target-rescued) just terminated. If it
        -- failed, leave the terminal state for the UI -- there is no
        -- reference to place against.
        if not finished then
            solution.placement = { phase = "done" }
            return
        end
        local groups = placement.violation_groups(solution.problem)
        if next(groups) == nil then
            -- No violation escapes at all (no intermediates): the base answer
            -- IS the sparse answer.
            solution.placement = { phase = "done" }
            return
        end
        local stats = placement.violation_stats(solution.problem, solution.raw_variables.x)
        -- The target budget every placement build carries (the linf t_limit
        -- move): the rescue's settled budget when one fired, else the base
        -- solve's own achieved relaxation plus the IPM margin -- so neither
        -- the Phase-I measurement nor a sparse re-solve can trade a target
        -- away past what the all-elastic base held.
        local t_limit = solution.target_rescue and solution.target_rescue.budget
        if not t_limit then
            local t0 = observe_price.target_relax(solution.problem.primals, solution.raw_variables.x)
            t_limit = t0 * (1 + target_budget_rel) + target_budget_abs
        end
        pm = {
            groups = groups,
            base_imp = stats.imp,
            base_dmp = stats.dmp,
            gp = stats.gp,
            t_limit = t_limit,
            placed = {},
            rounds = 0,
            p1iters = 0,
            -- Hold the finished base so an unrecoverable restricted solve
            -- restores it without solving again (the l2_compress pattern).
            saved = {
                problem = solution.problem,
                raw_variables = solution.raw_variables,
                machines = solution.quantity_of_machines_required,
            },
        }
        solution.placement = pm
        if norm == "smart" then
            pm.placed, pm.units, pm.junctions =
                placement.law_placement(solution.problem, lines, stats.gp)
            pm.phase = "restricted"
        else
            pm.phase = "phase1"
        end
        restart()
        return
    end

    if pm.phase == "phase1" then
        local widened_all = false
        if finished and pm.arts then
            -- Termination reads only the artificials that map onto a violation
            -- group: residual art on an unmapped row (a fluid window etc.) is
            -- imbalance no escape placement could absorb anyway, and holding
            -- the loop open on it would spin to the place-all fallback.
            local _, support =
                placement.phase1_support(pm.arts, solution.raw_variables.x, placement_support_tol)
            local mat2base = placement.invert_groups(pm.groups)
            local mapped_total = 0
            for _, s in ipairs(support) do
                if mat2base[s.row] then mapped_total = mapped_total + s.art end
            end
            if mapped_total <= placement_art_tol then
                pm.arts = nil
                pm.phase = "restricted"
                restart()
                return
            end
            local added = 0
            for _, s in ipairs(support) do
                local base = mat2base[s.row]
                if base and not pm.placed[base] then
                    pm.placed[base] = true
                    added = added + 1
                end
            end
            pm.p1iters = pm.p1iters + 1
            widened_all = added == 0 or pm.p1iters >= PLACEMENT_MAX_P1
        else
            -- The Phase-I LP itself diverged (feasible by construction, so
            -- this is IPM trouble; corpus: 1/1677).
            widened_all = true
        end
        if widened_all then
            -- No progress to be had: place everything, degenerating the
            -- restricted solve to the plain L2 the base already reached.
            for base in pairs(pm.groups) do pm.placed[base] = true end
            pm.arts = nil
            pm.phase = "restricted"
        end
        restart()
        return
    end

    -- phase == "restricted": the sparse re-solve reached a terminal state.
    if finished then
        local stats = placement.violation_stats(solution.problem, solution.raw_variables.x)
        local base_total = pm.base_imp + pm.base_dmp
        local ratio = base_total > 1e-9 and (stats.imp + stats.dmp) / base_total or 1
        if ratio <= PLACEMENT_GUARD or pm.rounds >= PLACEMENT_MAX_ROUNDS then
            -- The sparse answer stands. Out-of-rounds over the guard stands
            -- too: it converged, and restoring the base would silently hide
            -- the placement the user asked to see.
            pm.saved = nil
            pm.phase = "done"
            return
        end
        local added
        if norm == "smart" then
            added = placement.widen_structural(
                pm.units, pm.junctions, pm.gp, stats.gp, pm.placed)
            if added == 0 then
                added = placement.widen_rank(pm.gp, pm.placed, PLACEMENT_ADDK)
            end
        else
            added = placement.widen_rank(pm.gp, pm.placed, PLACEMENT_ADDK)
        end
        if added == 0 then
            pm.saved = nil
            pm.phase = "done"
            return
        end
        pm.rounds = pm.rounds + 1
        restart()
        return
    end

    -- The restricted solve did NOT converge (a too-sparse placement can be
    -- numerically hostile, or -- "smart" only, 4/1474 on the corpus --
    -- statically infeasible). Widen and retry while rounds remain.
    if pm.rounds < PLACEMENT_MAX_ROUNDS then
        local added
        if norm == "smart" then
            added = placement.widen_all_units(pm.units, pm.placed)
            if added == 0 then
                added = placement.widen_rank(pm.gp, pm.placed, PLACEMENT_ADDK)
            end
        else
            added = placement.widen_rank(pm.gp, pm.placed, PLACEMENT_ADDK)
        end
        if added > 0 then
            pm.rounds = pm.rounds + 1
            restart()
            return
        end
    end
    -- Out of rounds (or nothing left to widen) without a converged restricted
    -- solve: restore the held base answer verbatim.
    local saved = pm.saved
    if saved then
        solution.problem = saved.problem
        solution.raw_variables = saved.raw_variables
        solution.quantity_of_machines_required = saved.machines
        solution.inactive_recipe_variables = saved.problem.inactive_recipe_variables
        solution.solver_state = "finished"
        solution.solver_iteration = nil
    end
    pm.saved = nil
    pm.phase = "done"
end

---Advance the cascade staged rescue one step after a terminal solve. On the
---first call (no in-flight state) it begins the cascade on the
---target-rescued baseline; later calls feed the just-solved cascade build into
---cascade.advance, which either wants another solve (re-arm "ready") or settles
---("done" -- the held answer stands) or asks to restore the adopted answer
---("restore" -- rebuild the adopted problem and re-filter WITHOUT solving,
---because the last stage's result was rejected). cascade.advance handles
---non-finished solves itself (its deletion-final / staged-relay fallbacks), so
---this is driven on any terminal state; only the baseline must have finished to
---begin at all.
---@param solution Solution
---@param lines NormalizedProductionLine[]
function M.cascade_step(solution, lines)
    local cc = solution.cascade
    if not cc then
        -- The baseline (target-rescued) just terminated. If it failed, leave
        -- the terminal state for the UI -- there is no answer to cascade on.
        if solution.solver_state ~= "finished" or not solution.raw_variables then
            return
        end
        local rescue_budget = solution.target_rescue and solution.target_rescue.budget
        cc = cascade.begin(solution.problem, solution.raw_variables, lines, rescue_budget)
        solution.cascade = cc
        -- begin always leaves a build wanted (the pipeline ends with the
        -- polish), but guard anyway.
        if cc.build then
            M.arm_cascade_build(solution, cc.build)
        end
        return
    end
    if cc.phase == "done" then return end

    cascade.advance(cc, solution.problem, solution.raw_variables, solution.solver_state)

    -- A compact settled sentinel: drops the heavy working set (the adopted
    -- PackedVariables snapshot, the entry / verdict tables) but keeps the
    -- per-tier rescue outcome flags so idle ticks skip re-entry and diagnostics
    -- (the smoke read-side, future UI) can see what the cascade did.
    local function settled()
        return { phase = "done", vp_rescued = cc.vp_rescued, vf_rescued = cc.vf_rescued,
            vc_rescued = cc.vc_rescued, polish = cc.polish, vp_deleted = cc.vp_deleted,
            relay = cc.relay, solves = cc.solves }
    end

    if cc.phase == "restore" then
        -- The last stage's result was rejected: rebuild the adopted problem
        -- and restore its answer without solving. filter_result reads only the
        -- is_result primals against raw.x, and recipe keys are build-invariant,
        -- so the rebuilt problem yields the adopted machine counts exactly.
        local build = cc.build
        solution.problem = create_problem.create_problem(
            solution.name, solution.constraints, lines, nil, cascade.build_options(build))
        cascade.shape_problem(solution.problem, build)
        solution.problem.reduced = nil
        solution.problem.reconstruction = nil
        solution.inactive_recipe_variables = solution.problem.inactive_recipe_variables
        solution.raw_variables = cc.adopted_raw
        solution.quantity_of_machines_required =
            solution.problem:filter_result(solution.raw_variables)
        solution.solver_state = "finished"
        solution.cascade = settled()
        return
    end

    if cc.build then
        M.arm_cascade_build(solution, cc.build)
    else
        -- phase == "done": the held solution IS the adopted answer (its
        -- filter_result already ran this tick). Fold to the sentinel so idle
        -- ticks do not re-enter.
        solution.cascade = settled()
    end
end

---Re-arm the per-tick pump for the next cascade build: flip solver_state back
---to "ready" with cc_restart so the rebuild keeps the in-flight cascade state.
---EVERY cascade stage is solved COLD -- the warm seed (solution.raw_variables)
---is dropped unconditionally so the IPM restarts from the cold Mehrotra central
---path the reference solves on. Two findings drove this (project_cascade_warmstart):
---  1. The classification builds (cascade.is_cold -- fix-test verdict /
---     support-probe universe growth) MUST be cold: warming reads a different
---     degenerate vertex and corrupts the verdict (the warm verdict drift), and
---     does so non-deterministically.
---  2. Warming the heavy stage / final / polish builds buys nothing: each
---     cascade build carries a DIFFERENT objective (a new stage cost / budget
---     row), so the previous stage's optimum is not near this build's optimum,
---     and the boundary warm seed mismatches the IPM's interior preference --
---     measured zero cascade-internal speedup. The only warm that pays off is
---     the baseline's cross-EDIT re-solve, which never routes through here
---     (raw_variables is preserved across re-prepares above, not by this fn).
---With no upside and a real drift risk, the compromise is to cold-start them all.
---solution.raw_variables is only the warm SEED here (the cascade's adopted answer
---lives in cc.adopted_raw), so dropping it is safe; unfold(nil) /
---filter_result(nil) both no-op until the cold solve fills it back in.
---@param solution Solution
---@param build CascadeBuild
function M.arm_cascade_build(solution, build)
    solution.cc_restart = true
    solution.solver_state = "ready"
    solution.solver_iteration = nil
    solution.raw_variables = nil -- cold-start every stage; see the note above
end

---Advance the observe-price fixed point one step after a baseline / observe /
---verify solve has finished. Mutates solution.observe_price (the in-flight plan)
---and, when another solve is needed, flips solver_state back to "ready" with
---op_restart set so the rebuild keeps the plan. When the plan converges (or there
---is nothing to price) it leaves solver_state == "finished" and the current
---solution stands. Spread across ticks exactly like the old two-pass restart.
---@param solution Solution
---@param lines NormalizedProductionLine[]
function M.observe_price_step(solution, lines)
    if not solution.raw_variables or not solution.problem then return end
    local primals = solution.problem.primals
    local x = solution.raw_variables.x
    local op = solution.observe_price

    local function restart()
        solution.op_restart = true
        solution.solver_state = "ready"
        solution.solver_iteration = nil
    end

    if not op then
        -- The baseline (soft-gate only) solve just finished. Two things split the
        -- avoidable cheats it left:
        --   * observe-price's plan -- self-sustaining IDLE cycles to fabricate;
        --   * the two-pass diagnose -- the remaining avoidable export-feasible
        --     cheats (running-on-imported-input cycles where import is correct,
        --     e.g. lp_two_pass_reclassify), cheap-imported via forced_imports.
        -- The diagnose is a structural import-seeder (it picks WHICH material to
        -- import), the same role deficit_seeding / catalyst_closure play, so it
        -- stays. Exclude observe-price's fabricate targets so the two don't fight.
        local plan = observe_price.collect_plan(primals, x, solution.raw_variables.s, lines)
        local imports = create_problem.diagnose_avoidable_cheats(x, primals, lines)
        if plan then
            for _, k in ipairs(plan.keys) do imports[k.material] = nil end
        end
        if not plan and next(imports) == nil then
            -- Nothing to fabricate or cheap-import: park a "done" sentinel so we
            -- don't re-diagnose on every idle tick.
            solution.observe_price = { phase = "done" }
            return
        end
        solution.observe_price = {
            phase = plan and "observe" or "finalize",
            plan = plan,
            imports = imports,
            group_index = 1,
            round = 0,
        }
        restart()
    elseif op.phase == "finalize" then
        -- No fabricate plan -- the single solve that applied the cheap-import set
        -- just finished and stands.
        op.phase = "done"
    elseif op.phase == "observe" then
        -- The observe solve for group_index just finished: price (or freeze) it,
        -- then observe the next group, or move on to verify.
        observe_price.apply_observe(op.plan, op.plan.groups[op.group_index], primals, x)
        op.group_index = op.group_index + 1
        if op.group_index <= #op.plan.groups then
            restart()
        else
            op.phase = "verify"
            op.round = 0
            restart()
        end
    elseif op.phase == "verify" then
        op.round = op.round + 1
        local live = observe_price.apply_verify(op.plan, x, op.round)
        if live and op.round < observe_price.MAX_ROUNDS then
            restart()
        else
            op.phase = "done"
        end
    end
    -- op.phase == "done": nothing to do; the finished solution stands.
end

---comment
---@param production_lines ProductionLine[]
---@param bonuses ResearchBonuses?
---@return NormalizedProductionLine[]
function M.to_normalized_production_lines(production_lines, bonuses)
    local normalized_production_lines = {}
    for _, line in ipairs(production_lines) do
        local normalized_line, effectivity = acc.normalize_production_line(line, bonuses)

        -- Quality decomposition is LP-only: it splits one per-quality product
        -- amount into the distribution that module quality bonus would
        -- actually emit. UI and totals consume the pre-decomposition amount.
        local decomposed = {}
        for _, product in ipairs(normalized_line.products) do
            local unlocked = bonuses and bonuses.unlocked_qualities or nil
            for _, value in ipairs(M.quality_decomposition(product, effectivity.quality, unlocked)) do
                table.insert(decomposed, value)
            end
        end
        normalized_line.products = decomposed

        table.insert(normalized_production_lines, normalized_line)
    end
    M.resolve_bare_fluids(normalized_production_lines)
    return normalized_production_lines
end

---Fill in implicit temperature info on every fluid NormalizedAmount in the
---given lines (see acc.resolve_bare_fluid_product / _ingredient for the exact
---semantics). Mutates in place because the LP variable names downstream are
---computed from these same NormalizedAmounts.
---@param normalized_production_lines NormalizedProductionLine[]
function M.resolve_bare_fluids(normalized_production_lines)
    local function resolve_ingredient(amount)
        if amount.type ~= "fluid" then return end
        amount.minimum_temperature, amount.maximum_temperature =
            acc.resolve_bare_fluid_ingredient(amount.name,
                amount.minimum_temperature,
                amount.maximum_temperature)
    end

    for _, line in ipairs(normalized_production_lines) do
        for _, product in ipairs(line.products) do
            if product.type == "fluid" then
                product.minimum_temperature, product.maximum_temperature =
                    acc.resolve_bare_fluid_product(product.name,
                        product.minimum_temperature,
                        product.maximum_temperature)
            end
        end
        for _, ingredient in ipairs(line.ingredients) do
            resolve_ingredient(ingredient)
        end
        if line.fuel_ingredient then
            resolve_ingredient(line.fuel_ingredient)
        end
        -- The spent fluid is an OUTPUT, so widen it like a product (a bare one
        -- resolves to the point [default, default]). It normally already carries the
        -- emitted point temperature from normalize, making this a no-op; the call
        -- keeps the residue symmetric with recipe products for the rare bare case.
        local spent = line.fuel_spent_fluid
        if spent and spent.type == "fluid" then
            spent.minimum_temperature, spent.maximum_temperature =
                acc.resolve_bare_fluid_product(spent.name,
                    spent.minimum_temperature, spent.maximum_temperature)
        end
    end
end

---comment
---@param normalized_amount NormalizedAmount
---@param effectivity_quality number
---@param unlocked_qualities table<string, boolean>?
---@return NormalizedAmount[]
function M.quality_decomposition(normalized_amount, effectivity_quality, unlocked_qualities)
    if effectivity_quality <= 0 then
        return { normalized_amount }
    end

    local source_quality_proto = prototypes.quality[normalized_amount.quality]
    local source_level = source_quality_proto and source_quality_proto.level or 0
    -- utility_constants.maximum_quality_jump caps how many tier steps above the
    -- input quality a single craft can produce. Vanilla default is 255 (i.e.
    -- effectively unlimited), but mods may set it lower to model engines that
    -- only allow a one-tier jump per craft. Reading it through
    -- prototypes.utility_constants picks up any modded override without
    -- assuming a fixed value here.
    local max_jump = prototypes.utility_constants.maximum_quality_jump or 255

    local current_quality = normalized_amount.quality
    local current_probability = 1
    local ret = {}

    repeat
        local next_quality
        local next_probability
        local quality_prototype = prototypes.quality[current_quality]
        local next_proto = quality_prototype.next
        -- Walk to the next tier if (a) it exists in the prototype tree,
        -- (b) it's unlocked by the player's research snapshot, and
        -- (c) it's still within maximum_quality_jump tiers of the source.
        -- unlocked_qualities=nil means "no force snapshot" and falls back to
        -- the prototype-level chain (legacy behavior).
        local next_unlocked = next_proto
            and (not unlocked_qualities or unlocked_qualities[next_proto.name])
        local within_jump = next_proto and (next_proto.level - source_level) <= max_jump
        if next_unlocked and within_jump then
            next_quality = next_proto.name
            if quality_prototype.name == normalized_amount.quality then
                next_probability = math.min(effectivity_quality * quality_prototype.next_probability, 1)
            else
                -- Factorio 2.1 adds chain_probability, the probability of a
                -- SECOND (and later) consecutive tier jump within one craft --
                -- a different, typically much smaller number than
                -- next_probability, which only governs the first jump. 2.0
                -- has no such field at all, and indexing a nonexistent field
                -- on a runtime prototype throws rather than returning nil, so
                -- the read is pcall-guarded; failure or an actual nil value
                -- both fall back to the pre-2.1 (next_probability) math. A
                -- successful read of 0 (legendary, no further jump) is a real
                -- value and must NOT be treated as "missing".
                local ok, chain_probability = pcall(function() return quality_prototype.chain_probability end)
                if ok and chain_probability ~= nil then
                    next_probability = current_probability * chain_probability
                else
                    next_probability = current_probability * quality_prototype.next_probability
                end
            end
        else
            next_quality = "unknown-quality"
            next_probability = 0
        end

        ---@type NormalizedAmount
        local add_value = {
            type = normalized_amount.type,
            name = normalized_amount.name,
            quality = current_quality,
            amount_per_second = (current_probability - next_probability) * normalized_amount.amount_per_second,
            minimum_temperature = normalized_amount.minimum_temperature,
            maximum_temperature = normalized_amount.maximum_temperature,
        }
        table.insert(ret, add_value)

        current_quality = next_quality
        current_probability = next_probability
    until 0 == current_probability

    return ret
end

return M
