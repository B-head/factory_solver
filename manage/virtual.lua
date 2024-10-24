local flib_table = require "__flib__/table"
local flib_math = require "__flib__/math"

local fs_util = require "fs_util"
local info = require "manage/info"

local M = {}

---comment
---@param typed_name TypedName
---@return boolean
function M.is_virtual(typed_name)
    local t = typed_name.type
    return t == "virtual_material" or t == "virtual_recipe" or t == "virtual_machine"
end

---@return Virtuals
function M.create_virtuals()
    ---@type table<string, VirtualMaterial>
    local materials = {
        ["<heat>"] = {
            type = "virtual_material",
            name = "<heat>",
            localised_name = "Heat", --TODO
            sprite_path = "utility/heat_exchange_indication",
            order = "a",
            group_name = "other",
            subgroup_name = "general",
        },
    }

    ---@type table<string, VirtualRecipe>
    local recipes = {
        ["<solar-power>"] = {
            type = "virtual_recipe",
            name = "<solar-power>",
            localised_name = "Solar power", --TODO
            sprite_path = "factory-solver-solar-panel",
            energy = 1,
            products = {},
            ingredients = {},
            order = "b",
            group_name = "other",
            subgroup_name = "general",
            category = "<solar-power>",
        },
    }

    ---@type table<string, VirtualMachine>
    local machines = {
        ["machine-unknown"] = {
            type = "virtual_machine",
            name = "machine-unknown",
            localised_name = "machine-unknown",
            sprite_path = "utility/questionmark",
            module_inventory_size = 0,
            crafting_speed = 1,
            energy_source = {
                type = "void",
                is_generator = false,
                power_per_second = 0,
                pollution_per_second = 0,
            },
            crafting_categories = {},
        },
    }

    for _, entity in pairs(prototypes.entity) do
        if entity.type == "rocket-silo" then
            -- local recipe, machine = M.create_rocket_silo_virtual(entity)
            -- recipes[recipe.name] = recipe
            -- machines[machine.name] = machine
        elseif entity.type == "boiler" then
            local recipe, machine = M.create_boiler_virtual(entity)
            recipes[recipe.name] = recipe
            machines[machine.name] = machine
        elseif entity.type == "generator" then
            local recipe, machine = M.create_generator_virtual(entity)
            recipes[recipe.name] = recipe
            machines[machine.name] = machine
        elseif entity.type == "burner-generator" then
            local recipe, machine = M.create_burner_generator_virtual(entity)
            recipes[recipe.name] = recipe
            machines[machine.name] = machine
        elseif entity.type == "reactor" then
            local recipe, machine = M.create_reactor_virtual(entity)
            recipes[recipe.name] = recipe
            machines[machine.name] = machine
        elseif entity.type == "solar-panel" then
            local machine = M.create_solar_panel_virtual(entity)
            machines[machine.name] = machine
        elseif entity.type == "offshore-pump" then
            local recipe, machine = M.create_offshore_pump_virtual(entity)
            recipes[recipe.name] = recipe
            machines[machine.name] = machine
        elseif entity.type == "resource" then
            local recipe = M.create_resource_virtual(entity)
            recipes[recipe.name] = recipe
        elseif entity.type == "mining-drill" then
            local machine = M.create_mining_drill_virtual(entity)
            machines[machine.name] = machine
        end
    end

    ---@type { [string]: boolean }
    local crafting_categories = {}

    for _, machine in pairs(machines) do
        for category, _ in pairs(machine.crafting_categories) do
            crafting_categories[category] = true
        end
    end

    return {
        material = materials,
        recipe = recipes,
        machine = machines,
        crafting_categories = crafting_categories,
    }
end

---@param typed_name TypedName?
---@return string
---@return string
---@return string
function M.get_craft_order(typed_name)
    if not typed_name then
        return "", "other", "other"
    end

    local prototype
    if typed_name.type == "item" then
        prototype = prototypes.item[typed_name.name]
    elseif typed_name.type == "fluid" then
        prototype = prototypes.fluid[typed_name.name]
    else
        return assert()
    end

    return prototype.order, prototype.group.name, prototype.subgroup.name
end

