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
M.tolerance = (10 ^ -6) / 2

---comment
---@param product ProductEx
---@param quality string
---@param craft_energy number
---@param crafting_speed number
---@param effectivity_productivity number
---@return NormalizedAmount
function M.raw_product_to_amount(product, quality, craft_energy, crafting_speed, effectivity_productivity)
    local amount_min = assert(product.amount_min or product.amount)
    local amount_max = assert(product.amount_max or product.amount)

    local ignored_by_productivity = (product.ignored_by_productivity or 0)
    local target_by_productivity =
        math.max(amount_min - ignored_by_productivity, 0) +
        math.max(amount_max - ignored_by_productivity, 0)

    local normal_amount = (amount_min + amount_max + target_by_productivity * effectivity_productivity) / 2
    local extra_amount = (product.extra_count_fraction or 0) * (1 + effectivity_productivity)
    local amount = (normal_amount * product.probability + extra_amount) * crafting_speed / craft_energy

    ---@type NormalizedAmount
    return {
        type = product.type,
        name = product.name,
        quality = quality,
        amount_per_second = amount,
        temperature = product.temperature,
    }
end

---comment
---@param ingredient IngredientEx
---@param quality string
---@param craft_energy number
---@param crafting_speed number
---@return NormalizedAmount
function M.raw_ingredient_to_amount(ingredient, quality, craft_energy, crafting_speed)
    local amount = ingredient.amount * crafting_speed / craft_energy

    local min_temp = ingredient.minimum_temperature
    local max_temp = ingredient.maximum_temperature
    if ingredient.type == "fluid" then
        -- Factorio's runtime API returns the FLT-sentinel values
        -- (e.g. -3.4e38) for ingredient temperature bounds that the
        -- prototype left unset. Clamp to the fluid's physical range so
        -- the value flows through the rest of the mod (LP variable
        -- names, picker labels, tooltips) without leaking the sentinel.
        -- A nil bound is distinct from a sentinel: it marks a bare
        -- ingredient that pre_solve.resolve_bare_fluids will widen to
        -- [default, max] for LP purposes, while UI consumers want to
        -- treat it as "no temperature constraint" and skip the range
        -- label entirely. Only touch non-nil values here.
        local proto = prototypes.fluid[ingredient.name]
        if proto then
            if min_temp ~= nil and min_temp < proto.default_temperature then
                min_temp = proto.default_temperature
            end
            if max_temp ~= nil and max_temp > proto.max_temperature then
                max_temp = proto.max_temperature
            end
        end
    end

    ---@type NormalizedAmount
    return {
        type = ingredient.type,
        name = ingredient.name,
        quality = quality,
        amount_per_second = amount,
        minimum_temperature = min_temp,
        maximum_temperature = max_temp,
    }
end

---Widen a fluid amount in product position: a fully bare fluid resolves to
---its default_temperature (single). Anything already tagged passes through.
---Returns the (temperature, minimum_temperature, maximum_temperature) tuple
---so callers can mutate a NormalizedAmount in place or build a fresh
---TypedName from it.
---@param fluid_name string
---@param temperature number?
---@param minimum_temperature number?
---@param maximum_temperature number?
---@return number? temperature
---@return number? minimum_temperature
---@return number? maximum_temperature
function M.resolve_bare_fluid_product(fluid_name, temperature, minimum_temperature, maximum_temperature)
    if temperature == nil
        and minimum_temperature == nil
        and maximum_temperature == nil
    then
        local proto = prototypes.fluid[fluid_name]
        if proto then
            return proto.default_temperature, nil, nil
        end
    end
    return temperature, minimum_temperature, maximum_temperature
end

---Widen a fluid amount in ingredient position: any single-temperature tag
---passes through; otherwise the bounds are filled to [default_temperature,
---max_temperature] and clamped to the fluid's physical range. The clamp
---also tames the FLT-sentinel values Factorio returns for unset bounds
---(e.g. -3.4e38 for an unset minimum_temperature).
---@param fluid_name string
---@param temperature number?
---@param minimum_temperature number?
---@param maximum_temperature number?
---@return number? temperature
---@return number? minimum_temperature
---@return number? maximum_temperature
function M.resolve_bare_fluid_ingredient(fluid_name, temperature, minimum_temperature, maximum_temperature)
    if temperature ~= nil then
        return temperature, minimum_temperature, maximum_temperature
    end
    local proto = prototypes.fluid[fluid_name]
    if not proto then
        return temperature, minimum_temperature, maximum_temperature
    end
    local min = minimum_temperature or proto.default_temperature
    local max = maximum_temperature or proto.max_temperature
    if min < proto.default_temperature then min = proto.default_temperature end
    if max > proto.max_temperature then max = proto.max_temperature end
    return temperature, min, max
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
        -- entity-ghost fallback (see typed_name_to_machine): no energy source.
        return 0
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
        -- entity-ghost fallback (see typed_name_to_machine): no energy source.
        return 0
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

