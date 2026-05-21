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
            sprite_path = "utility/heat_exchange_indication",
            tooltip = "Heat energy",
            order = "a",
            group_name = "other",
            subgroup_name = "other",
            hidden = false,
        },
        ["<material-unknown>"] = {
            type = "virtual_material",
            name = "<material-unknown>",
            sprite_path = "utility/questionmark",
            tooltip = "Unknown virtual material",
            order = "z",
            group_name = "other",
            subgroup_name = "other",
            hidden = true,
        },
    }

    ---@type table<string, VirtualRecipe>
    local recipes = {}

    ---@type table<string, { [string]: true }>
    local fuel_categories_dictionary = {}

    local planet_index = M.build_planet_index()

    for _, entity in pairs(prototypes.entity) do
        local result_crafts = {}
        if entity.type == "rocket-silo" then
            result_crafts = M.create_rocket_silo_virtual(entity)
        elseif entity.type == "boiler" then
            result_crafts = M.create_boiler_virtual(entity)
        elseif entity.type == "generator" then
            result_crafts = M.create_generator_virtual(entity)
        elseif entity.type == "burner-generator" then
            result_crafts = M.create_burner_generator_virtual(entity)
        elseif entity.type == "reactor" then
            result_crafts = M.create_reactor_virtual(entity)
        elseif entity.type == "resource" then
            result_crafts = M.create_resource_virtual(entity, planet_index)
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

        local fuel_categories = acc.try_get_fuel_categories(entity)
        if fuel_categories then
            local joined_category = acc.join_categories(fuel_categories)
            fuel_categories_dictionary[joined_category] = fuel_categories
        end
    end

    for _, tile in pairs(prototypes.tile) do
        local result_crafts = {}
        if tile.fluid then
            result_crafts = M.create_offshore_tile_virtual(tile, planet_index)
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

    M.add_fluid_temperature_virtuals(materials, recipes)

    ---@type Virtuals
    return {
        material = materials,
        recipe = recipes,
        fuel_categories_dictionary = fuel_categories_dictionary,
    }
end

---Materialize a VirtualMaterial entry for each unique (fluid, single|range,
---temperature) tuple that appears as a temperature-tagged product or
---ingredient anywhere in the recipe set, including the freshly built virtual
---recipes. These entries surface in the constraint picker's virtual tab so a
---user can target a specific temperature variant. The name string matches
---the LP variable encoding so craft_to_typed_name can decode it back to a
---fluid TypedName with temperature info.
---@param materials table<string, VirtualMaterial>
---@param recipes table<string, VirtualRecipe>
function M.add_fluid_temperature_virtuals(materials, recipes)
    local function visit_products(products)
        for _, product in ipairs(products) do
            if product.type == "fluid" and product.temperature then
                M.register_fluid_temperature_single(materials, product.name, product.temperature)
            end
        end
    end
    local function visit_ingredients(ingredients)
        for _, ingredient in ipairs(ingredients) do
            if ingredient.type == "fluid" and ingredient.minimum_temperature then
                M.register_fluid_temperature_range(materials, ingredient.name,
                    ingredient.minimum_temperature, ingredient.maximum_temperature)
            end
        end
    end

    for _, recipe in pairs(prototypes.recipe) do
        visit_products(recipe.products)
        visit_ingredients(recipe.ingredients)
    end
    for _, recipe in pairs(recipes) do
        visit_products(recipe.products)
        visit_ingredients(recipe.ingredients)
    end
end

---@param materials table<string, VirtualMaterial>
---@param fluid_name string
---@param temperature number
function M.register_fluid_temperature_single(materials, fluid_name, temperature)
    local key = string.format("fluid/%s@%g", fluid_name, temperature)
    if materials[key] then return end
    local fluid_proto = prototypes.fluid[fluid_name]
    if not fluid_proto then return end
    ---@type VirtualMaterial
    materials[key] = {
        type = "virtual_material",
        name = key,
        sprite_path = "fluid/" .. fluid_name,
        elem_tooltip = { type = "fluid", name = fluid_name },
        order = fluid_proto.order .. string.format("@%020.6f", temperature),
        group_name = fluid_proto.group.name,
        subgroup_name = fluid_proto.subgroup.name,
        hidden = fluid_proto.hidden,
        source_fluid_name = fluid_name,
    }