---@param rocket_silo_prototype LuaEntityPrototype
---@return VirtualRecipe
---@return VirtualMachine
function M.create_rocket_silo_virtual(rocket_silo_prototype)
    local crafting_category = "<dedicated>" .. rocket_silo_prototype.name
    local rocket_part = prototypes.recipe[rocket_silo_prototype.fixed_recipe] -- TODO if the recipe is not fixed.
    local rocket_parts_required = assert(rocket_silo_prototype.rocket_parts_required)

    local ingredients = {}
    for _, value in pairs(rocket_part.ingredients) do
        local amount = {
            type = value.type,
            name = value.name,
            amount_per_second = info.raw_ingredient_to_amount(value, rocket_part.energy, rocket_parts_required, 1),
        }
        flib_table.insert(ingredients, amount)
    end

    local mining_result = rocket_silo_prototype.mineable_properties.products[1]
    local order, group_name, subgroup_name = M.get_craft_order(mining_result)

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<space-science-pack>" .. rocket_silo_prototype.name,
        localised_name = { "item-name.space-science-pack" },
        sprite_path = "item/space-science-pack",
        energy = 1,
        products = {
            {
                type = "item",
                name = "space-science-pack",
                amount_per_second = 1000,
            }
        },
        ingredients = ingredients,
        order = order,
        group_name = group_name,
        subgroup_name = subgroup_name,
        category = crafting_category,
    }

    ---@type VirtualMachine
    local machine = {
        type = "virtual_machine",
        name = rocket_silo_prototype.name,
        localised_name = rocket_silo_prototype.localised_name,
        sprite_path = "entity/" .. rocket_silo_prototype.name,
        module_inventory_size = rocket_silo_prototype.module_inventory_size,
        crafting_speed = rocket_silo_prototype.get_crafting_speed() / rocket_parts_required,
        -- crafting_interval_delay = 2420, -- TODO calculate
        -- interval_power_per_second = rocket_silo_prototype.active_energy_usage * info.ticks_per_second,
        energy_source = {
            type = info.get_energy_source_type(rocket_silo_prototype),
            is_generator = false,
            power_per_second = info.raw_energy_to_power(rocket_silo_prototype, 1),
            pollution_per_second = info.raw_emission_to_pollution(rocket_silo_prototype, "pollution", 1, 1),
            fuel_categories = info.try_get_fuel_categories(rocket_silo_prototype),
            fixed_fuel_typed_name = info.try_get_fixed_fuel(rocket_silo_prototype)
        },
        crafting_categories = {
            [crafting_category] = true,
        },
    }

    return recipe, machine
end

