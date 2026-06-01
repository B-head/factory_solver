-- Recipe-level scalars read off a LuaRecipePrototype | VirtualRecipe: craft
-- energy, speed / productivity caps, the recipe∩entity effect & module-category
-- masks, and the per-second base rate a virtual recipe runs at. Part of the
-- manage/accessor.lua family; reached through the accessor facade.

local fs_util = require "fs_util"
local quality_acc = require "manage/accessor/quality"

local M = {}

---@param recipe LuaRecipePrototype | VirtualRecipe
---@return number
function M.get_crafting_energy(recipe)
    ---@diagnostic disable-next-line: param-type-mismatch
    if recipe.object_name == "LuaRecipePrototype" then
        return assert(recipe.energy)
    else
        return 1
    end
end

---@param recipe LuaRecipePrototype | VirtualRecipe
---@return number
function M.get_crafting_speed_cap(recipe)
    ---@diagnostic disable-next-line: param-type-mismatch
    if recipe.object_name == "LuaRecipePrototype" then
        return math.huge
    else
        return recipe.crafting_speed_cap or math.huge
    end
end

---Productivity bonus ceiling for the given recipe. Mirrors get_crafting_speed_cap:
---LuaRecipePrototype carries a vanilla-default 3.0 with smaller values on a few
---Space Age recipes; VirtualRecipe leaves the field unset and the cap collapses
---to math.huge until a future virtual recipe needs one. Consumed by
---get_total_effectivity to clamp the final productivity sum.
---@param recipe LuaRecipePrototype | VirtualRecipe
---@return number
function M.get_maximum_productivity(recipe)
    ---@diagnostic disable-next-line: param-type-mismatch
    if recipe.object_name == "LuaRecipePrototype" then
        -- maximum_productivity landed in Factorio 2.0.77; the LuaCATS bundle
        -- shipped with the build hasn't picked it up yet, so the read is real
        -- but flagged as undefined here.
        ---@diagnostic disable-next-line: undefined-field
        return recipe.maximum_productivity
    else
        return recipe.maximum_productivity or math.huge
    end
end

---Per-effect-kind allow mask for the (recipe, entity) pair. Returns a dict
---over { speed, productivity, consumption, pollution, quality } with `true`
---for kinds that both sides accept. Either side leaving allowed_effects nil
---is treated as "no restriction" (Factorio semantics). VirtualRecipe never
---declares allowed_effects, so the union read falls through nil-safely.
---@param recipe LuaRecipePrototype | VirtualRecipe
---@param entity LuaEntityPrototype
---@return table<string, boolean>
function M.get_allowed_effects(recipe, entity)
    local ret = { speed = true, productivity = true, consumption = true,
                  pollution = true, quality = true }
    local function intersect(src)
        if src == nil then return end
        for k in pairs(ret) do
            if src[k] == false then ret[k] = false end
        end
    end
    ---@diagnostic disable-next-line: undefined-field
    intersect(recipe.allowed_effects)
    intersect(entity.allowed_effects)
    return ret
end

---Intersection of recipe and entity allowed_module_categories. nil result
---means "no restriction" on either side. The field is a set
---(`dict[string → true]?`) — key absence means the category is NOT allowed,
---which is the opposite convention to allowed_effects's `false` opt-out.
---Consumed by get_total_effectivity to skip modules whose
---LuaItemPrototype.category falls outside this intersection.
---@param recipe LuaRecipePrototype | VirtualRecipe
---@param entity LuaEntityPrototype
---@return table<string, true>?
function M.get_allowed_module_categories(recipe, entity)
    ---@diagnostic disable-next-line: undefined-field
    local r = recipe.allowed_module_categories
    local e = entity.allowed_module_categories
    if r == nil and e == nil then return nil end
    if r == nil then return e end
    if e == nil then return r end
    local ret = {}
    for k in pairs(r) do
        if e[k] then ret[k] = true end
    end
    return ret
end

