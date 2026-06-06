-- Byte-identity net for solver/var_key. The whole point of the var_key module
-- is that it changes WHERE LP variable keys are built, never the bytes. These
-- cases pin every constructor's output to the exact literal the former inline
-- concatenations produced, and check that each parse helper is the true inverse
-- of its constructor. If a refactor ever shifts a delimiter, these fail before
-- raw_variables / save-load / round-trip dumps silently diverge.

local harness = require "tests/harness"
local vk = require "solver/var_key"

local cases = {}

local function item_tn(name)
    return { type = "item", name = name, quality = "normal" }
end

table.insert(cases, {
    name = "material() matches typed_name_to_variable_name forms",
    run = function()
        harness.assert_eq(vk.material(item_tn("iron-plate")), "item/iron-plate/normal", "item key")
        harness.assert_eq(
            vk.material({ type = "fluid", name = "steam", quality = "normal",
                minimum_temperature = 165, maximum_temperature = 165 }),
            "fluid/steam@[165,165]", "point-temperature fluid key")
        harness.assert_eq(
            vk.material({ type = "fluid", name = "water", quality = "normal" }),
            "fluid/water", "bare fluid key")
    end,
})

table.insert(cases, {
    name = "derived-key constructors are byte-identical to the old literals",
    run = function()
        local m = "item/x/normal"
        harness.assert_eq(vk.limit(m), "|limit|item/x/normal", "limit")
        harness.assert_eq(vk.surplus_sink(m), "|surplus_sink|item/x/normal", "surplus_sink")
        harness.assert_eq(vk.final_sink(m), "|final_sink|item/x/normal", "final_sink")
        harness.assert_eq(vk.initial_source(m), "|initial_source|item/x/normal", "initial_source")
        harness.assert_eq(vk.shortage_source(m), "|shortage_source|item/x/normal", "shortage_source")
        -- create_problem builds |elastic| on top of an already-|limit| dual; the
        -- composite must equal the elastic_limit form the diagnose parser expects.
        harness.assert_eq(vk.elastic(vk.limit(m)), "|elastic||limit|item/x/normal", "elastic over limit")
        harness.assert_eq(vk.elastic_limit(m), "|elastic||limit|item/x/normal", "elastic_limit")
        harness.assert_eq(vk.pos_slack("d"), "%positive_slack%d", "pos_slack")
        harness.assert_eq(vk.neg_slack("d"), "%negative_slack%d", "neg_slack")
    end,
})

table.insert(cases, {
    name = "bridge() matches the create_temperature_bridges format",
    run = function()
        harness.assert_eq(
            vk.bridge("steam", 165, 165, 15, 1000),
            "|bridge|fluid/steam@[165,165]->[15,1000]", "point->range bridge")
        -- %g drops trailing zeros / uses sci notation, same as the original.
        harness.assert_eq(
            vk.bridge("steam", 10, 10, 10, 100),
            "|bridge|fluid/steam@[10,10]->[10,100]", "limestone-loop bridge")
    end,
})

table.insert(cases, {
    name = "recipe / bridge predicates",
    run = function()
        harness.assert_true(vk.is_recipe("recipe/iron-smelting/normal"), "recipe/ is a recipe")
        harness.assert_true(vk.is_recipe("virtual_recipe/foo/normal"), "virtual_recipe/ is a recipe")
        harness.assert_true(not vk.is_recipe("item/x/normal"), "material is not a recipe")
        -- A bridge variable is keyed virtual_recipe/|bridge|... and must be
        -- excluded so it is not counted as a user-placed recipe.
        local bridge_key = "virtual_recipe/" .. vk.bridge("steam", 165, 165, 15, 1000) .. "/normal"
        harness.assert_true(vk.is_bridge(bridge_key), "bridge key detected")
        harness.assert_true(not vk.is_recipe(bridge_key), "bridge is not a counted recipe")
        harness.assert_true(not vk.is_bridge("recipe/x/normal"), "plain recipe is not a bridge")
    end,
})

table.insert(cases, {
    name = "parse helpers are true inverses of the constructors",
    run = function()
        local m = "item/loop/normal"
        harness.assert_eq(vk.strip_shortage(vk.shortage_source(m)), m, "strip_shortage round-trip")
        harness.assert_eq(vk.strip_elastic_limit(vk.elastic_limit(m)), m, "strip_elastic_limit round-trip")
        -- Non-matches return nil.
        harness.assert_true(vk.strip_shortage("item/x/normal") == nil, "strip_shortage non-match")
        harness.assert_true(vk.strip_elastic_limit(vk.elastic("|other|x")) == nil,
            "bare elastic is not an elastic_limit")
    end,
})

table.insert(cases, {
    name = "has_* find-predicates fire on the constructed escape keys",
    run = function()
        harness.assert_true(vk.has_shortage(vk.shortage_source("item/x/normal")), "has_shortage")
        harness.assert_true(vk.has_elastic(vk.elastic_limit("item/x/normal")), "has_elastic")
        harness.assert_true(vk.has_initial(vk.initial_source("item/x/normal")), "has_initial")
        harness.assert_true(vk.has_final(vk.final_sink("item/x/normal")), "has_final")
        harness.assert_true(not vk.has_shortage("recipe/x/normal"), "has_shortage negative")
    end,
})

return cases