---@param boiler_prototype LuaEntityPrototype
---@return VirtualRecipe
---@return VirtualMachine
function M.create_boiler_virtual(boiler_prototype)
    local crafting_category = "<dedicated>" .. boiler_prototype.name

    if boiler_prototype.boiler_mode == "output-to-separate-pipe" then
        local input_fluidbox = boiler_prototype.fluidbox_prototypes[1]
        local output_fluidbox = boiler_prototype.fluidbox_prototypes[2]
        local input_fluid = prototypes.fluid[input_fluidbox.filter.name]
        local output_fluid = prototypes.fluid[output_fluidbox.filter.name]

        -- TODO virtual temperatue
        local need_tick = (boiler_prototype.target_temperature - input_fluid.default_temperature) /
            boiler_prototype.get_max_energy_usage()

        local mining_result = boiler_prototype.mineable_properties.products[1]
        local order, group_name, subgroup_name = M.get_craft_order(mining_result)

        ---@type VirtualRecipe
        local recipe = {
            type = "virtual_recipe",
            name = "<run>" .. boiler_prototype.name,
            localised_name = "<run>" .. boiler_prototype.name, --TODO
            sprite_path = "entity/" .. boiler_prototype.name,
            energy = 1,
            products = {
                {
                    type = "fluid",
                    name = output_fluidbox.filter.name,
                    amount_per_second = info.second_per_tick / (need_tick * output_fluid.heat_capacity),
                }
            },
            ingredients = {
                {
                    type = "fluid",
                    name = input_fluidbox.filter.name,
                    amount_per_second = info.second_per_tick / (need_tick * input_fluid.heat_capacity),
                }
            },
            order = order,
            group_name = group_name,
            subgroup_name = subgroup_name,
            category = crafting_category,
        }

        ---@type VirtualMachine
        local machine = {
            type = "virtual_machine",
            name = boiler_prototype.name,
            localised_name = boiler_prototype.localised_name,
            sprite_path = "entity/" .. boiler_prototype.name,
            module_inventory_size = 0,
            crafting_speed = 1,
            energy_source = {
                type = info.get_energy_source_type(boiler_prototype),
                is_generator = false,
                power_per_second = info.raw_energy_to_power(boiler_prototype, 1),
                pollution_per_second = info.raw_emission_to_pollution(boiler_prototype, "pollution", 1, 1),
                fuel_categories = info.try_get_fuel_categories(boiler_prototype),
                fixed_fuel_typed_name = info.try_get_fixed_fuel(boiler_prototype)
            },
            crafting_categories = {
                [crafting_category] = true,
            },
        }

        return recipe, machine
    elseif boiler_prototype.boiler_mode == "heat-water-inside" then
        local input_fluidbox = boiler_prototype.fluidbox_prototypes[1]
        local input_fluid = prototypes.fluid[input_fluidbox.filter.name]

        -- TODO virtual temperatue
        local need_tick = (boiler_prototype.target_temperature - input_fluid.default_temperature) /
            boiler_prototype.get_max_energy_usage()

        local mining_result = boiler_prototype.mineable_properties.products[1]
        local order, group_name, subgroup_name = M.get_craft_order(mining_result)

        ---@type VirtualRecipe
        local recipe = {
            type = "virtual_recipe",
            name = "<run>" .. boiler_prototype.name,
            localised_name = "<run>" .. boiler_prototype.name, --TODO
            sprite_path = "entity/" .. boiler_prototype.name,
            energy = 1,
            products = {
                {
                    type = "fluid",
                    name = input_fluidbox.filter.name,
                    amount_per_second = info.second_per_tick / (need_tick * input_fluid.heat_capacity),
                }
            },
            ingredients = {
                {
                    type = "fluid",
                    name = input_fluidbox.filter.name,
                    amount_per_second = info.second_per_tick / (need_tick * input_fluid.heat_capacity),
                }
            },
            order = order,
            group_name = group_name,
            subgroup_name = subgroup_name,
            category = crafting_category,
        }

        ---@type VirtualMachine
        local machine = {
            type = "virtual_machine",
            name = boiler_prototype.name,
            localised_name = boiler_prototype.localised_name,
            sprite_path = "entity/" .. boiler_prototype.name,
            module_inventory_size = 0,
            crafting_speed = 1,
            energy_source = {
                type = info.get_energy_source_type(boiler_prototype),
                is_generator = false,
                power_per_second = info.raw_energy_to_power(boiler_prototype, 1),
                pollution_per_second = info.raw_emission_to_pollution(boiler_prototype, "pollution", 1, 1),
                fuel_categories = info.try_get_fuel_categories(boiler_prototype),
                fixed_fuel_typed_name = info.try_get_fixed_fuel(boiler_prototype)
            },
            crafting_categories = {
                [crafting_category] = true,
            },
        }

        return recipe, machine
    else
        return assert()
    end
end

---@param generator_prototype LuaEntityPrototype
---@return VirtualRecipe
---@return VirtualMachine
function M.create_generator_virtual(generator_prototype)
    local crafting_category = "<dedicated>" .. generator_prototype.name
    local input_fluidbox = generator_prototype.fluidbox_prototypes[1]
    local input_fluid = prototypes.fluid[input_fluidbox.filter.name]

    local alternative_fuel_value = generator_prototype.max_power_output / generator_prototype.fluid_usage_per_tick
    local max_power_per_tick = generator_prototype.max_power_output
    if not max_power_per_tick then
        if generator_prototype.burns_fluid then
            alternative_fuel_value = input_fluid.fuel_value * generator_prototype.effectivity
            max_power_per_tick = generator_prototype.fluid_usage_per_tick * alternative_fuel_value
        else
            local diff_temp = flib_math.min(input_fluid.max_temperature, generator_prototype.maximum_temperature) -
                input_fluid.default_temperature
            alternative_fuel_value = diff_temp * input_fluid.heat_capacity * generator_prototype.effectivity
            max_power_per_tick = generator_prototype.fluid_usage_per_tick * alternative_fuel_value
        end
    end

    local mining_result = generator_prototype.mineable_properties.products[1]
    local order, group_name, subgroup_name = M.get_craft_order(mining_result)

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. generator_prototype.name,
        localised_name = "<run>" .. generator_prototype.name, --TODO
        sprite_path = "entity/" .. generator_prototype.name,
        energy = 1,
        products = {},
        ingredients = {},
        order = order,
        group_name = group_name,
        subgroup_name = subgroup_name,
        category = crafting_category,
    }

    ---@type VirtualMachine
    local machine = {
        type = "virtual_machine",
        name = generator_prototype.name,
        localised_name = generator_prototype.localised_name,
        sprite_path = "entity/" .. generator_prototype.name,
        module_inventory_size = 0,
        crafting_speed = 1,
        energy_source = {
            type = "fluid",
            is_generator = true,
            power_per_second = -max_power_per_tick * info.second_per_tick,
            pollution_per_second = 0,
            fixed_fuel_typed_name = info.create_typed_name("fluid", input_fluidbox.filter.name),
            alternative_fuel_value = alternative_fuel_value,
        },
        crafting_categories = {
            [crafting_category] = true,
        },
    }

    return recipe, machine