end

---@param materials table<string, VirtualMaterial>
---@param fluid_name string
---@param min_temperature number
---@param max_temperature number
function M.register_fluid_temperature_range(materials, fluid_name, min_temperature, max_temperature)
    local fluid_proto = prototypes.fluid[fluid_name]
    if not fluid_proto then return end
    -- Clamp the FLT-sentinel values Factorio returns for unset ingredient bounds
    -- (e.g. -3.4e38 / 3.4e38) to the fluid's physical range.
    if min_temperature < fluid_proto.default_temperature then
        min_temperature = fluid_proto.default_temperature
    end
    if max_temperature > fluid_proto.max_temperature then
        max_temperature = fluid_proto.max_temperature
    end
    local key = string.format("fluid/%s@[%g,%g]", fluid_name, min_temperature, max_temperature)
    if materials[key] then return end
    ---@type VirtualMaterial
    materials[key] = {
        type = "virtual_material",
        name = key,
        sprite_path = "fluid/" .. fluid_name,
        elem_tooltip = { type = "fluid", name = fluid_name },
        order = fluid_proto.order .. string.format("@z[%020.6f,%020.6f]", min_temperature, max_temperature),
        group_name = fluid_proto.group.name,
        subgroup_name = fluid_proto.subgroup.name,
        hidden = fluid_proto.hidden,
        source_fluid_name = fluid_name,
    }
end

---comment
---@param value Product|Ingredient
---@param divisor number
---@return Product|Ingredient
function M.modify_product_or_ingredient(value, divisor)
    local ret = flib_table.shallow_copy(value)

    if ret.amount then
        ret.amount = ret.amount / divisor
    else
        ret.amount_max = ret.amount_max / divisor
        ret.amount_min = ret.amount_min / divisor
    end

    if ret.ignored_by_productivity then
        ret.ignored_by_productivity = ret.ignored_by_productivity / divisor
    end

    if ret.extra_count_fraction then
        ret.extra_count_fraction = ret.extra_count_fraction / divisor
    end

    return ret
end

