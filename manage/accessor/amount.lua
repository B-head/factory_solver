-- Per-craft -> per-second amount normalization, plus fluid-temperature
-- widening for the range-only normalized layer. These helpers turn a recipe's
-- raw Product / Ingredient (and lab pack-drain productivity) into the
-- NormalizedAmount shape the LP and UI consume. Part of the
-- manage/accessor.lua family; reached through the accessor facade.

local M = {}

---comment
---@param product ProductEx
---@param quality string
---@param craft_energy number
---@param crafting_speed number
---@param effectivity_productivity number
---@return NormalizedAmount
function M.raw_product_to_amount(product, quality, craft_energy, crafting_speed, effectivity_productivity)
    local amount_min = assert(product.amount_min or product.amount)
    local amount_max = assert(product.amount_max or product.amount)

    local ignored_by_productivity = (product.ignored_by_productivity or 0)
    local target_by_productivity =
        math.max(amount_min - ignored_by_productivity, 0) +
        math.max(amount_max - ignored_by_productivity, 0)

    local normal_amount = (amount_min + amount_max + target_by_productivity * effectivity_productivity) / 2
    local extra_amount = (product.extra_count_fraction or 0) * (1 + effectivity_productivity)
    local amount = (normal_amount * product.probability + extra_amount) * crafting_speed / craft_energy

    -- The raw layer (Product) carries a single `temperature`; the normalized /
    -- LP layer is range-only, so a point temperature becomes the degenerate
    -- range [T,T]. A bare product (temperature nil) is left unset for
    -- resolve_bare_fluid_product to widen to [default, default].
    ---@type NormalizedAmount
    return {
        type = product.type,
        name = product.name,
        quality = quality,
        amount_per_second = amount,
        minimum_temperature = product.temperature,
        maximum_temperature = product.temperature,
    }
end

---Scale a normalized lab ingredient amount in place by every input-side
---productivity-like factor that does NOT come from modules:
---  * science_pack_drain_rate_percent (lab/biolab intrinsic): fewer packs
---    drained per research unit.
---  * pack quality durability (LuaItemPrototype:get_durability(quality)): a
---    quality-N pack carries durability-N research units worth of drain, so
---    one pack item is consumed once every `durability` research units.
---Both reduce per-second pack consumption, stack multiplicatively with each
---other and with module productivity (which raw_product_to_amount already
---applied on products). Module productivity is intentionally NOT applied
---here — that's a separate axis on the output side.
---Every caller that turns a recipe ingredient into a per-second amount for
---a lab-driven recipe must call this so the LP, the per-line UI, and the
---totals display agree.
---@param amount NormalizedAmount
---@param machine LuaEntityPrototype
function M.apply_lab_input_productivity_to_ingredient(amount, machine)
    if machine.type ~= "lab" then
        return
    end
    amount.amount_per_second = amount.amount_per_second
        * (machine.science_pack_drain_rate_percent / 100)
    local item_proto = prototypes.item[amount.name]
    if not item_proto then
        return
    end
    -- prototypes.quality returns nil for any string the engine doesn't know
    -- (e.g. legacy sentinels on migrated saves); skip the durability scaling
    -- in that case so get_durability — which would otherwise raise on an
    -- invalid QualityID — never sees it.
    local quality_proto = prototypes.quality[amount.quality]
    if not quality_proto then
        return
    end
    -- LuaItemPrototype.get_durability is bound to the item proto at index
    -- time — its in-game signature is `(QualityID) -> double?`, NOT a Lua
    -- method. Calling with colon (`item_proto:get_durability(q)`) would
    -- pass item_proto in the QualityID slot and trip Factorio's "Invalid
    -- QualityID" runtime check. pcall keeps non-tool items (no durability)
    -- from crashing the solve.
    local ok, durability = pcall(item_proto.get_durability, quality_proto)
    if ok and durability and durability > 0 then
        amount.amount_per_second = amount.amount_per_second / durability
    end
