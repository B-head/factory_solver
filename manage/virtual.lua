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
        local result_crafts = {}
        if entity.type == "rocket-silo" then
            result_crafts = M.create_rocket_silo_virtual(entity)
        elseif entity.type == "boiler" then
            local recipe = M.create_boiler_virtual(entity)
            recipes[recipe.name] = recipe
        elseif entity.type == "generator" then
            local recipe = M.create_generator_virtual(entity)
            recipes[recipe.name] = recipe
        elseif entity.type == "burner-generator" then
            local recipe = M.create_burner_generator_virtual(entity)
            recipes[recipe.name] = recipe
        elseif entity.type == "reactor" then
            local recipe = M.create_reactor_virtual(entity)
            recipes[recipe.name] = recipe
        elseif entity.type == "resource" then
            local recipe = M.create_resource_virtual(entity)
            recipes[recipe.name] = recipe
        end

        for _, craft in ipairs(result_crafts) do
            if craft.type == "virtual_material" then
                materials[craft.name] = craft
            elseif craft.type == "virtual_recipe" then
                recipes[craft.name] = craft
            else
                assert()
            end
        end
    end

    for _, tile in pairs(prototypes.tile) do
        local result_crafts = {}
        if tile.fluid then
            result_crafts = M.create_offshore_tile_virtual(tile)
        end

        for _, craft in ipairs(result_crafts) do
            if craft.type == "virtual_material" then
                materials[craft.name] = craft
            elseif craft.type == "virtual_recipe" then
                recipes[craft.name] = craft
            else
                assert()
            end
        end
    end

    return {
        material = materials,
        recipe = recipes,
    }
end

---@param rocket_silo_prototype LuaEntityPrototype
---@return (VirtualRecipe|VirtualMaterial)[]
function M.create_rocket_silo_virtual(rocket_silo_prototype)
    local rocket_parts_required = assert(rocket_silo_prototype.rocket_parts_required)
    local has_rocket_launch_products = prototypes.get_item_filtered { { filter = "has-rocket-launch-products" } }

    local time_to_quick_launch_per_tick = 1632 -- TODO calculate

    local rocket_parts
    if rocket_silo_prototype.fixed_recipe then
        rocket_parts = { prototypes.recipe[rocket_silo_prototype.fixed_recipe] }
    else
        local filters = {}
        for key, _ in pairs(rocket_silo_prototype.crafting_categories) do
            flib_table.insert(filters, { filter = "category", category = key })
        end
        rocket_parts = prototypes.get_recipe_filtered(filters)
    end

    local crafts = {}
    for _, rocket_part in pairs(rocket_parts) do
        local energy = rocket_part.energy
        local crafting_speed_cap = energy * rocket_parts_required * acc.second_per_tick / time_to_quick_launch_per_tick

        local ingredients = {}
        for _, value in pairs(rocket_part.ingredients) do
            local amount = {
                type = value.type,
                name = value.name,
                amount_per_second = acc.raw_ingredient_to_amount(value, energy, 1),
            }
            flib_table.insert(ingredients, amount)
        end

        if script.active_mods["space-age"] ~= nil then -- TODO use launch_to_space_platforms
            local rocket_entity_prototype = assert(rocket_silo_prototype.rocket_entity_prototype)
            local space_rocket_name = "<launch>" .. rocket_entity_prototype.name
            -- local sprite_path = "entity/" .. rocket_entity_prototype.name -- TODO
            local sprite_path = "entity/" .. rocket_silo_prototype.name

            ---@type VirtualMaterial
            local space_rocket = {
                type = "virtual_material",
                name = space_rocket_name,
                localised_name = "Space rocket",
                sprite_path = sprite_path,
                order = rocket_entity_prototype.order,
                group_name = rocket_entity_prototype.group.name,
                subgroup_name = rocket_entity_prototype.subgroup.name,
            }
            flib_table.insert(crafts, space_rocket)

            -- TODO Add note that power consumption is calculated to be higher.
            ---@type VirtualRecipe
            local recipe = {
                type = "virtual_recipe",
                name = string.format("<run>%s:%s:space-age", rocket_silo_prototype.name, rocket_part.name),
                localised_name = { "item-name.space-science-pack" },
                sprite_path = sprite_path,
                order = rocket_silo_prototype.order,
                group_name = rocket_silo_prototype.group.name,
                subgroup_name = rocket_silo_prototype.subgroup.name,
                products = {
                    {
                        type = "virtual_material",
                        name = space_rocket_name,
                        amount_per_second = 1 / (energy * rocket_parts_required),
                    }
                },
                ingredients = ingredients,
                fixed_crafting_machine = tn.craft_to_typed_name(rocket_silo_prototype),
                crafting_speed_cap = crafting_speed_cap,
            }
            flib_table.insert(crafts, recipe)
        else
            for _, has_rocket_launch_product in pairs(has_rocket_launch_products) do
                local products = {}
                for _, value in pairs(has_rocket_launch_product.rocket_launch_products) do
                    local amount = {
                        type = value.type, -- TODO research-progress
                        name = value.name,
                        amount_per_second = acc.raw_product_to_amount(value, energy * rocket_parts_required, 1, 1),
                    }
                    flib_table.insert(products, amount)
                end

                -- TODO Add note that power consumption is calculated to be higher.
                ---@type VirtualRecipe
                local recipe = {
                    type = "virtual_recipe",
                    name = string.format("<run>%s:%s:%s", rocket_silo_prototype.name,
                        rocket_part.name, has_rocket_launch_product.name),
                    localised_name = { "item-name.space-science-pack" },
                    sprite_path = tn.get_sprite_path(products[1]),
                    order = rocket_silo_prototype.order,
                    group_name = rocket_silo_prototype.group.name,
                    subgroup_name = rocket_silo_prototype.subgroup.name,
                    products = products,
                    ingredients = ingredients,
                    fixed_crafting_machine = tn.craft_to_typed_name(rocket_silo_prototype),
                    crafting_speed_cap = crafting_speed_cap,
                }
                flib_table.insert(crafts, recipe)
            end
        end
    end

    return crafts
