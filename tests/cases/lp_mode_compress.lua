-- L2 mode compression (solver/mode_compress.lua + create_problem's
-- hatch_exclude / sink_exclude): fold the L2 spread over sibling violation
-- channels (same base material AND same kind) down to the max-flow winner and
-- re-solve without the losers. The in-game stage machinery
-- (manage/pre_solve.lua M.l2_compress_step) is smoke-tested; this pins the
-- pure pieces -- the plan's grouping / winner rules over Primal metadata, the
-- material_base identity create_problem records, and the sink-side exclusion.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"
local pg = require "solver/problem_generator"
local mc = require "solver/mode_compress"

local fixture = require "tests/cases/fixture"
local item = fixture.item

local function fluid_single(name, temperature, amount)
    return {
        type = "fluid", name = name, quality = "normal",
        minimum_temperature = temperature, maximum_temperature = temperature,
        amount_per_second = amount,
    }
end
local function fluid_range(name, min, max, amount)
    return {
        type = "fluid", name = name, quality = "normal",
        minimum_temperature = min, maximum_temperature = max,
        amount_per_second = amount,
    }
end
local function recipe(name, products, ingredients)
    return {
        recipe_typed_name = { type = "recipe", name = name, quality = "normal" },
        products = products, ingredients = ingredients,
        power_per_second = 0, pollution_per_second = 0,
    }
end

