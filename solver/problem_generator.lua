local csr_matrix = require "solver/csr_matrix"

---@class Problem
---@field name string
---@field primals Primal[]
---@field primal_length integer
---@field duals Dual
---@field dual_length integer
---@field subject_terms number[][]
local M = {}

---@class Primal
---@field key string
---@field index integer
---@field cost number
---@field is_result boolean
local Primal = {}

---@class Dual
---@field key string
---@field index integer
---@field limit number
local Dual = {}

local metatable = { __index = M }

---Setup metatable.
---@param self Problem
---@return Problem
function M.setup_metatable(self)
    return setmetatable(self, metatable)
end

---Helper for generating linear programming problems.
---@param name string Name of the problem.
---@return Problem
function M.new(name)
    local self = {
        name = name,
        primals = {},
        primal_length = 0,
        duals = {},
        dual_length = 0,
        subject_terms = {},
    }
    return M.setup_metatable(self)
end

---Add the variables to optimize and a term for the objective function.
---@param primal_variable string
---@param cost number
---@param is_result boolean? If ture, variables are included in the output of the solution.
function M:add_objective(primal_variable, cost, is_result)
    assert(
        not self.primals[primal_variable],
        "Already added a primal variable with the same name."
    )
    self.primal_length = self.primal_length + 1
    self.primals[primal_variable] = {
        key = primal_variable,
        index = self.primal_length,
        cost = cost,
        is_result = is_result or false,
    }
end

---comment
---@param primal_variable string
---@param cost number
function M:update_objective_cost(primal_variable, cost)
    local t = self.primals[primal_variable].cost
    self.primals[primal_variable].cost = t + cost
end

---Is there an objective term that corresponds to the key?
---@param primal_variable string
---@return boolean
function M:is_exist_objective(primal_variable)
    return self.primals[primal_variable] ~= nil
end

---Add equivalence the constraint.
---@param dual_variable string
---@param limit number
function M:add_equivalence_constraint(dual_variable, limit)
    assert(
        not self.duals[dual_variable],
        "Already added a dual variable with the same name."
    )
    assert(
        0 <= limit,
        "The limit must be a positive value."
    )
    self.dual_length = self.dual_length + 1
    self.duals[dual_variable] = {
        key = dual_variable,
        index = self.dual_length,
        limit = limit,
    }
end

---Add inequality the constraint of equal or less.
---@param dual_variable string
---@param limit number
function M:add_upper_limit_constraint(dual_variable, limit)
    local slack_key = "%slack%" .. dual_variable
    M.add_equivalence_constraint(self, dual_variable, limit)
    M.add_objective(self, slack_key, 0, false)
    M.add_subject_term(self, slack_key, dual_variable, 1)
end

---Add inequality the constraint of equal or greater.
---@param dual_variable string
---@param limit number
function M:add_lower_limit_constraint(dual_variable, limit)
    local slack_key = "%slack%" .. dual_variable
    M.add_equivalence_constraint(self, dual_variable, limit)
    M.add_objective(self, slack_key, 0, false)
    M.add_subject_term(self, slack_key, dual_variable, -1)
end

---Is there an constraint that corresponds to the key?
---@param dual_variable string
function M:is_exist_constraint(dual_variable)
    return self.duals[dual_variable] ~= nil
end

---Add the term for the constraint equation.
---A term with no related variables is removed when generating matrix.
---@param primal_variable string
---@param dual_variable string
---@param coefficient number
function M:add_subject_term(primal_variable, dual_variable, coefficient)
    if not self.subject_terms[primal_variable] then
        self.subject_terms[primal_variable] = {}
    end

    local t = self.subject_terms[primal_variable][dual_variable] or 0
    self.subject_terms[primal_variable][dual_variable] = t + coefficient
end

---Make a vector of the coefficient of the primal problem.
---@return CsrMatrix
function M:generate_cost_vector()
    local ret = {}
    for _, v in pairs(self.primals) do
        ret[v.index] = v.cost
    end
    return csr_matrix.with_vector(ret, self.primal_length)
