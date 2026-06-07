local problem_generator = require "solver/problem_generator"

-- Proportional row reduction (singleton / doubleton variable substitution).
--
-- Factorio recipe networks contain long linear chains (A --r1--> B --r2--> C).
-- Whenever a material balance row is a pure two-term equality
--   a_rep * x_rep + a_elim * x_elim = 0
-- the eliminated variable is just a positive scalar multiple of the
-- representative (x_elim = k * x_rep, k > 0), so it can be substituted out of
-- the LP entirely. Each substitution removes one constraint row AND one
-- variable column; since the IPM's dominant cost is Cholesky(A·D²·Aᵀ) at
-- O(m³) in the row count m, folding chains directly shrinks the hot loop.
--
-- This is a pure presolve: the reduced LP has the identical optimum (costs are
-- transferred, c_rep' = c_rep + k * c_elim, so the objective is preserved), and
-- the eliminated variables are reconstructed exactly after the solve via
-- M.unfold. The full Problem is never mutated -- it stays the canonical
-- variable space that report / filter_result / diagnose read.
--
-- Safety (we only fold when the substitution provably keeps the solution
-- unchanged and feasible):
--   * the row's RHS limit must be 0 (no constant term leaks into other rows),
--   * the row must have exactly two non-zero terms,
--   * both variables must be recipe / bridge columns (escape variables --
--     source / sink / elastic / slack -- carry the cost tiers and must not be
--     folded),
--   * the two coefficients must have opposite signs, so k = -a_rep/a_elim > 0
--     and x_elim >= 0 follows from x_rep >= 0 automatically.
--
-- Determinism (Factorio multiplayer is deterministic lockstep): every scan is
-- over keys sorted by string, the representative is the lexicographically
-- smaller of the two variable keys, and no wall-clock / RNG source is touched.
-- Two reduce() calls on the same Problem produce bit-identical output.

local M = {}

---True for the variable classes that may be folded. Escape variables
---(source / sink / elastic / slack) attach to material rows with the BIG-M
---cost tiers, so folding them would smear those costs across recipes.
---@param kind PrimalKind?
---@return boolean
local function foldable_kind(kind)
    return kind == "recipe" or kind == "bridge"
end

---Reduce a Problem by substituting out proportional doubleton rows.
---
---Returns a fresh reduced Problem (a normal problem_generator instance, so the
---existing IPM solves it unchanged) plus a reconstruction map for M.unfold. The
---input `full` problem is not mutated.
---@param full Problem
---@return Problem reduced
---@return Reconstruction reconstruction
function M.reduce(full)
    -- Working copy of the constraint matrix in two synchronised directions:
    --   row[d][p]      = coefficient of primal p in dual row d
    --   prim_rows[p]   = set of dual rows that primal p appears in
    -- Mirrors generate_subject_matrix's filtering: a term counts only when both
    -- its primal and dual are registered, and explicit zeros are dropped.
    local row = {}
    local prim_rows = {}
    for p, terms in pairs(full.subject_terms) do
        if full.primals[p] then
            for d, coeff in pairs(terms) do
                if full.duals[d] and coeff ~= 0 then
                    local r = row[d]
                    if not r then r = {}; row[d] = r end
                    r[p] = coeff
                    local pr = prim_rows[p]
                    if not pr then pr = {}; prim_rows[p] = pr end
                    pr[d] = true
                end
            end
        end
    end

    -- Objective costs, mutated in place as costs are transferred onto the
    -- surviving representatives.
    local cost = {}
    for p, info in pairs(full.primals) do
        cost[p] = info.cost
    end

    local eliminated = {} ---@type table<string, { rep: string, k: number }>
    local order = {} ---@type string[]
    local dead_dual = {} ---@type table<string, true>

    -- Fixpoint: folding one row can turn another into a doubleton (the linear
    -- chain collapse), so re-scan until a full pass folds nothing. Each pass
    -- walks the live rows in sorted key order for determinism.
    local changed = true
    while changed do
        changed = false

        local dkeys = {}
        for d in pairs(full.duals) do
            if not dead_dual[d] then dkeys[#dkeys + 1] = d end
        end
        table.sort(dkeys)

        for _, d in ipairs(dkeys) do
            local terms = row[d]
            if not dead_dual[d] and full.duals[d].limit == 0 and terms then
                -- Collect the non-zero terms; we only fold an exact doubleton.
                local plist = {}
                for p, coeff in pairs(terms) do
                    if coeff ~= 0 then plist[#plist + 1] = p end
                end

                if #plist == 2 then
                    local p1, p2 = plist[1], plist[2]
                    if foldable_kind(full.primals[p1].kind)
                        and foldable_kind(full.primals[p2].kind) then
                        local a1, a2 = terms[p1], terms[p2]
                        -- Opposite signs => k > 0 and non-negativity is implied.
                        if a1 * a2 < 0 then
                            -- Representative = lexicographically smaller key.
                            local rep, elim, a_rep, a_elim
                            if p1 < p2 then
                                rep, elim, a_rep, a_elim = p1, p2, a1, a2
                            else
                                rep, elim, a_rep, a_elim = p2, p1, a2, a1
                            end
                            local k = -a_rep / a_elim

                            -- Transfer elim's coefficients in every OTHER row to
                            -- rep, scaled by k. (Row d itself is removed below.)
                            for d2 in pairs(prim_rows[elim]) do
                                if d2 ~= d then
                                    local c_elim = row[d2][elim]
                                    row[d2][elim] = nil
                                    local newc = (row[d2][rep] or 0) + k * c_elim
                                    if newc == 0 then
                                        -- Exact cancellation: rep drops out of d2.
                                        if row[d2][rep] ~= nil then
                                            row[d2][rep] = nil
                                            prim_rows[rep][d2] = nil
                                        end
                                    else
                                        if row[d2][rep] == nil then
                                            prim_rows[rep][d2] = true
                                        end
                                        row[d2][rep] = newc
                                    end
                                end
                            end

                            -- Transfer the objective cost onto rep.
                            cost[rep] = cost[rep] + k * cost[elim]

                            -- Retire elim and the doubleton row d.
                            prim_rows[elim] = nil
                            prim_rows[rep][d] = nil
                            row[d] = nil
                            dead_dual[d] = true

                            eliminated[elim] = { rep = rep, k = k }
                            order[#order + 1] = elim
                            changed = true
                        end
                    end
                end
            end
        end
    end

    -- Build the reduced Problem. Insert primals and duals in sorted key order so
    -- the index assignment (and therefore the generated matrix) is reproducible.
    local reduced = problem_generator.new(full.name)

    local pkeys = {}
    for p in pairs(full.primals) do
        if not eliminated[p] then pkeys[#pkeys + 1] = p end
    end
    table.sort(pkeys)
    for _, p in ipairs(pkeys) do
        local info = full.primals[p]
        reduced:add_objective(p, cost[p], info.is_result, info.kind, info.material)
    end

    local dkeys = {}
    for d in pairs(full.duals) do
        if not dead_dual[d] then dkeys[#dkeys + 1] = d end
    end
    table.sort(dkeys)
    for _, d in ipairs(dkeys) do
        local terms = row[d]
        local has_term = false
        if terms then
            for _, coeff in pairs(terms) do
                if coeff ~= 0 then has_term = true; break end
            end
        end
        -- Drop rows that collapsed to 0 = 0 (a redundant constraint that would
        -- otherwise add a zero row to A and make A·D²·Aᵀ singular). A row whose
        -- limit is non-zero is kept regardless: it is never an internal balance
        -- and losing it would change feasibility.
        if has_term or full.duals[d].limit ~= 0 then
            reduced:add_equivalence_constraint(d, full.duals[d].limit)
            if terms then
                for p, coeff in pairs(terms) do
                    if coeff ~= 0 then
                        reduced:add_subject_term(p, d, coeff)
                    end
                end
            end
        end
    end

    return reduced, { eliminated = eliminated, order = order }
end

---Expand a reduced solution back into the full variable space.
---
---The reduced solve returns x / y / s keyed only by surviving variables. This
---fills in every eliminated primal's x via x_elim = k * x_rep, resolving chains
---transitively (B -> A -> C) with memoisation. Dual (y) and slack (s) values
---for eliminated rows / columns are left absent: only x is read for
---correctness (filter_result, diagnose, report), and the warm-start make_*
---helpers fall back to defaults for missing keys.
---@param reduced_raw PackedVariables?
---@param reconstruction Reconstruction
---@return PackedVariables? #Full-space packed variables, or nil if the solve produced none.
function M.unfold(reduced_raw, reconstruction)
    if not reduced_raw then return nil end

    local elim_map = reconstruction.eliminated
    local x = {}
    for k, v in pairs(reduced_raw.x) do x[k] = v end
    local y = {}
    for k, v in pairs(reduced_raw.y) do y[k] = v end
    local s = {}
    for k, v in pairs(reduced_raw.s) do s[k] = v end

    local resolving = {}
    local function resolve(key)
        local info = elim_map[key]
        if not info then
            -- A surviving (root) variable: present in the reduced solution.
            return x[key] or 0
        end
        local cached = x[key]
        if cached ~= nil then return cached end
        assert(not resolving[key], "substitution.unfold: cyclic reconstruction")
        resolving[key] = true
        local v = info.k * resolve(info.rep)
        resolving[key] = nil
        x[key] = v
        return v
    end

    for key in pairs(elim_map) do
        resolve(key)
    end

    return { x = x, y = y, s = s }
end

return M
