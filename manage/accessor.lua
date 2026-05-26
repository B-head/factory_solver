local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local tn = require "manage/typed_name"

local M = {}

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

---Scale a normalized lab ingredient amount in place by every input-side
---productivity-like factor that does NOT come from modules:
---  * science_pack_drain_rate_percent (lab/biolab intrinsic): fewer packs
---    drained per research unit.
---  * pack quality durability (LuaItemPrototype:get_durability(quality)): a
---    quality-N pack carries durability-N research units worth of drain, so
---    one pack item is consumed once every `durability` research units.
---Both reduce per-second pack consumption, stack multiplicatively with each
---other and with module productivity (which raw_product_to_amount already
---applied on products). Module productivity is intentionally NOT applied
---here — that's a separate axis on the output side.
---Every caller that turns a recipe ingredient into a per-second amount for
---a lab-driven recipe must call this so the LP, the per-line UI, and the
---totals display agree.
---@param amount NormalizedAmount
---@param machine LuaEntityPrototype
function M.apply_lab_input_productivity_to_ingredient(amount, machine)
    if machine.type ~= "lab" then
        return
    end
    amount.amount_per_second = amount.amount_per_second
        * (machine.science_pack_drain_rate_percent / 100)
    local item_proto = prototypes.item[amount.name]
    if not item_proto then
        return
    end
    -- prototypes.quality returns nil for any string the engine doesn't know
    -- (e.g. legacy sentinels on migrated saves); skip the durability scaling
    -- in that case so get_durability — which would otherwise raise on an
    -- invalid QualityID — never sees it.
    local quality_proto = prototypes.quality[amount.quality]
    if not quality_proto then
        return
    end
    -- LuaItemPrototype.get_durability is bound to the item proto at index
    -- time — its in-game signature is `(QualityID) -> double?`, NOT a Lua
    -- method. Calling with colon (`item_proto:get_durability(q)`) would
    -- pass item_proto in the QualityID slot and trip Factorio's "Invalid
    -- QualityID" runtime check. pcall keeps non-tool items (no durability)
    -- from crashing the solve.
    local ok, durability = pcall(item_proto.get_durability, quality_proto)
    if ok and durability and durability > 0 then
        amount.amount_per_second = amount.amount_per_second / durability
    end
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

---Per-second emission rate at full throughput, combining the energy
---source's base (raw_emission_to_pollution) with the burned fuel's
---multiplier (fuel_emissions_multiplier for items, emissions_multiplier
---for fluids). Returns the base rate alone for non-fuel machines.
---@param machine LuaEntityPrototype
---@param pollutant_type string
---@param quality QualityID
---@param effectivity_consumption number
---@param effectivity_pollution number
---@param fuel_typed_name TypedName?
---@return number
function M.get_pollution_per_second(machine, pollutant_type, quality,
    effectivity_consumption, effectivity_pollution, fuel_typed_name)
    local pollution = M.raw_emission_to_pollution(machine, pollutant_type, quality,
        effectivity_consumption, effectivity_pollution)
    if M.is_use_fuel(machine) and fuel_typed_name then
        local fuel = tn.typed_name_to_material(fuel_typed_name)
        pollution = pollution * M.get_fuel_emissions_multiplier(fuel)
    end
    return pollution
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

    -- get_fluid_usage_per_tick(quality) returns the engine-resolved per-tick
    -- consumption at the requested quality (Factorio 2.0.x runtime API). It
    -- replaces the previous hardcoded `1 + level * 0.3` multiplier on
    -- fluid_usage_per_tick, which assumed vanilla QualityPrototype constants;
    -- the engine call now picks up any modded customisation transparently.
    local consumption = machine.get_fluid_usage_per_tick(machine_quality) * M.second_per_tick
    local effectivity_value = machine.effectivity or 1
    local fuel_power = -consumption * energy_per_unit * effectivity_value

    -- Both values are negative (output). The bottleneck has the smaller
    -- magnitude, i.e. the value closer to zero.
    if fuel_power > max_power then
        return fuel_power
    end
    return max_power
end

