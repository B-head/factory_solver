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
--   2. OBSERVE (one solve per SCC at the ceiling) -> read the escape-mass delta
--      dEsc the forced fabrication drags in, and price the key at
--      clamp(K_PRED * dEsc/qty, 2, ceiling). An SCC whose shortage does not
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
M.K_PRED = 1.5
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

-- Sum |x| over the escape-priced boundary (surplus_sink + shortage_source),
-- excluding `exclude` keys -- the "other escapes" a forced fabrication drags in.
---@param primals table<string, Primal>
---@param x table<string, number>
---@param exclude table<string, true>
---@return number
function M.other_escape(primals, x, exclude)
    local s = 0
    for key, p in pairs(primals) do
        if (p.kind == "surplus_sink" or p.kind == "shortage_source") and not exclude[key] then
            s = s + math.abs(x[key] or 0)
        end
    end
    return s
end

-- Recipe-flow variables internal to an SCC (>= 1 ingredient AND >= 1 product in
-- the SCC), summed -- the cycle's running flow (0 = idle).
local function internal_flow(lines, scc_set, x)
    local s = 0
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
            if hp then s = s + math.abs(x[tn.typed_name_to_variable_name(line.recipe_typed_name)] or 0) end
        end
    end
    return s
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
--   exclude = { [shortage_key]=true ... },    -- the plan's own keys, for the escape delta
--   esc_before, relax0, threshold,            -- baseline readouts
-- }
---@param primals table<string, Primal>
---@param x table<string, number>
---@param lines NormalizedProductionLine[]
---@return table?
function M.collect_plan(primals, x, lines)
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
                if self_sust and fab and internal_flow(lines, scc_set, x) < 1e-6 then
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
        esc_before = M.other_escape(primals, x, exclude),
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
-- the observed escape delta across the group's keys by qty share and price each
-- at clamp(K_PRED * share/qty, 2, ceiling).
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
    local desc = M.other_escape(observe_primals, observe_x, plan.exclude) - plan.esc_before
    for _, k in ipairs(gk) do
        local share = desc * (k.qty / qsum)
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
