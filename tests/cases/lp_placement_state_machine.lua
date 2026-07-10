-- The sparse-placement STATE MACHINE (manage/pre_solve.lua forwerd_solve +
-- placement_step, solver_norm "batch" / "smart"), driven end-to-end headless.
-- The placement mechanics themselves (solver/placement.lua) are exercised
-- through the pump; what this file pins is the orchestration -- base ->
-- [Phase-I loop] -> restricted with the physical guard, the pm_restart
-- preserve threading (the linf-livelock class), the target budget riding
-- every placement build (or the Phase-I meets an expensive target by
-- relaxing it and places nothing -- the all-zero collapse), and the guard
-- widening on a placement the static law under-places.
--
-- Research provenance: tests/research/probe_batch_iis.lua (batch),
-- probe_scc_compress.lua / probe_law_fix.lua (smart), corpus-validated on
-- all 1678 explorer dumps (project_batch_phase1_placement).
--
-- forwerd_solve is headless-safe except for the production-line normalizer
-- (prototype reads), so each case stubs pre_solve.to_normalized_production_lines
-- (mirrors lp_l2_state_machine.lua / lp_linf_state_machine.lua).

local harness = require "tests/harness"
local pre_solve = require "manage/pre_solve"

local function it(name, amount)
    return { type = "item", name = name, quality = "normal", amount_per_second = amount }
end
local function line(recipe, products, ingredients)
    return {
        recipe_typed_name = { type = "recipe", name = recipe, quality = "normal" },
        products = products, ingredients = ingredients,
        power_per_second = 0, pollution_per_second = 0,
    }
end

---Drive forwerd_solve to a terminal state exactly as the on_tick pump does.
---@return table solution, integer rebuilds
local function drive(norm, lines, constraints, max_steps)
    max_steps = max_steps or 20000
    local solution = {
        name = "placement-pump",
        constraints = constraints,
        production_lines = {},
        solver_state = "ready",
        solver_norm = norm,
    }
    local force_data = { research_bonuses = nil }

    local saved = pre_solve.to_normalized_production_lines
    pre_solve.to_normalized_production_lines = function() return lines end
    local rebuilds, steps = 0, 0
    local ok, err = pcall(function()
        while solution.solver_state == "ready" or solution.solver_state == "calculating" do
            if solution.solver_state == "ready" then rebuilds = rebuilds + 1 end
            pre_solve.forwerd_solve(force_data, solution)
            steps = steps + 1
            assert(steps <= max_steps,
                string.format("placement pump did not settle after %d steps / %d rebuilds (livelock)",
                    steps, rebuilds))
        end
    end)
    pre_solve.to_normalized_production_lines = saved
    if not ok then error(err, 0) end
    return solution, rebuilds
end

---Distinct violation groups (material_base grain) present in a build.
local function violation_group_count(problem)
    local seen, n = {}, 0
    for _, p in pairs(problem.primals) do
        if (p.kind == "shortage_source" or p.kind == "surplus_sink") and p.material then
            local base = p.material_base or p.material
            if not seen[base] then
                seen[base] = true
                n = n + 1
            end
        end
    end
    return n
end

local function count_placed(pm)
    local n = 0
    for _ in pairs(pm.placed or {}) do n = n + 1 end
    return n
end

-- The mass-losing cycle (the elastic-necessity fixture, minimized): cell ->
-- P + spent, spent -> 0.8 cell, so meeting the P target structurally needs a
-- cell-side makeup import (~0.2/s) plus a dump for the terminal W. The
-- all-elastic base spreads; the sparse placement must keep only the needed
-- escapes.
local cycle_lines = {
    line("make_P", { it("P", 1), it("spent", 1) }, { it("cell", 1) }),
    line("regen", { it("cell", 0.8) }, { it("spent", 1) }),
    line("eat_P", { it("W", 1) }, { it("P", 1) }),
}
local cycle_constraints = {
    { type = "item", name = "P", quality = "normal",
        limit_type = "lower", limit_amount_per_second = 1 },
}

