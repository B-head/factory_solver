-- L2 mode compression: fold sibling violation channels down to one per group.
--
-- The L2 (QP) norm spreads a material imbalance evenly across every equivalent
-- escape channel -- most visibly across the temperature-window variants of one
-- fluid, which all import (or dump) a slice of the same physical shortage. The
-- spread is an artifact of the quadratic cost (equal marginal prices), not a
-- statement about the factory, and it multiplies the import/dump rows the user
-- has to read. This module picks, for every group of ACTIVE sibling channels --
-- same base material (temperature window folded away) AND same kind (imports
-- never fold into dumps; the opposite-kind fold was measured as the dominant
-- destruction source) -- the channel carrying the largest physical flow, and
-- returns the rest as exclusion sets for a create_problem rebuild
-- (hatch_exclude / sink_exclude). Re-solving without the losers folds their
-- flow onto the winner; the LP re-balances everything else.
--
-- Measured on the 1678-dump explorer corpus (probe_mode_compress_cheap.lua,
-- variant "bx2", 2026-07-07): folds an average ~6.5 active channels per
-- affected problem, leaves the target and the violation tiers unchanged on
-- ~96% of problems, and the deletion solve converged on every corpus problem.
-- No per-channel perturbation solves and no union solve are needed -- grouping
-- by (base, kind) metadata and picking the max-flow winner matches the
-- clustered pipeline's quality at a fraction of its cost (~3 solves total vs
-- ~47). The quality verdict is NOT judged in-code (no verify gate is shipped:
-- its thresholds are unvalidated); the caller only restores the baseline when
-- the compress solve fails to converge.
--
-- Pure functions over Problem metadata (Primal.kind / .material /
-- .material_base) -- no key-string parsing (see CLAUDE.md), no Factorio
-- runtime, so the headless suite drives it directly.
local M = {}

-- A channel is "active" when its physical flow (|coefficient * x|, in material
-- units) exceeds this. Same dust floor as the corpus probes: below it the
-- channel is numerical dust the fold would neither help nor hurt.
local ACTIVE_EPS = 1e-6

---@class ModeCompressPlan
---@field hatch table<string, true>? Materials whose |shortage_source| import hatch the compressed build omits (import-side group losers), for CreateProblemOptions.hatch_exclude.
---@field sink table<string, true>? Materials whose |surplus_sink| dump escape the compressed build omits (dump-side group losers), for CreateProblemOptions.sink_exclude.
---@field excluded integer How many channels the plan folds away (diagnostics).

---Plan the compression for a finished solve: group the active violation
---channels by (kind, base material) and mark every group's non-winners for
---exclusion. Returns nil when nothing folds (no multi-member group), so the
---caller can skip the re-solve entirely.
---
---Deterministic (multiplayer lockstep): the exclusion sets are order-free, and
---the per-group winner is picked under a total order (physical flow descending,
---variable key ascending as the tie-break), so `pairs` iteration order never
---leaks into the result.
---@param problem Problem The finished baseline build.
---@param x table<string, number> The converged primal values (PackedVariables.x).
---@return ModeCompressPlan?
function M.plan(problem, x)
    ---@type table<string, {key: string, material: string, kind: PrimalKind, phys: number}[]>
    local groups = {}
    for key, p in pairs(problem.primals) do
        if (p.kind == "shortage_source" or p.kind == "surplus_sink") and p.material then
            local terms = problem.subject_terms[key]
            local coefficient = (terms and terms[p.material]) or 1
            local phys = math.abs(coefficient * (x[key] or 0))
            if phys > ACTIVE_EPS then
                local group_key = p.kind .. "|" .. (p.material_base or p.material)
                local group = groups[group_key]
                if not group then
                    group = {}
                    groups[group_key] = group
                end
                group[#group + 1] = { key = key, material = p.material, kind = p.kind, phys = phys }
            end
        end
    end

    local hatch, sink = nil, nil
    local excluded = 0
    for _, group in pairs(groups) do
        if #group >= 2 then
            table.sort(group, function(a, b)
                if a.phys ~= b.phys then return a.phys > b.phys end
                return a.key < b.key
            end)
            for i = 2, #group do
                local loser = group[i]
                if loser.kind == "shortage_source" then
                    hatch = hatch or {}
                    hatch[loser.material] = true
                else
                    sink = sink or {}
                    sink[loser.material] = true
                end
                excluded = excluded + 1
            end
        end
    end

    if excluded == 0 then return nil end
    return { hatch = hatch, sink = sink, excluded = excluded }
end

return M
