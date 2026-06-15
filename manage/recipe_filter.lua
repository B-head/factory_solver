-- Pure recipe-picker candidate filtering. Extracted from ui/production_line_adder
-- so the heavy, GUI-free part of the picker (temperature compatibility, the
-- de-dup / parameter-recipe drop) can be unit-tested and profiled headless --
-- the picker's per-open cost is dominated by this filter plus the engine-side
-- LuaGuiElement.add, and only the former is reachable without a connected
-- player. Depends only on manage/accessor, manage/typed_name and the global
-- prototype / storage tables, so it carries no GUI dependency.

local acc = require "manage/accessor"
local tn = require "manage/typed_name"

local M = {}

---[a_lo,a_hi] ⊆ [b_lo,b_hi]
local function range_subset(a_lo, a_hi, b_lo, b_hi)
    return b_lo <= a_lo and a_hi <= b_hi
end

---True if any of `machines` can burn `fluid_name` as fuel while accepting the
---reference temperature range [ref_lo, ref_hi] (reference produces, machine
---consumes, so reference ⊆ acceptance). A filterless fluid-fuel machine accepts
---any fluid at any temperature; a machine that doesn't burn this fluid is
---ignored. If no machine burns it at all the recipe is unrelated to this fuel,
---so it is kept (not filtered).
---@param machines LuaEntityPrototype[]
---@param fluid_name string
---@param ref_lo number
---@param ref_hi number
---@return boolean
local function any_machine_burns_fluid_at(machines, fluid_name, ref_lo, ref_hi)
    local matched = false
    for _, machine in ipairs(machines) do
        if acc.is_use_any_fluid_fuel(machine) then
            return true
        end
        local fuel = acc.try_get_fixed_fuel(machine)
        if fuel and fuel.type == "fluid" and fuel.name == fluid_name then
            matched = true
            if range_subset(ref_lo, ref_hi, fuel.minimum_temperature, fuel.maximum_temperature) then
                return true
            end
        end
    end
    return not matched
end

