-- Facade for the accessor layer.
--
-- The implementation lives in the responsibility-split sub-modules under
-- manage/accessor/ (prototype catalog queries, quality scaling, amount
-- normalization, recipe scalars, energy/fuel math, module/beacon effectivity,
-- and the normalize_production_line orchestrator). This file re-exports every
-- public name so the ~20 consumers keep calling `acc.fn(...)` unchanged.
--
-- The re-exports are written out explicitly (M.x = sub.x) rather than merged in
-- a loop, on purpose: it keeps every public name greppable here together with
-- the module that owns it, and it carries each function's LuaCATS signature
-- through to the call sites (a merge loop would collapse the facade to an
-- untyped table and lose that type checking — the main regression net for this
-- split). When adding a function to a sub-module, add its re-export line here.

local fs_util = require "fs_util"
local nf = require "manage/number_format"
local prototype_acc = require "manage/accessor/prototype"
local quality_acc = require "manage/accessor/quality"
local amount_acc = require "manage/accessor/amount"
local recipe_acc = require "manage/accessor/recipe"
local energy_acc = require "manage/accessor/energy"
local modules_acc = require "manage/accessor/modules"
local normalize_acc = require "manage/accessor/normalize"

local M = {}

-- Constants. The single source of truth is fs_util (shared leaf, broadly
-- required); re-exposed here so the existing `acc.second_per_tick` /
-- `acc.tolerance` consumers stay unchanged.
M.second_per_tick = fs_util.second_per_tick
M.tolerance = fs_util.tolerance

---True when a material's net per-second flow is within the solver's RELATIVE
---residual of zero, judged against its gross throughput. Thin pass-through to
---nf.is_negligible bound to this module's tolerance, so the totals UI's
---show/hide cutoff scales with flow instead of using a fixed absolute pad
---(which mistook a big recycling loop's ~1e-4 noise for a phantom ingredient).
---@param net number
---@param gross number
---@return boolean
function M.is_negligible(net, gross)
    return nf.is_negligible(net, gross, M.tolerance)
end

-- Prototype catalog queries -- manage/accessor/prototype.lua
M.join_categories = prototype_acc.join_categories
M.get_module = prototype_acc.get_module
M.get_beacon = prototype_acc.get_beacon
M.get_machines_in_category = prototype_acc.get_machines_in_category
M.machine_allows_recipe = prototype_acc.machine_allows_recipe
M.get_general_machines_in_category = prototype_acc.get_general_machines_in_category
M.get_machines_in_resource_category = prototype_acc.get_machines_in_resource_category
M.get_offshore_pumps_for_fluid = prototype_acc.get_offshore_pumps_for_fluid
M.get_labs_for_pack = prototype_acc.get_labs_for_pack
M.get_machines_for_recipe = prototype_acc.get_machines_for_recipe
M.get_fuels_in_categories = prototype_acc.get_fuels_in_categories
M.get_any_fluid_fuels = prototype_acc.get_any_fluid_fuels
M.is_hidden = prototype_acc.is_hidden
M.entity_is_unresearched = prototype_acc.entity_is_unresearched
M.is_unresearched = prototype_acc.is_unresearched
M.get_fluidbox_filter_prototype = prototype_acc.get_fluidbox_filter_prototype
M.get_plant_substrate_tiles = prototype_acc.get_plant_substrate_tiles

-- Quality scaling -- manage/accessor/quality.lua
M.get_quality_level = quality_acc.get_quality_level
M.get_quality_default_multiplier = quality_acc.get_quality_default_multiplier
M.get_module_quality_multiplier = quality_acc.get_module_quality_multiplier

-- Amount normalization / fluid-temperature widening -- manage/accessor/amount.lua
M.raw_product_to_amount = amount_acc.raw_product_to_amount
M.apply_lab_input_productivity_to_ingredient = amount_acc.apply_lab_input_productivity_to_ingredient
M.raw_ingredient_to_amount = amount_acc.raw_ingredient_to_amount
M.resolve_bare_fluid_product = amount_acc.resolve_bare_fluid_product
M.resolve_bare_fluid_ingredient = amount_acc.resolve_bare_fluid_ingredient

-- Recipe scalars / masks / virtual rate -- manage/accessor/recipe.lua
M.get_crafting_energy = recipe_acc.get_crafting_energy
M.get_crafting_speed_cap = recipe_acc.get_crafting_speed_cap
M.get_maximum_productivity = recipe_acc.get_maximum_productivity
M.get_allowed_effects = recipe_acc.get_allowed_effects
M.get_allowed_module_categories = recipe_acc.get_allowed_module_categories
M.get_virtual_recipe_rates = recipe_acc.get_virtual_recipe_rates

-- Energy / power / pollution / fuel -- manage/accessor/energy.lua
M.raw_energy_usage_to_power = energy_acc.raw_energy_usage_to_power
M.raw_emission_to_pollution = energy_acc.raw_emission_to_pollution
M.get_pollution_per_second = energy_acc.get_pollution_per_second
M.raw_energy_production_to_power = energy_acc.raw_energy_production_to_power
M.get_generator_power = energy_acc.get_generator_power
M.get_power_per_second = energy_acc.get_power_per_second
M.get_fuel_amount_per_second = energy_acc.get_fuel_amount_per_second
M.get_fuel_emissions_multiplier = energy_acc.get_fuel_emissions_multiplier
M.try_get_burnt_result = energy_acc.try_get_burnt_result
M.get_energy_source_type = energy_acc.get_energy_source_type
M.try_get_fuel_categories = energy_acc.try_get_fuel_categories
M.try_get_fixed_fuel = energy_acc.try_get_fixed_fuel
M.reconcile_fluid_fuel_for_machine = energy_acc.reconcile_fluid_fuel_for_machine
M.reconcile_fuel_for_machine = energy_acc.reconcile_fuel_for_machine
M.is_use_fuel = energy_acc.is_use_fuel
M.is_use_any_fluid_fuel = energy_acc.is_use_any_fluid_fuel
M.is_generator = energy_acc.is_generator
M.get_fluid_fuel_temperature_variants = energy_acc.get_fluid_fuel_temperature_variants

-- Module / beacon aggregation and effectivity -- manage/accessor/modules.lua
M.is_quality_module = modules_acc.is_quality_module
M.is_module_effective = modules_acc.is_module_effective
M.is_use_beacon = modules_acc.is_use_beacon
M.get_beacon_distribution_effectivity = modules_acc.get_beacon_distribution_effectivity
M.get_beacon_profile_multiplier = modules_acc.get_beacon_profile_multiplier
M.trim_modules = modules_acc.trim_modules
M.get_machine_module_inventory_size = modules_acc.get_machine_module_inventory_size
M.get_total_modules = modules_acc.get_total_modules
M.split_total_modules_by_effectiveness = modules_acc.split_total_modules_by_effectiveness
M.get_total_effectivity = modules_acc.get_total_effectivity

-- Production-line orchestration -- manage/accessor/normalize.lua
M.normalize_production_line = normalize_acc.normalize_production_line

return M
