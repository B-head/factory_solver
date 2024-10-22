local flib_table = require "__flib__/table"

local fs_util = require "fs_util"


local M = {}

M.ticks_per_second = 60
M.seconds_per_minute = 60
M.seconds_per_hour = 60 * 60
M.tolerance = (10 ^ -5)

---comment
---@param product Product | NormalizedAmount
---@param craft_energy number
---@param crafting_speed number
---@param effectivity_speed number
---@param effectivity_productivity number
---@return number
function M.raw_product_to_amount(product, craft_energy, crafting_speed, effectivity_speed, effectivity_productivity)
    if product.amount_per_second then
        local amount = product.amount_per_second * crafting_speed / craft_energy
        return amount * effectivity_speed * effectivity_productivity
    else
        local amount = product.amount
        if not amount then
            amount = (product.amount_min + product.amount_max) / 2
        end
        amount = amount * product.probability * crafting_speed / craft_energy
        return amount * effectivity_speed * effectivity_productivity
    end
end

---comment
---@param ingredient Ingredient | NormalizedAmount
---@param craft_energy number
---@param crafting_speed number
---@param effectivity_speed number
---@return number
function M.raw_ingredient_to_amount(ingredient, craft_energy, crafting_speed, effectivity_speed)
    if ingredient.amount_per_second then
        local amount = ingredient.amount_per_second * crafting_speed / craft_energy
        return amount * effectivity_speed
    else
        local amount = ingredient.amount * crafting_speed / craft_energy
        return amount * effectivity_speed
    end
end

---comment
---@param machine LuaEntityPrototype | VirtualMachine
---@param effectivity_consumption number
---@return number
function M.raw_energy_to_power(machine, effectivity_consumption)
    ---@diagnostic disable-next-line: param-type-mismatch
    if not machine.object_name then
        return machine.energy_source.power_per_second * effectivity_consumption
    end

    -- The energy_usage is not defined in boilers and reactors (TODO probably inaccurate)
    local energy_per_tick = (machine.energy_usage or machine.get_max_energy_usage()) * effectivity_consumption

    if machine.electric_energy_source_prototype then
        energy_per_tick = energy_per_tick + machine.electric_energy_source_prototype.drain
    elseif machine.burner_prototype then
        energy_per_tick = energy_per_tick / machine.burner_prototype.effectivity
    elseif machine.heat_energy_source_prototype then
        -- no operation
    elseif machine.fluid_energy_source_prototype then
        energy_per_tick = energy_per_tick / machine.fluid_energy_source_prototype.effectivity
    elseif machine.void_energy_source_prototype then
        energy_per_tick = 0
    else
        assert(false)
    end

    return energy_per_tick * M.ticks_per_second
end

---comment
---@param machine LuaEntityPrototype | VirtualMachine
---@param pollutant_type string
---@param effectivity_consumption number
---@param effectivity_pollution number
---@return number
function M.raw_emission_to_pollution(machine, pollutant_type, effectivity_consumption, effectivity_pollution)
    ---@diagnostic disable-next-line: param-type-mismatch
    if not machine.object_name then
        return machine.energy_source.pollution_per_second * effectivity_consumption * effectivity_pollution
    end

    -- The energy_usage is not defined in boilers and reactors (TODO probably inaccurate)
    local emission_per_tick = (machine.energy_usage or machine.get_max_energy_usage())
    emission_per_tick = emission_per_tick * effectivity_consumption * effectivity_pollution

    if machine.electric_energy_source_prototype then
        emission_per_tick = emission_per_tick *
            machine.electric_energy_source_prototype.emissions_per_joule[pollutant_type]
    elseif machine.burner_prototype then
        emission_per_tick = emission_per_tick * machine.burner_prototype.emissions_per_joule[pollutant_type]
    elseif machine.heat_energy_source_prototype then
        emission_per_tick = emission_per_tick * machine.heat_energy_source_prototype.emissions_per_joule[pollutant_type]
    elseif machine.fluid_energy_source_prototype then
        emission_per_tick = emission_per_tick * machine.fluid_energy_source_prototype.emissions_per_joule
            [pollutant_type]
    elseif machine.void_energy_source_prototype then
        emission_per_tick = emission_per_tick * machine.void_energy_source_prototype.emissions_per_joule[pollutant_type]
    else
        assert(false)
    end

    return emission_per_tick * M.ticks_per_second
end

---comment
---@param value number
---@param scale TimeScale?
---@return number
function M.to_scale(value, scale)
    if scale == "tick" then
        return value / M.ticks_per_second
    elseif scale == "minute" then
        return value * M.seconds_per_minute
    elseif scale == "hour" then
        return value * M.seconds_per_hour
    else
        return value
    end
