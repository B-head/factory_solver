---@diagnostic disable: undefined-global
-- Reusable observe-price fixed-point loop (Phase A extraction).
--
-- This factors the synchronous loop validated in probe_observe_converge.lua into
-- a callable so BOTH the suite-verification driver (verify_observe_suite.lua) and
-- the corpus probe can share one implementation, and so the eventual production
-- module (solver/observe_price.lua) has a single tested reference to port from.
-- It is RESEARCH code: it runs every solve synchronously (the production version
-- spreads the same passes across the incremental solver's ticks), and it lives
-- under tests/research so it may still require research_lib / explore_detect.
--
-- The validated configuration is all three escape-hatch heuristics OFF
-- (deficit_seeding / catalyst_closure / reachability_gating) -- the exact OPTS
-- the probe measured. observe-price replaces them: it is the sole import-vs-
-- fabricate decision mechanism, pricing each avoidable-cheat shortage so the
-- self-sustaining cycle the user placed runs (fabricate) instead of penalty-
-- importing, and FREEZING (leaving on flat import) the cone-over-promise /
-- unavoidable ones.
--
-- M.run(constraints, lines) -> readout table (see COLS / the return at the end).

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local mc = require "solver/material_cycles"
local R = require "tests/research/research_lib"
local ed = require "tests/explore_detect"
local tn = require "manage/typed_name"

local M = {}

M.ELASTIC_COST = 2 ^ 10
M.TARGET_COST = 2 ^ 20
M.K_PRED = 1.5
M.MAX_ROUNDS = 10
-- The validated production configuration: every shipped escape-hatch heuristic
-- off, so observe-price is the only thing deciding import vs fabricate.
M.ALL_OFF = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }

local TOL, ITER = 1e-7, 800

local TRACE = os.getenv("FS_TRACE") ~= nil
local function trace(s) if TRACE then io.stderr:write(s) end end
local function kid(key) return (key:gsub(".*|", ""):gsub("([^/]+)/([^/]+)/[^/]*$", "%1/%2")) end

-- Build a problem (under `opts_base`, default ALL_OFF) and apply per-key shortage
-- cost multipliers (key -> mult); keys absent from `mults` keep the flat baseline
-- elastic_cost. Mutating the primal cost directly mirrors the probe exactly (the
-- production module will instead route through create_problem's
-- shortage_cost_overrides option). `opts_base` lets a caller compare the validated
-- all-off configuration against layering observe-price ON TOP of the shipped
-- heuristics (opts_base = {} = all defaults ON). Returns problem, state, x (nil if
-- not finished), and the IPM iteration count.
function M.build_solve(constraints, lines, mults, opts_base)
    local ok, p = pcall(create_problem.create_problem, "observe", constraints, lines, nil, opts_base or M.ALL_OFF)
    if not ok then return nil, "build-error", nil, 0 end
    if mults then
        for key, m in pairs(mults) do
            if p.primals[key] then p.primals[key].cost = M.ELASTIC_COST * m end
        end
    end
    local state, vars, steps = harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER })
    if state ~= "finished" then return p, state, nil, steps end
    return p, state, vars.x, steps
end

-- Sum |x| over every surplus_sink (over-production / dump) primal.
local function surplus_mass(problem, x)
    local s = 0
    for key, p in pairs(problem.primals) do
        if p.kind == "surplus_sink" then s = s + math.abs(x[key] or 0) end
    end
    return s
end

-- Make a key record for one active shortage variable.
local function make_key(key, qty, g)
    local ceiling = math.max(2, M.TARGET_COST / (M.ELASTIC_COST * qty))
    return { key = key, qty = qty, ceiling = ceiling, group = g,
        mult = 1, frozen = false, resolved_round = -1 }
end