---@param rocket_silo_prototype LuaEntityPrototype
---@return (VirtualRecipe|VirtualMaterial)[]
function M.create_rocket_silo_virtual(rocket_silo_prototype)
    local rocket_parts_required = assert(rocket_silo_prototype.rocket_parts_required)
    local has_rocket_launch_products = prototypes.get_item_filtered { { filter = "has-rocket-launch-products" } }

    -- Measured against vanilla; not derivable at runtime because times_to_blink
    -- is data-stage only and the flight phase ends on a physics condition.
    local time_to_quick_launch_per_tick = 1632

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
        for _, value in ipairs(rocket_part.ingredients) do
            local amount = M.modify_product_or_ingredient(value, energy)
            flib_table.insert(ingredients, amount)
        end

        if rocket_silo_prototype.launch_to_space_platforms then
            local rocket_entity_prototype = assert(rocket_silo_prototype.rocket_entity_prototype)
            local space_rocket_name = "<launch>" .. rocket_entity_prototype.name
            -- RocketSiloRocketPrototype.cargo_pod_entity is not surfaced at runtime,
            -- so we cannot follow the actual cargo pod per-silo. Use the vanilla
            -- Space Age "cargo-pod" entity for icon/tooltip/locale when present.
            -- The rocket entity prototype itself is not set up for GUI display
            -- (no entity/<name> sprite, no localized name), so fall back to the
            -- silo when cargo-pod is missing.
            local display_prototype = prototypes.entity["cargo-pod"] or rocket_silo_prototype
            local sprite_path = "entity/" .. display_prototype.name

            ---@type VirtualMaterial
            local space_rocket = {
                type = "virtual_material",
                name = space_rocket_name,
                sprite_path = sprite_path,
                elem_tooltip = { type = "entity", name = display_prototype.name },
                order = display_prototype.order,
                group_name = display_prototype.group.name,
                subgroup_name = display_prototype.subgroup.name,
                hidden = rocket_silo_prototype.hidden,
                source_entity_name = rocket_silo_prototype.name,
            }
            flib_table.insert(crafts, space_rocket)

            -- TODO Add note that power consumption is calculated to be higher.
            ---@type VirtualRecipe
            local recipe = {
                type = "virtual_recipe",
                name = string.format("<run>%s:%s:space-age", rocket_silo_prototype.name, rocket_part.name),
                sprite_path = sprite_path,
                elem_tooltip = { type = "recipe", name = rocket_part.name },
                order = rocket_silo_prototype.order,
                group_name = rocket_silo_prototype.group.name,
                subgroup_name = rocket_silo_prototype.subgroup.name,
                products = {
                    {
                        type = "virtual_material",
                        name = space_rocket_name,
                        amount = 1 / (energy * rocket_parts_required),
                        probability = 1,
                    }
                },
                ingredients = ingredients,
                fixed_crafting_machine = tn.craft_to_typed_name(rocket_silo_prototype),
                crafting_speed_cap = crafting_speed_cap,
                hidden = rocket_silo_prototype.hidden,
                source_entity_name = rocket_silo_prototype.name,
            }
            flib_table.insert(crafts, recipe)
        else
            for _, has_rocket_launch_product in pairs(has_rocket_launch_products) do
                local products = {}
                for _, value in ipairs(has_rocket_launch_product.rocket_launch_products) do
                    local amount = M.modify_product_or_ingredient(value, energy * rocket_parts_required)
                    flib_table.insert(products, amount)
                end

                ---@type ItemProduct
                local payload = {
                    type = "item",
                    name = has_rocket_launch_product.name,
                    amount = 1 / (energy * rocket_parts_required),
                    probability = 1,
                }
                local modify_ingredients = flib_table.deep_copy(ingredients)
                flib_table.insert(modify_ingredients, payload)

                -- TODO Add note that power consumption is calculated to be higher.
                ---@type VirtualRecipe
                local recipe = {
                    type = "virtual_recipe",
                    name = string.format("<run>%s:%s:%s", rocket_silo_prototype.name,
                        rocket_part.name, has_rocket_launch_product.name),
                    sprite_path = tn.get_sprite_path(products[1]),
                    elem_tooltip = { type = "recipe", name = rocket_part.name },
                    order = rocket_silo_prototype.order,
                    group_name = rocket_silo_prototype.group.name,
                    subgroup_name = rocket_silo_prototype.subgroup.name,
                    products = products,
                    ingredients = modify_ingredients,
                    fixed_crafting_machine = tn.craft_to_typed_name(rocket_silo_prototype),
                    crafting_speed_cap = crafting_speed_cap,
                    hidden = rocket_silo_prototype.hidden,
                    source_entity_name = rocket_silo_prototype.name,
                }
                flib_table.insert(crafts, recipe)
            end
        end
    end

    return crafts
end

