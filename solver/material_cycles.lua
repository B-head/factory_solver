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
--   4. Inside each source SCC, first ask whether the cycle can sustain
--      itself: is there a positive recipe-rate vector x with A·x >= 0 for
--      every internal material (cone_feasible / is_self_sustaining)? If so
--      the cycle produces at least as much of every material as it consumes
--      and needs no external supply, so nothing is flagged. Only when the
--      SCC is NOT self-sustaining do we fall back to the unit-rate snapshot:
--      compute net flow with every touching recipe at rate 1, and flag any
--      material the cycle consumes more than 1.5x faster than it produces
--      (net deficit > half its internal production).
--
-- The self-sustaining gate is exact (an LP feasibility test over rate
-- *vectors*); the uniform-rate + 50% threshold behind it is a deliberately
-- coarse way to pick *which* materials to flag once we know the cycle can't
-- close on its own. Together they distinguish:
--   - Productivity-positive cycles (kovarex) and mass-positive <grow> loops
--     (Gleba seed<->plant): self-sustaining, so no deficits even though the
--     unit-rate snapshot looks deficit-heavy for the grow case.
--   - Mass-losing cycles (simple recycling): not self-sustaining, so the
--     heuristic flags the consumed ingredients and leaves the central
--     recycled product (it balances at a non-unit rate ratio) alone.
-- For multi-tier cascades the source-SCC gate keeps the deficit set to
-- the cycle that actually needs external supply (cu/normal + ir/normal
-- in the 5-tier electronic-circuit case).

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

