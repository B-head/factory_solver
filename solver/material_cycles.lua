-- Detects strongly connected components in the recipe graph and identifies
-- materials inside cycles that need external supply. The goal is to extend
-- the `|basic_source|` boundary beyond "ingredients with no producer in the
-- line set" (the rule encoded by compute_reachable_materials): when the
-- chain is fully cyclic, that seed is empty and the LP falls back to
-- `|shortage_source|` at penalty cost for *every* material in the cycle,
-- with no signal about which materials are the "natural" external inputs.
--
-- This module provides the structural analysis. Wiring its result into
-- create_problem.lua so deficit materials get a free `|basic_source|`
-- instead of a penalised `|shortage_source|` is a follow-up step.
--
-- Algorithm (Phase 1):
--   1. Build a material->material directed graph by adding an edge from
--      every ingredient to every product of every recipe. A recipe that
--      consumes and produces the same material (kovarex U-238) shows up
--      as a self-loop.
--   2. Tarjan's algorithm to find strongly connected components.
--   3. For each cyclic SCC, check whether it is a "source SCC" — no edge
--      enters it from outside. Non-source SCCs receive material from
--      upstream SCCs (e.g. SCC_uncommon in 5-tier quality recycling
--      receives cu/uncommon from EC/normal recycling's quality cascade),
--      so their materials are already supplied indirectly; flagging them
--      as deficits would give the LP free copies at every tier and
--      collapse to a degenerate solution that bypasses the cascade.
--   4. Inside each source SCC, compute the net flow per material when
--      every recipe touching the SCC runs at unit rate. A material whose
--      net consumption exceeds half its total inflow is flagged as a
--      deficit candidate.
--
-- The uniform-rate + 50% threshold is deliberately coarse. It correctly
-- distinguishes:
--   - Productivity-positive cycles (kovarex): all materials net >= 0,
--     no deficits.
--   - Mass-losing cycles (simple recycling): the ingredients are flagged
--     as deficits, the central recycled product is not (it balances at
--     a non-unit rate ratio).
-- For multi-tier cascades the source-SCC gate keeps the deficit set to
-- the cycle that actually needs external supply (cu/normal + ir/normal
-- in the 5-tier electronic-circuit case). Refining the per-material
-- threshold further is future work and would only matter for
-- intra-cycle stoichiometries that happen to land near 50%.

local tn = require "manage/typed_name"

local M = {}

---Build the material-to-material directed graph. An edge `a -> b` exists
---when some recipe consumes `a` and produces `b`. Materials are
---represented by their LP variable name (`typed_name_to_variable_name`)
---so the graph keys agree with the rest of the solver.
---@param production_lines NormalizedProductionLine[]
---@return table<string, table<string, true>> adjacency
function M.build_material_graph(production_lines)
    local adj = {} ---@type table<string, table<string, true>>
    local function ensure(v)
        if not adj[v] then adj[v] = {} end
    end

    for _, line in ipairs(production_lines) do
        local ingredients = {}
        for _, ing in ipairs(line.ingredients) do
            ingredients[#ingredients + 1] = tn.typed_name_to_variable_name(ing)
        end
        if line.fuel_ingredient then
            ingredients[#ingredients + 1] = tn.typed_name_to_variable_name(line.fuel_ingredient)
        end
        local products = {}
        for _, prod in ipairs(line.products) do
            products[#products + 1] = tn.typed_name_to_variable_name(prod)
        end

        for _, i_var in ipairs(ingredients) do
            ensure(i_var)
            for _, p_var in ipairs(products) do
                ensure(p_var)
                adj[i_var][p_var] = true
            end
        end
        -- Make sure pure-product / pure-ingredient materials still appear
        -- in the graph; otherwise SCC would silently drop them.
        for _, p_var in ipairs(products) do ensure(p_var) end
    end
    return adj
end

---Tarjan's SCC algorithm, iterative to avoid Lua's C-stack depth limit on
---large recipe graphs. Returns a list of SCCs in reverse topological order
---(per Tarjan); each SCC is a sorted list of node names. Visiting nodes in
---sorted order keeps the output deterministic, which matters because the
---caller may use it to derive `storage`-bound state and the project runs
---in Factorio's lockstep VM (see CLAUDE.md).
---@param adj table<string, table<string, true>>
---@return string[][] sccs
function M.find_sccs(adj)
    local index_counter = 0
    local stack = {}
    local on_stack = {}
    local node_index = {}
    local node_lowlink = {}
    local sccs = {}

    local nodes = {}
    for k in pairs(adj) do nodes[#nodes + 1] = k end
    table.sort(nodes)

    -- Each call_stack frame tracks the iterative state of one strongconnect
    -- invocation: which neighbour we are about to recurse into, and whether
    -- we are returning from a child (to update lowlink with its result).
    local function strongconnect_iter(start)
        local call_stack = { { node = start, neighbors = nil, idx = 0, phase = "enter" } }
        while #call_stack > 0 do
            local frame = call_stack[#call_stack]
            local v = frame.node

            if frame.phase == "enter" then
                node_index[v] = index_counter
                node_lowlink[v] = index_counter
                index_counter = index_counter + 1
                stack[#stack + 1] = v
                on_stack[v] = true

                local neighbors = {}
                for w in pairs(adj[v] or {}) do neighbors[#neighbors + 1] = w end
                table.sort(neighbors)
                frame.neighbors = neighbors
                frame.phase = "loop"
            end

            if frame.phase == "return_from_child" then
                local w = frame.pending_child
                if node_lowlink[w] < node_lowlink[v] then
                    node_lowlink[v] = node_lowlink[w]
                end
                frame.phase = "loop"
            end

            if frame.phase == "loop" then
                frame.idx = frame.idx + 1
                if frame.idx > #frame.neighbors then
                    if node_lowlink[v] == node_index[v] then
                        local scc = {}
                        repeat
                            local w = stack[#stack]
                            stack[#stack] = nil
                            on_stack[w] = nil
                            scc[#scc + 1] = w
                        until w == v
                        table.sort(scc)
                        sccs[#sccs + 1] = scc
                    end
                    call_stack[#call_stack] = nil
                else
                    local w = frame.neighbors[frame.idx]
                    if node_index[w] == nil then
                        frame.phase = "return_from_child"
                        frame.pending_child = w
                        call_stack[#call_stack + 1] = { node = w, idx = 0, phase = "enter" }
                    elseif on_stack[w] and node_index[w] < node_lowlink[v] then
                        node_lowlink[v] = node_index[w]
                    end
                end
            end
        end
    end

    for _, v in ipairs(nodes) do
        if node_index[v] == nil then
            strongconnect_iter(v)
        end
    end
    return sccs
end

---True when an SCC participates in a cycle. A multi-node SCC is always
---cyclic; a single-node SCC is cyclic only when it has a self-loop
---(e.g. a recipe that both consumes and produces the same material).
---@param scc string[]
---@param adj table<string, table<string, true>>
---@return boolean
function M.is_cyclic_scc(scc, adj)
    if #scc > 1 then return true end
    local v = scc[1]
    local out = adj[v]
    return (out and out[v]) == true
end

---True when no edge enters the SCC from a node outside it. Source SCCs
---are where deficit materials genuinely need external supply; non-source
---SCCs receive flow from upstream SCCs (e.g. quality cascades) and would
---otherwise be over-flagged.
---@param scc_set table<string, true>
---@param adj table<string, table<string, true>>
---@return boolean
function M.is_source_scc(scc_set, adj)
    for u, neighbors in pairs(adj) do
        if not scc_set[u] then
            for v in pairs(neighbors) do
                if scc_set[v] then return false end
            end
        end
    end
    return true
end

---For every material in `scc_set`, sum the per-second flow contribution
---of every recipe that touches the SCC (consumes or produces at least one
---SCC material) when each such recipe runs at unit rate (rate = 1). Returns
---both the signed net (production - consumption) and the total consumption,
---so callers can compute deficit ratios relative to the material's inflow.
---@param production_lines NormalizedProductionLine[]
---@param scc_set table<string, true>
---@return table<string, number> net  production minus consumption per material
---@return table<string, number> consumption  total consumption per material
function M.compute_net_flow(production_lines, scc_set)
    local net = {}
    local consumption = {}
    for m in pairs(scc_set) do net[m] = 0; consumption[m] = 0 end

    for _, line in ipairs(production_lines) do
        local touches = false
        for _, prod in ipairs(line.products) do
            if scc_set[tn.typed_name_to_variable_name(prod)] then touches = true; break end
        end
        if not touches then
            for _, ing in ipairs(line.ingredients) do
                if scc_set[tn.typed_name_to_variable_name(ing)] then touches = true; break end
            end
            if not touches and line.fuel_ingredient
                and scc_set[tn.typed_name_to_variable_name(line.fuel_ingredient)] then
                touches = true
            end
        end
        if touches then
            for _, prod in ipairs(line.products) do
                local v = tn.typed_name_to_variable_name(prod)
                if scc_set[v] then
                    net[v] = net[v] + prod.amount_per_second
                end
            end
            for _, ing in ipairs(line.ingredients) do
                local v = tn.typed_name_to_variable_name(ing)
                if scc_set[v] then
                    net[v] = net[v] - ing.amount_per_second
                    consumption[v] = consumption[v] + ing.amount_per_second
                end
            end
            if line.fuel_ingredient then
                local v = tn.typed_name_to_variable_name(line.fuel_ingredient)
                if scc_set[v] then
                    net[v] = net[v] - line.fuel_ingredient.amount_per_second
                    consumption[v] = consumption[v] + line.fuel_ingredient.amount_per_second
                end
            end
        end
    end
    return net, consumption
end

---Default deficit threshold: a material is flagged when its net deficit is
---more than 50% of its consumption at uniform recipe rates. This excludes
---materials that are merely "off by a recipe ratio" (e.g. the recycled
---product itself, which balances at non-unit rates) while still catching
---genuine mass-losing ingredients.
local default_threshold_ratio = 0.5

---Identify materials that need external supply. A material qualifies when:
---  - It belongs to a cyclic SCC, AND
---  - the SCC is a source SCC (no edge enters it from outside), AND
---  - net < -threshold_ratio * consumption at uniform recipe rates.
---@param production_lines NormalizedProductionLine[]
---@param threshold_ratio number?  default 0.5
---@return table<string, true> deficits  material variable names
---@return string[][] cyclic_sccs  every cyclic SCC, not just source ones (for diagnostics)
function M.find_deficit_materials(production_lines, threshold_ratio)
    threshold_ratio = threshold_ratio or default_threshold_ratio

    local adj = M.build_material_graph(production_lines)
    local sccs = M.find_sccs(adj)
    local cyclic_sccs = {}
    local deficits = {}

    for _, scc in ipairs(sccs) do
        if M.is_cyclic_scc(scc, adj) then
            cyclic_sccs[#cyclic_sccs + 1] = scc
            local scc_set = {}
            for _, m in ipairs(scc) do scc_set[m] = true end
            if M.is_source_scc(scc_set, adj) then
                local net, consumption = M.compute_net_flow(production_lines, scc_set)
                for _, m in ipairs(scc) do
                    local c = consumption[m]
                    if c > 0 and net[m] < -threshold_ratio * c then
                        deficits[m] = true
                    end
                end
            end
        end
    end
    return deficits, cyclic_sccs
end

return M
