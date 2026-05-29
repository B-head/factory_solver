local flib_table = require "__flib__/table"
local acc = require "manage/accessor"
local tn = require "manage/typed_name"
local fs_log = require "fs_log"

local log = fs_log.for_module("virtual")

local M = {}

---@return Virtuals
function M.create_virtuals()
    ---@type table<string, VirtualMaterial>
    local materials = {
        ["<heat>"] = {
            type = "virtual_material",
            name = "<heat>",
            sprite_path = "utility/heat_exchange_indication",
            tooltip = { "factory-solver-heat-energy" },
            order = "a",
            group_name = "other",
            subgroup_name = "other",
            hidden = false,
        },
        ["<material-unknown>"] = {
            type = "virtual_material",
            name = "<material-unknown>",
            sprite_path = "utility/questionmark",
            tooltip = { "factory-solver-unknown-virtual-material" },
            order = "z",
            group_name = "other",
            subgroup_name = "other",
            hidden = true,
        },
        ["<research>"] = {
            type = "virtual_material",
            name = "<research>",
            sprite_path = "utility/technology_white",
            tooltip = { "factory-solver-research-progress" },
            order = "a",
            group_name = "other",
            subgroup_name = "other",
            hidden = false,
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
        elseif entity.type == "fusion-reactor" then
            result_crafts = M.create_fusion_reactor_virtual(entity)
        elseif entity.type == "fusion-generator" then
            result_crafts = M.create_fusion_generator_virtual(entity)
        elseif entity.type == "thruster" then
            result_crafts = M.create_thruster_virtual(entity)
        elseif entity.type == "resource" then
            result_crafts = M.create_resource_virtual(entity, planet_index)
        elseif entity.type == "plant" then
            result_crafts = M.create_plant_virtual(entity, planet_index)
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

    ---@type table<string, LuaEntityPrototype[]>
    local pack_to_labs = {}
    for _, entity in pairs(prototypes.entity) do
        if entity.type == "lab" then
            for _, pack_name in ipairs(entity.lab_inputs or {}) do
                if not pack_to_labs[pack_name] then
                    pack_to_labs[pack_name] = {}
                end
                flib_table.insert(pack_to_labs[pack_name], entity)
            end
        end
    end
    for pack_name, labs in pairs(pack_to_labs) do
        local pack_prototype = prototypes.item[pack_name]
        if pack_prototype then
            local result_crafts = M.create_lab_research_virtual(pack_prototype, labs)
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
    end

    local spoilage_recipe_count = 0
    for _, item in pairs(prototypes.item) do
        local result_crafts = M.create_spoilage_virtual(item)
        for _, craft in ipairs(result_crafts) do
            if craft.type == "virtual_material" then
                materials[craft.name] = craft
            elseif craft.type == "virtual_recipe" then
                recipes[craft.name] = craft
                spoilage_recipe_count = spoilage_recipe_count + 1
            else
                assert()
            end
        end
    end
    log.info("registered %d spoilage virtual recipes", spoilage_recipe_count)

    M.add_fluid_temperature_virtuals(materials, recipes)

    M.create_source_sink_virtuals(materials, recipes)

    ---@type Virtuals
    return {
        material = materials,
        recipe = recipes,
        fuel_categories_dictionary = fuel_categories_dictionary,
    }
end

---Materialize a VirtualMaterial entry for each unique (fluid, single|range,
---temperature) tuple that appears as a fluid product or ingredient anywhere
---in the recipe set, including the freshly built virtual recipes. Bare fluid
---slots (no temperature filter) are resolved through acc.resolve_bare_fluid_*
---using the exact same rules pre_solve applies before LP construction, so the
---picker exposes the LP variable that the constraint will actually bind to:
---bare products materialize as single-T at default_temperature, bare ingredients
---materialize as range-T spanning [default_temperature, max_temperature]. These
---entries surface in the constraint picker's virtual tab; the name string
---matches the LP variable encoding so craft_to_typed_name can decode it back
---to a fluid TypedName with temperature info.
---@param materials table<string, VirtualMaterial>
---@param recipes table<string, VirtualRecipe>
function M.add_fluid_temperature_virtuals(materials, recipes)
    local function visit_products(products)
        for _, product in ipairs(products) do
            if product.type == "fluid" then
                local t = acc.resolve_bare_fluid_product(product.name,
                    product.temperature, product.minimum_temperature, product.maximum_temperature)
                if t then
                    M.register_fluid_temperature_single(materials, product.name, t)
                end
            end
        end
    end
    local function visit_ingredients(ingredients)
        for _, ingredient in ipairs(ingredients) do
            if ingredient.type == "fluid" then
                local t, lo, hi = acc.resolve_bare_fluid_ingredient(ingredient.name,
                    ingredient.temperature, ingredient.minimum_temperature, ingredient.maximum_temperature)
                if t then
                    M.register_fluid_temperature_single(materials, ingredient.name, t)
                elseif lo and hi then
                    M.register_fluid_temperature_range(materials, ingredient.name, lo, hi)
                end
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
    if not fluid_proto or fluid_proto.parameter then return end
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
    if not fluid_proto or fluid_proto.parameter then return end
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

---Materialize user-controlled infinite source / sink virtual recipes for every
---item, fluid (bare + each registered temperature variant) and <heat>. A
---`<source>X` recipe has no ingredients and emits 1 X per craft; a `<sink>X`
---recipe consumes 1 X per craft and emits nothing. Both use the entity-unknown
---machine sentinel + crafting_speed_cap = 1 (same "no real machine, rate 1:1"
---shape as spoilage), so one recipe variable == one unit/sec of flow. Quality
---is left unstamped and follows the production line's recipe quality at solve
---time (accessor.raw_product_to_amount / raw_ingredient_to_amount). The LP cost
---asymmetry (source priced at source_cost, sink free) lives in create_problem;
---here the recipes are plain virtual recipes flagged is_source / is_sink.
---
---Fluid temperature follows the LP encoding: sources produce a single
---temperature (default_temperature plus every registered single variant), sinks
---consume a temperature range ([default, max] plus every registered range
---variant). The single/range split is read back out of the temperature-variant
---VirtualMaterial names add_fluid_temperature_virtuals already registered, so
---this must run after it. Recipe names are deterministic and the recipes table
---is name-keyed, so the bare default and a coincident registered variant
---dedupe automatically.
---@param materials table<string, VirtualMaterial>
---@param recipes table<string, VirtualRecipe>
function M.create_source_sink_virtuals(materials, recipes)
    local source_count, sink_count = 0, 0
    local function add_recipe(recipe)
        recipes[recipe.name] = recipe
        if recipe.is_source then
            source_count = source_count + 1
        else
            sink_count = sink_count + 1
        end
    end

    local entity_unknown_machine = { type = "machine", name = "entity-unknown", quality = "normal" }

    ---@param is_source boolean
    ---@param name string
    ---@param material_amount Product|Ingredient
    ---@param display { sprite_path: string, elem_tooltip: ElemID?, material_localised: LocalisedString, order: string, group_name: string, subgroup_name: string, hidden: boolean }
    local function build(is_source, name, material_amount, display)
        ---@type VirtualRecipe
        local recipe = {
            type = "virtual_recipe",
            name = name,
            sprite_path = display.sprite_path,
            elem_tooltip = display.elem_tooltip,
            tooltip = {
                "",
                { is_source and "factory-solver-source-recipe" or "factory-solver-sink-recipe",
                    display.material_localised },
                "\n",
                { "factory-solver-external-recipe-description" },
            },
            order = display.order,
            group_name = display.group_name,
            subgroup_name = display.subgroup_name,
            products = is_source and { material_amount } or {},
            ingredients = is_source and {} or { material_amount },
            fixed_crafting_machine = entity_unknown_machine,
            crafting_speed_cap = 1,
            hidden = display.hidden,
            is_source = is_source or nil,
            is_sink = (not is_source) or nil,
        }
        add_recipe(recipe)
    end

    for _, item in pairs(prototypes.item) do
        if not item.parameter then
            local display = {
                sprite_path = "item/" .. item.name,
                elem_tooltip = { type = "item", name = item.name },
                material_localised = item.localised_name,
                order = item.order,
                group_name = item.group.name,
                subgroup_name = item.subgroup.name,
                hidden = item.hidden,
            }
            build(true, "<source>item/" .. item.name,
                { type = "item", name = item.name, amount = 1, probability = 1 }, display)
            build(false, "<sink>item/" .. item.name,
                { type = "item", name = item.name, amount = 1 }, display)
        end
    end

    -- Read the registered temperature-variant materials back into per-fluid
    -- single-temperature and range sets, mirroring the names
    -- register_fluid_temperature_single / _range emit.
    local singles = {} ---@type table<string, table<string, number>>
    local ranges = {}   ---@type table<string, table<string, number[]>>
    for _, m in pairs(materials) do
        if m.source_fluid_name then
            local fname, t = string.match(m.name, "^fluid/(.-)@(%-?%d+%.?%d*)$")
            if fname then
                singles[fname] = singles[fname] or {}
                singles[fname][t] = tonumber(t)
            else
                local fn2, lo, hi = string.match(m.name, "^fluid/(.-)@%[(%-?%d+%.?%d*),(%-?%d+%.?%d*)%]$")
                if fn2 then
                    ranges[fn2] = ranges[fn2] or {}
                    ranges[fn2][lo .. "," .. hi] = { tonumber(lo), tonumber(hi) }
                end
            end
        end
    end

    for _, fluid in pairs(prototypes.fluid) do
        if not fluid.parameter then
            local display = {
                sprite_path = "fluid/" .. fluid.name,
                elem_tooltip = { type = "fluid", name = fluid.name },
                material_localised = fluid.localised_name,
                order = fluid.order,
                group_name = fluid.group.name,
                subgroup_name = fluid.subgroup.name,
                hidden = fluid.hidden,
            }

            local temp_set = {} ---@type table<string, number>
            temp_set[string.format("%g", fluid.default_temperature)] = fluid.default_temperature
            for k, v in pairs(singles[fluid.name] or {}) do temp_set[k] = v end
            for _, t in pairs(temp_set) do
                display.order = fluid.order .. string.format("@%020.6f", t)
                build(true, string.format("<source>fluid/%s@%g", fluid.name, t),
                    { type = "fluid", name = fluid.name, amount = 1, probability = 1, temperature = t },
                    display)
            end

            local range_set = {} ---@type table<string, number[]>
            range_set["default"] = { fluid.default_temperature, fluid.max_temperature }
            for k, v in pairs(ranges[fluid.name] or {}) do range_set[k] = v end
            for _, r in pairs(range_set) do
                local lo, hi = r[1], r[2]
                display.order = fluid.order .. string.format("@z[%020.6f,%020.6f]", lo, hi)
                build(false, string.format("<sink>fluid/%s@[%g,%g]", fluid.name, lo, hi),
                    { type = "fluid", name = fluid.name, amount = 1,
                        minimum_temperature = lo, maximum_temperature = hi },
                    display)
            end
        end
    end

    local heat = materials["<heat>"]
    if heat then
        local display = {
            sprite_path = heat.sprite_path,
            elem_tooltip = heat.elem_tooltip,
            material_localised = heat.tooltip,
            order = heat.order,
            group_name = heat.group_name,
            subgroup_name = heat.subgroup_name,
            hidden = heat.hidden,
        }
        build(true, "<source><heat>",
            { type = "virtual_material", name = "<heat>", amount = 1, probability = 1 }, display)
        build(false, "<sink><heat>",
            { type = "virtual_material", name = "<heat>", amount = 1 }, display)
    end

    log.info("registered %d source + %d sink virtual recipes", source_count, sink_count)
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

        -- Per-craft ratio relative to the boiler's per-second energy_usage:
        -- fluid_per_second = energy_per_second / (delta_t * heat_capacity).
        -- pre_solve multiplies these by acc.get_virtual_recipe_rates(boiler, q)
        -- = get_max_energy_usage(q) * second_per_tick, which gives the
        -- per-second flow at the requested quality. Quality scaling on the
        -- boiler is therefore honored through the engine's quality-aware API
        -- with no hardcoded multiplier.
        local in_amount, out_amount
        if delta_t > 0
            and input_fluid.heat_capacity > 0 and output_fluid.heat_capacity > 0
        then
            in_amount = 1 / (delta_t * input_fluid.heat_capacity)
            out_amount = 1 / (delta_t * output_fluid.heat_capacity)
        else
            -- Physically impossible to heat this fluid (input default >= target
            -- or non-positive heat capacity). Emit a placeholder recipe so the
            -- picker still shows the entry, but with amount=0 so the LP sees
            -- an all-zero column and cannot pick it up.
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
                -- Per-craft ratio of 1 against acc.get_virtual_recipe_rates(reactor, q)
                -- = get_max_energy_usage(q) * second_per_tick. Quality scaling
                -- on the reactor's heat output is honored through the engine.
                type = "virtual_material",
                name = "<heat>",
                amount = 1,
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

---Space Age fusion-reactor: not a `reactor` subtype, so it needs its own
---branch. Consumes a cold input fluid (e.g. fluoroketone-cold) plus burner
---fuel cells and emits a hot output fluid (e.g. fusion-plasma). Burner fuel
---is auto-injected by pre_solve via line.fuel_typed_name, so only the input
---fluid is listed here. Per-craft amounts are unit ratios; the per-second
---rate is acc.get_virtual_recipe_rates(fusion-reactor, q) =
---get_fluid_usage_per_tick(q) * second_per_tick, so quality scaling is
---honored through the engine (note: fusion-reactor's energy_usage is
---quality-invariant in vanilla — only fluid throughput scales — so
---get_fluid_usage_per_tick is the only correct proxy). The output fluid
---comes out at its prototype default_temperature because the output fluidbox
---carries no temperature filter.
---@param fusion_reactor_prototype LuaEntityPrototype
---@return (VirtualRecipe|VirtualMaterial)[]
function M.create_fusion_reactor_virtual(fusion_reactor_prototype)
    local input_filter = acc.get_fluidbox_filter_prototype(fusion_reactor_prototype, 1)
    local output_filter = acc.get_fluidbox_filter_prototype(fusion_reactor_prototype, 2)
    if not input_filter or not output_filter then
        return {}
    end

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. fusion_reactor_prototype.name,
        sprite_path = "entity/" .. fusion_reactor_prototype.name,
        elem_tooltip = { type = "entity", name = fusion_reactor_prototype.name },
        order = fusion_reactor_prototype.order,
        group_name = fusion_reactor_prototype.group.name,
        subgroup_name = fusion_reactor_prototype.subgroup.name,
        products = {
            {
                type = "fluid",
                name = output_filter.name,
                amount = 1,
                probability = 1,
                temperature = output_filter.default_temperature,
            },
        },
        ingredients = {
            {
                type = "fluid",
                name = input_filter.name,
                amount = 1,
            },
        },
        fixed_crafting_machine = tn.craft_to_typed_name(fusion_reactor_prototype),
        hidden = fusion_reactor_prototype.hidden,
        source_entity_name = fusion_reactor_prototype.name,
    }

    return { recipe }
end

---Space Age fusion-generator: consumes hot plasma (input fluidbox carries a
---minimum_temperature, e.g. fusion-plasma ≥1000°C) and emits a spent fluid
---(output filter at default_temperature) plus electrical power. The power
---output is surfaced via acc.is_generator → get_generator_power for the UI
---power column; only the fluid conversion enters the LP. Forwarding the
---input box's minimum_temperature on the ingredient steers pre_solve toward
---the hot temperature variant of the input fluid so the fusion-reactor's
---hot plasma output binds to it through add_fluid_temperature_virtuals.
---@param fusion_generator_prototype LuaEntityPrototype
---@return (VirtualRecipe|VirtualMaterial)[]
function M.create_fusion_generator_virtual(fusion_generator_prototype)
    local input_filter = acc.get_fluidbox_filter_prototype(fusion_generator_prototype, 1)
    local output_filter = acc.get_fluidbox_filter_prototype(fusion_generator_prototype, 2)
    if not input_filter or not output_filter then
        return {}
    end

    local input_box = fusion_generator_prototype.fluidbox_prototypes[1]
    local in_min_temp = input_box and input_box.minimum_temperature
    local in_max_temp = input_box and input_box.maximum_temperature

    -- Per-craft ratio of 1 against acc.get_virtual_recipe_rates(fusion-generator, q)
    -- = get_fluid_usage_per_tick(q) * second_per_tick. Quality scaling is
    -- honored through the engine.
    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. fusion_generator_prototype.name,
        sprite_path = "entity/" .. fusion_generator_prototype.name,
        elem_tooltip = { type = "entity", name = fusion_generator_prototype.name },
        order = fusion_generator_prototype.order,
        group_name = fusion_generator_prototype.group.name,
        subgroup_name = fusion_generator_prototype.subgroup.name,
        products = {
            {
                type = "fluid",
                name = output_filter.name,
                amount = 1,
                probability = 1,
                temperature = output_filter.default_temperature,
            },
        },
        ingredients = {
            {
                type = "fluid",
                name = input_filter.name,
                amount = 1,
                minimum_temperature = in_min_temp,
                maximum_temperature = in_max_temp,
            },
        },
        fixed_crafting_machine = tn.craft_to_typed_name(fusion_generator_prototype),
        hidden = fusion_generator_prototype.hidden,
        source_entity_name = fusion_generator_prototype.name,
    }

    return { recipe }
