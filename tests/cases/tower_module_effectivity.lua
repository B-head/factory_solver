-- Unit coverage for manage/accessor/normalize.lua's M.normalize_production_line
-- on plant-growth lines, whose machine slot is now a real, user-selectable
-- agricultural-tower-type entity (Factorio 2.1.7's AgriculturalTowerPrototype
-- ::module_slots Modding-API addition -- manage/virtual.lua's
-- create_plant_virtual no longer sets fixed_crafting_machine to the plant).
--
-- Background: confirmed against real gameplay (2026-07-07) that only two of
-- the five module-effect kinds actually do anything for a plant line grown
-- through a modded, module-capable tower -- productivity increases harvest
-- yield, and pollution increases harvest-time pollution. Speed only spins the
-- tower's crane (no effect on plant growth), consumption/quality have no
-- bearing here. Vanilla's own tower has module_inventory_size == 0 and
-- allowed_effects all false, so none of this fires without a mod; these cases
-- exercise the mechanism directly against mocked prototypes, mirroring the
-- fs-test-agri-* / fs-test-fast-plant fixtures already in data_test.lua.
--
-- Not exercised by any lp_* fixture: those construct ProductionLines with
-- already-resolved (recipe, real-recipe) machines, never a virtual plant-
-- growth recipe with a live agricultural-tower machine.

local harness = require "tests/harness"

local cases = {}

---Install prototypes.entity / prototypes.item / prototypes.quality and
---storage.virtuals.recipe, run body(), and restore the previous globals
---afterward so cases don't leak state into each other or into other case
---files run in the same process. Mirrors module_effect_quality_scaling.lua's
---with_item_prototypes, extended to the additional globals
---manage/accessor/normalize.lua's call chain touches (tn.typed_name_to_machine
---reads prototypes.entity; tn.typed_name_to_recipe reads storage.virtuals.recipe
---for a virtual_recipe TypedName; manage/accessor/quality.lua reads
---prototypes.quality, which must at least exist as a table so `prototypes.
---quality["normal"]` returns nil instead of throwing).
---@param entity_mock table<string, table>
---@param item_mock table<string, table>
---@param recipe_mock table
---@param body fun()
local function with_plant_line_prototypes(entity_mock, item_mock, recipe_mock, body)
    local previous_prototypes = _G.prototypes
    local previous_storage = _G.storage
    -- Minimal get_entity_filtered supporting only the {filter="type", type=...}
    -- shape manage/accessor/prototype.lua's get_towers_for_plant uses -- not a
    -- general LuaEntityPrototype filter engine.
    local function get_entity_filtered(filters)
        local ret = {}
        for _, entity in pairs(entity_mock) do
            local matches = true
            for _, f in ipairs(filters) do
                if f.filter == "type" and entity.type ~= f.type then
                    matches = false
                end
            end
            if matches then table.insert(ret, entity) end
        end
        return ret
    end
    ---@diagnostic disable-next-line: undefined-global
    _G.prototypes = {
        entity = entity_mock,
        item = item_mock,
        quality = {},
        get_entity_filtered = get_entity_filtered,
    }
    ---@diagnostic disable-next-line: undefined-global
    _G.storage = { virtuals = { recipe = { ["<grow>test:test"] = recipe_mock } } }
    local ok, err = pcall(body)
    _G.prototypes = previous_prototypes
    _G.storage = previous_storage
    if not ok then
        error(err, 0)
    end
end

