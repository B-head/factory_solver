local flib_table = require "__flib__/table"
local flib_math = require "__flib__/math"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local info = require "manage/information"
local tn = require "manage/typed_name"
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
            presets = {
                fuel = info.create_fuel_presets(),
                fluid_fuel = info.create_fluid_fuel_preset(),
                resource = info.create_resource_presets(),
                machine = info.create_machine_presets(),
            },
            opened_gui = {},
        }
    end
end

---comment
---@param player_index integer
function M.reinit_player_data(player_index)
    ---@diagnostic disable: undefined-field
    ---@diagnostic disable: inject-field
    local player_data = storage.players[player_index]
    if player_data then
        if not acc.scale_per_second[player_data.time_scale] then
            player_data.time_scale = "minute"
        end
        if false then
            player_data.amount_unit = "time"
        end
        local presets = player_data.presets
        if presets then
            presets.fuel = info.create_fuel_presets(presets.fuel)
            presets.fluid_fuel = info.create_fluid_fuel_preset(presets.fluid_fuel)
            presets.resource = info.create_resource_presets(presets.resource)
            presets.machine = info.create_machine_presets(presets.machine)
        else
            player_data.presets = {
                fuel = info.create_fuel_presets(player_data.fuel_presets),
                fluid_fuel = info.create_fluid_fuel_preset(),
                resource = info.create_resource_presets(player_data.resource_presets),
                machine = info.create_machine_presets(player_data.machine_presets),
            }
            player_data.fuel_presets = nil
            player_data.resource_presets = nil
            player_data.machine_presets = nil
        end
    else
        M.init_player_data(player_index)
    end
    ---@diagnostic enable: undefined-field
    ---@diagnostic enable: inject-field
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
    ---@diagnostic disable: undefined-field
    ---@diagnostic disable: inject-field
    local force_data = storage.forces[force_index]
    if force_data then
        force_data.relation_to_recipes_needs_updating = true
        force_data.group_infos_needs_updating = true

        for _, solution in pairs(force_data.solutions) do
            for _, line in pairs(solution.production_lines) do
                tn.typed_name_migration(line.recipe_typed_name)
                tn.typed_name_migration(line.machine_typed_name)
                tn.typed_name_migration(line.fuel_typed_name)

                if line.module_names then
                    local module_typed_names = {}
                    for _, name in pairs(line.module_names) do
                        local typed_name = tn.create_typed_name("item", name)
                        flib_table.insert(module_typed_names, typed_name)
                    end
                    line.module_typed_names = module_typed_names
                    line.module_names = nil
                else
                    for _, typed_name in pairs(line.module_typed_names) do
                        tn.typed_name_migration(typed_name)
                    end
                end

                for _, affected in pairs(line.affected_by_beacons) do
                    if affected.beacon_name then
                        affected.beacon_typed_name = tn.create_typed_name("machine", affected.beacon_name)
                        affected.beacon_name = nil
                    else
                        tn.typed_name_migration(affected.beacon_typed_name)
                    end

                    if affected.module_names then
                        local module_typed_names = {}
                        for _, name in pairs(affected.module_names) do
                            local typed_name = tn.create_typed_name("item", name)
                            flib_table.insert(module_typed_names, typed_name)
                        end
                        affected.module_typed_names = module_typed_names
                        affected.module_names = nil
                    else
                        for _, typed_name in pairs(affected.module_typed_names) do
                            tn.typed_name_migration(typed_name)
                        end
                    end
                end
            end
        end
    else
        M.init_force_data(force_index)
    end
    ---@diagnostic enable: undefined-field
    ---@diagnostic enable: inject-field
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

    local machine = tn.typed_name_to_machine(machine_typed_name)

    local fixed_fuel = acc.try_get_fixed_fuel(machine)
    if fixed_fuel then
        return fixed_fuel
    end

    if acc.is_use_any_fluid_fuel(machine) then
        return assert(player_data.presets.fluid_fuel)
    end

    local fuel_categories = acc.try_get_fuel_categories(machine)
    if fuel_categories then
        local joined_fuel_category = info.join_fuel_categories(fuel_categories)
        return assert(player_data.presets.fuel[joined_fuel_category])
    end

    return nil
end

