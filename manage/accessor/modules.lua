-- Module / beacon aggregation and effect folding: how a line's machine and
-- beacon module slots combine into a single ModuleEffects (speed / productivity
-- / consumption / pollution / quality), masked per source by the recipe∩entity
-- allowed_effects, plus the effective-vs-ineffective split the UI renders.
-- Part of the manage/accessor.lua family; reached through the accessor facade.

local flib_table = require "__flib__/table"
local prototype_acc = require "manage/accessor/prototype"
local quality_acc = require "manage/accessor/quality"
local recipe_acc = require "manage/accessor/recipe"

local M = {}

---True for modules whose effect set includes a positive quality bonus
---(e.g. the vanilla quality module). Used to warn in the machine dialog when
---such a module is set while the force has unlocked no quality above normal,
---so the cascade cannot advance and the module would have no visible effect.
---@param name string?
---@return boolean
function M.is_quality_module(name)
    local module = prototype_acc.get_module(name)
    if not module then
        return false
    end
    local effects = module.module_effects
    return effects ~= nil and (effects.quality or 0) > 0
end

---Sign of the "beneficial" direction for each module effect kind. A module
---only counts as useful when at least one of its effects is on the
---beneficial side of zero AND the corresponding effect is allowed. Without
---this sign table, a productivity module on a productivity-disallowed
---recipe would still register as "effective" via its incidental speed
---penalty (which is the opposite of useful).
local beneficial_effect_sign = {
    speed = 1,
    productivity = 1,
    quality = 1,
    consumption = -1,
    pollution = -1,
}