---A minimal plant-growth VirtualRecipe shape, mirroring manage/virtual.lua's
---create_plant_virtual output: no fixed_crafting_machine (the machine is
---whatever the test's ProductionLine.machine_typed_name names), a single item
---product, and a per-craft harvest pollution baked into pollution_per_craft
---(matching how plant.harvest_emissions is folded in). crafting_speed_cap /
---maximum_productivity are left unset (both default to math.huge).
---@return table
local function make_plant_recipe()
    return {
        type = "virtual_recipe",
        name = "<grow>test:test",
        products = { { type = "item", name = "test-crop", amount = 1 } },
        ingredients = {},
        pollution_per_craft = 10,
        source_entity_name = "test-plant",
    }
end

---A real, electric-consuming agricultural-tower-type entity mock. The
---electric fields are never actually read by normalize_production_line for
---these lines (is_agricultural_tower short-circuits fuel/power/pollution
---before touching them) -- they exist so a regression that accidentally
---removes that guard would immediately surface as a non-zero power_per_second
---in the baseline case below, instead of a mock that's coincidentally void-like.
---@param name string
---@param effect_receiver table?
---@param module_inventory_size integer?
---@return table
local function make_tower(name, effect_receiver, module_inventory_size)
    return {
        name = name,
        type = "agricultural-tower",
        module_inventory_size = module_inventory_size or 0,
        effect_receiver = effect_receiver,
        electric_energy_source_prototype = { drain = 0, emissions_per_joule = 0.01 },
        get_max_energy_usage = function(quality) return 1000000 end,
    }
end

---@param recipe_typed_name TypedName
---@param machine_name string
---@param module_typed_names table<string, TypedName>?
---@param affected_by_beacons AffectedByBeacon[]?
---@return table
local function make_line(recipe_typed_name, machine_name, module_typed_names, affected_by_beacons)
    return {
        recipe_typed_name = recipe_typed_name,
        machine_typed_name = { type = "machine", name = machine_name, quality = "normal" },
        module_typed_names = module_typed_names or {},
        affected_by_beacons = affected_by_beacons or {},
        fuel_typed_name = nil,
    }
end

local recipe_typed_name = { type = "virtual_recipe", name = "<grow>test:test", quality = "normal" }

table.insert(cases, {
    name = "baseline tower (no productivity/pollution effect): products/pollution match the neutral recipe baseline, and the tower's own power/pollution (despite a real electric energy source) are suppressed",
    run = function()
        local entity_mock = { ["test-tower-baseline"] = make_tower("test-tower-baseline") }
        with_plant_line_prototypes(entity_mock, {}, make_plant_recipe(), function()
            local normalize_acc = require "manage/accessor/normalize"
            local line = make_line(recipe_typed_name, "test-tower-baseline")
            local normalized = normalize_acc.normalize_production_line(line, nil)
            harness.assert_near(normalized.products[1].amount_per_second, 1, 1e-9, "baseline product amount")
            harness.assert_near(normalized.pollution_per_second, 10, 1e-9, "baseline pollution (harvest only)")
            harness.assert_near(normalized.power_per_second, 0, 1e-9, "tower's own power draw suppressed")
        end)
    end,
})

table.insert(cases, {
    name = "productivity tower (effect_receiver.base_effect.productivity): harvest yield increases",
    run = function()
        local entity_mock = {
            ["test-tower-productivity"] = make_tower("test-tower-productivity", { base_effect = { productivity = 0.5 } }),
        }
        with_plant_line_prototypes(entity_mock, {}, make_plant_recipe(), function()
            local normalize_acc = require "manage/accessor/normalize"
            local line = make_line(recipe_typed_name, "test-tower-productivity")
            local normalized = normalize_acc.normalize_production_line(line, nil)
            -- normal_amount = (amount_min + amount_max + (amount_min+amount_max)*productivity) / 2
            --              = (1 + 1 + 2*0.5) / 2 = 1.5
            harness.assert_near(normalized.products[1].amount_per_second, 1.5, 1e-9, "productivity-boosted product amount")
        end)
    end,
})

table.insert(cases, {
    name = "pollution tower (effect_receiver.base_effect.pollution): harvest-time pollution increases, tower's own energy pollution stays suppressed",
    run = function()
        local entity_mock = {
            ["test-tower-pollution"] = make_tower("test-tower-pollution", { base_effect = { pollution = 2.0 } }),
        }
        with_plant_line_prototypes(entity_mock, {}, make_plant_recipe(), function()
            local normalize_acc = require "manage/accessor/normalize"
            local line = make_line(recipe_typed_name, "test-tower-pollution")
            local normalized = normalize_acc.normalize_production_line(line, nil)
            -- pollution_per_craft(10) * (crafting_speed(1)/crafting_energy(1)) * effectivity.pollution(1+2.0=3.0)
            harness.assert_near(normalized.pollution_per_second, 30, 1e-9, "pollution-boosted harvest emission")
        end)
    end,
})

table.insert(cases, {
    name = "speed tower (effect_receiver.base_effect.speed, maxed): harvest yield/pollution UNCHANGED -- speed only spins the crane, confirmed against real gameplay, and must not leak into the plant-growth rate",
    run = function()
        local entity_mock = {
            ["test-tower-speed"] = make_tower("test-tower-speed", { base_effect = { speed = 10 } }),
        }
        with_plant_line_prototypes(entity_mock, {}, make_plant_recipe(), function()
            local normalize_acc = require "manage/accessor/normalize"
            local line = make_line(recipe_typed_name, "test-tower-speed")
            local normalized = normalize_acc.normalize_production_line(line, nil)
            harness.assert_near(normalized.products[1].amount_per_second, 1, 1e-9, "product amount unaffected by tower speed")
            harness.assert_near(normalized.pollution_per_second, 10, 1e-9, "pollution unaffected by tower speed")
        end)
    end,
})

table.insert(cases, {
    name = "quality tower (effect_receiver.base_effect.quality, maxed): the returned ModuleEffects.quality is neutralized to 0, so pre_solve's quality_decomposition (and ui/solution_editor.lua's copy of it) never fires for this line -- confirmed no visible in-game effect",
    run = function()
        local entity_mock = {
            ["test-tower-quality"] = make_tower("test-tower-quality", { base_effect = { quality = 10 } }),
        }
        with_plant_line_prototypes(entity_mock, {}, make_plant_recipe(), function()
            local normalize_acc = require "manage/accessor/normalize"
            local line = make_line(recipe_typed_name, "test-tower-quality")
            local _, effectivity = normalize_acc.normalize_production_line(line, nil)
            harness.assert_near(effectivity.quality, 0, 1e-9, "quality neutralized for agricultural-tower machines")
        end)
    end,
})

table.insert(cases, {
    name = "consumption tower (effect_receiver.base_effect.consumption): power stays suppressed and the returned ModuleEffects.consumption is neutralized to 1 -- tower consumption only affects its own (unmodeled) power draw",
    run = function()
        local entity_mock = {
            ["test-tower-consumption"] = make_tower("test-tower-consumption", { base_effect = { consumption = -0.8 } }),
        }
        with_plant_line_prototypes(entity_mock, {}, make_plant_recipe(), function()
            local normalize_acc = require "manage/accessor/normalize"
            local line = make_line(recipe_typed_name, "test-tower-consumption")
            local normalized, effectivity = normalize_acc.normalize_production_line(line, nil)
            harness.assert_near(normalized.power_per_second, 0, 1e-9, "power stays suppressed regardless of consumption effect")
            harness.assert_near(effectivity.consumption, 1, 1e-9, "consumption neutralized for agricultural-tower machines")
        end)
    end,
})

table.insert(cases, {
    name = "a real productivity module seated in the tower's own module slots produces the same yield increase as an equivalent base_effect -- proves the physical module path, not just the isolation-test shortcut",
    run = function()
        local entity_mock = {
            ["test-tower-seated-module"] = make_tower("test-tower-seated-module", nil, 2),
        }
        local item_mock = {
            ["test-productivity-module"] = {
                name = "test-productivity-module",
                type = "module",
                category = "productivity",
                module_effects = { productivity = 0.5 },
            },
        }
        with_plant_line_prototypes(entity_mock, item_mock, make_plant_recipe(), function()
            local normalize_acc = require "manage/accessor/normalize"
            local module_typed_names = { ["1"] = { type = "item", name = "test-productivity-module", quality = "normal" } }
            local line = make_line(recipe_typed_name, "test-tower-seated-module", module_typed_names)
            local normalized = normalize_acc.normalize_production_line(line, nil)
            harness.assert_near(normalized.products[1].amount_per_second, 1.5, 1e-9,
                "seated-module product amount matches the equivalent base_effect case")
        end)
    end,
})

table.insert(cases, {
    name = "a beacon affecting the tower, carrying a productivity module, scales harvest yield the same way seated tower modules do",
    run = function()
        local entity_mock = {
            -- base_effect = {} matches the real engine's guarantee (confirmed via
            -- live RCON dump this session: a real EffectReceiver always carries
            -- base_effect as at least an empty table, even when unconfigured).
            ["test-tower-beacon-target"] = make_tower("test-tower-beacon-target",
                { uses_beacon_effects = true, base_effect = {} }),
            ["test-beacon"] = {
                name = "test-beacon",
                type = "beacon",
                distribution_effectivity = 0.5,
                module_inventory_size = 2,
            },
        }
        local item_mock = {
            ["test-productivity-module"] = {
                name = "test-productivity-module",
                type = "module",
                category = "productivity",
                module_effects = { productivity = 0.5 },
            },
        }
        with_plant_line_prototypes(entity_mock, item_mock, make_plant_recipe(), function()
            local normalize_acc = require "manage/accessor/normalize"
            local affected_by_beacons = {
                {
                    beacon_typed_name = { type = "machine", name = "test-beacon", quality = "normal" },
                    beacon_quantity = 1,
                    module_typed_names = { ["1"] = { type = "item", name = "test-productivity-module", quality = "normal" } },
                },
            }
            local line = make_line(recipe_typed_name, "test-tower-beacon-target", {}, affected_by_beacons)
            local normalized = normalize_acc.normalize_production_line(line, nil)
            -- beacon effectivity = distribution_effectivity(0.5) * quantity(1) * profile(1) * beacon_multiplier(1) = 0.5
            -- ret.productivity = 0 + module_effects.productivity(0.5) * 0.5 = 0.25
            -- normal_amount = (1 + 1 + 2*0.25) / 2 = 1.25
            harness.assert_near(normalized.products[1].amount_per_second, 1.25, 1e-9,
                "beacon-boosted product amount")
        end)
    end,
})

