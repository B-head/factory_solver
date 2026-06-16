local csr_matrix = require("solver/csr_matrix")
local fs_log = require("fs_log")

local log = fs_log.for_module("solver.lp")
local hmul, hdiv, hpow = csr_matrix.hadamard_product, csr_matrix.hadamard_division, csr_matrix.hadamard_power

local machine_upper_epsilon = (2 ^ 52)  -- (2 ^ 511)
local machine_lower_epsilon = (2 ^ -52) -- (2 ^ -511)

-- Tuning constants for the long-step path-following IPM (Nocedal & Wright
-- "Numerical Optimization" 2e, Algorithm 14.3).
-- step_fraction is the η in α = min(1, η · α_max): 0.99 keeps iterates
-- strictly interior while still allowing close-to-full Newton steps near the
-- optimum.
-- sigma is the centring parameter; 0.1 sits close to pure Newton-on-KKT
-- (σ → 0, aggressive convergence) with enough centring to keep the iteration
-- numerically robust on the BIG-M LPs the solver pipeline produces.
local step_fraction = 0.99
local centering_sigma = 0.1

-- Dual-certified zero purification. The IPM converges to the analytic centre of
-- the optimal face, so a variable that is exactly 0 in the true optimum parks at
-- the interior-point "dust" residual x ~ mu/s instead of 0 (see the
-- recipe_epsilon note in create_problem.lua). Complementary slackness gives a
-- scale-free certificate for which residuals are provably zero: at the optimum
-- x_i*s_i = 0 with s_i >= 0, so a converged variable whose reduced cost s_i
-- dominates its value x_i sits on the dual-active (nonbasic) side and belongs at
-- 0, while a genuinely basic variable has s_i -> 0 (x_i > s_i) and is left alone.
--
-- Snapping a certified zero to exactly 0 is not free, though: it shifts A·x by
-- x_i times that variable's constraint column, and a tiny x_i on a large
-- coefficient can move A·x far more than x_i itself. Two outcomes:
--   * Independent numerical dust (x ~ 1e-10) zeroes out directly -- feasibility
--     stays within tolerance with no further work.
--   * "Structural" dust (e.g. a dead-end recycling recipe parked at ~mu/eps that
--     forms a tiny circulating flow with its surplus_sink partner) is load-
--     bearing at the analytic centre: zeroing it alone breaks A·x = b by orders
--     of magnitude more than tolerance. Those are recovered by re-projecting --
--     a minimum-norm feasibility correction on the remaining FREE variables lets
--     the partners absorb the freed load while the certified zeros stay 0.
-- A feasibility-budgeted greedy snap is the safe fallback when the projection is
-- unusable (singular masked system, or a free variable would go negative). Every
-- path keeps the final relative primal residual at or below the same tolerance
-- the convergence test enforces, so purification never reports a solution dirtier
-- than the solver already promised.
local purify_zeros = true

local M = {}

-- Memoized LDLᵀ (csr_matrix.cholesky_decomposition_memo) for solve_step. P = A·D²·Aᵀ
-- keeps a fixed sparsity across a build's IPM iterations, so the memo caches the
-- fill structure + the multiply-accumulate tape once and replays it branch-free --
-- bit-identical to the fused factorization (verified: headless suite green + a
-- max|Δz|=0 RHS-applied check, so MP lockstep is safe).
--
-- DEFAULT OFF. It is ~2x faster under stock `lua` (tests/research/bench_cholesky),
-- but a controlled in-engine A/B (chain_explorer.profile_ab, same-boot back-to-back
-- to cancel the ~30% cross-boot machine-load noise) measured NO speedup in
-- Factorio's Lua 5.2 fork even with the cache 98% warm: the fused path is the same
-- speed in both VMs, but the tape replay that stock lua runs ~2x faster runs at the
-- fused speed in-engine (the alloc/GC saving stock lua rewards, and the branch
-- removal, are both ~free in Factorio's VM, while the tape's extra indirection
-- offsets them). Kept gated as a verified, reusable factorization -- do not enable
-- without re-measuring with profile_ab in the engine, not stock lua / a micro-bench.
-- A field (not a constant) so probes can flip it for an A/B.
M.cholesky_memo = false

