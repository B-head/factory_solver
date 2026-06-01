-- Prototype catalog queries: turning a category / recipe / fuel name into the
-- sorted list of machines, fuels, modules, beacons, or fluidbox filters that
-- back it, plus the hidden / unresearched predicates the pickers decorate with.
-- Pure read-side lookups over `prototypes` (no energy / quality math). Part of
-- the manage/accessor.lua family; reached through the accessor facade.

local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local tn = require "manage/typed_name"

local M = {}

---comment
---@param categories { [string]: true }
---@return string
function M.join_categories(categories)
    local name_list = {}
    for name, _ in pairs(categories) do
        flib_table.insert(name_list, name)
    end

    flib_table.sort(name_list)
    return flib_table.concat(name_list, "|")
end

---comment
---@param name string?
---@return LuaItemPrototype?
function M.get_module(name)
    if not name then
        return nil
    end

    local module = prototypes.item[name]
    if not module then
        return nil
    elseif module.type ~= "module" then
        return nil
    else
        return module
    end
end

---comment
---@param name string?
---@return LuaEntityPrototype?
function M.get_beacon(name)
    if not name then
        return nil
    end

    local beacon = prototypes.entity[name]
    if not beacon then
        return nil
    elseif beacon.type ~= "beacon" then
        return nil
    else
        return beacon
    end
end

---comment
---@param category_name string
---@return LuaEntityPrototype[]
function M.get_machines_in_category(category_name)
    local machines = prototypes.get_entity_filtered {
        { filter = "crafting-category", crafting_category = category_name },
    }
    machines = fs_util.sort_prototypes(fs_util.to_list(machines))
    return machines
end

---A crafting machine's engine-side `fixed_recipe` locks it to exactly one
---recipe; an unset (nil) lock means it can run any recipe in its categories.
---Reading `.fixed_recipe` is safe here because every caller passes a crafting
---machine (the `crafting-category` entity filter guarantees the subtype, and it
---reads back as nil on a machine without a lock).
---@param machine LuaEntityPrototype
---@param recipe_name string
---@return boolean
function M.machine_allows_recipe(machine, recipe_name)
    return machine.fixed_recipe == nil or machine.fixed_recipe == recipe_name
end