---Build the per-recipe net-flow matrix for one SCC. Columns are the recipes
---that touch the SCC (consume or produce at least one SCC material); rows are
---the SCC materials in the order given by `scc`. Entry A[i][j] is the net
---production (products minus ingredients/fuel) of material i by recipe j at
---unit rate. Unlike compute_net_flow this keeps recipes separate, so callers
---can reason about rate *vectors* rather than the uniform-rate snapshot.
---@param production_lines NormalizedProductionLine[]
---@param scc string[]  SCC materials, sorted (defines row order)
---@return number[][] A  A[i][j], i=1..#scc materials, j=1..#columns recipes
local function build_scc_matrix(production_lines, scc)
    local row_of = {}
    for i, m in ipairs(scc) do row_of[m] = i end

    local columns = {}
    for _, line in ipairs(production_lines) do
        local col = nil
        local function add(var, amount)
            local i = row_of[var]
            if i then
                if not col then
                    col = {}
                    for k = 1, #scc do col[k] = 0 end
                end
                col[i] = col[i] + amount
            end
        end
        for _, prod in ipairs(line.products) do
            add(tn.typed_name_to_variable_name(prod), prod.amount_per_second)
        end
        for _, ing in ipairs(line.ingredients) do
            add(tn.typed_name_to_variable_name(ing), -ing.amount_per_second)
        end
        if line.fuel_ingredient then
            add(tn.typed_name_to_variable_name(line.fuel_ingredient),
                -line.fuel_ingredient.amount_per_second)
        end
        if col then columns[#columns + 1] = col end
    end

    -- Transpose into A[material][recipe].
    local A = {}
    for i = 1, #scc do
        local row = {}
        for j = 1, #columns do row[j] = columns[j][i] end
        A[i] = row
    end
    return A
end

local feasibility_eps = 1e-9

---Phase-1 simplex feasibility test for the cone problem
---   ∃ x ≥ 0, x ≠ 0, A·x ≥ 0
---i.e. "can this SCC sustain itself at some positive recipe-rate vector?"
---A self-sustaining SCC produces at least as much of every internal material
---as it consumes (kovarex's productivity cycle, or a Gleba <grow> loop that
---gains mass), so it needs no external supply and must not be flagged.
---
---The LP is normalized with Σx = 1 to bound it, then solved as a single-
---artificial Phase-1: material rows `-Σⱼ A[i][j]·xⱼ + sᵢ = 0` start with the
---surplus sᵢ in the basis at value 0, and the normalization row `Σⱼ xⱼ + a = 1`
---starts with one artificial a = 1. Driving a → 0 means a valid x exists.
---Bland's rule guarantees termination under the heavy degeneracy these
---all-zero-RHS rows produce.
---@param A number[][]  A[i][j], i=1..m materials, j=1..n recipes
---@param m integer
---@param n integer
---@return boolean
local function cone_feasible(A, m, n)
    if n == 0 then return false end
    local a_col = n + m + 1
    local N = a_col
    local R = m + 1
    local rhs = N + 1

    local T = {}
    for i = 1, R do
        local row = {}
        for c = 1, rhs do row[c] = 0 end
        T[i] = row
    end
    for i = 1, m do
        for j = 1, n do T[i][j] = -A[i][j] end
        T[i][n + i] = 1
    end
    for j = 1, n do T[R][j] = 1 end
    T[R][a_col] = 1
    T[R][rhs] = 1

    local basis = {}
    for i = 1, m do basis[i] = n + i end
    basis[R] = a_col

    -- Reduced cost of column j. Only the artificial carries cost 1, so the
    -- objective contribution is the artificial's tableau row (if still basic).
    local function reduced_cost(j)
        local cj = (j == a_col) and 1 or 0
        for i = 1, R do
            if basis[i] == a_col then return cj - T[i][j] end
        end
        return cj
    end

    local max_iter = 1000 + 20 * N
    for _ = 1, max_iter do
        local enter = nil
        for j = 1, N do
            if reduced_cost(j) < -feasibility_eps then enter = j; break end
        end
        if not enter then break end

        local min_ratio = math.huge
        for i = 1, R do
            local aij = T[i][enter]
            if aij > feasibility_eps then
                local ratio = T[i][rhs] / aij
                if ratio < min_ratio then min_ratio = ratio end
            end
        end
        if min_ratio == math.huge then break end

        local leave, leave_basis = nil, math.huge
        for i = 1, R do
            local aij = T[i][enter]
            if aij > feasibility_eps then
                local ratio = T[i][rhs] / aij
                if ratio <= min_ratio + feasibility_eps and basis[i] < leave_basis then
                    leave, leave_basis = i, basis[i]
                end
            end
        end
        if not leave then break end

        local piv = T[leave][enter]
        for c = 1, rhs do T[leave][c] = T[leave][c] / piv end
        for i = 1, R do
            if i ~= leave then
                local f = T[i][enter]
                if f ~= 0 then
                    for c = 1, rhs do T[i][c] = T[i][c] - f * T[leave][c] end
                end
            end
        end
        basis[leave] = enter
    end

    local a_val = 0
    for i = 1, R do
        if basis[i] == a_col then a_val = T[i][rhs]; break end
    end
    return a_val <= feasibility_eps * 100
end

---True when the SCC can sustain itself at some positive recipe-rate vector
---(see cone_feasible). Such cycles need no external supply, so none of their
---materials are deficits regardless of the unit-rate snapshot.
---@param production_lines NormalizedProductionLine[]
---@param scc string[]
---@return boolean
function M.is_self_sustaining(production_lines, scc)
    local A = build_scc_matrix(production_lines, scc)
    return cone_feasible(A, #scc, A[1] and #A[1] or 0)
end

---Default deficit threshold: a material is flagged when its net deficit is
---more than 50% of its internal PRODUCTION at uniform recipe rates (the cycle
---consumes it more than 1.5x faster than it produces it). Measuring against
---production rather than consumption keeps the ratio meaningful when a recipe
---re-emits the material it consumes (asteroid reprocessing's same-tier
---self-roll): self-production cancels out of `net` but would otherwise pad the
---consumption denominator and hide the deficit. This still excludes materials
---that merely balance at a non-unit recipe ratio (the recycled product itself)
---while catching genuine mass-losing ingredients.
local default_threshold_ratio = 0.5

---Identify materials that need external supply. A material qualifies when:
---  - It belongs to a cyclic SCC, AND
---  - the SCC is a source SCC (no edge enters it from outside), AND
---  - the SCC is NOT self-sustaining (no positive rate vector balances it;
---    see is_self_sustaining), AND
---  - net < -threshold_ratio * production at uniform recipe rates (production
---    = net + consumption; see default_threshold_ratio for why production).
---The self-sustaining gate runs before the unit-rate heuristic so that a
---mass-positive cycle (kovarex productivity, a Gleba <grow> loop) flags
---nothing even though its uniform-rate snapshot looks deficit-heavy.
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
            if M.is_source_scc(scc_set, adj)
                and not M.is_self_sustaining(production_lines, scc) then
                local net, consumption = M.compute_net_flow(production_lines, scc_set)
                for _, m in ipairs(scc) do
                    -- Measure the deficit against the material's internal
                    -- PRODUCTION, not its consumption. A recipe that consumes
                    -- and re-emits the same material at the same tier (asteroid
                    -- reprocessing, which crushes 0.9 oxide/normal and re-rolls
                    -- 0.315 back) inflates consumption with mass it immediately
                    -- replaces, masking a genuine deficit under a consumption
                    -- ratio. production = net + consumption (compute_net_flow
                    -- gives net and consumption); flag when the cycle consumes
                    -- this material more than (1 + threshold)x faster than it
                    -- can produce it internally.
                    local production = net[m] + consumption[m]
                    if production > 0 and net[m] < -threshold_ratio * production then
                        deficits[m] = true
                    end
                end
            end
        end
    end
    return deficits, cyclic_sccs
end

return M