---@param boiler_prototype LuaEntityPrototype
---@return (VirtualRecipe|VirtualMaterial)[]
function M.create_boiler_virtual(boiler_prototype)
    local input_filter = acc.get_fluidbox_filter_prototype(boiler_prototype, 1)
    local output_filter = acc.get_fluidbox_filter_prototype(boiler_prototype, 2)
    local boiler_mode = boiler_prototype.boiler_mode
    local max_energy_usage = boiler_prototype.get_max_energy_usage()

    ---@type LuaFluidPrototype[]
    local candidates = {}
    if input_filter then
        flib_table.insert(candidates, input_filter)
    else
        for _, fluid_prototype in pairs(prototypes.fluid) do
            flib_table.insert(candidates, fluid_prototype)
        end
    end

    local crafts = {}
    for _, input_fluid in ipairs(candidates) do
        -- "heat-fluid-inside" keeps the fluid in the input pipe and heats it
        -- up to its own max_temperature; output_fluid_box is unused so the
        -- filter on it does not apply. "output-to-separate-pipe" converts
        -- the input into the output filter (if any) at target_temperature.
        local output_fluid, effective_target
        if boiler_mode == "heat-fluid-inside" then
            output_fluid = input_fluid
            effective_target = input_fluid.max_temperature
        else
            output_fluid = output_filter or input_fluid
            effective_target = boiler_prototype.target_temperature
        end
        local delta_t = effective_target - input_fluid.default_temperature

        local in_amount, out_amount
        if delta_t > 0 and max_energy_usage > 0
            and input_fluid.heat_capacity > 0 and output_fluid.heat_capacity > 0
        then
            local need_tick = delta_t / max_energy_usage
            in_amount = acc.second_per_tick / (need_tick * input_fluid.heat_capacity)
            out_amount = acc.second_per_tick / (need_tick * output_fluid.heat_capacity)
        else
            -- Physically impossible to heat this fluid (input default >= target,
            -- non-positive heat capacity, or zero-power boiler). Emit a placeholder
            -- recipe so the picker still shows the entry, but with amount=0 so the
            -- LP sees an all-zero column and cannot pick it up.
            in_amount = 0
            out_amount = 0
        end

        ---@type VirtualRecipe
        local recipe = {
            type = "virtual_recipe",
            name = string.format("<run>%s:%s", boiler_prototype.name, input_fluid.name),
            sprite_path = "entity/" .. boiler_prototype.name,
            elem_tooltip = { type = "entity", name = boiler_prototype.name },
            order = boiler_prototype.order .. ":" .. input_fluid.order,
            group_name = boiler_prototype.group.name,
            subgroup_name = boiler_prototype.subgroup.name,
            products = {
                {
                    type = "fluid",
                    name = output_fluid.name,
                    amount = out_amount,
                    probability = 1,
                    temperature = effective_target,
                }
            },
            ingredients = {
                {
                    type = "fluid",
                    name = input_fluid.name,
                    amount = in_amount,
                }
            },
            fixed_crafting_machine = tn.craft_to_typed_name(boiler_prototype),
            hidden = boiler_prototype.hidden,
            source_entity_name = boiler_prototype.name,
        }
        flib_table.insert(crafts, recipe)
    end

    return crafts
end

---@param generator_prototype LuaEntityPrototype
---@return (VirtualRecipe|VirtualMaterial)[]
function M.create_generator_virtual(generator_prototype)
    -- Fluid input is wired via line.fuel_typed_name (see pre_solve.lua's
    -- is_use_fuel branch); acc.try_get_fixed_fuel populates the temperature
    -- range from the generator's filter and maximum_temperature, so no
    -- explicit ingredient list is needed here.
    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. generator_prototype.name,
        sprite_path = "entity/" .. generator_prototype.name,
        elem_tooltip = { type = "entity", name = generator_prototype.name },
        order = generator_prototype.order,
        group_name = generator_prototype.group.name,
        subgroup_name = generator_prototype.subgroup.name,
        products = {},
        ingredients = {},
        fixed_crafting_machine = tn.craft_to_typed_name(generator_prototype),
        hidden = generator_prototype.hidden,
        source_entity_name = generator_prototype.name,
    }

    return { recipe }
end

