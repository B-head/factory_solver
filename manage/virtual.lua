local flib_table = require "__flib__/table"
local acc = require "manage/accessor"
local tn = require "manage/typed_name"

local M = {}

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
            subgroup_name = "other",
        },
        ["<material-unknown>"] = {
            type = "virtual_material",
            name = "<material-unknown>",
            localised_name = "Unknown material",
            sprite_path = "utility/questionmark",
            order = "z",
            group_name = "other",
            subgroup_name = "other",
        },
    }

    ---@type table<string, VirtualRecipe>
    local recipes = {}

    for _, entity in pairs(prototypes.entity) do
        if entity.type == "rocket-silo" then
            -- local recipe, machine = M.create_rocket_silo_virtual(entity)
            -- recipes[recipe.name] = recipe
            -- machines[machine.name] = machine
        elseif entity.type == "boiler" then
            local recipe = M.create_boiler_virtual(entity)
            recipes[recipe.name] = recipe
        elseif entity.type == "generator" then
            if entity.fluidbox_prototypes[1].filter then
                local recipe = M.create_generator_virtual(entity)
                recipes[recipe.name] = recipe
            end
        elseif entity.type == "burner-generator" then
            local recipe = M.create_burner_generator_virtual(entity)
            recipes[recipe.name] = recipe
        elseif entity.type == "reactor" then
            local recipe = M.create_reactor_virtual(entity)
            recipes[recipe.name] = recipe
        elseif entity.type == "offshore-pump" then
            local recipe = M.create_offshore_pump_virtual(entity)
            recipes[recipe.name] = recipe
        elseif entity.type == "resource" then
            local recipe = M.create_resource_virtual(entity)
            recipes[recipe.name] = recipe
        end
    end

    return {
        material = materials,
        recipe = recipes,
    }
end

---@param rocket_silo_prototype LuaEntityPrototype
---@return VirtualRecipe
function M.create_rocket_silo_virtual(rocket_silo_prototype)
    local crafting_category = "<dedicated>" .. rocket_silo_prototype.name
    local rocket_part = prototypes.recipe[rocket_silo_prototype.fixed_recipe] -- TODO if the recipe is not fixed.
    local rocket_parts_required = assert(rocket_silo_prototype.rocket_parts_required)

    local ingredients = {}
    for _, value in pairs(rocket_part.ingredients) do
        local amount = {
            type = value.type,
            name = value.name,
            amount_per_second = acc.raw_ingredient_to_amount(value, rocket_part.energy, rocket_parts_required, 1),
        }
        flib_table.insert(ingredients, amount)
    end

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<space-science-pack>" .. rocket_silo_prototype.name,
        localised_name = { "item-name.space-science-pack" },
        sprite_path = "item/space-science-pack",
        order = rocket_silo_prototype.order,
        group_name = rocket_silo_prototype.group.name,
        subgroup_name = rocket_silo_prototype.subgroup.name,
        energy = 1,
        products = {
            {
                type = "item",
                name = "space-science-pack",
                amount_per_second = 1000,
            }
        },
        ingredients = ingredients,
        fixed_crafting_machine = tn.craft_to_typed_name(rocket_silo_prototype),
    }

    -- ---@type VirtualMachine
    -- local machine = {
    --     type = "virtual_machine",
    --     name = rocket_silo_prototype.name,
    --     localised_name = rocket_silo_prototype.localised_name,
    --     sprite_path = "entity/" .. rocket_silo_prototype.name,
    --     module_inventory_size = rocket_silo_prototype.module_inventory_size,
    --     crafting_speed = rocket_silo_prototype.get_crafting_speed("normal") / rocket_parts_required,
    --     -- crafting_interval_delay = 2420, -- TODO calculate
    --     -- interval_power_per_second = rocket_silo_prototype.active_energy_usage * acc.ticks_per_second,
    --     energy_source = {
    --         type = acc.get_energy_source_type(rocket_silo_prototype),
    --         is_generator = false,
    --         power_per_second = acc.raw_energy_usage_to_power(rocket_silo_prototype, "normal", 1),
    --         pollution_per_second = acc.raw_emission_to_pollution(rocket_silo_prototype, "pollution", "normal", 1, 1),
    --         fuel_categories = acc.try_get_fuel_categories(rocket_silo_prototype),
    --         fixed_fuel_typed_name = acc.try_get_fixed_fuel(rocket_silo_prototype)
    --     },
    --     crafting_categories = {
    --         [crafting_category] = true,
    --     },
    -- }

    return recipe
end