---comment
---@param player_index integer
---@param recipe_typed_name TypedName
---@return TypedName
function M.get_machine_preset(player_index, recipe_typed_name)
    local player_data = storage.players[player_index]
    if recipe_typed_name.type == "virtual_recipe" then
        local recipe = storage.virtuals.recipe[recipe_typed_name.name]
        if recipe.fixed_crafting_machine then
            return recipe.fixed_crafting_machine
        elseif recipe.resource_category then
            return assert(player_data.presets.resource[recipe.resource_category])
        else
            return assert()
        end
    elseif recipe_typed_name.type == "recipe" then
        local recipe = prototypes.recipe[recipe_typed_name.name]
        return assert(player_data.presets.machine[recipe.category])
    else
        return assert()
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
        local recipe = tn.typed_name_to_recipe(line.recipe_typed_name)
        local machine = tn.typed_name_to_machine(line.machine_typed_name)
        local machine_quality = line.machine_typed_name.quality
        local module_counts = M.get_total_modules(machine, line.module_typed_names, line.affected_by_beacons)
        local effectivity = M.get_total_effectivity(module_counts)
        local crafting_energy = acc.get_crafting_energy(recipe)
        local crafting_speed_cap = acc.get_crafting_speed_cap(recipe)
        local crafting_speed = acc.get_crafting_speed(machine, machine_quality, effectivity.speed, crafting_speed_cap)
        local quantity_of_machines_required = M.get_quantity_of_machines_required(solution, line.recipe_typed_name)

        for _, product in pairs(recipe.products) do
            local amount = acc.raw_product_to_amount(
                product,
                "unknown-quality",
                crafting_energy,
                crafting_speed,
                effectivity.productivity
            )
            local filter_type = amount.type
            local name = amount.name
            local amount_per_second = amount.amount_per_second * quantity_of_machines_required

            if filter_type == "item" then
                item_totals[name] = (item_totals[name] or 0) + amount_per_second
            elseif filter_type == "fluid" then
                fluid_totals[name] = (fluid_totals[name] or 0) + amount_per_second
            elseif filter_type == "virtual_material" then
                virtual_totals[name] = (virtual_totals[name] or 0) + amount_per_second
            else
                virtual_totals["<material-unknown>"] = (virtual_totals["<material-unknown>"] or 0) + amount_per_second
            end
        end

        for _, ingredient in pairs(recipe.ingredients) do
            local amount = acc.raw_ingredient_to_amount(
                ingredient,
                "unknown-quality",
                crafting_energy,
                crafting_speed
            )
            local filter_type = amount.type
            local name = amount.name
            local amount_per_second = amount.amount_per_second * quantity_of_machines_required

            if filter_type == "item" then
                item_totals[name] = (item_totals[name] or 0) - amount_per_second
            elseif filter_type == "fluid" then
                fluid_totals[name] = (fluid_totals[name] or 0) - amount_per_second
            elseif filter_type == "virtual_material" then
                virtual_totals[name] = (virtual_totals[name] or 0) - amount_per_second
            else
                virtual_totals["<material-unknown>"] = (virtual_totals["<material-unknown>"] or 0) + amount_per_second
            end
        end

        if acc.is_use_fuel(machine) then
            local ftn = assert(line.fuel_typed_name)
            local fuel = tn.typed_name_to_material(ftn)
            local amount_per_second = acc.get_fuel_amount_per_second(machine, machine_quality,
                fuel, ftn.quality, effectivity.consumption) * quantity_of_machines_required

            if fuel.type == "item" then
                item_totals[ftn.name] = (item_totals[ftn.name] or 0) - amount_per_second
            elseif fuel.type == "fluid" then
                fluid_totals[ftn.name] = (fluid_totals[ftn.name] or 0) - amount_per_second
            elseif fuel.type == "virtual_material" then
                virtual_totals[ftn.name] = (virtual_totals[ftn.name] or 0) - amount_per_second
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
        local recipe = tn.typed_name_to_recipe(line.recipe_typed_name)
        local machine = tn.typed_name_to_machine(line.machine_typed_name)
        local machine_quality = line.machine_typed_name.quality
        local module_counts = M.get_total_modules(machine, line.module_typed_names, line.affected_by_beacons)
        local effectivity = M.get_total_effectivity(module_counts)
        local crafting_speed_cap = acc.get_crafting_speed_cap(recipe)
        local crafting_speed = acc.get_crafting_speed(machine, machine_quality, effectivity.speed, crafting_speed_cap)
        local quantity_of_machines_required = M.get_quantity_of_machines_required(solution, line.recipe_typed_name)

        if not acc.is_use_fuel(machine) then
            local power = acc.raw_energy_usage_to_power(machine, machine_quality, effectivity.consumption)
            total = total + power * quantity_of_machines_required
        elseif acc.is_generator(machine) then
            local power = acc.raw_energy_production_to_power(machine, machine_quality)
            total = total + power * quantity_of_machines_required
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
        local machine = tn.typed_name_to_machine(line.machine_typed_name)
        local machine_quality = line.machine_typed_name.quality
        local module_counts = M.get_total_modules(machine, line.module_typed_names, line.affected_by_beacons)
        local effectivity = M.get_total_effectivity(module_counts)
        local quantity_of_machines_required = M.get_quantity_of_machines_required(solution, line.recipe_typed_name)

        local pollution = acc.raw_emission_to_pollution(machine, "pollution", machine_quality,
            effectivity.consumption, effectivity.pollution)
        pollution = pollution * quantity_of_machines_required

        if acc.is_use_fuel(machine) then
            local fuel = tn.typed_name_to_material(line.fuel_typed_name)
            pollution = pollution * acc.get_fuel_emissions_multiplier(fuel)
        end

        total = total + pollution
    end

    return total