end

---comment
---@param value number
---@param scale TimeScale?
---@return number
function M.from_scale(value, scale)
    if scale == "tick" then
        return value * M.ticks_per_second
    elseif scale == "minute" then
        return value / M.seconds_per_minute
    elseif scale == "hour" then
        return value / M.seconds_per_hour
    else
        return value
    end
end

---comment
---@param category_name string
---@return (LuaEntityPrototype | VirtualMachine)[]
function M.get_machines_in_category(category_name)
    local machines

    if storage.virtuals.crafting_categories[category_name] then
        machines = flib_table.filter(storage.virtuals.machine, function(value)
            return value.crafting_categories[category_name]
        end)
    else
        machines = prototypes.get_entity_filtered {
            { filter = "crafting-category", crafting_category = category_name },
        }
    end

    machines = fs_util.sort_prototypes(fs_util.to_list(machines))
    return machines
end

---comment
---@param fuel_categories { [string]: boolean } | string
---@return LuaItemPrototype[]
function M.get_fuels_in_categories(fuel_categories)
    local fuels = {}

    if type(fuel_categories) == "string" then
        fuel_categories = { [fuel_categories] = true }
    end

    for name, _ in pairs(fuel_categories) do
        local f = prototypes.get_item_filtered {
            { filter = "fuel-category", ["fuel-category"] = name },
        }
        fuels = flib_table.array_merge { fuels, fs_util.to_list(f) }
    end

    fuels = fs_util.sort_prototypes(fuels)
    return fuels
end

---Create caches of relation to recipe for items, fluids and virtuals.
---@param force_index integer
---@return RelationToRecipes
function M.create_relation_to_recipes(force_index)
    local force = game.forces[force_index]
    local items = {} ---@type table<string, RelationToRecipe>
    local fluids = {} ---@type table<string, RelationToRecipe>
    local virtuals = {} ---@type table<string, RelationToRecipe>

    for key, _ in pairs(prototypes.item) do
        items[key] = { enabled_recipe_used_count = 0, recipe_for_ingredient = {}, recipe_for_product = {} }
    end

    for key, _ in pairs(prototypes.fluid) do
        fluids[key] = { enabled_recipe_used_count = 0, recipe_for_ingredient = {}, recipe_for_product = {} }
    end

    for key, _ in pairs(storage.virtuals.object) do
        virtuals[key] = { enabled_recipe_used_count = 0, recipe_for_ingredient = {}, recipe_for_product = {} }
    end

    for _, recipe in pairs(force.recipes) do
        for _, value in ipairs(recipe.products) do
            local info
            if value.type == "item" then
                info = items[value.name]
            elseif value.type == "fluid" then
                info = fluids[value.name]
            else
                assert(false)
            end

            flib_table.insert(info.recipe_for_product, recipe.name)
            if recipe.enabled then
                info.enabled_recipe_used_count = info.enabled_recipe_used_count + 1
            end
        end

        for _, value in ipairs(recipe.ingredients) do
            local info
            if value.type == "item" then
                info = items[value.name]
            elseif value.type == "fluid" then
                info = fluids[value.name]
            else
                assert(false)
            end

            flib_table.insert(info.recipe_for_ingredient, recipe.name)
            if recipe.enabled then
                info.enabled_recipe_used_count = info.enabled_recipe_used_count + 1
            end
        end
    end

    for _, recipe in pairs(storage.virtuals.recipe) do
        for _, value in pairs(recipe.products) do
            local info
            if value.type == "item" then
                info = items[value.name]
            elseif value.type == "fluid" then
                info = fluids[value.name]
            elseif value.type == "virtual-object" then
                info = virtuals[value.name]
            else
                assert(false)
            end

            flib_table.insert(info.recipe_for_product, recipe.name)
            -- if recipe.enabled then -- TODO
            --     info.enabled_recipe_used_count = info.enabled_recipe_used_count + 1
            -- end
        end

        for _, value in pairs(recipe.ingredients) do
            local info
            if value.type == "item" then
                info = items[value.name]
            elseif value.type == "fluid" then
                info = fluids[value.name]
            elseif value.type == "virtual-object" then
                info = virtuals[value.name]
            else
                assert(false)
            end

            flib_table.insert(info.recipe_for_ingredient, recipe.name)
            -- if recipe.enabled then -- TODO
            --     info.enabled_recipe_used_count = info.enabled_recipe_used_count + 1
            -- end
        end
    end

    for _, machine in pairs(storage.virtuals.machine) do
        local value = machine.energy_source.fixed_fuel_typed_name
        if value then
            local info
            if value.type == "item" then
                info = items[value.name]
            elseif value.type == "fluid" then
                info = fluids[value.name]
            elseif value.type == "virtual-object" then
                info = virtuals[value.name]
            else
                assert(false)
            end

            local categories = machine.crafting_categories
            for _, recipe in pairs(storage.virtuals.recipe) do
                if categories[recipe.category] then
                    flib_table.insert(info.recipe_for_ingredient, recipe.name)
                end
            end
        end
    end

    return { item = items, fluid = fluids, virtual = virtuals }
