---@diagnostic disable: undefined-global
-- Observe-price CONVERGENCE probe (research, no verdict).
--
-- probe_observe_price validated, per-SCC, that one observation predicts the flip
-- price (64/67 clean one-shot, 0 collapse). This probe answers the two follow-ups
-- at the PROBLEM (whole-factory) level:
--   (1) does a single correction round close the few one-shot misses?
--   (2) how many TOTAL solves does the full fixed point take per problem?
--
-- The algorithm, run once per dump over the union of all qualifying SCCs:
--   solve 1  BASELINE (flat 1024)            -> collect avoidable-cheat shortage keys
--                                               (self-sustaining & export_feasible &
--                                               idle), per-key qty, per-SCC footprint
--   solve 2  GLOBAL OBSERVE (all keys high)  -> one solve, every avoidable shortage at
--                                               the ceiling; read each SCC's dEsc
--                                               (footprint escape mass) -> set price
--                                               mult = clamp(k*dEsc/qty, 2, ceiling)
--   solve 3+ VERIFY + CORRECT (loop)         -> solve with current prices; any key
--                                               still importing is a straggler: re-read
--                                               its dEsc and bump (x2 or k*dEsc/qty);
--                                               a key already at its ceiling is frozen
--                                               back to import (unavoidable / cone-over-
--                                               promise). Stop when no live straggler.
--
-- total_solves = 2 + (verify/correct rounds). The per-key outcome is split into
-- resolved-at-first-verify (one-shot), resolved-after-correction, and unresolved
-- (frozen import), so the row shows BOTH the solve budget and whether correction
-- earns its keep. RAW numbers only.
--
-- Attribution caveat (honest): a per-SCC dEsc here is the escape mass of escapes
-- whose MATERIAL is in the SCC (byproduct dumps + in-SCC secondary deficits). A
-- secondary deficit OUTSIDE the SCC is missed, so the global-observe initial price
-- can read low vs probe_observe_price's per-SCC global read -- which is exactly
-- what the correction loop is there to absorb. The solve count is therefore an
-- HONEST upper bound for the cheaper-to-attribute per-SCC-observe variant.
--
-- Usage (from repo root):
--   <lua> tests/probe_observe_converge.lua --manifest <list> --out <file.tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"
local mc = require "solver/material_cycles"
local tn = require "manage/typed_name"

local TOL, ITER = 1e-7, 800
local OPTS = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
local ELASTIC_COST = 2 ^ 10
local TARGET_COST = 2 ^ 20
local K_PRED = 1.5
local MAX_ROUNDS = 10 -- backstop only; the per-SCC observe should land most in <=2 rounds

local TRACE = os.getenv("FS_TRACE") ~= nil
local function trace(s) if TRACE then io.stderr:write(s) end end

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("converge", c, l, nil, OPTS) end

-- Short readable id for a shortage key (last two '/'-segments), trace only.
local function kid(key) return (key:gsub(".*|", ""):gsub("([^/]+)/([^/]+)/[^/]*$", "%1/%2")) end

local function internal_recipes(lines, scc_set)
    local out = {}
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
            if hp then out[tn.typed_name_to_variable_name(line.recipe_typed_name)] = true end
        end
    end
    return out
end

local function internal_flow(x, internal_set)
    local s = 0
    for key in pairs(internal_set) do s = s + math.abs(x[key] or 0) end
    return s
end

local function target_relax(problem, x)
    local s = 0
    for key, p in pairs(problem.primals) do
        if p.kind == "elastic" then s = s + math.abs(x[key] or 0) end
    end
    return s
end

-- Total escape mass (surplus_sink + shortage_source), EXCLUDING the avoidable
-- keys (`exclude`). Read GLOBALLY, not restricted to one SCC: a fabrication's
-- byproduct dumps and secondary deficits often land OUTSIDE its SCC, so a
-- footprint-restricted read misses them (it read 0 for navens/bio-scafold and
-- starved the prediction). When only ONE SCC is raised, the delta of this global
-- read vs baseline cancels every unrelated escape and equals that SCC's dEsc --
-- exactly the accurate measurement probe_observe_price used for its 95.5% one-shot.
local function other_escape(problem, x, exclude)
    local s = 0
    for key, p in pairs(problem.primals) do
        if (p.kind == "surplus_sink" or p.kind == "shortage_source") and not exclude[key] then
            s = s + math.abs(x[key] or 0)
        end
    end
    return s
end

-- Build a problem and apply per-key shortage cost multipliers (key -> mult);
-- keys absent from `mults` keep the flat baseline. Returns problem, state, x, and
-- the IPM iteration count of THIS solve (steps) -- the real cost unit, vs the
-- coarser solve count. Each solve here is COLD (fresh create_problem, no warm
-- start), so these iterations are an upper bound on a warm-started production loop.
local function solve_with(constraints, lines, mults)
    local ok, p = pcall(build, constraints, lines)
    if not ok then return nil, nil, nil, 0 end
    for key, m in pairs(mults) do
        if p.primals[key] then p.primals[key].cost = ELASTIC_COST * m end
    end
    local s, v, steps = solve(p)
    if s ~= "finished" then return p, s, nil, steps end
    return p, s, v.x, steps
