local tn = require "manage/typed_name"
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

---Compute the set of materials that can be produced from raw inputs
---(materials with no producer recipe in the line set) or from recipes
---with no ingredients. Materials not in this set are stuck in dead-end
---cycles and need a |shortage_source| escape hatch in the LP.
---@param production_lines NormalizedProductionLine[]
---@return table<string, true> reachable
function M.compute_reachable_materials(production_lines)
    local has_producer = {} ---@type table<string, true>
    for _, line in ipairs(production_lines) do
        for _, product in ipairs(line.products) do
            has_producer[tn.typed_name_to_variable_name(product)] = true
        end
    end

    local reachable = {} ---@type table<string, true>
    for _, line in ipairs(production_lines) do
        for _, ingredient in ipairs(line.ingredients) do
            local name = tn.typed_name_to_variable_name(ingredient)
            if not has_producer[name] then
                reachable[name] = true
            end
        end
    end

    local fired = {} ---@type table<integer, true>
    repeat
        local changed = false
        for i, line in ipairs(production_lines) do
            if not fired[i] then
                local all_ingredients_reachable = true
                for _, ingredient in ipairs(line.ingredients) do
                    if not reachable[tn.typed_name_to_variable_name(ingredient)] then
                        all_ingredients_reachable = false
                        break
                    end
                end
                if all_ingredients_reachable then
                    fired[i] = true
                    for _, product in ipairs(line.products) do
                        local name = tn.typed_name_to_variable_name(product)
                        if not reachable[name] then
                            reachable[name] = true
                            changed = true
                        end
                    end
                end
            end
        end
    until not changed

    return reachable
end

---Create linear programming problems.
---@param solution_name string
---@param constraints Constraint[]
---@param production_lines NormalizedProductionLine[]
---@return Problem
function M.create_problem(solution_name, constraints, production_lines)
    local problem = problem_generator.new(solution_name)

    local reachable = M.compute_reachable_materials(production_lines)

    local included_products, included_ingresients = {}, {} ---@type table<string, true>, table<string, true>
    for _, line in ipairs(production_lines) do
        local objective_name = tn.typed_name_to_variable_name(line.recipe_typed_name)
        local product_count, ingredient_count = 0, 0

        for _, value in ipairs(line.products) do
            local constraint_name = tn.typed_name_to_variable_name(value)
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
            local constraint_name = tn.typed_name_to_variable_name(value)
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
        -- |shortage_source| is gated on reachability: materials reachable from
        -- raw inputs must run their producer chain. Without this gating the LP
        -- would pay elastic_cost to fabricate intermediates rather than run long
        -- recycling chains (e.g. Fulgora scrap), which produces wrong solutions.
        -- Materials stuck in dead-end cycles (mass-losing loops like fs-test-base
        -- + fs-test-short-negative) keep the escape hatch — otherwise the LP can
        -- only return all-zero.
        if not reachable[constraint_name] then
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
        local constraint_name = "|limit|" .. tn.typed_name_to_variable_name(constraint)
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