end

---comment
---@param solution Solution
---@param typed_name TypedName
---@return number
function M.get_quantity_of_machines_required(solution, typed_name)
    local variable_name = string.format("%s/%s/%s", typed_name.type, typed_name.name, typed_name.quality)
    return solution.quantity_of_machines_required[variable_name] or 1
end

---comment
---@param module_typed_names table<string, TypedName>
---@param module_inventory_size integer
---@return table<string, TypedName>
function M.trim_modules(module_typed_names, module_inventory_size)
    local ret = {}
    for index = 1, module_inventory_size do
        ret[tostring(index)] = module_typed_names[tostring(index)]
    end
    return ret
end

---comment
---@param machine LuaEntityPrototype
---@param module_typed_names table<string, TypedName>
---@param affected_by_beacons AffectedByBeacon[]
---@return table<string, table<string, number>>
function M.get_total_modules(machine, module_typed_names, affected_by_beacons)
    local module_counts = {}

    ---@param typed_name TypedName
    ---@param effectivity number
    local function count(typed_name, effectivity)
        local name = typed_name.name
        local quality = typed_name.quality
        if not module_counts[name] then
            module_counts[name] = {}
        end
        local inner = module_counts[name]
        local value = inner[quality] or 0
        inner[quality] = value + effectivity
    end

    module_typed_names = M.trim_modules(module_typed_names, machine.module_inventory_size)
    for _, typed_name in pairs(module_typed_names) do
        count(typed_name, 1)
    end

    for _, affected_by_beacon in ipairs(affected_by_beacons) do
        local beacon_typed_name = affected_by_beacon.beacon_typed_name
        local beacon = beacon_typed_name and tn.get_beacon(beacon_typed_name.name)
        if beacon then
            local effectivity = assert(beacon.distribution_effectivity) * affected_by_beacon.beacon_quantity
            local beacon_module_names = M.trim_modules(affected_by_beacon.module_typed_names,
                beacon.module_inventory_size)

            for _, typed_name in pairs(beacon_module_names) do
                count(typed_name, effectivity)
            end
        end
    end

    return module_counts
end

---comment
---@param module_counts table<string, table<string, number>>
---@return ModuleEffects
function M.get_total_effectivity(module_counts)
    ---@type ModuleEffects
    local ret = {
        speed = 1,
        consumption = 1,
        productivity = 0,
        pollution = 1,
        quality = 0,
    }

    ---@param effect number?
    ---@param count number
    ---@param quality_level integer
    ---@param is_negative boolean
    ---@return number
    local function modify(effect, count, quality_level, is_negative)
        effect = effect or 0
        local multiplier = (1 + quality_level * 0.3)
        if is_negative then
            if effect < 0 then
                effect = effect * multiplier
            end
        else
            if effect > 0 then
                effect = effect * multiplier
            end
        end
        return effect * count
    end

    for name, inner in pairs(module_counts) do
        for quality, count in pairs(inner) do
            local module = tn.get_module(name)
            if not module then
                goto continue
            end

            local effects = assert(module.module_effects)
            local quality_level = acc.get_quality_level(quality)

            ret.speed = ret.speed + modify(effects.speed, count, quality_level, false)
            ret.consumption = ret.consumption + modify(effects.consumption, count, quality_level, true)
            ret.productivity = ret.productivity + modify(effects.productivity, count, quality_level, false)
            ret.pollution = ret.pollution + modify(effects.pollution, count, quality_level, true)
            ret.quality = ret.quality + modify(effects.quality, count, quality_level, false)
            ::continue::
        end
    end

    ret.speed = math.max(ret.speed, 0.2)
    ret.consumption = math.max(ret.consumption, 0.2)
    ret.productivity = math.max(ret.productivity, 0)
    ret.pollution = math.max(ret.pollution, 0.2)
    ret.quality = math.max(ret.quality / 10, 0) -- TODO bug report

    return ret
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
        return tn.equals_typed_name(value, typed_name)
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
        quality = typed_name.quality,
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
---@param fuel_typed_name TypedName?
---@param line_index integer?
function M.new_production_line(player_index, solution, recipe_typed_name, fuel_typed_name, line_index)
    local production_lines = solution.production_lines
    line_index = line_index or #production_lines + 1

    local pos = fs_util.find(production_lines, function(value)
        return tn.equals_typed_name(value.recipe_typed_name, recipe_typed_name)
    end)
    if pos then
        M.move_production_line(solution, pos, line_index)
        return
    end

    local machine_typed_name = M.get_machine_preset(player_index, recipe_typed_name)
    fuel_typed_name = fuel_typed_name or M.get_fuel_preset(player_index, machine_typed_name)

    ---@type ProductionLine
    local line = {
        recipe_typed_name = recipe_typed_name,
        machine_typed_name = machine_typed_name,
        module_typed_names = {},
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
    line.module_typed_names = data.module_typed_names
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
