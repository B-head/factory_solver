local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local tn = require "manage/typed_name"

local M = {}

---comment
---@param crafts Craft[]
---@param filter_type FilterType
---@return TypedName
function M.get_default_preset(crafts, filter_type)
    local first = fs_util.find(crafts, function(value)
        return not acc.is_hidden(value)
    end)
    if first then
        return tn.craft_to_typed_name(crafts[first])
    elseif crafts[1] then
        return tn.craft_to_typed_name(crafts[1])
    else
        if filter_type == "item" then
            return tn.create_typed_name("item", "unknown-item")
        elseif filter_type == "fluid" then
            return tn.create_typed_name("fluid", "unknown-fluid")
        elseif filter_type == "machine" then
            return tn.create_typed_name("machine", "unknown-entity")
        else
            return assert()
        end
    end
end

---comment
---@param origin table<string, TypedName>?
---@return table<string, TypedName>
function M.create_fuel_presets(origin)
    local ret = {}
    if origin then
        ret = flib_table.deep_copy(origin)
    end

    for joined_category, fuel_categories in pairs(storage.virtuals.fuel_categories_dictionary) do
        tn.typed_name_migration(ret[joined_category])
        if tn.validate_typed_name(ret[joined_category]) then
            goto continue
        end

        local fuels = acc.get_fuels_in_categories(fuel_categories)
        ret[joined_category] = M.get_default_preset(fuels, "item")
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
    return M.get_default_preset(fluid_fuels, "fluid")
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
        ret[category_name] = M.get_default_preset(machines, "machine")
        ::continue::
    end

    return ret
end

---Preset machine per fluid name across all fluid-bearing tiles. Keyed by
---fluid name because the picker's compatible-pump set is determined by the
---fluid (tile.fluid.name), so two tiles producing the same fluid can share
---one preset entry.
---@param origin table<string, TypedName>?
---@return table<string, TypedName>
function M.create_pump_presets(origin)
    local ret = {}
    if origin then
        ret = flib_table.deep_copy(origin)
    end

    for _, tile in pairs(prototypes.tile) do
        if not tile.fluid then
            goto continue
        end
        local fluid_name = tile.fluid.name
        tn.typed_name_migration(ret[fluid_name])
        if tn.validate_typed_name(ret[fluid_name]) then
            goto continue
        end

        local pumps = acc.get_offshore_pumps_for_fluid(fluid_name)
        -- 0 件のケースも get_default_preset が `unknown-entity` センチネルに倒すので、
        -- そのまま preset を埋めて get_machine_preset の assert を満たす。
        ret[fluid_name] = M.get_default_preset(pumps, "machine")
        ::continue::
    end

    return ret
end

---Preset lab per science pack name. Keyed by the consumed pack item name
---because the picker's compatible-lab set is determined by which labs accept
---that pack in their lab_inputs.
---@param origin table<string, TypedName>?
---@return table<string, TypedName>
function M.create_lab_presets(origin)
    local ret = {}
    if origin then
        ret = flib_table.deep_copy(origin)
    end

    local pack_seen = {}
    for _, entity in pairs(prototypes.entity) do
        if entity.type == "lab" then
            for _, pack_name in ipairs(entity.lab_inputs or {}) do
                pack_seen[pack_name] = true
            end
        end
    end

    for pack_name, _ in pairs(pack_seen) do
        tn.typed_name_migration(ret[pack_name])
        if tn.validate_typed_name(ret[pack_name]) then
            goto continue
        end

        local labs = acc.get_labs_for_pack(pack_name)
        ret[pack_name] = M.get_default_preset(labs, "machine")
        ::continue::
    end

    return ret
end