---Machines in a category usable as a *category-wide* default: those without a
---`fixed_recipe` lock. A fixed-recipe machine is recipe-specific and is offered
---only through `get_machines_for_recipe` for its own recipe, never as a category
---preset. Input is already sorted, so rebuild the sequence by hand (avoid
---`flib_table.filter`, which preserves keys and would leave gaps).
---@param category_name string
---@return LuaEntityPrototype[]
function M.get_general_machines_in_category(category_name)
    local ret = {}
    for _, machine in ipairs(M.get_machines_in_category(category_name)) do
        if machine.fixed_recipe == nil then
            ret[#ret + 1] = machine
        end
    end
    return ret
end

---comment
---@param category_name string
---@return LuaEntityPrototype[]
function M.get_machines_in_resource_category(category_name)
    local machines = prototypes.get_entity_filtered {
        { filter = "type", type = "mining-drill" },
    }
    machines = flib_table.filter(machines, function(value)
        return value.resource_categories[category_name]
    end)
    machines = fs_util.sort_prototypes(fs_util.to_list(machines))
    return machines
end

---Offshore pumps compatible with a tile-bound fluid. An empty fluid_box
---filter on the pump means "any fluid"; a set filter must match by name.
---@param fluid_name string
---@return LuaEntityPrototype[]
function M.get_offshore_pumps_for_fluid(fluid_name)
    local pumps = prototypes.get_entity_filtered {
        { filter = "type", type = "offshore-pump" },
    }
    pumps = flib_table.filter(pumps, function(value)
        local filter = M.get_fluidbox_filter_prototype(value, 1)
        return filter == nil or filter.name == fluid_name
    end)
    pumps = fs_util.sort_prototypes(fs_util.to_list(pumps))
    return pumps
end

---Labs that accept a particular science pack item (their lab_inputs contains
---the given name). Drives the machine picker for <research>{pack} virtual
---recipes.
---@param pack_name string
---@return LuaEntityPrototype[]
function M.get_labs_for_pack(pack_name)
    local labs = prototypes.get_entity_filtered {
        { filter = "type", type = "lab" },
    }
    labs = flib_table.filter(labs, function(value)
        for _, input in ipairs(value.lab_inputs or {}) do
            if input == pack_name then
                return true
            end
        end
        return false
    end)
    labs = fs_util.sort_prototypes(fs_util.to_list(labs))
    return labs
end

---comment
---@param recipe LuaRecipePrototype | VirtualRecipe
---@return LuaEntityPrototype[]
function M.get_machines_for_recipe(recipe)
    ---@diagnostic disable-next-line: param-type-mismatch
    if recipe.object_name then
        -- Honour each machine's engine-side `fixed_recipe` lock: keep only those
        -- with no lock (any recipe in the category) or locked to this recipe.
        local ret = {}
        for _, machine in ipairs(M.get_machines_in_category(recipe.category)) do
            if M.machine_allows_recipe(machine, recipe.name) then
                ret[#ret + 1] = machine
            end
        end
        return ret
    elseif recipe.fixed_crafting_machine then
        return { tn.typed_name_to_machine(recipe.fixed_crafting_machine) }
    elseif recipe.resource_category then
        return M.get_machines_in_resource_category(recipe.resource_category)
    elseif recipe.pumped_fluid_name then
        return M.get_offshore_pumps_for_fluid(recipe.pumped_fluid_name)
    elseif recipe.consumed_pack_name then
        return M.get_labs_for_pack(recipe.consumed_pack_name)
    else
        return assert()
    end
end

---comment
---@param fuel_categories { [string]: true } | string
---@return LuaItemPrototype[]
function M.get_fuels_in_categories(fuel_categories)
    local fuels = {}

    if type(fuel_categories) == "string" then
        fuel_categories = { [fuel_categories] = true }
    end

    for name, _ in pairs(fuel_categories) do
        local f = prototypes.get_item_filtered {
            { filter = "fuel-category", ["fuel-category"] = name },
        }
        fuels = flib_table.array_merge { fuels, fs_util.to_list(f) }
    end

    fuels = fs_util.sort_prototypes(fuels)
    return fuels
end

---comment
---@return LuaFluidPrototype[]
function M.get_any_fluid_fuels()
    local fluid_fuels = prototypes.get_fluid_filtered {
        { filter = "fuel-value", comparison = ">", value = 0 }
    }
    fluid_fuels = fs_util.sort_prototypes(fs_util.to_list(fluid_fuels))
    return fluid_fuels
end

---comment
---@param craft Craft
---@return boolean
function M.is_hidden(craft)
    ---@diagnostic disable: param-type-mismatch
    if craft.object_name == "LuaItemPrototype" then
        return craft.hidden
    elseif craft.object_name == "LuaFluidPrototype" then
        return craft.hidden
    elseif craft.object_name == "LuaRecipePrototype" then
        return craft.hidden
    elseif craft.object_name == "LuaEntityPrototype" then
        return craft.hidden
    elseif craft.type == "virtual_material" then
        return craft.hidden
    elseif craft.type == "virtual_recipe" then
        return craft.hidden
    else
        return assert()
    end
    ---@diagnostic enable: param-type-mismatch
end

---@param entity LuaEntityPrototype
---@param relation_to_recipes RelationToRecipes
---@return boolean
function M.entity_is_unresearched(entity, relation_to_recipes)
    local ret = true
    for _, value in ipairs(entity.items_to_place_this or {}) do
        local item = prototypes.item[value.name]
        local is_researched = 0 < relation_to_recipes.item[item.name].craftable_count
        ret = ret and not is_researched
    end
    return ret
end

---comment
---@param craft Craft
---@param relation_to_recipes RelationToRecipes
---@return boolean
function M.is_unresearched(craft, relation_to_recipes)
    ---@diagnostic disable: param-type-mismatch
    if craft.object_name == "LuaItemPrototype" then
        return not (0 < relation_to_recipes.item[craft.name].craftable_count)
    elseif craft.object_name == "LuaFluidPrototype" then
        return not (0 < relation_to_recipes.fluid[craft.name].craftable_count)
    elseif craft.object_name == "LuaRecipePrototype" then
        return not relation_to_recipes.enabled_recipe[craft.name]
    elseif craft.object_name == "LuaEntityPrototype" then
        return M.entity_is_unresearched(craft, relation_to_recipes)
    elseif craft.type == "virtual_material" then
        if craft.source_fluid_name then
            return not (0 < relation_to_recipes.fluid[craft.source_fluid_name].craftable_count)
        elseif craft.source_entity_name then
            return M.entity_is_unresearched(prototypes.entity[craft.source_entity_name], relation_to_recipes)
        else
            return false
        end
    elseif craft.type == "virtual_recipe" then
        return not relation_to_recipes.virtual_recipe_researched[craft.name]
    else
        return assert()
    end
    ---@diagnostic enable: param-type-mismatch
end

---comment
---@param machine LuaEntityPrototype
---@param index integer
---@return LuaFluidPrototype?
function M.get_fluidbox_filter_prototype(machine, index)
    if machine.fluid_energy_source_prototype then
        index = index + 1
    end
    local fluidbox = machine.fluidbox_prototypes[index]
    return fluidbox and fluidbox.filter
end

---Substrate (soil tile) names a plant entity can be planted on, derived
---dynamically from plant.autoplace_specification.tile_restriction. Used by
---the production-line UI to populate the substrate picker and by
---new_production_line to pick a default substrate for plant lines.
---
---Vanilla Space Age plants (yumako-tree, jellystem, tree-plant) list every
---player-plantable soil tile in tile_restriction including artificial-*
---variants that never appear in autoplace, so this list matches the
---agricultural tower's actual plot acceptance. Returns a sorted, deduped
---array; empty array when the machine is not a plant or has no restriction.
---@param machine LuaEntityPrototype
---@return string[]
function M.get_plant_substrate_tiles(machine)
    if machine.type ~= "plant" then return {} end
    local ap = machine.autoplace_specification
    if not ap or not ap.tile_restriction then return {} end
    local seen = {}
    local list = {}
    for _, r in ipairs(ap.tile_restriction) do
        if r.first and not seen[r.first] then
            seen[r.first] = true
            flib_table.insert(list, r.first)
        end
        if r.second and not seen[r.second] then
            seen[r.second] = true
            flib_table.insert(list, r.second)
        end
    end
    table.sort(list)
    return list
end

return M
