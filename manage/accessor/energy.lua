-- Energy-source, power, pollution and fuel math for a machine running at full
-- throughput: electric draw / production, emission rates, generator power
-- bounded by fuel density, fuel consumption per second, and the fixed-fuel /
-- fluid-fuel-temperature selection + reconciliation. Energy and fuel are
-- mutually coupled (pollution needs the fuel multiplier; fuel amount needs the
-- raw power), so they live together here. Part of the manage/accessor.lua
-- family; reached through the accessor facade.

local fs_util = require "fs_util"
local tn = require "manage/typed_name"
local prototype_acc = require "manage/accessor/prototype"

local M = {}

---comment
---@param machine LuaEntityPrototype
---@param quality QualityID
---@param effectivity_consumption number
---@return number
function M.raw_energy_usage_to_power(machine, quality, effectivity_consumption)
    local energy_per_tick = machine.get_max_energy_usage(quality) * effectivity_consumption

    if machine.burner_prototype then
        energy_per_tick = energy_per_tick / machine.burner_prototype.effectivity
    elseif machine.heat_energy_source_prototype then
        -- no operation
    elseif machine.fluid_energy_source_prototype then
        energy_per_tick = energy_per_tick / machine.fluid_energy_source_prototype.effectivity
    elseif machine.void_energy_source_prototype then
        energy_per_tick = 0
    elseif machine.electric_energy_source_prototype then
        -- Last to not be applied to generators.
        energy_per_tick = energy_per_tick + machine.electric_energy_source_prototype.drain
    else
        -- entity-ghost fallback (see typed_name_to_machine): no energy source.
        return 0
    end

    return energy_per_tick * fs_util.second_per_tick
end

---comment
---@param machine LuaEntityPrototype
---@param pollutant_type string
---@param quality QualityID
---@param effectivity_consumption number
---@param effectivity_pollution number
---@return number
function M.raw_emission_to_pollution(machine, pollutant_type, quality, effectivity_consumption, effectivity_pollution)
    local energy_per_tick = machine.get_max_energy_usage(quality) * effectivity_consumption * effectivity_pollution
    local emissions_per_joule

    if machine.burner_prototype then
        emissions_per_joule = machine.burner_prototype.emissions_per_joule
    elseif machine.heat_energy_source_prototype then
        emissions_per_joule = machine.heat_energy_source_prototype.emissions_per_joule
    elseif machine.fluid_energy_source_prototype then
        emissions_per_joule = machine.fluid_energy_source_prototype.emissions_per_joule
    elseif machine.void_energy_source_prototype then
        emissions_per_joule = machine.void_energy_source_prototype.emissions_per_joule
    elseif machine.electric_energy_source_prototype then
        -- Last to not be applied to generators.
        emissions_per_joule = machine.electric_energy_source_prototype.emissions_per_joule
    else
        -- entity-ghost fallback (see typed_name_to_machine): no energy source.
        return 0
    end

    return emissions_per_joule[pollutant_type] * energy_per_tick * fs_util.second_per_tick
end

---Per-second emission rate at full throughput, combining the energy
---source's base (raw_emission_to_pollution) with the burned fuel's
---multiplier (fuel_emissions_multiplier for items, emissions_multiplier
---for fluids). Returns the base rate alone for non-fuel machines.
---@param machine LuaEntityPrototype
---@param pollutant_type string
---@param quality QualityID
---@param effectivity_consumption number
---@param effectivity_pollution number
---@param fuel_typed_name TypedName?
---@return number
function M.get_pollution_per_second(machine, pollutant_type, quality,
    effectivity_consumption, effectivity_pollution, fuel_typed_name)
    local pollution = M.raw_emission_to_pollution(machine, pollutant_type, quality,
        effectivity_consumption, effectivity_pollution)
    if M.is_use_fuel(machine) and fuel_typed_name then
        local fuel = tn.typed_name_to_material(fuel_typed_name)
        pollution = pollution * M.get_fuel_emissions_multiplier(fuel)
    end
    return pollution
end

---comment
---@param machine LuaEntityPrototype
---@param quality QualityID
---@return number
function M.raw_energy_production_to_power(machine, quality)
    return -machine.get_max_energy_production(quality) * fs_util.second_per_tick