end

---Space Age thruster: consumes two input fluids (fuel + oxidizer) and produces
---no LP-modeled output. Thrust / effectivity is deliberately not modeled — the
---recipe only exists so the LP can size the fuel/oxidizer supply chain to
---sustain N thrusters at max_performance. Per-craft ratio is 1 per fluidbox;
---the per-second rate is acc.get_virtual_recipe_rates(thruster, q) =
---max_performance.fluid_usage * default_multiplier(q) * second_per_tick
---(vanilla: 120/s at normal, 300/s at legendary, matching the in-game tooltip).
---No runtime quality-aware API exists on thruster, so default_multiplier is
---applied manually inside get_virtual_recipe_rates. No crafting_speed_cap is
---set: thruster accepts no modules or beacons, so the only multiplier above 1
---is the quality scaling itself, and capping at 1 would silently undo it.
---@param thruster_prototype LuaEntityPrototype
---@return (VirtualRecipe|VirtualMaterial)[]
function M.create_thruster_virtual(thruster_prototype)
    local fuel_filter = acc.get_fluidbox_filter_prototype(thruster_prototype, 1)
    local oxidizer_filter = acc.get_fluidbox_filter_prototype(thruster_prototype, 2)
    local perf = thruster_prototype.max_performance
    if not fuel_filter or not oxidizer_filter or not perf then
        return {}
    end

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<run>" .. thruster_prototype.name,
        sprite_path = "entity/" .. thruster_prototype.name,
        elem_tooltip = { type = "entity", name = thruster_prototype.name },
        order = thruster_prototype.order,
        group_name = thruster_prototype.group.name,
        subgroup_name = thruster_prototype.subgroup.name,
        products = {},
        ingredients = {
            {
                type = "fluid",
                name = fuel_filter.name,
                amount = 1,
            },
            {
                type = "fluid",
                name = oxidizer_filter.name,
                amount = 1,
            },
        },
        fixed_crafting_machine = tn.craft_to_typed_name(thruster_prototype),
        hidden = thruster_prototype.hidden,
        source_entity_name = thruster_prototype.name,
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

