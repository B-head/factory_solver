local csr_matrix = require("solver/csr_matrix")

local debug_print = print
local hmul, hdiv, hpow = csr_matrix.hadamard_product, csr_matrix.hadamard_division, csr_matrix.hadamard_power

local machine_upper_epsilon = (2 ^ 52) -- (2 ^ 511)
local machine_lower_epsilon = (2 ^ -52) -- (2 ^ -511)

local M = {}

---@param variables CsrMatrix
---@param laplacians CsrMatrix
---@return number
local function find_step(variables, laplacians)
    local steps = hdiv(variables, -laplacians)
    return steps:fold(1, function(a, b)
        return (b <= 0) and a or math.min(a, b)
    end)
end

---Solve linear programming problems.
---Use primal dual interior point methods.
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

        debug_print(string.format("-- ready solve '%s' --", problem.name))
        debug_print("cost <c>:\n" .. problem:dump_primal(c))
        debug_print("limit <b>:\n" .. problem:dump_dual(b))

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
    local x = problem:make_primal_variables(raw_variables)
    local y = problem:make_dual_variables(raw_variables)
    local s = problem:make_slack_variables(raw_variables)

    local primal = A * x - b
    local dual = AT * y + s - c
    local duality_gap = hmul(s, x)

    local p_criteria = primal:euclidean_norm()
    local d_criteria = dual:euclidean_norm()
    local dg_criteria = duality_gap:euclidean_norm()

    -- debug_print(string.format(
    --     "i = %i, primal = %f, dual = %f, duality_gap = %f",
    --     solver_state, p_criteria, d_criteria, dg_criteria
    -- ))

    if math.max(p_criteria, d_criteria, dg_criteria) <= tolerance then
        debug_print("primal <x>:\n" .. problem:dump_primal(x))
        debug_print(string.format("-- finished solve '%s' --", problem.name))
        debug_print(string.format("  iterate = %i, width = %i, height = %i", solver_state, p_degree, d_degree))

        return "finished", problem:pack_variables(x, y, s)
    end

    if iterate_limit <= solver_state then
        debug_print("primal <x>:\n" .. problem:dump_primal(x))
        debug_print(string.format("-- unfinished solve '%s' --", problem.name))
        debug_print(string.format("  iterate = %i, width = %i, height = %i", solver_state, p_degree, d_degree))

        return "unfinished", problem:pack_variables(x, y, s)
    end

    local SX = hpow(hmul(hpow(s, -0.5), hpow(x, 0.5)), 2):diag()
    local P = A * SX * AT

    local L, D = csr_matrix.cholesky_decomposition(P)

    local sic = hmul(hpow(s, -1), duality_gap)
    local aug_affine = A * (SX * -dual + sic) - primal
    local temp_affine = csr_matrix.forward_substitution(L * D, aug_affine)
    local y_affine = csr_matrix.backward_substitution(L:T(), temp_affine)
    local s_affine = AT * -y_affine - dual
    local x_affine = SX * -s_affine - sic

    local step_scale = 1 - tolerance
    local p_step = find_step(x, x_affine) * step_scale
    local d_step = find_step(s, s_affine) * step_scale

    -- debug_print(string.format(
    --     "  p_step = %f, d_step = %f, step_scale = %f",
    --     p_step, d_step, step_scale
    -- ))

    x = x + p_step * x_affine
    y = y + d_step * y_affine
    s = s + d_step * s_affine

    x = x:clamp(machine_lower_epsilon, machine_upper_epsilon)
    s = s:clamp(machine_lower_epsilon, machine_upper_epsilon)

    return solver_state + 1, problem:pack_variables(x, y, s)
end

return M