---Return the per-second throughput rate of `machine` that drives a virtual
---recipe. pre_solve multiplies each ingredient/product's per-craft ratio
---(amount) by this base rate. The machine.type dispatch was pinned down
---from a 2026-05-24 in-game dump:
---  boiler / reactor              -> get_max_energy_usage(q) (heat amount proxy)
---  generator / fusion-*          -> get_fluid_usage_per_tick(q)
---                                   (fusion-reactor's energy_usage is
---                                   quality-invariant; only the fluid
---                                   side scales)
---  thruster                      -> max_performance.fluid_usage × default_multiplier(q)
---                                   (no runtime quality API; multiplier
---                                   applied manually. Verified in-game
---                                   that the engine itself also reads
---                                   QualityPrototype::default_multiplier:
---                                   overwriting default_multiplier shifts
---                                   thruster consumption accordingly)
---  mining-drill                  -> mining_speed (quality-independent)
---                                   (vanilla mining-drill's mining speed
---                                   itself does not scale with quality;
---                                   quality acts on productivity / module
---                                   slots / radius instead. Verified
---                                   in-game on 2026-05-24)
---  offshore-pump                 -> get_pumping_speed(q)
---  lab                           -> get_researching_speed(q) / research_unit_energy
---                                   (research_unit_energy = seconds per
---                                   research unit, snapshotted from
---                                   force.current_research by the Research
---                                   bonuses dialog; defaults to 30s for the
---                                   vanilla automation-science-pack. A
---                                   vanilla lab + automation-science-pack
---                                   therefore settles at 1/30 pack/sec/lab
---                                   rather than the unscaled 1 pack/sec/lab)
---  plant / agricultural-tower    -> 1.0 (growth_ticks lives on the plant
---                                   prototype; tower quality has no effect)
---  default                       -> get_crafting_speed(q) (covers every
---                                   CraftingMachine type)
---All return values are normalised to "per second" (per-tick APIs are
---multiplied by second_per_tick internally). effectivity must be applied
---by the caller (this function is a pure helper depending only on machine
---+ quality + research-derived scalars).
---When the API returns nil (modded entity / placeholder), falls back to 0.
---@param machine LuaEntityPrototype
---@param quality QualityID
---@param bonuses ResearchBonuses?
---@return number
function M.get_virtual_recipe_rates(machine, quality, bonuses)
    local t = machine.type
    if t == "boiler" or t == "reactor" then
        return (machine.get_max_energy_usage(quality) or 0) * fs_util.second_per_tick
    elseif t == "generator" or t == "fusion-reactor" or t == "fusion-generator" then
        return (machine.get_fluid_usage_per_tick(quality) or 0) * fs_util.second_per_tick
    elseif t == "thruster" then
        local perf = machine.max_performance
        if not perf then return 0 end
        return perf.fluid_usage * quality_acc.get_quality_default_multiplier(quality) * fs_util.second_per_tick
    elseif t == "mining-drill" then
        return machine.mining_speed or 0
    elseif t == "offshore-pump" then
        return (machine.get_pumping_speed(quality) or 0) * fs_util.second_per_tick
    elseif t == "lab" then
        local rate = machine.get_researching_speed(quality) or 0
        -- 1 craft of a <research>{pack} virtual recipe represents 1 unit of
        -- research progress. researching_speed scales the unit rate; the
        -- pack-consumption side (drain_rate, pack durability) is layered on
        -- the input ingredient by apply_lab_input_productivity_to_ingredient,
        -- so output (research progress) and input (pack count) stay linked
        -- by the 1:1 invariant baked into the virtual recipe but scale on
        -- independent axes. Dividing by research_unit_energy here makes the
        -- final rate "packs per second per lab" rather than "research units
        -- per second per lab".
        local rue = bonuses and bonuses.research_unit_energy
        if rue and rue > 0 then
            rate = rate / rue
        end
        return rate
    elseif t == "plant" or t == "agricultural-tower" then
        return 1.0
    else
        return machine.get_crafting_speed(quality) or 1
    end
end

return M
