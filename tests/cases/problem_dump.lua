-- Verify the dumps used to capture headless fixtures from a live game:
--   - Problem:dump_subject_matrix / dump_primal / dump_dual (solver.lp at
--     "ready"): human-readable, pinned for dual row-major grouping,
--     deterministic index ordering, and full non-zero coefficient coverage.
--   - create_problem.dump_normalized_lines / dump_constraints: load()-able Lua
--     that round-trips the exact create_problem input, so an in-game solve
--     (enable with `/factory-solver-log-level trace`) can be replayed as a
--     fixture. Pinned for round-trip fidelity.

local harness = require "tests/harness"
local pg = require "solver/problem_generator"
local cp = require "solver/create_problem"

---Structural deep-equality for the plain tables these dumps round-trip.
---@param a any
---@param b any
---@return boolean
local function deep_eq(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not deep_eq(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

---Load a `return {...}` chunk produced by the dumpers and hand back the table.
---@param chunk string
---@return any
local function load_dump(chunk)
    local fn = assert(load(chunk, "dump", "t"))
    return fn()
end

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

table.insert(cases, {
    name = "dump_normalized_lines round-trips a NormalizedProductionLine[]",
    -- Covers every optional field: a fuel_ingredient, a fluid product with a
    -- temperature, and a fluid ingredient with a temperature range, plus the
    -- two mandatory amount arrays and the power/pollution scalars.
    run = function()
        local lines = {
            {
                recipe_typed_name = { type = "recipe", name = "alpha", quality = "normal" },
                products = {
                    { type = "item", name = "plate", quality = "uncommon", amount_per_second = 2.5 },
                    { type = "fluid", name = "steam", quality = "normal",
                      amount_per_second = 60, temperature = 165 },
                },
                ingredients = {
                    { type = "item", name = "ore", quality = "normal", amount_per_second = 1 },
                    { type = "fluid", name = "water", quality = "normal", amount_per_second = 10,
                      minimum_temperature = 15, maximum_temperature = 100 },
                },
                fuel_ingredient = { type = "item", name = "coal", quality = "normal",
                    amount_per_second = 0.0099999997764826 },
                power_per_second = 120000,
                pollution_per_second = 4,
            },
            {
                recipe_typed_name = { type = "virtual_recipe", name = "<grow>tree", quality = "rare" },
                products = { { type = "item", name = "fruit", quality = "rare",
                    amount_per_second = 0.16666666666666666 } },
                ingredients = { { type = "item", name = "seed", quality = "rare",
                    amount_per_second = 0.0033333333333333 } },
                power_per_second = 0,
                pollution_per_second = 0,
            },
        }

        local dumped = cp.dump_normalized_lines(lines)
        local loaded = load_dump(dumped)
        harness.assert_true(deep_eq(loaded, lines), "loaded lines must equal the originals")
        -- Re-dumping the loaded table reproduces the chunk byte-for-byte:
        -- proves the output is deterministic and lossless (%.17g round-trip).
        harness.assert_eq(cp.dump_normalized_lines(loaded), dumped, "re-dump is stable")
    end,
})

table.insert(cases, {
    name = "dump_constraints round-trips a Constraint[]",
    run = function()
        local constraints = {
            { type = "item", name = "science", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 0.5 },
            { type = "fluid", name = "steam", quality = "normal",
              limit_type = "upper", limit_amount_per_second = 1000,
              minimum_temperature = 15, maximum_temperature = 1000 },
            { type = "recipe", name = "crushing", quality = "legendary",
              limit_type = "upper", limit_amount_per_second = 1 },
        }

        local dumped = cp.dump_constraints(constraints)
        local loaded = load_dump(dumped)
        harness.assert_true(deep_eq(loaded, constraints), "loaded constraints must equal the originals")
        harness.assert_eq(cp.dump_constraints(loaded), dumped, "re-dump is stable")
    end,
})

table.insert(cases, {
    name = "dumped lines feed back into create_problem",
    -- The point of the dump is replay: a loaded fixture must be accepted by
    -- create_problem unchanged. A simple two-recipe chain with one target.
    run = function()
        local lines = {
            {
                recipe_typed_name = { type = "recipe", name = "smelt", quality = "normal" },
                products = { { type = "item", name = "plate", quality = "normal", amount_per_second = 1 } },
                ingredients = { { type = "item", name = "ore", quality = "normal", amount_per_second = 1 } },
                power_per_second = 0,
                pollution_per_second = 0,
            },
        }
        local constraints = {
            { type = "item", name = "plate", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        local loaded_lines = load_dump(cp.dump_normalized_lines(lines))
        local loaded_constraints = load_dump(cp.dump_constraints(constraints))
        local problem = cp.create_problem("replay", loaded_constraints, loaded_lines)
        harness.assert_true(problem ~= nil, "create_problem accepts the replayed fixture")
    end,
})

return cases