---Returns the actual electrical power produced by a generator at its rated
---throughput, bounded by both max_power_output and the supplied fuel's
---energy density (fluid_usage_per_tick * fuel_energy * effectivity). Sign
---convention matches raw_energy_production_to_power: negative = output. For
---non-generator entities or when fuel info is missing, returns the uncapped
---max so the caller doesn't have to branch.
---@param machine LuaEntityPrototype
---@param machine_quality QualityID
---@param fuel LuaItemPrototype | LuaFluidPrototype | VirtualMaterial?
---@param fuel_typed_name TypedName?
---@return number
function M.get_generator_power(machine, machine_quality, fuel, fuel_typed_name)
    local max_power = -machine.get_max_energy_production(machine_quality) * M.second_per_tick

    if machine.type ~= "generator" then
        return max_power
    end

    local energy_per_unit = 0
    ---@diagnostic disable: param-type-mismatch
    if fuel and fuel.object_name == "LuaFluidPrototype" then
        if machine.burns_fluid then
            energy_per_unit = fuel.fuel_value
        else
            local input_t = fuel.max_temperature
            if fuel_typed_name then
                input_t = fuel_typed_name.temperature
                    or fuel_typed_name.maximum_temperature
                    or input_t
            end
            local cap = machine.maximum_temperature
            if cap and cap > 0 and input_t > cap then
                input_t = cap
            end
            local delta = input_t - fuel.default_temperature
            if delta > 0 then
                energy_per_unit = delta * fuel.heat_capacity
            end
        end
    end
    ---@diagnostic enable: param-type-mismatch

    if energy_per_unit == 0 then
        return max_power
    end

    local quality_multiplier = 1 + M.get_quality_level(machine_quality) * 0.3
    local consumption = machine.fluid_usage_per_tick * M.second_per_tick * quality_multiplier
    local effectivity_value = machine.effectivity or 1
    local fuel_power = -consumption * energy_per_unit * effectivity_value

    -- Both values are negative (output). The bottleneck has the smaller
    -- magnitude, i.e. the value closer to zero.
    if fuel_power > max_power then
        return fuel_power
    end
    return max_power
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
---@param categories { [string]: true }
---@return string
function M.join_categories(categories)
    local name_list = {}
    for name, _ in pairs(categories) do
        flib_table.insert(name_list, name)
    end
    
    flib_table.sort(name_list)
    return flib_table.concat(name_list, "|")
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
---@param fuel_categories { [string]: true } | string
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
---@return LuaFluidPrototype[]
function M.get_any_fluid_fuels()
    local fluid_fuels = prototypes.get_fluid_filtered {
        { filter = "fuel-value", comparison = ">", value = 0 }
    }
    fluid_fuels = fs_util.sort_prototypes(fs_util.to_list(fluid_fuels))
    return fluid_fuels
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
        return not (0 < relation_to_recipes.item[craft.name].craftable_count)
    elseif craft.object_name == "LuaFluidPrototype" then
        return not (0 < relation_to_recipes.fluid[craft.name].craftable_count)
    elseif craft.object_name == "LuaRecipePrototype" then
        return not relation_to_recipes.enabled_recipe[craft.name]
    elseif craft.object_name == "LuaEntityPrototype" then
        local ret = true
        for _, value in ipairs(craft.items_to_place_this or {}) do
            local item = prototypes.item[value.name]
            local is_researched = 0 < relation_to_recipes.item[item.name].craftable_count
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
---@param fuel_typed_name TypedName?
---@return number
function M.get_fuel_amount_per_second(machine, machine_quality, fuel, fuel_quality, effectivity_consumption, fuel_typed_name)
    if machine.type == "generator" then
        local multiplier = 1 + M.get_quality_level(machine_quality) * 0.3
        return machine.fluid_usage_per_tick * M.second_per_tick * multiplier
    end

    local energy = machine.fluid_energy_source_prototype
    if energy then
        if not energy.scale_fluid_usage then
            -- scale=false: consumption is pinned to fluid_usage_per_tick regardless
            -- of energy demand; the engine discards any excess.
            return energy.fluid_usage_per_tick * M.second_per_tick
        end

        local power = M.raw_energy_usage_to_power(machine, machine_quality, effectivity_consumption)
        local energy_per_unit = 0
        ---@diagnostic disable: param-type-mismatch
        if energy.burns_fluid then
            if fuel.object_name == "LuaFluidPrototype" then
                energy_per_unit = fuel.fuel_value
            end
        elseif fuel.object_name == "LuaFluidPrototype" then
            -- burns_fluid=false: extracts (T_in - default_temperature) * heat_capacity per unit.
            -- The engine caps T_in at FluidEnergySource.maximum_temperature (0 means no cap).
            local input_t = fuel.max_temperature
            if fuel_typed_name then
                input_t = fuel_typed_name.temperature
                    or fuel_typed_name.maximum_temperature
                    or input_t
            end
            local cap = energy.maximum_temperature
            if cap and cap > 0 and input_t > cap then
                input_t = cap
            end
            local delta = input_t - fuel.default_temperature
            if delta > 0 then
                energy_per_unit = delta * fuel.heat_capacity
            end
        end
        ---@diagnostic enable: param-type-mismatch
        return (energy_per_unit == 0) and 0 or power / energy_per_unit
    end

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
        -- entity-ghost fallback (see typed_name_to_machine): no energy source,
        -- report as void so is_use_fuel / is_generator both return false.
        return "void"
    end
