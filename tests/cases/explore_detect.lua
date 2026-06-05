-- Unit tests for tests/explore_detect (the pure detect + format_result the
-- chain explorer and its headless worker share). These pin the HIT taxonomy --
-- DEGEN / NOSHIP / CATALYST / plain HIT / clean -- so the single source of the
-- status line stays correct as it is reused across the in-engine and parallel
-- paths. No Factorio, no solver: detect() reads a synthetic variable set, and
-- format_result() turns a context + detect result into the launcher line.

local harness = require "tests/harness"
local ed = require "tests/explore_detect"

-- A PackedVariables-shaped value: only .x matters to detect().
local function vars(x) return { x = x } end

-- A full ExploreContext with sensible defaults; `over` patches fields per case.
local function ctx(over)
    local c = {
        seed = 1, mode = "cycle", init = "recipe",
        exclude_void = true, exclude_source_sink = true,
        pins = 1, use_quality = false, target_quality = "rare", hops = 24,
        seed_recipe = "r-seed", built = 3, target_label = "pin:r-seed",
        do_close = true, catalysts = {}, trapped_items = {}, unresolved = {},
        closure_added = 0, closure_closed = true,
    }
    if over then for k, v in pairs(over) do c[k] = v end end
    return c
end

local PARKED = 1e-12 -- below the interior floor; counts as not running
local cases = {}

table.insert(cases, {
    name = "detect: nil vars yields an all-zero result",
    run = function()
        local d = ed.detect(nil)
        harness.assert_eq(d.recipes, 0, "recipes")
        harness.assert_eq(d.cheat, 0, "cheat")
        harness.assert_true(d.degenerate == false, "not degenerate")
        harness.assert_true(d.noship == false, "not noship")
    end,
})

table.insert(cases, {
    name = "clean finished: two active recipes, no cheat, no HIT",
    run = function()
        local d = ed.detect(vars({
            ["recipe/a/normal"] = 1.0,
            ["recipe/b/normal"] = 2.0,
        }))
        harness.assert_eq(d.recipes, 2, "recipes")
        harness.assert_eq(d.active, 2, "active")
        harness.assert_eq(d.cheat, 0, "cheat")
        harness.assert_true(d.degenerate == false, "not degenerate")
        local line = ed.format_result(ctx(), "finished", 42, d)
        harness.assert_true(not line:find("<<HIT", 1, true), "no HIT in clean line")
        harness.assert_true(line:find("state=finished", 1, true) ~= nil, "state shown")
        harness.assert_true(line:find("R=2(act=2)", 1, true) ~= nil, "recipe counts shown")
    end,
})

table.insert(cases, {
    name = "DEGEN: cheat>0 with zero active recipes (target conjured, nothing built)",
    run = function()
        local d = ed.detect(vars({
            ["recipe/loop/normal"] = PARKED,
            ["item/ash/normal|shortage_source|"] = 0.5,
            ["item/ash/normal|surplus_sink|"] = 0.5,
        }))
        harness.assert_eq(d.active, 0, "no active recipe")
        harness.assert_near(d.cheat, 0.5, 1e-9, "cheat mass")
        harness.assert_true(d.degenerate, "degenerate flag")
        local line = ed.format_result(ctx(), "finished", 10, d)
        harness.assert_true(line:find("<<HIT DEGEN", 1, true) ~= nil, "DEGEN tag")
        harness.assert_true(not line:find("CATALYST", 1, true), "no CATALYST without catalysts")
    end,
})

table.insert(cases, {
    name = "CATALYST: partial shortage on a genuine catalyst is tagged",
    run = function()
        local d = ed.detect(vars({
            ["recipe/a/normal"] = 1.0,
            ["recipe/b/normal"] = 1.0,
            ["recipe/c/normal"] = PARKED,
            ["item/sb-oxide/normal|shortage_source|"] = 0.75,
        }))
        harness.assert_eq(d.active, 2, "two active recipes")
        harness.assert_near(d.cheat, 0.75, 1e-9, "cheat mass")
        harness.assert_true(d.degenerate == false, "not degenerate (active>0)")
        local line = ed.format_result(ctx({ catalysts = { "sb-oxide" } }), "finished", 33, d)
        harness.assert_true(line:find("<<HIT CATALYST", 1, true) ~= nil, "HIT + CATALYST tag")
        harness.assert_true(line:find("catalyst={sb-oxide}", 1, true) ~= nil, "catalyst note")
    end,
})

table.insert(cases, {
    name = "NOSHIP: imports + runs but no final_sink (cheat-free impracticality)",
    run = function()
        local d = ed.detect(vars({
            ["recipe/a/normal"] = 1.0,
            ["item/ore/normal|initial_source|"] = 5.0,
            -- no |final_sink|; surplus is dumped back, not shipped
            ["item/mid/normal|surplus_sink|"] = 1.0,
        }))
        harness.assert_true(d.has_initial, "draws an import")
        harness.assert_true(d.has_final == false, "ships nothing")
        harness.assert_eq(d.cheat, 0, "no cheat")
        harness.assert_true(d.noship, "noship flag")
        local line = ed.format_result(ctx(), "finished", 20, d)
        harness.assert_true(line:find("<<HIT NOSHIP", 1, true) ~= nil, "NOSHIP tag")
    end,
})

table.insert(cases, {
    name = "non-convergence is a plain HIT regardless of cheat",
    run = function()
        local d = ed.detect(vars({ ["recipe/a/normal"] = 1.0 }))
        local line = ed.format_result(ctx(), "unfinished", 600, d)
        harness.assert_true(line:find("<<HIT", 1, true) ~= nil, "HIT on non-finished state")
        harness.assert_true(line:find("state=unfinished", 1, true) ~= nil, "state shown")
    end,
})

table.insert(cases, {
    name = "format_result: closure=off surfaces surviving traps",
    run = function()
        local d = ed.detect(vars({ ["recipe/a/normal"] = 1.0 }))
        local line = ed.format_result(
            ctx({ do_close = false, trapped_items = { "pu-238", "ash" } }), "finished", 5, d)
        harness.assert_true(line:find("closure=off,trapped={ash,pu-238}", 1, true) ~= nil
            or line:find("closure=off,trapped={pu-238,ash}", 1, true) ~= nil,
            "trapped items listed under closure=off")
    end,
})

return cases