---@param vector CsrMatrix
---@return number
local function vector_sum(vector)
    return vector:fold(0, function(a, b) return a + b end)
end

---@param vector CsrMatrix
---@return number
local function vector_inf_norm(vector)
    return vector:fold(0, function(a, v) return math.max(a, math.abs(v)) end)
end

---Find the largest α ∈ (0, 1] such that variables + α · deltas ≥ 0 componentwise.
---Returns 1 if every component moves away from zero (no boundary contact).
---@param variables CsrMatrix
---@param deltas CsrMatrix
---@return number
local function find_step(variables, deltas)
    local steps = hdiv(variables, -deltas)
    return steps:fold(1, function(a, b)
        return (b <= 0) and a or math.min(a, b)
    end)
end

---Mehrotra's heuristic starting point (Nocedal & Wright 2e, eq. 14.38).
---Seeds (x, y, s) from the minimum-norm solutions of A·x = b and Aᵀ·y ≈ c,
---then shifts both x and s into the strictly-positive orthant with a two-stage
---displacement. Unlike the ‖b‖∞ cold start, x here actually solves A·x = b in
---the least-norm sense, so its magnitude reflects coefficient-driven
---amplification (a tiny input cap fanning out through a small coefficient into
---a large internal throughput) rather than the raw right-hand-side scale.
---Returns nil if the normal-equation factorisation is non-finite (A not full
---row rank), so the caller can fall back to the data-scale cold start.
---@param A CsrMatrix
---@param AT CsrMatrix
---@param b CsrMatrix
---@param c CsrMatrix
---@param p_degree integer
---@param d_degree integer
---@return CsrMatrix? x
---@return CsrMatrix? y
---@return CsrMatrix? s
local function mehrotra_start(A, AT, b, c, p_degree, d_degree)
    -- One symmetric factorisation of A·Aᵀ drives every normal-equation solve
    -- below. This is the same d×d system shape (and sparsity pattern, since SX
    -- is diagonal) as the per-iteration A·D²·Aᵀ Cholesky, so it costs roughly
    -- one extra IPM iteration, paid once at cold start.
    local L, D = csr_matrix.cholesky_decomposition(A * AT)
    local LD = L * D
    local LT = L:T()
    local function solve_normal(rhs)
        return csr_matrix.backward_substitution(LT,
            csr_matrix.forward_substitution(LD, rhs))
    end

    -- x̃ = Aᵀ·(A·Aᵀ)⁻¹·b  (least-norm primal solution to A·x = b)
    -- ỹ = (A·Aᵀ)⁻¹·(A·c), s̃ = c - Aᵀ·ỹ  (least-squares dual)
    local x_tilde = csr_matrix.to_list(AT * solve_normal(b))
    local y = solve_normal(A * c)
    local s_tilde = csr_matrix.to_list(c - AT * y)

    -- First shift: lift each component clear of zero by 1.5× the most negative
    -- entry (implicit sparse zeros count, so the min is ≤ 0 in general).
    local min_x, min_s = math.huge, math.huge
    for i = 1, p_degree do
        if x_tilde[i] < min_x then min_x = x_tilde[i] end
        if s_tilde[i] < min_s then min_s = s_tilde[i] end
    end
    local dx = math.max(-1.5 * min_x, 0)
    local ds = math.max(-1.5 * min_s, 0)

    -- Second shift: centre the point so x̂ᵀ·ŝ is spread evenly, guaranteeing
    -- strict positivity even where the first shift left a component at zero.
    local sum_xs, sum_x, sum_s = 0, 0, 0
    for i = 1, p_degree do
        local xh, sh = x_tilde[i] + dx, s_tilde[i] + ds
        sum_xs = sum_xs + xh * sh
        sum_x = sum_x + xh
        sum_s = sum_s + sh
    end
    local dx_hat = 0.5 * sum_xs / sum_s
    local ds_hat = 0.5 * sum_xs / sum_x

    local x_list, s_list = {}, {}
    for i = 1, p_degree do
        local xv = x_tilde[i] + dx + dx_hat
        local sv = s_tilde[i] + ds + ds_hat
        -- Reject the whole point if the factorisation poisoned any component
        -- (NaN/inf from a near-singular A·Aᵀ). Cheaper than per-step recovery.
        if xv ~= xv or sv ~= sv or xv == math.huge or sv == math.huge
            or xv == -math.huge or sv == -math.huge then
            return nil, nil, nil
        end
        x_list[i] = xv
        s_list[i] = sv
    end

    return csr_matrix.with_vector(x_list, p_degree), y,
        csr_matrix.with_vector(s_list, p_degree)
