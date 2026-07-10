-- Sparse elastic placement: the shared machinery for the "batch" and "smart"
-- solver norms (manage/pre_solve.lua M.placement_step).
--
-- Both norms answer the same question -- WHERE do the violation escapes
-- (|shortage_source| / |surplus_sink|) need to exist? -- instead of placing
-- one on every intermediate and letting the L2 spread activate nearly all of
-- them (corpus: ~19 active groups mean, of which only ~2-3 are structurally
-- necessary). A sparse placement leaves the user a short, readable list of
-- import/dump channels to adjust.
--
--   "batch"  measures the placement: close every group, run a Phase-I LP
--            (artificials on every row, everything else free), open every
--            group the artificial support names, repeat until feasible.
--            2-3 linear solves on the research corpus (probe_batch_iis.lua).
--   "smart"  derives the placement statically from the necessity law
--            (project_fork_necessity_verification): one representative per
--            material-cycle SCC unit and per multi-output junction
--            (probe_scc_compress.lua v=law / probe_law_fix.lua v=smart).
--
-- Either placement then re-solves the L2 restricted to the placed groups,
-- guarded on the PHYSICAL import/dump totals against the all-elastic base
-- solve: a small set placed away from the true imbalance amplifies flows
-- through stoichiometric ratios (research: tbp 5 -> 913), and only a solved
-- solution reveals it. A failed guard round widens the placement -- "batch"
-- by physical rank, "smart" structurally (the SCC / junction partners of the
-- groups whose flow inflated; the corpus failure dissection showed the needed
-- channel is a low-flow SCC sibling that a rank-based widening never reaches).
--
-- Pure functions over Problem metadata (Primal.kind / .material /
-- .material_base) plus the normalized lines -- no key-string parsing (see
-- CLAUDE.md), no Factorio runtime, so the headless suite drives it directly.
-- Determinism (multiplayer lockstep): every derived list is built under a
-- total order (sorted keys / explicit tie-breaks), so `pairs` iteration order
-- never leaks into the placement.
local vk = require "solver/var_key"

local M = {}

-- A group's flow below this is numerical dust (same floor as mode_compress).
local ACTIVE_EPS = 1e-6

--------------------------------------------------------------------------------
-- Group index and physical stats
--------------------------------------------------------------------------------

