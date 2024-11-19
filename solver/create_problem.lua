local problem_generator = require "solver/problem_generator"

local final_product_cost = 0
local basic_ingredient_cost = 0
local surplus_product_cost = 0
local shortage_ingredient_cost = 0

local M = {}

---comment
---@param typed_name TypedName
---@return string
function M.make_variable_name(typed_name)
    return string.format("%s/%s/%s", typed_name.type, typed_name.name, typed_name.quality)
end

---comment
---@param production_lines NormalizedProductionLine[]
---@return table<string, { included_product: boolean, included_ingredient: boolean }>
function M.get_included_crafts(production_lines)
    ---@type table<string, { included_product: boolean, included_ingredient: boolean }>
    local set = {}
    local function add_set(key)
        if not set[key] then
            set[key] = {
                included_product = false,
                included_ingredient = false,
            }
        end
    end

    for _, line in pairs(production_lines) do
        for _, value in pairs(line.products) do
            local variable_name = M.make_variable_name(value)
            add_set(variable_name)
            set[variable_name].included_product = true
        end
        for _, value in pairs(line.ingredients) do
            local variable_name = M.make_variable_name(value)
            add_set(variable_name)
            set[variable_name].included_ingredient = true
        end
    end

    return set
end

---comment
---@param product_count number
---@param ingredient_count number
---@return number
function M.make_recipe_cost(product_count, ingredient_count)
    local value = ingredient_count - product_count
    return 1 / (1 + math.exp(-value)) - 1
end

---Create linear programming problems.
---@param solution_name string
---@param constraints Constraint[]
---@param production_lines NormalizedProductionLine[]
---@return Problem
function M.create_problem(solution_name, constraints, production_lines)
    local problem = problem_generator.new(solution_name)
    local included_items = M.get_included_crafts(production_lines)

    for variable_name, value in pairs(included_items) do
        problem:add_equivalence_constraint(variable_name, 0)

        if value.included_product and value.included_ingredient then
            --TODO Detection of linear dependencies.
            do
                local primal_variable = "|surplus_product|" .. variable_name
                problem:add_objective(primal_variable, surplus_product_cost)
                problem:add_subject_term(primal_variable, variable_name, -1)
            end
            do
                local primal_variable = "|shortage_ingredient|" .. variable_name
                problem:add_objective(primal_variable, shortage_ingredient_cost)
                problem:add_subject_term(primal_variable, variable_name, 1)
                problem:add_subject_term(primal_variable, "|limit|" .. variable_name, 1)
            end
        elseif value.included_product then
            local primal_variable = "|final_product|" .. variable_name
            problem:add_objective(primal_variable, final_product_cost)
            problem:add_subject_term(primal_variable, variable_name, -1)
        elseif value.included_ingredient then
            local primal_variable = "|basic_ingredient|" .. variable_name
            problem:add_objective(primal_variable, basic_ingredient_cost)
            problem:add_subject_term(primal_variable, variable_name, 1)
            problem:add_subject_term(primal_variable, "|limit|" .. variable_name, 1)
        else
            assert()
        end
    end

    for _, line in ipairs(production_lines) do
        local recipe_variable_name = M.make_variable_name(line.recipe_typed_name)
        local product_count, ingredient_count = 0, 0

        for _, value in ipairs(line.products) do
            local variable_name = M.make_variable_name(value)
            local amount = value.amount_per_second
            problem:add_subject_term(recipe_variable_name, variable_name, amount)
            problem:add_subject_term(recipe_variable_name, "|limit|" .. variable_name, amount)

            if value.type == "item" then
                product_count = product_count + amount
            else
                product_count = product_count + amount / 10
            end
        end

        for _, value in ipairs(line.ingredients) do
            local variable_name = M.make_variable_name(value)
            local amount = value.amount_per_second
            problem:add_subject_term(recipe_variable_name, variable_name, -amount)

            if value.type == "item" then
                ingredient_count = ingredient_count + amount
            else
                ingredient_count = ingredient_count + amount / 10
            end
        end

        local recipe_cost = M.make_recipe_cost(product_count, ingredient_count)
        problem:add_objective(recipe_variable_name, recipe_cost, true)
        problem:add_subject_term(recipe_variable_name, "|limit|" .. recipe_variable_name, 1)
    end

    for _, constraint in ipairs(constraints) do
        local variable_name = M.make_variable_name(constraint)
        local limit = constraint.limit_amount_per_second

        if constraint.limit_type == "upper" then
            problem:add_upper_limit_constraint("|limit|" .. variable_name, limit)
        elseif constraint.limit_type == "lower" then
            problem:add_lower_limit_constraint("|limit|" .. variable_name, limit)
        elseif constraint.limit_type == "equal" then
            problem:add_equivalence_constraint("|limit|" .. variable_name, limit)
        else
            assert()
        end
    end

    return problem
end

return M