end

---comment
---@param machine LuaEntityPrototype
---@return { [string]: true }?
function M.try_get_fuel_categories(machine)
    if machine.burner_prototype then
        return machine.burner_prototype.fuel_categories
    else
        return nil
    end
end

---comment
---@param machine LuaEntityPrototype
---@param index integer
---@return LuaFluidPrototype?
function M.get_fluidbox_filter_prototype(machine, index)
    if machine.fluid_energy_source_prototype then
        index = index + 1
    end
    local fluidbox = machine.fluidbox_prototypes[index]
    return fluidbox and fluidbox.filter
end

---comment
---@param machine LuaEntityPrototype
---@return TypedName?
function M.try_get_fixed_fuel(machine)
    if machine.heat_energy_source_prototype then
        return tn.create_typed_name("virtual_material", "<heat>")
    elseif machine.fluid_energy_source_prototype then
        local energy = machine.fluid_energy_source_prototype
        local fluidbox_filter = energy.fluid_box.filter
        if not fluidbox_filter then
            return nil
        end
        local min_temp = fluidbox_filter.default_temperature
        local max_temp = energy.maximum_temperature or fluidbox_filter.max_temperature
        return tn.create_typed_name("fluid", fluidbox_filter.name, nil, nil, min_temp, max_temp)
    elseif machine.type == "generator" then
        local fluidbox_filter = M.get_fluidbox_filter_prototype(machine, 1)
        if not fluidbox_filter then
            return nil
        end
        local min_temp = fluidbox_filter.default_temperature
        local max_temp = machine.maximum_temperature or fluidbox_filter.max_temperature
        return tn.create_typed_name("fluid", fluidbox_filter.name, nil, nil, min_temp, max_temp)
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
function M.is_use_any_fluid_fuel(machine)
    if machine.fluid_energy_source_prototype then
        return machine.fluid_energy_source_prototype.fluid_box.filter == nil
    end
    -- Generators carry their fluid input on the entity itself, not through a
    -- FluidEnergySource. A filterless input means any fluid fuel goes.
    -- burner-generator is solid-fueled and falls through to false here.
    if machine.type == "generator" then
        return M.get_fluidbox_filter_prototype(machine, 1) == nil
    end
    return false
end

---comment
---@param machine LuaEntityPrototype
---@return boolean
function M.is_generator(machine)
    return machine.type == "generator" or machine.type == "burner-generator"
end

---@param recipe LuaRecipePrototype | VirtualRecipe
---@return number
function M.get_crafting_energy(recipe)
    ---@diagnostic disable-next-line: param-type-mismatch
    if recipe.object_name == "LuaRecipePrototype" then
        return assert(recipe.energy)
    else
        return 1
    end
end

---@param recipe LuaRecipePrototype | VirtualRecipe
---@return number
function M.get_crafting_speed_cap(recipe)
    ---@diagnostic disable-next-line: param-type-mismatch
    if recipe.object_name == "LuaRecipePrototype" then
        return math.huge
    else
        return recipe.crafting_speed_cap or math.huge
    end
end

---comment
---@param machine LuaEntityPrototype
---@param quality QualityID
---@param effectivity_speed number
---@param crafting_speed_cap number
---@return number
function M.get_crafting_speed(machine, quality, effectivity_speed, crafting_speed_cap)
    local ret = machine.get_crafting_speed(quality) or machine.mining_speed
    if not ret then
        ret = 1 + M.get_quality_level(quality) * 0.3
    end
    return math.min(ret * effectivity_speed, crafting_speed_cap)
end

---comment
---@param quality QualityID
function M.get_quality_level(quality)
    local quality_prototype = (type(quality) == "string") and prototypes.quality[quality] or quality
    return quality_prototype and quality_prototype.level or 0
end

return M