end

---Scan a vector's underlying `values` array for any IEEE NaN.
---We can't use csr_matrix.fold here: its `initial or 0` clause coerces the
---natural `false` sentinel to 0 (truthy in Lua), so a fold-based predicate
---would always report "NaN seen".
---@param vector CsrMatrix
---@return boolean
local function has_nan(vector)
    local values = vector.values
    for i = 1, #values do
        if values[i] ~= values[i] then return true end
    end
    return false
end

---Per-variable least-norm magnitude estimate: |x̃| where x̃ = Aᵀ(A·Aᵀ)⁻¹b is the
---minimum-norm solution of A·x = b (the same seed mehrotra_start uses). Its
---magnitude reflects coefficient-driven amplification (a small input cap fanning
---through a small coefficient into a large internal throughput) and is
---OBJECTIVE-INDEPENDENT -- it depends only on A and b, not on the cost vector or
---which degenerate vertex the solve lands on -- so it is a deterministic,
---vertex-stable per-column scale. Returns nil if A·Aᵀ is not factorable (A not
---full row rank) or the result is non-finite, so the caller falls back to a flat
---tie-break. Research hook for tie-break magnitude normalization (C-2
---equilibration); NOT on the solve path.
---@param problem Problem
---@return table<string, number>? #key -> |x̃_key|, or nil when unavailable
function M.least_norm_magnitude(problem)
    local A = problem:generate_subject_matrix()
    local AT = A:T()
    local b = problem:generate_limit_vector()
    local ok, L, D = pcall(csr_matrix.cholesky_decomposition, A * AT)
    if not ok or not L or not D then return nil end
    local LD = L * D
    local LT = L:T()
    local z = csr_matrix.backward_substitution(LT, csr_matrix.forward_substitution(LD, b))
    local x_tilde = csr_matrix.to_list(AT * z)
    local map = {}
    for key, p in pairs(problem.primals) do
        local v = x_tilde[p.index] or 0
        if v ~= v or v == math.huge or v == -math.huge then return nil end
        map[key] = v < 0 and -v or v
    end
    return map
end

