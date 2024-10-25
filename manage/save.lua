local flib_table = require "__flib__/table"
local flib_math = require "__flib__/math"

local fs_util = require "fs_util"
local info = require "manage/info"
local virtual = require "manage/virtual"
local problem_generator = require "solver/problem_generator"

local M = {}

---comment
---@param player_index integer
function M.init_player_data(player_index)
    if not storage.players[player_index] then
        storage.players[player_index] = {
            selected_solution = "",
            selected_filter_type = "item",
            selected_filter_group = { -- TODO Dynamic initialization
                item = "logistics",
                fluid = "fluids",
                recipe = "logistics",
                virtual_recipe = "production",
            },
            unresearched_craft_visible = __DebugAdapter ~= nil,
            hidden_craft_visible = __DebugAdapter ~= nil,
            time_scale = "minute",
            amount_unit = "time",
            fuel_presets = M.init_fuel_presets(),
            machine_presets = M.init_machine_presets(),
            opened_gui = {},
        }
    end
end

---comment
---@param player_index integer
function M.reinit_player_data(player_index)
    local player_data = storage.players[player_index]
    if player_data then
        if not info.scale_per_second[player_data.time_scale] then
            player_data.time_scale = "minute"
        end
        if false then
            player_data.amount_unit = "time"
        end
        player_data.fuel_presets = M.init_fuel_presets(player_data.fuel_presets)
        player_data.machine_presets = M.init_machine_presets(player_data.machine_presets)
    else
        M.init_player_data(player_index)
    end
end

---comment
---@param fuel_categories { [string]: boolean }
---@return string
function M.join_fuel_categories(fuel_categories)
    local joined_fuel_category = ""
    for name, _ in pairs(fuel_categories) do
        if joined_fuel_category ~= "" then
            joined_fuel_category = joined_fuel_category .. "|"
        end
        joined_fuel_category = joined_fuel_category .. name
    end
    return joined_fuel_category
end

---comment
---@param origin table<string, TypedName>?
---@return table<string, TypedName>
function M.init_fuel_presets(origin)
    local ret = {}
    if origin then
        ret = flib_table.deep_copy(origin)
    end

    for category_name, _ in pairs(prototypes.fuel_category) do
        if info.validate_typed_name(ret[category_name]) then
            goto continue
        end

        local fuels = info.get_fuels_in_categories(category_name)
        local first = fs_util.find(fuels, function(value)
            return not info.is_hidden(value)
        end)
        if first then
            ret[category_name] = info.craft_to_typed_name(fuels[first])
        end

        ::continue::
    end

    return ret
end

---comment
---@param origin table<string, TypedName>?
---@return table<string, TypedName>
function M.init_machine_presets(origin)
    local ret = {}
    if origin then
        ret = flib_table.deep_copy(origin)
    end

    local function add(category_name)
        if info.validate_typed_name(ret[category_name]) then
            return
        end

        local machines = info.get_machines_in_category(category_name)
        local pos = fs_util.find(machines, function(value)
            return not info.is_hidden(value)
        end)
        if pos then
            local first = machines[pos]
            ret[category_name] = info.craft_to_typed_name(first)
        end
    end

    for category_name, _ in pairs(prototypes.recipe_category) do
        add(category_name)
    end

    for category_name, _ in pairs(storage.virtuals.crafting_categories) do
        add(category_name)
    end

    return ret
end

---comment
---@param force_index integer
function M.init_force_data(force_index)
    if not storage.forces[force_index] then
        storage.forces[force_index] = {
            relation_to_recipes = { enabled_recipe = {}, item = {}, fluid = {}, virtual_recipe = {} },
            relation_to_recipes_needs_updating = true,
            group_infos = { item = {}, fluid = {}, recipe = {}, virtual_recipe = {} },
            group_infos_needs_updating = true,
            solutions = {},
        }
    end
end

---comment
---@param force_index integer
function M.reinit_force_data(force_index)
    local force_data = storage.forces[force_index]
    if force_data then
        force_data.relation_to_recipes_needs_updating = true
        force_data.group_infos_needs_updating = true
    else
        M.init_force_data(force_index)
    end
end

---comment
---@param force_data ForceLocalData
function M.resetup_force_data_metatable(force_data)
    if force_data then
        for _, solution in pairs(force_data.solutions) do
            if solution.problem then
                problem_generator.setup_metatable(solution.problem)
            end
        end
    end
