-- Cholesky factorization micro-benchmark + bit-identity harness (pure Lua, no
-- Factorio). Extracts a real reduced-normal-equations matrix P = A·D²·Aᵀ from a
-- corpus problem's IPM solve, then times csr.cholesky_decomposition against the
-- memoized variant (when present) and asserts the two produce bit-identical
-- factorizations -- compared through forward/backward substitution on a fixed RHS,
-- the way solve_step actually consumes L/D, so explicit-zero structure differences
-- (the memo keeps the no-cancellation fill superset) don't register as a diff.
--
-- Stock `lua` here, NOT luajit: Factorio's runtime is a plain Lua 5.2 interpreter,
-- so the branch / indexing overhead this optimization targets shows up under stock
-- lua and is JIT-erased under luajit. Measure with `lua`, confirm in-engine after.
--
--   lua tests/research/bench_cholesky.lua <dump> [reps]

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local csr = require "solver/csr_matrix"
local problem_dump = require "tests/problem_dump"

local path = arg[1] or error("usage: lua bench_cholesky.lua <dump> [reps]")
local reps = tonumber(arg[2]) or 200

local prob = assert(problem_dump.load_problem(path), "load failed: " .. path)

local function copy_csr(P)
    local function arr(a) local b = {}; for i = 1, #a do b[i] = a[i] end; return b end
    return csr.new(P.width, arr(P.values), arr(P.column_indexes), arr(P.row_ranges))
end

-- Build the problem and run the IPM, capturing the LARGEST P handed to cholesky
-- (the worst-case factorization, the one that dominates per-tick cost).
local p = create_problem.create_problem("bench", prob.constraints, prob.normalized_lines, nil,
    { reachability_gating = false })
local captured
local orig = csr.cholesky_decomposition
csr.cholesky_decomposition = function(P, ...)
    local h = #P.row_ranges - 1
    if not captured or h > captured.h then captured = { h = h, P = copy_csr(P) } end
    return orig(P, ...)
end
do
    local state, iter, vars = "ready", nil, nil
    for _ = 1, 80 do
        state, iter, vars = lp.solve(p, state, iter, vars, 1e-7, 600)
        if state ~= "calculating" and state ~= "ready" then break end
    end
end
csr.cholesky_decomposition = orig
assert(captured, "no cholesky call captured")

local P = captured.P
local h = captured.h
local nnzP = P.row_ranges[#P.row_ranges] - 1
print(string.format("P: h=%d nnz=%d  (from %s)", h, nnzP, path:match("([^/\\]+)$") or path))

-- A fixed RHS to push through the factorization: solving L·D·Lᵀ z = b exercises
-- forward_substitution(L·D, b) then backward_substitution(Lᵀ, ...), exactly the
-- solve_step consumption path. Deterministic (no rng) so re-runs compare.
local function rhs(n)
    local b = {}
    for i = 1, n do b[i] = 1 + (i % 7) * 0.5 - (i % 3) * 0.25 end
    return csr.with_vector(b)
end
local b = rhs(h)

local function apply(L, D)
    -- z = Lᵀ \ (L·D \ b)
    local y = csr.forward_substitution(L * D, b)
    return csr.backward_substitution(L:T(), y)
end

local function max_abs_diff(z1, z2)
    local a, b2 = csr.to_list(z1), csr.to_list(z2)
    local d = 0
    for i = 1, math.max(#a, #b2) do
        local x = math.abs((a[i] or 0) - (b2[i] or 0))
        if x > d then d = x end
    end
    return d
end

-- Reference factorization + its applied solution (the bit-identity oracle).
local Lref, Dref = csr.cholesky_decomposition(P)
local zref = apply(Lref, Dref)

local function bench(fn, label)
    local t0 = os.clock()
    local L, D
    for _ = 1, reps do L, D = fn(P) end
    local dt = os.clock() - t0
    print(string.format("  %-10s %8.2f ms total / %7.4f ms per call (%d reps)",
        label, dt * 1000, dt * 1000 / reps, reps))
    return L, D
end

print(string.format("reps=%d", reps))
bench(csr.cholesky_decomposition, "reference")

if csr.cholesky_decomposition_memo then
    csr.reset_cholesky_memo()
    local Lm, Dm = csr.cholesky_decomposition_memo(P)
    local zm = apply(Lm, Dm)
    local d = max_abs_diff(zref, zm)
    print(string.format("bit-identity (memo vs reference, applied to RHS): max|Δz| = %.3g  -> %s",
        d, d == 0 and "EXACT" or (d < 1e-12 and "near (NOT bit-exact)" or "DIFFER")))
    -- Tape footprint per pattern (decides whether a multi-slot cache is viable).
    local tape = csr.build_cholesky_tape(P)
    local nums = #tape.ti + #tape.tk + #tape.tw + #tape.out_col + #tape.out_rr
        + #tape.tstart + #tape.tov + #tape.d_ov + #tape.sig_col + #tape.sig_rr
    print(string.format("tape: %d FMA entries, %d structure  ~= %.1f MB/pattern (Lua array est.)",
        #tape.ti, #tape.out_col, nums * 16 / 1e6))

    -- micro-bench reuses ONE P, so the tape is built once and replayed; this is the
    -- best case (warm cache).
    csr.reset_cholesky_memo()
    bench(csr.cholesky_decomposition_memo, "memo(warm)")

    -- Cache-warmth census: re-run a REAL solve with the memo on and count how many
    -- of its cholesky calls had to rebuild the tape. If P's pattern is stable across
    -- a build's iterations the rebuilds stay near 1; if the matmul prunes value
    -- zeros so the pattern flickers, rebuilds track the call count and the memo
    -- thrashes (the in-engine result that motivated this check).
    local lp_mod = require "solver/linear_programming"
    local before = csr.cholesky_rebuild_count
    local calls = 0
    local orig2 = csr.cholesky_decomposition_memo
    csr.cholesky_decomposition_memo = function(...) calls = calls + 1; return orig2(...) end
    lp_mod.cholesky_memo = true
    csr.reset_cholesky_memo()
    local p2 = create_problem.create_problem("census", prob.constraints, prob.normalized_lines, nil,
        { reachability_gating = false })
    local state, iter, vars = "ready", nil, nil
    for _ = 1, 600 do
        state, iter, vars = lp_mod.solve(p2, state, iter, vars, 1e-7, 600)
        if state ~= "calculating" and state ~= "ready" then break end
    end
    csr.cholesky_decomposition_memo = orig2
    local rebuilds = csr.cholesky_rebuild_count - before
    print(string.format("real-solve cache warmth: %d cholesky calls, %d tape rebuilds (%.0f%% warm) -> state=%s",
        calls, rebuilds, calls > 0 and (100 * (1 - rebuilds / calls)) or 0, state))
else
    print("  (csr.cholesky_decomposition_memo not implemented yet)")
end