---A recipe category is split into ingredient_count tiers because a single
---category-wide default machine cannot serve recipes whose item-ingredient count
---exceeds a low-`ingredient_count` machine in the same category. Each tier is one
---preset row keyed like the fuel presets' synthesized keys:
--- * base tier `category` -- every general (lock-free) machine is eligible (the
---   recipe fits even the smallest one). Same key the category used before tiers,
---   so existing presets keep working.
--- * tier `category|>ci` -- recipes needing more than ci item ingredients; only
---   machines whose cap exceeds ci are eligible.
---The number of tiers equals the count of distinct ingredient_count caps among the
---category's general machines (storage.virtuals.machine_ingredient_tiers), so a
---category whose machines share one cap (the common case) stays a single base tier.
---Exceeding the top cap leaves no machine, so it gets no tier (the recipe falls to
---the unknown-entity sentinel via get_machine_preset's fallback).
---@param category_name string
---@return { key: string, threshold: integer?, machines: LuaEntityPrototype[] }[]
function M.machine_preset_tiers(category_name)
    local machines = acc.get_general_machines_in_category(category_name)
    local caps = storage.virtuals.machine_ingredient_tiers[category_name] or {}

    local tiers = {
        { key = category_name, threshold = nil, machines = machines },
    }
    for i = 1, #caps - 1 do
        local threshold = caps[i]
        local eligible = {}
        for _, machine in ipairs(machines) do
            local cap = machine.ingredient_count
            if not cap or cap > threshold then
                eligible[#eligible + 1] = machine
            end
        end
        tiers[#tiers + 1] = {
            key = category_name .. "|>" .. threshold,
            threshold = threshold,
            machines = eligible,
        }
    end
    return tiers
end

---The machine preset key for a recipe's (category, item-ingredient count): the
---tier whose eligible set matches the recipe. Mirrors machine_preset_tiers' keys.
---@param category_name string
---@param item_count integer
---@return string
function M.machine_preset_key(category_name, item_count)
    local caps = storage.virtuals.machine_ingredient_tiers[category_name]
    if not caps then
        return category_name
    end
    -- The largest cap the recipe outgrows is the tier threshold; below the
    -- smallest cap (or no restrictive cap at all) the recipe uses the base key.
    local threshold
    for _, cap in ipairs(caps) do
        if cap < item_count then
            threshold = cap
        else
            break
        end
    end
    return threshold and (category_name .. "|>" .. threshold) or category_name
end

---comment
---@param origin table<string, TypedName>?
---@return table<string, TypedName>
function M.create_machine_presets(origin)
    local ret = {}
    if origin then
        ret = flib_table.deep_copy(origin)
    end

    -- One preset per (category, ingredient_count tier). Tier machine lists already
    -- exclude fixed_recipe machines (those are offered per-recipe by
    -- get_machines_for_recipe, never as a category default).
    for category_name, _ in pairs(prototypes.recipe_category) do
        for _, tier in ipairs(M.machine_preset_tiers(category_name)) do
            tn.typed_name_migration(ret[tier.key])
            if tn.validate_typed_name(ret[tier.key]) then
                goto continue
            end

            ret[tier.key] = M.get_default_preset(tier.machines, "machine")
            ::continue::
        end
    end

    return ret
end

---comment
---@param player_index integer
---@param machine_typed_name TypedName
---@return TypedName?
function M.get_fuel_preset(player_index, machine_typed_name)
    local player_data = storage.players[player_index]

    local machine = tn.typed_name_to_machine(machine_typed_name)

    local fixed_fuel = acc.try_get_fixed_fuel(machine)
    if fixed_fuel then
        return fixed_fuel
    end

    if acc.is_use_any_fluid_fuel(machine) then
        return assert(player_data.presets.fluid_fuel)
    end

    local fuel_categories = acc.try_get_fuel_categories(machine)
    if fuel_categories then
        local joined_category = acc.join_categories(fuel_categories)
        return assert(player_data.presets.fuel[joined_category])
    end

    return nil
end

---comment
---@param player_index integer
---@param recipe_typed_name TypedName
---@return TypedName
function M.get_machine_preset(player_index, recipe_typed_name)
    local player_data = storage.players[player_index]
    if recipe_typed_name.type == "virtual_recipe" then
        local recipe = storage.virtuals.recipe[recipe_typed_name.name]
        if recipe.fixed_crafting_machine then
            return recipe.fixed_crafting_machine
        elseif recipe.resource_category then
            return assert(player_data.presets.resource[recipe.resource_category])
        elseif recipe.pumped_fluid_name then
            return assert(player_data.presets.pump[recipe.pumped_fluid_name])
        elseif recipe.consumed_pack_name then
            return assert(player_data.presets.lab[recipe.consumed_pack_name])
        else
            return assert()
        end
    elseif recipe_typed_name.type == "recipe" then
        local recipe = prototypes.recipe[recipe_typed_name.name]
        -- Machine presets split each category by ingredient_count tier; pick the
        -- tier key whose eligible machines cover this recipe's item count.
        local key = M.machine_preset_key(recipe.category, acc.count_item_ingredients(recipe))
        local preset = player_data.presets.machine[key]
        -- Honour the tier default only if it can actually craft this recipe: a
        -- machine locked to a different recipe (engine fixed_recipe) or one whose
        -- ingredient_count cap is exceeded cannot. Fall back to the first eligible
        -- machine for this exact recipe, which resolves to the unknown-entity
        -- sentinel when none qualifies (a recipe no machine can craft becomes a
        -- visibly-broken row, not a silent swap).
        local machine = preset and prototypes.entity[preset.name]
        if machine and acc.machine_allows_recipe(machine, recipe.name)
            and acc.machine_within_ingredient_count(machine, recipe)
        then
            return preset
        end
        return M.get_default_preset(acc.get_machines_for_recipe(recipe), "machine")
    else
        return assert()
    end
end

return M
