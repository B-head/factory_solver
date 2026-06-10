local problem_generator = require "solver/problem_generator"

-- Escape-variable row reduction (column-singleton substitution presolve).
--
-- create_problem attaches an "escape" variable to most material balance rows:
-- |final_sink| on a terminal product, |initial_source| on a raw input,
-- |shortage_source| on an unreachable cycle material. On a material touched by a
-- single recipe these rows are pure two-term equalities
--   a_recipe * x_recipe  (+/-)  1 * x_escape = 0
-- where the escape variable appears in NO other row (a column singleton) and is
-- therefore uniquely pinned to the recipe flow: x_escape = k * x_recipe, k > 0.
-- Such a variable carries no decision -- it just records the flow leaving or
-- entering the factory -- so it can be substituted out: drop the row and the
-- column, fold the escape's per-unit cost onto the recipe (c_recipe += k *
-- c_escape), and reconstruct x_escape after the solve. Because the escape column
-- is a singleton, the substitution never rewrites any other row, so it is a pure
-- deletion: the remaining LP is byte-for-byte the same problem minus a pinned
-- variable, and the IPM solves a strictly smaller system (Cholesky on A·D²·Aᵀ is
-- O(m³) in the row count m).
--
-- On the explorer corpus (cycle-heavy pyanodon chains) escape variables sit on
-- ~73% of all rows, so this folds roughly half of them and the corpus solves
-- ~5x faster. The objective is preserved exactly (cost is conserved); on
-- degenerate problems the IPM may still land on a different point of the optimal
-- *face* (it returns the analytic center, which depends on the formulation), but
-- never a different objective.
--
-- Why only escape singletons, not recipe<->recipe chain doubletons: folding a
-- variable that appears in other rows substitutes into them, changing their
-- coefficients -- which both shifts the IPM center far more on degenerate
-- problems and, empirically, pushed one corpus problem into a singular
-- factorisation. Escape-singleton folds touch nothing else and never regressed
-- convergence.
--
-- |surplus_sink| is deliberately NOT folded: its sign makes the row
--   producer - consumer - surplus = 0,  surplus >= 0
-- an inequality (production may exceed consumption), so the variable is a real
-- slack with a load-bearing bound, not a pinned accumulator.
--
-- Determinism (Factorio multiplayer is deterministic lockstep): rows are scanned
-- in sorted key order and the reduced problem is built in sorted key order, so
-- two reduce() calls on the same Problem produce bit-identical output. No
-- wall-clock / RNG source is touched.

local M = {}

---@param kind PrimalKind?
---@return boolean
local function is_recipe(kind)
    return kind == "recipe" or kind == "bridge"
end

-- Escape classes that are uniquely pinned to a single recipe flow and safe to
-- substitute out. |surplus_sink| is excluded on purpose (see file header).
local ESCAPE_KIND = {
    final_sink = true,
    initial_source = true,
    shortage_source = true,
}

---Reduce a Problem by substituting out column-singleton escape variables.
---
---Returns a fresh reduced Problem (a normal problem_generator instance the IPM
---solves unchanged) plus a reconstruction map for M.unfold. The input `full`
---problem is not mutated.
---@param full Problem
---@return Problem reduced
---@return Reconstruction reconstruction
function M.reduce(full)
    -- Working copy of the constraint matrix in two synchronised directions, both
    -- filtered the way generate_subject_matrix filters (a term counts only when
    -- both its primal and dual are registered, dropping explicit zeros):
    --   row[d][p]    = coefficient of primal p in dual row d
    --   prim_rows[p] = set of dual rows primal p appears in
    -- The prim_rows count is what tells a column singleton from a multi-row
    -- escape (e.g. an |initial_source| that also feeds a registered |limit| row
    -- on a user-constrained material -- that one is NOT folded).
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

    local cost = {}
    for p, info in pairs(full.primals) do
        cost[p] = info.cost
    end

    local eliminated = {} ---@type table<string, { rep: string, k: number }>
    local order = {} ---@type string[]
    local dead_dual = {} ---@type table<string, true>

    -- A single sorted pass suffices: a pure-deletion fold never rewrites another
    -- row, so it cannot turn a different row into a new foldable doubleton (no
    -- fixpoint needed, unlike a substitution that touches other rows).
    local dkeys = {}
    for d in pairs(full.duals) do dkeys[#dkeys + 1] = d end
    table.sort(dkeys)

    for _, d in ipairs(dkeys) do
        local terms = row[d]
        if full.duals[d].limit == 0 and terms then
            -- Collect the non-zero terms; only an exact two-term row folds.
            local plist = {}
            for p, coeff in pairs(terms) do
                if coeff ~= 0 then plist[#plist + 1] = p end
            end

            if #plist == 2 then
                local p1, p2 = plist[1], plist[2]
                local k1, k2 = full.primals[p1].kind, full.primals[p2].kind
                -- Identify the recipe/bridge "keep" and the escape to eliminate.
                local keep, esc
                if is_recipe(k1) and ESCAPE_KIND[k2] then
                    keep, esc = p1, p2
                elseif is_recipe(k2) and ESCAPE_KIND[k1] then
                    keep, esc = p2, p1
                end

                if esc then
                    -- The escape must appear in this row only (column singleton);
                    -- otherwise eliminating it would drop a constraint it also
                    -- participates in (e.g. a |limit| row).
                    local nrows = 0
                    for _ in pairs(prim_rows[esc]) do nrows = nrows + 1 end
                    if nrows == 1 then
                        local k = -terms[keep] / terms[esc]
                        -- k > 0 means x_esc = k * x_keep keeps x_esc >= 0 given
                        -- x_keep >= 0; the opposite sign that makes this hold is
                        -- exactly the producer/sink (final_sink) or consumer/
                        -- source (initial/shortage) pairing.
                        if k > 0 then
                            cost[keep] = cost[keep] + k * cost[esc]
                            prim_rows[esc] = nil
                            prim_rows[keep][d] = nil
                            row[d] = nil
                            dead_dual[d] = true
                            eliminated[esc] = { rep = keep, k = k }
                            order[#order + 1] = esc
                        end
                    end
                end
            end
        end
    end

    -- Build the reduced Problem in sorted key order so the index assignment (and
    -- therefore the generated matrix) is reproducible.
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

    local rdkeys = {}
    for d in pairs(full.duals) do
        if not dead_dual[d] then rdkeys[#rdkeys + 1] = d end
    end
    table.sort(rdkeys)
    for _, d in ipairs(rdkeys) do
        local terms = row[d]
        reduced:add_equivalence_constraint(d, full.duals[d].limit)
        if terms then
            for p, coeff in pairs(terms) do
                if coeff ~= 0 then
                    reduced:add_subject_term(p, d, coeff)
                end
            end
        end
    end

    return reduced, { eliminated = eliminated, order = order }
end

---Expand a reduced solution back into the full variable space.
---
---Fills in every eliminated escape variable's x via x_esc = k * x_rep (the
---reconstruction chain is flat -- escape singletons never point at another
---eliminated variable -- but resolve transitively with memoisation anyway, to be
---robust). Dual (y) and slack (s) values for eliminated columns are left absent:
---the consumers that read s (observe_price's idle certificate) only look at
---recipe columns, which are never eliminated; everything else reads x only
---(filter_result, diagnose, report), and the warm-start make_* helpers fall
---back to defaults for missing keys.
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
