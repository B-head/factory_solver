local flib_table = require "__flib__/table"
local acc = require "manage/accessor"
local create_problem = require "solver/create_problem"
local linear_programming = require "solver/linear_programming"
local substitution = require "solver/substitution"
local observe_price = require "solver/observe_price"
local cascade = require "solver/cascade"

local iterate_limit = 600

-- The shipped solver pipeline (2026-06-13): the cascade staged rescue
-- (solver/cascade.lua) on an UN-GATED baseline. It approximates the reference
-- solver's 5-tier lexicographic optimum (target >> producible imports >>
-- makeup imports >> consumable dumps >> machines) with lazy budget-locked
-- stages, paid only when the corresponding defeat actually flows. It replaces
-- the observer (soft gate + observe-price): observe-price's cone fabrication
-- is the Vf stage's job now (see project_vp_rescue / project_solver_names).
-- Flip to false to roll back to the observer below (which itself rolls back to
-- the legacy hard gate via observe_price_enabled). cascade_enabled wins: when
-- true, neither observe-price nor the two-pass runs.
local cascade_enabled = true

-- Observer rollback (only consulted when cascade_enabled is false). Flip to
-- false to fall straight back to the legacy hard reachability gate + two-pass
-- diagnose (immediate rollback). When true, the gate is replaced by a SOFT
-- gate -- reachable shortages priced at elastic_cost * soft_gate_k so the
-- chain still wins -- and the unreachable self-sustaining catalyst cycles are
-- repriced by the observe-price fixed point below.
local observe_price_enabled = true
-- The soft-gate multiplier. Must stay below target_cost/elastic_cost (= 2^10) so
-- a reachable shortage never undercuts target relaxation; 256 is the measured
-- minimum that clears every headless fixture (see project_tilted_cost memo).
local soft_gate_k = 256

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
        -- restarts (op_restart / reclassify_pending) keep the settled budget so
        -- their re-solves stay locked on the rescued target.
        if not (solution.tr_restart or solution.op_restart or solution.reclassify_pending
                or solution.cc_restart) then
            solution.target_rescue = nil
        end
        solution.tr_restart = nil

        local options = nil
        -- The cascade build in flight this tick (nil = the un-gated baseline).
        -- A cascade build is shaped after create_problem and skips the
        -- substitution fold (its objective is overwritten).
        local cc_build = nil
        if cascade_enabled then
            -- Shipped path: un-gated baseline, then the cascade staged rescue
            -- (M.cascade_step) owns every later build. observe-price and the
            -- two-pass are not run; their state is dropped. A fresh "ready"
            -- drops in-flight cascade state; the loop's OWN restart keeps it.
            if not solution.cc_restart then solution.cascade = nil end
            solution.cc_restart = nil
            solution.observe_price = nil
            solution.forced_imports = nil
            solution.reclassify_pending = nil

            local cc = solution.cascade
            if cc and cc.build then
                cc_build = cc.build
                options = cascade.build_options(cc_build)
            else
                -- The baseline: un-gated flat hatches (no soft gate). The
                -- cascade's stages, not a gate, do the rescue work.
                options = { reachability_gating = false }
            end
        elseif observe_price_enabled then
            -- Shipped path: replace the hard gate with the soft gate and apply the
            -- current observe-price phase's per-material shortage overrides. A
            -- fresh "ready" (edit / migration / new solution) drops in-flight
            -- observe-price state so the next solve restarts from a clean
            -- baseline; the loop's OWN restarts set op_restart to keep their plan.
            if not solution.op_restart then solution.observe_price = nil end
            solution.op_restart = nil
            solution.reclassify_pending = nil

            options = { reachability_gating = false, reachability_soft_gate_k = soft_gate_k }
            -- forced_imports here carries the two-pass diagnose's cheap-import set
            -- (the avoidable export-feasible cheats observe-price does NOT
            -- fabricate -- the running-on-imported-input cycles where import is
            -- correct). It is computed once after the baseline solve and reapplied
            -- on every rebuild; observe-price's fabricate targets get
            -- shortage_cost_overrides instead.
            local op = solution.observe_price
            local forced = op and op.imports or nil
            if op and op.reverted then
                -- keep-best fallback: the priced result was worse, so cheap-import
                -- everything (the diagnose set plus the fabricate targets).
                forced = {}
                for m in pairs(op.imports or {}) do forced[m] = true end
                if op.plan then for _, k in ipairs(op.plan.keys) do forced[k.material] = true end end
            elseif op and op.plan then
                if op.phase == "observe" then
                    options.shortage_cost_overrides =
                        observe_price.observe_overrides(op.plan, op.plan.groups[op.group_index])
                elseif op.phase == "verify" then
                    options.shortage_cost_overrides = observe_price.verify_overrides(op.plan)
                end
            end
            solution.forced_imports = forced
        else
            -- Legacy rollback: hard reachability gate + two-pass diagnose. A fresh
            -- "ready" drops forced imports left from a previous reclassify pass;
            -- the two-pass restart sets reclassify_pending to keep its seeds.
            if not solution.reclassify_pending then
                solution.forced_imports = nil
            end
            solution.reclassify_pending = nil
            solution.observe_price = nil
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
        local fold = substitution_enabled and not (cc_build and cascade.is_cold(cc_build))
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

    if cascade_enabled then
        -- The cascade staged rescue (the shipped replacement for the observer).
        -- Each stage is a full incremental solve; advancing it sets
        -- solver_state="ready" + cc_restart so the rebuild above stays on the
        -- same cascade build. Driven on ANY terminal state, not just "finished":
        -- a stage CAN diverge (the deletion-final / staged-relay fallbacks exist
        -- for exactly that), so cascade_step must run to advance the fallback
        -- chain rather than stall in a terminal non-"finished" state. See
        -- M.cascade_step.
        local st = solution.solver_state
        if st ~= "ready" and st ~= "calculating" then
            M.cascade_step(solution, get_normalized())
        end
    elseif observe_price_enabled then
        -- observe-price fixed point (the observer's replacement for the
        -- two-pass). Each phase below is a full incremental solve; advancing it
        -- sets solver_state="ready" + op_restart so the rebuild above stays on
        -- the same plan. See M.observe_price_step.
        if solution.solver_state == "finished" then
            M.observe_price_step(solution, get_normalized())
        end
    else
        -- Legacy two-pass diagnose-then-reclassify (rollback). When the FIRST pass
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
            baseline_cheat = observe_price.cheat_mass(primals, x),
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
        if op.reverted then
            -- The keep-best revert solve (no overrides) finished: it is the
            -- baseline-equivalent answer; accept it.
            op.phase = "done"
            return
        end
        op.round = op.round + 1
        local live = observe_price.apply_verify(op.plan, x, op.round)
        if live and op.round < observe_price.MAX_ROUNDS then
            restart()
        else
            -- Keep-best guard: observe-price is best-effort. If the priced result
            -- carries MORE import/relaxation cheat than the baseline, discard the
            -- overrides and re-solve once at the baseline (the placed cycle stays a
            -- neutral import rather than a worse fabrication).
            local final_cheat = observe_price.cheat_mass(primals, x)
            if final_cheat > op.baseline_cheat + 1e-6 then
                op.reverted = true
                restart()
            else
                op.phase = "done"
            end
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
                flib_table.insert(decomposed, value)
            end
        end
        normalized_line.products = decomposed

        flib_table.insert(normalized_production_lines, normalized_line)
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
                next_probability = current_probability * quality_prototype.next_probability
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
        flib_table.insert(ret, add_value)

        current_quality = next_quality
        current_probability = next_probability
    until 0 == current_probability

    return ret
end

return M
