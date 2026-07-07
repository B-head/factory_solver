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

    -- Filter-pinned fluids that no tile produces (e.g. a lubricant-filtered
    -- pump) are keyed `<pump-fluid>{fluid}` but still dispatch through
    -- pumped_fluid_name, so they need a preset under the fluid name too --
    -- otherwise get_machine_preset's assert trips for those recipes.
    for _, fluid in ipairs(acc.get_offshore_filter_only_fluids()) do
        local fluid_name = fluid.name
        tn.typed_name_migration(ret[fluid_name])
        if tn.validate_typed_name(ret[fluid_name]) then
            goto continue
        end

        local pumps = acc.get_offshore_pumps_for_fluid(fluid_name)
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

---Preset tower (agricultural-tower-type entity) per plant entity name.
---Mirrors create_pump_presets / create_lab_presets: a plant-growth recipe's
---candidate machine set is determined by the plant it grows (acc.
---get_towers_for_plant), so the remembered default is keyed by the plant's
---name rather than by recipe. A base/Space Age install has exactly one
---candidate (vanilla's own agricultural-tower, module_inventory_size == 0 --
---get_towers_for_plant lists it regardless), so get_default_preset picks it
---unambiguously; only an install with zero agricultural-tower-type entities
---at all (no Space Age, so no plant recipes exist either) would fall to the
---unknown-entity sentinel.
---@param origin table<string, TypedName>?
---@return table<string, TypedName>
function M.create_plant_tower_presets(origin)
    local ret = {}
    if origin then
        ret = flib_table.deep_copy(origin)
    end

    for _, entity in pairs(prototypes.entity) do
        if entity.type == "plant" then
            tn.typed_name_migration(ret[entity.name])
            if tn.validate_typed_name(ret[entity.name]) then
                goto continue
            end

            local towers = acc.get_towers_for_plant(entity)
            ret[entity.name] = M.get_default_preset(towers, "machine")
            ::continue::
        end
    end

    return ret
end

---Preset machine per real recipe that is craftable only by >=2 fixed_recipe
---machines (its category has no general machine -- storage.virtuals.shared_fixed_-
---recipes). Keyed by recipe name because the candidate set is recipe-specific (each
---fixed machine is locked to one recipe), exactly as the pump/lab presets key by the
---fluid/pack that determines their candidate set. Such recipes cannot be anchored by
---a category machine preset (which excludes fixed_recipe machines), so without this
---the chosen machine never persists across new lines.
---@param origin table<string, TypedName>?
---@return table<string, TypedName>
function M.create_fixed_recipe_presets(origin)
    local ret = {}
    if origin then
        ret = flib_table.deep_copy(origin)
    end

    for recipe_name, _ in pairs(storage.virtuals.shared_fixed_recipes) do
        tn.typed_name_migration(ret[recipe_name])
        if tn.validate_typed_name(ret[recipe_name]) then
            goto continue
        end

        local recipe = prototypes.recipe[recipe_name]
        ret[recipe_name] = M.get_default_preset(acc.get_machines_for_recipe(recipe), "machine")
        ::continue::
    end

    return ret
end

---A recipe-category *combination* (storage.virtuals.recipe_categories_dictionary
----- every distinct set of categories some real recipe actually has, a
---single-category recipe's combination being just that one category) is split
---into ingredient_count tiers because a single combination-wide default machine
---cannot serve recipes whose item-ingredient count exceeds a low-`ingredient_count`
---machine in the same combination. Each tier is one preset row keyed like the fuel
---presets' synthesized keys:
--- * base tier `key` -- every general (lock-free) machine across the combination's
---   categories is eligible (the recipe fits even the smallest one). Same key the
---   combination used before tiers, so existing presets keep working.
--- * tier `key|>ci` -- recipes needing more than ci item ingredients; only
---   machines whose cap exceeds ci are eligible.
---The number of tiers equals the count of distinct ingredient_count caps among the
---combination's general machines (storage.virtuals.machine_ingredient_tiers), so a
---combination whose machines share one cap (the common case) stays a single base
---tier. Exceeding the top cap leaves no machine, so it gets no tier (the recipe
---falls to the unknown-entity sentinel via get_machine_preset's fallback).
---@param key string joined recipe_categories_dictionary key (a bare category name for a single-category combination)
---@param categories string[] the combination's category set (recipe_categories_dictionary[key])
---@return { key: string, threshold: integer?, machines: LuaEntityPrototype[] }[]
function M.machine_preset_tiers(key, categories)
    local machines = acc.get_general_machines_in_categories(categories)
    local caps = storage.virtuals.machine_ingredient_tiers[key] or {}

    local tiers = {
        { key = key, threshold = nil, machines = machines },
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
            key = key .. "|>" .. threshold,
            threshold = threshold,
            machines = eligible,
        }
    end
    return tiers
end

---The machine preset key for a recipe's (category combination, item-ingredient
---count): the tier whose eligible set matches the recipe. Mirrors
---machine_preset_tiers' keys.
---@param key string joined recipe_categories_dictionary key
---@param item_count integer
---@return string
function M.machine_preset_key(key, item_count)
    local caps = storage.virtuals.machine_ingredient_tiers[key]
    if not caps then
        return key
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
    return threshold and (key .. "|>" .. threshold) or key
end

---comment
---@param origin table<string, TypedName>?
---@return table<string, TypedName>
function M.create_machine_presets(origin)
    local ret = {}
    if origin then
        ret = flib_table.deep_copy(origin)
    end

    -- One preset per (category combination, ingredient_count tier). Tier machine
    -- lists already exclude fixed_recipe machines (those are offered per-recipe by
    -- get_machines_for_recipe, never as a combination default).
    for key, categories in pairs(storage.virtuals.recipe_categories_dictionary) do
        for _, tier in ipairs(M.machine_preset_tiers(key, categories)) do
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
        elseif acc.get_recipe_plant(recipe) then
            return assert(player_data.presets.plant_tower[acc.get_recipe_plant(recipe).name])
        else
            return assert()
        end
    elseif recipe_typed_name.type == "recipe" then
        local recipe = prototypes.recipe[recipe_typed_name.name]
        local preset
        if storage.virtuals.shared_fixed_recipes[recipe.name] then
            -- Only fixed_recipe machines craft this recipe, so a category preset is
            -- vacuous; its default lives in the recipe-keyed fixed_recipe preset.
            preset = player_data.presets.fixed_recipe[recipe.name]
        else
            -- Machine presets split each category *combination* (the recipe's own
            -- set of categories, joined -- see recipe_categories_dictionary) by
            -- ingredient_count tier; pick the tier key whose eligible machines
            -- cover this recipe's item count.
            local combo_key = table.concat(acc.recipe_categories(recipe), "|")
            local key = M.machine_preset_key(combo_key, acc.count_item_ingredients(recipe))
            preset = player_data.presets.machine[key]
        end
        -- Honour the stored default only if it can actually craft this recipe: a
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