---Per-second electric power flow for a machine running at full throughput.
---Positive = consumption, negative = production, zero = the machine
---exchanges its energy in fuel form (and so doesn't appear on the electric
---grid). Generators are bounded by both max_power_output and the supplied
---fuel's energy density.
---@param machine LuaEntityPrototype
---@param machine_quality QualityID
---@param effectivity_consumption number
---@param fuel_typed_name TypedName?
---@return number
function M.get_power_per_second(machine, machine_quality, effectivity_consumption, fuel_typed_name)
    if M.is_generator(machine) then
        local fuel = fuel_typed_name and tn.typed_name_to_material(fuel_typed_name)
        return M.get_generator_power(machine, machine_quality, fuel, fuel_typed_name)
    end
    if M.is_use_fuel(machine) then
        return 0
    end
    return M.raw_energy_usage_to_power(machine, machine_quality, effectivity_consumption)
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
---@param name string?
---@return LuaItemPrototype?
function M.get_module(name)
    if not name then
        return nil
    end

    local module = prototypes.item[name]
    if not module then
        return nil
    elseif module.type ~= "module" then
        return nil
    else
        return module
    end
end

---True for modules whose effect set includes a positive quality bonus
---(e.g. the vanilla quality module). Used to warn in the machine dialog when
---such a module is set while the force has unlocked no quality above normal,
---so the cascade cannot advance and the module would have no visible effect.
---@param name string?
---@return boolean
function M.is_quality_module(name)
    local module = M.get_module(name)
    if not module then
        return false
    end
    local effects = module.module_effects
    return effects ~= nil and (effects.quality or 0) > 0
end

---comment
---@param name string?
---@return LuaEntityPrototype?
function M.get_beacon(name)
    if not name then
        return nil
    end

    local beacon = prototypes.entity[name]
    if not beacon then
        return nil
    elseif beacon.type ~= "beacon" then
        return nil
    else
        return beacon
    end
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

---Offshore pumps compatible with a tile-bound fluid. An empty fluid_box
---filter on the pump means "any fluid"; a set filter must match by name.
---@param fluid_name string
---@return LuaEntityPrototype[]
function M.get_offshore_pumps_for_fluid(fluid_name)
    local pumps = prototypes.get_entity_filtered {
        { filter = "type", type = "offshore-pump" },
    }
    pumps = flib_table.filter(pumps, function(value)
        local filter = M.get_fluidbox_filter_prototype(value, 1)
        return filter == nil or filter.name == fluid_name
    end)
    pumps = fs_util.sort_prototypes(fs_util.to_list(pumps))
    return pumps
end

---Labs that accept a particular science pack item (their lab_inputs contains
---the given name). Drives the machine picker for <research>{pack} virtual
---recipes.
---@param pack_name string
---@return LuaEntityPrototype[]
function M.get_labs_for_pack(pack_name)
    local labs = prototypes.get_entity_filtered {
        { filter = "type", type = "lab" },
    }
    labs = flib_table.filter(labs, function(value)
        for _, input in ipairs(value.lab_inputs or {}) do
            if input == pack_name then
                return true
            end
        end
        return false
    end)
    labs = fs_util.sort_prototypes(fs_util.to_list(labs))
    return labs
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
    elseif recipe.pumped_fluid_name then
        return M.get_offshore_pumps_for_fluid(recipe.pumped_fluid_name)
    elseif recipe.consumed_pack_name then
        return M.get_labs_for_pack(recipe.consumed_pack_name)
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
        return craft.hidden
    elseif craft.type == "virtual_recipe" then
        return craft.hidden
    else
        return assert()
    end
    ---@diagnostic enable: param-type-mismatch
end

---@param entity LuaEntityPrototype
---@param relation_to_recipes RelationToRecipes
---@return boolean
function M.entity_is_unresearched(entity, relation_to_recipes)
    local ret = true
    for _, value in ipairs(entity.items_to_place_this or {}) do
        local item = prototypes.item[value.name]
        local is_researched = 0 < relation_to_recipes.item[item.name].craftable_count
        ret = ret and not is_researched
    end
    return ret
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
        return M.entity_is_unresearched(craft, relation_to_recipes)
    elseif craft.type == "virtual_material" then
        if craft.source_fluid_name then
            return not (0 < relation_to_recipes.fluid[craft.source_fluid_name].craftable_count)
        elseif craft.source_entity_name then
            return M.entity_is_unresearched(prototypes.entity[craft.source_entity_name], relation_to_recipes)
        else
            return false
        end
    elseif craft.type == "virtual_recipe" then
        return not relation_to_recipes.virtual_recipe_researched[craft.name]
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
        -- See get_generator_power for the rationale: route through the
        -- engine's quality-aware getter instead of hardcoding the vanilla
        -- 30%/tier multiplier so modded QualityPrototype values flow through.
        return machine.get_fluid_usage_per_tick(machine_quality) * M.second_per_tick
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
        local energy = assert(machine.fluid_energy_source_prototype)
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