end

---Returns the actual electrical power produced by a generator at its rated
---throughput, bounded by both max_power_output and the supplied fuel's
---energy density (fluid_usage_per_tick * fuel_energy * effectivity). Sign
---convention matches raw_energy_production_to_power: negative = output. For
---non-generator entities or when fuel info is missing, returns the uncapped
---max so the caller doesn't have to branch.
---@param machine LuaEntityPrototype
---@param machine_quality QualityID
---@param fuel LuaItemPrototype | LuaFluidPrototype | VirtualMaterial?
---@param fuel_typed_name TypedName?
---@return number
function M.get_generator_power(machine, machine_quality, fuel, fuel_typed_name)
    local max_power = -machine.get_max_energy_production(machine_quality) * fs_util.second_per_tick

    if machine.type ~= "generator" then
        return max_power
    end

    local energy_per_unit = 0
    ---@diagnostic disable: param-type-mismatch
    if fuel and fuel.object_name == "LuaFluidPrototype" then
        if machine.burns_fluid then
            energy_per_unit = fuel.fuel_value
        else
            local input_t = fuel.max_temperature
            if fuel_typed_name then
                input_t = fuel_typed_name.maximum_temperature
                    or input_t
            end
            local cap = machine.maximum_temperature
            if cap and cap > 0 and input_t > cap then
                input_t = cap
            end
            local delta = input_t - fuel.default_temperature
            if delta > 0 then
                energy_per_unit = delta * fuel.heat_capacity
            end
        end
    end
    ---@diagnostic enable: param-type-mismatch

    if energy_per_unit == 0 then
        return max_power
    end

    -- get_fluid_usage_per_tick(quality) returns the engine-resolved per-tick
    -- consumption at the requested quality (Factorio 2.0.x runtime API). It
    -- replaces the previous hardcoded `1 + level * 0.3` multiplier on
    -- fluid_usage_per_tick, which assumed vanilla QualityPrototype constants;
    -- the engine call now picks up any modded customisation transparently.
    local consumption = machine.get_fluid_usage_per_tick(machine_quality) * fs_util.second_per_tick
    local effectivity_value = machine.effectivity or 1
    local fuel_power = -consumption * energy_per_unit * effectivity_value

    -- Both values are negative (output). The bottleneck has the smaller
    -- magnitude, i.e. the value closer to zero.
    if fuel_power > max_power then
        return fuel_power
    end
    return max_power
end

---Per-second electric power flow for a machine running at full throughput.
---Positive = consumption, negative = production, zero = the machine
---exchanges its energy in fuel form (and so doesn't appear on the electric
---grid). Generators are bounded by both max_power_output and the supplied
---fuel's energy density.
---@param machine LuaEntityPrototype
---@param machine_quality QualityID
---@param effectivity_consumption number
---@param fuel_typed_name TypedName?
---@return number
function M.get_power_per_second(machine, machine_quality, effectivity_consumption, fuel_typed_name)
    if M.is_generator(machine) then
        local fuel = fuel_typed_name and tn.typed_name_to_material(fuel_typed_name)
        return M.get_generator_power(machine, machine_quality, fuel, fuel_typed_name)
    end
    if M.is_use_fuel(machine) then
        return 0
    end
    return M.raw_energy_usage_to_power(machine, machine_quality, effectivity_consumption)
end

