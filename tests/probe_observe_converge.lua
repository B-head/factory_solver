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
local OBSERVE_MULT = 16384
local K_PRED = 1.5
local MAX_ROUNDS = 6

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("converge", c, l, nil, OPTS) end

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

-- Escape mass (surplus_sink + shortage_source) of escapes whose material is in
-- scc_set, EXCLUDING the avoidable keys themselves -- the SCC's dEsc footprint
-- (byproduct dumps + in-SCC secondary deficits). At baseline the SCC is idle so
-- this is ~0; after fabrication it is the disposal mass fabrication dragged in.
local function scc_footprint(problem, x, scc_set, exclude)
    local s = 0
    for key, p in pairs(problem.primals) do
        if (p.kind == "surplus_sink" or p.kind == "shortage_source") and p.material
            and scc_set[p.material] and not exclude[key] then
            s = s + math.abs(x[key] or 0)
        end
    end
    return s
end

-- Build a problem and apply per-key shortage cost multipliers (key -> mult);
-- keys absent from `mults` keep the flat baseline. Returns problem, state, x.
local function solve_with(constraints, lines, mults)
    local ok, p = pcall(build, constraints, lines)
    if not ok then return nil end
    for key, m in pairs(mults) do
        if p.primals[key] then p.primals[key].cost = ELASTIC_COST * m end
    end
    local s, v = solve(p)
    if s ~= "finished" then return p, s, nil end
    return p, s, v.x
end

local COLS = {
    "label", "n_scc", "n_keys", "n_oneshot", "n_after_corr", "n_unresolved",
    "rounds", "total_solves",
}

local function process(constraints, lines, label, emit)
    local ok, prob = pcall(build, constraints, lines)
    if not ok then return end
    local state, vars = solve(prob)
    if state ~= "finished" then return end
    local x0 = vars.x
    local th = ed.park_threshold(vars, prob.primals)
    local relax0 = target_relax(prob, x0)

    local adj = mc.build_material_graph(lines)
    local sccs = mc.find_sccs(adj)

    -- Gather every avoidable-cheat shortage key across qualifying SCCs.
    -- keys[i] = { key, qty, scc_set, exclude, ceiling, mult, frozen, resolved_round }
    local keys = {}
    local n_scc = 0
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
                    local exclude = {}
                    for _, key in ipairs(active_sh) do exclude[key] = true end
                    for _, key in ipairs(active_sh) do
                        local qty = x0[key] or 0
                        if qty > 1e-12 then
                            -- collapse ceiling: cost*qty <= target_cost  =>  mult <= target/(elastic*qty)
                            local ceiling = TARGET_COST / (ELASTIC_COST * qty)
                            keys[#keys + 1] = {
                                key = key, qty = qty, scc_set = scc_set, exclude = exclude,
                                ceiling = math.max(2, ceiling), mult = 1, frozen = false, resolved_round = -1,
                            }
                        end
                    end
                end
            end
        end
    end
    if #keys == 0 then return end

    -- Phase 2: ONE global observe -- all avoidable keys at the ceiling at once.
    local obs_mults = {}
    for _, k in ipairs(keys) do obs_mults[k.key] = OBSERVE_MULT end
    local pobs, sobs, xobs = solve_with(constraints, lines, obs_mults)
    if not xobs then return end -- observe didn't finish; out of scope for this probe
    for _, k in ipairs(keys) do
        local desc = scc_footprint(pobs, xobs, k.scc_set, k.exclude)
        local pred = K_PRED * desc / k.qty
        k.mult = math.max(2, math.min(k.ceiling, pred))
    end

    -- Phase 3+: verify + correct loop. Each round = one solve.
    local rounds = 0
    while rounds < MAX_ROUNDS do
        rounds = rounds + 1
        local mults = {}
        for _, k in ipairs(keys) do mults[k.key] = k.frozen and 1 or k.mult end
        local pr, sr, xr = solve_with(constraints, lines, mults)
        if not xr then break end

        local live_straggler = false
        for _, k in ipairs(keys) do
            if not k.frozen then
                local v = xr[k.key] or 0
                if v <= th then
                    if k.resolved_round < 0 then k.resolved_round = rounds end
                else
                    -- still importing: straggler. bump, or freeze if at ceiling.
                    k.resolved_round = -1
                    if k.mult >= k.ceiling * (1 - 1e-9) then
                        k.frozen = true -- unavoidable / cone-over-promise: import is correct
                    else
                        local desc = scc_footprint(pr, xr, k.scc_set, k.exclude)
                        local pred = K_PRED * desc / k.qty
                        k.mult = math.min(k.ceiling, math.max(k.mult * 2, pred))
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
        rounds = rounds, total_solves = 2 + rounds,
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
