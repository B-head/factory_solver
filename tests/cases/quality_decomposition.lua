-- Unit coverage for manage/pre_solve.lua's M.quality_decomposition, the
-- per-craft quality-upgrade cascade split. Not exercised by any LP fixture:
-- tests/cases/fixture.lua's M.cascade and every lp_quality_cascade.lua /
-- lp_scale_invariance.lua case hand-construct already-decomposed
-- NormalizedAmount[] arrays with a single flat per-step probability -- they
-- never call quality_decomposition itself, so a bug in its cascade math
-- (or a fix to it) is invisible to them.
--
-- Background: Factorio 2.1 added LuaQualityPrototype.chain_probability,
-- distinct from the pre-existing next_probability. next_probability governs
-- only the FIRST quality-upgrade roll (the recipe's own quality-module-driven
-- jump); chain_probability governs every SECOND-and-later consecutive jump
-- within the same craft, and is typically much smaller. The pre-fix code
-- reused next_probability for both, which on real 2.1.9 data (next_probability
-- == 1.0 normal..epic, chain_probability == 0.1 normal..epic) made the cascade
-- multiply by 1.0 at every step after the first -- collapsing nearly all
-- probability mass into the terminal (legendary) tier and overestimating the
-- legendary-reach rate by roughly 1000x.
--
-- chain_probability does not exist at all on Factorio 2.0 prototypes, and
-- CLAUDE.md's "Runtime API gotchas" section holds that indexing a
-- non-existent field on a runtime prototype throws rather than returning
-- nil -- so the fix reads it through pcall and falls back to the pre-2.1
-- next_probability math when the read fails or yields an actual nil. These
-- mocks stand in for prototypes.quality / prototypes.utility_constants (not
-- provided by tests/headless_env.lua) and exercise both branches directly:
-- a 2.0-style mock with chain_probability absent (must reproduce the exact
-- old cascade), and a 2.1-style mock with chain_probability present and
-- different from next_probability (must decay by chain_probability, not
-- next_probability, after the first step).

local harness = require "tests/harness"

local cases = {}