-- The target-collapse fixture (lp_target_rescue's shape): meeting 1 T/s
-- forces ~3000 units/s of penalised surplus, so the base relaxes the target,
-- the rescue fires, and every placement build must carry the rescued budget
-- (a placement build without it re-relaxes T and the Phase-I names nothing).
local collapse_lines = {
    line("r_t", { it("T", 1), it("J", 3000) }, { it("Jin", 1) }),
    line("r_x", { it("Jin", 1) }, { it("J", 1) }),
    line("r_b", { it("Jin", 0.001) }, {}),
}
local collapse_constraints = {
    { type = "item", name = "T", quality = "normal",
        limit_type = "equal", limit_amount_per_second = 1 },
}

local cases = {}

table.insert(cases, {
    name = "batch pump: the cycle's makeup import and terminal dump get placed, the rest excluded",
    run = function()
        local solution, rebuilds = drive("batch", cycle_lines, cycle_constraints)
        harness.assert_eq(solution.solver_state, "finished", "solver_state")
        local pm = solution.placement
        harness.assert_eq(pm and pm.phase, "done", "placement settled")
        assert(solution.raw_variables, "expected packed variables")
        local x = solution.raw_variables.x
        -- The target is met through the cycle. The exact rate inherits the
        -- BASE solve's activity via the floors (the base L2 spread runs regen
        -- slightly hot, so the hard spent row pulls make_P up to it) -- at
        -- least the target, not above the floored equilibrium.
        harness.assert_true((x["recipe/make_P/normal"] or 0) >= 1 - 1e-3
            and (x["recipe/make_P/normal"] or 0) <= 1.1,
            "make_P carries the target, got " .. tostring(x["recipe/make_P/normal"]))
        -- The DEFINITION: only feasibility-relevant escapes remain. The
        -- mass-losing cycle needs exactly one makeup channel; the prune must
        -- leave exactly it (cell -- the largest-flow member survives).
        harness.assert_eq(count_placed(pm), 1, "exactly the cycle's makeup escape")
        harness.assert_true((pm.placed or {})["item/cell/normal"] == true,
            "the cell makeup channel is the survivor")
        harness.assert_eq(violation_group_count(solution.problem), 1,
            "the final build carries exactly the placed group")
        -- base (1) + Phase-I opens (2) + prune (1) + restricted (1).
        harness.assert_true(rebuilds >= 4 and rebuilds <= 9,
            "base + phase-I loop + prune + restricted, got " .. rebuilds .. " rebuilds")
    end,
})

table.insert(cases, {
    name = "smart pump: the static law placement solves the cycle without a Phase-I",
    run = function()
        local solution, rebuilds = drive("smart", cycle_lines, cycle_constraints)
        harness.assert_eq(solution.solver_state, "finished", "solver_state")
        local pm = solution.placement
        harness.assert_eq(pm and pm.phase, "done", "placement settled")
        assert(solution.raw_variables, "expected packed variables")
        local x = solution.raw_variables.x
        harness.assert_near(x["recipe/make_P/normal"] or 0, 1, 1e-2, "make_P carries the target")
        -- The law places the SCC representative ({cell, spent} is a cycle)
        -- and the junction representative (make_P co-produces P + spent);
        -- guard widening may add more, but the set stays sparse.
        harness.assert_eq(violation_group_count(solution.problem), count_placed(pm),
            "the final build carries exactly the placed groups")
        harness.assert_true(count_placed(pm) <= 4,
            "placement stays sparse, got " .. count_placed(pm))
        -- No Phase-I under "smart": base + restricted (+ guard rounds).
        harness.assert_true(rebuilds >= 2 and rebuilds <= 7,
            "base + restricted (+ widening), got " .. rebuilds .. " rebuilds")
        harness.assert_true(pm.p1iters == 0, "smart runs no Phase-I")
    end,
})