end

---@param burner_generator_prototype LuaEntityPrototype
---@return VirtualRecipe
---@return VirtualMachine
function M.create_burner_generator_virtual(burner_generator_prototype)
    local crafting_category = "<dedicated>" .. burner_generator_prototype.name
    local max_power = burner_generator_prototype.max_power_output

    local mining_result = burner_generator_prototype.mineable_properties.products[1]
    local order, group_name, subgroup_name = M.get_craft_order(mining_result)

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. burner_generator_prototype.name,
        localised_name = "<run>" .. burner_generator_prototype.name, --TODO
        sprite_path = "entity/" .. burner_generator_prototype.name,
        energy = 1,
        products = {},
        ingredients = {},
        order = order,
        group_name = group_name,
        subgroup_name = subgroup_name,
        category = crafting_category,
    }

    ---@type VirtualMachine
    local machine = {
        type = "virtual_machine",
        name = burner_generator_prototype.name,
        localised_name = burner_generator_prototype.localised_name,
        sprite_path = "entity/" .. burner_generator_prototype.name,
        module_inventory_size = 0,
        crafting_speed = 1,
        energy_source = {
            type = "burner",
            is_generator = true,
            power_per_second = -max_power * info.second_per_tick,
            pollution_per_second = max_power *
                burner_generator_prototype.burner_prototype.emissions_per_joule["pollution"],
            fuel_categories = burner_generator_prototype.burner_prototype.fuel_categories,
        },
        crafting_categories = {
            [crafting_category] = true,
        },
    }

    return recipe, machine
end

---@param reactor_prototype LuaEntityPrototype
---@return VirtualRecipe
---@return VirtualMachine
function M.create_reactor_virtual(reactor_prototype)
    local crafting_category = "<dedicated>" .. reactor_prototype.name

    local mining_result = reactor_prototype.mineable_properties.products[1]
    local order, group_name, subgroup_name = M.get_craft_order(mining_result)

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. reactor_prototype.name,
        localised_name = "<run>" .. reactor_prototype.name, --TODO
        sprite_path = "entity/" .. reactor_prototype.name,
        energy = 1,
        products = {
            {
                type = "virtual_material",
                name = "<heat>",
                amount_per_second = reactor_prototype.get_max_energy_usage() * info.second_per_tick,
            },
        },
        ingredients = {},
        order = order,
        group_name = group_name,
        subgroup_name = subgroup_name,
        category = crafting_category,
    }

    ---@type VirtualMachine
    local machine = {
        type = "virtual_machine",
        name = reactor_prototype.name,
        localised_name = reactor_prototype.localised_name,
        sprite_path = "entity/" .. reactor_prototype.name,
        module_inventory_size = 0,
        crafting_speed = 1,
        energy_source = {
            type = info.get_energy_source_type(reactor_prototype),
            is_generator = false,
            power_per_second = info.raw_energy_to_power(reactor_prototype, 1),
            pollution_per_second = info.raw_emission_to_pollution(reactor_prototype, "pollution", 1, 1),
            fuel_categories = info.try_get_fuel_categories(reactor_prototype),
            fixed_fuel_typed_name = info.try_get_fixed_fuel(reactor_prototype)
        },
        crafting_categories = {
            [crafting_category] = true,
        },
    }

    return recipe, machine
end

---@param solar_panel_prototype LuaEntityPrototype
---@return VirtualMachine
function M.create_solar_panel_virtual(solar_panel_prototype)
    local daylight_coefficient = 42 / 60 -- TODO calculate

    ---@type VirtualMachine
    local machine = {
        type = "virtual_machine",
        name = solar_panel_prototype.name,
        localised_name = solar_panel_prototype.localised_name,
        sprite_path = "entity/" .. solar_panel_prototype.name,
        module_inventory_size = 0,
        crafting_speed = 1,
        energy_source = {
            type = "electric",
            is_generator = true,
            power_per_second = -solar_panel_prototype.get_max_energy_production() * info.second_per_tick *
                daylight_coefficient,
            pollution_per_second = 0,
        },
        crafting_categories = {
            ["<solar-power>"] = true,
        },
    }

    return machine
