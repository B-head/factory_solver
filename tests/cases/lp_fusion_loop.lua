-- Fusion power: an "outlet-less" closed loop with NO LP-visible final
-- product. The real output is electricity, which factory_solver does not
-- model as an LP material (electricity-only producers aren't given virtual
-- recipes), so there is no |final_sink| anywhere. The entire solve is driven
-- by a single input cap on fusion-power-cell.
--
-- Captured from a real Space Age save. Loop structure:
--   fusion-reactor:      4 fluoroketone-cold@[-150,180] + 0.00025 power-cell
--                          -> 4 fusion-plasma@1e6
--   fusion-generator:    1.999998 fusion-plasma@[1e6,1e7]
--                          -> 1.999998 fluoroketone-hot@180   (+ electricity)
--   fluoroketone-cooling: 4 fluoroketone-hot@[180,180]
--                          -> 4 fluoroketone-cold@-150
-- with temperature bridges relabelling each single-temperature flow to the
-- range-temperature dual the consumer reads:
--   fk-cold@-150 -> [-150,180], fk-hot@180 -> [180,180],
--   plasma@1e6 -> [1e6,1e7].
-- The fluoroketone cools, heats, and recools in a perfect cycle; the only
-- mass entering is the power-cell, the only thing leaving is (unmodelled)
-- electricity.
--
-- This fixture is xfail: the problem is feasible and bounded -- in-game it
-- converged in 18 iterations (Solution 7) -- but the headless COLD start
-- fails with "Cholesky lost precision" around iteration 13. Verified that a
-- warm start seeded near the optimum (x ~ 266 on the bridges, 1/60 on the
-- power-cell) converges in ~15 iterations, so the in-game success came from
-- warm-starting off a prior solve while the user iterated on this factory.
--
-- Root cause -- a cold-start scaling gap: the IPM seeds x_0 proportional to
-- ||b||_inf (see the cold-start block in solver/linear_programming.lua). Here
-- ||b||_inf = 1/60 ~ 0.0167 (the lone power-cell cap), but the true optimum
-- has x ~ 266 on the fluid bridges -- a ~16000x gap. The amplifier is the
-- 0.00025 power-cell coefficient in the fusion-reactor row: a tiny input cap
-- drives a huge internal fluid throughput. Starting x ~ 0.0167 when the
-- optimum is ~266, the first Newton steps pin most slacks at the 2^-52 clamp,
-- D^2 = X.S^-1 blows its dynamic range, and the unpivoted Cholesky hits a
-- zero/NaN pivot that the ε.I retry can't recover. The symmetric
-- ||b||-vs-||c|| scaling argument in the solver comments assumes x ~ ||b||;
-- this outlet-less loop is the counterexample where a small cap fans out into
-- a large-throughput cycle. See [[ipm-cold-start-small-cap-large-loop]].
--
-- The assertions below describe the DESIRED outcome (converged, loop closed).
-- They fail today (cold start -> "unfinished"); when the cold-start scaling
-- learns to account for coefficient-driven amplification this becomes XPASS
-- and should be promoted to a normal case.
--
-- Two structural points the fixture also exercises once it does converge:
--  1. Outlet-less: with no |final_sink| to pull on, the solve is anchored
--     purely by the fusion-power-cell |limit| (= 1/60, an upper cap whose
--     2^20 slack pins it to equality).
--  2. The loop closes cleanly across three temperature bridges spanning
--     -150 .. 1e7, with the fusion fluid-throughput coefficient 1.999998
--     (not exactly 2; from get_fluid_usage_per_tick), so the loop ratios are
--     very slightly irrational.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local pg = require "solver/problem_generator"

local cases = {}

