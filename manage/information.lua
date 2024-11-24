local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local tn = require "manage/typed_name"

local M = {}

---comment
---@return table<string, string[]>, table<string, string[]>, string[]
function M.cache_fuel_names()
    local cache_crafting_fuels = {}
    for crafting_category_name, _ in pairs(prototypes.recipe_category) do
        local machines = acc.get_machines_in_category(crafting_category_name)

        local fuel_categories = {}
        for _, machine in pairs(machines) do
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
    end

    local cache_resource_fuels = {}
    for resource_category_name, _ in pairs(prototypes.resource_category) do
        local machines = acc.get_machines_in_resource_category(resource_category_name)

        local fuel_categories = {}
        for _, machine in pairs(machines) do
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
    end

    local any_fluid_fuels = flib_table.map(acc.get_any_fluid_fuels(), function(value)
        return value.name
    end)

    return cache_crafting_fuels, cache_resource_fuels, any_fluid_fuels
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

    local cache_crafting_fuels, cache_resource_fuels, any_fluid_fuels = M.cache_fuel_names()

    ---@return RelationToRecipe
    local function create_relation_table()
        ---@type RelationToRecipe
        return { craftable_count = 0, recipe_for_ingredient = {}, recipe_for_product = {}, recipe_for_fuel = {} }
    end

    ---@param filter_type FilterType|"research-progress"
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

        for _, value in ipairs(cache_crafting_fuels[recipe.category]) do
            local info = get_info("item", value) -- TODO fluid fuels
            flib_table.insert(info.recipe_for_fuel, recipe.name)
        end
    end

    for _, recipe in pairs(storage.virtuals.recipe) do
        for _, value in pairs(recipe.products) do
            local info = get_info(value.type, value.name)
            flib_table.insert(info.recipe_for_product, recipe.name)
            if true then -- TODO
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
                flib_table.insert(info.recipe_for_fuel, recipe.name)
            end

            if acc.is_use_any_fluid_fuel(machine) then
                for _, value in ipairs(any_fluid_fuels) do
                    local info = get_info("fluid", value)
                    flib_table.insert(info.recipe_for_fuel, recipe.name)
                end
            end

            local fuel_categories = acc.try_get_fuel_categories(machine)
            if fuel_categories then
                local fuels = acc.get_fuels_in_categories(fuel_categories)
                for _, value in ipairs(fuels) do
                    local info = get_info("item", value.name)
                    flib_table.insert(info.recipe_for_fuel, recipe.name)
                end
            end
        end

        if recipe.resource_category then
            for _, value in ipairs(cache_resource_fuels[recipe.resource_category]) do
                local info = get_info("item", value) -- TODO fluid fuels
                flib_table.insert(info.recipe_for_fuel, recipe.name)
            end
        end
    end

    return { enabled_recipe = enabled_recipe, item = items, fluid = fluids, virtual_recipe = virtuals }
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

    for key, _ in pairs(prototypes.item_group) do
        items[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
        fluids[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
        recipes[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
        virtuals[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
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
        virtual_group.researched_count = virtual_group.researched_count + 1
        -- TODO hidden and unreserched
    end

    for _, virtual_recipe in pairs(storage.virtuals.recipe) do
        local virtual_group = virtuals[virtual_recipe.group_name]
        virtual_group.researched_count = virtual_group.researched_count + 1
        -- TODO hidden and unreserched
    end

    return { item = items, fluid = fluids, recipe = recipes, virtual_recipe = virtuals }
end

---comment
---@param origin table<string, TypedName>?
---@return table<string, TypedName>
function M.create_fuel_presets(origin)
    local ret = {}
    if origin then
        ret = flib_table.deep_copy(origin)
    end

    for category_name, _ in pairs(prototypes.fuel_category) do
        tn.typed_name_migration(ret[category_name])
        if tn.validate_typed_name(ret[category_name]) then
            goto continue
        end

        local fuels = acc.get_fuels_in_categories(category_name)
        local first = fs_util.find(fuels, function(value)
            return not acc.is_hidden(value)
        end)
        if first then
            ret[category_name] = tn.craft_to_typed_name(fuels[first])
        end
        ::continue::
    end

    return ret
end

---comment
---@param origin TypedName?
---@return TypedName
function M.create_fluid_fuel_preset(origin)
    tn.typed_name_migration(origin)
    if tn.validate_typed_name(origin) then
        return assert(origin)
    end

    local fluid_fuels = acc.get_any_fluid_fuels()
    local first = fs_util.find(fluid_fuels, function(value)
        return not acc.is_hidden(value)
    end)
    if first then
        return tn.craft_to_typed_name(fluid_fuels[first])
    else
        return tn.create_typed_name("fluid", "unknown-fluid")
    end
end

---comment
---@param origin table<string, TypedName>?
---@return table<string, TypedName>
function M.create_resource_presets(origin)
    local ret = {}
    if origin then
        ret = flib_table.deep_copy(origin)
    end

    for category_name, _ in pairs(prototypes.resource_category) do
        tn.typed_name_migration(ret[category_name])
        if tn.validate_typed_name(ret[category_name]) then
            goto continue
        end

        local machines = acc.get_machines_in_resource_category(category_name)
        local first = fs_util.find(machines, function(value)
            return not acc.is_hidden(value)
        end)
        if first then
            ret[category_name] = tn.craft_to_typed_name(machines[first])
        end
        ::continue::
    end

    return ret
end

---comment
---@param origin table<string, TypedName>?
---@return table<string, TypedName>
function M.create_machine_presets(origin)
    local ret = {}
    if origin then
        ret = flib_table.deep_copy(origin)
    end

    for category_name, _ in pairs(prototypes.recipe_category) do
        tn.typed_name_migration(ret[category_name])
        if tn.validate_typed_name(ret[category_name]) then
            goto continue
        end

        local machines = acc.get_machines_in_category(category_name)
        local pos = fs_util.find(machines, function(value)
            return not acc.is_hidden(value)
        end)
        if pos then
            local first = machines[pos]
            ret[category_name] = tn.craft_to_typed_name(first)
        end
        ::continue::
    end

    return ret
end

return M
