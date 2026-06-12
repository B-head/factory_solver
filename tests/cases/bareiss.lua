-- Tests for the Bareiss (fraction-free) elimination family on the CSR layer.
-- Two implementations live side by side: a dense `*_reference` pair that is easy
-- to read, and a sparse `bareiss_algorithm` that operates on the CSR list-of-list
-- form. The reference exists to pin the sparse version down, so the core of this
-- file is "the two agree" plus a couple of solvable systems with known answers.
-- Nothing in the shipped solver consumes these yet; they are a reusable library.

local harness = require "tests/harness"
local csr = require "solver/csr_matrix"

local cases = {}

-- A * x = b with the textbook solution x = (2, 3, -1).
local A_DENSE = { { 2, 1, -1 }, { -3, -1, 2 }, { -2, 1, 2 } }
local B_LIST = { 8, -11, -3 }
local X_EXPECTED = { 2, 3, -1 }

table.insert(cases, {
    name = "reference bareiss + reduced echelon recovers a known solution",
    run = function()
        local a = csr.from_matrix(A_DENSE)
        local b = csr.with_vector(B_LIST)
        -- bareiss_algorithm_reference prepends the augment column, so after full
        -- reduction the leading column of each pivot row holds the solution.
        local echelon = csr.bareiss_algorithm_reference(a, b)
        local reduced = csr.to_matrix(csr.reduce_echelon_reference(echelon, 1e-9))
        for y = 1, #X_EXPECTED do
            harness.assert_near(reduced[y][1], X_EXPECTED[y], 1e-9,
                "solution component " .. y)
        end
    end,
})

table.insert(cases, {
    name = "sparse bareiss_algorithm agrees with the dense reference",
    run = function()
        local a = csr.from_matrix(A_DENSE)
        local b = csr.with_vector(B_LIST)

        local ref = csr.to_matrix(csr.bareiss_algorithm_reference(a, b))
        local opt_matrix, opt_augment = csr.bareiss_algorithm(a, b)
        opt_matrix = csr.to_matrix(opt_matrix)
        opt_augment = csr.to_list(opt_augment)

        -- The reference carries the augment as a prepended first column; the
        -- sparse version returns it separately. Stripping that column should make
        -- the two echelon forms identical.
        local expected_matrix = {}
        for y = 1, #ref do
            local row = {}
            for x = 2, #ref[y] do
                row[x - 1] = ref[y][x]
            end
            expected_matrix[y] = row
            harness.assert_near(opt_augment[y], ref[y][1], 1e-9,
                "augment row " .. y)
        end
        harness.assert_matrix_near(opt_matrix, expected_matrix, 1e-9,
            "echelon matrices agree")
    end,
})

table.insert(cases, {
    name = "extra_substitution yields a null-space vector",
    run = function()
        -- A wide (under-determined) homogeneous system: A2 has a 1-D null space.
        -- extra_substitution sets free variables to 1 and back-solves, so the
        -- result must satisfy A2 * x = 0.
        local a2 = csr.from_matrix({ { 1, 2, 3 }, { 0, 1, 1 } })
        local echelon = csr.bareiss_algorithm_reference(a2)
        local reduced = csr.reduce_echelon_reference(echelon, 1e-9)
        local solved = csr.extra_substitution(reduced)

        -- It must be a non-trivial vector (free var pinned to 1, not all zeros).
        local solved_list = csr.to_list(solved)
        local nonzero = false
        for _, v in ipairs(solved_list) do
            if math.abs(v) > 1e-12 then nonzero = true end
        end
        harness.assert_true(nonzero, "null-space vector is non-trivial")

        harness.assert_matrix_near(csr.to_matrix(a2 * solved),
            { { 0 }, { 0 } }, 1e-9, "A2 * x = 0")
    end,
})

return cases