---Index the violation groups of a build: one group per base material
---(Primal.material_base -- temperature windows folded, the same grain as the
---mode-compression fold and the L2 violation locks), carrying the material
---rows of every variant so a rebuild can exclude them.
---@param problem Problem
---@return table<string, string[]> groups base material -> sorted material rows
function M.violation_groups(problem)
    local sets = {} ---@type table<string, table<string, true>>
    for _, p in pairs(problem.primals) do
        if (p.kind == "shortage_source" or p.kind == "surplus_sink") and p.material then
            local base = p.material_base or p.material
            local set = sets[base]
            if not set then
                set = {}
                sets[base] = set
            end
            set[p.material] = true
        end
    end
    local groups = {}
    for base, set in pairs(sets) do
        local mats = {}
        for mat in pairs(set) do mats[#mats + 1] = mat end
        table.sort(mats)
        groups[base] = mats
    end
    return groups
end

---Invert a group index to material row -> base material.
---@param groups table<string, string[]>
---@return table<string, string>
function M.invert_groups(groups)
    local mat2base = {}
    for base, mats in pairs(groups) do
        for _, mat in ipairs(mats) do mat2base[mat] = base end
    end
    return mat2base
end

---The physical violation totals of a converged solve, per group and summed.
---Physical = |coefficient * x| in material units (the mode-compression read).
---@param problem Problem
---@param x table<string, number> PackedVariables.x
---@return {imp: number, dmp: number, gp: table<string, number>}
function M.violation_stats(problem, x)
    local imp, dmp, gp = 0, 0, {}
    for key, p in pairs(problem.primals) do
        if (p.kind == "shortage_source" or p.kind == "surplus_sink") and p.material then
            local terms = problem.subject_terms[key]
            local coefficient = (terms and terms[p.material]) or 1
            local phys = math.abs(coefficient * (x[key] or 0))
            local base = p.material_base or p.material
            gp[base] = (gp[base] or 0) + phys
            if p.kind == "shortage_source" then imp = imp + phys else dmp = dmp + phys end
        end
    end
    return { imp = imp, dmp = dmp, gp = gp }
end

---The exclusion sets a placement-restricted rebuild feeds to create_problem:
---every material row of every group NOT in `placed` loses both its import
---hatch and its dump escape.
---@param groups table<string, string[]>
---@param placed table<string, true>
---@return table<string, true> hatch_exclude
---@return table<string, true> sink_exclude
function M.excludes(groups, placed)
    local hatch, sink = {}, {}
    for base, mats in pairs(groups) do
        if not placed[base] then
            for _, mat in ipairs(mats) do
                hatch[mat] = true
                sink[mat] = true
            end
        end
    end
    return hatch, sink
end

--------------------------------------------------------------------------------
-- Phase-I ("batch" placement measurement)
--------------------------------------------------------------------------------

---Shape a freshly built (placement-excluded) problem into the Phase-I
---feasibility LP: every primal cost drops to 0 and every dual row gains a
---± artificial pair at cost 1, so the LP is feasible by construction and its
---optimum is the least total row violation.
---
---EXCEPT the target machinery: no artificial goes on a row referenced by a
---target relaxation column (kinds "elastic" / "headroom" -- their limit rows
---and the target-budget row). With those rows hard (and the target budget the
---caller threads in capping the relaxations at the base solve's own level),
---the Phase-I optimum measures "the least material imbalance GIVEN the
---targets stay met" -- otherwise the LP would meet an expensive target by
---relaxing it (the all-zero collapse economics) and the artificial support
---would name nothing.
---@param problem Problem A create_problem build (no L2 shaping).
---@return {pos: string, neg: string, row: string}[] arts sorted by row
function M.shape_phase1(problem)
    local target_rows = {} ---@type table<string, true>
    for key, p in pairs(problem.primals) do
        if p.kind == "elastic" or p.kind == "headroom" then
            for row in pairs(problem.subject_terms[key] or {}) do
                target_rows[row] = true
            end
        end
    end
    for _, p in pairs(problem.primals) do
        p.cost = 0
    end
    local rows = {}
    for row in pairs(problem.duals) do
        if not target_rows[row] then rows[#rows + 1] = row end
    end
    table.sort(rows)
    local arts = {}
    for _, row in ipairs(rows) do
        local pos, neg = vk.phase1_art(row, 1), vk.phase1_art(row, -1)
        problem:add_objective(pos, 1, false, "slack")
        problem:add_subject_term(pos, row, 1)
        problem:add_objective(neg, 1, false, "slack")
        problem:add_subject_term(neg, row, -1)
        arts[#arts + 1] = { pos = pos, neg = neg, row = row }
    end
    return arts
end

---Read a finished Phase-I solve: the total artificial mass and its support
---(rows whose artificial stays above `tol`), sorted largest first (key
---ascending as the tie-break).
---@param arts {pos: string, neg: string, row: string}[] From M.shape_phase1.
---@param x table<string, number> PackedVariables.x
---@param tol number
---@return number total
---@return {row: string, art: number}[] support
function M.phase1_support(arts, x, tol)
    local total, support = 0, {}
    for _, a in ipairs(arts) do
        local v = math.abs(x[a.pos] or 0) + math.abs(x[a.neg] or 0)
        total = total + v
        if v > tol then support[#support + 1] = { row = a.row, art = v } end
    end
    table.sort(support, function(a, b)
        if a.art ~= b.art then return a.art > b.art end
        return a.row < b.row
    end)
    return total, support
end

--------------------------------------------------------------------------------
-- Static law placement ("smart")
--------------------------------------------------------------------------------

---The base-material key of a normalized product/ingredient value, matching
---the grain of Primal.material_base (temperature windows folded to the plain
---fluid key; items keep their quality). Built through var_key -- never by
---slicing an existing key.
---@param value NormalizedAmount|NormalizedFixedAmount
---@return string
local function value_base(value)
    return vk.material({ type = value.type, name = value.name, quality = value.quality or "normal" })
end

---Derive the static "law" placement from the necessity law: one
---representative group per SCC unit of the material graph (variant-level
---Tarjan over the LP's own subject terms, plus the self-loop bases the net
---coefficients hide -- growth loops and perfect catalysts) and one per
---multi-output junction. The representative is the group with the largest
---base-solve physical flow (key ascending as the tie-break).
---
---Returns the placement plus the unit / junction member lists (base
---materials) the structural guard widening walks.
---@param problem Problem The all-elastic base build.
---@param lines NormalizedProductionLine[] The same lines the build came from.
---@param gp table<string, number> Per-group physical flow of the base solve.
---@return table<string, true> placed
---@return string[][] units SCC units as sorted base-material arrays.
---@return string[][] junctions Junction outputs as sorted base-material arrays.
function M.law_placement(problem, lines, gp)
    local groups = M.violation_groups(problem)
    local mat2base = M.invert_groups(groups)
    local free = {} ---@type table<string, true>  free-port material rows
    for _, p in pairs(problem.primals) do
        if (p.kind == "initial_source" or p.kind == "final_sink") and p.material then
            free[p.material] = true
        end
    end

    -- The variant-level material graph from the recipe/bridge subject terms:
    -- coef > 0 produces the row, coef < 0 consumes it. Only rows that are
    -- material rows (a violation group variant, or a free port) count; limit /
    -- budget rows are recognized by NOT being in either map, no name parsing.
    local adj = {} ---@type table<string, table<string, true>>
    local nodes = {} ---@type table<string, true>
    local junction_outs = {} ---@type string[][]
    local rkeys = {}
    for key, p in pairs(problem.primals) do
        if p.kind == "recipe" or p.kind == "bridge" then rkeys[#rkeys + 1] = key end
    end
    table.sort(rkeys)
    for _, key in ipairs(rkeys) do
        local prods, cons = {}, {}
        for row, coefficient in pairs(problem.subject_terms[key] or {}) do
            if mat2base[row] or free[row] then
                if coefficient > 0 then
                    prods[#prods + 1] = row
                elseif coefficient < 0 then
                    cons[#cons + 1] = row
                end
            end
        end
        table.sort(prods)
        table.sort(cons)
        for _, row in ipairs(prods) do
            if not free[row] then nodes[row] = true end
        end
        for _, row in ipairs(cons) do
            if not free[row] then nodes[row] = true end
        end
        for _, a in ipairs(cons) do
            if not free[a] then
                local out = adj[a]
                if not out then
                    out = {}
                    adj[a] = out
                end
                for _, b in ipairs(prods) do
                    if not free[b] then out[b] = true end
                end
            end
        end
        if #prods >= 2 then
            -- A multi-output junction. Free co-products still make it a
            -- junction (a rigid ratio constrains the others), but only rows
            -- with a violation group are placement candidates.
            local outs, seen = {}, {}
            for _, row in ipairs(prods) do
                local base = mat2base[row]
                if base and not seen[base] then
                    seen[base] = true
                    outs[#outs + 1] = base
                end
            end
            if #outs >= 1 then
                table.sort(outs)
                junction_outs[#junction_outs + 1] = outs
            end
        end
    end

    -- Self-loop bases: subject terms hold NET coefficients, so a recipe that
    -- both consumes and produces one material (growth loops, perfect
    -- catalysts) loses its self-edge -- recover it from the raw lines.
    local selfloop = {} ---@type table<string, true>
    for _, line in ipairs(lines) do
        if not line.is_bridge then
            local pb = {}
            for _, value in ipairs(line.products or {}) do pb[value_base(value)] = true end
            for _, value in ipairs(line.ingredients or {}) do
                local base = value_base(value)
                if pb[base] then selfloop[base] = true end
            end
        end
    end

    -- Iterative Tarjan over the free-excluded digraph (the research probes'
    -- shape, sorted roots for determinism).
    local sorted_nodes = {}
    for row in pairs(nodes) do sorted_nodes[#sorted_nodes + 1] = row end
    table.sort(sorted_nodes)
    local index, low, stack, on_stack = {}, {}, {}, {}
    local sccid, sccsize = {}, {}
    local order, nscc = 0, 0
    for _, s in ipairs(sorted_nodes) do
        if not index[s] then
            local work = { { s, false } }
            while #work > 0 do
                local top = work[#work]
                local v, started = top[1], top[2]
                if not started then
                    order = order + 1
                    index[v] = order
                    low[v] = order
                    stack[#stack + 1] = v
                    on_stack[v] = true
                    top[2] = true
                end
                local pushed = false
                if adj[v] then
                    for w in pairs(adj[v]) do
                        if not index[w] then
                            work[#work + 1] = { w, false }
                            pushed = true
                            break
                        elseif on_stack[w] and index[w] < low[v] then
                            low[v] = index[w]
                        end
                    end
                end
                if not pushed then
                    if adj[v] then
                        for w in pairs(adj[v]) do
                            if on_stack[w] and low[w] < low[v] then low[v] = low[w] end
                        end
                    end
                    if low[v] == index[v] then
                        nscc = nscc + 1
                        while true do
                            local u = stack[#stack]
                            stack[#stack] = nil
                            on_stack[u] = nil
                            sccid[u] = nscc
                            sccsize[nscc] = (sccsize[nscc] or 0) + 1
                            if u == v then break end
                        end
                    end
                    work[#work] = nil
                end
            end
        end
    end

    -- SCC units at group grain: size>=2 SCC members, plus the self-edge /
    -- self-loop bases as singleton units.
    local unit_sets = {} ---@type table<string|integer, table<string, true>>
    for _, row in ipairs(sorted_nodes) do
        local base = mat2base[row]
        if base then
            local id = sccid[row]
            if id and sccsize[id] >= 2 then
                local set = unit_sets[id]
                if not set then
                    set = {}
                    unit_sets[id] = set
                end
                set[base] = true
            end
            if (adj[row] and adj[row][row]) or selfloop[base] then
                unit_sets["self|" .. base] = { [base] = true }
            end
        end
    end
    local units = {} ---@type string[][]
    do
        local ukeys = {}
        for uid in pairs(unit_sets) do ukeys[#ukeys + 1] = tostring(uid) end
        table.sort(ukeys)
        local by_string = {}
        for uid, set in pairs(unit_sets) do by_string[tostring(uid)] = set end
        for _, uid in ipairs(ukeys) do
            local members = {}
            for base in pairs(by_string[uid]) do members[#members + 1] = base end
            table.sort(members)
            units[#units + 1] = members
        end
    end

    -- Representatives: the largest base-solve flow, key ascending tie-break.
    local function rep_of(members)
        local best, best_phys = nil, -1
        for _, base in ipairs(members) do
            local phys = gp[base] or 0
            if phys > best_phys or (phys == best_phys and (best == nil or base < best)) then
                best, best_phys = base, phys
            end
        end
        return best
    end
    local placed = {} ---@type table<string, true>
    for _, members in ipairs(units) do
        local rep = rep_of(members)
        if rep then placed[rep] = true end
    end
    for _, outs in ipairs(junction_outs) do
        local rep = rep_of(outs)
        if rep then placed[rep] = true end
    end
    return placed, units, junction_outs
end

--------------------------------------------------------------------------------
-- Guard widening
--------------------------------------------------------------------------------

---Place the next `k` groups by base-solve physical flow (descending, key
---ascending tie-break), skipping dust and already-placed groups.
---@param gp table<string, number> Per-group physical flow of the base solve.
---@param placed table<string, true> Mutated: the widened placement.
---@param k integer
---@return integer added
function M.widen_rank(gp, placed, k)
    local ranked = {}
    for base, phys in pairs(gp) do
        if phys > ACTIVE_EPS and not placed[base] then ranked[#ranked + 1] = { base = base, phys = phys } end
    end
    table.sort(ranked, function(a, b)
        if a.phys ~= b.phys then return a.phys > b.phys end
        return a.base < b.base
    end)
    local added = 0
    for _, r in ipairs(ranked) do
        if added >= k then break end
        placed[r.base] = true
        added = added + 1
    end
    return added
end

---Structural widening ("smart"): find the groups whose physical flow inflated
---the most against the base solve (the amplification carriers) and place every
---SCC-unit / junction partner they have. The corpus failure dissection
---(probe_law_dissect.lua) showed the missing channel is a low-flow sibling of
---an inflated carrier -- rank-based widening structurally never reaches it.
---@param units string[][] From M.law_placement.
---@param junctions string[][] From M.law_placement.
---@param base_gp table<string, number> Base-solve per-group flow.
---@param restricted_gp table<string, number> Restricted-solve per-group flow.
---@param placed table<string, true> Mutated: the widened placement.
---@return integer added
function M.widen_structural(units, junctions, base_gp, restricted_gp, placed)
    local carriers = {}
    for base, phys in pairs(restricted_gp) do
        local delta = phys - (base_gp[base] or 0)
        if delta > ACTIVE_EPS then carriers[#carriers + 1] = { base = base, delta = delta } end
    end
    table.sort(carriers, function(a, b)
        if a.delta ~= b.delta then return a.delta > b.delta end
        return a.base < b.base
    end)
    local added = 0
    local function place_partners(lists, carrier)
        for _, members in ipairs(lists) do
            local has = false
            for _, base in ipairs(members) do
                if base == carrier then
                    has = true
                    break
                end
            end
            if has then
                for _, base in ipairs(members) do
                    if not placed[base] then
                        placed[base] = true
                        added = added + 1
                    end
                end
            end
        end
    end
    for i = 1, math.min(3, #carriers) do
        place_partners(units, carriers[i].base)
        place_partners(junctions, carriers[i].base)
    end
    return added
end

---Place every member of every SCC unit -- the "smart" response to a
---restricted solve that failed to converge (no solution to read carriers
---from; the law's safe upper bound is all of them).
---@param units string[][] From M.law_placement.
---@param placed table<string, true> Mutated: the widened placement.
---@return integer added
function M.widen_all_units(units, placed)
    local added = 0
    for _, members in ipairs(units) do
        for _, base in ipairs(members) do
            if not placed[base] then
                placed[base] = true
                added = added + 1
            end
        end
    end
    return added
end

return M
