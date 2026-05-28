-- Verify the human-readable dumps on Problem (used by solver.lp at "ready"
-- to capture a fixture for the headless test suite). The matrix dump is the
-- main thing this file pins: dual row-major grouping, deterministic ordering
-- by primal/dual index, and inclusion of every non-zero coefficient that
-- generate_subject_matrix would emit.

local harness = require "tests/harness"
local pg = require "solver/problem_generator"

local cases = {}

table.insert(cases, {
    name = "dump_subject_matrix groups terms by dual and orders by index",
    run = function()
        -- Two primals (r1, r2), three duals (m1, m2, m3) wired as a linear
        -- chain m1 -[r1]-> m2 -[r2]-> m3. The expected layout has m1 with
        -- one negative coefficient, m2 with one of each sign, m3 with one
        -- positive coefficient.
        local problem = pg.new("dump-chain")
        problem:add_objective("recipe/r1", 0, true)
        problem:add_objective("recipe/r2", 0, true)
        problem:add_equivalence_constraint("item/m1", 0)
        problem:add_equivalence_constraint("item/m2", 0)
        problem:add_equivalence_constraint("item/m3", 0)
        problem:add_subject_term("recipe/r1", "item/m1", -1)
        problem:add_subject_term("recipe/r1", "item/m2", 1)
        problem:add_subject_term("recipe/r2", "item/m2", -1)
        problem:add_subject_term("recipe/r2", "item/m3", 1)

        local expected = table.concat({
            "  [1]\"item/m1\":\n",
            "    [1]\"recipe/r1\" = -1.000000\n",
            "  [2]\"item/m2\":\n",
            "    [1]\"recipe/r1\" = 1.000000\n",
            "    [2]\"recipe/r2\" = -1.000000\n",
            "  [3]\"item/m3\":\n",
            "    [2]\"recipe/r2\" = 1.000000\n",
        })
        harness.assert_eq(problem:dump_subject_matrix(), expected, "matrix dump")
    end,
})

table.insert(cases, {
    name = "dump_subject_matrix skips terms whose primal or dual is unregistered",
    -- generate_subject_matrix filters out subject_terms whose endpoints
    -- aren't registered (e.g. a constraint declared and then removed); the
    -- dump must mirror that filtering so the printout matches what the LP
    -- solver actually sees.
    run = function()
        local problem = pg.new("dump-filter")
        problem:add_objective("recipe/keep", 0, true)
        problem:add_equivalence_constraint("item/keep", 0)
        -- Both endpoints registered: must appear.
        problem:add_subject_term("recipe/keep", "item/keep", 2.5)
        -- Primal not registered: must be skipped.
        problem:add_subject_term("recipe/ghost", "item/keep", 99)
        -- Dual not registered: must be skipped.
        problem:add_subject_term("recipe/keep", "item/ghost", 99)

        local expected = table.concat({
            "  [1]\"item/keep\":\n",
            "    [1]\"recipe/keep\" = 2.500000\n",
        })
        harness.assert_eq(problem:dump_subject_matrix(), expected, "matrix dump")
    end,
})

return cases
