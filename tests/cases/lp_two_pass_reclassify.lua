-- Diagnose-then-reclassify: a signal-free two-pass that fixes AVOIDABLE cheats.
--
-- Some self-sustaining cycles cannot bootstrap from zero and the LP fabricates
-- the demanded material via |shortage_source| even though the recipe set can
-- actually produce it (the cost tiers preferred a cheap shortage over an
-- inefficient but valid real chain). The net-flow / catalyst heuristics in
-- create_problem cannot see this a priori (it is a cost outcome, visible only
-- after solving), and an upfront export-feasibility seed over-fires: a Gleba
-- <grow> loop is export-feasible too but closes on its own and must NOT be
-- seeded. The two-pass separates them empirically:
--
--   1. solve once;
--   2. diagnose: which materials carry a non-zero cheat (shortage / elastic)
--      AND are export_feasible (their cycle CAN yield them) -> AVOIDABLE;
--   3. re-seed those as create_problem `forced_imports` and solve again.
--
-- A material that cheats but is NOT export-feasible (a fabricated dead-end
-- intermediate, or a base resource only the prototype layer knows is suppliable
-- -- see the base-resource-import-signal branch) is left alone and keeps its
-- |shortage_source| escape hatch. A material that is export-feasible but never
-- cheated (Gleba bioflux) is never diagnosed, so it is never spuriously seeded.
--
-- This branch fixes the limestone explorer case (avoidable) on its own; the
-- tuuphra one is unavoidable (its self-loop cannot self-produce) and still needs
-- the orthogonal base-resource signal.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

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

-- Run create_problem + solve, return the packed primal map.
local function solve(name, constraints, lines, forced)
    local problem = cp.create_problem(name, constraints, lines, forced)
    local state, vars = harness.solve_to_completion(lp, problem,
        { tolerance = 1e-6, iterate_limit = 600 })
    harness.assert_eq(state, "finished", name .. " solver_state")
    return vars.x
end

local function cheat_mass(x)
    local cheat = 0
    for k, v in pairs(x) do
        if math.abs(v) > 1e-6
            and (k:find("|shortage_source|", 1, true) or k:find("|elastic|", 1, true)) then
            cheat = cheat + math.abs(v)
        end
    end
    return cheat
end

