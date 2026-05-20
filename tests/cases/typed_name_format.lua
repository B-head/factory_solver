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
        harness.assert_true(tn.is_bare_fluid(t), "is_bare_fluid is true for bare fluid")
    end,
})

table.insert(cases, {
    name = "single-temperature fluid encodes @<T>",
    run = function()
        local t = tn.create_typed_name("fluid", "steam", nil, 165)
        harness.assert_eq(tn.typed_name_to_variable_name(t), "fluid/steam@165")
        harness.assert_true(not tn.is_bare_fluid(t), "single-temp fluid is not bare")
    end,
})

table.insert(cases, {
    name = "range-temperature fluid encodes @[lo,hi]",
    run = function()
        local t = tn.create_typed_name("fluid", "steam", nil, nil, 15, 1000)
        harness.assert_eq(tn.typed_name_to_variable_name(t), "fluid/steam@[15,1000]")
        harness.assert_true(not tn.is_bare_fluid(t), "range-temp fluid is not bare")
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
    name = "is_bare_fluid is false for non-fluid TypedName",
    run = function()
        local t = tn.create_typed_name("item", "iron-plate")
        harness.assert_true(not tn.is_bare_fluid(t), "items are never 'bare fluids'")
    end,
})

table.insert(cases, {
    name = "equals_typed_name treats matching single temperatures as equal",
    run = function()
        local a = tn.create_typed_name("fluid", "steam", nil, 165)
        local b = tn.create_typed_name("fluid", "steam", nil, 165)
        harness.assert_true(tn.equals_typed_name(a, b), "same single temperature")
    end,
})

table.insert(cases, {
    name = "equals_typed_name separates different single temperatures",
    run = function()
        local a = tn.create_typed_name("fluid", "steam", nil, 165)
        local b = tn.create_typed_name("fluid", "steam", nil, 500)
        harness.assert_true(not tn.equals_typed_name(a, b), "different temperatures")
    end,
})

table.insert(cases, {
    name = "equals_typed_name compares range endpoints",
    run = function()
        local a = tn.create_typed_name("fluid", "steam", nil, nil, 15, 1000)
        local b = tn.create_typed_name("fluid", "steam", nil, nil, 15, 1000)
        local c = tn.create_typed_name("fluid", "steam", nil, nil, 15, 500)
        harness.assert_true(tn.equals_typed_name(a, b), "identical ranges")
        harness.assert_true(not tn.equals_typed_name(a, c), "different max")
    end,
})

table.insert(cases, {
    name = "equals_typed_name distinguishes single from range",
    run = function()
        local a = tn.create_typed_name("fluid", "steam", nil, 165)
        local b = tn.create_typed_name("fluid", "steam", nil, nil, 15, 1000)
        harness.assert_true(not tn.equals_typed_name(a, b), "single vs range")
    end,
})

table.insert(cases, {
    name = "bare and single-temperature fluids are not equal",
    run = function()
        local a = tn.create_typed_name("fluid", "steam")
        local b = tn.create_typed_name("fluid", "steam", nil, 165)
        harness.assert_true(not tn.equals_typed_name(a, b), "bare vs single")
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
    name = "format_temperature_suffix renders single temperature",
    run = function()
        local t = tn.create_typed_name("fluid", "steam", nil, 165)
        harness.assert_eq(tn.format_temperature_suffix(t), "@165")
    end,
})

table.insert(cases, {
    name = "format_temperature_suffix renders range",
    run = function()
        local t = tn.create_typed_name("fluid", "steam", nil, nil, 15, 1000)
        harness.assert_eq(tn.format_temperature_suffix(t), "@[15,1000]")
    end,
})

return cases