---Build a 5-tier prototypes.quality mock (normal..legendary), matching the
---real prototype shape M.quality_decomposition reads: name, level, next
---(the next tier's own quality prototype, or nil at legendary), next_probability,
---and optionally chain_probability.
---@param next_probability number
---@param chain_probability number? omit to model a pre-2.1 engine (2.0 fallback path)
---@return table<string, table>
local function build_quality_mock(next_probability, chain_probability)
    local names = { "normal", "uncommon", "rare", "epic", "legendary" }
    local protos = {}
    for level, name in ipairs(names) do
        protos[name] = { name = name, level = level - 1 }
    end
    for level, name in ipairs(names) do
        local proto = protos[name]
        if level < #names then
            proto.next = protos[names[level + 1]]
            proto.next_probability = next_probability
            proto.chain_probability = chain_probability
        else
            proto.next = nil
            proto.next_probability = 0
            proto.chain_probability = 0
        end
    end
    return protos
end

---Install prototypes.quality / prototypes.utility_constants, run body(), and
---restore the previous _G.prototypes afterward so cases don't leak state into
---each other or into other case files run in the same process.
---@param quality_mock table<string, table>
---@param body fun()
local function with_prototypes(quality_mock, body)
    local previous = _G.prototypes
    ---@diagnostic disable-next-line: undefined-global
    _G.prototypes = {
        quality = quality_mock,
        utility_constants = { maximum_quality_jump = 255 },
    }
    local ok, err = pcall(body)
    _G.prototypes = previous
    if not ok then
        error(err, 0)
    end
end

table.insert(cases, {
    name = "2.0 fallback (chain_probability absent): cascade uses next_probability at every step",
    run = function()
        local quality_mock = build_quality_mock(0.1, nil)
        with_prototypes(quality_mock, function()
            local pre_solve = require "manage/pre_solve"
            local normalized_amount = {
                type = "item", name = "iron-plate", quality = "normal", amount_per_second = 1,
            }
            local ret = pre_solve.quality_decomposition(normalized_amount, 1, nil)

            -- Old/current math: first step effectivity_quality(=1) * next_probability
            -- (=0.1) => 90% stays at normal, 10% carries on. Every subsequent step
            -- also multiplies by next_probability(=0.1) (the bug this test pins for
            -- the pre-2.1 fallback, where it is CORRECT because chain_probability
            -- doesn't exist): uncommon keeps 90% of the remaining 10%, etc.
            harness.assert_eq(#ret, 5, "one entry per tier down to legendary")
            harness.assert_near(ret[1].amount_per_second, 0.9, 1e-9, "normal share")
            harness.assert_eq(ret[1].quality, "normal")
            harness.assert_near(ret[2].amount_per_second, 0.1 * 0.9, 1e-9, "uncommon share")
            harness.assert_eq(ret[2].quality, "uncommon")
            harness.assert_near(ret[3].amount_per_second, 0.1 * 0.1 * 0.9, 1e-9, "rare share")
            harness.assert_near(ret[4].amount_per_second, 0.1 * 0.1 * 0.1 * 0.9, 1e-9, "epic share")
            -- legendary (terminal tier) absorbs all remaining probability mass.
            harness.assert_near(ret[5].amount_per_second, 0.1 * 0.1 * 0.1 * 0.1, 1e-9, "legendary share")
            harness.assert_eq(ret[5].quality, "legendary")

            local total = 0
            for _, entry in ipairs(ret) do total = total + entry.amount_per_second end
            harness.assert_near(total, 1, 1e-9, "cascade conserves total amount_per_second")
        end)
    end,
})

table.insert(cases, {
    name = "2.1 chain_probability path: first step uses next_probability, later steps decay by chain_probability",
    run = function()
        -- Mirrors real Factorio 2.1.9 vanilla data: next_probability = 1.0,
        -- chain_probability = 0.1 for every tier normal..epic.
        local quality_mock = build_quality_mock(1.0, 0.1)
        with_prototypes(quality_mock, function()
            package.loaded["manage/pre_solve"] = nil
            local pre_solve = require "manage/pre_solve"
            local normalized_amount = {
                type = "item", name = "iron-plate", quality = "normal", amount_per_second = 1,
            }
            local ret = pre_solve.quality_decomposition(normalized_amount, 1, nil)

            -- First step: effectivity_quality(=1) * next_probability(=1.0), clamped
            -- to 1 -> ALL mass advances past normal (0 stays at normal).
            harness.assert_eq(#ret, 5, "one entry per tier down to legendary")
            harness.assert_near(ret[1].amount_per_second, 0, 1e-9, "normal share is fully upgraded")

            -- Every step after the first must use chain_probability (0.1), NOT
            -- next_probability (1.0) -- the bug this test guards against. If the
            -- fix regressed to next_probability here, uncommon's share would be
            -- ~0 (1.0 * 1.0 carried forward) instead of 90% of the mass.
            harness.assert_near(ret[2].amount_per_second, 1 * (1 - 0.1), 1e-9, "uncommon share decays by chain_probability")
            harness.assert_eq(ret[2].quality, "uncommon")
            harness.assert_near(ret[3].amount_per_second, 0.1 * (1 - 0.1), 1e-9, "rare share")
            harness.assert_near(ret[4].amount_per_second, 0.1 * 0.1 * (1 - 0.1), 1e-9, "epic share")
            harness.assert_near(ret[5].amount_per_second, 0.1 * 0.1 * 0.1, 1e-9, "legendary share (terminal, absorbs remainder)")
            harness.assert_eq(ret[5].quality, "legendary")

            local total = 0
            for _, entry in ipairs(ret) do total = total + entry.amount_per_second end
            harness.assert_near(total, 1, 1e-9, "cascade conserves total amount_per_second")
        end)
    end,
})

table.insert(cases, {
    name = "chain_probability of exactly 0 is honored, not treated as missing",
    run = function()
        -- A quality tier whose chain_probability is a real 0 (e.g. a modded
        -- tier that permits the first jump but never a second one) must stop
        -- the cascade there, not silently fall back to next_probability.
        local quality_mock = build_quality_mock(1.0, 0)
        with_prototypes(quality_mock, function()
            package.loaded["manage/pre_solve"] = nil
            local pre_solve = require "manage/pre_solve"
            local normalized_amount = {
                type = "item", name = "iron-plate", quality = "normal", amount_per_second = 1,
            }
            local ret = pre_solve.quality_decomposition(normalized_amount, 1, nil)

            harness.assert_eq(#ret, 2, "cascade stops at uncommon: chain_probability=0 ends it immediately")
            harness.assert_near(ret[1].amount_per_second, 0, 1e-9, "normal share fully upgraded")
            harness.assert_eq(ret[2].quality, "uncommon")
            harness.assert_near(ret[2].amount_per_second, 1, 1e-9, "all mass parks at uncommon")
        end)
    end,
})

return cases