---comment
---@param machine LuaEntityPrototype
---@param machine_quality QualityID
---@param fuel LuaItemPrototype | LuaFluidPrototype | VirtualMaterial
---@param fuel_quality QualityID
---@param effectivity_consumption number
---@param fuel_typed_name TypedName?
---@return number
function M.get_fuel_amount_per_second(machine, machine_quality, fuel, fuel_quality, effectivity_consumption, fuel_typed_name)
    if machine.type == "generator" then
        -- See get_generator_power for the rationale: route through the
        -- engine's quality-aware getter instead of hardcoding the vanilla
        -- 30%/tier multiplier so modded QualityPrototype values flow through.
        return machine.get_fluid_usage_per_tick(machine_quality) * fs_util.second_per_tick
    end

    local energy = machine.fluid_energy_source_prototype
    if energy then
        if not energy.scale_fluid_usage then
            -- scale=false: consumption is pinned to fluid_usage_per_tick regardless
            -- of energy demand; the engine discards any excess.
            return energy.fluid_usage_per_tick * fs_util.second_per_tick
        end

        local power = M.raw_energy_usage_to_power(machine, machine_quality, effectivity_consumption)
        local energy_per_unit = 0
        ---@diagnostic disable: param-type-mismatch
        if energy.burns_fluid then
            if fuel.object_name == "LuaFluidPrototype" then
                energy_per_unit = fuel.fuel_value
            end
        elseif fuel.object_name == "LuaFluidPrototype" then
            -- burns_fluid=false: extracts (T_in - default_temperature) * heat_capacity per unit.
            -- The engine caps T_in at FluidEnergySource.maximum_temperature (0 means no cap).
            local input_t = fuel.max_temperature
            if fuel_typed_name then
                input_t = fuel_typed_name.maximum_temperature
                    or input_t
            end
            local cap = energy.maximum_temperature
            if cap and cap > 0 and input_t > cap then
                input_t = cap
            end
            local delta = input_t - fuel.default_temperature
            if delta > 0 then
                energy_per_unit = delta * fuel.heat_capacity
            end
        end
        ---@diagnostic enable: param-type-mismatch
        return (energy_per_unit == 0) and 0 or power / energy_per_unit
    end

    ---@diagnostic disable: param-type-mismatch
    local fuel_value = 1
    if fuel.object_name == "LuaItemPrototype" then
        fuel_value = fuel.fuel_value
    elseif fuel.object_name == "LuaFluidPrototype" then
        fuel_value = fuel.fuel_value
    end
    ---@diagnostic enable: param-type-mismatch
    local power = M.raw_energy_usage_to_power(machine, machine_quality, effectivity_consumption)
    return (fuel_value == 0) and 0 or power / fuel_value
end

---comment
---@param material LuaItemPrototype | LuaFluidPrototype | VirtualMaterial
---@return number
function M.get_fuel_emissions_multiplier(material)
    ---@diagnostic disable: param-type-mismatch
    if material.object_name == "LuaItemPrototype" then
        return material.fuel_emissions_multiplier
    elseif material.object_name == "LuaFluidPrototype" then
        return material.emissions_multiplier
    else
        return 1
    end
    ---@diagnostic enable: param-type-mismatch
end

---The item produced when this fuel is burned (e.g. uranium-fuel-cell ->
---used-up-uranium-fuel-cell). Only item fuels have a burnt_result; fluid /
---virtual fuels return nil. Reading `.burnt_result` is gated on the
---LuaItemPrototype discriminant so it never indexes a field that doesn't
---exist on the other prototype variants (see CLAUDE.md union-typing rule).
---@param material LuaItemPrototype | LuaFluidPrototype | VirtualMaterial
---@return LuaItemPrototype?
function M.try_get_burnt_result(material)
    ---@diagnostic disable-next-line: param-type-mismatch
    if material.object_name == "LuaItemPrototype" then
        ---@diagnostic disable-next-line: param-type-mismatch
        return material.burnt_result
    end
    return nil
end

---comment
---@param machine LuaEntityPrototype
---@return EnergyType
function M.get_energy_source_type(machine)
    if machine.burner_prototype then
        return "burner"
    elseif machine.heat_energy_source_prototype then
        return "heat"
    elseif machine.fluid_energy_source_prototype then
        return "fluid"
    elseif machine.void_energy_source_prototype then
        return "void"
    elseif machine.electric_energy_source_prototype then
        -- Last to not be applied to generators.
        if machine.type == "generator" then
            return "fluid"
        else
            return "electric"
        end
    else
        -- entity-ghost fallback (see typed_name_to_machine): no energy source,
        -- report as void so is_use_fuel / is_generator both return false.
        return "void"
    end
end

---comment
---@param machine LuaEntityPrototype
---@return { [string]: true }?
function M.try_get_fuel_categories(machine)
    if machine.burner_prototype then
        return machine.burner_prototype.fuel_categories
    else
        return nil
    end
end