end

---comment
---@param player_index integer
---@return PlayerLocalData
function M.get_player_data(player_index)
    return storage.players[player_index]
end

---comment
---@param player_index integer
---@return table<string, Solution>
function M.get_solutions(player_index)
    local force_index = game.players[player_index].force_index
    return storage.forces[force_index].solutions
end

---comment
---@param player_index integer
---@return Solution?
function M.get_selected_solution(player_index)
    local force_index = game.players[player_index].force_index
    local player_data = storage.players[player_index]
    return storage.forces[force_index].solutions[player_data.selected_solution]
end

---comment
---@param player_index integer
---@return RelationToRecipes
function M.get_relation_to_recipes(player_index)
    local force_index = game.players[player_index].force_index
    local force_data = storage.forces[force_index]
    if force_data.relation_to_recipes_needs_updating then
        force_data.relation_to_recipes_needs_updating = false
        force_data.relation_to_recipes = info.create_relation_to_recipes(force_index)
    end
    return force_data.relation_to_recipes
end

---comment
---@param player_index integer
---@param filter_type FilterType
---@return GroupInfos
function M.get_group_infos(player_index, filter_type)
    local force_index = game.players[player_index].force_index
    local force_data = storage.forces[force_index]
    if force_data.group_infos_needs_updating then
        local relation_to_recipes = M.get_relation_to_recipes(player_index)
        force_data.group_infos_needs_updating = false
        force_data.group_infos = info.create_group_infos(force_index, relation_to_recipes)
    end
    return assert(force_data.group_infos[filter_type])
end

---comment
---@param player_index integer
---@param machine_typed_name TypedName
---@return TypedName?
function M.get_fuel_preset(player_index, machine_typed_name)
    local player_data = storage.players[player_index]

    local machine = info.typed_name_to_machine(machine_typed_name)

    local fixed_fuel = info.try_get_fixed_fuel(machine)
    if fixed_fuel then
        return fixed_fuel
    end

    local fuel_categories = info.try_get_fuel_categories(machine)
    if fuel_categories then
        local joined_fuel_category = M.join_fuel_categories(fuel_categories)
        return assert(player_data.fuel_presets[joined_fuel_category])
    end

    return nil
end

---comment
---@param player_index integer
---@param recipe_typed_name TypedName
---@return TypedName
function M.get_machine_preset(player_index, recipe_typed_name)
    local player_data = storage.players[player_index]
    if virtual.is_virtual(recipe_typed_name) then
        local recipe = storage.virtuals.recipe[recipe_typed_name.name]
        return assert(player_data.machine_presets[recipe.category])
    else
        local recipe = prototypes.recipe[recipe_typed_name.name]
        return assert(player_data.machine_presets[recipe.category])
    end
end

