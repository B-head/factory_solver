local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local tn = require "manage/typed_name"

local M = {}

---@type table<TimeScale, number>
M.scale_per_second = {
    second = 1,
    five_seconds = 5,
    minute = 60,
    ten_minutes = 10 * 60,
    hour = 60 * 60,
    ten_hours = 10 * 60 * 60,
    fifty_hours = 50 * 60 * 60,
    two_hundred_fifty_hours = 250 * 60 * 60,
    thousand_hours = 1000 * 60 * 60,
}

M.second_per_tick = 60
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
        return product.amount_per_second * crafting_speed *
            effectivity_speed * effectivity_productivity / craft_energy
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
        return ingredient.amount_per_second * crafting_speed * effectivity_speed / craft_energy -- TODO quality
    else
        return ingredient.amount * crafting_speed * effectivity_speed / craft_energy
    end
end

---comment
---@param machine LuaEntityPrototype | VirtualMachine
---@param quality QualityID
---@param effectivity_consumption number
---@return number
function M.raw_energy_to_power(machine, quality, effectivity_consumption)
    ---@diagnostic disable-next-line: param-type-mismatch
    if not machine.object_name then
        return machine.energy_source.power_per_second * effectivity_consumption -- TODO quality
    end

    local energy_per_tick = machine.get_max_energy_usage(quality) * effectivity_consumption

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
        assert()
    end

    return energy_per_tick * M.second_per_tick
end

---comment
---@param machine LuaEntityPrototype | VirtualMachine
---@param pollutant_type string
---@param quality QualityID
---@param effectivity_consumption number
---@param effectivity_pollution number
---@return number
function M.raw_emission_to_pollution(machine, pollutant_type, quality, effectivity_consumption, effectivity_pollution)
    ---@diagnostic disable-next-line: param-type-mismatch
    if not machine.object_name then
        return machine.energy_source.pollution_per_second * effectivity_consumption *
            effectivity_pollution -- TODO quality
    end

    local emission_per_tick = machine.get_max_energy_usage(quality)
        * effectivity_consumption * effectivity_pollution

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
        assert()
    end

    return emission_per_tick * M.second_per_tick
end

---comment
---@param value number
---@param scale TimeScale
---@return number
function M.to_scale(value, scale)
    return value * M.scale_per_second[scale]
end

---comment
---@param value number
---@param scale TimeScale
---@return number
function M.from_scale(value, scale)
    return value / M.scale_per_second[scale]
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

---comment
---@param craft Craft
---@return boolean
function M.is_hidden(craft)
    ---@diagnostic disable: param-type-mismatch
    if craft.object_name == "LuaItemPrototype" then
        return craft.hidden
    elseif craft.object_name == "LuaFluidPrototype" then
        return craft.hidden
    elseif craft.object_name == "LuaRecipePrototype" then
        return craft.hidden
    elseif craft.object_name == "LuaEntityPrototype" then
        return craft.hidden
    elseif craft.type == "virtual_material" then
        return false --TODO
    elseif craft.type == "virtual_recipe" then
        return false --TODO
    elseif craft.type == "virtual_machine" then
        return false --TODO
    else
        return assert()
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
        return not (0 < relation_to_recipes.item[craft.name].enabled_recipe_used_count)
    elseif craft.object_name == "LuaFluidPrototype" then
        return not (0 < relation_to_recipes.fluid[craft.name].enabled_recipe_used_count)
    elseif craft.object_name == "LuaRecipePrototype" then
        return not relation_to_recipes.enabled_recipe[craft.name]
    elseif craft.object_name == "LuaEntityPrototype" then
        local ret = true
        for _, value in ipairs(craft.items_to_place_this) do
            local item = prototypes.item[value.name]
            local is_researched = 0 < relation_to_recipes.item[item.name].enabled_recipe_used_count
            ret = ret and not is_researched
        end
        return ret
    elseif craft.type == "virtual_material" then
        return false --TODO
    elseif craft.type == "virtual_recipe" then
        return false --TODO
    elseif craft.type == "virtual_machine" then
        return false --TODO
    else
        return assert()
    end
    ---@diagnostic enable: param-type-mismatch
end

---comment
---@param power number
---@param material LuaItemPrototype | LuaFluidPrototype | VirtualMaterial
---@param machine LuaEntityPrototype | VirtualMachine
---@return number
function M.get_fuel_amount_per_second(power, material, machine)
    ---@diagnostic disable: param-type-mismatch
    if not machine.object_name and machine.energy_source.alternative_fuel_value then
        return machine.energy_source.alternative_fuel_value
    end

    local fuel_value = 1
    ---@diagnostic disable: param-type-mismatch
    if material.object_name == "LuaItemPrototype" then
        fuel_value = material.fuel_value
    elseif material.object_name == "LuaFluidPrototype" then
        fuel_value = material.fuel_value
    end
    ---@diagnostic enable: param-type-mismatch

    if fuel_value == 0 then
        return 0
    else
        return power / fuel_value
    end
end

---comment
---@param material LuaItemPrototype | LuaFluidPrototype | VirtualMaterial
---@return number
function M.get_fuel_emissions_multiplier(material)
    ---@diagnostic disable: param-type-mismatch
    if material.object_name == "LuaItemPrototype" then
        return material.fuel_emissions_multiplier
    elseif material.object_name == "LuaFluidPrototype" then
        return material.emissions_multiplier
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
            return assert()
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
            return tn.create_typed_name("virtual_material", "<heat>")
        elseif machine.fluid_energy_source_prototype then
            local fluid_name = machine.fluid_energy_source_prototype.fluid_box.filter.name
            return tn.create_typed_name("fluid", fluid_name)
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
function M.is_use_fuel(machine)
    local energy_source_type = M.get_energy_source_type(machine)
    return energy_source_type == "burner" or energy_source_type == "heat" or energy_source_type == "fluid"
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
---@param quality QualityID
---@return number
function M.get_crafting_speed(machine, quality)
    ---@diagnostic disable-next-line: param-type-mismatch
    if machine.object_name then
        return machine.get_crafting_speed(quality)
    else
        return machine.crafting_speed -- TODO quality
    end
end

return M
