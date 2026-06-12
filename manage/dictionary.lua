local flib_dictionary = require "__flib__/dictionary"

-- Locale dictionaries for the constraint adder's name filter. flib_dictionary
-- requests the engine translate each prototype's localised_name once per
-- language, so the filter can match the displayed name (not just the internal
-- name) without us touching the low-level on_string_translated plumbing.
--
-- Dictionary names mirror the constraint picker's filter types: "item",
-- "fluid", "recipe", and a single "virtual" that covers both the Virtual and
-- External tabs (both are drawn from storage.virtuals, and their names never
-- collide). Keys are the prototype / virtual `name`; values are the raw
-- LocalisedString. Case folding for the actual comparison happens on the read
-- side (ui/constraint_adder.lua) via helpers.multilingual_to_lower.
local M = {}

-- Maps an ElemID's type onto the runtime prototype table that owns its
-- localised_name. Virtual recipes / materials only carry the user-visible name
-- through their elem_tooltip target, so this is how we recover it.
local elem_tooltip_prototypes = {
    entity = function(name) return prototypes.entity[name] end,
    item = function(name) return prototypes.item[name] end,
    fluid = function(name) return prototypes.fluid[name] end,
    recipe = function(name) return prototypes.recipe[name] end,
    tile = function(name) return prototypes.tile[name] end,
}

---Resolve the localised_name of the prototype an ElemID points at.
---@param elem_tooltip ElemID?
---@return LocalisedString?
local function localised_from_elem_tooltip(elem_tooltip)
    if not elem_tooltip then
        return nil
    end
    local getter = elem_tooltip_prototypes[elem_tooltip.type]
    if not getter then
        return nil
    end
    local proto = getter(elem_tooltip.name)
    if not proto then
        return nil
    end
    return proto.localised_name
end

---Best available user-visible LocalisedString for a virtual material / recipe.
---Virtuals have no localised_name field; the displayed name comes from the
---elem_tooltip target when present (derived virtuals such as miners /
---generators), otherwise from the tooltip (source/sink recipes embed the
---material name there, static materials carry a plain locale key).
---@param value VirtualMaterial|VirtualRecipe
---@return LocalisedString?
local function virtual_localised(value)
    return localised_from_elem_tooltip(value.elem_tooltip) or value.tooltip
end

---(Re)build the constraint-adder name dictionaries. Must run inside on_init /
---on_configuration_changed (before flib_dictionary marks itself initialized);
---flib resets its storage on on_configuration_changed, so both lifecycle events
---rebuild. Relies on storage.virtuals already being populated by the caller.
function M.build()
    flib_dictionary.new("item")
    flib_dictionary.new("fluid")
    flib_dictionary.new("recipe")
    flib_dictionary.new("virtual")

    for name, proto in pairs(prototypes.item) do
        if not proto.parameter then
            flib_dictionary.add("item", name, proto.localised_name)
        end
    end
    for name, proto in pairs(prototypes.fluid) do
        if not proto.parameter then
            flib_dictionary.add("fluid", name, proto.localised_name)
        end
    end
    for name, proto in pairs(prototypes.recipe) do
        if not proto.parameter then
            flib_dictionary.add("recipe", name, proto.localised_name)
        end
    end

    for name, value in pairs(storage.virtuals.material) do
        local loc = virtual_localised(value)
        if loc then
            flib_dictionary.add("virtual", name, loc)
        end
    end
    for name, value in pairs(storage.virtuals.recipe) do
        local loc = virtual_localised(value)
        if loc then
            flib_dictionary.add("virtual", name, loc)
        end
    end
end

return M
