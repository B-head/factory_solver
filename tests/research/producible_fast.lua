---@diagnostic disable: undefined-global
-- Fast producibility classification: the reference's greatest-fixpoint
-- (M is producible iff the lines net-produce M without importing M itself) but
-- with phase 1 (the O(#mats) individual screen) replaced by RECURSIVE all-batch.
--
-- One joint solve prices+demands a whole batch; a member whose own shortage stays
-- at dust passes the STRICTEST test, so it is producible (monotone -- it would pass
-- the easier individual test too). Re-batch the failers (less contention -> more
-- pass) until a round makes no progress, then individual-test the irreducible
-- tight-cycle core. Verdict-identical to per-material phase 1 (proven over the full
-- explorer corpus: 0 mismatch / 1678 files), at ~4.8 solves mean vs ~30.7.
--
-- Phases 2 (demote coupled ties) and 3 (promote) are the reference's, unchanged --
-- they operate on the phase-1 member set. Returns (producible_set, n_solves).

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"

local M = {}
local EPS_RECIPE = 2 ^ -20
local TOL = 1e-4
local OPTS = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }

---@param constraints table
---@param lines NormalizedProductionLine[]
---@param priced_kind string "shortage_source" (producible) / "surplus_sink" (consumable)
---@param demand_sign number -1 (demand net production) / +1 (inject to absorb)
---@return table<string, true> members, integer n_solves
function M.classify(constraints, lines, priced_kind, demand_sign)
    local base = create_problem.create_problem("pf", constraints, lines, nil, OPTS)
    local mats = {}
    for _, p in pairs(base.primals) do
        if p.kind == priced_kind and p.material then mats[#mats + 1] = p.material end
    end
    table.sort(mats)

    local n_solves = 0
    local function joint_residuals(priced_set, demand_list)
        local p = create_problem.create_problem("pf", constraints, lines, nil, OPTS)
        for _, pr in pairs(p.primals) do
            if pr.kind == priced_kind and priced_set[pr.material] then pr.cost = 1
            elseif pr.kind == "recipe" or pr.kind == "bridge" then pr.cost = EPS_RECIPE
            else pr.cost = 0 end
        end
        for _, mat in ipairs(demand_list) do
            local probe = "|pf_probe|" .. mat
            p:add_objective(probe, 0, false, nil, mat)
            p:add_subject_term(probe, mat, demand_sign)
            local dual = "|pf_demand|" .. mat
            p:add_lower_limit_constraint(dual, 1)
            p:add_subject_term(probe, dual, 1)
        end
        local s, v = harness.solve_to_completion(lp, p, { tolerance = 1e-7, iterate_limit = 800 })
        n_solves = n_solves + 1
        if s ~= "finished" or not v then return nil end
        local own = {}
        for key, pr in pairs(p.primals) do
            if pr.kind == priced_kind and priced_set[pr.material] then
                own[pr.material] = (own[pr.material] or 0) + math.abs(v.x[key] or 0)
            end
        end
        return own
    end
    local function member_list(set)
        local l = {} for _, m in ipairs(mats) do if set[m] then l[#l + 1] = m end end return l
    end
    local function indiv(mat)
        local own = joint_residuals({ [mat] = true }, { mat })
        return own and (own[mat] or 0) <= TOL
    end

    -- Phase 1: recursive all-batch.
    local members = {}
    do
        local pending = {}
        for _, m in ipairs(mats) do pending[#pending + 1] = m end
        while #pending > 0 do
            if #pending == 1 then
                if indiv(pending[1]) then members[pending[1]] = true end
                break
            end
            local set = {}; for _, m in ipairs(pending) do set[m] = true end
            local own = joint_residuals(set, pending)
            if not own then
                -- a non-finished batch carries no certificate: fall back to individual
                for _, m in ipairs(pending) do if indiv(m) then members[m] = true end end
                break
            end
            local nextp = {}
            for _, m in ipairs(pending) do
                if (own[m] or 0) <= TOL then members[m] = true else nextp[#nextp + 1] = m end
            end
            if #nextp == #pending then
                for _, m in ipairs(nextp) do if indiv(m) then members[m] = true end end
                break
            end
            pending = nextp
        end
    end

    -- Phase 2: joint demote-one over the coupled ties.
    local tie_demoted = {}
    for _ = 1, #mats + 1 do
        local own = joint_residuals(members, member_list(members))
        if not own then break end
        local worst, wamt = nil, TOL
        for _, mat in ipairs(mats) do
            local amt = own[mat] or 0
            if members[mat] and amt > wamt then worst, wamt = mat, amt end
        end
        if not worst then break end
        members[worst] = nil
        tie_demoted[#tie_demoted + 1] = worst
    end

    -- Phase 3: promotion sweeps over the phase-2 demotions.
    for _ = 1, #tie_demoted do
        local promoted = false
        for _, mat in ipairs(tie_demoted) do
            if not members[mat] then
                local trial = { [mat] = true }
                for m in pairs(members) do trial[m] = true end
                local own = joint_residuals(trial, member_list(trial))
                if own then
                    local clean = true
                    for m in pairs(trial) do if (own[m] or 0) > TOL then clean = false; break end end
                    if clean then members[mat] = true; promoted = true end
                end
            end
        end
        if not promoted then break end
    end

    return members, n_solves
end

---@return table<string, true> producible, integer n_solves
function M.producible_set(constraints, lines)
    return M.classify(constraints, lines, "shortage_source", -1)
end

return M