---True iff `module` would actually do something useful under the given
---allow masks. Returns false when the module's category is excluded from
---`allowed_module_categories` (when it's non-nil), OR when every
---*beneficial* effect direction the module carries is masked off by
---`allowed_effects`. Used by the module picker UI to grey out modules that
---won't contribute on the current (recipe, machine) or (recipe, beacon)
---pair.
---@param module LuaItemPrototype
---@param allowed_effects table<string, boolean>
---@param allowed_categories table<string, true>?
---@return boolean
function M.is_module_effective(module, allowed_effects, allowed_categories)
    if allowed_categories and not allowed_categories[module.category] then
        return false
    end
    local effects = module.module_effects
    if not effects then return false end
    for kind, value in pairs(effects) do
        local sign = beneficial_effect_sign[kind]
        if sign and value * sign > 0 and allowed_effects[kind] then
            return true
        end
    end
    return false
end

---True for machines that can receive beacon effects. effect_receiver is nil
---for entities that take neither modules nor beacons (boilers, generators, ...),
---and uses_beacon_effects may be false even when modules are accepted, so both
---are checked.
---@param machine LuaEntityPrototype
---@return boolean
function M.is_use_beacon(machine)
    local effect_receiver = machine.effect_receiver
    return effect_receiver ~= nil and effect_receiver.uses_beacon_effects == true
end

---Return the quality-scaled distribution_effectivity of a beacon.
---Factorio 2.0 beacons have no `get_distribution_effectivity(quality)`
---runtime method, so the value is composed from two prototype reads:
---  effective = distribution_effectivity
---            + quality_level * distribution_effectivity_bonus_per_quality_level
---bonus_per_quality_level is optional on the prototype; treat a missing
---value as 0 so vanilla beacons (which do define it) and modded beacons
---that opt out both behave correctly.
---@param beacon LuaEntityPrototype
---@param quality QualityID
---@return number
function M.get_beacon_distribution_effectivity(beacon, quality)
    local base = assert(beacon.distribution_effectivity)
    local bonus = beacon.distribution_effectivity_bonus_per_quality_level or 0
    local level = quality_acc.get_quality_level(quality)
    return base + level * bonus
end

---Return the diminishing-returns multiplier from a beacon's `profile` for a
---given number of beacons reaching the receiving machine. `profile` is a 1-based
---array of doubles sampled by the beacon count; counts past the array length
---reuse the last entry (engine behaviour). An undefined or empty profile is the
---engine default `{1}` — no diminishing returns, so non-Space-Age and modded
---beacons that omit it behave as before. `beacon_count` is chosen by the caller
---per the beacon's `beacon_counter` ("total" vs "same_type"); counts below 1
---clamp to index 1 so the array is never indexed at 0 / nil.
---@param beacon LuaEntityPrototype
---@param beacon_count integer
---@return number
function M.get_beacon_profile_multiplier(beacon, beacon_count)
    local profile = beacon.profile
    if type(profile) ~= "table" then
        return 1
    end
    local n = #profile
    if n == 0 then
        return 1
    end
    local index = beacon_count
    if index < 1 then
        index = 1
    elseif index > n then
        index = n
    end
    return profile[index]
end

---Module-inventory `defines.inventory` index per machine type, used to read the
---quality-scaled module slot count via get_inventory_size. A type absent here (or
---a nil define on an older engine) falls back to the static module_inventory_size.
local MODULE_INVENTORY_BY_TYPE = {
    ["assembling-machine"] = defines.inventory.assembling_machine_modules,
    ["furnace"] = defines.inventory.furnace_modules,
    ["rocket-silo"] = defines.inventory.rocket_silo_modules,
    ["lab"] = defines.inventory.lab_modules,
    ["mining-drill"] = defines.inventory.mining_drill_modules,
    ["beacon"] = defines.inventory.beacon_modules,
}

---Module slot count of a machine at the given quality. Factorio 2.0.77+ lets an
---entity grant extra module slots per quality tier (quality_affects_module_slots
---+ <class>_module_slots_bonus). Rather than read the 2.0.77-only gate flag --
---which throws on older builds -- this reads the engine's already-resolved count
---through get_inventory_size(<module inventory>, quality): the same flag-free,
---all-versions-safe pattern get_max_energy_usage(quality) uses for energy. Falls
---back to the static module_inventory_size when the type has no known module
---inventory or get_inventory_size yields nothing; that fallback is correct, since
---builds without the feature don't scale module slots at all. Vanilla opts in
---nowhere (no entity sets the gate), so this only adds slots for modded entities.
---@param machine LuaEntityPrototype
---@param quality QualityID
---@return integer
function M.get_machine_module_inventory_size(machine, quality)
    local base = machine.module_inventory_size or 0
    if base == 0 then return 0 end
    local index = MODULE_INVENTORY_BY_TYPE[machine.type]
    if not index then return base end
    local ok, size = pcall(function() return machine.get_inventory_size(index, quality) end)
    if ok and type(size) == "number" and size > 0 then return size end
    return base
end

---comment
---@param module_typed_names table<string, TypedName>
---@param module_inventory_size integer
---@return table<string, TypedName>
function M.trim_modules(module_typed_names, module_inventory_size)
    local ret = {}
    for index = 1, module_inventory_size do
        ret[tostring(index)] = module_typed_names[tostring(index)]
    end
    return ret
end

---Aggregate modules in slots into per-source counts. Beacon modules are
---kept in a separate per-beacon list so get_total_effectivity can mask each
---group against (recipe ∩ machine) or (recipe ∩ beacon)'s allowed_effects
---independently. The pre-allowed_effects layout collapsed both into a single
---table, which made it impossible to apply per-entity effect restrictions.
---@param machine LuaEntityPrototype
---@param machine_quality QualityID
---@param module_typed_names table<string, TypedName>
---@param affected_by_beacons AffectedByBeacon[]
---@param bonuses ResearchBonuses?
---@return TotalModules
function M.get_total_modules(machine, machine_quality, module_typed_names, affected_by_beacons, bonuses)
    ---@param dest table<string, table<string, number>>
    ---@param typed_name TypedName
    ---@param effectivity number
    local function count(dest, typed_name, effectivity)
        local name = typed_name.name
        local quality = typed_name.quality
        if not dest[name] then
            dest[name] = {}
        end
        local inner = dest[name]
        inner[quality] = (inner[quality] or 0) + effectivity
    end

    local machine_modules = {}
    module_typed_names = M.trim_modules(module_typed_names,
        M.get_machine_module_inventory_size(machine, machine_quality))
    for _, typed_name in pairs(module_typed_names) do
        count(machine_modules, typed_name, 1)
    end

    -- Research-derived beacon distribution scales beacon contribution
    -- multiplicatively on top of the beacon prototype's own
    -- distribution_effectivity. Module contribution from machine inventory is
    -- unaffected.
    local beacon_multiplier = 1 + ((bonuses and bonuses.beacon_distribution) or 0)

    ---@type { beacon: LuaEntityPrototype, modules: table<string, table<string, number>> }[]
    local beacon_groups = {}

    -- Machines that cannot receive beacon effects ignore any beacons attached
    -- to the line, so stale data on such a line never reaches the LP.
    if M.is_use_beacon(machine) then
        -- Diminishing returns: the profile multiplier is sampled by how many
        -- beacons reach this one machine, and beacon_counter selects the
        -- population ("total" = every beacon on the line, "same_type" = beacons
        -- sharing a prototype). Precompute both populations once so per-entry
        -- work stays O(1); same_type groups by prototype name because quality
        -- never changes which BeaconPrototype an entity is.
        local total_beacon_count = 0
        local same_type_count = {}
        for _, affected_by_beacon in ipairs(affected_by_beacons) do
            local quantity = affected_by_beacon.beacon_quantity
            total_beacon_count = total_beacon_count + quantity
            local beacon_typed_name = affected_by_beacon.beacon_typed_name
            if beacon_typed_name then
                local name = beacon_typed_name.name
                same_type_count[name] = (same_type_count[name] or 0) + quantity
            end
        end

        for _, affected_by_beacon in ipairs(affected_by_beacons) do
            local beacon_typed_name = affected_by_beacon.beacon_typed_name
            local beacon = beacon_typed_name and prototype_acc.get_beacon(beacon_typed_name.name)
            if beacon and beacon_typed_name then
                local effect_count = total_beacon_count
                if beacon.beacon_counter == "same_type" then
                    effect_count = same_type_count[beacon_typed_name.name]
                end
                local profile_multiplier = M.get_beacon_profile_multiplier(beacon, effect_count)

                local effectivity = M.get_beacon_distribution_effectivity(beacon, beacon_typed_name.quality)
                    * affected_by_beacon.beacon_quantity
                    * profile_multiplier
                    * beacon_multiplier
                local beacon_module_names = M.trim_modules(affected_by_beacon.module_typed_names,
                    M.get_machine_module_inventory_size(beacon, beacon_typed_name.quality))

                local modules = {}
                for _, typed_name in pairs(beacon_module_names) do
                    count(modules, typed_name, effectivity)
                end
                flib_table.insert(beacon_groups, { beacon = beacon, modules = modules })
            end
        end
    end

    return { machine_modules = machine_modules, beacon_groups = beacon_groups }
end

---Splits the modules in `total_modules` into effective vs ineffective
---contributions per (name, quality). Each source (machine slots, each
---beacon's slots) is evaluated against its own `recipe ∩ entity`
---allowed_effects / allowed_module_categories, so a quality module that is
---effective in machine slots but masked in a beacon shows up as two
---separate sub-counts rather than collapsing into a single misleading
---entry. Used by aggregated UI panels (effective modules, production line
---row) to render effective and ineffective contributions as separate slot
---buttons.
---@param recipe (LuaRecipePrototype | VirtualRecipe)?
---@param machine LuaEntityPrototype
---@param total_modules TotalModules
---@return table<string, table<string, { effective: number, ineffective: number }>>
function M.split_total_modules_by_effectiveness(recipe, machine, total_modules)
    local out = {}

    ---@param entity LuaEntityPrototype
    ---@param modules table<string, table<string, number>>
    local function add(entity, modules)
        local allowed_effects, allowed_categories
        if recipe then
            allowed_effects = recipe_acc.get_allowed_effects(recipe, entity)
            allowed_categories = recipe_acc.get_allowed_module_categories(recipe, entity)
        end
        for name, inner in pairs(modules) do
            local module = prototype_acc.get_module(name)
            -- Unknown module or missing recipe context falls through as
            -- "effective" so the UI doesn't surface a misleading warning
            -- about something we can't actually evaluate.
            local is_effective = true
            if module and recipe then
                is_effective = M.is_module_effective(module, allowed_effects, allowed_categories)
            end
            if not out[name] then out[name] = {} end
            for quality, count in pairs(inner) do
                if not out[name][quality] then
                    out[name][quality] = { effective = 0, ineffective = 0 }
                end
                if is_effective then
                    out[name][quality].effective = out[name][quality].effective + count
                else
                    out[name][quality].ineffective = out[name][quality].ineffective + count
                end
            end
        end
    end

    add(machine, total_modules.machine_modules)
    for _, group in ipairs(total_modules.beacon_groups) do
        add(group.beacon, group.modules)
    end
    return out
end

---Sum every contribution to a line's ModuleEffects: modules in the machine
---slots, modules in attached beacon slots, the machine's effect_receiver
---base_effect, and research bonuses. Modules are masked by recipe ∩ entity
---allowed_effects per source (machine modules against the machine's
---allowed_effects, each beacon's modules against that beacon's). base_effect
---and research bonuses are intentionally NOT masked — they bypass the module
---effect-type restriction in Factorio.
---@param recipe (LuaRecipePrototype | VirtualRecipe)?
---@param total_modules TotalModules
---@param effect_receiver EffectReceiver?
---@param recipe_typed_name TypedName?
---@param machine LuaEntityPrototype?
---@param bonuses ResearchBonuses?
---@param maximum_productivity number?
---@return ModuleEffects
function M.get_total_effectivity(recipe, total_modules, effect_receiver, recipe_typed_name, machine, bonuses, maximum_productivity)
    ---@type ModuleEffects
    local ret = {
        speed = 1,
        consumption = 1,
        productivity = 0,
        pollution = 1,
        quality = 0,
    }

    ---@param effect number?
    ---@param count number
    ---@param multiplier number
    ---@param is_negative boolean
    ---@return number
    local function modify(effect, count, multiplier, is_negative)
        effect = effect or 0
        if is_negative then
            if effect < 0 then
                effect = effect * multiplier
            end
        else
            if effect > 0 then
                effect = effect * multiplier
            end
        end
        return effect * count
    end

    ---@param modules table<string, table<string, number>>
    ---@param allowed table<string, boolean>
    ---@param allowed_categories table<string, true>?
    local function apply_group(modules, allowed, allowed_categories)
        for name, inner in pairs(modules) do
            for quality, count in pairs(inner) do
                local module = prototype_acc.get_module(name)
                if module
                    and (allowed_categories == nil or allowed_categories[module.category])
                then
                    local effects = assert(module.module_effects)
                    -- Quality scaling on module effects: default_multiplier is the
                    -- engine-side per-tier multiplier (vanilla: 1, 1.3, 1.6, 1.9, 2.5
                    -- for normal..legendary). Reading it through the QualityPrototype
                    -- replaces the previous hardcoded (1 + quality_level * 0.3) so
                    -- modded quality tiers are honored.
                    local multiplier = quality_acc.get_module_quality_multiplier(quality)
                    if allowed.speed then
                        ret.speed = ret.speed + modify(effects.speed, count, multiplier, false)
                    end
                    if allowed.consumption then
                        ret.consumption = ret.consumption + modify(effects.consumption, count, multiplier, true)
                    end
                    if allowed.productivity then
                        ret.productivity = ret.productivity + modify(effects.productivity, count, multiplier, false)
                    end
                    if allowed.pollution then
                        ret.pollution = ret.pollution + modify(effects.pollution, count, multiplier, true)
                    end
                    if allowed.quality then
                        ret.quality = ret.quality + modify(effects.quality, count, multiplier, false)
                    end
                end
            end
        end
    end

    if recipe and machine then
        apply_group(total_modules.machine_modules,
            recipe_acc.get_allowed_effects(recipe, machine),
            recipe_acc.get_allowed_module_categories(recipe, machine))
        for _, g in ipairs(total_modules.beacon_groups) do
            apply_group(g.modules,
                recipe_acc.get_allowed_effects(recipe, g.beacon),
                recipe_acc.get_allowed_module_categories(recipe, g.beacon))
        end
    end

    if effect_receiver then
        local base_effect = effect_receiver.base_effect
        ret.speed = ret.speed + (base_effect.speed or 0)
        ret.consumption = ret.consumption + (base_effect.consumption or 0)
        ret.productivity = ret.productivity + (base_effect.productivity or 0)
        ret.pollution = ret.pollution + (base_effect.pollution or 0)
        ret.quality = ret.quality + (base_effect.quality or 0)
    end

    -- Research-derived additive bonuses. Folded in before the min-clamps so
    -- that, like module/beacon effects, a non-zero research bonus can lift
    -- effectivity above its floor.
    if bonuses then
        if recipe_typed_name and recipe_typed_name.type == "recipe" then
            ret.productivity = ret.productivity
                + (bonuses.recipe_productivity[recipe_typed_name.name] or 0)
        end
        if machine then
            if machine.type == "mining-drill" then
                ret.productivity = ret.productivity + bonuses.mining_drill_productivity
            elseif machine.type == "lab" then
                ret.productivity = ret.productivity + bonuses.laboratory_productivity
                ret.speed = ret.speed + bonuses.laboratory_speed
            end
        end
    end

    ret.speed = math.max(ret.speed, 0.2)
    ret.consumption = math.max(ret.consumption, 0.2)
    ret.productivity = math.max(ret.productivity, 0)
    if maximum_productivity then
        ret.productivity = math.min(ret.productivity, maximum_productivity)
    end
    ret.pollution = math.max(ret.pollution, 0.2)
    ret.quality = math.max(ret.quality, 0)

    return ret
end

return M