table.insert(cases, {
    name = "REGRESSION: a module-less (vanilla-shaped) tower is still offered as a machine candidate -- get_towers_for_plant / get_machines_for_recipe must NOT filter by module_inventory_size, or ordinary (non-modded) plant-growth gameplay loses its only real machine entirely",
    run = function()
        local entity_mock = {
            ["test-plant"] = { name = "test-plant", type = "plant" },
            -- module_inventory_size left at the default (0), matching real
            -- vanilla's own agricultural-tower exactly (confirmed via live
            -- RCON dump this session).
            ["test-tower-vanilla-shaped"] = make_tower("test-tower-vanilla-shaped"),
            ["test-tower-modded"] = make_tower("test-tower-modded", { base_effect = {} }, 2),
        }
        local recipe = make_plant_recipe()
        with_plant_line_prototypes(entity_mock, {}, recipe, function()
            local prototype_acc = require "manage/accessor/prototype"
            local plant = entity_mock["test-plant"]
            local towers = prototype_acc.get_towers_for_plant(plant)
            local names = {}
            for _, tower in ipairs(towers) do
                names[tower.name] = true
            end
            harness.assert_true(names["test-tower-vanilla-shaped"],
                "module-less tower must still be offered")
            harness.assert_true(names["test-tower-modded"],
                "module-capable tower is also offered")

            local machines = prototype_acc.get_machines_for_recipe(recipe)
            local machine_names = {}
            for _, machine in ipairs(machines) do
                machine_names[machine.name] = true
            end
            harness.assert_true(machine_names["test-tower-vanilla-shaped"],
                "get_machines_for_recipe must offer the module-less tower too")
        end)
    end,
})

return cases