table.insert(cases, {
    name = "outlet-less fusion loop: cold start fails to converge (feasible in-game via warm start)",
    xfail = true,
    run = function()
        local p = pg.new("fusion-outlet-less-loop")

        p:add_objective("r/generator", 0, true)
        p:add_objective("r/reactor",   0, true)
        p:add_objective("r/cooling",   0, true)
        p:add_objective("bridge/cold",   0, true)
        p:add_objective("bridge/hot",    0, true)
        p:add_objective("bridge/plasma", 0, true)

        local fluids = {
            "fk-hot@180", "plasma@1e6", "fk-cold@-150",
            "fk-cold@range", "fk-hot@range", "plasma@range",
        }
        for _, f in ipairs(fluids) do
            p:add_objective("|surplus_sink|" .. f, 1024, false)
            p:add_objective("|shortage_source|" .. f, 1024, false)
        end

        p:add_objective("|basic_source|power-cell", 1, false)
        p:add_objective("%positive_slack%|limit|power-cell", 1048576, false)

        for _, f in ipairs(fluids) do
            p:add_equivalence_constraint(f, 0)
        end
        p:add_equivalence_constraint("power-cell", 0)
        p:add_equivalence_constraint("|limit|power-cell", 1 / 60)

        -- fk-hot@180: generator produces, bridge relabels to [180,180].
        p:add_subject_term("r/generator",   "fk-hot@180", 1.999998)
        p:add_subject_term("bridge/hot",    "fk-hot@180", -1)
        p:add_subject_term("|surplus_sink|fk-hot@180", "fk-hot@180", -1)
        p:add_subject_term("|shortage_source|fk-hot@180", "fk-hot@180", 1)

        -- plasma@1e6: reactor produces, bridge relabels to [1e6,1e7].
        p:add_subject_term("r/reactor",     "plasma@1e6", 4)
        p:add_subject_term("bridge/plasma", "plasma@1e6", -1)
        p:add_subject_term("|surplus_sink|plasma@1e6", "plasma@1e6", -1)
        p:add_subject_term("|shortage_source|plasma@1e6", "plasma@1e6", 1)

        -- fk-cold@-150: cooling produces, bridge relabels to [-150,180].
        p:add_subject_term("r/cooling",     "fk-cold@-150", 4)
        p:add_subject_term("bridge/cold",   "fk-cold@-150", -1)
        p:add_subject_term("|surplus_sink|fk-cold@-150", "fk-cold@-150", -1)
        p:add_subject_term("|shortage_source|fk-cold@-150", "fk-cold@-150", 1)

        -- fk-cold@[-150,180]: reactor consumes, bridge supplies.
        p:add_subject_term("r/reactor",     "fk-cold@range", -4)
        p:add_subject_term("bridge/cold",   "fk-cold@range", 1)
        p:add_subject_term("|surplus_sink|fk-cold@range", "fk-cold@range", -1)
        p:add_subject_term("|shortage_source|fk-cold@range", "fk-cold@range", 1)

        -- fk-hot@[180,180]: cooling consumes, bridge supplies.
        p:add_subject_term("r/cooling",     "fk-hot@range", -4)
        p:add_subject_term("bridge/hot",    "fk-hot@range", 1)
        p:add_subject_term("|surplus_sink|fk-hot@range", "fk-hot@range", -1)
        p:add_subject_term("|shortage_source|fk-hot@range", "fk-hot@range", 1)

        -- plasma@[1e6,1e7]: generator consumes, bridge supplies.
        p:add_subject_term("r/generator",   "plasma@range", -1.999998)
        p:add_subject_term("bridge/plasma", "plasma@range", 1)
        p:add_subject_term("|surplus_sink|plasma@range", "plasma@range", -1)
        p:add_subject_term("|shortage_source|plasma@range", "plasma@range", 1)

        -- power-cell: reactor consumes 0.00025, basic_source supplies.
        p:add_subject_term("r/reactor",            "power-cell", -0.00025)
        p:add_subject_term("|basic_source|power-cell", "power-cell", 1)

        -- limit row: basic_source + slack = 1/60.
        p:add_subject_term("|basic_source|power-cell",          "|limit|power-cell", 1)
        p:add_subject_term("%positive_slack%|limit|power-cell", "|limit|power-cell", 1)

        local state, vars, steps = harness.solve_to_completion(lp, p,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        harness.assert_true(steps < 100, "converged in under 100 iterations (took " .. steps .. ")")

        -- Power-cell input pinned at the cap; slack idle.
        harness.assert_near(vars.x["|basic_source|power-cell"], 1 / 60, 1e-5, "power-cell input pinned at 1/min")
        harness.assert_near(vars.x["%positive_slack%|limit|power-cell"], 0, 1e-3, "power-cell cap slack idle")

        -- Loop rates: reactor = (1/60)/0.00025 = 66.667, cooling matches,
        -- generator = 4*reactor/1.999998 ~ 133.333, bridges carry 266.667.
        harness.assert_near(vars.x["r/reactor"],     66.666667,  1e-2, "reactor rate")
        harness.assert_near(vars.x["r/cooling"],     66.666663,  1e-2, "cooling rate")
        harness.assert_near(vars.x["r/generator"],   133.333453, 1e-1, "generator rate")
        harness.assert_near(vars.x["bridge/cold"],   266.666651, 1e-1, "cold bridge flow")
        harness.assert_near(vars.x["bridge/hot"],    266.666651, 1e-1, "hot bridge flow")
        harness.assert_near(vars.x["bridge/plasma"], 266.666651, 1e-1, "plasma bridge flow")

        -- THE point: an outlet-less loop closes with no slack on either side.
        -- No final product, no shortage, no surplus -- the fluoroketone just
        -- cycles, anchored entirely by the power-cell cap.
        for _, f in ipairs(fluids) do
            harness.assert_near(vars.x["|shortage_source|" .. f], 0, 1e-3,
                "shortage|" .. f .. " idle (loop closes)")
            harness.assert_near(vars.x["|surplus_sink|" .. f], 0, 1e-3,
                "surplus|" .. f .. " idle (loop closes)")
        end
    end,
})

return cases
