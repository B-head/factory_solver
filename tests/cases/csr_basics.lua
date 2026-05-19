-- Sanity tests for the hand-rolled sparse-matrix layer.
-- These are the building blocks the IPM solver leans on; if any of them is
-- wrong the LP results downstream are meaningless.

local harness = require "tests/harness"
local csr = require "solver/csr_matrix"

local cases = {}

table.insert(cases, {
    name = "from_matrix / to_matrix roundtrip preserves sparse content",
    run = function()
        local dense = { { 1, 0, 2 }, { 0, 3, 0 }, { 4, 0, 5 } }
        local m = csr.from_matrix(dense)
        harness.assert_eq(m.width, 3, "width")
        harness.assert_matrix_near(csr.to_matrix(m), dense, 0, "roundtrip")
    end,
})

table.insert(cases, {
    name = "transpose is its own inverse",
    run = function()
        local dense = { { 1, 2, 0 }, { 0, 0, 3 } }
        local m = csr.from_matrix(dense)
        local mtt = csr.to_matrix(m:T():T())
        harness.assert_matrix_near(mtt, dense, 0, "T(T(M))")
    end,
})

table.insert(cases, {
    name = "matrix multiplication agrees with a hand-computed product",
    run = function()
        -- [1 2 0]   [1 0]   [1*1+2*0+0*1  1*0+2*1+0*0]   [1  2]
        -- [0 1 3] * [0 1] = [0*1+1*0+3*1  0*0+1*1+3*0] = [3  1]
        --           [1 0]
        local a = csr.from_matrix({ { 1, 2, 0 }, { 0, 1, 3 } })
        local b = csr.from_matrix({ { 1, 0 }, { 0, 1 }, { 1, 0 } })
        harness.assert_matrix_near(csr.to_matrix(a * b), { { 1, 2 }, { 3, 1 } }, 0, "A*B")
    end,
})

table.insert(cases, {
    name = "scalar multiplication scales every stored value",
    run = function()
        local m = csr.from_matrix({ { 1, 0 }, { 0, 2 } })
        harness.assert_matrix_near(csr.to_matrix(m * 3), { { 3, 0 }, { 0, 6 } }, 0, "M*3")
        harness.assert_matrix_near(csr.to_matrix(3 * m), { { 3, 0 }, { 0, 6 } }, 0, "3*M")
    end,
})

table.insert(cases, {
    name = "euclidean_norm on a sparse vector",
    run = function()
        local v = csr.with_vector({ 3, 0, 4 })
        harness.assert_near(v:euclidean_norm(), 5, 1e-12, "||(3,0,4)||")
    end,
})

table.insert(cases, {
    name = "hadamard product / division round-trip on a positive vector",
    run = function()
        local a = csr.with_vector({ 2, 3, 4 })
        local b = csr.with_vector({ 5, 6, 7 })
        local back = csr.hadamard_division(csr.hadamard_product(a, b), b)
        harness.assert_matrix_near(
            csr.to_matrix(back),
            { { 2 }, { 3 }, { 4 } },
            1e-12, "((a*b)/b)"
        )
    end,
})

table.insert(cases, {
    name = "Cholesky + forward/backward substitution solves a small SPD system",
    run = function()
        -- SPD matrix P = [4 2; 2 3]. LDL: L=[1 0; 0.5 1], D=diag(4, 2).
        -- Solve P * x = b for b = [6; 5]. Expect x = [1; 1].
        local P = csr.from_matrix({ { 4, 2 }, { 2, 3 } })
        local L, D = csr.cholesky_decomposition(P)
        local b = csr.with_vector({ 6, 5 })
        local temp = csr.forward_substitution(L * D, b)
        local x = csr.backward_substitution(L:T(), temp)
        harness.assert_matrix_near(csr.to_matrix(x), { { 1 }, { 1 } }, 1e-9, "P x = b")
    end,
})

return cases
