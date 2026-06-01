-- Verify manage/number_format: the slot pre-rounding and the relative
-- negligibility cutoff. (Labels other than slot `number` fields keep flib's
-- fixed-width formatting and are not exercised here.) These tests pin:
--   * round_for_kind lands a solved 59.9999996 on the engine's display grid so
--     the engine's floor reads "60", not "59.9".
--   * every material kind uses one slot decimal, so the same magnitude renders
--     consistently across columns (item 30.7 == fluid 30.7, not "31").
--   * is_negligible is RELATIVE to gross throughput, not a fixed absolute
--     cutoff -- phantom net flows vanish, genuine tiny demands survive.
--
-- Pure Lua: manage/number_format requires only flib's number formatter, which
-- tests/run.lua stubs. Nothing here touches the Factorio runtime.

local harness = require "tests/harness"
local nf = require "manage/number_format"

local cases = {}

-- Mirror the engine's slot formatting (SI + one mantissa decimal + FLOOR),
-- confirmed in-game 2026-06-01, so we can assert that round_for_kind makes the
-- engine floor a no-op.
local function engine_floor(value)
    local mag = math.abs(value)
    local suffix_list = {
        { "Q", 1e30 }, { "R", 1e27 }, { "Y", 1e24 }, { "Z", 1e21 }, { "E", 1e18 },
        { "P", 1e15 }, { "T", 1e12 }, { "G", 1e9 }, { "M", 1e6 }, { "k", 1e3 },
    }
    local amount, suffix = value, ""
    for _, data in ipairs(suffix_list) do
        if mag >= data[2] then
            amount = value / data[2]
            suffix = data[1]
            break
        end
    end
    amount = math.floor(amount * 10) / 10
    return amount, suffix
end

-- The headline regression: a relative-residual tail must round away so the
-- engine floor lands on the integer.
table.insert(cases, {
    name = "round_for_kind lands 59.9999996 on the engine grid -> floors to 60",
    run = function()
        local r = nf.round_for_kind(59.9999996, "fluid")
        local mantissa = engine_floor(r)
        harness.assert_eq(mantissa, 60, "engine floor of pre-rounded value")
    end,
})

-- Every material kind uses one slot decimal: the same magnitude must pre-round
-- to the same value whether it is an item or a fluid.
table.insert(cases, {
    name = "item and fluid slots pre-round to the same one-decimal value",
    run = function()
        harness.assert_near(nf.round_for_kind(30.7, "item"), 30.7, 1e-9)
        harness.assert_near(nf.round_for_kind(30.7, "fluid"), 30.7, 1e-9)
        harness.assert_near(nf.round_for_kind(45.678, "item"), 45.7, 1e-9)
        harness.assert_near(nf.round_for_kind(45.678, "fluid"), 45.7, 1e-9)
    end,
})

table.insert(cases, {
    name = "sub-0.1 rate keeps a non-zero floor instead of collapsing to 0",
    run = function()
        harness.assert_near(nf.round_for_kind(0.5, "item"), 0.5, 1e-9)
        -- 0.04 rounds to 0 at one decimal; the non-zero floor keeps it visible.
        harness.assert_near(nf.round_for_kind(0.04, "item"), 0.04, 1e-9)
        harness.assert_near(nf.round_for_kind(0.04, "fluid"), 0.04, 1e-9)
    end,
})

table.insert(cases, {
    name = "SI range pre-rounds the mantissa to one decimal",
    run = function()
        harness.assert_near(nf.round_for_kind(1234.5, "fluid"), 1200, 1e-6)
        harness.assert_near(nf.round_for_kind(1500, "item"), 1500, 1e-6)
        -- engine floor of the pre-rounded value reproduces "1.2k".
        local mantissa, suffix = engine_floor(nf.round_for_kind(1234.5, "fluid"))
        harness.assert_eq(string.format("%.1f", mantissa) .. suffix, "1.2k")
    end,
})

table.insert(cases, {
    name = "zero pre-rounds to a clean 0",
    run = function()
        harness.assert_eq(nf.round_for_kind(0, "fluid"), 0)
        harness.assert_eq(nf.round_for_kind(0, "item"), 0)
    end,
})

table.insert(cases, {
    name = "negative value keeps its sign through round_for_kind",
    run = function()
        harness.assert_near(nf.round_for_kind(-45.678, "fluid"), -45.7, 1e-9)
    end,
})

table.insert(cases, {
    name = "kind_for_material maps type to rounding kind",
    run = function()
        harness.assert_eq(nf.kind_for_material({ type = "item" }), "item")
        harness.assert_eq(nf.kind_for_material({ type = "fluid" }), "fluid")
        harness.assert_eq(nf.kind_for_material({ type = "virtual_material" }), "virtual")
    end,
})

-- round_to_sig reproduces the legacy accessor.round_display (5 sig figs).
table.insert(cases, {
    name = "round_to_sig(x, 5) reproduces the legacy round_display",
    run = function()
        harness.assert_near(nf.round_to_sig(59.9999996, 5), 60, 1e-9)
        harness.assert_near(nf.round_to_sig(0, 5), 0, 0)
        harness.assert_near(nf.round_to_sig(-1234.567, 5), -1234.6, 1e-9)
        harness.assert_near(nf.round_to_sig(0.00012345, 5), 0.00012345, 1e-12)
    end,
})

-- is_negligible: RELATIVE to gross throughput.
table.insert(cases, {
    name = "is_negligible hides residual noise of a large opposing flow",
    run = function()
        -- 100/s moved both ways, net is float noise ~1e-4: phantom, must hide.
        local net, gross, rel = 1e-4, 200, 1e-6
        harness.assert_true(nf.is_negligible(net, gross, rel), "1e-4 noise on gross 200 is negligible")
    end,
})

table.insert(cases, {
    name = "is_negligible keeps a genuine tiny demand above the relative floor",
    run = function()
        -- A trace catalyst: small net but the gross is equally small, so the
        -- ratio is well above rel_tol -- must be kept.
        local net, gross, rel = 0.01, 0.01, 1e-6
        harness.assert_true(not nf.is_negligible(net, gross, rel), "0.01 demand on gross 0.01 is real")
    end,
})

table.insert(cases, {
    name = "is_negligible with no flow is negligible only at exact zero",
    run = function()
        harness.assert_true(nf.is_negligible(0, 0, 1e-6), "exact zero")
        harness.assert_true(not nf.is_negligible(5, 0, 1e-6), "nonzero with no gross is not negligible")
    end,
})

return cases
