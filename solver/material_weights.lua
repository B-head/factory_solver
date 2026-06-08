-- Per-material "embodied cost" weights derived from the conversion ratios of a
-- single chain (a NormalizedProductionLine[] set), for normalizing the flat
-- per-unit cost the LP puts on its four escape variables (|shortage_source|,
-- |surplus_sink|, |initial_source|, |final_sink|).
--
-- The problem this solves
-- -----------------------
-- Each escape variable is priced per unit of its material. That is "fair" only
-- when every recipe converts 1:1 -- then one unit anywhere embodies the same
-- amount of upstream work, so a flat cost is uniform. Real recipes convert at
-- wildly different ratios (a deep vanilla chain reaches 1:100+), so the *real*
-- effort embodied in one unit of a material drifts far from 1, and the flat
-- escape cost silently over/under-charges per material. This module estimates a
-- per-material weight w(M) that tracks that embodied effort, so a later caller
-- can multiply the flat escape cost by w(M) and recover a normalized per-unit
-- cost.
--
-- The model: embodied cost is conserved
-- -------------------------------------
-- Treat each recipe as conserving a scalar "value": the total value of its
-- products equals the total value of its ingredients (the recipe itself adds
-- nothing). Root materials -- ones the chain does not produce (mined / pumped /
-- externally supplied) and the outputs of |is_source| virtual recipes -- inject
-- value at `base`. Every other material's weight follows from propagating the
-- conservation equation along the chain:
--
--     C_in(r) = Σ_ingredients amount_i · w(i)            (fuel included)
--     w(product) = C_in(r) / Σ_products amount_p          (burnt result included)
--
-- With `amount` allocation every product of a recipe carries the same per-unit
-- value C_in/Σamount, which conserves the recipe's total value exactly
-- (Σ amount_p · C_in/Σamount = C_in). 1:1 everywhere ⇒ w ≡ base. A recipe that
-- turns 1 unit into 10 makes each output worth base/10; one that burns 10 into 1
-- makes the output worth 10·base. Ratios compound multiplicatively down the
-- chain, which is exactly the 1:100 spread we want to capture.
--
-- This is intentionally a heuristic. A single scalar "value" is a modelling
-- fiction (real recipes conserve no such quantity), so the propagated weights
-- are an estimate, not a ground truth -- good enough to *normalize* a flat cost,
-- not a replacement for the LP. The three modelling choices (joint-product
-- allocation, multi-recipe combination, cycle handling) are all options on
-- M.compute so a caller can probe alternatives.
--
-- Determinism: every iteration walks materials/recipes in sorted key order, the
-- combiners are min / arithmetic mean, and there is no RNG or wall-clock input,
-- so the result is bit-identical across Factorio's lockstep clients and across
-- PUC-Lua / LuaJIT (the headless suite runs both). See CLAUDE.md.

local tn = require "manage/typed_name"
local material_cycles = require "solver/material_cycles"

local M = {}

local DEFAULTS = {
    -- Weight assigned to root materials (chain inputs / |is_source| outputs).
    base = 1,
    -- How to combine the candidate weights from several recipes that all
    -- produce the same material. "min" approximates the cheapest fabrication
    -- path (what the LP would pick); "mean" averages them.
    combiner = "min",
    -- Joint-product cost allocation. "amount" spreads a recipe's input value
    -- across its products by output amount (value-conserving, every product
    -- gets the same per-unit value). "main" charges the whole input value to
    -- the largest-amount product and leaves byproducts free (weight 0 from
    -- that recipe).
    allocation = "amount",
    -- Early-exit threshold on the max relative weight change in a cycle
    -- relaxation sweep.
    tolerance = 1e-9,
    -- Hard cap / floor clamped onto every finished weight, relative to base,
    -- so a pathological productive cycle can never blow a weight to inf/0.
    ceil_ratio = 1e12,
    floor_ratio = 1e-12,
}

---One material reference (ingredient or product) reduced to (variable, amount).
---@class MwTerm
---@field var string
---@field amount number

