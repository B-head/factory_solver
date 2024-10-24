local fs_util = require "fs_util"
local problem_generator = require "solver/problem_generator"

local final_product_cost = 2 ^ -10
local basic_ingredient_cost = 2 ^ -10
local surplus_cost = 2 ^ 0
local shortage_cost = 2 ^ 0

local target_profit = -2 ^ 10
local machine_count_cost = 0

local M = {}

---comment
---@param production_lines NormalizedProductionLine[]
---@return table<string, { included_product: boolean, included_ingredient: boolean }>
local function get_included_crafts(production_lines)
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

local function create_item_flow_graph(flat_recipe_lines)
    local ret = {}
    local function add(a, type, b, ratio)
        if not ret[a] then
            ret[a] = {
                from = {},
                to = {},
                visited = false,
                cycled = false,
            }
        end
        table.insert(ret[a][type], { id = b, ratio = ratio })
    end

    for _, l in pairs(flat_recipe_lines) do
        for _, a in pairs(l.products) do
            for _, b in pairs(l.ingredients) do
                local ratio = b.amount_per_machine_by_second / a.amount_per_machine_by_second
                add(a.normalized_id, "to", b.normalized_id, ratio)
            end
        end
        for _, a in pairs(l.ingredients) do
            for _, b in pairs(l.products) do
                local ratio = b.amount_per_machine_by_second / a.amount_per_machine_by_second
                add(a.normalized_id, "from", b.normalized_id, ratio)
            end
        end
    end
    return ret
end

local function detect_cycle_dilemma_impl(item_flow_graph, id, path)
    local current = item_flow_graph[id]
    if current.visited then
        local included = false
        for _, path_id in ipairs(path) do
            if path_id == id then
                included = true
            end
            if included then
                item_flow_graph[path_id].cycled = true
            end
        end
        return
    end

    current.visited = true
    table.insert(path, id)
    for _, n in ipairs(current.to) do
        detect_cycle_dilemma_impl(item_flow_graph, n.id, path)
    end
    table.remove(path)
end

local function detect_cycle_dilemma(flat_recipe_lines)
    local item_flow_graph = create_item_flow_graph(flat_recipe_lines)
    local path = {}
    for id, _ in pairs(item_flow_graph) do
        if not item_flow_graph[id].visited then
            detect_cycle_dilemma_impl(item_flow_graph, id, path)
        end
    end

    local ret = {}
    for id, v in pairs(item_flow_graph) do
        ret[id] = { product = v.cycled, ingredient = v.cycled }
    end
    return ret
end

---comment
---@param constraints Constraint[]
---@param typed_name TypedName
local function has_upper_limit(constraints, typed_name)
    local pos = fs_util.find(constraints, function(value)
        return value.type == typed_name.type and value.name == typed_name.name
    end)
    if pos then
        local c = constraints[pos]
        return c.limit_type == "upper" or c.limit_type == "equal"
    else
        return false
    end
end

---Create linear programming problems.
---@param solution_name string
---@param constraints Constraint[]
---@param production_lines NormalizedProductionLine[]
---@return Problem
function M.create_problem(solution_name, constraints, production_lines)
    local problem = problem_generator.new(solution_name)
    local included_items = get_included_crafts(production_lines)

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
                problem:add_subject_term(primal_variable, "|upper_limit|" .. craft_name, 1)
                problem:add_subject_term(primal_variable, "|lower_limit|" .. craft_name, 1)
            end
        elseif value.included_product then
            local primal_variable = "|final_product|" .. craft_name
            problem:add_objective(primal_variable, final_product_cost)
            problem:add_subject_term(primal_variable, craft_name, -1)
        elseif value.included_ingredient then
            local primal_variable = "|basic_ingredient|" .. craft_name
            problem:add_objective(primal_variable, basic_ingredient_cost)
            problem:add_subject_term(primal_variable, craft_name, 1)
            problem:add_subject_term(primal_variable, "|upper_limit|" .. craft_name, 1)
            problem:add_subject_term(primal_variable, "|lower_limit|" .. craft_name, 1)
        else
            assert()
        end
    end

    for _, line in ipairs(production_lines) do
        local recipe_typed_name = line.recipe_typed_name

        problem:add_objective(recipe_typed_name.name, machine_count_cost, true)
        problem:add_subject_term(recipe_typed_name.name, "|upper_limit|" .. recipe_typed_name.name, 1)
        problem:add_subject_term(recipe_typed_name.name, "|lower_limit|" .. recipe_typed_name.name, 1)

        if has_upper_limit(constraints, recipe_typed_name) then
            problem:update_objective_cost(recipe_typed_name.name, target_profit)
        end

        for _, value in ipairs(line.products) do
            local craft_name = value.type .. "/" .. value.name
            local amount = value.amount_per_second
            problem:add_subject_term(recipe_typed_name.name, craft_name, amount)
            problem:add_subject_term(recipe_typed_name.name, "|upper_limit|" .. craft_name, amount)
            problem:add_subject_term(recipe_typed_name.name, "|lower_limit|" .. craft_name, amount)

            if has_upper_limit(constraints, value) then
                problem:update_objective_cost(recipe_typed_name.name, target_profit)
            end
        end

        for _, value in ipairs(line.ingredients) do
            local craft_name = value.type .. "/" .. value.name
            local amount = value.amount_per_second
            problem:add_subject_term(recipe_typed_name.name, craft_name, -amount)

            if has_upper_limit(constraints, value) then
                problem:update_objective_cost(recipe_typed_name.name, target_profit)
            end
        end
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
            problem:add_upper_limit_constraint("|upper_limit|" .. craft_name, limit)
        elseif constraint.limit_type == "lower" then
            problem:add_upper_limit_constraint("|lower_limit|" .. craft_name, limit)
        elseif constraint.limit_type == "equal" then
            problem:add_upper_limit_constraint("|upper_limit|" .. craft_name, limit)
            problem:add_upper_limit_constraint("|lower_limit|" .. craft_name, limit)
        else
            assert()
        end
    end

    return problem
end

return M