---@param burner_generator_prototype LuaEntityPrototype
---@return (VirtualRecipe|VirtualMaterial)[]
function M.create_burner_generator_virtual(burner_generator_prototype)
    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. burner_generator_prototype.name,
        sprite_path = "entity/" .. burner_generator_prototype.name,
        elem_tooltip = { type = "entity", name = burner_generator_prototype.name },
        order = burner_generator_prototype.order,
        group_name = burner_generator_prototype.group.name,
        subgroup_name = burner_generator_prototype.subgroup.name,
        products = {},
        ingredients = {},
        fixed_crafting_machine = tn.craft_to_typed_name(burner_generator_prototype),
        hidden = burner_generator_prototype.hidden,
        source_entity_name = burner_generator_prototype.name,
    }

    return { recipe }
end

---@param reactor_prototype LuaEntityPrototype
---@return (VirtualRecipe|VirtualMaterial)[]
function M.create_reactor_virtual(reactor_prototype)
    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. reactor_prototype.name,
        sprite_path = "entity/" .. reactor_prototype.name,
        elem_tooltip = { type = "entity", name = reactor_prototype.name },
        order = reactor_prototype.order,
        group_name = reactor_prototype.group.name,
        subgroup_name = reactor_prototype.subgroup.name,
        products = {
            {
                type = "virtual_material",
                name = "<heat>",
                amount = reactor_prototype.get_max_energy_usage() * acc.second_per_tick,
                probability = 1,
            },
        },
        ingredients = {},
        fixed_crafting_machine = tn.craft_to_typed_name(reactor_prototype),
        hidden = reactor_prototype.hidden,
        source_entity_name = reactor_prototype.name,
    }

    return { recipe }
end

---@class PlanetIndex
---@field entity_planets table<string, table<string, true>>
---@field tile_planets table<string, table<string, true>>
---@field control_planets table<string, table<string, true>>

---Scan every planet's map_gen_settings to build reverse maps from
---autoplaced entity/tile name (and from autoplace control name) back to
---the set of planet space-location names that reference it. Used by the
---resource / offshore-tile virtual builders to attach `source_planet_names`
---so the picker can gate them on `force.is_space_location_unlocked` at
---runtime. Planets without runtime support (no `prototypes.planet` table)
---return empty maps and every caller falls back to the unconditional path.
---@return PlanetIndex
function M.build_planet_index()
    local entity_planets = {} ---@type table<string, table<string, true>>
    local tile_planets = {}   ---@type table<string, table<string, true>>
    local control_planets = {} ---@type table<string, table<string, true>>

    -- Planets are surfaced under `prototypes.space_location` (LuaSpaceLocationPrototype);
    -- the planet subclass is the only kind that carries `map_gen_settings`, so we
    -- gate on its presence rather than on a `type == "planet"` discriminator.
    for planet_name, planet in pairs(prototypes.space_location or {}) do
        local mgs = planet.map_gen_settings
        if mgs then
            local autoplace_settings = mgs.autoplace_settings
            if autoplace_settings then
                local entity_settings = autoplace_settings["entity"]
                if entity_settings and entity_settings.settings then
                    for name, _ in pairs(entity_settings.settings) do
                        local set = entity_planets[name] or {}
                        set[planet_name] = true
                        entity_planets[name] = set
                    end
                end
                local tile_settings = autoplace_settings["tile"]
                if tile_settings and tile_settings.settings then
                    for name, _ in pairs(tile_settings.settings) do
                        local set = tile_planets[name] or {}
                        set[planet_name] = true
                        tile_planets[name] = set
                    end
                end
            end
            if mgs.autoplace_controls then
                for control_name, _ in pairs(mgs.autoplace_controls) do
                    local set = control_planets[control_name] or {}
                    set[planet_name] = true
                    control_planets[control_name] = set
                end
            end
        end
    end

    return {
        entity_planets = entity_planets,
        tile_planets = tile_planets,
        control_planets = control_planets,
    }
end

