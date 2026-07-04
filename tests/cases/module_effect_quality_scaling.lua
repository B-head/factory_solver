-- Unit coverage for manage/accessor/modules.lua's private
-- get_effective_module_effects (exercised through the exported
-- M.get_total_effectivity), which supplies the quality-scaled ModuleEffects
-- for each module in apply_group. Not exercised by any LP fixture -- every
-- lp_* case constructs its production lines with already-scaled
-- ModuleEffects, so a bug here (or a fix to it) is invisible to them.
--
-- Background: an earlier version of this code hand-computed the scaled
-- effect from two prototype-field reads -- the quality tier's per-effect
-- multiplier (QualityPrototype.module_speed_multiplier etc.) and each
-- module's own per-effect blend factor (ModulePrototype.speed_quality_
-- multiplier etc., lua-api.factorio.com/latest/prototypes/ModulePrototype.html).
-- Both are folded together, already, by the engine's own
-- LuaItemPrototype.get_module_effects(quality) -- confirmed bit-exact
-- against vanilla speed-module-3 / productivity-module-3 / quality-module-3
-- at the legendary tier on Factorio 2.1.9 via tests/console.ps1 (2026-07-04)
-- -- so get_effective_module_effects delegates to it instead of
-- reimplementing the blend. get_module_effects is a bound function (like
-- get_durability -- see CLAUDE.md's "Runtime API gotchas"): calling it with
-- `:` instead of `.` shifts the quality argument into the wrong slot and
-- raises "Invalid QualityID" (also confirmed in-game). Because this mod's
-- declared minimum (base >= 2.0.56, see info.json) predates the version
-- get_module_effects was verified on, get_effective_module_effects
-- pcall-guards the call and falls back to the module's unscaled base
-- effects if it fails.
--
-- These mocks stand in for prototypes.item (not provided by
-- tests/headless_env.lua). prototypes.quality is NOT needed here: quality
-- scaling is entirely the engine's job now, so get_effective_module_effects
-- just forwards the `quality` value into get_module_effects(quality)
-- without ever resolving a QualityPrototype itself.

local harness = require "tests/harness"

local cases = {}

---Install prototypes.item, run body(), and restore the previous
---_G.prototypes afterward so cases don't leak state into each other or into
---other case files run in the same process.
---@param item_mock table<string, table>
---@param body fun()
local function with_item_prototypes(item_mock, body)
    local previous = _G.prototypes
    ---@diagnostic disable-next-line: undefined-global
    _G.prototypes = { item = item_mock }
    local ok, err = pcall(body)
    _G.prototypes = previous
    if not ok then
        error(err, 0)
    end
end

---The minimal (recipe, machine) pair get_total_effectivity needs: no
---allowed_effects / allowed_module_categories restriction on either side, so
---every module and every effect kind is allowed through unmasked.
---@return table recipe
---@return table machine
local function unrestricted_recipe_and_machine()
    return {}, { type = "assembling-machine" }
end

table.insert(cases, {
    name = "get_module_effects present: its return value is used directly, not the unscaled module_effects",
    run = function()
        local item_mock = {
            ["test-module"] = {
                name = "test-module",
                type = "module",
                category = "misc",
                module_effects = { speed = 0.5 },
                get_module_effects = function(quality)
                    -- Pretend the engine already scaled this for `quality`.
                    return { speed = 1.25 }
                end,
            },
        }
        with_item_prototypes(item_mock, function()
            local modules_acc = require "manage/accessor/modules"
            local recipe, machine = unrestricted_recipe_and_machine()
            local total_modules = {
                machine_modules = { ["test-module"] = { legendary = 1 } },
                beacon_groups = {},
            }
            local ret = modules_acc.get_total_effectivity(recipe, total_modules, nil, nil, machine, nil, nil)
            -- 1 (base) + 1.25 (get_module_effects' scaled value), NOT
            -- 1 + 0.5 (the unscaled module_effects value).
            harness.assert_near(ret.speed, 2.25, 1e-9, "speed")
        end)
    end,
})

table.insert(cases, {
    name = "get_module_effects returns nil: falls back to unscaled module_effects",
    run = function()
        local item_mock = {
            ["test-module"] = {
                name = "test-module",
                type = "module",
                category = "misc",
                module_effects = { speed = 0.5 },
                get_module_effects = function(quality)
                    return nil
                end,
            },
        }
        with_item_prototypes(item_mock, function()
            local modules_acc = require "manage/accessor/modules"
            local recipe, machine = unrestricted_recipe_and_machine()
            local total_modules = {
                machine_modules = { ["test-module"] = { legendary = 1 } },
                beacon_groups = {},
            }
            local ret = modules_acc.get_total_effectivity(recipe, total_modules, nil, nil, machine, nil, nil)
            harness.assert_near(ret.speed, 1.5, 1e-9, "speed")
        end)
    end,
})

table.insert(cases, {
    name = "get_module_effects absent (nil field, calling it throws): falls back to unscaled module_effects",
    run = function()
        local item_mock = {
            ["test-module"] = {
                name = "test-module",
                type = "module",
                category = "misc",
                module_effects = { speed = 0.5 },
                -- No get_module_effects key at all: indexing it yields nil, and
                -- calling nil() raises "attempt to call a nil value", which
                -- get_effective_module_effects's pcall must catch.
            },
        }
        with_item_prototypes(item_mock, function()
            local modules_acc = require "manage/accessor/modules"
            local recipe, machine = unrestricted_recipe_and_machine()
            local total_modules = {
                machine_modules = { ["test-module"] = { legendary = 1 } },
                beacon_groups = {},
            }
            local ret = modules_acc.get_total_effectivity(recipe, total_modules, nil, nil, machine, nil, nil)
            harness.assert_near(ret.speed, 1.5, 1e-9, "speed")
        end)
    end,
})

table.insert(cases, {
    name = "get_module_effects key genuinely doesn't exist (throws on index, pre-2.0.69-style): falls back to unscaled module_effects",
    run = function()
        local test_module = setmetatable(
            {
                name = "test-module",
                type = "module",
                category = "misc",
                module_effects = { speed = 0.5 },
            },
            { __index = function(_, key) error("LuaItemPrototype doesn't contain key " .. tostring(key)) end }
        )
        local item_mock = { ["test-module"] = test_module }
        with_item_prototypes(item_mock, function()
            local modules_acc = require "manage/accessor/modules"
            local recipe, machine = unrestricted_recipe_and_machine()
            local total_modules = {
                machine_modules = { ["test-module"] = { legendary = 1 } },
                beacon_groups = {},
            }
            local ret = modules_acc.get_total_effectivity(recipe, total_modules, nil, nil, machine, nil, nil)
            harness.assert_near(ret.speed, 1.5, 1e-9, "speed")
        end)
    end,
})

table.insert(cases, {
    name = "get_module_effects is called with `.`, receiving quality as its sole argument (not shifted by a bound-self)",
    run = function()
        local seen_quality = nil
        local item_mock = {
            ["test-module"] = {
                name = "test-module",
                type = "module",
                category = "misc",
                module_effects = { productivity = 0.1 },
                get_module_effects = function(quality)
                    seen_quality = quality
                    return { productivity = 0.4 }
                end,
            },
        }
        with_item_prototypes(item_mock, function()
            local modules_acc = require "manage/accessor/modules"
            local recipe, machine = unrestricted_recipe_and_machine()
            local total_modules = {
                machine_modules = { ["test-module"] = { epic = 1 } },
                beacon_groups = {},
            }
            local ret = modules_acc.get_total_effectivity(recipe, total_modules, nil, nil, machine, nil, nil)
            harness.assert_eq(seen_quality, "epic", "quality argument")
            harness.assert_near(ret.productivity, 0.4, 1e-9, "productivity")
        end)
    end,
})

return cases