---True for machines that can receive beacon effects. effect_receiver is nil
---for entities that take neither modules nor beacons (boilers, generators, ...),
---and uses_beacon_effects may be false even when modules are accepted, so both
---are checked.
---@param machine LuaEntityPrototype
---@return boolean
function M.is_use_beacon(machine)
    local effect_receiver = machine.effect_receiver
    return effect_receiver ~= nil and effect_receiver.uses_beacon_effects == true
end

---comment
---@param machine LuaEntityPrototype
---@return boolean
function M.is_generator(machine)
    return machine.type == "generator"
        or machine.type == "burner-generator"
        or machine.type == "fusion-generator"
end

---Substrate (soil tile) names a plant entity can be planted on, derived
---dynamically from plant.autoplace_specification.tile_restriction. Used by
---the production-line UI to populate the substrate picker and by
---new_production_line to pick a default substrate for plant lines.
---
---Vanilla Space Age plants (yumako-tree, jellystem, tree-plant) list every
---player-plantable soil tile in tile_restriction including artificial-*
---variants that never appear in autoplace, so this list matches the
---agricultural tower's actual plot acceptance. Returns a sorted, deduped
---array; empty array when the machine is not a plant or has no restriction.
---@param machine LuaEntityPrototype
---@return string[]
function M.get_plant_substrate_tiles(machine)
    if machine.type ~= "plant" then return {} end
    local ap = machine.autoplace_specification
    if not ap or not ap.tile_restriction then return {} end
    local seen = {}
    local list = {}
    for _, r in ipairs(ap.tile_restriction) do
        if r.first and not seen[r.first] then
            seen[r.first] = true
            flib_table.insert(list, r.first)
        end
        if r.second and not seen[r.second] then
            seen[r.second] = true
            flib_table.insert(list, r.second)
        end
    end
    table.sort(list)
    return list
end

