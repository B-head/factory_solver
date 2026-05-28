-- create_problem's material classification: every material in the active line
-- set is wired into the LP as exactly one role depending on whether it is
-- produced, consumed, both, or neither, and (when in a cycle) whether it is
-- reachable. The other fixtures lean on this implicitly; here we assert the
-- *classes of primal create_problem emits*, not just the solved rates, so a
-- change to the translation logic is caught directly.
--
-- Roles (create_problem.lua, the included_products / included_ingredients
-- pass):
--   produced AND consumed  -> |surplus_sink| (+ |shortage_source| if it is
--                             a cycle material not reachable from raw input)
--   product only           -> |final_sink|
--   ingredient only        -> |basic_source| at source_cost
--
-- Fixture chain: raw -[r1]-> mid -[r2]-> final + byprod, with `final` pinned.
--   raw    : ingredient only      -> basic_source
--   mid    : produced + consumed  -> surplus_sink (reachable, so NO shortage)
--   final  : product only         -> final_sink
--   byprod : product only         -> final_sink

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local function item(name, amount)
    return { type = "item", name = name, quality = "normal", amount_per_second = amount }
end

local function line(recipe_name, products, ingredients)
    return {
        recipe_typed_name = { type = "recipe", name = recipe_name, quality = "normal" },
        products = products,
        ingredients = ingredients,
        power_per_second = 0,
        pollution_per_second = 0,
    }
end

local cases = {}

table.insert(cases, {
    name = "each material gets exactly the source/sink role its produced/consumed status implies",
    run = function()
        local lines = {
            line("r1", { item("mid", 1) }, { item("raw", 1) }),
            line("r2", { item("final", 1), item("byprod", 1) }, { item("mid", 1) }),
        }
        local constraints = {
            { type = "item", name = "final", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 5 },
        }

        local problem = cp.create_problem("classify", constraints, lines)

        local function has(name) return problem.primals[name] ~= nil end

        -- raw: ingredient only -> basic_source, nothing else.
        harness.assert_true(has("|basic_source|item/raw/normal"), "raw -> basic_source")
        harness.assert_true(not has("|final_sink|item/raw/normal"), "raw is not a final product")
        harness.assert_true(not has("|surplus_sink|item/raw/normal"), "raw is not an intermediate")

        -- mid: produced + consumed -> surplus_sink, and NOT a basic_source /
        -- final_sink. Reachable from raw, so the cycle escape hatch
        -- |shortage_source| must NOT be added.
        harness.assert_true(has("|surplus_sink|item/mid/normal"), "mid -> surplus_sink")
        harness.assert_true(not has("|shortage_source|item/mid/normal"),
            "mid is reachable from raw, so no shortage_source escape hatch")
        harness.assert_true(not has("|basic_source|item/mid/normal"),
            "mid has a producer, so it is not sourced externally")
        harness.assert_true(not has("|final_sink|item/mid/normal"),
            "mid is consumed downstream, so it is not a final product")

        -- final + byprod: product only -> final_sink.
        harness.assert_true(has("|final_sink|item/final/normal"), "final -> final_sink")
        harness.assert_true(has("|final_sink|item/byprod/normal"),
            "byprod (product with no consumer) -> final_sink")
        harness.assert_true(not has("|basic_source|item/byprod/normal"),
            "byprod is produced, not sourced")

        -- And the rates still solve correctly: r1 = r2 = 5, raw drawn 5,
        -- mid balances (no surplus), final + byprod come out at 5 each.
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 300 })
        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        harness.assert_near(vars.x["recipe/r1/normal"], 5, 0.05, "r1 rate")
        harness.assert_near(vars.x["recipe/r2/normal"], 5, 0.05, "r2 rate")
        harness.assert_near(vars.x["|basic_source|item/raw/normal"], 5, 0.05, "raw drawn")
        harness.assert_near(vars.x["|surplus_sink|item/mid/normal"], 0, 0.05,
            "mid balances exactly -- no surplus")
        harness.assert_near(vars.x["|final_sink|item/final/normal"], 5, 0.05, "final output")
        harness.assert_near(vars.x["|final_sink|item/byprod/normal"], 5, 0.05, "byprod output")
    end,
})