end

---@param boiler_prototype LuaEntityPrototype
---@return VirtualRecipe
function M.create_boiler_virtual(boiler_prototype)
    local input_fluid = assert(acc.get_fluidbox_filter_prototype(boiler_prototype, 1)) -- TODO any fluid
    local output_fluid = acc.get_fluidbox_filter_prototype(boiler_prototype, 2) or input_fluid

    if not input_fluid then
        return {}
    end

    -- TODO virtual temperatue
    local need_tick = (boiler_prototype.target_temperature - input_fluid.default_temperature) /
        boiler_prototype.get_max_energy_usage()

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. boiler_prototype.name,
        localised_name = "<run>" .. boiler_prototype.name, --TODO
        sprite_path = "entity/" .. boiler_prototype.name,
        order = boiler_prototype.order,
        group_name = boiler_prototype.group.name,
        subgroup_name = boiler_prototype.subgroup.name,
        products = {
            {
                type = "fluid",
                name = output_fluid.name,
                amount_per_second = acc.second_per_tick / (need_tick * output_fluid.heat_capacity),
            }
        },
        ingredients = {
            {
                type = "fluid",
                name = input_fluid.name,
                amount_per_second = acc.second_per_tick / (need_tick * input_fluid.heat_capacity),
            }
        },
        fixed_crafting_machine = tn.craft_to_typed_name(boiler_prototype),
    }

    return recipe
end

---@param generator_prototype LuaEntityPrototype
---@return VirtualRecipe
function M.create_generator_virtual(generator_prototype)
    -- TODO virtual temperatue
    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. generator_prototype.name,
        localised_name = "<run>" .. generator_prototype.name, --TODO
        sprite_path = "entity/" .. generator_prototype.name,
        order = generator_prototype.order,
        group_name = generator_prototype.group.name,
        subgroup_name = generator_prototype.subgroup.name,
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

---@param resource_prototype LuaEntityPrototype
---@return VirtualRecipe
function M.create_resource_virtual(resource_prototype)
    local mineable = resource_prototype.mineable_properties

    local products = {}
    for _, value in pairs(mineable.products) do
        local data = {
            type = value.type,
            name = value.name,
            amount_per_second = acc.raw_product_to_amount(value, mineable.mining_time, 1, 1),
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
        name = "<mine>" .. resource_prototype.name,
        localised_name = "<mine>" .. resource_prototype.name, --TODO
        sprite_path = "entity/" .. resource_prototype.name,
        order = resource_prototype.order,
        group_name = resource_prototype.group.name,
        subgroup_name = resource_prototype.subgroup.name,
        products = products,
        ingredients = ingredients,
        resource_category = resource_prototype.resource_category,
    }

    return recipe
end

---@param tile_prototype LuaTilePrototype
---@return (VirtualRecipe|VirtualMaterial)[]
function M.create_offshore_tile_virtual(tile_prototype)
    local fluid_prototype = assert(tile_prototype.fluid)
    local offshore_pump_prototypes = prototypes.get_entity_filtered {
        { filter = "type", type = "offshore-pump" }
    }

    local crafts = {}
    for _, offshore_pump_prototype in pairs(offshore_pump_prototypes) do
        local fluidbox_filter = acc.get_fluidbox_filter_prototype(offshore_pump_prototype, 1)
        if fluidbox_filter and fluidbox_filter.name ~= fluid_prototype.name then
            goto continue
        end

        ---@type VirtualRecipe
        local recipe = {
            type = "virtual_recipe",
            name = string.format("<pump>%s:%s", offshore_pump_prototype.name, tile_prototype.name),
            localised_name = "<pump>" .. tile_prototype.name, --TODO
            sprite_path = "tile/" .. tile_prototype.name,
            order = tile_prototype.order,
            group_name = tile_prototype.group.name,
            subgroup_name = tile_prototype.subgroup.name,
            products = {
                {
                    type = "fluid",
                    name = fluid_prototype.name,
                    amount_per_second = offshore_pump_prototype.pumping_speed,
                }
            },
            ingredients = {},
            fixed_crafting_machine = tn.craft_to_typed_name(offshore_pump_prototype),
        }
        flib_table.insert(crafts, recipe)
        ::continue::
    end

    return crafts
end

return M