end

---@param offshore_pump_prototype LuaEntityPrototype
---@return VirtualRecipe
---@return VirtualMachine
function M.create_offshore_pump_virtual(offshore_pump_prototype)
    local crafting_category = "<dedicated>" .. offshore_pump_prototype.name
    local fluidbox = offshore_pump_prototype.fluidbox_prototypes[1]

    local fluid_name = "water"
    if fluidbox.filter then
        fluid_name = fluidbox.filter.name
    end

    local mining_result = offshore_pump_prototype.mineable_properties.products[1]
    local order, group_name, subgroup_name = M.get_craft_order(mining_result)

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. offshore_pump_prototype.name,
        localised_name = "<run>" .. offshore_pump_prototype.name, --TODO
        sprite_path = "entity/" .. offshore_pump_prototype.name,

        energy = 1,
        products = {
            {
                type = "fluid",
                name = fluid_name,
                amount_per_second = offshore_pump_prototype.pumping_speed * info.second_per_tick,
            }
        },
        ingredients = {},
        order = order,
        group_name = group_name,
        subgroup_name = subgroup_name,
        category = crafting_category,
    }

    ---@type VirtualMachine
    local machine = {
        type = "virtual_machine",
        name = offshore_pump_prototype.name,
        localised_name = offshore_pump_prototype.localised_name,
        sprite_path = "entity/" .. offshore_pump_prototype.name,
        module_inventory_size = 0,
        crafting_speed = 1,
        energy_source = {
            type = "void",
            is_generator = false,
            power_per_second = info.raw_energy_to_power(offshore_pump_prototype, 1),
            pollution_per_second = 0,
        },
        crafting_categories = {
            [crafting_category] = true,
        },
    }

    return recipe, machine
end

---@param resource_prototype LuaEntityPrototype
---@return VirtualRecipe
function M.create_resource_virtual(resource_prototype)
    local mineable = resource_prototype.mineable_properties

    local products = {}
    for _, value in pairs(mineable.products) do
        local data = {
            type = value.type,
            name = value.name,
            amount_per_second = info.raw_product_to_amount(value, mineable.mining_time, 1, 1, 1),
        }
        flib_table.insert(products, data)
    end

    local ingredients = {}
    if mineable.required_fluid then
        local data = {
            type = "fluid",
            name = mineable.required_fluid,
            amount_per_second = mineable.fluid_amount,
        }
        flib_table.insert(ingredients, data)
    end

    local main_product = mineable.products[1]
    local order, group_name, subgroup_name = M.get_craft_order(main_product)

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<minable>" .. resource_prototype.name,
        localised_name = "<minable>" .. resource_prototype.name, --TODO
        sprite_path = "entity/" .. resource_prototype.name,
        energy = 1,
        products = products,
        ingredients = ingredients,
        order = order,
        group_name = group_name,
        subgroup_name = subgroup_name,
        category = "<resource>" .. resource_prototype.resource_category,
    }

    return recipe
end

---@param mining_drill_prototype LuaEntityPrototype
---@return VirtualMachine
function M.create_mining_drill_virtual(mining_drill_prototype)
    local crafting_categories = {}
    for key, _ in pairs(mining_drill_prototype.resource_categories) do
        crafting_categories["<resource>" .. key] = true
    end

    ---@type VirtualMachine
    local machine = {
        type = "virtual_machine",
        name = mining_drill_prototype.name,
        localised_name = mining_drill_prototype.localised_name,
        sprite_path = "entity/" .. mining_drill_prototype.name,
        module_inventory_size = mining_drill_prototype.module_inventory_size,
        crafting_speed = mining_drill_prototype.mining_speed,
        energy_source = {
            type = info.get_energy_source_type(mining_drill_prototype),
            is_generator = false,
            power_per_second = info.raw_energy_to_power(mining_drill_prototype, 1),
            pollution_per_second = info.raw_emission_to_pollution(mining_drill_prototype, "pollution", 1, 1),
            fuel_categories = info.try_get_fuel_categories(mining_drill_prototype),
            fixed_fuel_typed_name = info.try_get_fixed_fuel(mining_drill_prototype)
        },
        crafting_categories = crafting_categories,
    }

    return machine
end

return M