---comment
---@param solution Solution
---@return table<string, number>
---@return table<string, number>
---@return table<string, number>
function M.get_total_amounts(solution)
    local item_totals, fluid_totals, virtual_totals = {}, {}, {}

    for _, line in ipairs(solution.production_lines) do
        local recipe = info.typed_name_to_recipe(line.recipe_typed_name)
        local machine = info.typed_name_to_machine(line.machine_typed_name)
        local craft_energy = assert(recipe.energy)
        local crafting_speed = info.get_crafting_speed(machine, line.machine_quality)
        local module_counts = info.get_total_modules(machine, line.module_names, line.affected_by_beacons)
        local effectivity = info.get_total_effectivity(module_counts)
        local quantity_of_machines_required = M.get_quantity_of_machines_required(solution, line.recipe_typed_name.name)

        for _, value in pairs(recipe.products) do
            local amount_per_second = info.raw_product_to_amount(value, craft_energy, crafting_speed,
                effectivity.speed, effectivity.productivity)
            amount_per_second = amount_per_second * quantity_of_machines_required

            if value.type == "item" then
                item_totals[value.name] = (item_totals[value.name] or 0) + amount_per_second
            elseif value.type == "fluid" then
                fluid_totals[value.name] = (fluid_totals[value.name] or 0) + amount_per_second
            elseif value.type == "virtual_material" then
                virtual_totals[value.name] = (virtual_totals[value.name] or 0) + amount_per_second
            else
                virtual_totals["<material-unknown>"] = (virtual_totals["<material-unknown>"] or 0) + amount_per_second
            end
        end

        for _, value in pairs(recipe.ingredients) do
            local amount_per_second = info.raw_ingredient_to_amount(value, craft_energy, crafting_speed, effectivity.speed)
            amount_per_second = amount_per_second * effectivity.speed * quantity_of_machines_required

            if value.type == "item" then
                item_totals[value.name] = (item_totals[value.name] or 0) - amount_per_second
            elseif value.type == "fluid" then
                fluid_totals[value.name] = (fluid_totals[value.name] or 0) - amount_per_second
            elseif value.type == "virtual_material" then
                virtual_totals[value.name] = (virtual_totals[value.name] or 0) - amount_per_second
            else
                virtual_totals["<material-unknown>"] = (virtual_totals["<material-unknown>"] or 0) + amount_per_second
            end
        end

        if info.is_use_fuel(machine) then
            local ftn = assert(line.fuel_typed_name)
            local power = info.raw_energy_to_power(machine, line.machine_quality, effectivity.consumption)
            power = power * quantity_of_machines_required
            local fuel = info.typed_name_to_material(line.fuel_typed_name)
            local amount_per_second = info.get_fuel_amount_per_second(power, fuel, machine)

            if info.is_generator(machine) then
                amount_per_second = -amount_per_second
            end

            if fuel.type == "item" then
                item_totals[fuel.name] = (item_totals[fuel.name] or 0) - amount_per_second
            elseif fuel.type == "fluid" then
                fluid_totals[fuel.name] = (fluid_totals[fuel.name] or 0) - amount_per_second
            elseif fuel.type == "virtual_material" then
                virtual_totals[fuel.name] = (virtual_totals[fuel.name] or 0) - amount_per_second
            else
                virtual_totals["<material-unknown>"] = (virtual_totals["<material-unknown>"] or 0) + amount_per_second
            end
        end
    end

    return item_totals, fluid_totals, virtual_totals
end

---comment
---@param solution Solution
---@return number
function M.get_total_power(solution)
    local total = 0

    for _, line in ipairs(solution.production_lines) do
        local machine = info.typed_name_to_machine(line.machine_typed_name)
        local module_counts = info.get_total_modules(machine, line.module_names, line.affected_by_beacons)
        local effectivity = info.get_total_effectivity(module_counts)
        local quantity_of_machines_required = M.get_quantity_of_machines_required(solution, line.recipe_typed_name.name)

        if not info.is_use_fuel(machine) or info.is_generator(machine) then
            local power = info.raw_energy_to_power(machine, line.machine_quality, effectivity.consumption)
            power = power * quantity_of_machines_required
            total = total + power
        end
    end

    return total
end

---comment
---@param solution Solution
---@return number
function M.get_total_pollution(solution)
    local total = 0

    for _, line in ipairs(solution.production_lines) do
        local machine = info.typed_name_to_machine(line.machine_typed_name)
        local module_counts = info.get_total_modules(machine, line.module_names, line.affected_by_beacons)
        local effectivity = info.get_total_effectivity(module_counts)
        local quantity_of_machines_required = M.get_quantity_of_machines_required(solution, line.recipe_typed_name.name)

        local pollution = info.raw_emission_to_pollution(machine, "pollution", line.machine_quality,
            effectivity.consumption, effectivity.pollution)
        pollution = pollution * quantity_of_machines_required

        if info.is_use_fuel(machine) then
            local fuel = info.typed_name_to_material(line.fuel_typed_name)
            pollution = pollution * info.get_fuel_emissions_multiplier(fuel)
        end

        total = total + pollution
    end

    return total
end

---comment
---@param solution Solution
---@param result_key string
---@return number
function M.get_quantity_of_machines_required(solution, result_key)
    return solution.quantity_of_machines_required[result_key] or 1
end

---comment
---@param solutions table<string, Solution>
---@param solution_name string?
---@return string
function M.new_solution(solutions, solution_name)
    solution_name = solution_name or "Solution"

    local new_solution_name
    local postfix_number = 1
    repeat
        new_solution_name = solution_name .. " " .. postfix_number
        postfix_number = postfix_number + 1
    until not solutions[new_solution_name]

    ---@type Solution
    local solution = {
        name = new_solution_name,
        constraints = {},
        production_lines = {},
        quantity_of_machines_required = {},
        solver_state = "finished",
    }
    solutions[new_solution_name] = solution

    return new_solution_name
end