---Returns the single-temperature virtual_material variants of the machine's
---filter fluid. Only meaningful for burns_fluid=false machines, where the
---power output depends on input temperature; returns nil for other cases so
---the caller knows there is nothing to expand. Filterless machines are also
---out of scope here (the candidate fluid set is unbounded).
---
---We deliberately do not clip by the machine's maximum_temperature: the
---engine accepts hotter fluid and merely discards the excess heat, so the
---picker should still surface those variants and let the user choose.
---Out-of-range temperatures are handled correctly downstream by
---get_generator_power and get_fuel_amount_per_second, which clamp T_in.
---@param machine LuaEntityPrototype
---@return VirtualMaterial[]?
function M.get_fluid_fuel_temperature_variants(machine)
    ---@type LuaFluidPrototype?
    local filter
    if machine.fluid_energy_source_prototype then
        local energy = assert(machine.fluid_energy_source_prototype)
        if energy.burns_fluid then return nil end
        filter = energy.fluid_box.filter
    elseif machine.type == "generator" then
        if machine.burns_fluid then return nil end
        filter = M.get_fluidbox_filter_prototype(machine, 1)
    else
        return nil
    end
    if not filter then return nil end

    local prefix = "fluid/" .. filter.name .. "@"
    local prefix_len = #prefix
    local results = {}
    for key, material in pairs(storage.virtuals.material) do
        if string.sub(key, 1, prefix_len) == prefix then
            -- Single-temperature variants stringify to a bare number after
            -- the "@". Range variants stringify to "[lo,hi]" and fail
            -- tonumber, so they're naturally excluded.
            if tonumber(string.sub(key, prefix_len + 1)) then
                results[#results + 1] = material
            end
        end
    end
    return fs_util.sort_prototypes(results)
end

---Picks the best single-temperature variant for a burns_fluid=false
---machine's fuel slot. Returns nil if the machine has no variants or isn't
---a heat-extraction fluid consumer. The choice mirrors the old implicit
---default: highest temperature ≤ machine cap (maximum useful energy, no
---wasted heat); if every variant is above the cap, fall back to the lowest
---(least waste). Used by migration to pin legacy range-only or bare-fluid
---fuel selections onto a concrete picker button.
---@param machine LuaEntityPrototype
---@return VirtualMaterial?
function M.get_default_fluid_fuel_variant(machine)
    local variants = M.get_fluid_fuel_temperature_variants(machine)
    if not variants or #variants == 0 then return nil end

    local cap
    if machine.fluid_energy_source_prototype then
        cap = machine.fluid_energy_source_prototype.maximum_temperature
    elseif machine.type == "generator" then
        cap = machine.maximum_temperature
    end
    if cap and cap <= 0 then cap = nil end

    ---@param v VirtualMaterial
    ---@return number?
    local function temp_of(v)
        return tonumber(string.match(v.name, "@(%-?[%d.]+)$"))
    end

    local best, best_t
    for _, v in ipairs(variants) do
        local t = temp_of(v)
        if t and (not cap or t <= cap) then
            if best_t == nil or t > best_t then
                best, best_t = v, t
            end
        end
    end
    if best then return best end

    for _, v in ipairs(variants) do
        local t = temp_of(v)
        if t and (best_t == nil or t < best_t) then
            best, best_t = v, t
        end
    end
    return best
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

---Productivity bonus ceiling for the given recipe. Mirrors get_crafting_speed_cap:
---LuaRecipePrototype carries a vanilla-default 3.0 with smaller values on a few
---Space Age recipes; VirtualRecipe leaves the field unset and the cap collapses
---to math.huge until a future virtual recipe needs one. Consumed by
---get_total_effectivity to clamp the final productivity sum.
---@param recipe LuaRecipePrototype | VirtualRecipe
---@return number
function M.get_maximum_productivity(recipe)
    ---@diagnostic disable-next-line: param-type-mismatch
    if recipe.object_name == "LuaRecipePrototype" then
        -- maximum_productivity landed in Factorio 2.0.77; the LuaCATS bundle
        -- shipped with the build hasn't picked it up yet, so the read is real
        -- but flagged as undefined here.
        ---@diagnostic disable-next-line: undefined-field
        return recipe.maximum_productivity
    else
        return recipe.maximum_productivity or math.huge
    end
end

---Per-effect-kind allow mask for the (recipe, entity) pair. Returns a dict
---over { speed, productivity, consumption, pollution, quality } with `true`
---for kinds that both sides accept. Either side leaving allowed_effects nil
---is treated as "no restriction" (Factorio semantics). VirtualRecipe never
---declares allowed_effects, so the union read falls through nil-safely.
---@param recipe LuaRecipePrototype | VirtualRecipe
---@param entity LuaEntityPrototype
---@return table<string, boolean>
function M.get_allowed_effects(recipe, entity)
    local ret = { speed = true, productivity = true, consumption = true,
                  pollution = true, quality = true }
    local function intersect(src)
        if src == nil then return end
        for k in pairs(ret) do
            if src[k] == false then ret[k] = false end
        end
    end
    ---@diagnostic disable-next-line: undefined-field
    intersect(recipe.allowed_effects)
    intersect(entity.allowed_effects)
    return ret
end

---Intersection of recipe and entity allowed_module_categories. nil result
---means "no restriction" on either side. The field is a set
---(`dict[string → true]?`) — key absence means the category is NOT allowed,
---which is the opposite convention to allowed_effects's `false` opt-out.
---Consumed by get_total_effectivity to skip modules whose
---LuaItemPrototype.category falls outside this intersection.
---@param recipe LuaRecipePrototype | VirtualRecipe
---@param entity LuaEntityPrototype
---@return table<string, true>?
function M.get_allowed_module_categories(recipe, entity)
    ---@diagnostic disable-next-line: undefined-field
    local r = recipe.allowed_module_categories
    local e = entity.allowed_module_categories
    if r == nil and e == nil then return nil end
    if r == nil then return e end
    if e == nil then return r end
    local ret = {}
    for k in pairs(r) do
        if e[k] then ret[k] = true end
    end
    return ret
end

---comment
---@param quality QualityID
function M.get_quality_level(quality)
    local quality_prototype = (type(quality) == "string") and prototypes.quality[quality] or quality
    return quality_prototype and quality_prototype.level or 0
end

---Return the base multiplier for a quality tier (normal=1, uncommon=1.3, ...).
---LuaQualityPrototype::default_multiplier (Factorio 2.0.69+ runtime read)
---reflects per-QualityPrototype customisation, so this is the single entry
---point used to retire the hardcoded `1 + level * 0.3` everywhere.
---Falls back to `1 + level * 0.3` on older Factorio versions or when
---default_multiplier is not exposed.
---@param quality QualityID
---@return number
function M.get_quality_default_multiplier(quality)
    local quality_prototype = (type(quality) == "string") and prototypes.quality[quality] or quality
    if quality_prototype then
        local m = quality_prototype.default_multiplier
        if m then
            return m
        end
        return 1 + quality_prototype.level * 0.3
    end
    return 1
end

---Return the quality multiplier applied to module effects.
---Uses the quality tier's default_multiplier (matches the engine's own
---quality scaling of module effects). Used to replace the hardcoded
---`(1 + quality_level * 0.3)` inside `get_total_effectivity`'s `modify()`.
---@param quality QualityID
---@return number
function M.get_module_quality_multiplier(quality)
    return M.get_quality_default_multiplier(quality)
