local problem_generator = require "solver/problem_generator"

local slack_cost = 0
local elastic_cost = 2 ^ 10
local target_cost = 2 ^ 20

local M = {}

---comment
---@param value number
---@return number
function M.make_recipe_cost(value)
    return (value / (1 + math.abs(value)) - 1) / 2
end

---Create linear programming problems.
---@param solution_name string
---@param constraints Constraint[]
---@param production_lines NormalizedProductionLine[]
---@return Problem
function M.create_problem(solution_name, constraints, production_lines)
    local problem = problem_generator.new(solution_name)

    local included_products, included_ingresients = {}, {} ---@type table<string, true>, table<string, true>
    for _, line in ipairs(production_lines) do
        local objective_name = line.recipe_typed_name.name
        local product_count, ingredient_count = 0, 0

        for _, value in ipairs(line.products) do
            local constraint_name = value.type .. "/" .. value.name
            included_products[constraint_name] = true

            local amount = value.amount_per_second
            problem:add_subject_term(objective_name, constraint_name, amount)
            problem:add_subject_term(objective_name, "|limit|" .. constraint_name, amount)

            if value.type == "item" then
                product_count = product_count + amount
            else
                product_count = product_count + amount / 10
            end
        end

        for _, value in ipairs(line.ingredients) do
            local constraint_name = value.type .. "/" .. value.name
            included_ingresients[constraint_name] = true

            local amount = value.amount_per_second
            problem:add_subject_term(objective_name, constraint_name, -amount)

            if value.type == "item" then
                ingredient_count = ingredient_count + amount
            else
                ingredient_count = ingredient_count + amount / 10
            end
        end

        local recipe_cost = M.make_recipe_cost(ingredient_count - product_count)
        problem:add_objective(objective_name, recipe_cost, true)
        problem:add_subject_term(objective_name, "|limit|" .. objective_name, 1)
    end

    for constraint_name, _ in pairs(included_products) do
        if not included_ingresients[constraint_name] then
            goto continue
        end
        included_products[constraint_name] = nil
        included_ingresients[constraint_name] = nil

        problem:add_equivalence_constraint(constraint_name, 0)

        do
            local elastic_name = "|surplus_sink|" .. constraint_name
            problem:add_objective(elastic_name, elastic_cost)
            problem:add_subject_term(elastic_name, constraint_name, -1)
        end
        do
            local elastic_name = "|shortage_source|" .. constraint_name
            problem:add_objective(elastic_name, elastic_cost)
            problem:add_subject_term(elastic_name, constraint_name, 1)
            problem:add_subject_term(elastic_name, "|limit|" .. constraint_name, 1)
        end
        ::continue::
    end

    for constraint_name, _ in pairs(included_products) do
        problem:add_equivalence_constraint(constraint_name, 0)

        local slack_name = "|final_sink|" .. constraint_name
        problem:add_objective(slack_name, slack_cost)
        problem:add_subject_term(slack_name, constraint_name, -1)
    end

    for constraint_name, _ in pairs(included_ingresients) do
        problem:add_equivalence_constraint(constraint_name, 0)

        local slack_name = "|basic_source|" .. constraint_name
        problem:add_objective(slack_name, slack_cost)
        problem:add_subject_term(slack_name, constraint_name, 1)
        problem:add_subject_term(slack_name, "|limit|" .. constraint_name, 1)
    end

    for _, constraint in ipairs(constraints) do
        local constraint_name
        if constraint.type == "recipe" or constraint.type == "virtual_recipe" then
            constraint_name = "|limit|" .. constraint.name
        else
            constraint_name = "|limit|" .. constraint.type .. "/" .. constraint.name
        end
        local limit = constraint.limit_amount_per_second

        if constraint.limit_type == "upper" then
            local slack_name = problem:add_upper_limit_constraint(constraint_name, limit)
            problem:update_objective_cost(slack_name, target_cost)
        elseif constraint.limit_type == "lower" then
            problem:add_lower_limit_constraint(constraint_name, limit)

            local elastic_name = "|elastic|" .. constraint_name
            problem:add_objective(elastic_name, elastic_cost)
            problem:add_subject_term(elastic_name, constraint_name, 1)
        elseif constraint.limit_type == "equal" then
            problem:add_equivalence_constraint(constraint_name, limit)

            local elastic_name = "|elastic|" .. constraint_name
            problem:add_objective(elastic_name, elastic_cost)
            problem:add_subject_term(elastic_name, constraint_name, 1)
        else
            assert()
        end
    end

    return problem
end

return M
