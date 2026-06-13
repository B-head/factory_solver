local flib_table = require "__flib__/table"
local acc = require "manage/accessor"
local tn = require "manage/typed_name"

local M = {}

---comment
---@return table<string, string[]>, table<string, string[]>, table<string, string[]>, table<string, string[]>, string[]
function M.cache_fuel_names()
    local any_fluid_fuels = flib_table.map(acc.get_any_fluid_fuels(), function(value)
        return value.name
    end)

    ---@param machines LuaEntityPrototype[]
    ---@return string[]
    local function collect_fluid_fuels(machines)
        local names = {}
        local seen = {}
        local include_any = false
        for _, machine in ipairs(machines) do
            if acc.is_use_any_fluid_fuel(machine) then
                include_any = true
            else
                local energy = machine.fluid_energy_source_prototype
                local filter = energy and energy.fluid_box.filter
                if filter and not seen[filter.name] then
                    seen[filter.name] = true
                    names[#names + 1] = filter.name
                end
            end
        end
        if include_any then
            for _, name in ipairs(any_fluid_fuels) do
                if not seen[name] then
                    seen[name] = true
                    names[#names + 1] = name
                end
            end
        end
        return names
    end

    local cache_crafting_fuels = {}
    local cache_crafting_fluid_fuels = {}
    for crafting_category_name, _ in pairs(prototypes.recipe_category) do
        local machines = acc.get_machines_in_category(crafting_category_name)

        local fuel_categories = {}
        for _, machine in ipairs(machines) do
            local res = acc.try_get_fuel_categories(machine)
            if not res then
                goto continue
            end
            for key, _ in pairs(res) do
                fuel_categories[key] = true
            end
            ::continue::
        end

        local fuels = acc.get_fuels_in_categories(fuel_categories)
        cache_crafting_fuels[crafting_category_name] = flib_table.map(fuels, function(value)
            return value.name
        end)
        cache_crafting_fluid_fuels[crafting_category_name] = collect_fluid_fuels(machines)
    end

    local cache_resource_fuels = {}
    local cache_resource_fluid_fuels = {}
    for resource_category_name, _ in pairs(prototypes.resource_category) do
        local machines = acc.get_machines_in_resource_category(resource_category_name)

        local fuel_categories = {}
        for _, machine in ipairs(machines) do
            local res = acc.try_get_fuel_categories(machine)
            if not res then
                goto continue
            end
            for key, _ in pairs(res) do
                fuel_categories[key] = true
            end
            ::continue::
        end

        local fuels = acc.get_fuels_in_categories(fuel_categories)
        cache_resource_fuels[resource_category_name] = flib_table.map(fuels, function(value)
            return value.name
        end)
        cache_resource_fluid_fuels[resource_category_name] = collect_fluid_fuels(machines)
    end

    return cache_crafting_fuels, cache_resource_fuels,
        cache_crafting_fluid_fuels, cache_resource_fluid_fuels,
        any_fluid_fuels
end

---Create caches of relation to recipe for items, fluids and virtuals.
---@param force_index integer
---@return RelationToRecipes
function M.create_relation_to_recipes(force_index)
    local force = game.forces[force_index]
    local enabled_recipe = {} ---@type table<string, boolean>
    local items = {} ---@type table<string, RelationToRecipe>
    local fluids = {} ---@type table<string, RelationToRecipe>
    local virtuals = {} ---@type table<string, RelationToRecipe>
    local recipes_by_category = {} ---@type table<string, string[]>

    local cache_crafting_fuels, cache_resource_fuels,
        cache_crafting_fluid_fuels, cache_resource_fluid_fuels,
        any_fluid_fuels = M.cache_fuel_names()

    ---@return RelationToRecipe
    local function create_relation_table()
        ---@type RelationToRecipe
        return { craftable_count = 0, recipe_for_ingredient = {}, recipe_for_product = {}, recipe_for_burnt_result = {}, fuel_consumer_categories = {}, fuel_consumer_virtual_recipes = {} }
    end

    ---@param filter_type FilterType
    ---@param name string
    ---@return RelationToRecipe
    local function get_info(filter_type, name)
        if filter_type == "item" then
            return items[name]
        elseif filter_type == "fluid" then
            return fluids[name]
        elseif filter_type == "virtual_material" then
            return virtuals[name]
        else
            return assert()
        end
    end

    -- A machine burning an item fuel emits that fuel's burnt_result (spent
    -- cell / ash), so a recipe consuming the fuel is also a *producer* of the
    -- residue. Register it under recipe_for_burnt_result -- NOT recipe_for_product
    -- -- so the picker can list it in a dedicated "spent fuel" section. Mixing it
    -- into recipe_for_product buries the real producers: for a common combustion
    -- residue (ash), every recipe runnable in a fuel-burning machine would flood
    -- the product list. craftable_count still counts it so a residue with no real
    -- recipe (depleted-uranium-fuel-cell) is not flagged unresearched.
    -- Fluid fuels have no burnt_result and never reach here.
    --
    -- A fuel item is registered as the producer of its burnt_result once per
    -- (recipe, category) it can burn in -- ~389k times for only ~116 distinct
    -- fuels on a pyanodon set -- so resolving burnt_result per registration is
    -- the single biggest cost in create_relation_to_recipes (~772ms of ~2.5s).
    -- Resolve it once up front into an immutable item -> spent-item NAME map.
    -- Deliberately not a lazily-grown cache and string-valued (not the
    -- LuaItemPrototype): it is built once and only read afterwards, so it stays
    -- correct -- and storage-safe -- if this function is ever split across ticks.
    -- An upvalue/lazy cache holding a LuaObject could not be carried across a
    -- tick boundary (LuaObjects are not storable) and would desync.
    local burnt_result_names = {} ---@type table<string, string>
    for name, item in pairs(prototypes.item) do
        local burnt = item.burnt_result
        if burnt then burnt_result_names[name] = burnt.name end
    end
    ---@param fuel_item_name string
    ---@param recipe_name string
    ---@param is_visible boolean
    local function register_burnt_result(fuel_item_name, recipe_name, is_visible)
        local burnt_name = burnt_result_names[fuel_item_name]
        if burnt_name then
            local info = get_info("item", burnt_name)
            flib_table.insert(info.recipe_for_burnt_result, recipe_name)
            if is_visible then
                info.craftable_count = info.craftable_count + 1
            end
        end
    end

    for key, _ in pairs(prototypes.item) do
        items[key] = create_relation_table()
    end
    for key, _ in pairs(prototypes.fluid) do
        fluids[key] = create_relation_table()
    end
    for key, _ in pairs(storage.virtuals.material) do
        virtuals[key] = create_relation_table()
    end

    for _, recipe in pairs(force.recipes) do
        enabled_recipe[recipe.name] = recipe.enabled

        -- Group real recipes by category so a fuel's consumers expand lazily
        -- (category -> recipes) instead of being flattened per (recipe, fuel).
        local cat_recipes = recipes_by_category[recipe.category]
        if not cat_recipes then
            cat_recipes = {}
            recipes_by_category[recipe.category] = cat_recipes
        end
        cat_recipes[#cat_recipes + 1] = recipe.name

        for _, value in ipairs(recipe.products) do
            local info = get_info(value.type, value.name)
            flib_table.insert(info.recipe_for_product, recipe.name)
            if recipe.enabled and not recipe.hidden then
                info.craftable_count = info.craftable_count + 1
            end
        end

        for _, value in ipairs(recipe.ingredients) do
            local info = get_info(value.type, value.name)
            flib_table.insert(info.recipe_for_ingredient, recipe.name)
        end

        -- recipe_for_fuel is no longer materialized per (recipe, fuel) -- that was
        -- the recipe x fuel product. Fuel consumers expand later from
        -- fuel_consumer_categories (built just below). The spent-fuel credit still
        -- runs here because it targets only the few fuels that have a burnt_result.
        for _, value in ipairs(cache_crafting_fuels[recipe.category]) do
            register_burnt_result(value, recipe.name, recipe.enabled and not recipe.hidden)
        end
    end

    -- Reverse cache_fuel_names' category -> fuel lists into each fuel material's
    -- fuel_consumer_categories. This is the sum of category fuel-list sizes
    -- (~1k on pyanodon), not the recipe x fuel product (~389k) the per-recipe
    -- recipe_for_fuel insert used to pay.
    for category, fuel_items in pairs(cache_crafting_fuels) do
        for _, fuel_name in ipairs(fuel_items) do
            local info = items[fuel_name]
            if info then
                info.fuel_consumer_categories[#info.fuel_consumer_categories + 1] = category
            end
        end
    end
    for category, fuel_fluids in pairs(cache_crafting_fluid_fuels) do
        for _, fuel_name in ipairs(fuel_fluids) do
            local info = fluids[fuel_name]
            if info then
                info.fuel_consumer_categories[#info.fuel_consumer_categories + 1] = category
            end
        end
    end

    -- Virtual recipes have no per-force `enabled` flag; their researched-ness
    -- is derived from the source entity (its `items_to_place_this` against the
    -- item table built above) and, for entity-less tile / resource virtuals,
    -- from `force.is_space_location_unlocked` against the planets that autoplace
    -- them. The result is cached per name on `virtual_recipe_researched` so
    -- accessor.is_unresearched can look it up without re-deriving (and without
    -- needing a force handle).
    ---@diagnostic disable-next-line: missing-fields
    local items_view = { item = items } ---@type RelationToRecipes
    local virtual_recipe_researched = {} ---@type table<string, boolean>
    ---@param recipe VirtualRecipe
    ---@return boolean
    local function compute_researched(recipe)
        if recipe.source_entity_name then
            local entity = prototypes.entity[recipe.source_entity_name]
            if acc.entity_is_unresearched(entity, items_view) then return false end
        end
        if recipe.source_planet_names then
            local any_unlocked = false
            for _, planet_name in ipairs(recipe.source_planet_names) do
                if force.is_space_location_unlocked(planet_name) then
                    any_unlocked = true
                    break
                end
            end
            if not any_unlocked then return false end
        end
        return true
    end

    for _, recipe in pairs(storage.virtuals.recipe) do
        local researched = compute_researched(recipe)
        virtual_recipe_researched[recipe.name] = researched
        local is_visible = researched and not recipe.hidden
        for _, value in pairs(recipe.products) do
            local info = get_info(value.type, value.name)
            flib_table.insert(info.recipe_for_product, recipe.name)
            if is_visible then
                info.craftable_count = info.craftable_count + 1
            end
        end

        for _, value in pairs(recipe.ingredients) do
            local info = get_info(value.type, value.name)
            flib_table.insert(info.recipe_for_ingredient, recipe.name)
        end

        if recipe.fixed_crafting_machine then
            local machine = tn.typed_name_to_machine(recipe.fixed_crafting_machine)

            local fixed_fuel = acc.try_get_fixed_fuel(machine)
            if fixed_fuel then
                local info = get_info(fixed_fuel.type, fixed_fuel.name)
                flib_table.insert(info.fuel_consumer_virtual_recipes, recipe.name)
                if fixed_fuel.type == "item" then
                    register_burnt_result(fixed_fuel.name, recipe.name, is_visible)
                end
            end

            if acc.is_use_any_fluid_fuel(machine) then
                for _, value in ipairs(any_fluid_fuels) do
                    local info = get_info("fluid", value)
                    flib_table.insert(info.fuel_consumer_virtual_recipes, recipe.name)
                end
            end

            local fuel_categories = acc.try_get_fuel_categories(machine)
            if fuel_categories then
                local fuels = acc.get_fuels_in_categories(fuel_categories)
                for _, value in ipairs(fuels) do
                    local info = get_info("item", value.name)
                    flib_table.insert(info.fuel_consumer_virtual_recipes, recipe.name)
                    register_burnt_result(value.name, recipe.name, is_visible)
                end
            end
        end

        if recipe.resource_category then
            for _, value in ipairs(cache_resource_fuels[recipe.resource_category]) do
                local info = get_info("item", value)
                flib_table.insert(info.fuel_consumer_virtual_recipes, recipe.name)
                register_burnt_result(value, recipe.name, is_visible)
            end

            for _, value in ipairs(cache_resource_fluid_fuels[recipe.resource_category]) do
                local info = get_info("fluid", value)
                flib_table.insert(info.fuel_consumer_virtual_recipes, recipe.name)
            end
        end
    end

    return {
        enabled_recipe = enabled_recipe,
        item = items,
        fluid = fluids,
        virtual_recipe = virtuals,
        virtual_recipe_researched = virtual_recipe_researched,
        recipes_by_category = recipes_by_category,
    }
end

---Expand a material's lazy fuel-consumer representation into the flat list of
---recipe names that burn it as fuel: real recipes via category indirection
---(fuel_consumer_categories x recipes_by_category) plus the directly-listed
---virtual recipes. The flat list is never stored -- it is the recipe x fuel
---product that dominated create_relation_to_recipes -- so the picker materializes
---it on demand for the single selected material.
---@param relation_to_recipes RelationToRecipes
---@param info RelationToRecipe
---@return string[]
function M.expand_fuel_consumers(relation_to_recipes, info)
    local result = {}
    local by_category = relation_to_recipes.recipes_by_category
    for _, category in ipairs(info.fuel_consumer_categories) do
        local recipes = by_category[category]
        if recipes then
            for _, recipe_name in ipairs(recipes) do
                result[#result + 1] = recipe_name
            end
        end
    end
    for _, recipe_name in ipairs(info.fuel_consumer_virtual_recipes) do
        result[#result + 1] = recipe_name
    end
    return result
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
    -- External source/sink recipes are split off into their own group counts so
    -- they populate the constraint picker's dedicated "External" tab and stop
    -- burying the genuine virtual recipes (boiler / mining / spoilage / ...) in
    -- the Virtual tab.
    local externals = {} ---@type table<string, GroupInfo>

    for key, _ in pairs(prototypes.item_group) do
        items[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
        fluids[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
        recipes[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
        virtuals[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
        externals[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
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
            elseif 0 < relation_to_recipes.item[key].craftable_count then
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
            elseif 0 < relation_to_recipes.fluid[key].craftable_count then
                fluid_group.researched_count = fluid_group.researched_count + 1
            else
                fluid_group.unresearched_count = fluid_group.unresearched_count + 1
            end
        end
    end

    for _, virtual_material in pairs(storage.virtuals.material) do
        local virtual_group = virtuals[virtual_material.group_name]
        if acc.is_hidden(virtual_material) then
            virtual_group.hidden_count = virtual_group.hidden_count + 1
        elseif acc.is_unresearched(virtual_material, relation_to_recipes) then
            virtual_group.unresearched_count = virtual_group.unresearched_count + 1
        else
            virtual_group.researched_count = virtual_group.researched_count + 1
        end
    end

    for _, virtual_recipe in pairs(storage.virtuals.recipe) do
        -- Route source/sink into the External group counts; everything else
        -- stays in the Virtual counts.
        local bucket = (virtual_recipe.is_source or virtual_recipe.is_sink) and externals or virtuals
        local virtual_group = bucket[virtual_recipe.group_name]
        if acc.is_hidden(virtual_recipe) then
            virtual_group.hidden_count = virtual_group.hidden_count + 1
        elseif acc.is_unresearched(virtual_recipe, relation_to_recipes) then
            virtual_group.unresearched_count = virtual_group.unresearched_count + 1
        else
            virtual_group.researched_count = virtual_group.researched_count + 1
        end
    end

    return { item = items, fluid = fluids, recipe = recipes, virtual_recipe = virtuals, external = externals }
end

return M