---One virtual recipe per (plant, seed) pair. Vanilla plants have a single
---seed item with plant_result pointing back at the plant, so only one recipe
---is emitted per plant; modded plants may have several seeds, in which case
---each gets its own recipe with that seed as the sole ingredient.
---
---The plant entity itself is the fixed_crafting_machine: 1 craft = 1 plant
---growing through one full cycle = 1 occupied slot in some agricultural
---tower's radius. quantity_of_machines_required at the LP layer therefore
---represents the number of concurrent plant slots, not the number of towers.
---The tower's crane action time is not surfaced at runtime (only
---crane_energy_usage is) so it is intentionally not modeled; growth_ticks is
---the sole rate-limiting factor.
---
---Substrate (soil tile) selection is purely user metadata stored on the
---ProductionLine as substrate_tile_name; it does not flow through here.
---The picker UI reads plant.autoplace_specification.tile_restriction at
---render time to populate the substrate choices.
---
---harvest_emissions is baked into pollution_per_craft on the recipe; the
---per-second pollution layer in accessor.normalize_production_line picks
---this up and adds (pollution_per_craft * crafts_per_second * effectivity)
---to the line's pollution total.
---@param plant_prototype LuaEntityPrototype
---@param planet_index PlanetIndex
---@return (VirtualRecipe|VirtualMaterial)[]
function M.create_plant_virtual(plant_prototype, planet_index)
    local growth_ticks = plant_prototype.growth_ticks
    if not growth_ticks or growth_ticks <= 0 then
        return {}
    end
    local growth_seconds = growth_ticks / acc.second_per_tick

    local seed_items = prototypes.get_item_filtered {
        { filter = "plant-result", elem_filters = { { filter = "name", name = plant_prototype.name } } },
    }
    local seeds = {}
    for _, seed in pairs(seed_items) do
        flib_table.insert(seeds, seed)
    end
    if #seeds == 0 then
        return {}
    end
    table.sort(seeds, function(a, b) return a.name < b.name end)

    local mineable = plant_prototype.mineable_properties
    local products = {}
    for _, value in ipairs(mineable.products or {}) do
        local amount = M.modify_product_or_ingredient(value, growth_seconds)
        flib_table.insert(products, amount)
    end

    -- harvest_emissions["pollution"] is per-harvest (emitted once on each
    -- crane harvest cycle). Normalize to per-second by dividing by the
    -- growth cycle length, matching the per-second product/ingredient
    -- scaling above. accessor.normalize_production_line then multiplies by
    -- (crafting_speed / crafting_energy) — both 1 for plant virtual recipes
    -- at base — and by effectivity.pollution, so module/beacon pollution
    -- boosts still scale this contribution symmetrically with energy-source
    -- pollution on conventional machines.
    local harvest_pollution = nil
    if plant_prototype.harvest_emissions then
        local raw = plant_prototype.harvest_emissions["pollution"]
        if raw then
            harvest_pollution = raw / growth_seconds
        end
    end

    local source_planet_names = M.collect_planets_for_prototype(plant_prototype.name,
        plant_prototype.autoplace_specification,
        planet_index.entity_planets, planet_index.control_planets)

    local fixed_machine = tn.craft_to_typed_name(plant_prototype)

    local crafts = {}
    for _, seed in ipairs(seeds) do
        ---@type Ingredient
        local seed_ingredient = {
            type = "item",
            name = seed.name,
            amount = 1 / growth_seconds,
        }

        ---@type VirtualRecipe
        local recipe = {
            type = "virtual_recipe",
            name = string.format("<grow>%s:%s", plant_prototype.name, seed.name),
            sprite_path = "entity/" .. plant_prototype.name,
            elem_tooltip = { type = "entity", name = plant_prototype.name },
            order = plant_prototype.order .. ":" .. seed.order,
            group_name = plant_prototype.group.name,
            subgroup_name = plant_prototype.subgroup.name,
            products = products,
            ingredients = { seed_ingredient },
            fixed_crafting_machine = fixed_machine,
            pollution_per_craft = harvest_pollution,
            hidden = plant_prototype.hidden,
            source_entity_name = plant_prototype.name,
            source_planet_names = source_planet_names,
        }
        flib_table.insert(crafts, recipe)
    end

    return crafts