end

---Return the per-second throughput rate of `machine` that drives a virtual
---recipe. pre_solve multiplies each ingredient/product's per-craft ratio
---(amount) by this base rate. The machine.type dispatch was pinned down
---from a 2026-05-24 in-game dump:
---  boiler / reactor              -> get_max_energy_usage(q) (heat amount proxy)
---  generator / fusion-*          -> get_fluid_usage_per_tick(q)
---                                   (fusion-reactor's energy_usage is
---                                   quality-invariant; only the fluid
---                                   side scales)
---  thruster                      -> max_performance.fluid_usage × default_multiplier(q)
---                                   (no runtime quality API; multiplier
---                                   applied manually. Verified in-game
---                                   that the engine itself also reads
---                                   QualityPrototype::default_multiplier:
---                                   overwriting default_multiplier shifts
---                                   thruster consumption accordingly)
---  mining-drill                  -> mining_speed (quality-independent)
---                                   (vanilla mining-drill's mining speed
---                                   itself does not scale with quality;
---                                   quality acts on productivity / module
---                                   slots / radius instead. Verified
---                                   in-game on 2026-05-24)
---  offshore-pump                 -> get_pumping_speed(q)
---  lab                           -> get_researching_speed(q)
---  plant / agricultural-tower    -> 1.0 (growth_ticks lives on the plant
---                                   prototype; tower quality has no effect)
---  default                       -> get_crafting_speed(q) (covers every
---                                   CraftingMachine type)
---All return values are normalised to "per second" (per-tick APIs are
---multiplied by second_per_tick internally). effectivity must be applied
---by the caller (this function is a pure helper depending only on machine
---+ quality).
---When the API returns nil (modded entity / placeholder), falls back to 0.
---@param machine LuaEntityPrototype
---@param quality QualityID
---@return number
function M.get_virtual_recipe_rates(machine, quality)
    local t = machine.type
    if t == "boiler" or t == "reactor" then
        return (machine.get_max_energy_usage(quality) or 0) * M.second_per_tick
    elseif t == "generator" or t == "fusion-reactor" or t == "fusion-generator" then
        return (machine.get_fluid_usage_per_tick(quality) or 0) * M.second_per_tick
    elseif t == "thruster" then
        local perf = machine.max_performance
        if not perf then return 0 end
        return perf.fluid_usage * M.get_quality_default_multiplier(quality) * M.second_per_tick
    elseif t == "mining-drill" then
        return machine.mining_speed or 0
    elseif t == "offshore-pump" then
        return (machine.get_pumping_speed(quality) or 0) * M.second_per_tick
    elseif t == "lab" then
        return machine.get_researching_speed(quality) or 0
    elseif t == "plant" or t == "agricultural-tower" then
        return 1.0
    else
        return machine.get_crafting_speed(quality) or 1
    end
end

---Return the quality-scaled distribution_effectivity of a beacon.
---Factorio 2.0 beacons have no `get_distribution_effectivity(quality)`
---runtime method, so the value is composed from two prototype reads:
---  effective = distribution_effectivity
---            + quality_level * distribution_effectivity_bonus_per_quality_level
---bonus_per_quality_level is optional on the prototype; treat a missing
---value as 0 so vanilla beacons (which do define it) and modded beacons
---that opt out both behave correctly.
---@param beacon LuaEntityPrototype
---@param quality QualityID
---@return number
function M.get_beacon_distribution_effectivity(beacon, quality)
    local base = assert(beacon.distribution_effectivity)
    local bonus = beacon.distribution_effectivity_bonus_per_quality_level or 0
    local level = M.get_quality_level(quality)
    return base + level * bonus
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

