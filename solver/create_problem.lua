local problem_generator = require "solver/problem_generator"

local final_product_cost = 0
local basic_ingredient_cost = 0
local surplus_cost = 2 ^ 10
local shortage_cost = 2 ^ 10

local M = {}

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
            local craft_name = value.type .. "/" .. value.name
            add_set(craft_name)
            set[craft_name].included_product = true
        end
        for _, value in pairs(line.ingredients) do
            local craft_name = value.type .. "/" .. value.name
            add_set(craft_name)
            set[craft_name].included_ingredient = true
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
    return (value / (1 + math.abs(value)) - 1) / 2
end

---Create linear programming problems.
---@param solution_name string
---@param constraints Constraint[]
---@param production_lines NormalizedProductionLine[]
---@return Problem
function M.create_problem(solution_name, constraints, production_lines)
    local problem = problem_generator.new(solution_name)
    local included_items = M.get_included_crafts(production_lines)

    for craft_name, value in pairs(included_items) do
        problem:add_equivalence_constraint(craft_name, 0)

        if value.included_product and value.included_ingredient then
            --TODO Detection of linear dependencies.
            do
                local primal_variable = "|surplus_product|" .. craft_name
                problem:add_objective(primal_variable, surplus_cost)
                problem:add_subject_term(primal_variable, craft_name, -1)
            end
            do
                local primal_variable = "|shortage_ingredient|" .. craft_name
                problem:add_objective(primal_variable, shortage_cost)
                problem:add_subject_term(primal_variable, craft_name, 1)
                problem:add_subject_term(primal_variable, "|limit|" .. craft_name, 1)
            end
        elseif value.included_product then
            local primal_variable = "|final_product|" .. craft_name
            problem:add_objective(primal_variable, final_product_cost)
            problem:add_subject_term(primal_variable, craft_name, -1)
        elseif value.included_ingredient then
            local primal_variable = "|basic_ingredient|" .. craft_name
            problem:add_objective(primal_variable, basic_ingredient_cost)
            problem:add_subject_term(primal_variable, craft_name, 1)
            problem:add_subject_term(primal_variable, "|limit|" .. craft_name, 1)
        else
            assert()
        end
    end

    for _, line in ipairs(production_lines) do
        local recipe_typed_name = line.recipe_typed_name
        local product_count, ingredient_count = 0, 0

        for _, value in ipairs(line.products) do
            local craft_name = value.type .. "/" .. value.name
            local amount = value.amount_per_second
            problem:add_subject_term(recipe_typed_name.name, craft_name, amount)
            problem:add_subject_term(recipe_typed_name.name, "|limit|" .. craft_name, amount)

            if value.type == "item" then
                product_count = product_count + amount
            else
                product_count = product_count + amount / 10
            end
        end

        for _, value in ipairs(line.ingredients) do
            local craft_name = value.type .. "/" .. value.name
            local amount = value.amount_per_second
            problem:add_subject_term(recipe_typed_name.name, craft_name, -amount)

            if value.type == "item" then
                ingredient_count = ingredient_count + amount
            else
                ingredient_count = ingredient_count + amount / 10
            end
        end

        local recipe_cost = M.make_recipe_cost(product_count, ingredient_count)
        problem:add_objective(recipe_typed_name.name, recipe_cost, true)
        problem:add_subject_term(recipe_typed_name.name, "|limit|" .. recipe_typed_name.name, 1)
    end

    for _, constraint in ipairs(constraints) do
        local craft_name
        if constraint.type == "recipe" or constraint.type == "virtual_recipe" then
            craft_name = constraint.name
        else
            craft_name = constraint.type .. "/" .. constraint.name
        end
        local limit = constraint.limit_amount_per_second

        if constraint.limit_type == "upper" then
            problem:add_upper_limit_constraint("|limit|" .. craft_name, limit)
        elseif constraint.limit_type == "lower" then
            problem:add_lower_limit_constraint("|limit|" .. craft_name, limit)
        elseif constraint.limit_type == "equal" then
            problem:add_equivalence_constraint("|limit|" .. craft_name, limit)
        else
            assert()
        end
    end

    return problem
end

return M
