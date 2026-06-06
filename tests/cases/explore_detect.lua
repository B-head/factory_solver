-- Unit tests for tests/explore_detect (the pure detect + format_result the
-- chain explorer and its headless worker share). These pin the HIT taxonomy --
-- DEGEN / NOSHIP / CATALYST / plain HIT / clean -- so the single source of the
-- status line stays correct as it is reused across the in-engine and parallel
-- paths. No Factorio, no solver: detect() reads a synthetic variable set, and
-- format_result() turns a context + detect result into the launcher line.

local harness = require "tests/harness"
local ed = require "tests/explore_detect"

-- Build the (vars, primals) pair detect() reads: x holds the solved values,
-- primals holds each variable's kind so detect classifies by metadata, not by
-- parsing the key. Returned as two values so `ed.detect(solved{...})` forwards
-- both through Lua's multi-return. Entry shape: { key, value, kind }.
local function solved(entries)
    local x, primals = {}, {}
    for _, e in ipairs(entries) do
        x[e[1]] = e[2]
        primals[e[1]] = { key = e[1], index = 0, cost = 0, is_result = false, kind = e[3] }
    end
    return { x = x }, primals
end

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
        local d = ed.detect(solved({
            { "recipe/a/normal", 1.0, "recipe" },
            { "recipe/b/normal", 2.0, "recipe" },
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
        local d = ed.detect(solved({
            { "recipe/loop/normal", PARKED, "recipe" },
            { "|shortage_source|item/ash/normal", 0.5, "shortage_source" },
            { "|surplus_sink|item/ash/normal", 0.5, "surplus_sink" },
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
        local d = ed.detect(solved({
            { "recipe/a/normal", 1.0, "recipe" },
            { "recipe/b/normal", 1.0, "recipe" },
            { "recipe/c/normal", PARKED, "recipe" },
            { "|shortage_source|item/sb-oxide/normal", 0.75, "shortage_source" },
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
        local d = ed.detect(solved({
            { "recipe/a/normal", 1.0, "recipe" },
            { "|initial_source|item/ore/normal", 5.0, "initial_source" },
            -- no |final_sink|; surplus is dumped back, not shipped
            { "|surplus_sink|item/mid/normal", 1.0, "surplus_sink" },
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
        local d = ed.detect(solved({ { "recipe/a/normal", 1.0, "recipe" } }))
        local line = ed.format_result(ctx(), "unfinished", 600, d)
        harness.assert_true(line:find("<<HIT", 1, true) ~= nil, "HIT on non-finished state")
        harness.assert_true(line:find("state=unfinished", 1, true) ~= nil, "state shown")
    end,
})

table.insert(cases, {
    name = "format_result: closure=off surfaces surviving traps",
    run = function()
        local d = ed.detect(solved({ { "recipe/a/normal", 1.0, "recipe" } }))
        local line = ed.format_result(
            ctx({ do_close = false, trapped_items = { "pu-238", "ash" } }), "finished", 5, d)
        harness.assert_true(line:find("closure=off,trapped={ash,pu-238}", 1, true) ~= nil
            or line:find("closure=off,trapped={pu-238,ash}", 1, true) ~= nil,
            "trapped items listed under closure=off")
    end,
})

return cases