-- Gather avoidable-cheat shortage keys, grouped (the observe step raises one
-- group at a time and reads the global escape delta, so a group must be the
-- materials whose dEsc should be measured together). Sorted iteration over
-- primals keeps the plan deterministic.
--
-- mode "strict" (the probe-validated qualification): only self-sustaining, idle,
--   export-feasible cyclic SCCs -- the corpus catalyst-loop subset.
-- mode "broad" (the gating-replacement candidate): EVERY active shortage whose
--   material is export_feasible (the chain can net-produce it). This is meant to
--   subsume reachability_gating via cost: a reachable intermediate the LP would
--   rather fabricate gets its shortage repriced so the chain runs instead.
--   Non-export-feasible materials (mass-losing / dead-end) are left out -- those
--   are deficit_seeding / catalyst_closure's structural job, not a cost lever.
--   Grouping: materials sharing a cyclic SCC observe together; the rest are
--   singletons.
local function collect(problem, x0, lines, th, mode)
    local adj = mc.build_material_graph(lines)
    local sccs = mc.find_sccs(adj)

    local prim_keys = {}
    for k in pairs(problem.primals) do prim_keys[#prim_keys + 1] = k end
    table.sort(prim_keys)

    local ef_cache = {}
    local function export_feasible(m)
        if ef_cache[m] == nil then ef_cache[m] = mc.export_feasible(lines, m) end
        return ef_cache[m]
    end

    if mode == "broad" then
        -- This is the cost form of reachability_gating. Gating denies the cheap
        -- shortage hatch to reachable, non-deficit materials so their chain must
        -- run; the cost equivalent raises that shortage instead. The qualifier is
        -- therefore "reachable (from raw + the deficit seeds, matching what
        -- create_problem reaches with) AND not itself a deficit". Excluding
        -- deficits is load-bearing: a mass-losing material (ash) is reachable too,
        -- but it cannot be net-fabricated, so repricing its shortage just drags in
        -- secondary shortage (measured: ash 0.1 -> 2). Deficits stay on their cheap
        -- |initial_source| import (deficit_seeding's job). export_feasible is kept
        -- as an OR so a self-sustaining cycle that closes without reaching raw
        -- (the corpus catalyst loops) still qualifies.
        local deficits = mc.find_deficit_materials(lines)
        local reachable = create_problem.compute_reachable_materials(lines, deficits)
        local function fab_supplyable(m)
            if deficits[m] then return false end
            return reachable[m] == true or export_feasible(m)
        end

        -- material -> stable group id (cyclic SCC share an id; others singleton).
        local scc_group = {}
        for si, scc in ipairs(sccs) do
            if mc.is_cyclic_scc(scc, adj) then
                local id = "scc:" .. si
                for _, m in ipairs(scc) do scc_group[m] = id end
            end
        end
        local function active_fab(key)
            local p = problem.primals[key]
            return p.kind == "shortage_source" and p.material
                and (x0[key] or 0) > th and (x0[key] or 0) > 1e-12
                and fab_supplyable(p.material)
        end
        local by_group, order = {}, {}
        for _, key in ipairs(prim_keys) do
            if active_fab(key) then
                local gid = scc_group[problem.primals[key].material] or ("single:" .. problem.primals[key].material)
                if not by_group[gid] then by_group[gid] = { sh = {} }; order[#order + 1] = gid end
            end
        end
        local groups, keys, excl_all = {}, {}, {}
        for _, key in ipairs(prim_keys) do
            if active_fab(key) then
                local gid = scc_group[problem.primals[key].material] or ("single:" .. problem.primals[key].material)
                local g = by_group[gid]
                local k = make_key(key, x0[key], g)
                keys[#keys + 1] = k
                g.sh[#g.sh + 1] = k
                excl_all[key] = true
            end
        end
        for _, gid in ipairs(order) do groups[#groups + 1] = by_group[gid] end
        return groups, keys, excl_all, #groups
    end

    -- strict (default): probe-validated self-sustaining/idle/cyclic qualification.
    local groups, keys, excl_all, n_scc = {}, {}, {}, 0
    for _, scc in ipairs(sccs) do
        if mc.is_cyclic_scc(scc, adj) then
            local scc_set = {}
            for _, m in ipairs(scc) do scc_set[m] = true end
            local active_sh, active_mats = {}, {}
            for _, key in ipairs(prim_keys) do
                local p = problem.primals[key]
                if p.kind == "shortage_source" and p.material and scc_set[p.material] and (x0[key] or 0) > th then
                    active_sh[#active_sh + 1] = key
                    active_mats[#active_mats + 1] = p.material
                end
            end
            if #active_sh >= 1 then
                local iset = R.internal_recipes(lines, scc_set)
                local self_sust = mc.is_self_sustaining(lines, scc)
                local fab = true
                for _, mm in ipairs(active_mats) do
                    if not export_feasible(mm) then fab = false; break end
                end
                if self_sust and fab and R.internal_flow(x0, iset) < 1e-6 then
                    n_scc = n_scc + 1
                    local g = { sh = {} }
                    for _, key in ipairs(active_sh) do
                        local qty = x0[key] or 0
                        if qty > 1e-12 then
                            local k = make_key(key, qty, g)
                            keys[#keys + 1] = k
                            g.sh[#g.sh + 1] = k
                            excl_all[key] = true
                        end
                    end
                    if #g.sh > 0 then groups[#groups + 1] = g end
                end
            end
        end
    end
    return groups, keys, excl_all, n_scc
end

-- Run the full observe-price fixed point synchronously on (constraints, lines).
-- Returns a readout table. `qualified=false` means no avoidable-cheat SCC was
-- found (the baseline solution is already the answer); the baseline/final
-- invariant fields are still filled so the caller can classify it.
---@param constraints Constraint[]
---@param lines NormalizedProductionLine[]
---@param opts_base CreateProblemOptions?  create_problem base options (default ALL_OFF). Pass {} to layer observe-price on the shipped heuristics.
---@param mode string?  qualification mode: "strict" (default, probe-validated) or "broad" (gating replacement: every export-feasible active shortage).
---@return table
function M.run(constraints, lines, opts_base, mode)
    local function bs(mults) return M.build_solve(constraints, lines, mults, opts_base) end
    -- Baseline (flat 1024 everywhere).
    local prob, state, x0, base_iters = bs(nil)
    if state ~= "finished" or not x0 then
        return { state = state, qualified = false, ok = false }
    end
    local th = ed.park_threshold({ x = x0 }, prob.primals)
    local relax0 = R.target_relax(prob, x0)
    local d0 = ed.detect({ x = x0 }, prob.primals)
    local surp0 = surplus_mass(prob, x0)

    local groups, keys, excl_all, n_scc = collect(prob, x0, lines, th, mode)

    -- Common readout skeleton, filled with the baseline solve when nothing
    -- qualifies (final == baseline) and overwritten below when it does.
    local out = {
        state = "finished", ok = true, qualified = (#keys > 0),
        n_scc = n_scc, n_keys = #keys,
        base_cheat = d0.cheat, base_active = d0.active, base_relax = relax0, base_surplus = surp0,
        final_cheat = d0.cheat, final_active = d0.active, final_relax = relax0, final_surplus = surp0,
        n_oneshot = 0, n_after_corr = 0, n_unresolved = 0,
        total_solves = 1, base_iters = base_iters, total_iters = base_iters,
        collapse = false, over_dump_ratio = 1, avoidable_remaining = 0,
    }
    if #keys == 0 then return out end

    local esc_before = R.other_escape_sum(prob, x0, excl_all)
    trace(("== %d SCC / %d keys ==\n"):format(n_scc, #keys))

    -- Phase 2: per-SCC observe.
    local observe_solves, observe_iters = 0, 0
    for gi, g in ipairs(groups) do
        local obs_mults = {}
        for _, k in ipairs(g.sh) do obs_mults[k.key] = k.ceiling end
        local pobs, sobs, xobs, obs_steps = bs(obs_mults)
        observe_solves = observe_solves + 1
        observe_iters = observe_iters + (obs_steps or 0)
        local cleared = xobs ~= nil
        local short_o, relax_o = 0, math.huge
        if xobs then
            for _, k in ipairs(g.sh) do short_o = short_o + (xobs[k.key] or 0) end
            relax_o = R.target_relax(pobs, xobs)
            cleared = short_o <= th and relax_o <= relax0 + 1e-4
        end
        if cleared then
            local desc = R.other_escape_sum(pobs, xobs, excl_all) - esc_before
            local qsum = 0
            for _, k in ipairs(g.sh) do qsum = qsum + k.qty end
            for _, k in ipairs(g.sh) do
                local share = desc * (k.qty / qsum)
                k.mult = math.max(2, math.min(k.ceiling, M.K_PRED * share / k.qty))
                trace(("  [observe scc%d] %-26s qty=%.4g ceil=%.4g dEsc=%.4g -> mult=%.4g\n")
                    :format(gi, kid(k.key), k.qty, k.ceiling, desc, k.mult))
            end
        else
            for _, k in ipairs(g.sh) do k.frozen = true end
            trace(("  [observe scc%d] cone-over-promise/unavoidable (short_o=%.4g relax_o=%.4g) -> FREEZE %d\n")
                :format(gi, short_o, relax_o, #g.sh))
        end
    end

    -- Phase 3+: verify + correct loop. Keep the LAST solve as the final answer.
    local rounds, verify_iters = 0, 0
    local final_prob, final_x = prob, x0
    while rounds < M.MAX_ROUNDS do
        rounds = rounds + 1
        local mults = {}
        for _, k in ipairs(keys) do mults[k.key] = k.frozen and 1 or k.mult end
        local pr, sr, xr, ver_steps = bs(mults)
        verify_iters = verify_iters + (ver_steps or 0)
        if not xr then break end
        final_prob, final_x = pr, xr

        local live_straggler = false
        for _, k in ipairs(keys) do
            if not k.frozen then
                local v = xr[k.key] or 0
                if v <= th then
                    if k.resolved_round < 0 then k.resolved_round = rounds end
                else
                    k.resolved_round = -1
                    if k.mult >= k.ceiling * (1 - 1e-9) then
                        k.frozen = true
                    else
                        k.mult = math.min(k.ceiling, k.mult * 2)
                        live_straggler = true
                    end
                end
            end
        end
        if not live_straggler then break end
    end

    local n_oneshot, n_after, n_unres = 0, 0, 0
    for _, k in ipairs(keys) do
        if k.frozen or k.resolved_round < 0 then
            n_unres = n_unres + 1
        elseif k.resolved_round == 1 then
            n_oneshot = n_oneshot + 1
        else
            n_after = n_after + 1
        end
    end

    -- Final invariants from the last accepted solve.
    local df = ed.detect({ x = final_x }, final_prob.primals)
    local relax_f = R.target_relax(final_prob, final_x)
    local surp_f = surplus_mass(final_prob, final_x)
    -- Avoidable still importing after the loop, that we did NOT deliberately
    -- freeze (a genuine miss vs an accepted cone-over-promise import).
    local avoidable_remaining = 0
    for _, k in ipairs(keys) do
        if not k.frozen and (final_x[k.key] or 0) > th then avoidable_remaining = avoidable_remaining + 1 end
    end

    out.final_cheat = df.cheat
    out.final_active = df.active
    out.final_relax = relax_f
    out.final_surplus = surp_f
    out.n_oneshot, out.n_after_corr, out.n_unresolved = n_oneshot, n_after, n_unres
    out.observe_solves = observe_solves
    out.rounds = rounds
    out.total_solves = 1 + observe_solves + rounds
    out.observe_iters, out.verify_iters = observe_iters, verify_iters
    out.total_iters = base_iters + observe_iters + verify_iters
    out.collapse = relax_f > relax0 + 1e-4
    out.over_dump_ratio = (surp0 > 1e-9) and (surp_f / surp0) or (surp_f > 1e-6 and math.huge or 1)
    out.avoidable_remaining = avoidable_remaining
    return out
end

return M
