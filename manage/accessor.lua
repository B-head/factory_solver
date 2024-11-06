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
---@param machine LuaEntityPrototype
---@param quality QualityID
---@param effectivity_consumption number
---@return number
function M.raw_energy_usage_to_power(machine, quality, effectivity_consumption)
    local energy_per_tick = machine.get_max_energy_usage(quality) * effectivity_consumption

    if machine.burner_prototype then
        energy_per_tick = energy_per_tick / machine.burner_prototype.effectivity
    elseif machine.heat_energy_source_prototype then
        -- no operation
    elseif machine.fluid_energy_source_prototype then
        energy_per_tick = energy_per_tick / machine.fluid_energy_source_prototype.effectivity
    elseif machine.void_energy_source_prototype then
        energy_per_tick = 0
    elseif machine.electric_energy_source_prototype then
        -- Last to not be applied to generators.
        energy_per_tick = energy_per_tick + machine.electric_energy_source_prototype.drain
    else
        assert()
    end

    return energy_per_tick * M.second_per_tick
end

---comment
---@param machine LuaEntityPrototype
---@param pollutant_type string
---@param quality QualityID
---@param effectivity_consumption number
---@param effectivity_pollution number
---@return number
function M.raw_emission_to_pollution(machine, pollutant_type, quality, effectivity_consumption, effectivity_pollution)
    local energy_per_tick = machine.get_max_energy_usage(quality) * effectivity_consumption * effectivity_pollution
    local emissions_per_joule

    if machine.burner_prototype then
        emissions_per_joule = machine.burner_prototype.emissions_per_joule
    elseif machine.heat_energy_source_prototype then
        emissions_per_joule = machine.heat_energy_source_prototype.emissions_per_joule
    elseif machine.fluid_energy_source_prototype then
        emissions_per_joule = machine.fluid_energy_source_prototype.emissions_per_joule
    elseif machine.void_energy_source_prototype then
        emissions_per_joule = machine.void_energy_source_prototype.emissions_per_joule
    elseif machine.electric_energy_source_prototype then
        -- Last to not be applied to generators.
        emissions_per_joule = machine.electric_energy_source_prototype.emissions_per_joule
    else
        assert()
    end

    return emissions_per_joule[pollutant_type] * energy_per_tick * M.second_per_tick
end

---comment
---@param machine LuaEntityPrototype
---@param quality QualityID
---@return number
function M.raw_energy_production_to_power(machine, quality)
    return -machine.get_max_energy_production(quality) * M.second_per_tick
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
---@return LuaEntityPrototype[]
function M.get_machines_in_category(category_name)
    local machines = prototypes.get_entity_filtered {
        { filter = "crafting-category", crafting_category = category_name },
    }
    machines = fs_util.sort_prototypes(fs_util.to_list(machines))
    return machines
end

---comment
---@param category_name string
---@return LuaEntityPrototype[]
function M.get_machines_in_resource_category(category_name)
    local machines = prototypes.get_entity_filtered {
        { filter = "type", type = "mining-drill" },
    }
    machines = flib_table.filter(machines, function(value)
        return value.resource_categories[category_name]
    end)
    machines = fs_util.sort_prototypes(fs_util.to_list(machines))
    return machines
end

---comment
---@param recipe LuaRecipePrototype | VirtualRecipe
---@return LuaEntityPrototype[]
function M.get_machines_for_recipe(recipe)
    ---@diagnostic disable-next-line: param-type-mismatch
    if recipe.object_name then
        return M.get_machines_in_category(recipe.category)
    elseif recipe.fixed_crafting_machine then
        return { tn.typed_name_to_machine(recipe.fixed_crafting_machine) }
    elseif recipe.resource_category then
        return M.get_machines_in_resource_category(recipe.resource_category)
    else
        return assert()
    end
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
    else
        return assert()
    end
    ---@diagnostic enable: param-type-mismatch
end

---comment
---@param machine LuaEntityPrototype
---@param machine_quality QualityID
---@param fuel LuaItemPrototype | LuaFluidPrototype | VirtualMaterial
---@param fuel_quality QualityID
---@param effectivity_consumption number
---@return number
function M.get_fuel_amount_per_second(machine, machine_quality, fuel, fuel_quality, effectivity_consumption)
    if machine.type == "generator" then
        local multiplier = 1 + M.get_quality_level(machine_quality) * 0.3
        return machine.fluid_usage_per_tick * M.second_per_tick * multiplier
    else
        ---@diagnostic disable: param-type-mismatch
        local fuel_value = 1
        if fuel.object_name == "LuaItemPrototype" then
            fuel_value = fuel.fuel_value
        elseif fuel.object_name == "LuaFluidPrototype" then
            fuel_value = fuel.fuel_value
        end
        ---@diagnostic enable: param-type-mismatch

        local power = M.raw_energy_usage_to_power(machine, machine_quality, effectivity_consumption)
        return (fuel_value == 0) and 0 or power / fuel_value
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
---@param machine LuaEntityPrototype
---@return EnergyType
function M.get_energy_source_type(machine)
    if machine.burner_prototype then
        return "burner"
    elseif machine.heat_energy_source_prototype then
        return "heat"
    elseif machine.fluid_energy_source_prototype then
        return "fluid"
    elseif machine.void_energy_source_prototype then
        return "void"
    elseif machine.electric_energy_source_prototype then
        -- Last to not be applied to generators.
        if machine.type == "generator" then
            return "fluid"
        else
            return "electric"
        end
    else
        return assert()
    end
end

---comment
---@param machine LuaEntityPrototype
---@return { [string]: boolean }?
function M.try_get_fuel_categories(machine)
    if machine.burner_prototype then
        return machine.burner_prototype.fuel_categories
    else
        return nil
    end
end

---comment
---@param machine LuaEntityPrototype
---@return TypedName?
function M.try_get_fixed_fuel(machine)
    if machine.heat_energy_source_prototype then
        return tn.create_typed_name("virtual_material", "<heat>")
    elseif machine.fluid_energy_source_prototype then
        local fluid_name = machine.fluid_energy_source_prototype.fluid_box.filter.name
        return tn.create_typed_name("fluid", fluid_name)
    elseif machine.type == "generator" then
        local fluid_name = machine.fluidbox_prototypes[1].filter.name
        return tn.create_typed_name("fluid", fluid_name)
    else
        return nil
    end
end

---comment
---@param machine LuaEntityPrototype
---@return boolean
function M.is_use_fuel(machine)
    local energy_source_type = M.get_energy_source_type(machine)
    return energy_source_type == "burner" or energy_source_type == "heat" or energy_source_type == "fluid"
end

---comment
---@param machine LuaEntityPrototype
---@return boolean
function M.is_generator(machine)
    return machine.type == "generator" or machine.type == "burner-generator"
end

---comment
---@param machine LuaEntityPrototype
---@param quality QualityID
---@return number
function M.get_crafting_speed(machine, quality)
    local ret = machine.get_crafting_speed(quality) or machine.mining_speed
    if not ret then
        ret = 1 + M.get_quality_level(quality) * 0.3
    end
    return ret
end

---comment
---@param quality QualityID
function M.get_quality_level(quality)
    local quality_prototype = (type(quality) == "string") and prototypes.quality[quality] or quality
    return quality_prototype and quality_prototype.level or 0
end

return M