end

---One virtual recipe per fluid-bearing tile. The picker dispatches by
---pumped_fluid_name to the set of offshore-pumps whose fluid_box filter
---matches (or is unset). Product amount is a per-craft ratio of 1; the
---per-second rate is acc.get_virtual_recipe_rates(pump, q) =
---get_pumping_speed(q) * second_per_tick, giving fluid/sec at the LP layer.
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
                amount = 1,
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

---One virtual recipe per spoilable item (`spoil_ticks > 0` with a non-nil
---`spoil_result`). Rate-only 1:1 conversion: the user picks the rate in the
---production line and the LP treats it like any other recipe at 1
---ingredient -> 1 product. No time normalization happens here -- spoilage
---in Factorio is shelf-life, not throughput, and modelling it as
---spoil_ticks/sec would silently assume a buffer size of 1 that nobody
---would actually use.
---
---Display follows the Plant virtual recipe convention: there is no
---natural "machine" for spoilage (items just decay in any inventory), so
---we plug `entity-unknown` into `fixed_crafting_machine` to satisfy the
---machine pipeline and flip `is_spoilage = true` so solution_editor can
---hide the machine button the same way it already hides the plant
---button. The recipe icon, group, subgroup and order all follow the
---spoil_result so the picker lists spoilage recipes next to whatever
---they decay into; tried `utility/quantity-time` first but that name
---does not exist in Factorio 2.0 utility sprites.
---@param item_prototype LuaItemPrototype
---@return (VirtualRecipe|VirtualMaterial)[]
function M.create_spoilage_virtual(item_prototype)
    -- spoil_ticks is exposed as a quality-aware getter
    -- (LuaItemPrototype.get_spoil_ticks(quality)), not a bare property — same
    -- shape as LuaItemPrototype.get_durability. Non-spoilable items raise on
    -- direct `.spoil_ticks` access because LuaObject __index rejects unknown
    -- keys, so we probe through pcall. quality has no effect on the
    -- conversion stoichiometry (1:1 either way), so we use "normal" purely
    -- to satisfy the API contract.
    local quality_normal = prototypes.quality["normal"]
    if not quality_normal then return {} end
    local ok_ticks, spoil_ticks = pcall(item_prototype.get_spoil_ticks, quality_normal)
    if not ok_ticks or not spoil_ticks or spoil_ticks <= 0 then return {} end

    -- spoil_result is fixed per item (does not vary with quality), but the
    -- field may still be absent for items that don't spoil; same pcall guard.
    local ok_result, spoil_result = pcall(function() return item_prototype.spoil_result end)
    if not ok_result or not spoil_result then return {} end

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<spoil>" .. item_prototype.name,
        sprite_path = "item/" .. item_prototype.name,
        elem_tooltip = { type = "item", name = item_prototype.name },
        order = item_prototype.order .. ":" .. spoil_result.name,
        group_name = item_prototype.group.name,
        subgroup_name = item_prototype.subgroup.name,
        products = {
            {
                type = "item",
                name = spoil_result.name,
                amount = 1,
                probability = 1,
            }
        },
        ingredients = {
            {
                type = "item",
                name = item_prototype.name,
                amount = 1,
            }
        },
        fixed_crafting_machine = {
            type = "machine",
            name = "entity-unknown",
            quality = "normal",
        },
        crafting_speed_cap = 1,
        hidden = item_prototype.hidden or spoil_result.hidden,
        is_spoilage = true,
    }
    return { recipe }
