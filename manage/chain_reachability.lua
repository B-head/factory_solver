-- Temperature-aware material reachability for the chain explorer.
--
-- The explorer used to key materials by "type/name", collapsing every
-- temperature variant of a fluid into one node. solver/create_problem reaches
-- materials temperature-specifically: a fluid PRODUCT carries a point
-- temperature, a fluid INGREDIENT an acceptance range [lo,hi], and the two are
-- connected only by a temperature bridge when the produced point falls inside
-- the range. That divergence makes the explorer's own reachability disagree with
-- the solver it drives -- most sharply on a cycle broken by a temperature gap,
-- which the name-keyed model reports as a closed (trapped) loop while the solver
-- breaks it by importing the out-of-range fluid as a raw input.
--
-- This module is the pure core of the aligned model: no Factorio runtime
-- dependency, so it is exercised by tests/cases/chain_reachability.lua. The
-- caller (manage/chain_explorer.lua) normalizes prototype recipes into the shape
-- below -- resolving the FLT temperature sentinels and default/max temperatures
-- against the fluid prototypes -- and queries the result.
--
-- Normalized recipe shape (a plain table per recipe):
--   { ings = { <ing>, ... }, prods = { <prod>, ... } }
--   <ing>  item : { item = "<name>" }    fluid: { fluid = "<name>", lo = N, hi = N }
--   <prod> item : { item = "<name>" }    fluid: { fluid = "<name>", t  = N }
--
-- The model mirrors create_problem.compute_reachable_materials + the temperature
-- bridges:
--   * an item ingredient is satisfied when the item has no producer (a raw seed)
--     or some producer chain has reached it;
--   * a fluid ingredient [lo,hi] is satisfied when NO recipe produces that fluid
--     at a point inside [lo,hi] (a raw seed -- the LP |initial_source|s it, which
--     is exactly how a temperature gap breaks a cycle), or some reachable
--     producer makes it at a point inside [lo,hi] (the bridge fired).

local M = {}

---@class ChainReachIng
---@field item string?
---@field fluid string?
---@field lo number?
---@field hi number?

---@class ChainReachProd
---@field item string?
---@field fluid string?
---@field t number?

---@class ChainReachRecipe
---@field ings ChainReachIng[]
---@field prods ChainReachProd[]

---@class ChainReach
---@field reach_items table<string, true> Items reached through a producer chain.
---@field reach_points table<string, table<number, true>> Reached produced fluid points: name -> { temp -> true }.
---@field item_producer table<string, true> Items some recipe produces.
---@field producer_points table<string, table<number, true>> Every produced fluid point (reachable or not): name -> { temp -> true }.
---@field ing_ok fun(ing: ChainReachIng): boolean Whether an ingredient is satisfied under this reachability.

---Compute temperature-aware reachability over a normalized recipe list.
---@param recipes ChainReachRecipe[]
---@return ChainReach
function M.reachable(recipes)
    local item_producer = {} ---@type table<string, true>
    local producer_points = {} ---@type table<string, table<number, true>>
    for _, r in ipairs(recipes) do
        for _, p in ipairs(r.prods) do
            if p.item then
                item_producer[p.item] = true
            elseif p.fluid then
                local s = producer_points[p.fluid]
                if not s then s = {}; producer_points[p.fluid] = s end
                s[p.t] = true
            end
        end
    end

    local reach_items = {} ---@type table<string, true>
    local reach_points = {} ---@type table<string, table<number, true>>

    -- A fluid ingredient is a RAW SEED when no recipe produces the fluid at a
    -- point inside its acceptance range: there is no bridge to make it, so the LP
    -- imports it (this is the cycle-breaking import a temperature gap forces).
    local function is_raw_fluid(name, lo, hi)
        local pts = producer_points[name]
        if not pts then return true end
        for t in pairs(pts) do
            if t >= lo and t <= hi then return false end
        end
        return true
    end

    local function ing_ok(ing)
        if ing.item then
            return (not item_producer[ing.item]) or (reach_items[ing.item] == true)
        elseif ing.fluid then
            if is_raw_fluid(ing.fluid, ing.lo, ing.hi) then return true end
            local rp = reach_points[ing.fluid]
            if rp then
                for t in pairs(rp) do
                    if t >= ing.lo and t <= ing.hi then return true end
                end
            end
            return false
        end
        -- Malformed ingredient: treat as satisfied so it never blocks a recipe.
        return true
    end

    local changed = true
    while changed do
        changed = false
        for _, r in ipairs(recipes) do
            local all = true
            for _, ing in ipairs(r.ings) do
                if not ing_ok(ing) then all = false; break end
            end
            if all then
                for _, p in ipairs(r.prods) do
                    if p.item then
                        if item_producer[p.item] and not reach_items[p.item] then
                            reach_items[p.item] = true
                            changed = true
                        end
                    elseif p.fluid then
                        local s = reach_points[p.fluid]
                        if not s then s = {}; reach_points[p.fluid] = s end
                        if not s[p.t] then s[p.t] = true; changed = true end
                    end
                end
            end
        end
    end

    return {
        reach_items = reach_items,
        reach_points = reach_points,
        item_producer = item_producer,
        producer_points = producer_points,
        ing_ok = ing_ok,
    }
end

---True when an ITEM is produced by some recipe yet never reached -- a trapped
---item (the degenerate-shortage target). Raw items (no producer) are not trapped.
---@param reach ChainReach
---@param name string
---@return boolean
function M.item_trapped(reach, name)
    return reach.item_producer[name] == true and not reach.reach_items[name]
end

return M