local function set_keys(s)
    local out = {}
    for k in pairs(s) do out[#out + 1] = k end
    table.sort(out)
    return out
end

local cases = {}

-- An export-feasible cycle that the LP fabricates anyway. `target` is both
-- produced and consumed inside a {target, mid} cycle that CAN net-produce it
-- (export_feasible: x=(1,1) gives target +1, mid balanced), but the only entry
-- runs through an expensive raw, so per unit of target the real chain costs more
-- than the |shortage_source| penalty (elastic_cost = 2^10) -- exactly limestone's
-- shape, where a long mass-losing upstream made fabrication look cheaper. The
-- cycle is also self-sustaining, so the net-flow / catalyst heuristics skip it.
-- Pass 1 cheats; the diagnose pass sees the cheat IS export-feasible and re-seeds
-- it as an import; pass 2 closes at zero cheat.
--   r1: 1 target + 2000 raw -> 1 mid     (expensive entry: cost > shortage)
--   r2: 1 mid               -> 2 target  (recycles to a net surplus)
table.insert(cases, {
    name = "avoidable cheat: export-feasible cycle is imported on the second pass",
    run = function()
        -- `raw` has no producer, so it is a priced |initial_source| (cost 1/unit);
        -- 2000 of it per target makes the real chain cost 2000/target, above the
        -- 1024 shortage penalty. (A free mining recipe for raw would zero that cost
        -- and the LP would just run the chain -- the cheat needs a priced input.)
        local lines = {
            line("r1", { it("mid", 1) }, { it("target", 1), it("raw", 2000) }),
            line("r2", { it("target", 2) }, { it("mid", 1) }),
        }
        local constraints = {
            { type = "item", name = "target", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        -- Pass 1: target is trapped in the cycle (unreachable) and fabricating it
        -- (1024 / unit) undercuts the 2000-raw real chain, so the LP cheats.
        local x1 = solve("avoidable-p1", constraints, lines, nil)
        harness.assert_true(cheat_mass(x1) > 0.1,
            "pass 1 fabricates the target (got cheat " .. cheat_mass(x1) .. ")")

        -- Diagnose + reclassify: the cheat is avoidable (the cycle CAN make it).
        -- Which cycle material the LP fabricates is its own choice -- here it
        -- cheats `mid` (0.5 mid at 1024 makes 1 target via r2, cheaper than
        -- fabricating 1 target directly) -- so assert the set is non-empty rather
        -- than naming one.
        local avoidable = cp.diagnose_avoidable_cheats(x1, lines) or {}
        harness.assert_true(#set_keys(avoidable) > 0,
            "a cheated cycle material is diagnosed as avoidable (export-feasible)")

        -- Pass 2: re-seed and re-solve -> no cheat (imported below the penalty).
        local x2 = solve("avoidable-p2", constraints, lines, avoidable)
        harness.assert_near(cheat_mass(x2), 0, 1e-3,
            "pass 2 imports/runs the chain with zero cheat (got " .. cheat_mass(x2) .. ")")
        local imported = false
        for k, v in pairs(x2) do
            if k:find("|initial_source|", 1, true) and math.abs(v) > 1e-6 then imported = true end
        end
        harness.assert_true(imported,
            "the reclassified material is now drawn from |initial_source|, not shortage")
    end,
})

-- The unavoidable companion: a dead-end self-loop whose only producer needs the
-- material itself, fed by nothing reachable. It cheats AND is NOT export-feasible
-- (no positive circulation yields it), so diagnose leaves it on shortage.
table.insert(cases, {
    name = "unavoidable cheat: a non-producible dead-end is NOT reclassified",
    run = function()
        local lines = {
            -- spin needs `loop` to make `loop`+`out`; nothing else makes `loop`,
            -- so `loop` can never be produced from zero (not export-feasible).
            line("spin", { it("loop", 1.5), it("out", 1) }, { it("loop", 2) }),
        }
        local constraints = {
            { type = "item", name = "out", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        local x1 = solve("unavoidable-p1", constraints, lines, nil)
        harness.assert_true((x1["|shortage_source|item/loop/normal"] or 0) > 0.1,
            "pass 1 fabricates loop via shortage")

        local avoidable = cp.diagnose_avoidable_cheats(x1, lines)
        harness.assert_true(not avoidable["item/loop/normal"],
            "loop is NOT diagnosed as avoidable (no flow produces it). got: " ..
            table.concat(set_keys(avoidable), ", "))
        harness.assert_eq(#set_keys(avoidable), 0, "nothing reclassified")
    end,
})

-- Self-sustaining mass-positive loop (Gleba <grow> shape) never cheats, so even
-- though its materials are export-feasible the diagnose pass never touches them.
table.insert(cases, {
    name = "export-feasible but no cheat: a mass-positive grow loop is left alone",
    run = function()
        local lines = {
            line("agricultural-science-pack",
                { it("agricultural-science-pack", 0.75) },
                { it("nutrients", 0.25), it("bioflux", 0.5) }),
            line("nutrients-from-bioflux", { it("nutrients", 59.75) }, { it("bioflux", 5) }),
            line("bioflux", { it("bioflux", 2) }, { it("nutrients", 0.25), it("yumako-mash", 5) }),
            line("yumako-processing",
                { it("yumako-mash", 6), it("yumako-seed", 0.06) },
                { it("yumako", 2), it("nutrients", 0.25) }),
            line("grow-yumako-tree", { it("yumako", 0.166667) }, { it("yumako-seed", 0.003333) }),
        }
        local constraints = {
            { type = "item", name = "agricultural-science-pack", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 0.5 },
        }

        local x1 = solve("grow-p1", constraints, lines, nil)
        harness.assert_near(cheat_mass(x1), 0, 1e-3,
            "the grow loop closes via real recipes with no cheat (got " .. cheat_mass(x1) .. ")")

        local avoidable = cp.diagnose_avoidable_cheats(x1, lines)
        harness.assert_eq(#set_keys(avoidable), 0,
            "nothing to reclassify -- no cheat to diagnose (got: " ..
            table.concat(set_keys(avoidable), ", ") .. ")")
    end,
})

return cases