---Round-trip a temperature through "%g" so it matches the format that
---register_fluid_temperature_range / typed_name_to_variable_name emit. Without
---this, single-precision quantization (a fluid declared at 0.01 reads back as
---0.0099999, per CLAUDE.md) makes the raw acceptance-range TypedName differ
---byte-for-byte from the picker's range button (decoded from a "%g" key), so
---the range button never lights up as the selected default. A no-op for the
---clean integer temperatures of essentially every real fluid fuel.
---@param t number
---@return number
local function normalize_temperature(t)
    return tonumber(string.format("%g", t)) --[[@as number]]
end

---comment
---@param machine LuaEntityPrototype
---@return TypedName?
function M.try_get_fixed_fuel(machine)
    if machine.heat_energy_source_prototype then
        return tn.create_typed_name("virtual_material", "<heat>")
    elseif machine.fluid_energy_source_prototype then
        local energy = assert(machine.fluid_energy_source_prototype)
        local fluidbox = energy.fluid_box
        local filter = fluidbox.filter
        if not filter then
            return nil
        end
        -- The ACCEPTANCE range is the fuel fluidbox's own temperature filter,
        -- NOT energy.maximum_temperature. maximum_temperature is only the
        -- energy-conversion cap: fluid hotter than it is still accepted, with the
        -- excess heat wasted (get_fuel_amount_per_second applies that cap). Using
        -- it as the acceptance ceiling wrongly bars the machine from taking hotter
        -- fuel (e.g. a Pyanodons nuclear-reactor-mk01, cap 250, accepts uf6 up to
        -- its physical 10000). Same rule as the generator branch below; tame the
        -- FLT sentinels Factorio returns for unset fluidbox temperature bounds.
        local min_temp = fluidbox.minimum_temperature
        local max_temp = fluidbox.maximum_temperature
        if not min_temp or min_temp < filter.default_temperature then
            min_temp = filter.default_temperature
        end
        if not max_temp or max_temp > filter.max_temperature then
            max_temp = filter.max_temperature
        end
        return tn.create_typed_name("fluid", filter.name, nil,
            normalize_temperature(min_temp), normalize_temperature(max_temp))
    elseif machine.type == "generator" then
        -- The ACCEPTANCE range is the input fluidbox's own temperature filter,
        -- NOT machine.maximum_temperature. maximum_temperature is only the
        -- energy-conversion cap: steam hotter than it is still consumed, with the
        -- excess heat wasted (get_generator_power applies that cap). Using it as
        -- the acceptance ceiling wrongly bars the generator from taking hotter
        -- steam (e.g. a 100-5000 C turbine showed up as 15-165). A generator has
        -- no fluid_energy_source, so the input box is index 1.
        local fluidbox = machine.fluidbox_prototypes[1]
        local filter = fluidbox and fluidbox.filter
        if not filter then
            return nil
        end
        -- Fall back to the fluid's physical range and tame the FLT sentinels
        -- Factorio returns for unset fluidbox temperature bounds.
        local min_temp = fluidbox.minimum_temperature
        local max_temp = fluidbox.maximum_temperature
        if not min_temp or min_temp < filter.default_temperature then
            min_temp = filter.default_temperature
        end
        if not max_temp or max_temp > filter.max_temperature then
            max_temp = filter.max_temperature
        end
        return tn.create_typed_name("fluid", filter.name, nil,
            normalize_temperature(min_temp), normalize_temperature(max_temp))
    else
        return nil
    end
end

---Reconcile a (possibly stale) fluid fuel selection against `machine` so the
---stored temperature follows the machine's current acceptance range. A default
---RANGE is re-derived to the machine's range; a deliberate single-temperature
---pick (min==max) is preserved when still accepted, else snapped to the range.
---A fluid that the fixed-filter machine doesn't accept comes back as the
---machine's own fuel. Non-fluid fuels (item/heat) and filterless any-fluid
---machines (try_get_fixed_fuel returns nil) are returned unchanged. Mirrors the
---new-line derivation in save.new_production_line; idempotent so repeated calls
---(e.g. the on_fuel_click re-dispatch into on_make_fuel_table) are value no-ops.
---@param fuel_typed_name TypedName?
---@param machine LuaEntityPrototype
---@return TypedName?
function M.reconcile_fluid_fuel_for_machine(fuel_typed_name, machine)
    if not (fuel_typed_name and fuel_typed_name.type == "fluid") then
        return fuel_typed_name
    end
    local fixed = M.try_get_fixed_fuel(machine)
    if not (fixed and fixed.type == "fluid") then
        return fuel_typed_name -- filterless any-fluid / non-fluid fuel: leave as-is
    end
    if fuel_typed_name.name == fixed.name then
        local mn, mx = fuel_typed_name.minimum_temperature, fuel_typed_name.maximum_temperature
        local lo, hi = fixed.minimum_temperature, fixed.maximum_temperature
        if mn ~= nil and mn == mx and lo ~= nil and hi ~= nil and lo <= mn and mn <= hi then
            return fuel_typed_name -- in-range single pick preserved
        end
    end
    return fixed -- stale range / out-of-range pick / different fluid -> machine range