---Aggregate modules in slots into per-source counts. Beacon modules are
---kept in a separate per-beacon list so get_total_effectivity can mask each
---group against (recipe ∩ machine) or (recipe ∩ beacon)'s allowed_effects
---independently. The pre-allowed_effects layout collapsed both into a single
---table, which made it impossible to apply per-entity effect restrictions.
---@param machine LuaEntityPrototype
---@param module_typed_names table<string, TypedName>
---@param affected_by_beacons AffectedByBeacon[]
---@param bonuses ResearchBonuses?
---@return TotalModules
function M.get_total_modules(machine, module_typed_names, affected_by_beacons, bonuses)
    ---@param dest table<string, table<string, number>>
    ---@param typed_name TypedName
    ---@param effectivity number
    local function count(dest, typed_name, effectivity)
        local name = typed_name.name
        local quality = typed_name.quality
        if not dest[name] then
            dest[name] = {}
        end
        local inner = dest[name]
        inner[quality] = (inner[quality] or 0) + effectivity
    end

    local machine_modules = {}
    module_typed_names = M.trim_modules(module_typed_names, machine.module_inventory_size)
    for _, typed_name in pairs(module_typed_names) do
        count(machine_modules, typed_name, 1)
    end

    -- Research-derived beacon distribution scales beacon contribution
    -- multiplicatively on top of the beacon prototype's own
    -- distribution_effectivity. Module contribution from machine inventory is
    -- unaffected.
    local beacon_multiplier = 1 + ((bonuses and bonuses.beacon_distribution) or 0)

    ---@type { beacon: LuaEntityPrototype, modules: table<string, table<string, number>> }[]
    local beacon_groups = {}

    -- Machines that cannot receive beacon effects ignore any beacons attached
    -- to the line, so stale data on such a line never reaches the LP.
    if M.is_use_beacon(machine) then
        for _, affected_by_beacon in ipairs(affected_by_beacons) do
            local beacon_typed_name = affected_by_beacon.beacon_typed_name
            local beacon = beacon_typed_name and M.get_beacon(beacon_typed_name.name)
            if beacon and beacon_typed_name then
                local effectivity = M.get_beacon_distribution_effectivity(beacon, beacon_typed_name.quality)
                    * affected_by_beacon.beacon_quantity
                    * beacon_multiplier
                local beacon_module_names = M.trim_modules(affected_by_beacon.module_typed_names,
                    beacon.module_inventory_size)

                local modules = {}
                for _, typed_name in pairs(beacon_module_names) do
                    count(modules, typed_name, effectivity)
                end
                flib_table.insert(beacon_groups, { beacon = beacon, modules = modules })
            end
        end
    end

    return { machine_modules = machine_modules, beacon_groups = beacon_groups }
end

---Collapse a TotalModules grouped layout back to the legacy
---`name → quality → count` aggregate used by UI summary panels that only
---want a flat module roster. Effect masking is intentionally NOT applied
---here — the flat view shows which modules the user picked, not which ones
---contributed to LP effectivity.
---@param total TotalModules
---@return table<string, table<string, number>>
function M.flatten_total_modules(total)
    local out = {}
    local function merge(src)
        for name, inner in pairs(src) do
            if not out[name] then out[name] = {} end
            for quality, count in pairs(inner) do
                out[name][quality] = (out[name][quality] or 0) + count
            end
        end
    end
    merge(total.machine_modules)
    for _, g in ipairs(total.beacon_groups) do
        merge(g.modules)
    end
    return out
end

