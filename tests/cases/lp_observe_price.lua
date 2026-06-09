-- observe-price (solver/observe_price.lua) data-operation regressions.
--
-- The full fixed point (baseline -> observe -> verify) runs across the
-- incremental solver's ticks in manage/pre_solve.lua, so it is exercised
-- end-to-end by the in-game smoke test and measured on the explorer corpus. What
-- the headless suite pins here is the PURE logic the module owns: which cycles
-- qualify, how the per-material override maps are built, and how the verify loop
-- bumps / freezes a key. These operate on constructed primal / x / line tables --
-- the same shapes pre_solve hands the module -- so no Factorio runtime or solve
-- is involved.
--
-- The qualifying shape: a self-sustaining, export-feasible cyclic SCC {A, B} that
-- sits idle (its internal recipes carry no flow) while the demanded material A is
-- penalty-imported through |shortage_source|. observe-price exists to reprice
-- that shortage so the placed cycle runs instead.

local harness = require "tests/harness"
local op = require "solver/observe_price"

local function it(n, a) return { type = "item", name = n, quality = "normal", amount_per_second = a } end
local function line(r, prods, ings)
    return { recipe_typed_name = { type = "recipe", name = r, quality = "normal" },
        products = prods, ingredients = ings, power_per_second = 0, pollution_per_second = 0 }
end

-- {A, B} is a mass-positive 2-cycle (r1: A -> 2B, r2: B -> 2A), self-sustaining
-- and export-feasible; r3 draws A out to the target. With r1/r2 idle and A
-- imported via shortage, the cycle is the observe-price target.
local function cycle_lines()
    return {
        line("r1", { it("B", 2) }, { it("A", 1) }),
        line("r2", { it("A", 2) }, { it("B", 1) }),
        line("r3", { it("target", 1) }, { it("A", 1) }),
    }
end
local A_SHORTAGE = "|shortage_source|item/A/normal"
local function base_primals()
    return {
        ["recipe/r1/normal"] = { kind = "recipe" },
        ["recipe/r2/normal"] = { kind = "recipe" },
        ["recipe/r3/normal"] = { kind = "recipe" },
        [A_SHORTAGE] = { kind = "shortage_source", material = "item/A/normal" },
    }
end
-- Idle cycle (r1/r2 = 0), one active recipe (r3 = 1) setting the park threshold,
-- A imported via shortage = 1.
local function idle_x()
    return { ["recipe/r1/normal"] = 0, ["recipe/r2/normal"] = 0, ["recipe/r3/normal"] = 1,
        [A_SHORTAGE] = 1 }
end

local cases = {}

