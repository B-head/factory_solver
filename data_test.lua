---@diagnostic disable: undefined-global
--
-- Debug-only synthetic prototypes for exercising factory_solver's prototype ->
-- virtual-recipe -> pre_solve layer WITHOUT depending on any third-party mod.
--
-- This file is require()d from data.lua only when `mods["debugadapter"]` is set
-- (i.e. running under the factoriomod-debug VS Code extension), so nothing here
-- ever reaches a shipped save. The historical inline `fs-test-*` / `fbtest-*` /
-- `fes-*` blocks that used to live in data.lua are consolidated here.
--
-- The headless suite (tests/run.lua) covers the pure-LP layer (temperature
-- bridges, reachability, quality recycling, ...). It cannot reach virtual-recipe
-- GENERATION (manage/virtual.lua), fuel/temperature acceptance resolution
-- (manage/accessor.lua), or machine<->category binding, because those read live
-- LuaXxxPrototype objects. Vanilla + Space Age exercises most of those branches;
-- the prototypes below fill the branches that no vanilla prototype hits and that
-- would otherwise require installing Pyanodons / KS_Power / etc. to surface.
--
-- Each group is guarded on the specific base prototype it deep-copies, so a
-- base-only or Space-Age-less install silently skips the groups it can't build
-- instead of hard-erroring at the data stage.
--
-- NOTE FOR FIRST LOAD: this file has no headless coverage (it is data-stage
-- only). After editing it, boot Factorio once under the debugger to confirm the
-- data stage loads clean before relying on the new prototypes.

local raw = data.raw

-- ============================================================================
-- 0. Synthetic dependency materials/items used by the entity groups below.
-- ============================================================================

if raw.fluid and raw.fluid["water"] then
    -- A combustible fluid (fuel_value > 0): the only way to exercise the
    -- burns_fluid=true branches of get_fuel_amount_per_second / get_generator_power
    -- and is_use_any_fluid_fuel. No vanilla fluid carries a fuel_value.
    local fuel_gas = table.deepcopy(raw.fluid["water"])
    fuel_gas.name = "fs-test-fuel-gas"
    fuel_gas.localised_name = "fs-test-fuel-gas"
    fuel_gas.fuel_value = "1MJ"
    fuel_gas.default_temperature = 15
    fuel_gas.max_temperature = 1000
    fuel_gas.emissions_multiplier = 1

    -- A fluid whose default_temperature == max_temperature: drives the boiler
    -- "physically impossible to heat" branch (delta_t <= 0 -> amount = 0
    -- placeholder column) in create_boiler_virtual.
    local uncookable = table.deepcopy(raw.fluid["water"])
    uncookable.name = "fs-test-uncookable"
    uncookable.localised_name = "fs-test-uncookable"
    uncookable.default_temperature = 200
    uncookable.max_temperature = 200

    -- A fluid with a very large max_temperature: its source/sink virtual range
    -- ([default, 1e7]) stringifies to a scientific-notation key
    -- ("fluid/...@[15,1e+07]"), exercising the %g / tonumber round-trip in
    -- create_source_sink_virtuals and the constraint-picker key decoder.
    local hot = table.deepcopy(raw.fluid["water"])
    hot.name = "fs-test-large-temp"
    hot.localised_name = "fs-test-large-temp"
    hot.default_temperature = 15
    hot.max_temperature = 1e7

    data:extend({ fuel_gas, uncookable, hot })
end

-- A launchable item (carries rocket_launch_products): required so the
-- launch_to_space_platforms=false rocket-silo below has at least one
-- has-rocket-launch-products item to build a recipe from. In Space Age the
-- vanilla silo launches to platforms, so no vanilla item needs this field.
if raw.item and raw.item["iron-plate"] then
    local launchable = table.deepcopy(raw.item["iron-plate"])
    launchable.name = "fs-test-launchable"
    launchable.localised_name = "fs-test-launchable"
    launchable.rocket_launch_products = { { type = "item", name = "iron-plate", amount = 1 } }
    data:extend({ launchable })
end