end

---comment
---@param ingredient IngredientEx
---@param quality string
---@param craft_energy number
---@param crafting_speed number
---@return NormalizedAmount
function M.raw_ingredient_to_amount(ingredient, quality, craft_energy, crafting_speed)
    local amount = ingredient.amount * crafting_speed / craft_energy

    local min_temp = ingredient.minimum_temperature
    local max_temp = ingredient.maximum_temperature
    -- A fluid ingredient pinned to an exact temperature is the degenerate range
    -- [T,T] in the range-only model. (Most fluid ingredients expose min/max; this
    -- handles the rarer exact-`temperature` shape without leaking a single field
    -- into the normalized layer.)
    if ingredient.type == "fluid" and ingredient.temperature ~= nil then
        min_temp = ingredient.temperature
        max_temp = ingredient.temperature
    end
    if ingredient.type == "fluid" then
        -- Factorio's runtime API returns the FLT-sentinel values
        -- (e.g. -3.4e38) for ingredient temperature bounds that the
        -- prototype left unset. Clamp to the fluid's physical range so
        -- the value flows through the rest of the mod (LP variable
        -- names, picker labels, tooltips) without leaking the sentinel.
        -- A nil bound is distinct from a sentinel: it marks a bare
        -- ingredient that pre_solve.resolve_bare_fluids will widen to
        -- [default, max] for LP purposes, while UI consumers want to
        -- treat it as "no temperature constraint" and skip the range
        -- label entirely. Only touch non-nil values here.
        local proto = prototypes.fluid[ingredient.name]
        if proto then
            if min_temp ~= nil and min_temp < proto.default_temperature then
                min_temp = proto.default_temperature
            end
            if max_temp ~= nil and max_temp > proto.max_temperature then
                max_temp = proto.max_temperature
            end
        end
    end

    ---@type NormalizedAmount
    return {
        type = ingredient.type,
        name = ingredient.name,
        quality = quality,
        amount_per_second = amount,
        minimum_temperature = min_temp,
        maximum_temperature = max_temp,
    }
end

---Widen a fluid amount in product position: a fully bare fluid resolves to the
---degenerate range [default_temperature, default_temperature] (a product comes
---out at exactly one temperature). Anything already tagged passes through.
---Returns (minimum_temperature, maximum_temperature) — the range-only model has
---no single-value field.
---@param fluid_name string
---@param minimum_temperature number?
---@param maximum_temperature number?
---@return number? minimum_temperature
---@return number? maximum_temperature
function M.resolve_bare_fluid_product(fluid_name, minimum_temperature, maximum_temperature)
    if minimum_temperature == nil and maximum_temperature == nil then
        local proto = prototypes.fluid[fluid_name]
        if proto then
            return proto.default_temperature, proto.default_temperature
        end
    end
    return minimum_temperature, maximum_temperature
end

---Widen a fluid amount in ingredient position: a bare ingredient's bounds are
---filled to [default_temperature, max_temperature] and clamped to the fluid's
---physical range. The clamp also tames the FLT-sentinel values Factorio returns
---for unset bounds (e.g. -3.4e38 for an unset minimum_temperature).
---Returns (minimum_temperature, maximum_temperature).
---@param fluid_name string
---@param minimum_temperature number?
---@param maximum_temperature number?
---@return number? minimum_temperature
---@return number? maximum_temperature
function M.resolve_bare_fluid_ingredient(fluid_name, minimum_temperature, maximum_temperature)
    local proto = prototypes.fluid[fluid_name]
    if not proto then
        return minimum_temperature, maximum_temperature
    end
    local min = minimum_temperature or proto.default_temperature
    local max = maximum_temperature or proto.max_temperature
    if min < proto.default_temperature then min = proto.default_temperature end
    if max > proto.max_temperature then max = proto.max_temperature end
    return min, max
end

return M