---Sum every contribution to a line's ModuleEffects: modules in the machine
---slots, modules in attached beacon slots, the machine's effect_receiver
---base_effect, and research bonuses. Modules are masked by recipe ∩ entity
---allowed_effects per source (machine modules against the machine's
---allowed_effects, each beacon's modules against that beacon's). base_effect
---and research bonuses are intentionally NOT masked — they bypass the module
---effect-type restriction in Factorio.
---@param recipe (LuaRecipePrototype | VirtualRecipe)?
---@param total_modules TotalModules
---@param effect_receiver EffectReceiver?
---@param recipe_typed_name TypedName?
---@param machine LuaEntityPrototype?
---@param bonuses ResearchBonuses?
---@param maximum_productivity number?
---@return ModuleEffects
function M.get_total_effectivity(recipe, total_modules, effect_receiver, recipe_typed_name, machine, bonuses, maximum_productivity)
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
    ---@param multiplier number
    ---@param is_negative boolean
    ---@return number
    local function modify(effect, count, multiplier, is_negative)
        effect = effect or 0
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

    ---@param modules table<string, table<string, number>>
    ---@param allowed table<string, boolean>
    ---@param allowed_categories table<string, true>?
    local function apply_group(modules, allowed, allowed_categories)
        for name, inner in pairs(modules) do
            for quality, count in pairs(inner) do
                local module = M.get_module(name)
                if module
                    and (allowed_categories == nil or allowed_categories[module.category])
                then
                    local effects = assert(module.module_effects)
                    -- Quality scaling on module effects: default_multiplier is the
                    -- engine-side per-tier multiplier (vanilla: 1, 1.3, 1.6, 1.9, 2.5
                    -- for normal..legendary). Reading it through the QualityPrototype
                    -- replaces the previous hardcoded (1 + quality_level * 0.3) so
                    -- modded quality tiers are honored.
                    local multiplier = M.get_module_quality_multiplier(quality)
                    if allowed.speed then
                        ret.speed = ret.speed + modify(effects.speed, count, multiplier, false)
                    end
                    if allowed.consumption then
                        ret.consumption = ret.consumption + modify(effects.consumption, count, multiplier, true)
                    end
                    if allowed.productivity then
                        ret.productivity = ret.productivity + modify(effects.productivity, count, multiplier, false)
                    end
                    if allowed.pollution then
                        ret.pollution = ret.pollution + modify(effects.pollution, count, multiplier, true)
                    end
                    if allowed.quality then
                        ret.quality = ret.quality + modify(effects.quality, count, multiplier, false)
                    end
                end
            end
        end
    end

    if recipe and machine then
        apply_group(total_modules.machine_modules,
            M.get_allowed_effects(recipe, machine),
            M.get_allowed_module_categories(recipe, machine))
        for _, g in ipairs(total_modules.beacon_groups) do
            apply_group(g.modules,
                M.get_allowed_effects(recipe, g.beacon),
                M.get_allowed_module_categories(recipe, g.beacon))
        end
    end

    if effect_receiver then
        local base_effect = effect_receiver.base_effect
        ret.speed = ret.speed + (base_effect.speed or 0)
        ret.consumption = ret.consumption + (base_effect.consumption or 0)
        ret.productivity = ret.productivity + (base_effect.productivity or 0)
        ret.pollution = ret.pollution + (base_effect.pollution or 0)
        ret.quality = ret.quality + (base_effect.quality or 0)
    end

    -- Research-derived additive bonuses. Folded in before the min-clamps so
    -- that, like module/beacon effects, a non-zero research bonus can lift
    -- effectivity above its floor.
    if bonuses then
        if recipe_typed_name and recipe_typed_name.type == "recipe" then
            ret.productivity = ret.productivity
                + (bonuses.recipe_productivity[recipe_typed_name.name] or 0)
        end
        if machine then
            if machine.type == "mining-drill" then
                ret.productivity = ret.productivity + bonuses.mining_drill_productivity
            elseif machine.type == "lab" then
                ret.productivity = ret.productivity + bonuses.laboratory_productivity
                ret.speed = ret.speed + bonuses.laboratory_speed
            end
        end
    end

    ret.speed = math.max(ret.speed, 0.2)
    ret.consumption = math.max(ret.consumption, 0.2)
    ret.productivity = math.max(ret.productivity, 0)
    if maximum_productivity then
        ret.productivity = math.min(ret.productivity, maximum_productivity)
    end
    ret.pollution = math.max(ret.pollution, 0.2)
    ret.quality = math.max(ret.quality, 0)

    return ret
end

