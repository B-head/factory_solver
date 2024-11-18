--- Create and solve linear programming problems (a.k.a linear optimization).
---@license MIT
---@author B_head

local Matrix = require("solver/Matrix")
local SparseMatrix = require("solver/SparseMatrix")

local debug_print = print
local hmul, hpow, diag = Matrix.hadamard_product, Matrix.hadamard_power, SparseMatrix.diag

local iterate_limit = 600
local machine_upper_epsilon = (2 ^ 52)
local machine_lower_epsilon = (2 ^ -52)
local tolerance = (10 ^ -6) / 2

local M = {}

local function enforce_epsilon_limit(variables)
    local height = variables.height
    for y = 1, height do
        variables[y][1] = math.max(machine_lower_epsilon, math.min(machine_upper_epsilon, variables[y][1]))
    end
end

local function sigmoid(value, min, max)
    min = min or 0
    max = max or 1
    return (max - min) / (1 + math.exp(-value)) + min
end

---comment
---@param variables Matrix
---@param laplacians Matrix
---@return number
local function find_step(variables, laplacians)
    local height = variables.height
    local ret = 1

    for y = 1, height do
        local a, b = variables[y][1], laplacians[y][1]
        if b < 0 then
            ret = math.min(ret, a / -b)
        end
    end

    return ret
end

---Solve linear programming problems.
---Use primal dual interior point methods.
---@param problem Problem Problems to solve.
---@param solver_state SolverState
---@param raw_variables PackedVariables? The value returned by @{Problem:pack_pdip_variables}.
---@return SolverState
---@return PackedVariables? #Packed table of raw solution.
function M.solve(problem, solver_state, raw_variables)
    if solver_state == "ready" then
        debug_print(string.format("-- ready solve '%s' --", problem.name))
        return 1, raw_variables
    elseif type(solver_state) ~= "number" then
        return solver_state, raw_variables
    end

    local A = problem:generate_subject_sparse_matrix()
    local AT = A:T()
    local b = problem:generate_limit_vector()
    local c = problem:generate_cost_vector()
    local p_degree = problem.primal_length
    local d_degree = problem.dual_length
    local x = problem:make_primal_variables(raw_variables)
    local y = problem:make_dual_variables(raw_variables)
    local s = problem:make_slack_variables(raw_variables)

    enforce_epsilon_limit(x)
    enforce_epsilon_limit(s)

    local primal = A * x - b
    local dual = AT * y + s - c
    local duality_gap = hmul(s, x)

    local p_criteria = primal:euclidean_norm()
    local d_criteria = dual:euclidean_norm()
    local dg_criteria = duality_gap:euclidean_norm()

    debug_print(string.format(
        "i = %i, primal = %f, dual = %f, duality_gap = %f",
        solver_state, p_criteria, d_criteria, dg_criteria
    ))

    if math.max(p_criteria, d_criteria, dg_criteria) <= tolerance then
        debug_print("primal <x>:\n" .. problem:dump_primal(x))
        debug_print("cost <c>:\n" .. problem:dump_primal(c))
        debug_print("limit <b>:\n" .. problem:dump_dual(b))
        debug_print(string.format("-- finished solve '%s' --", problem.name))
        debug_print(string.format("  iterate = %i, width = %i, height = %i", solver_state, p_degree, d_degree))

        return "finished", problem:pack_variables(x, y, s)
    end

    if iterate_limit <= solver_state then
        debug_print("primal <x>:\n" .. problem:dump_primal(x))
        debug_print("cost <c>:\n" .. problem:dump_primal(c))
        debug_print("limit <b>:\n" .. problem:dump_dual(b))
        debug_print(string.format("-- unfinished solve '%s' --", problem.name))
        debug_print(string.format("  iterate = %i, width = %i, height = %i", solver_state, p_degree, d_degree))

        return "unfinished", problem:pack_variables(x, y, s)
    end

    local SX = diag(hpow(hmul(hpow(s, -0.5), hpow(x, 0.5)), 2))
    local P = A * SX * AT

    local L, FD, U = M.cholesky_factorization(P)
    L = L * FD

    local fvg = M.create_flee_value_generator(y)

    local sic = hmul(hpow(s, -1), duality_gap)
    local aug_affine = A * (SX * -dual + sic) - primal
    local y_affine = M.lu_solve_linear_equation(L, U, aug_affine, fvg)
    local s_affine = AT * -y_affine - dual
    local x_affine = SX * -s_affine - sic

    local p_step = find_step(x, x_affine)
    local d_step = find_step(s, s_affine)
    local step_scale = sigmoid(dg_criteria, 1 / 3)

    debug_print(string.format(
        "  p_step = %f, d_step = %f, step_scale = %f",
        p_step, d_step, step_scale
    ))

    x = x + step_scale * p_step * x_affine
    y = y + step_scale * d_step * y_affine
    s = s + step_scale * d_step * s_affine

    return solver_state + 1, problem:pack_variables(x, y, s)
end