-- ============================================================================
-- 1. Fluid temperature acceptance probes.
--    [[reference_fluid_temperature_acceptance_gating]]: FluidBox min/max gate
--    acceptance; energy_source/generator maximum_temperature is only an
--    extraction/output cap. These are placed via the map editor and probed with
--    insert_fluid; the generator needs an electric load (e.g. a lamp) to spin up.
-- ============================================================================

-- A generator whose WORKING-fluid fluid_box carries a temperature bound, with
-- the generator's own maximum_temperature pushed high so only the fluid_box
-- bound is under test.
local function make_fbtest(name, temp_field, temp_value)
    local e = table.deepcopy(raw.generator["steam-engine"])
    e.name = name
    e.localised_name = name
    e.minable = nil
    e.next_upgrade = nil
    e.placeable_by = nil
    e.maximum_temperature = 1000
    e.fluid_box.filter = "steam"
    e.fluid_box.minimum_temperature = nil
    e.fluid_box.maximum_temperature = nil
    e.fluid_box[temp_field] = temp_value
    return e
end

-- Both-bounded variant: a real acceptance WINDOW [lo,hi] on the working fluid.
local function make_fbtest_window(name, lo, hi)
    local e = make_fbtest(name, "minimum_temperature", lo)
    e.fluid_box.maximum_temperature = hi
    return e
end

-- A crafting machine whose FluidEnergySource fuel fluid_box carries a
-- temperature bound. energy_source.maximum_temperature is pushed high so only
-- the fluid_box bound is under test. pipe_connections is emptied because these
-- are probed with insert_fluid, not pipe flow.
local function make_fes_test(name, temp_field, temp_value)
    local e = table.deepcopy(raw["assembling-machine"]["assembling-machine-2"])
    e.name = name
    e.localised_name = name
    e.minable = nil
    e.next_upgrade = nil
    e.placeable_by = nil
    e.energy_usage = "100kW"
    e.energy_source = {
        type = "fluid",
        burns_fluid = false,
        scale_fluid_usage = true,
        destroy_non_fuel_fluid = false,
        maximum_temperature = 1000,
        effectivity = 1,
        fluid_box = {
            volume = 200,
            production_type = "input",
            pipe_connections = {},
            filter = "steam",
            [temp_field] = temp_value,
        },
    }
    return e
end

if raw.generator and raw.generator["steam-engine"] then
    data:extend({
        -- Control: minimum_temperature is the confirmed acceptance gate.
        make_fbtest("fbtest-min-100", "minimum_temperature", 100),
        -- Confirmed: maximum_temperature gates the same way.
        make_fbtest("fbtest-max-100", "maximum_temperature", 100),
        -- Both bounds at once: an acceptance window [100,300].
        make_fbtest_window("fbtest-window-100-300", 100, 300),
    })
end

if raw["assembling-machine"] and raw["assembling-machine"]["assembling-machine-2"] then
    data:extend({
        make_fes_test("fes-min-100", "minimum_temperature", 100),
        make_fes_test("fes-max-100", "maximum_temperature", 100),
    })
    -- Both-bounded FluidEnergySource fuel window.
    local fes_window = make_fes_test("fes-window-100-300", "minimum_temperature", 100)
    fes_window.energy_source.fluid_box.maximum_temperature = 300
    data:extend({ fes_window })
end

-- ============================================================================
-- 2. FluidEnergySource crafting-machine fuel-mode variants. assembling-machine-2
--    keeps its default crafting categories, so any fluid-using recipe can be
--    assigned one of these machines to drive the fuel math through the solver.
-- ============================================================================