---comment
---@param solutions table<string, Solution>
---@param solution_name string
function M.delete_solution(solutions, solution_name)
    solutions[solution_name] = nil
end

---comment
---@param solutions table<string, Solution>
---@param solution_name string
---@param new_solution_name string
---@return string
function M.rename_solution(solutions, solution_name, new_solution_name)
    local temp = solutions[solution_name]
    solutions[solution_name] = nil

    local postfix_number = 1
    while solutions[new_solution_name] do
        new_solution_name = new_solution_name .. " " .. postfix_number
        postfix_number = postfix_number + 1
    end

    temp.name = new_solution_name
    solutions[new_solution_name] = temp

    return new_solution_name
end

---comment
---@param solution Solution
function M.sort_constraints(solution)
    -- TODO
end

---comment
---@param solution Solution
---@param typed_name TypedName
function M.new_constraint(solution, typed_name)
    local constraints = solution.constraints

    local pos = fs_util.find(constraints, function(value)
        return info.equals_typed_name(value, typed_name)
    end)
    if pos then
        return
    end

    local amount
    if typed_name.type == "recipe" or typed_name.type == "virtual_recipe" then
        amount = 1
    else
        amount = 0.5
    end

    ---@type Constraint
    local add_data = {
        type = typed_name.type,
        name = typed_name.name,
        limit_type = "upper",
        limit_amount_per_second = amount,
    }
    flib_table.insert(constraints, add_data)

    M.sort_constraints(solution)
    solution.solver_state = "ready"
end

---comment
---@param solution Solution
---@param constraint_index integer
function M.delete_constraint(solution, constraint_index)
    local constraints = solution.constraints
    flib_table.remove(constraints, constraint_index)

    M.sort_constraints(solution)
    solution.solver_state = "ready"
end

---comment
---@param solution Solution
---@param constraint_index integer
---@param data table
function M.update_constraint(solution, constraint_index, data)
    solution.constraints[constraint_index] = flib_table.shallow_merge {
        solution.constraints[constraint_index],
        data,
    }

    M.sort_constraints(solution)
    solution.solver_state = "ready"
end

---comment
---@param player_index integer
---@param solution Solution
---@param recipe_typed_name TypedName
---@param line_index integer?
function M.new_production_line(player_index, solution, recipe_typed_name, line_index)
    local production_lines = solution.production_lines
    line_index = line_index or #production_lines + 1

    local pos = fs_util.find(production_lines, function(value)
        return value.recipe_typed_name.type == recipe_typed_name.type and
            value.recipe_typed_name.name == recipe_typed_name.name
    end)
    if pos then
        M.move_production_line(solution, pos, line_index)
        return
    end

    local machine_typed_name = M.get_machine_preset(player_index, recipe_typed_name)
    local fuel_typed_name = M.get_fuel_preset(player_index, machine_typed_name)

    ---@type ProductionLine
    local line = {
        recipe_typed_name = recipe_typed_name,
        machine_typed_name = machine_typed_name,
        machine_quality = "normal",
        module_names = {},
        affected_by_beacons = {},
        fuel_typed_name = fuel_typed_name,
    }
    flib_table.insert(production_lines, line_index, line)

    solution.solver_state = "ready"
end

---comment
---@param solution Solution
---@param line_index integer?
function M.delete_production_line(solution, line_index)
    local production_lines = solution.production_lines
    flib_table.remove(production_lines, line_index)

    solution.solver_state = "ready"
end

---comment
---@param solution Solution
---@param line_index integer
---@param data ProductionLine
function M.update_production_line(solution, line_index, data)
    local line = solution.production_lines[line_index]
    line.recipe_typed_name = data.recipe_typed_name
    line.machine_typed_name = data.machine_typed_name
    line.machine_quality = data.machine_quality
    line.module_names = data.module_names
    line.affected_by_beacons = data.affected_by_beacons
    line.fuel_typed_name = data.fuel_typed_name

    solution.solver_state = "ready"
end

---comment
---@param solution Solution
---@param from_line_index integer
---@param to_line_index integer
function M.move_production_line(solution, from_line_index, to_line_index)
    local production_lines = solution.production_lines
    local tail = #solution.production_lines

    from_line_index = flib_math.clamp(from_line_index, 1, tail)
    to_line_index = flib_math.clamp(to_line_index, 1, tail)

    local temp = flib_table.remove(production_lines, from_line_index)
    flib_table.insert(production_lines, to_line_index, temp)
end

return M