---Add a synthetic violation escape to a bare Problem: kind + material metadata,
---the material_base grouping identity, and a subject term carrying `coef` (the
---physical flow read is |coef * x|, matching create_problem's escapes).
local function escape(problem, key, kind, material, base, coef)
    problem:add_objective(key, 0, false, kind, material)
    problem.primals[key].material_base = base
    problem:add_subject_term(key, material, coef)
end

local cases = {}

--------------------------------------------------------------------------------
-- The plan: pure metadata grouping.
--------------------------------------------------------------------------------

table.insert(cases, {
    name = "plan folds same-base same-kind siblings to the max-physical-flow winner",
    run = function()
        local problem = pg.new("plan-fold")
        -- Import-side sibling group on base A (three windows). s3's raw x is the
        -- largest but its subject coefficient scales it down: the winner must be
        -- picked on PHYSICAL flow |coef * x|, not raw x.
        escape(problem, "s1", "shortage_source", "A@[10,20]", "A", 1)
        escape(problem, "s2", "shortage_source", "A@[30,40]", "A", 1)
        escape(problem, "s3", "shortage_source", "A@[50,60]", "A", 0.2)
        -- Opposite kind on the SAME base: a lone dump never folds into the
        -- import group (the opposite-kind fold is the measured destruction
        -- source, so kinds group separately).
        escape(problem, "d1", "surplus_sink", "A@[10,20]", "A", 1)
        -- Items are their own base: two active item imports never group.
        escape(problem, "s4", "shortage_source", "B", "B", 1)
        escape(problem, "s5", "shortage_source", "C", "C", 1)
        local x = { s1 = 5, s2 = 3, s3 = 10, d1 = 4, s4 = 2, s5 = 2 }

        local plan = mc.plan(problem, x)
        assert(plan, "expected a plan (the A import group folds)")
        harness.assert_eq(plan.excluded, 2, "two losers folded")
        harness.assert_true(plan.hatch ~= nil, "import-side exclusions present")
        harness.assert_true(plan.hatch["A@[30,40]"] == true, "s2 (phys 3) folded")
        harness.assert_true(plan.hatch["A@[50,60]"] == true, "s3 (phys 0.2*10=2 < 5) folded")
        harness.assert_true(plan.hatch["A@[10,20]"] == nil, "winner s1 (phys 5) kept")
        harness.assert_true(plan.sink == nil, "the lone dump is untouched")
        harness.assert_true(plan.hatch["B"] == nil and plan.hatch["C"] == nil,
            "distinct-base items never group")
    end,
})

table.insert(cases, {
    name = "plan returns nil when nothing folds (singletons / dust members)",
    run = function()
        local problem = pg.new("plan-nil")
        escape(problem, "s1", "shortage_source", "A@[10,20]", "A", 1)
        -- Same base but below the dust floor: not an active channel, so the
        -- group stays a singleton and nothing folds.
        escape(problem, "s2", "shortage_source", "A@[30,40]", "A", 1)
        escape(problem, "d1", "surplus_sink", "B", "B", 1)
        local x = { s1 = 5, s2 = 1e-9, d1 = 3 }
        harness.assert_true(mc.plan(problem, x) == nil, "no multi-member group -> nil")
    end,
})

table.insert(cases, {
    name = "plan winner tie-break is the key order (deterministic across clients)",
    run = function()
        local problem = pg.new("plan-tie")
        escape(problem, "sA", "shortage_source", "A@[10,20]", "A", 1)
        escape(problem, "sB", "shortage_source", "A@[30,40]", "A", 1)
        local x = { sA = 2, sB = 2 } -- exactly tied physical flow
        local plan = mc.plan(problem, x)
        assert(plan, "expected a plan")
        -- Total order: phys desc, key asc -- the tied winner is the smaller key.
        harness.assert_true(plan.hatch["A@[30,40]"] == true, "larger key folded")
        harness.assert_true(plan.hatch["A@[10,20]"] == nil, "smaller key wins the tie")
    end,
})

--------------------------------------------------------------------------------
-- create_problem: the material_base identity and the sink-side exclusion.
--------------------------------------------------------------------------------

-- Two point-temperature producers of one fluid, a range consumer (so the
-- temperature bridges connect them), and a capped water feed forcing a genuine
-- shortfall the violation escapes must carry.
local function steam_fixture()
    local lines = {
        recipe("boiler165", { fluid_single("steam", 165, 1) }, { item("water", 1) }),
        recipe("boiler500", { fluid_single("steam", 500, 1) }, { item("water", 1) }),
        recipe("well", { item("water", 1) }, {}),
        recipe("generator", { item("power", 1) }, { fluid_range("steam", 15, 1000, 2) }),
    }
    local constraints = {
        { type = "item", name = "power", quality = "normal",
            limit_type = "equal", limit_amount_per_second = 1 },
        { type = "item", name = "water", quality = "normal",
            limit_type = "upper", limit_amount_per_second = 1 },
    }
    return lines, constraints
end

table.insert(cases, {
    name = "create_problem records material_base: temperature variants share one base",
    run = function()
        local lines, constraints = steam_fixture()
        local problem = cp.create_problem("mb-identity", constraints, lines, nil,
            { reachability_gating = false })
        local bases, own = {}, 0
        for _, p in pairs(problem.primals) do
            if p.kind == "shortage_source" or p.kind == "surplus_sink" then
                assert(p.material_base, "every violation escape carries material_base ("
                    .. p.key .. ")")
                if p.material:find("steam", 1, true) then
                    -- A windowed fluid folds to the bare base, shared across variants.
                    harness.assert_true(p.material_base ~= p.material,
                        "windowed fluid folds its window away (" .. p.material .. ")")
                    bases[p.material_base] = (bases[p.material_base] or 0) + 1
                else
                    -- Items (and bare fluids) are their own base.
                    harness.assert_eq(p.material_base, p.material, "item base is itself")
                    own = own + 1
                end
            end
        end
        local distinct = 0
        for _ in pairs(bases) do distinct = distinct + 1 end
        harness.assert_eq(distinct, 1, "every steam variant shares ONE base")
        harness.assert_true(own > 0, "the fixture also had item escapes to check")
    end,
})

table.insert(cases, {
    name = "sink_exclude omits the |surplus_sink| (the dump-side hatch_exclude mirror)",
    run = function()
        local lines, constraints = steam_fixture()
        local baseline = cp.create_problem("sink-excl-base", constraints, lines, nil,
            { reachability_gating = false })
        -- Find one dump escape to exclude, via metadata (never key parsing).
        local victim_key, victim_material = nil, nil
        for key, p in pairs(baseline.primals) do
            if p.kind == "surplus_sink" and p.material:find("steam", 1, true) then
                if victim_key == nil or key < victim_key then -- deterministic pick
                    victim_key, victim_material = key, p.material
                end
            end
        end
        assert(victim_key and victim_material, "fixture yields a steam dump escape")

        local rebuilt = cp.create_problem("sink-excl", constraints, lines, nil,
            { reachability_gating = false, sink_exclude = { [victim_material] = true } })
        harness.assert_true(rebuilt.primals[victim_key] == nil,
            "excluded material lost its surplus_sink")
        local others = 0
        for key, p in pairs(rebuilt.primals) do
            if p.kind == "surplus_sink" then
                harness.assert_true(p.material ~= victim_material, "no dump for the victim")
                others = others + 1
            end
            harness.assert_true(baseline.primals[key] ~= nil or key == victim_key,
                "no unexpected new primal")
        end
        harness.assert_true(others > 0, "other materials keep their dumps")
    end,
})

--------------------------------------------------------------------------------
-- End to end: solve, plan, re-solve compressed, physical totals preserved.
--------------------------------------------------------------------------------

table.insert(cases, {
    name = "compressed re-solve keeps the target and the physical import total",
    run = function()
        -- The shipped L2 shaping (manage/pre_solve.lua): un-gated, raised recipe
        -- tier, violation quad + floor, and the target lock (the fixture's target
        -- is reachable through the import hatch, so T_min ~ 0).
        local lines, constraints = steam_fixture()
        local function build(excl)
            local problem = cp.create_problem("mc-e2e", constraints, lines, nil, {
                reachability_gating = false, deficit_seeding = false,
                catalyst_closure = false, surplus_sink_gating = false,
                recipe_epsilon = 2 ^ -10, target_budget = 1e-6,
                hatch_exclude = excl and excl.hatch or nil,
                sink_exclude = excl and excl.sink or nil,
            })
            cp.shape_l2(problem, 2 ^ 11, 2 ^ -8)
            return problem
        end
        local function phys_of(problem, key, x)
            local p = problem.primals[key]
            local terms = problem.subject_terms[key]
            local coefficient = (terms and p.material and terms[p.material]) or 1
            return math.abs(coefficient * (x[key] or 0))
        end
        local function import_stats(problem, x)
            local total, channels = 0, 0
            for key, p in pairs(problem.primals) do
                if p.kind == "shortage_source" then
                    local v = phys_of(problem, key, x)
                    total = total + v
                    if v > 1e-6 then channels = channels + 1 end
                end
            end
            return total, channels
        end
        local function target_relax(problem, x)
            local sum = 0
            for key, p in pairs(problem.primals) do
                if p.kind == "elastic" or p.kind == "headroom" then
                    sum = sum + math.abs(x[key] or 0)
                end
            end
            return sum
        end

        local baseline = build(nil)
        local st0, v0 = harness.solve_to_completion(lp, baseline,
            { tolerance = 1e-7, iterate_limit = 600 })
        harness.assert_eq(st0, "finished", "baseline solver_state")
        assert(v0, "expected packed variables (baseline)")
        local total0, channels0 = import_stats(baseline, v0.x)
        -- The water cap starves the boilers: 2 steam demanded, 1 producible, so
        -- ~1 unit must import -- and the L2 quad spreads it over the sibling
        -- steam windows (that spread is what the compression folds).
        harness.assert_true(total0 > 0.5, "the shortfall flows through the imports")
        harness.assert_true(channels0 >= 2, "L2 spreads the import over sibling channels")

        local plan = mc.plan(baseline, v0.x)
        assert(plan, "the sibling spread yields a fold plan")
        harness.assert_true(plan.excluded >= 1, "at least one channel folds")

        local compressed = build(plan)
        for material in pairs(plan.hatch or {}) do
            for _, p in pairs(compressed.primals) do
                harness.assert_true(not (p.kind == "shortage_source" and p.material == material),
                    "folded import channel absent from the rebuild")
            end
        end
        local st1, v1 = harness.solve_to_completion(lp, compressed,
            { tolerance = 1e-7, iterate_limit = 600 })
        harness.assert_eq(st1, "finished", "compressed solver_state")
        assert(v1, "expected packed variables (compressed)")

        harness.assert_near(target_relax(compressed, v1.x), 0, 1e-3,
            "target stays met after the fold")
        local total1, channels1 = import_stats(compressed, v1.x)
        harness.assert_near(total1, total0, math.max(0.05 * total0, 1e-3),
            "physical import total preserved (the fold moves flow, not the books)")
        harness.assert_true(channels1 < channels0,
            "the active import channels actually compressed ("
            .. channels0 .. " -> " .. channels1 .. ")")
    end,
})

return cases
