-- LP fixtures with extreme coefficient ranges, captured from in-game solves
-- via the trace-level subject matrix dump in solver.lp's "ready" block.
--
-- The motivating case is vanilla nuclear power: the <heat> material row has
-- coefficients of 40,000,000 (reactor production) and -10,000,000 (heat
-- exchanger consumption) -- both in joule-per-tick units because heat-
-- producing entities declare power that way. The same problem includes a
-- uranium-fuel-cell row whose reactor coefficient is -0.005, giving a 10^10
-- dynamic range across rows of A in a single LP. That ratio stresses the
-- IPM's reduced normal-equation matrix A*D^2*A^T -- D^2 inherits the squared
-- column scaling, so the per-element magnitude span of the system Cholesky
-- factors hits ~10^20.
--
-- See the commentary in solver/linear_programming.lua around the cold-start
-- scaling and the Cholesky retry-on-NaN block for the design that handles
-- this regime. This file pins the behaviour with concrete coefficients so a
-- regression to "unfinished on the heat row's pivot" gets caught headlessly.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local pg = require "solver/problem_generator"

local cases = {}

table.insert(cases, {
    name = "vanilla nuclear power LP with 10^10 coefficient range converges",
    -- Captured from vanilla (no Space Age) with the trace-dumped subject
    -- matrix. Layout:
    --   uranium-fuel-cell (basic_source, capped at 1/60 per sec by an upper-
    --   limit constraint) --[reactor]--> <heat> --[heat-exchanger]-->
    --   steam@500 + consumes water@[15,100] <-[bridge]- water@15 <-[pump]--
    -- All surplus_sinks priced at 1024, the limit slack at 2^20, and the
    -- basic_source at 1 -- the BIG-M layered cost stack create_problem
    -- emits, preserved verbatim to keep the fixture representative.
    run = function()
        local p = pg.new("vanilla-nuclear")

        p:add_objective("recipe/steam-turbine", 0, true)
        p:add_objective("recipe/heat-exchanger", 0, true)
        p:add_objective("recipe/nuclear-reactor", 0, true)
        p:add_objective("recipe/pump-water", 0, true)
        p:add_objective("recipe/bridge-water", 0, true)
        p:add_objective("|surplus_sink|steam@500", 1024, false)
        p:add_objective("|surplus_sink|heat", 1024, false)
        p:add_objective("|surplus_sink|water@15", 1024, false)
        p:add_objective("|surplus_sink|water@[15,100]", 1024, false)
        p:add_objective("|basic_source|uranium-fuel-cell", 1, false)
        p:add_objective("%positive_slack%|limit|uranium-fuel-cell", 1048576, false)

        p:add_equivalence_constraint("steam@500", 0)
        p:add_equivalence_constraint("heat", 0)
        p:add_equivalence_constraint("water@15", 0)
        p:add_equivalence_constraint("water@[15,100]", 0)
        p:add_equivalence_constraint("uranium-fuel-cell", 0)
        p:add_equivalence_constraint("|limit|uranium-fuel-cell", 1 / 60)

        p:add_subject_term("recipe/steam-turbine",       "steam@500",   -60)
        p:add_subject_term("recipe/heat-exchanger",      "steam@500",    103.092784)
        p:add_subject_term("|surplus_sink|steam@500",    "steam@500",   -1)

        -- The extreme row: heat balance in J/tick.
        p:add_subject_term("recipe/heat-exchanger",      "heat",        -10000000)
        p:add_subject_term("recipe/nuclear-reactor",     "heat",         40000000)
        p:add_subject_term("|surplus_sink|heat",         "heat",        -1)

        p:add_subject_term("recipe/pump-water",          "water@15",     1200)
        p:add_subject_term("recipe/bridge-water",        "water@15",    -1)
        p:add_subject_term("|surplus_sink|water@15",     "water@15",    -1)

        p:add_subject_term("recipe/heat-exchanger",      "water@[15,100]", -10.309278)
        p:add_subject_term("recipe/bridge-water",        "water@[15,100]",  1)
        p:add_subject_term("|surplus_sink|water@[15,100]","water@[15,100]", -1)

        -- And the opposite extreme: a 0.005 coefficient sharing the LP.
        p:add_subject_term("recipe/nuclear-reactor",                       "uranium-fuel-cell", -0.005)
        p:add_subject_term("|basic_source|uranium-fuel-cell",              "uranium-fuel-cell",  1)

        p:add_subject_term("|basic_source|uranium-fuel-cell",              "|limit|uranium-fuel-cell", 1)
        p:add_subject_term("%positive_slack%|limit|uranium-fuel-cell",     "|limit|uranium-fuel-cell", 1)

        local state, vars, steps = harness.solve_to_completion(lp, p,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        harness.assert_true(steps < 100, "converged in under 100 iterations (took " .. steps .. ")")

        -- Expected rates derived from the limit (basic_source <= 1/60):
        --   reactor       = (1/60) / 0.005           = 10/3
        --   heat-exch     = reactor * 40e6 / 10e6    = 40/3
        --   bridge        = heat-exch * 10.309278    = 137.457...
        --   pump          = bridge / 1200            = 0.114548...
        --   turbine       = heat-exch * 103.092784 / 60 = 22.909507...
        -- All surplus_sinks and the limit slack stay near zero at optimum.
        harness.assert_near(vars.x["recipe/nuclear-reactor"],            10 / 3,    1e-3, "reactor rate")
        harness.assert_near(vars.x["recipe/heat-exchanger"],             40 / 3,    1e-3, "heat-exch rate")
        harness.assert_near(vars.x["recipe/bridge-water"],               137.457045, 1e-2, "bridge flow")
        harness.assert_near(vars.x["recipe/pump-water"],                 0.114548,  1e-4, "pump rate")
        harness.assert_near(vars.x["recipe/steam-turbine"],              22.909507, 1e-3, "turbine rate")
        harness.assert_near(vars.x["|basic_source|uranium-fuel-cell"],   1 / 60,    1e-5, "uranium uptake at 1/min")
        harness.assert_near(vars.x["%positive_slack%|limit|uranium-fuel-cell"], 0,  1e-4, "limit slack idle")
    end,
})

return cases
