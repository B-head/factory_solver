-- Shared fixture builders for the headless solver case suite (tests/cases/*.lua).
--
-- Every LP case hand-builds NormalizedProductionLine / NormalizedAmount tables,
-- and the same `item` / `line` / `cascade` / `QUALITY` helpers were copied into a
-- dozen-plus case files verbatim. This module is that boilerplate factored once.
--
-- `item` and `line` each accept BOTH historical call shapes, discriminated by
-- arity, so existing call sites migrate by aliasing the helpers (no edits to the
-- carefully-tuned fixture literals, which carry the assertions):
--
--     local fixture = require "tests/cases/fixture"
--     local item, line = fixture.item, fixture.line
--
--   * quality-implicit:  item(name, amount)              line(recipe, products, ingredients)
--   * quality-explicit:  item(name, quality, amount)     line(recipe, quality, products, ingredients)
--
-- Not every case fits: files whose `line` carries extra fields (fuel, opts) keep
-- a bespoke local builder and only alias the parts that match.
--
-- This module is NOT registered in run.lua's case_files list, so it is never run
-- as a case itself -- run.lua only requires the files it enumerates.

local M = {}

M.QUALITY = { "normal", "uncommon", "rare", "epic", "legendary" }

---Build a NormalizedAmount. Two arities:
---  item(name, amount)            -> quality "normal"
---  item(name, quality, amount)   -> explicit quality
---@param name string
---@param a string|number quality (3-arg form) or amount (2-arg form)
---@param b number? amount (3-arg form only)
---@return NormalizedAmount
function M.item(name, a, b)
    if b == nil then
        return { type = "item", name = name, quality = "normal", amount_per_second = a }
    end
    return { type = "item", name = name, quality = a or "normal", amount_per_second = b }
end

---Build a NormalizedProductionLine (power/pollution zeroed). Two arities:
---  line(recipe, products, ingredients)            -> recipe quality "normal"
---  line(recipe, quality, products, ingredients)   -> explicit recipe quality
---@param recipe_name string
---@param a string|NormalizedAmount[] quality (4-arg form) or products (3-arg form)
---@param b NormalizedAmount[] products (4-arg form) or ingredients (3-arg form)
---@param c NormalizedAmount[]? ingredients (4-arg form only)
---@return NormalizedProductionLine
function M.line(recipe_name, a, b, c)
    local quality, products, ingredients
    if c == nil then
        quality, products, ingredients = "normal", a, b
    else
        quality, products, ingredients = a or "normal", b, c
    end
    return {
        recipe_typed_name = { type = "recipe", name = recipe_name, quality = quality },
        products = products,
        ingredients = ingredients,
        power_per_second = 0,
        pollution_per_second = 0,
    }
end

---Build a quality-decomposition cascade product list with the same shape
---pre_solve.quality_decomposition produces for a recipe with quality modules.
---`base_amount` is the recipe's native (un-decomposed) per-second amount.
---`start_quality` is the recipe-quality of the producer. `tiers` is how many
---cascade levels to emit (will not exceed the QUALITY chain length).
---`next_prob` is the per-step upgrade probability (Factorio default is 0.1).
---@param name string
---@param base_amount number
---@param start_quality string
---@param tiers integer
---@param next_prob number?
---@return NormalizedAmount[]
function M.cascade(name, base_amount, start_quality, tiers, next_prob)
    next_prob = next_prob or 0.1
    local start_idx
    for i, q in ipairs(M.QUALITY) do
        if q == start_quality then start_idx = i; break end
    end
    assert(start_idx, "unknown start_quality: " .. tostring(start_quality))

    local ret = {}
    local prob_left = 1
    for offset = 0, tiers - 1 do
        local idx = start_idx + offset
        if idx > #M.QUALITY then break end
        local p
        if offset < tiers - 1 and idx < #M.QUALITY then
            p = prob_left * (1 - next_prob)
            prob_left = prob_left * next_prob
        else
            p = prob_left
            prob_left = 0
        end
        table.insert(ret, M.item(name, M.QUALITY[idx], base_amount * p))
        if prob_left == 0 then break end
    end
    return ret
end

return M