---Reduce an augmented matrix into row echelon form.
---@todo Refactoring for use in matrix solvers.
---@param A Matrix Matrix equation.
---@param b Matrix Column vector.
---@return Matrix #Matrix of row echelon form.
---@return Matrix
function M.gaussian_elimination(A, b)
    local height, width = A.height, A.width
    local ret_A = A:clone():insert_column(b)

    local function select_pivot(s, x)
        local max_value, max_index, raw_max_value = 0, nil, nil
        for y = s, height do
            local r = ret_A:get(y, x)
            local a = math.abs(r)
            if max_value < a then
                max_value = a
                max_index = y
                raw_max_value = r
            end
        end
        return max_index, raw_max_value
    end

    local i = 1
    for x = 1, width + 1 do
        local pi, pv = select_pivot(i, x)
        if pi then
            ret_A:row_swap(i, pi)
            for k = i + 1, height do
                local f = -ret_A:get(k, x) / pv
                ret_A:row_trans(k, i, f)
                ret_A:set(k, x, 0)
            end
            i = i + 1
        end
    end

    local ret_b = ret_A:remove_column()
    return ret_A, ret_b
end

---LU decomposition of the symmetric matrix.
---@param A Matrix Symmetric matrix.
---@return Matrix #Lower triangular matrix.
---@return Matrix #Diagonal matrix.
---@return Matrix #Upper triangular matrix.
function M.cholesky_factorization(A)
    assert(A.height == A.width)
    local size = A.height
    local L, D = SparseMatrix(size, size), SparseMatrix(size, size)
    for i = 1, size do
        local a_values = {}
        for x, v in A:iterate_row(i) do
            a_values[x] = v
        end

        for k = 1, i do
            local i_it, k_it = L:iterate_row(i), L:iterate_row(k)
            local i_r, i_v = i_it()
            local k_r, k_v = k_it()

            local sum = 0
            while i_r and k_r do
                if i_r < k_r then
                    i_r, i_v = i_it()
                elseif i_r > k_r then
                    k_r, k_v = k_it()
                else -- i_r == k_r
                    local d = D:get(i_r, k_r)
                    sum = sum + i_v * k_v * d
                    i_r, i_v = i_it()
                    k_r, k_v = k_it()
                end
            end

            local a = a_values[k] or 0
            local b = a - sum
            if i == k then
                D:set(k, k, math.max(b, a * machine_lower_epsilon))
                L:set(i, k, 1)
            else
                local c = D:get(k, k)
                local v = b / c
                L:set(i, k, v)
            end
        end
    end
    return L, D, L:T()
end

local function substitution(s, e, m, A, b, flee_value_generator)
    local sol = {}
    for y = s, e, m do
        local total, factors, indexes = b:get(y, 1), {}, {}
        for x, v in A:iterate_row(y) do
            if sol[x] then
                total = total - sol[x] * v
            else
                table.insert(factors, v)
                table.insert(indexes, x)
            end
        end

        local l = #indexes
        if l == 1 then
            sol[indexes[1]] = total / factors[1]
        elseif l >= 2 then
            local res = flee_value_generator(total, factors, indexes)
            for k, x in ipairs(indexes) do
                sol[x] = res[k]
            end
        end
    end
    return Matrix.list_to_vector(sol, A.width)
end

---Use LU-decomposed matrices to solve linear equations.
---@param L Matrix Lower triangular matrix.
---@param U Matrix Upper triangular matrix.
---@param b Matrix Column vector.
---@param flee_value_generator function Callback function that generates the value of free variable.
---@return Matrix #Solution of linear equations.
function M.lu_solve_linear_equation(L, U, b, flee_value_generator)
    local t = M.forward_substitution(L, b, flee_value_generator)
    return M.backward_substitution(U, t, flee_value_generator)
end

---Use lower triangular matrix to solve linear equations.
---@param L Matrix Lower triangular matrix.
---@param b Matrix Column vector.
---@param flee_value_generator function Callback function that generates the value of free variable.
---@return Matrix #Solution of linear equations.
function M.forward_substitution(L, b, flee_value_generator)
    return substitution(1, L.height, 1, L, b, flee_value_generator)
end

---Use upper triangular matrix to solve linear equations.
---@param U Matrix Upper triangular matrix.
---@param b Matrix Column vector.
---@param flee_value_generator function Callback function that generates the value of free variable.
---@return Matrix #Solution of linear equations.
function M.backward_substitution(U, b, flee_value_generator)
    return substitution(U.height, 1, -1, U, b, flee_value_generator)
end

---Create to callback function that generates the value of free variable.
---@param ... Matrix Vector to be referenced in debug output.
---@return function #Callback function.
function M.create_flee_value_generator(...)
    local currents = Matrix.join_vector { ... }
    return function(target, factors, indexes)
        debug_print(string.format("generate flee values: target = %f", target))
        local tf = 0
        for _, v in ipairs(factors) do
            tf = tf + math.abs(v)
        end
        local ret = {}
        local sol = target / tf
        for i, k in ipairs(indexes) do
            ret[i] = sol * factors[i] / math.abs(factors[i])
            debug_print(string.format(
                "index = %i, factor = %f, current = %f, solution = %f",
                k, factors[i], currents[k][1], sol
            ))
        end
        return ret
    end
end

return M
