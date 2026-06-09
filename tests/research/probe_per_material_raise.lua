---@diagnostic disable: undefined-global
-- Phase 2 confirm: iterative PER-MATERIAL shortage raise (with cycle-grouped
-- fallback), scored on the corrected dump-acceptable yardstick.
--
-- The global shortage multiplier has no sweet spot (probe_shortage_raise): raise
-- enough to flip high-threshold imports and the low-threshold / unavoidable ones
-- collapse. This probe instead raises EACH importing material to ITS OWN
-- threshold, so each gets just enough and no more:
--   Lever A (individual): raise only material M's |shortage_source| up a ladder.
--     flip     = M's shortage drops to ~0 with target relaxation NOT rising
--     collapse = target relaxation rises before M flips (over-raised an
--                unavoidable import past target_cost)
--     stuck    = neither at the top of the ladder (LP keeps importing M)
--   Lever B (cycle-grouped, only when A is stuck): raise ALL |shortage_source|
--     whose material is in M's SCC together -- the prior cycle work's "raise-all"
--     that stops relief from just hopping to a sibling import (whack-a-mole).
-- RAW per-material outcomes only. The yardstick (dump acceptable) ignores
-- surplus changes; target-relaxation rise is the collapse signal.
--
-- Single-shot (run_corpus): one row per importing material, rows start 'seed='.
-- Usage:
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_per_material_raise.lua -Collect '^seed=' -Out <tsv>
--   <lua> tests/research/probe_per_material_raise.lua --manifest <list> --out <tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"
local mc = require "solver/material_cycles"

local TOL, ITER = 1e-7, 800
local OPTS = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
local ELASTIC_COST = 2 ^ 10
local LADDER = { 2, 4, 8, 16, 32, 64, 128, 512, 2048 }

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("pmr", c, l, nil, OPTS) end

local function target_total(p, x)
    local t = 0
    for key, pr in pairs(p.primals) do if pr.kind == "elastic" then t = t + math.abs(x[key] or 0) end end
    return t
end
local function shortage_for(p, x, material)
    local s = 0
    for key, pr in pairs(p.primals) do
        if pr.kind == "shortage_source" and pr.material == material then s = s + math.abs(x[key] or 0) end
    end
    return s
end

-- Raise the shortage_source cost for a set of materials; returns flip/collapse/
-- stuck and the multiplier at the verdict. raise_set = { material -> true }.
-- target0 = baseline target relaxation; thresh = park threshold; track_mat = the
-- material whose shortage must drop to count as flip.
local function probe(constraints, lines, raise_set, track_mat, target0, thresh)
    for _, m in ipairs(LADDER) do
        local ok, p = pcall(build, constraints, lines)
        if not ok then return "builderr", -1 end
        for key, pr in pairs(p.primals) do
            if pr.kind == "shortage_source" and pr.material and raise_set[pr.material] then
                pr.cost = ELASTIC_COST * m
            end
        end
        local st, vr = solve(p)
        if st ~= "finished" then return "unfin", m end
        local tgt = target_total(p, vr.x)
        local sho = shortage_for(p, vr.x, track_mat)
        if tgt > target0 + 1e-4 and sho > thresh then return "collapse", m end
        if sho <= thresh and tgt <= target0 + 1e-4 then return "flip", m end
    end
    return "stuck", -1
end

local COLS = { "label", "material", "scc_size", "scc_n_short_active", "scc_n_surplus_active",
    "A_outcome", "A_m", "B_outcome", "B_m" }

local function process(constraints, lines, label, emit)
    local ok, prob = pcall(build, constraints, lines)
    if not ok then return end
    local st, vr = solve(prob); if st ~= "finished" then return end
    local x0 = vr.x
    local thresh = ed.park_threshold(vr, prob.primals)
    local target0 = target_total(prob, x0)

    -- importing materials (active shortage at baseline)
    local importing = {}
    for key, p in pairs(prob.primals) do
        if p.kind == "shortage_source" and p.material and (x0[key] or 0) > thresh then importing[p.material] = true end
    end
    if not next(importing) then return end

    -- SCC map: material -> members set; plus per-SCC active short/surplus counts.
    local adj = mc.build_material_graph(lines)
    local sccs = mc.find_sccs(adj)
    local scc_of = {}
    for _, scc in ipairs(sccs) do
        local set, cyclic = {}, mc.is_cyclic_scc(scc, adj)
        for _, mtl in ipairs(scc) do set[mtl] = true end
        for _, mtl in ipairs(scc) do scc_of[mtl] = { set = set, size = #scc, cyclic = cyclic } end
    end
    -- per-SCC active escape counts (for the kind axis)
    local function scc_counts(set)
        local ns, nu = 0, 0
        for key, p in pairs(prob.primals) do
            if p.material and set[p.material] and (x0[key] or 0) > thresh then
                if p.kind == "shortage_source" then ns = ns + 1
                elseif p.kind == "surplus_sink" then nu = nu + 1 end
            end
        end
        return ns, nu
    end

    for material in pairs(importing) do
        local info = scc_of[material]
        local size = info and info.size or 1
        local ns, nu = 0, 0
        if info then ns, nu = scc_counts(info.set) end
        -- Lever A: individual
        local a_out, a_m = probe(constraints, lines, { [material] = true }, material, target0, thresh)
        -- Lever B: cycle-grouped, only if A stuck and material is in a cyclic SCC
        local b_out, b_m = "NA", -1
        if a_out == "stuck" and info and info.cyclic then
            b_out, b_m = probe(constraints, lines, info.set, material, target0, thresh)
        end
        emit({ label = label, material = material, scc_size = size,
            scc_n_short_active = ns, scc_n_surplus_active = nu,
            A_outcome = a_out, A_m = a_m, B_outcome = b_out, B_m = b_m })
    end
end

-- ---- main -------------------------------------------------------------------
local out_path, manifest_path, files = nil, nil, {}
do local i = 1; while arg[i] do local a = arg[i]
    if a == "--out" then i = i + 1; out_path = arg[i]
    elseif a == "--manifest" then i = i + 1; manifest_path = arg[i]
    else files[#files + 1] = a end; i = i + 1 end end
if manifest_path then for line in io.lines(manifest_path) do line = line:gsub("%s+$", ""); if line ~= "" then files[#files + 1] = line end end end

local sink = io.write; local out_file = nil
if out_path then out_file = assert(io.open(out_path, "w")); sink = function(s) out_file:write(s) end end
local function fmt(v) if v == nil then return "NA" end if type(v) == "number" then return string.format("%.6g", v) end return tostring(v) end
if out_path then sink("#" .. table.concat(COLS, "\t") .. "\n") end
local function emit(r) local o = {}; for _, k in ipairs(COLS) do o[#o + 1] = fmt(r[k]) end; sink(table.concat(o, "\t") .. "\n") end

for _, path in ipairs(files) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local label = "seed=" .. tostring(prob.meta and prob.meta.seed) .. "|" .. (path:match("([^/\\]+)%.lua$") or path)
        pcall(process, prob.constraints, prob.normalized_lines, label, emit)
    end
end
if out_file then out_file:close() end