---Fold one ProductionLine into a per-second NormalizedProductionLine:
---products, ingredients (with lab input productivity), fuel, power and
---pollution all live on the returned table. Quality decomposition and
---bare-fluid temperature widening are deliberately NOT applied here — they
---are LP-only post-steps owned by pre_solve and would distort UI / totals
---views that need the raw per-recipe-quality amounts.
---The companion ModuleEffects is returned so pre_solve can drive
---quality_decomposition with effectivity.quality without recomputing.
---UI / totals callers that don't need it can drop the second return.
---@param line ProductionLine
---@param bonuses ResearchBonuses?
---@return NormalizedProductionLine
---@return ModuleEffects
function M.normalize_production_line(line, bonuses)
    local recipe = tn.typed_name_to_recipe(line.recipe_typed_name)
    local recipe_quality = line.recipe_typed_name.quality
    local machine = tn.typed_name_to_machine(line.machine_typed_name)
    local machine_quality = line.machine_typed_name.quality
    local total_modules = M.get_total_modules(machine, line.module_typed_names,
        line.affected_by_beacons, bonuses)
    local maximum_productivity = M.get_maximum_productivity(recipe)
    local effectivity = M.get_total_effectivity(recipe, total_modules, machine.effect_receiver,
        line.recipe_typed_name, machine, bonuses, maximum_productivity)
    local crafting_energy = M.get_crafting_energy(recipe)
    local crafting_speed_cap = M.get_crafting_speed_cap(recipe)
    -- Dispatch by recipe object kind. Real recipes (LuaRecipePrototype) are
    -- crafted at rate machine.get_crafting_speed(quality) / recipe.energy and
    -- product/ingredient .amount values are per-craft quantities. Virtual
    -- recipes carry per-craft ratios in .amount (default 1) and the per-second
    -- baseline comes from get_virtual_recipe_rates, which dispatches per
    -- machine type to whichever quality-aware runtime API actually scales for
    -- that entity (boiler -> get_max_energy_usage, generator family ->
    -- get_fluid_usage_per_tick, ...). crafting_energy stays 1 for virtual
    -- recipes so the downstream raw_*_to_amount formula (amount * speed /
    -- energy) collapses to ratio * rate.
    local crafting_speed
    ---@diagnostic disable-next-line: undefined-field
    if recipe.object_name == "LuaRecipePrototype" then
        crafting_speed = machine.get_crafting_speed(machine_quality)
            or machine.mining_speed
            or 0
    else
        crafting_speed = M.get_virtual_recipe_rates(machine, machine_quality)
    end
    crafting_speed = math.min(crafting_speed * effectivity.speed, crafting_speed_cap)

    ---@type NormalizedAmount[]
    local products = {}
    for _, product in ipairs(recipe.products) do
        local amount = M.raw_product_to_amount(
            product, recipe_quality, crafting_energy, crafting_speed, effectivity.productivity)
        flib_table.insert(products, amount)
    end

    ---@type NormalizedAmount[]
    local ingredients = {}
    for _, ingredient in ipairs(recipe.ingredients) do
        local amount = M.raw_ingredient_to_amount(
            ingredient, recipe_quality, crafting_energy, crafting_speed)
        M.apply_lab_input_productivity_to_ingredient(amount, machine)
        flib_table.insert(ingredients, amount)
    end

    ---@type NormalizedAmount?
    local fuel_ingredient = nil
    if M.is_use_fuel(machine) then
        local ftn = assert(line.fuel_typed_name)
        local fuel = tn.typed_name_to_material(ftn)
        local amount_per_second = M.get_fuel_amount_per_second(machine, machine_quality,
            fuel, ftn.quality, effectivity.consumption, ftn)
        ---@type NormalizedAmount
        fuel_ingredient = {
            type = ftn.type, ---@diagnostic disable-line: assign-type-mismatch
            name = ftn.name,
            quality = ftn.quality,
            amount_per_second = amount_per_second,
            temperature = ftn.temperature,
            minimum_temperature = ftn.minimum_temperature,
            maximum_temperature = ftn.maximum_temperature,
        }
    end

    local power = M.get_power_per_second(machine, machine_quality,
        effectivity.consumption, line.fuel_typed_name)
    local pollution = M.get_pollution_per_second(machine, "pollution",
        machine_quality, effectivity.consumption, effectivity.pollution,
        line.fuel_typed_name)

    -- Recipe-intrinsic pollution (plant.harvest_emissions baked into
    -- VirtualRecipe.pollution_per_craft by manage/virtual.lua). Real recipes
    -- and other virtual recipes leave this nil and contribute nothing here.
    -- Approximation: per-harvest emission scaled by craft rate so module
    -- pollution effectivity still applies symmetrically with the energy-
    -- source pollution above.
    -- LuaRecipePrototype rejects unknown-key indexing at the C++ layer, so
    -- gate the lookup on the VirtualRecipe branch (see get_crafting_speed_cap
    -- for the same pattern).
    ---@diagnostic disable-next-line: undefined-field
    if recipe.object_name ~= "LuaRecipePrototype" then
        ---@diagnostic disable-next-line: undefined-field
        local pollution_per_craft = recipe.pollution_per_craft
        if pollution_per_craft then
            pollution = pollution
                + pollution_per_craft * (crafting_speed / crafting_energy) * effectivity.pollution
        end
    end

    ---@type NormalizedProductionLine
    local normalized_line = {
        recipe_typed_name = line.recipe_typed_name,
        products = products,
        ingredients = ingredients,
        fuel_ingredient = fuel_ingredient,
        power_per_second = power,
        pollution_per_second = pollution,
    }
    return normalized_line, effectivity
end

return M
