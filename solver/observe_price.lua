-- observe-price: the import-vs-fabricate fixed point for unreachable, self-
-- sustaining catalyst cycles.
--
-- The soft gate (create_problem's reachability_soft_gate_k) handles every
-- REACHABLE material: its shortage is priced high so the chain runs. What it
-- leaves at the flat elastic_cost are the UNREACHABLE produced+consumed cycles --
-- closed catalyst loops (the antimony purex sb-oxide, the tuuphra biological
-- loop) the user placed but that the LP would rather penalty-import than run.
-- For those the right shortage cost is not a fixed gate value but a per-material
-- one that only the solve can reveal, so this module measures it:
--
--   1. BASELINE solve (flat 1024) -> collect the avoidable-cheat shortage keys:
--      a material with an active shortage whose cyclic SCC is self-sustaining,
--      export-feasible, and currently idle (the placed cycle is not running).
--   2. OBSERVE (one solve per SCC at the ceiling) -> read the escape-cost delta
--      dCost the forced fabrication drags in (objective cost of the collateral
--      surplus/shortage/initial_source, in elastic_cost units -- see M.escape_cost
--      for why cost, not mass), and price the key at
--      clamp(K_PRED * dCost/qty, 2, ceiling). An SCC whose shortage does not
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
local tn = require "manage/typed_name"

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
-- target-relaxation cheat). pre_solve compares this before and after the loop:
-- observe-price is a best-effort improvement, so a result whose cheat exceeds the
-- baseline is reverted to the baseline (the placed cycle stays a neutral import
-- rather than a worse fabrication). Surplus is excluded: byproduct dump is
-- accepted, only import/relaxation counts as the thing observe-price should cut.
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

-- Sum |x| over every elastic (target-relaxation) variable -- how far the solve
-- gave up on the requested output.
---@param primals table<string, Primal>
---@param x table<string, number>
---@return number
function M.target_relax(primals, x)
    local s = 0
    for key, p in pairs(primals) do
        if p.kind == "elastic" then s = s + math.abs(x[key] or 0) end
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

-- Is the SCC's internal recipe flow idle? Internal = >= 1 ingredient AND >= 1
-- product in the SCC. Two tests, ORed, because their blind spots are disjoint:
--
--   * |flow| sum < IDLE_FLOW_EPS. Parked recipes read exactly 0 at normal
--     solution scale (purify_zeros snaps them), so any flow at all means the
--     cycle runs. But interior-point dust that escapes purification sits at an
--     ABSOLUTE floor coupled to the solve tolerance (~1e-7..3e-6 measured),
--     independent of solution scale: on a very small-scale plan (cycle flows
--     below ~1e-6/s -- items-per-hour pins through deep chains) that dust
--     crosses the epsilon and a truly idle cycle would read "running",
--     silently dropping it from the plan.
--   * Dual certificate: every internal recipe is exactly 0 or dual-dominated
--     (reduced cost s > x, the same nonbasic test certify_zeros uses). The
--     certificate is what purification itself failed to apply to that dust, so
--     re-reading it here rescues the small-scale case; a genuinely basic
--     (running) recipe has s -> 0 < x and never certifies.
--
-- The OR can only widen "idle", so it eliminates the unguarded failure (idle
-- cycle missed -> cheat never repriced) at the cost of occasionally collecting
-- a sub-tolerance running cycle -- that direction is bounded by the verify
-- loop and the keep-best revert in pre_solve.
local IDLE_FLOW_EPS = 1e-6
local function cycle_idle(lines, scc_set, x, s)
    local flow, certified = 0, true
    for _, line in ipairs(lines) do
        local hi = false
        for _, ing in ipairs(line.ingredients) do
            if scc_set[tn.typed_name_to_variable_name(ing)] then hi = true; break end
        end
        if not hi and line.fuel_ingredient and scc_set[tn.typed_name_to_variable_name(line.fuel_ingredient)] then hi = true end
        if hi then
            local hp = false
            for _, prod in ipairs(line.products) do
                if scc_set[tn.typed_name_to_variable_name(prod)] then hp = true; break end
            end
            if not hp and line.fuel_burnt_result and scc_set[tn.typed_name_to_variable_name(line.fuel_burnt_result)] then hp = true end
            if hp then
                local key = tn.typed_name_to_variable_name(line.recipe_typed_name)
                local v = math.abs(x[key] or 0)
                flow = flow + v
                if v > 0 and (s[key] or 0) <= v then certified = false end
            end
        end
    end
    return flow < IDLE_FLOW_EPS or certified
end

local function ceiling_for(qty)
    return math.max(2, TARGET_COST / (ELASTIC_COST * qty))
end

-- Collect the avoidable-cheat plan from a finished baseline solve. Returns a
-- plain-table plan (storage-safe) or nil when nothing qualifies. The plan keys
-- are sorted, and SCC groups are keyed by a stable id, so two clients build the
-- identical plan.
--
-- plan = {
--   keys = { { key, material, qty, ceiling, group, mult=1, frozen=false, resolved_round=-1 } ... },
--   groups = { "<group-id>", ... },          -- observe order
--   exclude = { [shortage_key]=true ... },    -- the plan's own keys, for the cost delta
--   escape_cost_before, relax0, threshold,    -- baseline readouts
-- }
---@param primals table<string, Primal>
---@param x table<string, number>
---@param s table<string, number> Dual slack (reduced cost) values from the same PackedVariables as `x`; cycle_idle's certificate reads them.
---@param lines NormalizedProductionLine[]
---@return table?
function M.collect_plan(primals, x, s, lines)
    local threshold = M.park_threshold(x, primals)
    local adj = material_cycles.build_material_graph(lines)
    local sccs = material_cycles.find_sccs(adj)

    -- Stable scan order over shortage primals.
    local prim_keys = {}
    for k in pairs(primals) do prim_keys[#prim_keys + 1] = k end
    table.sort(prim_keys)

    local keys, groups, exclude = {}, {}, {}
    for si, scc in ipairs(sccs) do
        if material_cycles.is_cyclic_scc(scc, adj) then
            local scc_set = {}
            for _, m in ipairs(scc) do scc_set[m] = true end
            local active, active_mats = {}, {}
            for _, key in ipairs(prim_keys) do
                local p = primals[key]
                if p.kind == "shortage_source" and p.material and scc_set[p.material]
                    and (x[key] or 0) > threshold then
                    active[#active + 1] = key
                    active_mats[#active_mats + 1] = p.material
                end
            end
            if #active >= 1 then
                local self_sust = material_cycles.is_self_sustaining(lines, scc)
                local fab = true
                for _, mm in ipairs(active_mats) do
                    if not material_cycles.export_feasible(lines, mm) then fab = false; break end
                end
                if self_sust and fab and cycle_idle(lines, scc_set, x, s) then
                    local gid = "scc:" .. si
                    local added = false
                    for _, key in ipairs(active) do
                        local qty = x[key] or 0
                        if qty > 1e-12 then
                            keys[#keys + 1] = {
                                key = key, material = primals[key].material, qty = qty,
                                ceiling = ceiling_for(qty), group = gid,
                                mult = 1, frozen = false, resolved_round = -1,
                            }
                            exclude[key] = true
                            added = true
                        end
                    end
                    if added then groups[#groups + 1] = gid end
                end
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