end

---One virtual recipe per science pack item that at least one lab accepts.
---The picker dispatches by consumed_pack_name to the set of labs whose
---lab_inputs contains the pack. The per-craft 1 pack → 1 <research>
---invariant is what the recipe encodes; the per-second rate is composed
---by two independent axes outside this file:
---  * acc.get_virtual_recipe_rates folds in researching_speed and divides by
---    bonuses.research_unit_energy (seconds per research unit), so a
---    vanilla lab + automation-science-pack settles at 1/30 craft/sec.
---  * acc.apply_lab_input_productivity_to_ingredient scales the
---    pack-side ingredient by science_pack_drain_rate_percent and by the
---    pack's quality durability, keeping the pack/research ratio
---    independent from the speed axis.
---@param pack_prototype LuaItemPrototype
---@param labs LuaEntityPrototype[]
---@return (VirtualRecipe|VirtualMaterial)[]
function M.create_lab_research_virtual(pack_prototype, labs)
    local all_labs_hidden = true
    for _, lab in ipairs(labs) do
        if not lab.hidden then
            all_labs_hidden = false
            break
        end
    end

    ---@type VirtualRecipe
    local recipe = {
        type = "virtual_recipe",
        name = "<research>" .. pack_prototype.name,
        sprite_path = "item/" .. pack_prototype.name,
        elem_tooltip = { type = "item", name = pack_prototype.name },
        order = pack_prototype.order,
        group_name = pack_prototype.group.name,
        subgroup_name = pack_prototype.subgroup.name,
        products = {
            {
                type = "virtual_material",
                name = "<research>",
                amount = 1,
                probability = 1,
            }
        },
        ingredients = {
            {
                type = "item",
                name = pack_prototype.name,
                amount = 1,
            }
        },
        consumed_pack_name = pack_prototype.name,
        hidden = pack_prototype.hidden or all_labs_hidden,
    }
    return { recipe }
end

return M
