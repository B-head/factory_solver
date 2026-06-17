-- observe-price: per-material repricing of the import-vs-fabricate escape, for
-- every shortage the baseline would rather penalty-import than run the chain for.
--
-- The soft gate (create_problem's reachability_soft_gate_k) prices REACHABLE
-- materials' shortages high so the chain runs. Whatever still imports at the
-- baseline -- a placed loop the LP declines to run, a chain it would rather buy --
-- carries an active |shortage_source|, and the right cost for it is not a fixed
-- gate value but a per-material one only the solve can reveal, so this module
-- measures it:
--
--   1. BASELINE solve -> collect EVERY active-shortage material as a reprice
--      target (SCC membership does NOT gate this -- see M.collect_plan); group
--      them so the observe step can measure a coupled escape-cost delta:
--      materials sharing one cyclic SCC observe together, every other material on
--      its own.
--   2. OBSERVE (one solve per group at the ceiling) -> read the escape-cost delta
--      dCost the forced fabrication drags in (objective cost of the collateral
--      surplus/shortage/initial_source, in elastic_cost units -- see M.escape_cost
--      for why cost, not mass), and price each key at
--      clamp(K_PRED * dCost/qty, 2, ceiling). A group whose shortage does not
--      clear without relaxing the target is cone-over-promise: FREEZE it (import
--      is correct) rather than chase it.
--   3. VERIFY + CORRECT -> re-solve at the predicted prices; a key still
--      importing is bumped (x2, capped at the ceiling, then frozen). Loop until
--      no live straggler.
--
-- This module is pure (no Factorio runtime, no tests/ dependency) so the headless
-- suite drives it directly. It owns only the DATA: pre_solve runs the actual
-- solves across the incremental solver's ticks and calls these between them. The
-- plan is plain string/number/bool tables -- it rides solution.observe_price in
-- `storage` and needs no metatable on load. Every table iteration that feeds an
-- output is sorted, so the plan is byte-identical across multiplayer clients.

local material_cycles = require "solver/material_cycles"
local create_problem = require "solver/create_problem"

local M = {}

local ELASTIC_COST = create_problem.elastic_cost
local TARGET_COST = create_problem.target_cost
M.K_PRED = 2.0
M.MAX_ROUNDS = 10

-- A recipe variable sits at the IPM interior floor (parked) below this; mirrors
-- tests/explore_detect.park_threshold (PARK_ABS / PARK_REL) so the production and
-- headless readers agree on "active". Relative to the largest recipe flow so it
-- adapts to the solution scale.
local PARK_ABS, PARK_REL = 1e-9, 1e-6
---@param x table<string, number>
---@param primals table<string, Primal>
---@return number
function M.park_threshold(x, primals)
    local max_x = 0
    for k, v in pairs(x) do
        local p = primals[k]
        if p and p.kind == "recipe" and math.abs(v) > max_x then max_x = math.abs(v) end
    end
    return math.max(PARK_ABS, max_x * PARK_REL)
end

-- Penalty-escape mass: sum |x| over shortage_source + elastic (the import /
-- target-relaxation cheat). A measurement utility for the research drivers
-- (tests/research/drive_observe_e2e etc.) that compare a priced result against
-- the baseline; pre_solve no longer reads it (the keep-best revert was removed).
-- Surplus is excluded: byproduct dump is accepted, only import/relaxation counts
-- as the thing observe-price reprices.
---@param primals table<string, Primal>
---@param x table<string, number>
---@return number
function M.cheat_mass(primals, x)
    local s = 0
    for key, p in pairs(primals) do
        if p.kind == "shortage_source" or p.kind == "elastic" then
            s = s + math.abs(x[key] or 0)
        end
    end
    return s
end

-- Sum |x| over every target variable -- how far the solve gave up on the
-- requested output. An elastic relaxes a lower/equal demand; a headroom is an
-- upper cap's pull-slack (limit - production), priced at target_cost so the cap
-- reads as a target to FILL, not a passive bound. Both are tier-1 (the
-- reference's is_target), so the target rescue that this feeds must minimize
-- both.
---@param primals table<string, Primal>
---@param x table<string, number>
---@return number
function M.target_relax(primals, x)
    local s = 0
    for key, p in pairs(primals) do
        if p.kind == "elastic" or p.kind == "headroom" then s = s + math.abs(x[key] or 0) end
    end
    return s
end

-- Objective COST carried by the escape boundary (surplus_sink + shortage_source +
-- initial_source), in elastic_cost units, excluding `exclude` keys -- the "other
-- escapes" a forced fabrication drags in. apply_observe reads the delta of this vs
-- baseline (dCost) and prices the cycle's shortage at K_PRED * dCost/qty.
--
-- This is COST-weighted, not mass-weighted, and that is load-bearing on the shipped
-- soft-gate config: forcing a cycle to fabricate drags in SECONDARY shortages that
-- the soft gate prices at elastic_cost*k (k=256). A mass read sees only their tiny
-- |x| and under-prices the cycle's shortage, so the chain keeps importing and the
-- verify loop has to bump it round after round; weighting each escape by its real
-- objective cost captures the 256x and the prediction lands in one shot. It also
-- folds initial_source in correctly: the raw supply a fabrication pulls in is huge
-- by mass but cheap by cost (source_cost ~ elastic_cost/1024 for items), so cost
-- weighting discounts it automatically instead of letting it dominate the delta.
-- (cheat_mass / target_relax stay mass-based: those measure import/relaxation
-- magnitude for the keep-best revert, where mass is the right neutral unit.)
---@param primals table<string, Primal>
---@param x table<string, number>
---@param exclude table<string, true>
---@return number
function M.escape_cost(primals, x, exclude)
    local s = 0
    for key, p in pairs(primals) do
        if (p.kind == "surplus_sink" or p.kind == "shortage_source" or p.kind == "initial_source")
            and not exclude[key] then
            s = s + (p.cost or 0) * math.abs(x[key] or 0)
        end
    end
    return s / ELASTIC_COST
end

local function ceiling_for(qty)
    return math.max(2, TARGET_COST / (ELASTIC_COST * qty))
end

-- Collect the reprice plan from a finished baseline solve. Returns a plain-table
-- plan (storage-safe) or nil when nothing qualifies.
--
-- A material qualifies as a reprice target by its OWN active shortage alone --
-- independent of SCC membership: any |shortage_source| carrying flow above the
-- park threshold is collected. The material-cycle SCCs are used ONLY to GROUP the
-- collected keys for the per-group observe solve: materials sharing one cyclic SCC
-- observe together (their escape-cost delta is coupled), every other material is
-- its own singleton group. Iteration over the sorted primal keys keeps keys,
-- groups, and group ids byte-identical across multiplayer clients.
--
-- plan = {
--   keys = { { key, material, qty, ceiling, group, mult=1, frozen=false, resolved_round=-1 } ... },
--   groups = { "<group-id>", ... },          -- observe order
--   exclude = { [shortage_key]=true ... },    -- the plan's own keys, for the cost delta
--   escape_cost_before, relax0, threshold,    -- baseline readouts
-- }
---@param primals table<string, Primal>
---@param x table<string, number>
---@param s table<string, number> Unused (the SCC idle certificate was removed); kept for call-site signature stability.
---@param lines NormalizedProductionLine[]
---@return table?
function M.collect_plan(primals, x, s, lines)
    local threshold = M.park_threshold(x, primals)
    local adj = material_cycles.build_material_graph(lines)
    local sccs = material_cycles.find_sccs(adj)

    -- SCC -> stable group id, used ONLY as the escape grouping unit: materials in
    -- one cyclic SCC share a group; everything else falls back to a per-material
    -- singleton below. Membership here does NOT gate whether a material is a
    -- reprice target.
    local scc_group = {}
    for si, scc in ipairs(sccs) do
        if material_cycles.is_cyclic_scc(scc, adj) then
            local gid = "scc:" .. si
            for _, m in ipairs(scc) do scc_group[m] = gid end
        end
    end

    -- Stable scan order over shortage primals.
    local prim_keys = {}
    for k in pairs(primals) do prim_keys[#prim_keys + 1] = k end
    table.sort(prim_keys)

    local keys, groups, exclude, seen_group = {}, {}, {}, {}
    for _, key in ipairs(prim_keys) do
        local p = primals[key]
        -- Any active shortage is a reprice target, regardless of SCC membership.
        if p.kind == "shortage_source" and p.material
            and (x[key] or 0) > threshold and (x[key] or 0) > 1e-12 then
            local qty = x[key]
            local gid = scc_group[p.material] or ("single:" .. p.material)
            keys[#keys + 1] = {
                key = key, material = p.material, qty = qty,
                ceiling = ceiling_for(qty), group = gid,
                mult = 1, frozen = false, resolved_round = -1,
            }
            exclude[key] = true
            if not seen_group[gid] then
                seen_group[gid] = true
                groups[#groups + 1] = gid
            end
        end
    end

    if #keys == 0 then return nil end
    return {
        keys = keys, groups = groups, exclude = exclude,
        escape_cost_before = M.escape_cost(primals, x, exclude),
        relax0 = M.target_relax(primals, x),
        threshold = threshold,
    }
end

-- Keys belonging to one group, in plan order.
local function group_keys(plan, gid)
    local out = {}
    for _, k in ipairs(plan.keys) do if k.group == gid then out[#out + 1] = k end end
    return out
end

-- Override map (material -> mult) that raises one group's shortages to their
-- ceiling -- the build for that group's OBSERVE solve. All other shortages keep
-- their flat/gate cost (absent from the map).
---@param plan table
---@param gid string
---@return table<string, number>
function M.observe_overrides(plan, gid)
    local o = {}
    for _, k in ipairs(group_keys(plan, gid)) do o[k.material] = k.ceiling end
    return o
end

-- Read one group's OBSERVE solve and set its keys' prices (mutates plan). If the
-- group's shortage does not clear, or clears only by relaxing the target, it is
-- cone-over-promise / unavoidable -> FREEZE (import is correct). Otherwise split
-- the observed escape-cost delta across the group's keys by qty share and price
-- each at clamp(K_PRED * share/qty, 2, ceiling).
---@param plan table
---@param gid string
---@param observe_primals table<string, Primal>
---@param observe_x table<string, number>
function M.apply_observe(plan, gid, observe_primals, observe_x)
    local gk = group_keys(plan, gid)
    local short_o, qsum = 0, 0
    for _, k in ipairs(gk) do
        short_o = short_o + (observe_x[k.key] or 0)
        qsum = qsum + k.qty
    end
    local relax_o = M.target_relax(observe_primals, observe_x)
    local cleared = short_o <= plan.threshold and relax_o <= plan.relax0 + 1e-4
    if not cleared then
        for _, k in ipairs(gk) do k.frozen = true end
        return
    end
    local dcost = M.escape_cost(observe_primals, observe_x, plan.exclude) - plan.escape_cost_before
    for _, k in ipairs(gk) do
        local share = dcost * (k.qty / qsum)
        k.mult = math.max(2, math.min(k.ceiling, M.K_PRED * share / k.qty))
    end
end

-- Override map (material -> mult) for a VERIFY / CORRECT solve: live keys at their
-- current mult, frozen keys omitted (they keep the flat import cost).
---@param plan table
---@return table<string, number>
function M.verify_overrides(plan)
    local o = {}
    for _, k in ipairs(plan.keys) do
        if not k.frozen then o[k.material] = k.mult end
    end
    return o
end

-- Read a VERIFY solve and advance every live key (mutates plan). A key whose
-- shortage parked is resolved (records the round). A key still importing is a
-- straggler: bump x2 (capped at the ceiling) or, once at the ceiling, freeze
-- (unavoidable import). Returns true while any key is still being bumped.
---@param plan table
---@param verify_x table<string, number>
---@param round integer
---@return boolean live_straggler
function M.apply_verify(plan, verify_x, round)
    local live = false
    for _, k in ipairs(plan.keys) do
        if not k.frozen then
            local v = verify_x[k.key] or 0
            if v <= plan.threshold then
                if k.resolved_round < 0 then k.resolved_round = round end
            else
                k.resolved_round = -1
                if k.mult >= k.ceiling * (1 - 1e-9) then
                    k.frozen = true
                else
                    k.mult = math.min(k.ceiling, k.mult * 2)
                    live = true
                end
            end
        end
    end
    return live
end

return M