end

---Make a vector of the coefficient of the dual problem.
---@return CsrMatrix
function M:generate_limit_vector()
    local ret = {}
    for _, v in pairs(self.duals) do
        ret[v.index] = v.limit
    end
    return csr_matrix.with_vector(ret, self.dual_length)
end

---Make a sparse matrix of constraint equations.
---@return CsrMatrix
function M:generate_subject_matrix()
    local ret = {}
    for p, t in pairs(self.subject_terms) do
        if self.primals[p] then
            local x = self.primals[p].index
            for d, v in pairs(t) do
                if self.duals[d] then
                    local y = self.duals[d].index
                    table.insert(ret, { y = y, x = x, value = v })
                end
            end
        end
    end
    return csr_matrix.from_coordinate_list(self.primal_length, ret)
end

---Make primal variables.
---@param raw_variables PackedVariables? The value returned by @{pack_variables}.
---@return CsrMatrix #Variables in vector form.
function M:make_primal_variables(raw_variables)
    local prev_x = raw_variables and raw_variables.x or {}
    local ret = {}
    for k, v in pairs(self.primals) do
        ret[v.index] = prev_x[k] or 1
    end
    return csr_matrix.with_vector(ret, self.primal_length)
end

---Make dual variables.
---@param raw_variables PackedVariables? The value returned by @{pack_variables}.
---@return CsrMatrix #Variables in vector form.
function M:make_dual_variables(raw_variables)
    local prev_y = raw_variables and raw_variables.y or {}
    local ret = {}
    for k, v in pairs(self.duals) do
        ret[v.index] = prev_y[k] or 0
    end
    return csr_matrix.with_vector(ret, self.dual_length)
end

---Make slack variables.
---@param raw_variables PackedVariables? The value returned by @{pack_variables}.
---@return CsrMatrix #Variables in vector form.
function M:make_slack_variables(raw_variables)
    local prev_s = raw_variables and raw_variables.s or {}
    local ret = {}
    for k, v in pairs(self.primals) do
        ret[v.index] = prev_s[k] or math.max(1, v.cost)
    end
    return csr_matrix.with_vector(ret, self.primal_length)
end

---Store the value of variables in a plain table.
---@param x CsrMatrix Primal variables.
---@param y CsrMatrix Dual variables.
---@param s CsrMatrix Slack variables.
---@return PackedVariables #Packed table.
function M:pack_variables(x, y, s)
    local list_x, list_s = x:to_list(), s:to_list()
    local ret_x, ret_s = {}, {}
    for k, v in pairs(self.primals) do
        ret_x[k] = list_x[v.index]
        ret_s[k] = list_s[v.index]
    end

    local list_y = y:to_list()
    local ret_y = {}
    for k, v in pairs(self.duals) do
        ret_y[k] = list_y[v.index]
    end

    return {
        x = ret_x,
        y = ret_y,
        s = ret_s,
    }
end

---Remove unnecessary variables from the solution of the problem.
---@param raw_variables PackedVariables?
---@return table<string, number>
function M:filter_result(raw_variables)
    local ret = {}
    for k, v in pairs(self.primals) do
        if v.is_result then
            if raw_variables then
                ret[k] = raw_variables.x[k] or 1
            else
                ret[k] = 1
            end
        end
    end
    return ret
end

---Put primal variables in readable format.
---@param vector CsrMatrix
---@return string
function M:dump_primal(vector)
    local list = vector:to_list()
    local ret = {}
    for k, v in pairs(self.primals) do
        table.insert(ret, string.format("  %q = %f\n", k, list[v.index]))
    end
    return table.concat(ret)
end

---Put dual variables in readable format.
---@param vector CsrMatrix
---@return string
function M:dump_dual(vector)
    local list = vector:to_list()
    local ret = {}
    for k, v in pairs(self.duals) do
        table.insert(ret, string.format("  %q = %f\n", k, list[v.index]))
    end
    return table.concat(ret)
end

return M
