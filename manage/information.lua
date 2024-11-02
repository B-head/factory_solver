local flib_table = require "__flib__/table"
local fs_util = require "fs_util"

local M = {}

---Create caches of relation to recipe for items, fluids and virtuals.
---@param force_index integer
---@return RelationToRecipes
function M.create_relation_to_recipes(force_index)
    local force = game.forces[force_index]
    local enabled_recipe = {} ---@type table<string, boolean>
    local items = {} ---@type table<string, RelationToRecipe>
    local fluids = {} ---@type table<string, RelationToRecipe>
    local virtuals = {} ---@type table<string, RelationToRecipe>

    for key, _ in pairs(prototypes.item) do
        items[key] = { enabled_recipe_used_count = 0, recipe_for_ingredient = {}, recipe_for_product = {} }
    end

    for key, _ in pairs(prototypes.fluid) do
        fluids[key] = { enabled_recipe_used_count = 0, recipe_for_ingredient = {}, recipe_for_product = {} }
    end

    for key, _ in pairs(storage.virtuals.material) do
        virtuals[key] = { enabled_recipe_used_count = 0, recipe_for_ingredient = {}, recipe_for_product = {} }
    end

    for _, recipe in pairs(force.recipes) do
        enabled_recipe[recipe.name] = recipe.enabled

        for _, value in ipairs(recipe.products) do
            local info
            if value.type == "item" then
                info = items[value.name]
            elseif value.type == "fluid" then
                info = fluids[value.name]
            else
                assert()
            end

            flib_table.insert(info.recipe_for_product, recipe.name)
            if recipe.enabled and not recipe.hidden then
                info.enabled_recipe_used_count = info.enabled_recipe_used_count + 1
            end
        end

        for _, value in ipairs(recipe.ingredients) do
            local info
            if value.type == "item" then
                info = items[value.name]
            elseif value.type == "fluid" then
                info = fluids[value.name]
            else
                assert()
            end

            flib_table.insert(info.recipe_for_ingredient, recipe.name)
            if recipe.enabled and not recipe.hidden then
                info.enabled_recipe_used_count = info.enabled_recipe_used_count + 1
            end
        end
    end

    for _, recipe in pairs(storage.virtuals.recipe) do
        for _, value in pairs(recipe.products) do
            local info
            if value.type == "item" then
                info = items[value.name]
            elseif value.type == "fluid" then
                info = fluids[value.name]
            elseif value.type == "virtual_material" then
                info = virtuals[value.name]
            else
                assert()
            end

            flib_table.insert(info.recipe_for_product, recipe.name)
            -- if recipe.enabled then -- TODO
            --     info.enabled_recipe_used_count = info.enabled_recipe_used_count + 1
            -- end
        end

        for _, value in pairs(recipe.ingredients) do
            local info
            if value.type == "item" then
                info = items[value.name]
            elseif value.type == "fluid" then
                info = fluids[value.name]
            elseif value.type == "virtual_material" then
                info = virtuals[value.name]
            else
                assert()
            end

            flib_table.insert(info.recipe_for_ingredient, recipe.name)
            -- if recipe.enabled then -- TODO
            --     info.enabled_recipe_used_count = info.enabled_recipe_used_count + 1
            -- end
        end
    end

    for _, machine in pairs(storage.virtuals.machine) do
        local value = machine.energy_source.fixed_fuel_typed_name
        if value then
            local info
            if value.type == "item" then
                info = items[value.name]
            elseif value.type == "fluid" then
                info = fluids[value.name]
            elseif value.type == "virtual_material" then
                info = virtuals[value.name]
            else
                assert()
            end

            local categories = machine.crafting_categories
            for _, recipe in pairs(storage.virtuals.recipe) do
                if categories[recipe.category] then
                    flib_table.insert(info.recipe_for_ingredient, recipe.name)
                end
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
            elseif 0 < relation_to_recipes.item[key].enabled_recipe_used_count then
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
            elseif 0 < relation_to_recipes.fluid[key].enabled_recipe_used_count then
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
---@param fuel_categories { [string]: boolean }
---@return string
function M.join_fuel_categories(fuel_categories)
    local joined_fuel_category = ""
    for name, _ in pairs(fuel_categories) do
        if joined_fuel_category ~= "" then
            joined_fuel_category = joined_fuel_category .. "|"
        end
        joined_fuel_category = joined_fuel_category .. name
    end
    return joined_fuel_category
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
        M.typed_name_migration(ret[category_name])
        if info.validate_typed_name(ret[category_name]) then
            goto continue
        end

        local fuels = info.get_fuels_in_categories(category_name)
        local first = fs_util.find(fuels, function(value)
            return not info.is_hidden(value)
        end)
        if first then
            ret[category_name] = info.craft_to_typed_name(fuels[first])
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

    local function add(category_name)
        M.typed_name_migration(ret[category_name])
        if info.validate_typed_name(ret[category_name]) then
            return
        end

        local machines = info.get_machines_in_category(category_name)
        local pos = fs_util.find(machines, function(value)
            return not info.is_hidden(value)
        end)
        if pos then
            local first = machines[pos]
            ret[category_name] = info.craft_to_typed_name(first)
        end
    end

    for category_name, _ in pairs(prototypes.recipe_category) do
        add(category_name)
    end

    for category_name, _ in pairs(storage.virtuals.crafting_categories) do
        add(category_name)
    end

    return ret
end

return M