---Collect a line's ingredient terms (ingredients + fuel) as (var, amount).
---@param line NormalizedProductionLine
---@return MwTerm[]
local function input_terms(line)
    local terms = {}
    for _, ing in ipairs(line.ingredients) do
        terms[#terms + 1] = { var = tn.typed_name_to_variable_name(ing), amount = ing.amount_per_second }
    end
    if line.fuel_ingredient then
        terms[#terms + 1] = {
            var = tn.typed_name_to_variable_name(line.fuel_ingredient),
            amount = line.fuel_ingredient.amount_per_second,
        }
    end
    return terms
end

---Collect a line's product terms (products + burnt result) as (var, amount).
---@param line NormalizedProductionLine
---@return MwTerm[]
local function output_terms(line)
    local terms = {}
    for _, prod in ipairs(line.products) do
        terms[#terms + 1] = { var = tn.typed_name_to_variable_name(prod), amount = prod.amount_per_second }
    end
    if line.fuel_burnt_result then
        terms[#terms + 1] = {
            var = tn.typed_name_to_variable_name(line.fuel_burnt_result),
            amount = line.fuel_burnt_result.amount_per_second,
        }
    end
    return terms
end

---A producing recipe reduced to what the weight propagation needs: its input
---terms, its total output amount, and the amount of the specific product whose
---weight we are computing (for "main" allocation).
---@class MwProducer
---@field inputs MwTerm[]
---@field out_total number   Σ of all product amounts (for "amount" allocation)
---@field main_var string    the largest-amount product (for "main" allocation)
---@field main_amount number  the largest product's amount (for "main" allocation)

---Per-material candidate weight from one producing recipe.
---@param prod MwProducer
---@param mvar string         the material being priced
---@param weight table<string, number>
---@param allocation string
---@return number?            candidate weight, or nil if this recipe gives none
local function candidate_from(prod, mvar, weight, allocation)
    local c_in = 0
    for _, t in ipairs(prod.inputs) do
        local wi = weight[t.var]
        if wi == nil then return nil end          -- input not yet priced
        c_in = c_in + t.amount * wi
    end
    if allocation == "main" then
        if mvar ~= prod.main_var then
            return 0                               -- byproduct: free from this recipe
        end
        if prod.main_amount <= 0 then return nil end
        -- main_amount is out_total minus nothing here: main allocation charges
        -- the whole input value to the main product's own amount.
        return c_in / prod.main_amount
    end
    -- "amount" allocation: input value spread over total output quantity.
    if prod.out_total <= 0 then return nil end
    return c_in / prod.out_total
end

---Combine candidate weights from several producing recipes.
---@param cands number[]
---@param combiner string
---@return number?
local function combine(cands, combiner)
    if #cands == 0 then return nil end
    if combiner == "mean" then
        local s = 0
        for _, c in ipairs(cands) do s = s + c end
        return s / #cands
    end
    -- "min"
    local m = cands[1]
    for i = 2, #cands do
        if cands[i] < m then m = cands[i] end
    end
    return m
end

---Recompute one material's weight from its producing recipes under the current
---weight estimate. Returns nil when no producer yields a finite candidate yet.
---@param producers MwProducer[]
---@param mvar string
---@param weight table<string, number>
---@param opts table
---@return number?
local function recompute(producers, mvar, weight, opts)
    local cands = {}
    for _, prod in ipairs(producers) do
        local c = candidate_from(prod, mvar, weight, opts.allocation)
        if c ~= nil then cands[#cands + 1] = c end
    end
    return combine(cands, opts.combiner)
end

---@class MaterialWeights
---@field weight table<string, number>    material variable name -> embodied weight
---@field is_root table<string, true>     materials seeded at `base`
---@field unresolved table<string, true>  materials a cycle never priced from roots (got fallback)

---Compute embodied-cost weights for every material in the chain.
---@param production_lines NormalizedProductionLine[]
---@param opts table?  overrides for DEFAULTS (base / combiner / allocation / tolerance / clamps)
---@return MaterialWeights
function M.compute(production_lines, opts)
    opts = opts or {}
    for k, v in pairs(DEFAULTS) do
        if opts[k] == nil then opts[k] = v end
    end
    local base = opts.base

    -- 1. Index producers per material and the universe of materials. is_sink
    --    lines produce nothing we propagate; is_source line outputs are roots
    --    (their inputs, if any, do not define their value).
    local producers = {}      ---@type table<string, MwProducer[]>
    local all_materials = {}  ---@type table<string, true>
    local produced = {}       ---@type table<string, true>  produced by a non-source line
    local source_outputs = {} ---@type table<string, true>

    for _, line in ipairs(production_lines) do
        local ins = input_terms(line)
        local outs = output_terms(line)
        for _, t in ipairs(ins) do all_materials[t.var] = true end
        for _, t in ipairs(outs) do all_materials[t.var] = true end

        if line.is_sink then
            -- consumes only; nothing to propagate
        elseif line.is_source or #ins == 0 then
            -- |is_source| virtual recipes and zero-ingredient bootstrap recipes
            -- (mining / pumping analogues -- see the bootstrap rule in
            -- tests/run.lua) inject material from nothing, so their outputs are
            -- roots priced at `base`, not the C_in/Σamount = 0 a real recipe
            -- would give them.
            for _, t in ipairs(outs) do source_outputs[t.var] = true end
        else
            local out_total = 0
            local main_var, main_amount = nil, -math.huge
            for _, t in ipairs(outs) do
                out_total = out_total + t.amount
                if t.amount > main_amount then
                    main_amount, main_var = t.amount, t.var
                end
            end
            local prod = { inputs = ins, out_total = out_total, main_var = main_var, main_amount = main_amount }
            for _, t in ipairs(outs) do
                produced[t.var] = true
                local list = producers[t.var]
                if not list then list = {}; producers[t.var] = list end
                list[#list + 1] = prod
            end
        end
    end

    -- 2. Roots: outputs of |is_source| lines, plus any material the chain never
    --    produces (mined / pumped / externally supplied raw inputs).
    local weight = {}      ---@type table<string, number>
    local is_root = {}     ---@type table<string, true>
    for mvar in pairs(all_materials) do
        if source_outputs[mvar] or not produced[mvar] then
            weight[mvar] = base
            is_root[mvar] = true
        end
    end

    -- 3. Process SCCs of the material graph in topological order (roots first).
    --    find_sccs returns reverse-topological order, so iterate it backwards.
    local adj = material_cycles.build_material_graph(production_lines)
    local sccs = material_cycles.find_sccs(adj)

    local unresolved = {}  ---@type table<string, true>

    for si = #sccs, 1, -1 do
        local scc = sccs[si]
        local cyclic = material_cycles.is_cyclic_scc(scc, adj)

        if not cyclic then
            -- Acyclic singleton: all non-root inputs already priced upstream.
            local mvar = scc[1]
            if not is_root[mvar] then
                local w = recompute(producers[mvar] or {}, mvar, weight, opts)
                if w == nil then
                    unresolved[mvar] = true
                else
                    weight[mvar] = w
                end
            end
        else
            -- Cyclic component: bounded min-relaxation (Bellman-Ford style).
            -- Members start unpriced; external inputs are already final, so the
            -- first sweeps inject root cost at the cycle's entry recipes and
            -- later sweeps carry it around the loop. Monotone under "min", so it
            -- settles; the iteration cap bounds productive cycles that would
            -- otherwise keep lowering a weight toward its fixed point.
            local members = {}
            for _, mvar in ipairs(scc) do
                if not is_root[mvar] then members[#members + 1] = mvar end
            end
            table.sort(members)
            local max_iter = math.max(20, #members * 4)
            for _ = 1, max_iter do
                local max_delta = 0
                for _, mvar in ipairs(members) do
                    local w = recompute(producers[mvar] or {}, mvar, weight, opts)
                    if w ~= nil then
                        local prev = weight[mvar]
                        weight[mvar] = w
                        if prev ~= nil then
                            local denom = math.abs(prev) + math.abs(w) + 1e-300
                            local d = math.abs(w - prev) / denom
                            if d > max_delta then max_delta = d end
                        else
                            max_delta = math.huge
                        end
                    end
                end
                if max_delta <= opts.tolerance then break end
            end
            for _, mvar in ipairs(members) do
                if weight[mvar] == nil then unresolved[mvar] = true end
            end
        end
    end

    -- 4. Fallback for materials no production path ever priced (closed catalyst
    --    cycles with no external feed in this chain). Give them the max finite
    --    weight seen, so they are treated as "expensive" rather than free.
    local max_finite = base
    for _, w in pairs(weight) do
        if w > max_finite then max_finite = w end
    end
    for mvar in pairs(unresolved) do
        weight[mvar] = max_finite
    end

    -- 5. Clamp every weight into a sane band relative to base.
    local ceil = base * opts.ceil_ratio
    local floor = base * opts.floor_ratio
    for mvar, w in pairs(weight) do
        if w > ceil then
            weight[mvar] = ceil
        elseif w < floor then
            weight[mvar] = floor
        end
    end

    return { weight = weight, is_root = is_root, unresolved = unresolved }
end

return M
