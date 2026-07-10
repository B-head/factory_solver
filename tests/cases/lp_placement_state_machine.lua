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
        -- The target is met through the cycle (not bought through an escape).
        harness.assert_near(x["recipe/make_P/normal"] or 0, 1, 1e-2, "make_P carries the target")
        -- The placement is sparse: fewer groups survive in the final build
        -- than the 5 intermediates the base carried, and everything the
        -- Phase-I placed is a real escape (cell-side makeup / W dump).
        local placed = count_placed(pm)
        harness.assert_true(placed >= 1 and placed <= 3,
            "phase-I placed a sparse set, got " .. placed)
        harness.assert_eq(violation_group_count(solution.problem), placed,
            "the final build carries exactly the placed groups")
        -- base (1) + >=1 Phase-I + restricted (1); the guard usually passes
        -- on the first restricted solve.
        harness.assert_true(rebuilds >= 3 and rebuilds <= 9,
            "base + phase-I loop + restricted, got " .. rebuilds .. " rebuilds")
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
        harness.assert_true((solution.placement.placed or {})["item/J/normal"] == true,
            "the forced-surplus dump J is placed")
    end,
})

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
