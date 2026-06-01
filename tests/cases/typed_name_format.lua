-- Verify the LP variable name format and TypedName equality semantics for
-- fluids with the new temperature dimension. These tests exercise only the
-- pure-string parts of manage/typed_name; nothing touches the Factorio
-- runtime globals (prototypes, storage).

local harness = require "tests/harness"
local tn = require "manage/typed_name"

local cases = {}

table.insert(cases, {
    name = "non-fluid TypedName keeps the type/name/quality format",
    run = function()
        local t = tn.create_typed_name("item", "iron-plate", "normal")
        harness.assert_eq(tn.typed_name_to_variable_name(t), "item/iron-plate/normal")
    end,
})

table.insert(cases, {
    name = "non-fluid TypedName preserves non-default quality",
    run = function()
        local t = tn.create_typed_name("item", "iron-plate", "legendary")
        harness.assert_eq(tn.typed_name_to_variable_name(t), "item/iron-plate/legendary")
    end,
})

table.insert(cases, {
    name = "bare fluid drops quality segment and has no suffix",
    run = function()
        local t = tn.create_typed_name("fluid", "steam")
        harness.assert_eq(tn.typed_name_to_variable_name(t), "fluid/steam")
    end,
})

table.insert(cases, {
    name = "point-temperature fluid encodes @[T,T] (degenerate range)",
    run = function()
        local t = tn.create_typed_name("fluid", "steam", nil, 165, 165)
        harness.assert_eq(tn.typed_name_to_variable_name(t), "fluid/steam@[165,165]")
    end,
})

table.insert(cases, {
    name = "range-temperature fluid encodes @[lo,hi]",
    run = function()
        local t = tn.create_typed_name("fluid", "steam", nil, 15, 1000)
        harness.assert_eq(tn.typed_name_to_variable_name(t), "fluid/steam@[15,1000]")
    end,
})

table.insert(cases, {
    name = "fluid quality is always coerced to normal even when given",
    run = function()
        local t = tn.create_typed_name("fluid", "steam", "legendary")
        harness.assert_eq(t.quality, "normal")
        harness.assert_eq(tn.typed_name_to_variable_name(t), "fluid/steam")
    end,
})

table.insert(cases, {
    name = "equals_typed_name treats matching point temperatures as equal",
    run = function()
        local a = tn.create_typed_name("fluid", "steam", nil, 165, 165)
        local b = tn.create_typed_name("fluid", "steam", nil, 165, 165)
        harness.assert_true(tn.equals_typed_name(a, b), "same point temperature")
    end,
})

table.insert(cases, {
    name = "equals_typed_name separates different point temperatures",
    run = function()
        local a = tn.create_typed_name("fluid", "steam", nil, 165, 165)
        local b = tn.create_typed_name("fluid", "steam", nil, 500, 500)
        harness.assert_true(not tn.equals_typed_name(a, b), "different temperatures")
    end,
})

table.insert(cases, {
    name = "equals_typed_name compares range endpoints",
    run = function()
        local a = tn.create_typed_name("fluid", "steam", nil, 15, 1000)
        local b = tn.create_typed_name("fluid", "steam", nil, 15, 1000)
        local c = tn.create_typed_name("fluid", "steam", nil, 15, 500)
        harness.assert_true(tn.equals_typed_name(a, b), "identical ranges")
        harness.assert_true(not tn.equals_typed_name(a, c), "different max")
    end,
})

table.insert(cases, {
    name = "equals_typed_name distinguishes a point from a wider range",
    run = function()
        local a = tn.create_typed_name("fluid", "steam", nil, 165, 165)
        local b = tn.create_typed_name("fluid", "steam", nil, 15, 1000)
        harness.assert_true(not tn.equals_typed_name(a, b), "point vs range")
    end,
})

table.insert(cases, {
    name = "bare and point-temperature fluids are not equal",
    run = function()
        local a = tn.create_typed_name("fluid", "steam")
        local b = tn.create_typed_name("fluid", "steam", nil, 165, 165)
        harness.assert_true(not tn.equals_typed_name(a, b), "bare vs point")
    end,
})

table.insert(cases, {
    name = "format_temperature_suffix returns empty for bare",
    run = function()
        local t = tn.create_typed_name("fluid", "steam")
        harness.assert_eq(tn.format_temperature_suffix(t), "")
    end,
})

table.insert(cases, {
    name = "format_temperature_suffix renders a point as a degenerate range",
    run = function()
        local t = tn.create_typed_name("fluid", "steam", nil, 165, 165)
        harness.assert_eq(tn.format_temperature_suffix(t), "@[165,165]")
    end,
})

table.insert(cases, {
    name = "format_temperature_suffix renders range",
    run = function()
        local t = tn.create_typed_name("fluid", "steam", nil, 15, 1000)
        harness.assert_eq(tn.format_temperature_suffix(t), "@[15,1000]")
    end,
})

table.insert(cases, {
    name = "large temperatures format in scientific notation (%g) and round-trip",
    -- Fusion plasma sits at 1e6-1e7 °C; "%g" emits these as "1e+06" / "1e+07".
    -- The variable name and the registered material key must agree on that
    -- representation or the picker can't bind plasma. The round-trip goes
    -- through the VirtualMaterial fields, the only path craft_to_typed_name uses.
    run = function()
        local t = tn.create_typed_name("fluid", "fusion-plasma", nil, 1000000, 10000000)
        local var = tn.typed_name_to_variable_name(t)
        harness.assert_eq(var, "fluid/fusion-plasma@[1e+06,1e+07]")

        local virtual_material = {
            type = "virtual_material",
            name = var,
            source_fluid_name = "fusion-plasma",
            minimum_temperature = 1000000,
            maximum_temperature = 10000000,
        }
        local decoded = tn.craft_to_typed_name(virtual_material)
        harness.assert_eq(decoded.type, "fluid")
        harness.assert_eq(decoded.name, "fusion-plasma")
        harness.assert_eq(decoded.minimum_temperature, 1000000)
        harness.assert_eq(decoded.maximum_temperature, 10000000)
        harness.assert_eq(tn.typed_name_to_variable_name(decoded), var)
    end,
})

table.insert(cases, {
    name = "craft_to_typed_name reads temperature from VirtualMaterial fields, not the name",
    -- The primary path uses the explicit source_fluid_name + min/max fields a
    -- registered VirtualMaterial carries. The name here is deliberately a
    -- mismatched placeholder to prove the fields win over any name parsing.
    run = function()
        local virtual_material = {
            type = "virtual_material",
            name = "fluid/decoy@[0,0]",
            source_fluid_name = "steam",
            minimum_temperature = 165,
            maximum_temperature = 500,
        }
        local typed_name = tn.craft_to_typed_name(virtual_material)
        harness.assert_eq(typed_name.type, "fluid")
        harness.assert_eq(typed_name.name, "steam")
        harness.assert_eq(typed_name.minimum_temperature, 165)
        harness.assert_eq(typed_name.maximum_temperature, 500)
        harness.assert_eq(tn.typed_name_to_variable_name(typed_name), "fluid/steam@[165,500]")
    end,
})

table.insert(cases, {
    name = "craft_to_typed_name keeps non-temperature virtual_material as-is",
    run = function()
        local virtual_material = { type = "virtual_material", name = "<heat>" }
        local typed_name = tn.craft_to_typed_name(virtual_material)
        harness.assert_eq(typed_name.type, "virtual_material")
        harness.assert_eq(typed_name.name, "<heat>")
    end,
})

return cases