end

---Create caches of additional information for groups.
---@param force_index integer
---@param relation_to_recipes RelationToRecipes
---@return GroupInfos
function M.create_group_infos(force_index, relation_to_recipes)
    local force = game.forces[force_index]
    local items = {} ---@type table<string, GroupInfo>
    local fluids = {} ---@type table<string, GroupInfo>
    local recipes = {} ---@type table<string, GroupInfo>
    local virtuals = {} ---@type table<string, GroupInfo>

    for key, _ in pairs(prototypes.item_group) do
        items[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
        fluids[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
        recipes[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
        virtuals[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
    end

    for _, recipe in pairs(force.recipes) do
        if not prototypes.recipe[recipe.name].parameter then
            local recipe_group = recipes[recipe.group.name]
            if recipe.hidden then
                recipe_group.hidden_count = recipe_group.hidden_count + 1
            elseif recipe.enabled then
                recipe_group.researched_count = recipe_group.researched_count + 1
            else
                recipe_group.unresearched_count = recipe_group.unresearched_count + 1
            end
        end
    end

    for key, item in pairs(prototypes.item) do
        if not item.parameter then
            local item_group = items[item.group.name]
            if item.hidden then
                item_group.hidden_count = item_group.hidden_count + 1
            elseif 0 < relation_to_recipes.item[key].enabled_recipe_used_count then
                item_group.researched_count = item_group.researched_count + 1
            else
                item_group.unresearched_count = item_group.unresearched_count + 1
            end
        end
    end

    for key, fluid in pairs(prototypes.fluid) do
        if not fluid.parameter then
            local fluid_group = fluids[fluid.group.name]
            if fluid.hidden then
                fluid_group.hidden_count = fluid_group.hidden_count + 1
            elseif 0 < relation_to_recipes.fluid[key].enabled_recipe_used_count then
                fluid_group.researched_count = fluid_group.researched_count + 1
            else
                fluid_group.unresearched_count = fluid_group.unresearched_count + 1
            end
        end
    end

    for _, virtual_object in pairs(storage.virtuals.object) do
        local virtual_group = virtuals[virtual_object.group_name]
        virtual_group.researched_count = virtual_group.researched_count + 1
        -- TODO hidden and unreserched
    end

    for _, virtual_recipe in pairs(storage.virtuals.recipe) do
        local virtual_group = virtuals[virtual_recipe.group_name]
        virtual_group.researched_count = virtual_group.researched_count + 1
        -- TODO hidden and unreserched
    end

    return { item = items, fluid = fluids, recipe = recipes, virtual = virtuals }
end

---comment
---@param craft Craft
---@return boolean
function M.is_hidden(craft)
    ---@diagnostic disable: param-type-mismatch
    if craft.object_name == "LuaItemPrototype" then
        return craft.hidden
    elseif craft.object_name == "LuaFluidPrototype" then
        return craft.hidden
    elseif craft.object_name == "LuaRecipe" then
        return craft.hidden
    elseif craft.object_name == "LuaEntityPrototype" then
        return craft.hidden
    elseif craft.type == "virtual-object" then
        return false --TODO
    elseif craft.type == "virtual-recipe" then
        return false --TODO
    elseif craft.type == "virtual-machine" then
        return false --TODO
    else
        return assert(false)
    end
    ---@diagnostic enable: param-type-mismatch
end

---comment
---@param craft Craft
---@param relation_to_recipes RelationToRecipes
---@return boolean
function M.is_unresearched(craft, relation_to_recipes)
    ---@diagnostic disable: param-type-mismatch
    if craft.object_name == "LuaItemPrototype" then
        local is_researched = 0 < relation_to_recipes.item[craft.name].enabled_recipe_used_count
        return not is_researched
    elseif craft.object_name == "LuaFluidPrototype" then
        local is_researched = 0 < relation_to_recipes.fluid[craft.name].enabled_recipe_used_count
        return not is_researched
    elseif craft.object_name == "LuaRecipe" then
        return not craft.enabled
    elseif craft.object_name == "LuaEntityPrototype" then
        local ret = true
        for _, value in ipairs(craft.items_to_place_this) do
            local item = prototypes.item[value.name]
            local is_researched = 0 < relation_to_recipes.item[item.name].enabled_recipe_used_count
            ret = ret and not is_researched
        end
        return ret
    elseif craft.type == "virtual-object" then
        return false --TODO
    elseif craft.type == "virtual-recipe" then
        return false --TODO
    elseif craft.type == "virtual-machine" then
        return false --TODO
    else
        return assert(false)
    end
    ---@diagnostic enable: param-type-mismatch
end

---comment
---@param elem_type ElemType
---@param name string
---@param quality string?
---@return ElemID
function M.create_elem_id(elem_type, name, quality)
    return { type = elem_type, name = name, quality = quality }
end

---@type table<FilterType, ElemType>
local type_dictionary = {
    ["item"] = "item",
    ["fluid"] = "fluid",
    ["recipe"] = "recipe",
    ["machine"] = "entity",
}

---comment
---@param typed_name TypedName
---@param quality string?
---@return ElemID?
function M.typed_name_to_elem_id(typed_name, quality)
    local elem_type = type_dictionary[typed_name.type]
    if elem_type then
        return { type = elem_type, name = typed_name.name, quality = quality }
    else
        return nil
    end
end

---comment
---@param filter_type FilterType
---@param name string
---@return TypedName
function M.create_typed_name(filter_type, name)
    return { type = filter_type, name = name }
end

---comment
---@param value1 TypedName
---@param value2 TypedName
---@return boolean
function M.equals_typed_name(value1, value2)
    return value1.type == value2.type and value1.name == value2.name
end

---comment
---@param typed_name TypedName
---@param force LuaForce?
---@return Craft
function M.typed_name_to_craft(typed_name, force)
    local type = typed_name.type
    local name = typed_name.name
    if type == "item" then
        return prototypes.item[name]
    elseif type == "fluid" then
        return prototypes.fluid[name]
    elseif type == "recipe" then
        if force then
            return force.recipes[name]
        else
            return prototypes.recipe[name]
        end
    elseif type == "machine" then
        return prototypes.entity[name]
    elseif type == "virtual-object" then
        return storage.virtuals.object[name]
    elseif type == "virtual-recipe" then
        return storage.virtuals.recipe[name]
    elseif type == "virtual-machine" then
        return storage.virtuals.machine[name]
    else
        return assert(nil)
    end
end

---comment
---@param craft Craft
---@return TypedName
function M.craft_to_typed_name(craft)
    ---@diagnostic disable: param-type-mismatch
    if craft.object_name == "LuaItemPrototype" then
        return M.create_typed_name("item", craft.name)
    elseif craft.object_name == "LuaFluidPrototype" then
        return M.create_typed_name("fluid", craft.name)
    elseif craft.object_name == "LuaRecipe" then
        return M.create_typed_name("recipe", craft.name)
    elseif craft.object_name == "LuaRecipePrototype" then
        return M.create_typed_name("recipe", craft.name)
    elseif craft.object_name == "LuaEntityPrototype" then
        return M.create_typed_name("machine", craft.name)
    else
        return M.create_typed_name(craft.type, craft.name)
    end
    ---@diagnostic enable: param-type-mismatch
end

---comment
---@param typed_name TypedName
---@return string
function M.get_sprite_path(typed_name)
    if typed_name.type == "virtual-object" then
        object = storage.virtuals.object[typed_name.name]
        return object.sprite_path
    elseif typed_name.type == "virtual-recipe" then
        local recipe = storage.virtuals.recipe[typed_name.name]
        return recipe.sprite_path
    elseif typed_name.type == "virtual-machine" then
        local machine = storage.virtuals.machine[typed_name.name]
        return machine.sprite_path
    elseif typed_name.type == "machine" then
        return "entity" .. "/" .. typed_name.name
    else
        return typed_name.type .. "/" .. typed_name.name
    end
end

---comment
---@param object LuaItemPrototype | LuaFluidPrototype | VirtualObject
---@param machine LuaEntityPrototype | VirtualMachine
---@return number
function M.get_fuel_value(object, machine)
    ---@diagnostic disable: param-type-mismatch
    if not machine.object_name and machine.energy_source.alternative_fuel_value then
        return machine.energy_source.alternative_fuel_value
    end

    ---@diagnostic disable: param-type-mismatch
    if object.object_name == "LuaItemPrototype" then
        return object.fuel_value
    elseif object.object_name == "LuaFluidPrototype" then
        return object.fuel_value
    else
        return 1
    end
    ---@diagnostic enable: param-type-mismatch
end

---comment
---@param object LuaItemPrototype | LuaFluidPrototype | VirtualObject
---@return number
function M.get_fuel_emissions_multiplier(object)
    ---@diagnostic disable: param-type-mismatch
    if object.object_name == "LuaItemPrototype" then
        return object.fuel_emissions_multiplier
    elseif object.object_name == "LuaFluidPrototype" then
        return object.emissions_multiplier
    else
        return 1
    end
    ---@diagnostic enable: param-type-mismatch
end

---comment
---@param machine LuaEntityPrototype | VirtualMachine
---@return EnergyType
function M.get_energy_source_type(machine)
    ---@diagnostic disable-next-line: param-type-mismatch
    if machine.object_name then
        if machine.electric_energy_source_prototype then
            return "electric"
        elseif machine.burner_prototype then
            return "burner"
        elseif machine.heat_energy_source_prototype then
            return "heat"
        elseif machine.fluid_energy_source_prototype then
            return "fluid"
        elseif machine.void_energy_source_prototype then
            return "void"
        else
            return assert(nil)
        end
    else
        return machine.energy_source.type
    end
end

---comment
---@param machine LuaEntityPrototype | VirtualMachine
---@return { [string]: boolean }?
function M.try_get_fuel_categories(machine)
    ---@diagnostic disable-next-line: param-type-mismatch
    if machine.object_name then
        if machine.burner_prototype then
            return machine.burner_prototype.fuel_categories
        else
            return nil
        end
    else
        return machine.energy_source.fuel_categories
    end
end

---comment
---@param machine LuaEntityPrototype | VirtualMachine
---@return TypedName?
function M.try_get_fixed_fuel(machine)
    ---@diagnostic disable-next-line: param-type-mismatch
    if machine.object_name then
        if machine.heat_energy_source_prototype then
            return M.create_typed_name("virtual-object", "<heat>")
        elseif machine.fluid_energy_source_prototype then
            local fluid_name = machine.fluid_energy_source_prototype.fluid_box.filter.name
            return M.create_typed_name("fluid", fluid_name)
        else
            return nil
        end
    else
        return machine.energy_source.fixed_fuel_typed_name
    end
end

---comment
---@param machine LuaEntityPrototype | VirtualMachine
---@return boolean
function M.is_generator(machine)
    ---@diagnostic disable-next-line: param-type-mismatch
    return not machine.object_name and machine.energy_source.is_generator
end

---comment
---@param machine LuaEntityPrototype | VirtualMachine
---@return number
function M.get_crafting_speed(machine)
    ---@diagnostic disable-next-line: param-type-mismatch
    if machine.object_name then
        return machine.get_crafting_speed()
    else
        return machine.crafting_speed
    end
end

---comment
---@param module_names table<string, string>
---@param affected_by_beacons AffectedByBeacon[]
---@return table<string, number>
function M.get_total_modules(module_names, affected_by_beacons)
    local module_counts = {}

    for _, name in pairs(module_names) do
        module_counts[name] = (module_counts[name] or 0) + 1
    end

    for _, affected_by_beacon in ipairs(affected_by_beacons) do
        if affected_by_beacon.beacon_name then
            local beacon = prototypes.entity[affected_by_beacon.beacon_name]
            local effectivity = assert(beacon.distribution_effectivity) * affected_by_beacon.beacon_quantity
            local module_names = affected_by_beacon.module_names

            for _, name in pairs(module_names) do
                module_counts[name] = (module_counts[name] or 0) + effectivity
            end
        end
    end

    return module_counts
end

---comment
---@param module_counts table<string, number>
---@return ModuleEffects
function M.get_total_effectivity(module_counts)
    ---@type ModuleEffects
    local ret = {
        speed = 1,
        consumption = 1,
        productivity = 1,
        pollution = 1,
        quality = 1,
    }

    for name, count in pairs(module_counts) do
        local module = prototypes.item[name]
        local effects = assert(module.module_effects)

        ret.speed = ret.speed + (effects.speed or 0) * count
        ret.consumption = ret.consumption + (effects.consumption or 0) * count
        ret.productivity = ret.productivity + (effects.productivity or 0) * count
        ret.pollution = ret.pollution + (effects.pollution or 0) * count
        ret.quality = ret.quality + (effects.quality or 0) * count
    end

    ret.speed = math.max(ret.speed, 0.2)
    ret.consumption = math.max(ret.consumption, 0.2)
    ret.productivity = math.max(ret.productivity, 1)
    ret.pollution = math.max(ret.pollution, 0.2)
    ret.quality = math.max(ret.quality, 1)

    return ret
end

return M
