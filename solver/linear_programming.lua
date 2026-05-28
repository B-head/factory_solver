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

local M = {}

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

---Solve linear programming problems.
---Uses a primal-dual interior point method (long-step path-following). One
---Cholesky factorisation of A·D²·Aᵀ per iteration drives a single Newton
---step; if it produces NaN (the unpivoted decomposition cannot recover from
---a zero pivot when active inequality constraints make A·D²·Aᵀ near-
---singular) the solve is retried with a fat ε·I regularisation.
---@param problem Problem Problems to solve.
---@param solver_state SolverState
---@param raw_variables PackedVariables? The value returned by @{Problem:pack_variables}.
---@param tolerance number
---@param iterate_limit integer
---@return SolverState
---@return PackedVariables? #Packed table of raw solution.
function M.solve(problem, solver_state, raw_variables, tolerance, iterate_limit)
    if solver_state == "ready" then
        local b = problem:generate_limit_vector()
        local c = problem:generate_cost_vector()

        log.debug("-- ready solve '%s' --", problem.name)
        log.debug("cost <c>:\n%s", problem:dump_primal(c))
        log.debug("limit <b>:\n%s", problem:dump_dual(b))
        -- Subject matrix only at trace -- on real factories the dump is large
        -- (one line per non-zero coefficient) and only needed when capturing
        -- a fixture for the headless test suite. Stays off under both the
        -- default info and the __DebugAdapter debug threshold.
        log.trace("subject <A>:\n%s", problem:dump_subject_matrix())

        return 1, raw_variables
    elseif type(solver_state) ~= "number" then
        return solver_state, raw_variables
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
        -- "ready" -> 1 transition returns the caller's raw_variables
        -- unchanged, so the first solve call to see real work has
        -- solver_state == 1 with raw_variables from the *previous*
        -- terminated solve. After a finished solve the complementarity
        -- x_i·s_i = 0 condition pins one side of every active
        -- constraint at the 2⁻⁵² lower clamp. Carrying those boundary
        -- values forward when the next solve scales x or b by 10×
        -- breaks the unpivoted Cholesky: D² = X·S⁻¹ spans ~2¹⁰⁴ orders
        -- of magnitude, round-off cancellation drives a pivot to 0 /
        -- produces NaN, and the LP terminates "unfinished" already at
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
        -- Subsequent iterations (solver_state >= 2) are internal IPM
        -- progression: x and s legitimately approach the boundary as
        -- the iterates close in on the optimum, and clamping would
        -- prevent convergence on LPs whose true optimum has small
        -- variable values.
        if solver_state == 1 then
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
    local mu_criteria = vector_sum(duality_gap) / p_degree

    -- log.debug("i = %i, p_rel = %g, d_rel = %g, mu = %g",
    --     solver_state, p_criteria, d_criteria, mu_criteria)

    if math.max(p_criteria, d_criteria, mu_criteria) <= tolerance then
        log.debug("primal <x>:\n%s", problem:dump_primal(x))
        log.debug("-- finished solve '%s' --", problem.name)
        log.debug("  iterate = %i, width = %i, height = %i", solver_state, p_degree, d_degree)

        return "finished", problem:pack_variables(x, y, s)
    end

    if iterate_limit <= solver_state then
        log.debug("primal <x>:\n%s", problem:dump_primal(x))
        log.debug("-- unfinished solve '%s' --", problem.name)
        log.debug("  iterate = %i, width = %i, height = %i", solver_state, p_degree, d_degree)

        -- Drop the partial primal so the next re-prepare warm-starts from the
        -- default (make_primal_variables fallback) rather than from a stuck-
        -- at-clamp x that would just reproduce the same non-convergence.
        return "unfinished", nil
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

    -- Cholesky stability: the unpivoted decomposition in
    -- csr_matrix.cholesky_decomposition cannot recover from a zero pivot. As
    -- the IPM approaches the optimum, active constraints pin one of x_i or
    -- s_i at the boundary clamp 2⁻⁵² while the partner stays moderate, so
    -- D²_ii spans ~2¹⁰⁴ orders of magnitude. Round-off cancellation in the
    -- resulting near-singular A·D²·Aᵀ can drive a pivot to 0; that pivot
    -- propagates inf/NaN through the substitution back-end (clamp does not
    -- catch NaN). The two-tier strategy keeps the well-conditioned majority
    -- bias-free: first try with no regularisation, and only fall back to a
    -- fat ε·I on detected NaN. The fat ε is intentionally large -- the
    -- retry path only fires after the bias-free solve already failed, so
    -- trading some precision for a non-poisoned iteration is the right side
    -- of the trade.
    local function solve_step(reg_epsilon)
        local P = A * SX * AT
        if reg_epsilon > 0 then
            P = P + csr_matrix.with_diagonal(reg_epsilon, d_degree)
        end
        local L, D = csr_matrix.cholesky_decomposition(P)
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
        log.debug("-- unfinished solve '%s' (Cholesky lost precision) --",
            problem.name)
        log.debug("  iterate = %i, width = %i, height = %i",
            solver_state, p_degree, d_degree)
        return "unfinished", nil
    end

    local p_step = math.min(1, step_fraction * find_step(x, x_step))
    local d_step = math.min(1, step_fraction * find_step(s, s_step))

    -- log.debug("  sigma = %g, mu = %g, p_step = %g, d_step = %g",
    --     centering_sigma, mu, p_step, d_step)

    x = x + p_step * x_step
    y = y + d_step * y_step
    s = s + d_step * s_step

    x = x:clamp(machine_lower_epsilon, machine_upper_epsilon)
    s = s:clamp(machine_lower_epsilon, machine_upper_epsilon)

    return solver_state + 1, problem:pack_variables(x, y, s)
end

return M
