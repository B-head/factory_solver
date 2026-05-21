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
        ret[category_name] = M.get_default_preset(machines, "machine")
        ::continue::
    end

    return ret
end

return M