table.insert(cases, {
    name = "collect_plan qualifies an idle self-sustaining cyclic SCC with active shortage",
    run = function()
        local plan = op.collect_plan(base_primals(), idle_x(), cycle_lines())
        harness.assert_true(plan ~= nil, "expected a plan")
        harness.assert_eq(#plan.keys, 1, "one shortage key qualifies")
        local k = plan.keys[1]
        harness.assert_eq(k.material, "item/A/normal", "the demanded cycle material")
        harness.assert_eq(k.key, A_SHORTAGE, "its shortage variable")
        harness.assert_near(k.qty, 1, 1e-9, "baseline shortage qty")
        -- ceiling = target_cost / (elastic_cost * qty) = 2^20 / 2^10 = 1024.
        harness.assert_near(k.ceiling, 1024, 1e-6, "collapse ceiling")
        harness.assert_eq(k.frozen, false, "starts live")
        harness.assert_eq(#plan.groups, 1, "one SCC group")
    end,
})

table.insert(cases, {
    name = "collect_plan skips a cycle that is already running (not idle)",
    run = function()
        local running = { ["recipe/r1/normal"] = 1, ["recipe/r2/normal"] = 1,
            ["recipe/r3/normal"] = 1, [A_SHORTAGE] = 1 }
        harness.assert_eq(op.collect_plan(base_primals(), running, cycle_lines()), nil,
            "a running internal cycle does not qualify")
    end,
})

table.insert(cases, {
    name = "collect_plan skips a cycle with no active shortage",
    run = function()
        local no_short = { ["recipe/r1/normal"] = 0, ["recipe/r2/normal"] = 0,
            ["recipe/r3/normal"] = 1, [A_SHORTAGE] = 0 }
        harness.assert_eq(op.collect_plan(base_primals(), no_short, cycle_lines()), nil,
            "no active shortage -> nothing to reprice")
    end,
})

table.insert(cases, {
    name = "observe_overrides raises the group to its ceiling",
    run = function()
        local plan = op.collect_plan(base_primals(), idle_x(), cycle_lines())
        local o = op.observe_overrides(plan, plan.groups[1])
        harness.assert_near(o["item/A/normal"], 1024, 1e-6, "observed at the ceiling")
    end,
})

table.insert(cases, {
    name = "apply_observe prices a cleared cycle from the escape delta",
    run = function()
        local plan = op.collect_plan(base_primals(), idle_x(), cycle_lines())
        -- Observe solution: the shortage cleared (cycle fabricates A), no target
        -- relaxation, and the fabrication dumps 4 units of a byproduct -> dEsc = 4.
        local obs_primals = base_primals()
        obs_primals["|surplus_sink|item/C/normal"] = { kind = "surplus_sink", material = "item/C/normal" }
        local obs_x = { ["recipe/r1/normal"] = 1, ["recipe/r2/normal"] = 1, ["recipe/r3/normal"] = 1,
            [A_SHORTAGE] = 0, ["|surplus_sink|item/C/normal"] = 4 }
        op.apply_observe(plan, plan.groups[1], obs_primals, obs_x)
        -- mult = clamp(K_PRED * dEsc/qty, 2, ceiling) = clamp(1.5 * 4 / 1, 2, 1024) = 6.
        harness.assert_near(plan.keys[1].mult, 6, 1e-6, "priced at k*dEsc/qty")
        harness.assert_eq(plan.keys[1].frozen, false, "not frozen")
    end,
})

table.insert(cases, {
    name = "apply_observe freezes a cone-over-promise cycle (shortage will not clear)",
    run = function()
        local plan = op.collect_plan(base_primals(), idle_x(), cycle_lines())
        -- Observe solution where the shortage stays active even at the ceiling:
        -- fabrication is infeasible, so import is correct -> FREEZE.
        local obs_primals = base_primals()
        local obs_x = { ["recipe/r3/normal"] = 1, [A_SHORTAGE] = 1 }
        op.apply_observe(plan, plan.groups[1], obs_primals, obs_x)
        harness.assert_eq(plan.keys[1].frozen, true, "frozen back to flat import")
    end,
})

table.insert(cases, {
    name = "verify_overrides omits frozen keys and reflects live mults",
    run = function()
        local plan = op.collect_plan(base_primals(), idle_x(), cycle_lines())
        plan.keys[1].mult = 8
        local live = op.verify_overrides(plan)
        harness.assert_near(live["item/A/normal"], 8, 1e-9, "live key at its mult")
        plan.keys[1].frozen = true
        local frozen = op.verify_overrides(plan)
        harness.assert_eq(frozen["item/A/normal"], nil, "frozen key omitted (keeps flat cost)")
    end,
})

table.insert(cases, {
    name = "apply_verify resolves, bumps, and freezes a key",
    run = function()
        -- Resolved: shortage parked -> records the round, no live straggler.
        local plan = op.collect_plan(base_primals(), idle_x(), cycle_lines())
        plan.keys[1].mult = 6
        local live = op.apply_verify(plan, { [A_SHORTAGE] = 0 }, 1)
        harness.assert_eq(live, false, "no straggler when shortage parks")
        harness.assert_eq(plan.keys[1].resolved_round, 1, "records the resolving round")

        -- Straggler below the ceiling -> bump x2, live.
        local plan2 = op.collect_plan(base_primals(), idle_x(), cycle_lines())
        plan2.keys[1].mult = 6
        local live2 = op.apply_verify(plan2, { [A_SHORTAGE] = 1 }, 1)
        harness.assert_eq(live2, true, "still importing -> live straggler")
        harness.assert_near(plan2.keys[1].mult, 12, 1e-6, "bumped x2")

        -- Straggler at the ceiling -> freeze, not live.
        local plan3 = op.collect_plan(base_primals(), idle_x(), cycle_lines())
        plan3.keys[1].mult = plan3.keys[1].ceiling
        local live3 = op.apply_verify(plan3, { [A_SHORTAGE] = 1 }, 2)
        harness.assert_eq(plan3.keys[1].frozen, true, "frozen at the ceiling")
        harness.assert_eq(live3, false, "a ceiling freeze is not a live straggler")
    end,
})

table.insert(cases, {
    name = "cheat_mass sums shortage_source + elastic, not surplus",
    run = function()
        local primals = {
            ["|shortage_source|item/A/normal"] = { kind = "shortage_source", material = "item/A/normal" },
            ["|elastic||limit|item/T/normal"] = { kind = "elastic" },
            ["|surplus_sink|item/C/normal"] = { kind = "surplus_sink", material = "item/C/normal" },
        }
        local x = { ["|shortage_source|item/A/normal"] = 2, ["|elastic||limit|item/T/normal"] = 3,
            ["|surplus_sink|item/C/normal"] = 100 }
        harness.assert_near(op.cheat_mass(primals, x), 5, 1e-9, "2 shortage + 3 elastic; surplus excluded")
    end,
})

table.insert(cases, {
    name = "collect_plan is deterministic across runs",
    run = function()
        local p1 = op.collect_plan(base_primals(), idle_x(), cycle_lines())
        local p2 = op.collect_plan(base_primals(), idle_x(), cycle_lines())
        harness.assert_eq(#p1.keys, #p2.keys, "same key count")
        harness.assert_eq(p1.keys[1].key, p2.keys[1].key, "same key")
        harness.assert_eq(p1.keys[1].group, p2.keys[1].group, "same group id")
        harness.assert_near(p1.keys[1].ceiling, p2.keys[1].ceiling, 1e-9, "same ceiling")
    end,
})

return cases
