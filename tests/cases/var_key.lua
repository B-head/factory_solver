-- Byte-identity net for solver/var_key. The whole point of the var_key module
-- is that it changes WHERE LP variable keys are built, never the bytes. These
-- cases pin every constructor's output to the exact literal the former inline
-- concatenations produced. If a refactor ever shifts a delimiter, these fail
-- before raw_variables / save-load / round-trip dumps silently diverge. var_key
-- only builds keys now -- there are no parse helpers to test.

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

return cases