end

-- WARM-started solve of the perturbed problem: same as solve_with but seeds the
-- IPM from `warm` (a previous solve's packed variables) instead of the cold
-- Mehrotra start. The solver's iteration-1 re-centering clamp keeps the warm
-- direction while discarding the boundary clamps. Returns state, steps -- this is
-- a measurement-only re-solve (the cold solve_with stays the canonical result),
-- so it reports just convergence + cost, not x.
local function solve_with_warm(constraints, lines, mults, warm)
    local ok, p = pcall(build, constraints, lines)
    if not ok then return "error", 0 end
    for key, m in pairs(mults) do
        if p.primals[key] then p.primals[key].cost = ELASTIC_COST * m end
    end
    local state, iteration, vars, steps = "ready", nil, warm, 0
    while state == "calculating" or state == "ready" do
        state, iteration, vars = lp.solve(p, state, iteration, vars, TOL, ITER)
        steps = steps + 1
        if steps > ITER + 4 then break end
    end
    return state, steps
end

local COLS = {
    "label", "n_scc", "n_keys", "n_oneshot", "n_after_corr", "n_unresolved",
    "observe_solves", "rounds", "total_solves",
    "base_iters", "observe_iters", "verify_iters", "total_iters",
    "warm_observe_iters", "warm_verify_iters", "total_warm_iters", "warm_fail",
}

local function process(constraints, lines, label, emit)
    local ok, prob = pcall(build, constraints, lines)
    if not ok then return end
    local state, vars, base_iters = solve(prob)
    if state ~= "finished" then return end
    local x0 = vars.x
    local th = ed.park_threshold(vars, prob.primals)
    local relax0 = target_relax(prob, x0)

    local adj = mc.build_material_graph(lines)
    local sccs = mc.find_sccs(adj)

    -- Gather avoidable-cheat shortage keys, GROUPED by SCC (the observe is done
    -- per-SCC so its global escape delta cleanly isolates that SCC's dEsc).
    -- groups[i] = { sh = {keys...}, qty = {key->qty}, ceiling = {key->mult} }
    local groups, keys, excl_all, n_scc = {}, {}, {}, 0
    for _, scc in ipairs(sccs) do
        if mc.is_cyclic_scc(scc, adj) then
            local scc_set = {}
            for _, m in ipairs(scc) do scc_set[m] = true end
            local active_sh, active_mats = {}, {}
            for key, p in pairs(prob.primals) do
                if p.kind == "shortage_source" and p.material and scc_set[p.material] and (x0[key] or 0) > th then
                    active_sh[#active_sh + 1] = key
                    active_mats[#active_mats + 1] = p.material
                end
            end
            if #active_sh >= 1 then
                local iset = internal_recipes(lines, scc_set)
                local self_sust = mc.is_self_sustaining(lines, scc)
                local fab = true
                for _, m in ipairs(active_mats) do
                    if not mc.export_feasible(lines, m) then fab = false; break end
                end
                if self_sust and fab and internal_flow(x0, iset) < 1e-6 then
                    n_scc = n_scc + 1
                    local g = { sh = {} }
                    for _, key in ipairs(active_sh) do
                        local qty = x0[key] or 0
                        if qty > 1e-12 then
                            -- collapse ceiling: cost*qty <= target_cost => mult <= target/(elastic*qty)
                            local ceiling = math.max(2, TARGET_COST / (ELASTIC_COST * qty))
                            local k = { key = key, qty = qty, ceiling = ceiling, group = g,
                                mult = 1, frozen = false, resolved_round = -1 }
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
    if #keys == 0 then return end
    trace(("== %s : %d SCC / %d keys ==\n"):format(label, n_scc, #keys))

    -- Phase 2: per-SCC OBSERVE. Raise ONE SCC's keys to its ceiling, solve, read
    -- the global escape delta vs baseline = that SCC's dEsc. If the SCC's shortage
    -- does NOT clear, or it clears only by relaxing the target, it is cone-over-
    -- promise / unavoidable -> freeze now (import is correct), don't waste rounds.
    -- One observe solve per SCC; most dumps are single-SCC so this stays ~1.
    local esc_before = other_escape(prob, x0, excl_all)
    local observe_solves, observe_iters = 0, 0
    local warm_observe_iters, warm_verify_iters, warm_fail = 0, 0, 0
    for gi, g in ipairs(groups) do
        local obs_mults = {}
        for _, k in ipairs(g.sh) do obs_mults[k.key] = k.ceiling end
        local pobs, sobs, xobs, obs_steps = solve_with(constraints, lines, obs_mults)
        observe_solves = observe_solves + 1
        observe_iters = observe_iters + (obs_steps or 0)
        -- warm measurement: same observe, seeded from the baseline solution.
        local ws, wsteps = solve_with_warm(constraints, lines, obs_mults, vars)
        warm_observe_iters = warm_observe_iters + wsteps
        if ws ~= "finished" then warm_fail = warm_fail + 1 end
        local cleared = xobs ~= nil
        local short_o, relax_o = 0, math.huge
        if xobs then
            for _, k in ipairs(g.sh) do short_o = short_o + (xobs[k.key] or 0) end
            relax_o = target_relax(pobs, xobs)
            cleared = short_o <= th and relax_o <= relax0 + 1e-4
        end
        if cleared then
            local desc = other_escape(pobs, xobs, excl_all) - esc_before
            local qsum = 0
            for _, k in ipairs(g.sh) do qsum = qsum + k.qty end
            for _, k in ipairs(g.sh) do
                -- split the SCC's dEsc across its keys by qty share
                local share = desc * (k.qty / qsum)
                k.mult = math.max(2, math.min(k.ceiling, K_PRED * share / k.qty))
                trace(("  [observe scc%d] %-26s qty=%.4g ceil=%.4g dEsc=%.4g -> mult=%.4g\n")
                    :format(gi, kid(k.key), k.qty, k.ceiling, desc, k.mult))
            end
        else
            for _, k in ipairs(g.sh) do k.frozen = true end
            trace(("  [observe scc%d] cone-over-promise/unavoidable (short_o=%.4g relax_o=%.4g) -> FREEZE %d key(s)\n")
                :format(gi, short_o, relax_o, #g.sh))
        end
    end

    -- Phase 3+: verify + correct loop. Each round = one solve.
    local rounds, verify_iters = 0, 0
    while rounds < MAX_ROUNDS do
        rounds = rounds + 1
        local mults = {}
        for _, k in ipairs(keys) do mults[k.key] = k.frozen and 1 or k.mult end
        local pr, sr, xr, ver_steps = solve_with(constraints, lines, mults)
        verify_iters = verify_iters + (ver_steps or 0)
        -- warm measurement: same verify, seeded from the baseline solution.
        local ws, wsteps = solve_with_warm(constraints, lines, mults, vars)
        warm_verify_iters = warm_verify_iters + wsteps
        if ws ~= "finished" then warm_fail = warm_fail + 1 end
        if not xr then break end

        local live_straggler = false
        for _, k in ipairs(keys) do
            if not k.frozen then
                local v = xr[k.key] or 0
                if v <= th then
                    if k.resolved_round < 0 then k.resolved_round = rounds end
                    trace(("  [r%d] %-28s mult=%.4g short=%.4g  OK\n"):format(rounds, kid(k.key), k.mult, v))
                else
                    -- still importing: straggler. The per-SCC observe already set
                    -- an accurate price, so a straggler is just slightly under the
                    -- threshold -- bump x2 (bounded by the collapse ceiling). At the
                    -- ceiling it is unavoidable -> freeze (import is correct).
                    k.resolved_round = -1
                    if k.mult >= k.ceiling * (1 - 1e-9) then
                        k.frozen = true
                        trace(("  [r%d] %-28s mult=%.4g short=%.4g  FREEZE (at ceiling)\n"):format(rounds, kid(k.key), k.mult, v))
                    else
                        k.mult = math.min(k.ceiling, k.mult * 2)
                        trace(("  [r%d] %-28s short=%.4g  BUMP -> mult=%.4g\n"):format(rounds, kid(k.key), v, k.mult))
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

    emit({
        label = label, n_scc = n_scc, n_keys = #keys,
        n_oneshot = n_oneshot, n_after_corr = n_after, n_unresolved = n_unres,
        observe_solves = observe_solves, rounds = rounds,
        total_solves = 1 + observe_solves + rounds,
        base_iters = base_iters, observe_iters = observe_iters,
        verify_iters = verify_iters, total_iters = base_iters + observe_iters + verify_iters,
        warm_observe_iters = warm_observe_iters, warm_verify_iters = warm_verify_iters,
        total_warm_iters = base_iters + warm_observe_iters + warm_verify_iters,
        warm_fail = warm_fail,
    })
end

-- ---- main -------------------------------------------------------------------
local out_path, manifest_path, files = nil, nil, {}
do
    local i = 1
    while arg[i] do
        local a = arg[i]
        if a == "--out" then i = i + 1; out_path = arg[i]
        elseif a == "--manifest" then i = i + 1; manifest_path = arg[i]
        else files[#files + 1] = a end
        i = i + 1
    end
end
if manifest_path then
    for line in io.lines(manifest_path) do
        line = line:gsub("%s+$", "")
        if line ~= "" then files[#files + 1] = line end
    end
end

local sink = io.write
local out_file = nil
if out_path then out_file = assert(io.open(out_path, "w")); sink = function(s) out_file:write(s) end end

local function fmt(v) if type(v) == "number" then return string.format("%.6g", v) end return tostring(v) end
sink("#" .. table.concat(COLS, "\t") .. "\n")
local function emit(r)
    local o = {}
    for _, k in ipairs(COLS) do o[#o + 1] = fmt(r[k]) end
    sink(table.concat(o, "\t") .. "\n")
end

for _, path in ipairs(files) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local label = "seed=" .. tostring(prob.meta and prob.meta.seed) ..
            "|" .. (path:match("([^/\\]+)%.lua$") or path)
        pcall(process, prob.constraints, prob.normalized_lines, label, emit)
    end
end

if out_file then out_file:close() end