end

---Reconcile a stored fuel to `machine` across every fuel mode, for use when the
---machine changes (a switch between item / heat / fluid fuels must update the
---selection in both directions). Returns (fuel, needs_preset):
--- * fuel-less machine (electric / void): (nil, false) -- caller leaves fuel as-is.
--- * heat machine: (<heat>, false).
--- * fixed-filter fluid machine: (reconciled fluid, false) -- a fluid fuel keeps or
---   snaps its temperature, a non-fluid fuel adopts the machine's fluid range.
--- * item (burner) / filterless any-fluid machine: the current fuel if it is still
---   in the machine's fuel list, else (nil, true) so the caller substitutes its
---   preset (accessor cannot reach manage/preset).
---@param fuel_typed_name TypedName?
---@param machine LuaEntityPrototype
---@return TypedName?, boolean
function M.reconcile_fuel_for_machine(fuel_typed_name, machine)
    if not M.is_use_fuel(machine) then
        return nil, false
    end
    local fixed = M.try_get_fixed_fuel(machine)
    if fixed and fixed.type == "virtual_material" then
        return fixed, false -- heat
    elseif fixed and fixed.type == "fluid" then
        if fuel_typed_name and fuel_typed_name.type == "fluid" then
            return M.reconcile_fluid_fuel_for_machine(fuel_typed_name, machine), false
        end
        return fixed, false -- coming from a non-fluid fuel: adopt the machine's fluid
    end

    -- item (burner) or filterless any-fluid: keep an in-list fuel, else need preset.
    local fuels
    local categories = M.try_get_fuel_categories(machine)
    if categories then
        fuels = prototype_acc.get_fuels_in_categories(categories)
    elseif M.is_use_any_fluid_fuel(machine) then
        fuels = prototype_acc.get_any_fluid_fuels()
    end
    if fuels and fuel_typed_name then
        local name = fuel_typed_name.name
        local pos = fs_util.find(fuels, function(value)
            return value.name == name
        end)
        if pos then
            return fuel_typed_name, false
        end
    end
    return nil, true
end

---comment
---@param machine LuaEntityPrototype
---@return boolean
function M.is_use_fuel(machine)
    local energy_source_type = M.get_energy_source_type(machine)
    return energy_source_type == "burner" or energy_source_type == "heat" or energy_source_type == "fluid"
end

---comment
---@param machine LuaEntityPrototype
---@return boolean
function M.is_use_any_fluid_fuel(machine)
    if machine.fluid_energy_source_prototype then
        return machine.fluid_energy_source_prototype.fluid_box.filter == nil
    end
    -- Generators carry their fluid input on the entity itself, not through a
    -- FluidEnergySource. A filterless input means any fluid fuel goes.
    -- burner-generator is solid-fueled and falls through to false here.
    if machine.type == "generator" then
        return prototype_acc.get_fluidbox_filter_prototype(machine, 1) == nil
    end
    return false
end

---comment
---@param machine LuaEntityPrototype
---@return boolean
function M.is_generator(machine)
    return machine.type == "generator"
        or machine.type == "burner-generator"
        or machine.type == "fusion-generator"
end