---Solve linear programming problems.
---Feasibility-budgeted greedy snap: the safe fallback path for certify_zeros.
---Snaps candidate zeros to 0 in ascending feasibility impact (x_i²·‖col_i‖²),
---admitting each only while the running primal residual stays within budget, so
---the result never breaches `tolerance`. The residual is tracked incrementally,
---touching only each snapped column's nonzeros.
---@param x_list number[] Dense primal values (mutated copy is returned).
---@param candidates integer[] Candidate variable indices.
---@param AT CsrMatrix Transposed subject matrix; row i is variable i's column.
---@param res0 number[] Dense pre-snap primal residual A·x - b.
---@param budget_sq number Squared absolute residual budget (tolerance·denom)².
---@param length integer Primal vector length.
---@return number[] out Primal values with the admitted subset zeroed.
---@return integer count Number of variables snapped.
---@return number max_snapped Largest x_i snapped to 0.
---@return number residual_norm Post-snap absolute residual ‖A·x-b‖.
local function budgeted_greedy(x_list, candidates, AT, res0, budget_sq, length)
    local at_values, at_cols, at_ranges = AT.values, AT.column_indexes, AT.row_ranges

    local items = {}
    for _, i in ipairs(candidates) do
        local xi = x_list[i]
        local col_sq = 0
        for t = at_ranges[i], at_ranges[i + 1] - 1 do
            local a = at_values[t]
            col_sq = col_sq + a * a
        end
        items[#items + 1] = { i = i, impact = xi * xi * col_sq }
    end
    -- Break impact ties by index so the admitted set is a total order independent
    -- of table.sort's unstable tie handling -- the purified solution must be
    -- bit-identical across clients (multiplayer lockstep).
    table.sort(items, function(p, q)
        if p.impact ~= q.impact then return p.impact < q.impact end
        return p.i < q.i
    end)

    local out, res = {}, {}
    for i = 1, length do out[i] = x_list[i] end
    for j = 1, #res0 do res[j] = res0[j] end
    local ss = 0
    for j = 1, #res do ss = ss + res[j] * res[j] end

    local count, max_snapped = 0, 0
    for _, it in ipairs(items) do
        local i = it.i
        local xi = out[i]
        local ss_new = ss
        for t = at_ranges[i], at_ranges[i + 1] - 1 do
            local old = res[at_cols[t]]
            local new = old - xi * at_values[t]
            ss_new = ss_new - old * old + new * new
        end
        if ss_new <= budget_sq then
            for t = at_ranges[i], at_ranges[i + 1] - 1 do
                local j = at_cols[t]
                res[j] = res[j] - xi * at_values[t]
            end
            ss = ss_new
            out[i] = 0
            count = count + 1
            if xi > max_snapped then max_snapped = xi end
        end
    end

    return out, count, max_snapped, math.sqrt(ss)
end

---Dual-certified zero purification (see the purify_zeros note above). A primal
---is a *candidate* zero when its reduced cost s_i dominates its value x_i -- the
---nonbasic side of complementary slackness, scale-free (each variable's own x_i
---vs its own s_i, no absolute thresholds). The three feasibility-preserving
---paths -- direct zeroing, re-projection, budgeted greedy fallback -- are
---described in the purify_zeros note above; every one keeps the returned
---solution's relative primal residual at or below `tolerance`.
---@param x CsrMatrix Converged primal variables.
---@param s CsrMatrix Converged slack (reduced cost = c - Aᵀ·y) variables.
---@param A CsrMatrix Subject matrix.
---@param AT CsrMatrix Transposed subject matrix; row i is variable i's constraint column.
---@param b CsrMatrix Limit vector.
---@param primal CsrMatrix Pre-snap primal residual A·x - b.
---@param denom number Relative-residual denominator 1 + ‖b‖.
---@param length integer Primal vector length (problem.primal_length).
---@param tolerance number Relative feasibility bound the result must not exceed.
---@return CsrMatrix #Primal vector with certified zeros snapped to 0.
---@return integer count Number of variables snapped to exactly 0.
---@return number max_snapped Largest x_i snapped to 0.
---@return number residual Post-snap relative primal residual ‖A·x-b‖/denom.
---@return string mode One of "none" | "direct" | "projection" | "greedy".
local function certify_zeros(x, s, A, AT, b, primal, denom, length, tolerance)
    local x_list, s_list = csr_matrix.to_list(x), csr_matrix.to_list(s)

    -- Dual-certified candidates: reduced cost dominates value (nonbasic side).
    local is_candidate, candidates = {}, {}
    local max_snapped = 0
    for i = 1, length do
        local xi, si = x_list[i] or 0, s_list[i] or 0
        if xi > 0 and si > xi then
            is_candidate[i] = true
            candidates[#candidates + 1] = i
            if xi > max_snapped then max_snapped = xi end
        end
    end

    local function rel_residual(xs)
        return (A * csr_matrix.with_vector(xs, length) - b):euclidean_norm() / denom
    end

    if #candidates == 0 then
        return x, 0, 0, primal:euclidean_norm() / denom, "none"
    end

    -- (1) Direct: zero every candidate. For independent numerical dust this is
    -- already feasible within tolerance -- the common case, no factorisation.
    local proj = {}
    for i = 1, length do proj[i] = is_candidate[i] and 0 or x_list[i] end
    local r_direct = rel_residual(proj)
    if r_direct <= tolerance then
        return csr_matrix.with_vector(proj, length), #candidates, max_snapped, r_direct, "direct"
    end

    -- (2) Re-projection: the candidates were load-bearing, so restore feasibility
    -- with the minimum-norm correction on the FREE (non-candidate) variables.
    -- Solve (A·W·Aᵀ)·u = -(A·x_proj - b) and set Δx = W·Aᵀ·u, where W masks out
    -- the candidate columns so they stay exactly 0 while their partners absorb
    -- the freed load. Mirrors the IPM normal-equation solve (LDLᵀ via Cholesky,
    -- with the same ε·I retry on a NaN-poisoned near-singular factorisation).
    local mask = {}
    for i = 1, length do mask[i] = is_candidate[i] and 0 or 1 end
    local W = csr_matrix.with_diagonal(mask, length)
    local r = A * csr_matrix.with_vector(proj, length) - b
    local P_base = A * W * AT
    -- Masking out the candidate columns makes A·W·Aᵀ structurally singular
    -- wherever a constraint row touched only candidates (its row goes empty, and
    -- the unpivoted Cholesky then divides by a zero pivot -- not even a NaN, but a
    -- nil that throws). A tiny Tikhonov ε·I fills those diagonals so the
    -- factorisation is always well-formed; the damping is negligible on the
    -- well-conditioned majority, and on a genuinely unsatisfiable masked row it
    -- inflates the correction, which the residual check below then rejects in
    -- favour of the greedy fallback. pcall guards any residual breakdown.
    local function solve_proj(reg)
        local P = P_base + csr_matrix.with_diagonal(reg, AT.width)
        local L, D = csr_matrix.cholesky_decomposition(P)
        local u = csr_matrix.backward_substitution(L:T(),
            csr_matrix.forward_substitution(L * D, -r))
        return W * (AT * u)
    end
    local function try_solve_proj(reg)
        local ok, dx = pcall(solve_proj, reg)
        if ok and not has_nan(dx) then return dx end
        return nil
    end
    local dx = try_solve_proj(2 ^ -40) or try_solve_proj(2 ^ -12)
    if dx then
        local dx_list = csr_matrix.to_list(dx)
        local final = {}
        for i = 1, length do
            -- Candidates stay 0 (W zeroes their Δx); clamp any round-off-negative
            -- free correction up to 0 -- the residual check below rejects the
            -- whole projection if that clamp (or a materially negative free var)
            -- pushed feasibility back over tolerance.
            local v = proj[i] + (dx_list[i] or 0)
            final[i] = v > 0 and v or 0
        end
        local r_proj = rel_residual(final)
        if r_proj <= tolerance then
            return csr_matrix.with_vector(final, length), #candidates, max_snapped, r_proj, "projection"
        end
    end

    -- (3) Projection unusable (singular masked system, or a free variable would
    -- go materially negative). Fall back to the budgeted greedy snap, which zeroes
    -- only the subset that fits under tolerance -- always safe, never breaches.
    local budget_sq = (tolerance * denom) ^ 2
    local out, count, snapped, rnorm =
        budgeted_greedy(x_list, candidates, AT, csr_matrix.to_list(primal), budget_sq, length)
    return csr_matrix.with_vector(out, length), count, snapped, rnorm / denom, "greedy"
end

---Uses a primal-dual interior point method (long-step path-following). One
---Cholesky factorisation of A·D²·Aᵀ per iteration drives a single Newton step.
---Modified-Cholesky pivot flooring (in csr_matrix) keeps a cancelled pivot from
---dividing to NaN; if the near-singular A·D²·Aᵀ still overflows large L entries
---to inf the solve is retried with a fat ε·I regularisation (see the two-layer
---note at the Newton system below).
---@param problem Problem Problems to solve.
---@param solver_state SolverState
---@param iteration integer? The IPM iteration count carried across calls; meaningful only while solver_state == "calculating".
---@param raw_variables PackedVariables? The value returned by @{Problem:pack_variables}.
---@param tolerance number
---@param iterate_limit integer
---@return SolverState
---@return integer? iteration
---@return PackedVariables? #Packed table of raw solution.
function M.solve(problem, solver_state, iteration, raw_variables, tolerance, iterate_limit)
    if solver_state == "ready" then
        local b = problem:generate_limit_vector()
        local c = problem:generate_cost_vector()

        -- The LP internals are bulky (the subject-matrix dump is one line per
        -- non-zero coefficient on a real factory) and only needed when capturing
        -- a fixture, so they log at trace -- a level below the debug-tier
        -- reproduction input that create_problem emits. Guarded because the
        -- dumps build large strings eagerly: fs_log args are evaluated by the
        -- caller before emit() can filter on the level.
        log.trace("-- ready solve '%s' --", problem.name)
        if fs_log.is_enabled("trace") then
            log.trace("cost <c>:\n%s", problem:dump_primal(c))
            log.trace("limit <b>:\n%s", problem:dump_dual(b))
            log.trace("subject <A>:\n%s", problem:dump_subject_matrix())
        end

        return "calculating", 1, raw_variables
    elseif solver_state ~= "calculating" then
        return solver_state, iteration, raw_variables
    end

    local A = problem:generate_subject_matrix()
    local AT = A:T()
    local b = problem:generate_limit_vector()
    local c = problem:generate_cost_vector()
    local p_degree = problem.primal_length
    local d_degree = problem.dual_length

    local x, y, s
    if raw_variables == nil then
        -- Cold start via Mehrotra's heuristic starting point. It seeds x from
        -- the least-norm solution of A·x = b, so x's magnitude tracks the
        -- problem's true scale -- including coefficient-driven amplification,
        -- where a tiny input cap fans out through a small coefficient into a
        -- large internal throughput. See mehrotra_start.
        --
        -- The fallback below is the older data-scale seed: x ∝ ‖b‖∞, s ∝ ‖c‖∞.
        -- It keeps the first Newton step proportional to the problem scale (a
        -- naive x=100, s=1 stalls find_step to ~1e-10 against BIG-M elastic/
        -- target costs in the 10³–10⁵ range), but assumes x ≈ ‖b‖∞. That
        -- assumption is exactly what breaks on amplifying loops, so it is now
        -- only the rank-deficient fallback when A·Aᵀ cannot be factored.
        x, y, s = mehrotra_start(A, AT, b, c, p_degree, d_degree)
        if x == nil then
            local b_inf_norm = math.max(2 ^ -32, vector_inf_norm(b))
            local c_inf_norm = math.max(2 ^ -32, vector_inf_norm(c))
            x = csr_matrix.with_vector(b_inf_norm, p_degree)
            y = csr_matrix.with_vector(0, d_degree)
            s = csr_matrix.with_vector(c_inf_norm, p_degree)
        end
        ---@cast x CsrMatrix
        ---@cast y CsrMatrix
        ---@cast s CsrMatrix
    else
        x = problem:make_primal_variables(raw_variables)
        y = problem:make_dual_variables(raw_variables)
        s = problem:make_slack_variables(raw_variables)

        -- Warm-start recentering, applied only at the first IPM
        -- iteration after a fresh "ready" handoff (i.e. external
        -- warm-start: constraint edits, line edits, mod reload). The
        -- "ready" -> "calculating" (iteration 1) transition returns the
        -- caller's raw_variables unchanged, so the first solve call to see
        -- real work has iteration == 1 with raw_variables from the *previous*
        -- terminated solve. After a finished solve the complementarity
        -- x_i·s_i = 0 condition pins one side of every active
        -- constraint at the 2⁻⁵² lower clamp. Carrying those boundary
        -- values forward when the next solve scales x or b by 10×
        -- breaks the unpivoted Cholesky: D² = X·S⁻¹ spans ~2¹⁰⁴ orders
        -- of magnitude, round-off cancellation drives a pivot to 0 /
        -- produces NaN, and the LP terminates "singular" already at
        -- the second IPM iteration (observed in-game when the user
        -- toggled an upper-limit constraint between 1/min and 10/min
        -- on a 5-tier quality recycling chain).
        --
        -- Pull every x_i and s_i back into a band scaled to the problem
        -- data, keeping the warm-start *direction* but discarding the
        -- boundary clamps. The 2⁻¹⁰ floor (≈10⁻³ × ‖·‖∞) is narrow
        -- enough that the warm-start hint still saves iterations on
        -- small incremental edits, and wide enough to keep D²'s
        -- dynamic range under ~2²⁰ on the first Newton step.
        --
        -- Subsequent iterations (iteration >= 2) are internal IPM
        -- progression: x and s legitimately approach the boundary as
        -- the iterates close in on the optimum, and clamping would
        -- prevent convergence on LPs whose true optimum has small
        -- variable values.
        if iteration == 1 then
            local b_inf_norm = math.max(2 ^ -32, vector_inf_norm(b))
            local c_inf_norm = math.max(2 ^ -32, vector_inf_norm(c))
            x = x:clamp(b_inf_norm * 2 ^ -10, machine_upper_epsilon)
            s = s:clamp(c_inf_norm * 2 ^ -10, machine_upper_epsilon)
        end
    end

    local primal = A * x - b
    local dual = AT * y + s - c
    local duality_gap = hmul(s, x)

    -- Relative residual norms keep the convergence test independent of the
    -- problem's data scale. BIG-M LPs can have ||c||_∞ in the 10⁴–10⁵ range
    -- (elastic + target cost tiers), so an absolute ||r_d|| ≤ tol test
    -- demands ~9 orders of magnitude of dual residual reduction even when
    -- the relative residual is already at machine precision. The 1+ guard
    -- keeps the test absolute when the right-hand side is zero.
    local p_criteria = primal:euclidean_norm() / (1 + b:euclidean_norm())
    local d_criteria = dual:euclidean_norm() / (1 + c:euclidean_norm())
    -- Guard the empty problem (p_degree == 0, e.g. every line pruned as
    -- inactive): the duality gap sum is 0, so 0/0 = NaN. Lua 5.4's math.max
    -- discards a NaN argument (the test would still pass), but LuaJIT's returns
    -- NaN, so the convergence test never trips and the solve spins to the
    -- iterate limit. An empty LP is trivially optimal, so report mu = 0.
    local mu_criteria = p_degree > 0 and vector_sum(duality_gap) / p_degree or 0

    -- log.trace("i = %i, p_rel = %g, d_rel = %g, mu = %g",
    --     iteration, p_criteria, d_criteria, mu_criteria)

    if math.max(p_criteria, d_criteria, mu_criteria) <= tolerance then
        if purify_zeros and p_degree > 0 then
            local denom = 1 + b:euclidean_norm()
            local count, max_snapped, residual, mode
            x, count, max_snapped, residual, mode =
                certify_zeros(x, s, A, AT, b, primal, denom, p_degree, tolerance)
            log.trace("  purify_zeros[%s]: snapped %i var(s), max |x| = %g, "
                .. "relative ||A·x-b|| %g -> %g (tol %g)",
                mode, count, max_snapped, p_criteria, residual, tolerance)
        end

        if fs_log.is_enabled("trace") then log.trace("primal <x>:\n%s", problem:dump_primal(x)) end
        log.trace("-- finished solve '%s' --", problem.name)
        log.trace("  iterate = %i, width = %i, height = %i", iteration, p_degree, d_degree)

        return "finished", iteration, problem:pack_variables(x, y, s)
    end

    if iterate_limit <= iteration then
        if fs_log.is_enabled("trace") then log.trace("primal <x>:\n%s", problem:dump_primal(x)) end
        log.trace("-- unfinished solve '%s' --", problem.name)
        log.trace("  iterate = %i, width = %i, height = %i", iteration, p_degree, d_degree)

        -- Drop the partial primal so the next re-prepare warm-starts from the
        -- default (make_primal_variables fallback) rather than from a stuck-
        -- at-clamp x that would just reproduce the same non-convergence.
        return "unfinished", iteration, nil
    end

    -- Build the Newton system. The long-step path-following step targets
    --   S·Δx + X·Δs = -XSe + σμ·e
    -- with σ = centering_sigma. Block-eliminating Δx and Δs gives the
    -- reduced normal-equation form
    --   A·D²·Aᵀ · Δy = aug
    -- (with D² = X·S⁻¹). sic = (XSe - σμe)/s packages the complementarity
    -- RHS so the existing aug = A·(SX·-r_d + sic) - r_p shape applies.
    local SX = hpow(hmul(hpow(s, -0.5), hpow(x, 0.5)), 2):diag()
    local mu = vector_sum(duality_gap) / p_degree
    local barrier = csr_matrix.with_vector(centering_sigma * mu, p_degree)
    local sic = hmul(hpow(s, -1), duality_gap - barrier)
    local aug = A * (SX * -dual + sic) - primal

    -- Cholesky stability is handled in two COMPLEMENTARY layers, because the
    -- near-singular A·D²·Aᵀ has two distinct round-off failure modes (as the IPM
    -- nears the optimum, active constraints pin one of x_i / s_i at the 2⁻⁵²
    -- clamp while the partner stays moderate, so D²_ii spans ~2¹⁰⁴ orders of
    -- magnitude):
    --   * Zero / negative pivots from cancellation -- handled inside
    --     csr_matrix.cholesky_decomposition by the modified-Cholesky pivot floor,
    --     so a cancelled pivot can no longer divide to inf/NaN, independent of
    --     the column order the pivots are visited in.
    --   * Pivots floored small but carrying a large numerator still yield large L
    --     entries whose Schur sums can OVERFLOW to ±inf -- which the pivot floor
    --     cannot prevent. This is caught here by retrying with a fat ε·I, whose
    --     larger diagonal shrinks the L entries back below the overflow threshold.
    -- So the retry is NOT made redundant by the pivot floor: on the pyanodon
    -- random-chain corpus it still fires and rescues tens of iterations even at
    -- the 1e-7 default tolerance (the overflow mode the floor does not address),
    -- with zero residual failures below 1e-10. The two-tier shape keeps the
    -- well-conditioned majority bias-free: try unregularised first, fall back to
    -- the fat ε·I only on detected NaN.
    local cholesky = M.cholesky_memo and csr_matrix.cholesky_decomposition_memo
        or csr_matrix.cholesky_decomposition
    local function solve_step(reg_epsilon)
        local P = A * SX * AT
        if reg_epsilon > 0 then
            P = P + csr_matrix.with_diagonal(reg_epsilon, d_degree)
        end
        local L, D = cholesky(P)
        local y_step_ = csr_matrix.backward_substitution(L:T(),
            csr_matrix.forward_substitution(L * D, aug))
        local s_step_ = AT * -y_step_ - dual
        local x_step_ = SX * -s_step_ - sic
        return y_step_, s_step_, x_step_
    end

    local y_step, s_step, x_step = solve_step(0)
    if has_nan(y_step) or has_nan(s_step) or has_nan(x_step) then
        y_step, s_step, x_step = solve_step(2 ^ -12)
    end
    if has_nan(y_step) or has_nan(s_step) or has_nan(x_step) then
        log.trace("-- singular solve '%s' (Cholesky lost precision) --",
            problem.name)
        log.trace("  iterate = %i, width = %i, height = %i",
            iteration, p_degree, d_degree)
        -- "singular", not "unfinished": the iterate budget is NOT exhausted -- the
        -- reduced normal equations A·D²·Aᵀ went singular under round-off and the
        -- unpivoted Cholesky produced NaN even after the regularised retry. This
        -- terminal state is reachable at any iteration (as early as the second),
        -- so it is a distinct numerical-breakdown signal from the iterate-limit
        -- "unfinished" above; callers that only branch on "finished" treat both
        -- the same, but the split lets diagnosis tell convergence-budget failures
        -- apart from conditioning failures.
        return "singular", iteration, nil
    end

    local p_step = math.min(1, step_fraction * find_step(x, x_step))
    local d_step = math.min(1, step_fraction * find_step(s, s_step))

    -- log.trace("  sigma = %g, mu = %g, p_step = %g, d_step = %g",
    --     centering_sigma, mu, p_step, d_step)

    x = x + p_step * x_step
    y = y + d_step * y_step
    s = s + d_step * s_step

    x = x:clamp(machine_lower_epsilon, machine_upper_epsilon)
    s = s:clamp(machine_lower_epsilon, machine_upper_epsilon)

    return "calculating", iteration + 1, problem:pack_variables(x, y, s)
end

return M