---@param boiler_prototype LuaEntityPrototype
---@return VirtualRecipe
function M.create_boiler_virtual(boiler_prototype)
    local products, ingredients

    if boiler_prototype.boiler_mode == "output-to-separate-pipe" then
        local input_fluidbox = boiler_prototype.fluidbox_prototypes[1]
        local output_fluidbox = boiler_prototype.fluidbox_prototypes[2]
        local input_fluid = prototypes.fluid[input_fluidbox.filter.name]
        local output_fluid = prototypes.fluid[output_fluidbox.filter.name]

        -- TODO virtual temperatue
        local need_tick = (boiler_prototype.target_temperature - input_fluid.default_temperature) /
            boiler_prototype.get_max_energy_usage()

        products = {
            {
                type = "fluid",
                name = output_fluidbox.filter.name,
                amount_per_second = acc.second_per_tick / (need_tick * output_fluid.heat_capacity),
            }
        }
        ingredients = {
            {
                type = "fluid",
                name = input_fluidbox.filter.name,
                amount_per_second = acc.second_per_tick / (need_tick * input_fluid.heat_capacity),
            }
        }
    elseif boiler_prototype.boiler_mode == "heat-water-inside" then
        local input_fluidbox = boiler_prototype.fluidbox_prototypes[1]
        local input_fluid = prototypes.fluid[input_fluidbox.filter.name]

        -- TODO virtual temperatue
        local need_tick = (boiler_prototype.target_temperature - input_fluid.default_temperature) /
            boiler_prototype.get_max_energy_usage()

        products = {
            {
                type = "fluid",
                name = input_fluidbox.filter.name,
                amount_per_second = acc.second_per_tick / (need_tick * input_fluid.heat_capacity),
            }
        }
        ingredients = {
            {
                type = "fluid",
                name = input_fluidbox.filter.name,
                amount_per_second = acc.second_per_tick / (need_tick * input_fluid.heat_capacity),
            }
        }
    else
        assert()
    end

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. boiler_prototype.name,
        localised_name = "<run>" .. boiler_prototype.name, --TODO
        sprite_path = "entity/" .. boiler_prototype.name,
        order = boiler_prototype.order,
        group_name = boiler_prototype.group.name,
        subgroup_name = boiler_prototype.subgroup.name,
        energy = 1,
        products = products,
        ingredients = ingredients,
        fixed_crafting_machine = tn.craft_to_typed_name(boiler_prototype),
    }

    return recipe
end

---@param generator_prototype LuaEntityPrototype
---@return VirtualRecipe
function M.create_generator_virtual(generator_prototype)
    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. generator_prototype.name,
        localised_name = "<run>" .. generator_prototype.name, --TODO
        sprite_path = "entity/" .. generator_prototype.name,
        order = generator_prototype.order,
        group_name = generator_prototype.group.name,
        subgroup_name = generator_prototype.subgroup.name,
        energy = 1,
        products = {},
        ingredients = {},
        fixed_crafting_machine = tn.craft_to_typed_name(generator_prototype),
    }

    return recipe
end

---@param burner_generator_prototype LuaEntityPrototype
---@return VirtualRecipe
function M.create_burner_generator_virtual(burner_generator_prototype)
    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. burner_generator_prototype.name,
        localised_name = "<run>" .. burner_generator_prototype.name, --TODO
        sprite_path = "entity/" .. burner_generator_prototype.name,
        order = burner_generator_prototype.order,
        group_name = burner_generator_prototype.group.name,
        subgroup_name = burner_generator_prototype.subgroup.name,
        energy = 1,
        products = {},
        ingredients = {},
        fixed_crafting_machine = tn.craft_to_typed_name(burner_generator_prototype),
    }

    return recipe
end

---@param reactor_prototype LuaEntityPrototype
---@return VirtualRecipe
function M.create_reactor_virtual(reactor_prototype)
    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. reactor_prototype.name,
        localised_name = "<run>" .. reactor_prototype.name, --TODO
        sprite_path = "entity/" .. reactor_prototype.name,
        order = reactor_prototype.order,
        group_name = reactor_prototype.group.name,
        subgroup_name = reactor_prototype.subgroup.name,
        energy = 1,
        products = {
            {
                type = "virtual_material",
                name = "<heat>",
                amount_per_second = reactor_prototype.get_max_energy_usage() * acc.second_per_tick,
            },
        },
        ingredients = {},
        fixed_crafting_machine = tn.craft_to_typed_name(reactor_prototype),
    }

    return recipe
end

---@param offshore_pump_prototype LuaEntityPrototype
---@return VirtualRecipe
function M.create_offshore_pump_virtual(offshore_pump_prototype)
    local fluidbox = offshore_pump_prototype.fluidbox_prototypes[1]
    local fluid_name = "water" -- TODO
    if fluidbox.filter then
        fluid_name = fluidbox.filter.name
    end

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. offshore_pump_prototype.name,
        localised_name = "<run>" .. offshore_pump_prototype.name, --TODO
        sprite_path = "entity/" .. offshore_pump_prototype.name,
        order = offshore_pump_prototype.order,
        group_name = offshore_pump_prototype.group.name,
        subgroup_name = offshore_pump_prototype.subgroup.name,
        energy = 1,
        products = {
            {
                type = "fluid",
                name = fluid_name,
                amount_per_second = offshore_pump_prototype.pumping_speed * acc.second_per_tick,
            }
        },
        ingredients = {},
        fixed_crafting_machine = tn.craft_to_typed_name(offshore_pump_prototype),
    }

    return recipe
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
            amount_per_second = acc.raw_product_to_amount(value, mineable.mining_time, 1, 1, 1),
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

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<minable>" .. resource_prototype.name,
        localised_name = "<minable>" .. resource_prototype.name, --TODO
        sprite_path = "entity/" .. resource_prototype.name,
        order = resource_prototype.order,
        group_name = resource_prototype.group.name,
        subgroup_name = resource_prototype.subgroup.name,
        energy = 1,
        products = products,
        ingredients = ingredients,
        resource_category = resource_prototype.resource_category,
    }

    return recipe
end

return M