if raw["assembling-machine"] and raw["assembling-machine"]["assembling-machine-2"]
    and raw.fluid and raw.fluid["water"] then
    local function base_fes(name)
        local e = table.deepcopy(raw["assembling-machine"]["assembling-machine-2"])
        e.name = name
        e.localised_name = name
        e.minable = nil
        e.next_upgrade = nil
        e.placeable_by = nil
        e.energy_usage = "100kW"
        return e
    end

    -- burns_fluid=true: consumes a combustible fluid by its fuel_value. Drives
    -- the energy.burns_fluid branch of get_fuel_amount_per_second.
    local burns = base_fes("fs-test-fes-burns-fluid")
    burns.energy_source = {
        type = "fluid",
        burns_fluid = true,
        scale_fluid_usage = true,
        destroy_non_fuel_fluid = true,
        effectivity = 1,
        fluid_box = {
            volume = 200,
            production_type = "input",
            pipe_connections = {},
            filter = "fs-test-fuel-gas",
        },
    }

    -- scale_fluid_usage=false: consumption pinned to fluid_usage_per_tick
    -- regardless of energy demand. Drives the early-return in
    -- get_fuel_amount_per_second.
    local noscale = base_fes("fs-test-fes-no-scale")
    noscale.energy_source = {
        type = "fluid",
        burns_fluid = false,
        scale_fluid_usage = false,
        fluid_usage_per_tick = 0.1,
        destroy_non_fuel_fluid = false,
        maximum_temperature = 1000,
        effectivity = 1,
        fluid_box = {
            volume = 200,
            production_type = "input",
            pipe_connections = {},
            filter = "steam",
        },
    }

    -- Filterless heat-extraction fluid energy source: is_use_any_fluid_fuel is
    -- true, so the line offers every fluid as a fuel candidate.
    local anyfluid = base_fes("fs-test-fes-any-fluid")
    anyfluid.energy_source = {
        type = "fluid",
        burns_fluid = false,
        scale_fluid_usage = true,
        destroy_non_fuel_fluid = false,
        maximum_temperature = 1000,
        effectivity = 1,
        fluid_box = {
            volume = 200,
            production_type = "input",
            pipe_connections = {},
            -- no filter
        },
    }

    data:extend({ burns, noscale, anyfluid })
end

-- ============================================================================
-- 2b. Crafting machines on the other energy-source kinds. assembling-machine-2
--     is electric in vanilla; these swap its energy_source to exercise the
--     burner / void / heat branches of get_energy_source_type, is_use_fuel,
--     try_get_fuel_categories, try_get_fixed_fuel and the power/pollution math.
-- ============================================================================

if raw["assembling-machine"] and raw["assembling-machine"]["assembling-machine-2"] then
    local function base_cm(name)
        local e = table.deepcopy(raw["assembling-machine"]["assembling-machine-2"])
        e.name = name
        e.localised_name = name
        e.minable = nil
        e.next_upgrade = nil
        e.placeable_by = nil
        e.energy_usage = "100kW"
        return e
    end

    -- Multi fuel-category burner: try_get_fuel_categories returns two categories,
    -- exercising join_categories ("chemical|nuclear") + the fuel_categories_-
    -- dictionary union, and get_fuels_in_categories merging both fuel sets.
    -- Vanilla burners declare a single fuel category.
    local multi_burner = base_cm("fs-test-cm-multi-fuel")
    multi_burner.energy_source = {
        type = "burner",
        fuel_categories = { "chemical", "nuclear" },
        fuel_inventory_size = 1,
        effectivity = 1,
        emissions_per_minute = { pollution = 4 },
    }

    -- Void energy source: is_use_fuel / is_generator both false and
    -- raw_energy_usage_to_power returns 0, so the power column should read 0.
    -- No vanilla crafting machine is void-powered.
    local void_cm = base_cm("fs-test-cm-void")
    void_cm.energy_source = { type = "void" }

    -- Heat energy source: try_get_fixed_fuel returns <heat>, so the machine
    -- consumes the <heat> virtual material as fuel. Vanilla heat consumers are
    -- only the heat-exchanger (a boiler); a heat-powered crafting machine is
    -- otherwise untested. Heat-source shape mirrors heat-exchanger's.
    local heat_cm = base_cm("fs-test-cm-heat")
    heat_cm.energy_source = {
        type = "heat",
        max_temperature = 1000,
        specific_heat = "1MJ",
        max_transfer = "2GW",
        min_working_temperature = 500,
        minimum_glow_temperature = 350,
        connections = {
            { position = { 0, 0.5 }, direction = defines.direction.south },
        },
    }

    data:extend({ multi_burner, void_cm, heat_cm })
end