---Resolve a resource entity or fluid tile back to the set of planets that
---autoplace it, by name and by autoplace_control. Returns a sorted array
---to keep storage deterministic across save/load (pairs over the per-name
---set is not order-stable). Returns nil if no planet linkage was found —
---callers treat that as "no planet gate", preserving the historical
---always-researched behavior for vanilla-only and modded resources.
---@param name string
---@param autoplace_specification AutoplaceSpecification?
---@param name_to_planets table<string, table<string, true>>
---@param control_planets table<string, table<string, true>>
---@return string[]?
function M.collect_planets_for_prototype(name, autoplace_specification, name_to_planets, control_planets)
    local union = {}
    if name_to_planets[name] then
        for planet_name, _ in pairs(name_to_planets[name]) do
            union[planet_name] = true
        end
    end
    if autoplace_specification and autoplace_specification.control then
        local hit = control_planets[autoplace_specification.control]
        if hit then
            for planet_name, _ in pairs(hit) do
                union[planet_name] = true
            end
        end
    end

    local sorted = {}
    for planet_name, _ in pairs(union) do
        flib_table.insert(sorted, planet_name)
    end
    if #sorted == 0 then return nil end
    table.sort(sorted)
    return sorted
end

---@param resource_prototype LuaEntityPrototype
---@param planet_index PlanetIndex
---@return (VirtualRecipe|VirtualMaterial)[]
function M.create_resource_virtual(resource_prototype, planet_index)
    local mineable = resource_prototype.mineable_properties

    local products = {}
    for _, value in ipairs(mineable.products or {}) do
        local amount = M.modify_product_or_ingredient(value, mineable.mining_time)
        flib_table.insert(products, amount)
    end

    local ingredients = {}
    if mineable.required_fluid then
        ---@type Ingredient
        local amount = {
            type = "fluid",
            name = mineable.required_fluid,
            amount = mineable.fluid_amount,
        }
        flib_table.insert(ingredients, amount)
    end

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<mine>" .. resource_prototype.name,
        sprite_path = "entity/" .. resource_prototype.name,
        elem_tooltip = { type = "entity", name = resource_prototype.name },
        order = resource_prototype.order,
        group_name = resource_prototype.group.name,
        subgroup_name = resource_prototype.subgroup.name,
        products = products,
        ingredients = ingredients,
        resource_category = resource_prototype.resource_category,
        hidden = resource_prototype.hidden,
        source_planet_names = M.collect_planets_for_prototype(resource_prototype.name,
            resource_prototype.autoplace_specification,
            planet_index.entity_planets, planet_index.control_planets),
    }

    return { recipe }
end

---One virtual recipe per fluid-bearing tile. The picker dispatches by
---pumped_fluid_name to the set of offshore-pumps whose fluid_box filter
---matches (or is unset). Product amount is normalized to per-tick units of 1
---scaled by acc.second_per_tick, so multiplying by the picked pump's
---get_pumping_speed(quality) (per tick) inside acc.get_crafting_speed yields
---fluid/sec at the LP layer.
---@param tile_prototype LuaTilePrototype
---@param planet_index PlanetIndex
---@return (VirtualRecipe|VirtualMaterial)[]
function M.create_offshore_tile_virtual(tile_prototype, planet_index)
    local fluid_prototype = assert(tile_prototype.fluid)

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<pump>" .. tile_prototype.name,
        sprite_path = "tile/" .. tile_prototype.name,
        elem_tooltip = { type = "tile", name = tile_prototype.name },
        order = tile_prototype.order,
        group_name = tile_prototype.group.name,
        subgroup_name = tile_prototype.subgroup.name,
        products = {
            {
                type = "fluid",
                name = fluid_prototype.name,
                amount = acc.second_per_tick,
                probability = 1,
                temperature = fluid_prototype.default_temperature,
            }
        },
        ingredients = {},
        pumped_fluid_name = fluid_prototype.name,
        hidden = tile_prototype.hidden,
        source_planet_names = M.collect_planets_for_prototype(tile_prototype.name,
            tile_prototype.autoplace_specification,
            planet_index.tile_planets, planet_index.control_planets),
    }
    return { recipe }
end

return M