table.insert(cases, {
    name = "batch pump on a rescue-firing problem: the budget rides the Phase-I and the restricted solve",
    run = function()
        local solution = drive("batch", collapse_lines, collapse_constraints)
        harness.assert_eq(solution.solver_state, "finished", "solver_state")
        harness.assert_eq(solution.placement and solution.placement.phase, "done", "placement settled")
        harness.assert_eq(solution.target_rescue and solution.target_rescue.phase, "done",
            "rescue sentinel survived the placement rebuilds")
        assert(solution.raw_variables, "expected packed variables")
        local x = solution.raw_variables.x
        -- The rescued target is met in the SPARSE answer: without the budget
        -- riding the placement builds, the Phase-I would relax T (3000 units
        -- of J-art vs the target's own size), place nothing, and the
        -- restricted solve would collapse to all-zero.
        harness.assert_near(x["recipe/r_t/normal"] or 0, 1, 1e-2,
            "target recipe runs at the requested rate in the sparse answer")
        -- Exactly ONE escape survives: the forced surplus exits either as a
        -- J dump or -- washed through r_x, a substitutable minimal choice the
        -- max-artificial opening may equally pick -- as a Jin dump. WHICH one
        -- is the open selection problem (import-vs-fabricate), not the
        -- definition; the definition only forbids irrelevant escapes.
        local pm = solution.placement
        harness.assert_eq(count_placed(pm), 1, "exactly one escape survives")
        harness.assert_true((pm.placed or {})["item/J/normal"] == true
            or (pm.placed or {})["item/Jin/normal"] == true,
            "the survivor carries the forced surplus (J or its washed Jin form)")
    end,
})

-- The side-chain fixture (the over-reduction regression, 2026-07-10): s2
-- converts the byproduct G into H mass-neutrally, so the base L2 runs it at
-- the half-half spread -- but nothing FORCES it in a sparse build (shutting
-- it down balances G's and H's escape-less rows at 0 = 0, and the L1
-- Phase-I is indifferent between the splits). Without the recipe floors the
-- sparse re-solve kills every line the target does not need (observed
-- in-game: most of a pyanodon factory at 0.000); with them the sparse
-- answer must keep the user's factory at least as active as the base.
local sidechain_lines = {
    line("mk_T", { it("T", 1), it("G", 2) }, {}),
    line("eat_T", { it("W", 1) }, { it("T", 1) }),
    line("s2", { it("H", 1) }, { it("G", 1) }),
}
local sidechain_constraints = {
    { type = "item", name = "T", quality = "normal",
        limit_type = "lower", limit_amount_per_second = 1 },
}

table.insert(cases, {
    name = "batch pump: the placement is scale-invariant",
    run = function()
        -- The same factory at a 1000x larger target must choose the SAME
        -- escapes: the Phase-I decision thresholds follow the base solve's
        -- violation scale (absolute cutoffs made a 30x smaller target flip
        -- the placement -- the in-game "changing the scale is unstable").
        local function placed_set(mult)
            local constraints = {
                { type = "item", name = "P", quality = "normal",
                    limit_type = "lower", limit_amount_per_second = mult },
            }
            local solution = drive("batch", cycle_lines, constraints)
            harness.assert_eq(solution.solver_state, "finished", "solver_state at x" .. mult)
            local t = {}
            for b in pairs(solution.placement.placed or {}) do t[#t + 1] = b end
            table.sort(t)
            return table.concat(t, ",")
        end
        harness.assert_eq(placed_set(1), placed_set(1000), "same placement at 1x and 1000x")
    end,
})

table.insert(cases, {
    name = "batch pump: definition-pure -- the pruned set stands over the smart guard threshold",
    run = function()
        -- The rigid fork (fixture (c)): mk co-produces X and Y 1:1, the only
        -- consumer eats them 1:3. The base L2 spreads (eatXY ~0.4: dump some
        -- X, import some Y, total ~0.8); under the floors the Phase-I opens
        -- X then Y, and the prune discovers X's opening became redundant
        -- (with Y open, eatXY can run at 1 and eat ALL of X) -- the pin for
        -- "an early opening is dropped once a later one covers it". The
        -- surviving {Y} placement concentrates: Y imports ~2, ~2.5x the
        -- base's physical total -- and "batch" must STAND on it (no guard
        -- widening may re-add feasibility-irrelevant escapes; the ratio is
        -- recorded as information only).
        local amp_lines = {
            line("mk", { it("T", 1), it("X", 1), it("Y", 1) }, {}),
            line("eatXY", { it("W", 1) }, { it("X", 1), it("Y", 3) }),
        }
        local amp_constraints = {
            { type = "item", name = "T", quality = "normal",
                limit_type = "lower", limit_amount_per_second = 1 },
        }
        local solution = drive("batch", amp_lines, amp_constraints)
        harness.assert_eq(solution.solver_state, "finished", "solver_state")
        local pm = solution.placement
        harness.assert_eq(pm and pm.phase, "done", "placement settled")
        harness.assert_eq(count_placed(pm), 1, "exactly one escape survives the prune")
        harness.assert_true((pm.placed or {})["item/Y/normal"] == true,
            "the fork's binding branch Y is the survivor")
        harness.assert_true((pm.rounds or 0) == 0, "batch never runs a guard round")
        harness.assert_true((pm.ratio or 0) >= 2 and (pm.ratio or 0) <= 3,
            "the concentrated ratio is recorded as information, got " .. tostring(pm.ratio))
        assert(solution.raw_variables, "expected packed variables")
        local x = solution.raw_variables.x
        harness.assert_near(x["recipe/eatXY/normal"] or 0, 1, 1e-2,
            "the hard X row pins the consumer to the co-production")
    end,
})

table.insert(cases, {
    name = "batch pump: no escape is placed when free terminals absorb everything",
    run = function()
        -- H and W are terminal products with free final sinks, so the
        -- byproduct G washes through s2 into H's free outflow and the
        -- all-closed Phase-I is feasible outright: by the DEFINITION (an
        -- escape exists only where its absence makes the problem infeasible)
        -- the placement must be EMPTY -- the hard G row simply forces s2 to
        -- carry all of it.
        local solution = drive("batch", sidechain_lines, sidechain_constraints)
        harness.assert_eq(solution.solver_state, "finished", "solver_state")
        local pm = solution.placement
        harness.assert_eq(pm and pm.phase, "done", "placement settled")
        harness.assert_eq(count_placed(pm), 0, "no feasibility-relevant escape exists")
        assert(solution.raw_variables, "expected packed variables")
        local x = solution.raw_variables.x
        harness.assert_true((x["recipe/s2/normal"] or 0) >= 1.9,
            "s2 carries ALL of G into H's free sink, got " .. tostring(x["recipe/s2/normal"]))
    end,
})

for _, norm in ipairs({ "batch", "smart" }) do
    table.insert(cases, {
        name = norm .. " pump: the recipe floors keep the target-independent side chain alive",
        run = function()
            local solution = drive(norm, sidechain_lines, sidechain_constraints)
            harness.assert_eq(solution.solver_state, "finished", "solver_state")
            harness.assert_eq(solution.placement and solution.placement.phase, "done",
                "placement settled")
            assert(solution.raw_variables, "expected packed variables")
            local x = solution.raw_variables.x
            harness.assert_near(x["recipe/mk_T/normal"] or 0, 1, 1e-2, "mk_T carries the target")
            -- The base spread runs s2 at ~1 (half of G washes into H); the
            -- sparse answer must not shut it down.
            harness.assert_true((x["recipe/s2/normal"] or 0) >= 0.9,
                "the side chain stays at its base activity, got "
                .. tostring(x["recipe/s2/normal"]))
        end,
    })
end

table.insert(cases, {
    name = "smart pump on the rescue-firing problem: SCC representative covers the forced dump",
    run = function()
        local solution = drive("smart", collapse_lines, collapse_constraints)
        harness.assert_eq(solution.solver_state, "finished", "solver_state")
        harness.assert_eq(solution.placement and solution.placement.phase, "done", "placement settled")
        harness.assert_eq(solution.target_rescue and solution.target_rescue.phase, "done",
            "rescue sentinel survived the placement rebuilds")
        assert(solution.raw_variables, "expected packed variables")
        local x = solution.raw_variables.x
        harness.assert_near(x["recipe/r_t/normal"] or 0, 1, 1e-2,
            "target recipe runs at the requested rate in the sparse answer")
    end,
})

return cases