-- ============================================================================
-- 3. Generator fuel-mode variants (steam-engine is burns_fluid=false, filtered).
-- ============================================================================

if raw.generator and raw.generator["steam-engine"] then
    local function base_gen(name)
        local e = table.deepcopy(raw.generator["steam-engine"])
        e.name = name
        e.localised_name = name
        e.minable = nil
        e.next_upgrade = nil
        e.placeable_by = nil
        return e
    end

    -- Filterless heat-extraction generator: is_use_any_fluid_fuel true via the
    -- generator branch (input fluidbox filter == nil). The engine requires a
    -- generator to either filter its fluid_box or define max_power_output;
    -- dropping the filter forces the latter (steam-engine's rated 900kW).
    local genany = base_gen("fs-test-generator-any-fluid")
    genany.fluid_box.filter = nil
    genany.fluid_box.minimum_temperature = nil
    genany.fluid_box.maximum_temperature = nil
    genany.max_power_output = "900kW"

    -- burns_fluid=true generator: burns a combustible fluid by fuel_value
    -- (get_generator_power's burns_fluid branch).
    local genburn = base_gen("fs-test-generator-burns-fluid")
    genburn.burns_fluid = true
    genburn.fluid_box.filter = "fs-test-fuel-gas"
    genburn.fluid_box.minimum_temperature = nil
    genburn.fluid_box.maximum_temperature = nil

    data:extend({ genany, genburn })
end

-- ============================================================================
-- 4. burner-generator. No vanilla entity uses this type, so create_burner_-
--    generator_virtual is otherwise untested. Built from a steam-engine copy:
--    steam-engine already has the electric secondary-output energy_source a
--    burner-generator needs; we add the `burner` fuel input + max_power_output
--    and strip the generator-only fields (field shape confirmed against
--    KS_Power's burner-generator).
-- ============================================================================

if raw.generator and raw.generator["steam-engine"] then
    local src = table.deepcopy(raw.generator["steam-engine"])
    ---@type table
    local bg = {
        type = "burner-generator",
        name = "fs-test-burner-generator",
        localised_name = "fs-test-burner-generator",
        icon = src.icon,
        icon_size = src.icon_size,
        flags = src.flags,
        max_health = src.max_health,
        collision_box = src.collision_box,
        selection_box = src.selection_box,
        max_power_output = "900kW",
        energy_source = {
            type = "electric",
            usage_priority = "secondary-output",
        },
        burner = {
            type = "burner",
            fuel_categories = { "chemical" },
            fuel_inventory_size = 1,
            effectivity = 1,
        },
        -- A single Animation is accepted where Animation4Way is expected; reuse
        -- the steam-engine's horizontal animation so the entity renders.
        animation = src.horizontal_animation,
    }
    data:extend({ bg })
end

-- ============================================================================
-- 5. Boiler variants. Vanilla boiler/heat-exchanger are output-to-separate-pipe
--    with an input filter; the universal heater covers heat-fluid-inside with no
--    filter. These cover the remaining branches of create_boiler_virtual.
-- ============================================================================

if raw.boiler and raw.boiler["boiler"] then
    -- heat-fluid-inside WITH no input filter: enumerates one virtual recipe per
    -- fluid, heating each to its own max_temperature. (Carried over from the
    -- original inline fs-test-universal-heater.)
    if mods["base"] then
        local universal_heater = table.deepcopy(raw.boiler["boiler"])
        universal_heater.name = "fs-test-universal-heater"
        universal_heater.localised_name = "fs-test-universal-heater"
        universal_heater.minable = nil
        universal_heater.mode = "heat-fluid-inside"
        universal_heater.fluid_box.filter = nil
        universal_heater.output_fluid_box.filter = nil
        data:extend({ universal_heater })
    end

    -- heat-fluid-inside WITH an input filter: the filtered counterpart of the
    -- universal heater (single fluid, heated to its own max_temperature).
    local heat_inside = table.deepcopy(raw.boiler["boiler"])
    heat_inside.name = "fs-test-boiler-heat-inside-filtered"
    heat_inside.localised_name = "fs-test-boiler-heat-inside-filtered"
    heat_inside.minable = nil
    heat_inside.next_upgrade = nil
    heat_inside.placeable_by = nil
    heat_inside.mode = "heat-fluid-inside"
    heat_inside.fluid_box.filter = "water"
    data:extend({ heat_inside })

    -- output-to-separate-pipe with NO output filter: create_boiler_virtual's
    -- `output_fluid = output_filter or input_fluid` falls to the input fluid, so
    -- the filtered input (water) is heated to target_temperature and emitted as
    -- itself (water@165). Vanilla boilers always set an output filter (steam).
    local no_output_filter = table.deepcopy(raw.boiler["boiler"])
    no_output_filter.name = "fs-test-boiler-no-output-filter"
    no_output_filter.localised_name = "fs-test-boiler-no-output-filter"
    no_output_filter.minable = nil
    no_output_filter.next_upgrade = nil
    no_output_filter.placeable_by = nil
    no_output_filter.fluid_box.filter = "water"
    no_output_filter.output_fluid_box.filter = nil
    data:extend({ no_output_filter })

    -- "Physically impossible to heat": a heat-fluid-inside boiler on a fluid
    -- whose default_temperature == max_temperature, so delta_t == 0 and the
    -- builder emits the all-zero placeholder column.
    if raw.fluid and raw.fluid["fs-test-uncookable"] then
        local uncookable_boiler = table.deepcopy(raw.boiler["boiler"])
        uncookable_boiler.name = "fs-test-boiler-uncookable"
        uncookable_boiler.localised_name = "fs-test-boiler-uncookable"
        uncookable_boiler.minable = nil
        uncookable_boiler.next_upgrade = nil
        uncookable_boiler.placeable_by = nil
        uncookable_boiler.mode = "heat-fluid-inside"
        uncookable_boiler.fluid_box.filter = "fs-test-uncookable"
        uncookable_boiler.output_fluid_box.filter = "fs-test-uncookable"
        data:extend({ uncookable_boiler })
    end
end

-- ============================================================================
-- 5b. Offshore-pump with a fluid_box filter. The vanilla offshore-pump has an
--     UNFILTERED fluid_box (it pumps whatever the tile holds), so
--     get_offshore_pumps_for_fluid's `filter.name == fluid_name` match branch
--     and its exclusion-on-mismatch are otherwise untested. A filtered pump must
--     appear as a machine option for the matching fluid's tile only.
--     Note: get_fluidbox_filter_prototype reads fluidbox_prototypes[1].filter;
--     an offshore-pump has no fluid_energy_source, so its output box is index 1.
-- ============================================================================

if raw["offshore-pump"] and raw["offshore-pump"]["offshore-pump"] then
    -- Filtered to water: should appear for water-fluid tiles, and be excluded
    -- from any other fluid tile (lava, ammoniacal-ocean, ...).
    local pump_water = table.deepcopy(raw["offshore-pump"]["offshore-pump"])
    pump_water.name = "fs-test-offshore-pump-water"
    pump_water.localised_name = "fs-test-offshore-pump-water"
    pump_water.minable = nil
    pump_water.next_upgrade = nil
    pump_water.placeable_by = nil
    pump_water.fluid_box.filter = "water"
    data:extend({ pump_water })

    -- Negative control: filtered to a REAL fluid that no tile produces
    -- (lubricant is crafted from heavy-oil, never pumped). The pump references a
    -- genuine fluid prototype yet should still match no offshore tile and never
    -- surface in any <pump> recipe's machine list — confirming the exclusion is
    -- driven purely by the tile-fluid <-> filter name match, not by whether the
    -- filtered fluid happens to exist.
    if raw.fluid and raw.fluid["lubricant"] then
        local pump_lubricant = table.deepcopy(raw["offshore-pump"]["offshore-pump"])
        pump_lubricant.name = "fs-test-offshore-pump-lubricant"
        pump_lubricant.localised_name = "fs-test-offshore-pump-lubricant"
        pump_lubricant.minable = nil
        pump_lubricant.next_upgrade = nil
        pump_lubricant.placeable_by = nil
        pump_lubricant.fluid_box.filter = "lubricant"
        data:extend({ pump_lubricant })
    end
end

-- ============================================================================
-- 6. rocket-silo variants. Vanilla SA silo has NO fixed_recipe (uses
--    crafting_categories) and launch_to_space_platforms=true. These cover the
--    opposite branch of each fork in create_rocket_silo_virtual.
-- ============================================================================

if raw["rocket-silo"] and raw["rocket-silo"]["rocket-silo"] then
    -- fixed_recipe set: the silo resolves its rocket-part recipe from
    -- fixed_recipe instead of scanning crafting_categories.
    local fixed_silo = table.deepcopy(raw["rocket-silo"]["rocket-silo"])
    fixed_silo.name = "fs-test-rocket-silo-fixed"
    fixed_silo.localised_name = "fs-test-rocket-silo-fixed"
    fixed_silo.minable = nil
    fixed_silo.next_upgrade = nil
    fixed_silo.placeable_by = nil
    fixed_silo.fixed_recipe = "rocket-part"
    data:extend({ fixed_silo })

    -- launch_to_space_platforms=false: drives the rocket_launch_products branch
    -- (base-game "launch item -> rocket_launch_products" behaviour). Needs at
    -- least one has-rocket-launch-products item, supplied by fs-test-launchable.
    local lp_silo = table.deepcopy(raw["rocket-silo"]["rocket-silo"])
    lp_silo.name = "fs-test-rocket-silo-launch-products"
    lp_silo.localised_name = "fs-test-rocket-silo-launch-products"
    lp_silo.minable = nil
    lp_silo.next_upgrade = nil
    lp_silo.placeable_by = nil
    lp_silo.launch_to_space_platforms = false
    data:extend({ lp_silo })
end

-- ============================================================================
-- 7. Plant with multiple seeds. Vanilla plants are 1 plant : 1 seed; modded
--    plants may have several, which create_plant_virtual emits one recipe per.
-- ============================================================================

if raw.plant and raw.plant["yumako-tree"] and raw.item and raw.item["yumako-seed"] then
    local plant = table.deepcopy(raw.plant["yumako-tree"])
    plant.name = "fs-test-plant"
    plant.localised_name = "fs-test-plant"
    -- Keep `minable`: create_plant_virtual reads mineable_properties.products as
    -- the harvest output, so nil-ing it would emit a productless recipe.
    plant.next_upgrade = nil
    plant.placeable_by = nil
    -- Drop autoplace so the synthetic plant doesn't spawn on Gleba and carries
    -- no planet gate (always pickable for the test).
    plant.autoplace = nil

    local seed_a = table.deepcopy(raw.item["yumako-seed"])
    seed_a.name = "fs-test-seed-a"
    seed_a.localised_name = "fs-test-seed-a"
    seed_a.plant_result = "fs-test-plant"

    local seed_b = table.deepcopy(raw.item["yumako-seed"])
    seed_b.name = "fs-test-seed-b"
    seed_b.localised_name = "fs-test-seed-b"
    seed_b.plant_result = "fs-test-plant"

    data:extend({ plant, seed_a, seed_b })
end

-- ============================================================================
-- 8. Recipe / category / temperature edge recipes.
-- ============================================================================

-- 8a. Single-machine isolated category + a fluid-fuel machine that only accepts
--     steam at >=100C: a one-to-one check of the recipe-picker fuel-temperature
--     filter (503efbb). steam@15 must NOT offer this recipe; steam@>=100 must.
if raw["assembling-machine"] and raw["assembling-machine"]["assembling-machine-2"] then
    local ffm = make_fes_test("fs-test-fuel-filter-machine", "minimum_temperature", 100)
    ffm.crafting_categories = { "fs-test-fuel-filter" }
    data:extend({
        { type = "recipe-category", name = "fs-test-fuel-filter" },
        ffm,
        {
            type = "recipe",
            name = "fs-test-fuel-filter-recipe",
            category = "fs-test-fuel-filter",
            enabled = true,
            energy_required = 1,
            ingredients = { { type = "item", name = "efficiency-module", amount = 1 } },
            results = { { type = "item", name = "speed-module", amount = 1 } },
        },
    })
end

-- 8b. Orphan category: a recipe whose category has no machine at all, so
--     get_machines_in_category / get_machines_for_recipe returns empty. Exercises
--     the empty-machine-list path in the picker and machine resolution.
data:extend({
    { type = "recipe-category", name = "fs-test-orphan-cat" },
    {
        type = "recipe",
        name = "fs-test-orphan-recipe",
        category = "fs-test-orphan-cat",
        enabled = true,
        energy_required = 1,
        ingredients = { { type = "item", name = "iron-plate", amount = 1 } },
        results = { { type = "item", name = "copper-plate", amount = 1 } },
    },
})

-- 8c. Exact-temperature fluid ingredient (single `temperature`, not min/max):
--     exercises the degenerate [T,T] branch in raw_ingredient_to_amount and the
--     picker's exact-temperature slot handling.
if raw.fluid and raw.fluid["steam"] then
    data:extend({
        {
            type = "recipe",
            name = "fs-test-exact-temp-recipe",
            category = "crafting-with-fluid",
            enabled = true,
            energy_required = 1,
            ingredients = {
                { type = "fluid", name = "steam", amount = 10, temperature = 500 },
            },
            results = { { type = "item", name = "iron-plate", amount = 1 } },
        },
    })
end

-- 8d. Split producer: one recipe emitting the SAME fluid at two distinct
--     temperatures, so add_fluid_temperature_virtuals registers two ranges and
--     the picker's "keep if ANY matching slot connects" branch is exercised.
if raw.fluid and raw.fluid["steam"] then
    data:extend({
        {
            type = "recipe",
            name = "fs-test-split-temp-recipe",
            category = "crafting-with-fluid",
            enabled = true,
            energy_required = 1,
            ingredients = { { type = "item", name = "iron-plate", amount = 1 } },
            results = {
                { type = "fluid", name = "steam", amount = 5, temperature = 165 },
                { type = "fluid", name = "steam", amount = 5, temperature = 500 },
            },
            -- Two products -> no single auto-derivable icon; pin main_product so
            -- the recipe icon resolves to the steam fluid icon.
            main_product = "steam",
        },
    })
end

-- 8e. A REGULAR crafting machine carrying `fixed_recipe`. factory_solver reads
--     fixed_recipe only inside the rocket-silo virtual builder; every other
--     crafting machine is resolved purely by crafting-category
--     (get_machines_in_category), so the engine-side recipe lock is ignored.
--     This isolated category holds two recipes (A and B) but only one machine,
--     which is fixed to recipe A. Expected: the machine is offered for BOTH A
--     and B in the picker, and recipe B (which no machine can actually craft
--     in-game, since the sole candidate is locked to A) is still solvable —
--     documenting the category-only resolution / fixed_recipe-blind behaviour.
if raw["assembling-machine"] and raw["assembling-machine"]["assembling-machine-2"] then
    local fixed_machine = table.deepcopy(raw["assembling-machine"]["assembling-machine-2"])
    fixed_machine.name = "fs-test-fixed-recipe-machine"
    fixed_machine.localised_name = "fs-test-fixed-recipe-machine"
    fixed_machine.minable = nil
    fixed_machine.next_upgrade = nil
    fixed_machine.placeable_by = nil
    fixed_machine.crafting_categories = { "fs-test-fixed-cat" }
    fixed_machine.fixed_recipe = "fs-test-fixed-recipe-a"
    data:extend({
        { type = "recipe-category", name = "fs-test-fixed-cat" },
        fixed_machine,
        {
            type = "recipe",
            name = "fs-test-fixed-recipe-a",
            category = "fs-test-fixed-cat",
            enabled = true,
            energy_required = 1,
            ingredients = { { type = "item", name = "iron-plate", amount = 1 } },
            results = { { type = "item", name = "copper-plate", amount = 1 } },
        },
        {
            type = "recipe",
            name = "fs-test-fixed-recipe-b",
            category = "fs-test-fixed-cat",
            enabled = true,
            energy_required = 1,
            ingredients = { { type = "item", name = "copper-plate", amount = 1 } },
            results = { { type = "item", name = "iron-plate", amount = 1 } },
        },
    })
end