table.insert(cases, {
    name = "a self-consumed intermediate in a dead-end cycle gets a shortage_source escape hatch",
    -- Contrast to the reachable `mid` above: here the only producer of `loop`
    -- also consumes it (a mass-losing self-loop with no raw seed), so `loop`
    -- is produced + consumed but NOT reachable from any open boundary. The
    -- reachability gate must therefore give it a |shortage_source| so the LP
    -- can still satisfy the `out` demand instead of being forced to all-zero.
    --
    -- spin: 1 loop + 1 seedless-raw... no -- to make it genuinely unreachable
    -- the cycle has no external producer at all: spin consumes `loop` and
    -- produces `loop` + `out`, mass-losing (2 loop in, 1 loop + 1 out back).
    run = function()
        local lines = {
            line("spin", { item("loop", 1), item("out", 1) }, { item("loop", 2) }),
        }
        local constraints = {
            { type = "item", name = "out", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("deadend-cycle", constraints, lines)

        harness.assert_true(problem.primals["|shortage_source|item/loop/normal"] ~= nil,
            "an unreachable cycle material gets a shortage_source escape hatch")
        harness.assert_true(problem.primals["|surplus_sink|item/loop/normal"] ~= nil,
            "and still gets its surplus_sink as a produced+consumed material")

        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })
        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        -- The demand is met by paying the shortage rather than returning zero.
        harness.assert_true((vars.x["recipe/spin/normal"] or 0) > 0.5,
            "spin runs to make `out` (got " .. tostring(vars.x["recipe/spin/normal"]) .. ")")
        harness.assert_true((vars.x["|shortage_source|item/loop/normal"] or 0) > 0.1,
            "the dead-end loop is fed by the shortage_source escape hatch")
    end,
})

table.insert(cases, {
    name = "the same cycle with an external producer is fed by the producer, not a shortage_source",
    -- The counterpart to the dead-end case: the same mass-losing `spin` cycle,
    -- but now a `feed` recipe produces `loop` from a raw input. That external
    -- edge into the cycle makes its SCC non-source, so find_deficit_materials
    -- does NOT flag `loop`; and because `loop` is now reachable from `raw`,
    -- the reachability gate adds NO shortage_source. The cycle is supplied by
    -- the real producer chain instead -- which is exactly what adding an
    -- asteroid-collector / ingredient source does for a starved loop in game.
    run = function()
        local lines = {
            line("spin", { item("loop", 1), item("out", 1) }, { item("loop", 2) }),
            line("feed", { item("loop", 1) }, { item("raw", 1) }),
        }
        local constraints = {
            { type = "item", name = "out", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("fed-cycle", constraints, lines)

        -- loop is produced + consumed -> surplus_sink, but with a real
        -- producer it is neither sourced externally nor short.
        harness.assert_true(problem.primals["|surplus_sink|item/loop/normal"] ~= nil,
            "loop -> surplus_sink")
        harness.assert_true(problem.primals["|shortage_source|item/loop/normal"] == nil,
            "no shortage_source: loop is reachable from raw via feed")
        harness.assert_true(problem.primals["|basic_source|item/loop/normal"] == nil,
            "no basic_source: loop has a real producer (not a source-SCC deficit)")
        harness.assert_true(problem.primals["|basic_source|item/raw/normal"] ~= nil,
            "raw is the genuine external input")

        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })
        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        -- spin makes 1 out; the cycle's net -1 loop/run is covered by feed
        -- from raw, not by a shortage.
        harness.assert_near(vars.x["recipe/spin/normal"], 1, 0.05, "spin makes the out demand")
        harness.assert_near(vars.x["recipe/feed/normal"], 1, 0.1, "feed supplies the loop deficit from raw")
        harness.assert_near(vars.x["|basic_source|item/raw/normal"], 1, 0.1, "raw drawn to feed the cycle")
    end,
})

return cases