---Returns the fluid-fuel temperature options to offer in the picker for a
---burns_fluid=false machine (one where extracted energy depends on input
---temperature). The first entry is the machine's full ACCEPTANCE-range
---variant (the default "any temperature in range" pick); the rest are the
---distinct single temperatures other recipes actually produce this fluid at,
---clipped to the acceptance range. Returns nil / an empty list when there is
---nothing to choose between — a non-fluid or burns_fluid=true fuel, a
---filterless any-fluid machine (unbounded candidate set), a machine that
---accepts only one exact temperature (lo == hi), or a fluid no recipe produces
---a point temperature for in-range. The caller hides the picker on empty.
---
---We clip to the acceptance range but deliberately NOT to the machine's
---energy-conversion cap: the engine accepts fluid hotter than the cap and just
---discards the excess heat, so an in-range-but-above-cap temperature is a valid
---(if wasteful) pick the user may want to model. get_generator_power /
---get_fuel_amount_per_second clamp T_in downstream.
---@param machine LuaEntityPrototype
---@return VirtualMaterial[]?
function M.get_fluid_fuel_temperature_variants(machine)
    ---@type LuaFluidPrototype?
    local filter
    if machine.fluid_energy_source_prototype then
        local energy = assert(machine.fluid_energy_source_prototype)
        if energy.burns_fluid then return nil end
        filter = energy.fluid_box.filter
    elseif machine.type == "generator" then
        if machine.burns_fluid then return nil end
        filter = prototype_acc.get_fluidbox_filter_prototype(machine, 1)
    else
        return nil
    end
    if not filter then return nil end

    local fixed = M.try_get_fixed_fuel(machine)
    if not (fixed and fixed.type == "fluid") then return nil end
    local lo, hi = fixed.minimum_temperature, fixed.maximum_temperature
    if lo == nil or hi == nil or lo == hi then
        -- Degenerate acceptance range: the machine takes exactly one
        -- temperature, so there is no range-vs-point choice to offer.
        return {}
    end

    -- Collect this fluid's registered single-temperature points (the degenerate
    -- ranges where minimum_temperature == maximum_temperature) that fall within
    -- the acceptance range. Matched off VirtualMaterial fields, not the name key,
    -- so the filter is grep-discoverable and survives a key-format change.
    local points = {}
    for _, material in pairs(storage.virtuals.material) do
        if material.source_fluid_name == filter.name
            and material.minimum_temperature ~= nil
            and material.minimum_temperature == material.maximum_temperature
            and lo <= material.minimum_temperature and material.minimum_temperature <= hi then
            points[#points + 1] = material
        end
    end
    if #points == 0 then return {} end
    fs_util.sort_prototypes(points)

    -- Prepend the acceptance-range variant (the default). Reuse the registered
    -- material when one exists, else synthesize a transient one from the fluid
    -- prototype; source_fluid_name is required by is_unresearched / tooltips.
    local range_key = string.format("fluid/%s@[%g,%g]", filter.name, lo, hi)
    local range_material = storage.virtuals.material[range_key]
    if range_material then
        -- register_fluid_temperature_range stores the RAW (un-%g-normalized)
        -- temperatures on the material; only its key is built with "%g". `lo, hi`
        -- here come from try_get_fixed_fuel and are already %g-normalized to match
        -- the reconciled fuel TypedName. Without re-normalizing, the picker
        -- button's decoded TypedName (craft_to_typed_name reads these raw fields)
        -- fails equals_typed_name's strict == against the stored selection for any
        -- fluid whose acceptance bound isn't %g-clean in single precision, so the
        -- default range variant never highlights as selected. Copy (never mutate
        -- the shared storage entry) and overwrite with the normalized bounds.
        local copy = {}
        for k, v in pairs(range_material) do copy[k] = v end
        copy.minimum_temperature = lo
        copy.maximum_temperature = hi
        range_material = copy
    else
        ---@type VirtualMaterial
        range_material = {
            type = "virtual_material",
            name = range_key,
            sprite_path = "fluid/" .. filter.name,
            elem_tooltip = { type = "fluid", name = filter.name },
            order = filter.order .. string.format("@z[%020.6f,%020.6f]", lo, hi),
            group_name = filter.group.name,
            subgroup_name = filter.subgroup.name,
            hidden = filter.hidden,
            source_fluid_name = filter.name,
            minimum_temperature = lo,
            maximum_temperature = hi,
        }
    end

    local results = { range_material }
    for _, p in ipairs(points) do
        results[#results + 1] = p
    end
    return results
end

return M