---True if `recipe` can connect to the referenced fluid at the reference's
---temperature for `kind`, using the bridge rule producer_range ⊆ consumer_range.
---EVERY matching fluid slot is checked and the recipe is kept if ANY connects:
---a recipe may carry the same fluid at several temperatures (e.g. a split that
---outputs the fluid both hot and cold), and any compatible slot makes it useful.
---A slot with no well-defined range, or a recipe with no matching slot, counts
---as compatible (never filtered). `recipe` is a real LuaRecipePrototype or a
---plain-table VirtualRecipe; `reference` is known to carry a temperature.
---@param recipe LuaRecipePrototype | VirtualRecipe
---@param reference TypedName
---@param kind string
---@param category_fuel_cache table<string, boolean> memoises the fuel verdict per crafting category
---@return boolean
local function recipe_temperature_compatible(recipe, reference, kind, category_fuel_cache)
    local fluid_name = reference.name
    local ref_lo = reference.minimum_temperature
    local ref_hi = reference.maximum_temperature

    -- Does the candidate slot range [c_lo,c_hi] connect to the reference?
    local function slot_ok(c_lo, c_hi)
        if c_lo == nil then return true end
        if kind == "product" then
            -- candidate produces, reference consumes
            return range_subset(c_lo, c_hi, ref_lo, ref_hi)
        end
        -- ingredient / fuel: reference produces, candidate consumes
        return range_subset(ref_lo, ref_hi, c_lo, c_hi)
    end

    if kind == "product" then
        local matched = false
        for _, p in ipairs(recipe.products) do
            if p.type == "fluid" and p.name == fluid_name then
                matched = true
                -- A product comes out at a single temperature; bare resolves to
                -- the degenerate [default, default].
                if slot_ok(acc.resolve_bare_fluid_product(fluid_name, p.temperature, p.temperature)) then
                    return true
                end
            end
        end
        return not matched
    elseif kind == "ingredient" then
        local matched = false
        for _, ing in ipairs(recipe.ingredients) do
            if ing.type == "fluid" and ing.name == fluid_name then
                matched = true
                local c_lo, c_hi
                if ing.temperature ~= nil then
                    c_lo, c_hi = ing.temperature, ing.temperature
                else
                    c_lo, c_hi = acc.resolve_bare_fluid_ingredient(fluid_name,
                        ing.minimum_temperature, ing.maximum_temperature)
                end
                if slot_ok(c_lo, c_hi) then
                    return true
                end
            end
        end
        return not matched
    elseif kind == "fuel" then
        -- The recipe burns `fluid_name` as fuel through one or more machines; keep
        -- it if ANY machine it can actually run on accepts the reference
        -- temperature. A virtual recipe with a fixed machine pins exactly one; a
        -- virtual mining recipe runs on any drill in its resource category. Guard
        -- the field reads: a real LuaRecipePrototype (userdata) throws on unknown
        -- keys, while a VirtualRecipe is a plain table (object_name nil).
        --
        -- The per-category verdict is memoised — a fluid-fuel machine in a common
        -- category (e.g. "crafting") would otherwise re-scan the same machine list
        -- for every recipe in it. The cache covers only machines usable by *every*
        -- recipe in the category (no fixed_recipe lock); resource recipes never
        -- have locks, so that is their whole answer. A real recipe whose general
        -- machines all reject the fuel can still be served by a machine the engine
        -- locks to *this* recipe, so those are checked separately (rare, unmemoised).
        if recipe.object_name == nil and recipe.fixed_crafting_machine then
            local machine = tn.typed_name_to_machine(recipe.fixed_crafting_machine)
            return any_machine_burns_fluid_at({ machine }, fluid_name, ref_lo, ref_hi)
        end

        local is_real = recipe.object_name ~= nil
        local cache_key
        if is_real then
            cache_key = "crafting/" .. recipe.category
        elseif recipe.resource_category then
            cache_key = "resource/" .. recipe.resource_category
        else
            return true
        end

        local cached = category_fuel_cache[cache_key]
        if cached == nil then
            local machines
            if is_real then
                machines = acc.get_general_machines_in_category(recipe.category)
            else
                machines = acc.get_machines_in_resource_category(recipe.resource_category)
            end
            cached = any_machine_burns_fluid_at(machines, fluid_name, ref_lo, ref_hi)
            category_fuel_cache[cache_key] = cached
        end
        if cached then return true end

        if is_real then
            for _, machine in ipairs(acc.get_machines_in_category(recipe.category)) do
                if machine.fixed_recipe == recipe.name
                    and any_machine_burns_fluid_at({ machine }, fluid_name, ref_lo, ref_hi) then
                    return true
                end
            end
        end
        return false
    end
    return true
end

---Filter the recipe picker's candidate names: drop blueprint-parameter recipes
---(placeholders that must never be buildable), de-duplicate (relation.lua lists
---a recipe once per matching fluid slot, so a recipe carrying the same fluid at
---several temperatures appears multiple times), and — when the reference carries
---a temperature — drop recipes whose referenced-fluid slot can't connect to it.
---@param reference TypedName
---@param recipe_names string[]
---@param kind string
---@return string[]
function M.pickable_recipe_names(reference, recipe_names, kind)
    local filter_temp = reference.type == "fluid" and reference.minimum_temperature ~= nil
    local out = {}
    local seen = {}
    local category_fuel_cache = {} ---@type table<string, boolean>
    for _, name in ipairs(recipe_names) do
        if not seen[name] then
            seen[name] = true
            local recipe = storage.virtuals.recipe[name] or prototypes.recipe[name]
            local keep = recipe ~= nil
            -- Blueprint parameter placeholders (parameter-0..9) must never appear.
            -- Only a real LuaRecipePrototype carries `parameter`; virtuals never do.
            if keep and recipe.object_name ~= nil and recipe.parameter then
                keep = false
            end
            if keep and filter_temp then
                keep = recipe_temperature_compatible(recipe, reference, kind, category_fuel_cache)
            end
            if keep then
                out[#out + 1] = name
            end
        end
    end
    return out
end

return M
