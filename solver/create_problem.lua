local tn = require "manage/typed_name"
local problem_generator = require "solver/problem_generator"

local slack_cost = 0
local elastic_cost = 2 ^ 10
local target_cost = 2 ^ 20

local bridge_prefix = "|bridge|"

local M = {}

---comment
---@param value number
---@return number
function M.make_recipe_cost(value)
    return (value / (1 + math.abs(value)) - 1) / 2
end

---@param line NormalizedProductionLine
---@return boolean
local function is_bridge_line(line)
    return string.sub(line.recipe_typed_name.name, 1, #bridge_prefix) == bridge_prefix
end

---For a temperature-suffixed fluid variable name ("fluid/<X>@T" / "fluid/<X>@[lo,hi]"),
---return the bare-fluid limit dual name ("|limit|fluid/<X>") so constraints on a
---temperature-agnostic fluid pick can aggregate flow across every variant.
---Constraints on temperature-specific variants keep going through their own
---"|limit|fluid/<X>@..." dual, untouched. Returns nil for non-fluid variables and
---for already-bare fluid names (no aggregation to do).
---@param variable_name string
---@return string?
local function bare_fluid_limit_dual(variable_name)
    if string.sub(variable_name, 1, 6) ~= "fluid/" then
        return nil
    end
    local at = string.find(variable_name, "@", 7, true)
    if not at then
        return nil
    end
    return "|limit|" .. string.sub(variable_name, 1, at - 1)
end

---For every (single_temperature, temperature_range) pair found in the production
---line set where the single value falls inside the range, emit a zero-cost
---virtual recipe that converts the single-temperature fluid variable into the
---range-temperature one. The LP solves the otherwise-disconnected variables
---through these bridges (e.g. steam@165 from a boiler feeding a generator that
---accepts steam@[15,1000]).
---@param production_lines NormalizedProductionLine[]
---@return NormalizedProductionLine[]
function M.create_temperature_bridges(production_lines)
    local singles = {}  -- fluid_name -> { temperature = true, ... }
    local ranges = {}   -- fluid_name -> { "min,max" -> { min, max } }

    for _, line in ipairs(production_lines) do
        for _, product in ipairs(line.products) do
            if product.type == "fluid" and product.temperature then
                local s = singles[product.name]
                if not s then
                    s = {}
                    singles[product.name] = s
                end
                s[product.temperature] = true
            end
        end
        for _, ingredient in ipairs(line.ingredients) do
            if ingredient.type == "fluid" and ingredient.minimum_temperature then
                local r = ranges[ingredient.name]
                if not r then
                    r = {}
                    ranges[ingredient.name] = r
                end
                local key = string.format("%g,%g", ingredient.minimum_temperature, ingredient.maximum_temperature)
                r[key] = { ingredient.minimum_temperature, ingredient.maximum_temperature }
            end
        end
    end

    local fluid_names = {}
    local seen = {}
    for name, _ in pairs(singles) do
        if not seen[name] then seen[name] = true; fluid_names[#fluid_names + 1] = name end
    end
    for name, _ in pairs(ranges) do
        if not seen[name] then seen[name] = true; fluid_names[#fluid_names + 1] = name end
    end
    table.sort(fluid_names)

    local bridges = {}
    for _, fluid_name in ipairs(fluid_names) do
        local s = singles[fluid_name]
        local r = ranges[fluid_name]
        if s and r then
            local single_temps = {}
            for t in pairs(s) do single_temps[#single_temps + 1] = t end
            table.sort(single_temps)

            local range_keys = {}
            for k in pairs(r) do range_keys[#range_keys + 1] = k end
            table.sort(range_keys)

            for _, temperature in ipairs(single_temps) do
                for _, range_key in ipairs(range_keys) do
                    local range = r[range_key]
                    local min, max = range[1], range[2]
                    if min <= temperature and temperature <= max then
                        local bridge_name = string.format("%sfluid/%s@%g->[%g,%g]",
                            bridge_prefix, fluid_name, temperature, min, max)
                        ---@type NormalizedProductionLine
                        local bridge_line = {
                            recipe_typed_name = {
                                type = "virtual_recipe",
                                name = bridge_name,
                                quality = "normal",
                            },
                            products = { {
                                type = "fluid",
                                name = fluid_name,
                                quality = "normal",
                                minimum_temperature = min,
                                maximum_temperature = max,
                                amount_per_second = 1,
                            } },
                            ingredients = { {
                                type = "fluid",
                                name = fluid_name,
                                quality = "normal",
                                temperature = temperature,
                                amount_per_second = 1,
                            } },
                            power_per_second = 0,
                            pollution_per_second = 0,
                        }
                        bridges[#bridges + 1] = bridge_line
                    end
                end
            end
        end
    end

    return bridges
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

    local bridges = M.create_temperature_bridges(production_lines)
    -- Bridges are not part of solution.production_lines but their flows do
    -- need to net out in the Final Products / Basic Ingredients panels.
    -- Attach the structured bridge lines so save.get_total_amounts can fold
    -- the LP-solved flows back in without parsing variable-name strings.
    problem.bridges = bridges
    local all_lines = {}
    for _, line in ipairs(production_lines) do all_lines[#all_lines + 1] = line end
    for _, line in ipairs(bridges) do all_lines[#all_lines + 1] = line end

    local reachable = M.compute_reachable_materials(all_lines)

    local included_products, included_ingresients = {}, {} ---@type table<string, true>, table<string, true>
    for _, line in ipairs(all_lines) do
        local objective_name = tn.typed_name_to_variable_name(line.recipe_typed_name)
        local bridge = is_bridge_line(line)
        local product_count, ingredient_count = 0, 0

        for _, value in ipairs(line.products) do
            local constraint_name = tn.typed_name_to_variable_name(value)
            included_products[constraint_name] = true

            local amount = value.amount_per_second
            problem:add_subject_term(objective_name, constraint_name, amount)
            problem:add_subject_term(objective_name, "|limit|" .. constraint_name, amount)

            -- Skip bridges from the bare-fluid aggregation: a bridge re-labels
            -- single-T flow as range-T (or vice versa) without creating any new
            -- fluid, so counting both the boiler's steam@165 product and the
            -- bridge's steam@[15,1000] product would double the bare-fluid total.
            local bare_limit = bare_fluid_limit_dual(constraint_name)
            if bare_limit and not bridge then
                problem:add_subject_term(objective_name, bare_limit, amount)
            end

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

        if bridge then
            problem:add_objective(objective_name, slack_cost, false)
        else
            local recipe_cost = M.make_recipe_cost(ingredient_count - product_count)
            problem:add_objective(objective_name, recipe_cost, true)
            problem:add_subject_term(objective_name, "|limit|" .. objective_name, 1)
        end
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

            local bare_limit = bare_fluid_limit_dual(constraint_name)
            if bare_limit then
                problem:add_subject_term(elastic_name, bare_limit, 1)
            end
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

        local bare_limit = bare_fluid_limit_dual(constraint_name)
        if bare_limit then
            problem:add_subject_term(slack_name, bare_limit, 1)
        end
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
