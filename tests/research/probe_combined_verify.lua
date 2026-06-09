---@diagnostic disable: undefined-global
-- Combined-regime per-material correctness check (research, no verdict).
--
-- probe_elastic_tighten showed that a coarse uniform import tilt (amount lever,
-- K=1024) PLUS an elastic-shrink (amount lever, E=1024) drives the tilt-induced
-- target collapses to zero -- the LP imports instead of abandoning. The open
-- question: is the resulting split CORRECT per material, i.e. does the uniform
-- (K,E) let the LP self-discriminate without a gate?
--   * avoidable cheat (self-sustaining cyclic SCC, export_feasible, idle-import at
--     baseline) -- SHOULD fabricate (its shortage -> 0, the cycle runs).
--   * unavoidable import (cyclic-SCC active shortage that is NOT export_feasible)
--     -- SHOULD keep importing, with no target collapse and no forced over-build.
--
-- For each cyclic-SCC active-shortage material, classify it on export_feasibility
-- (and the avoidable-cheat qualification), solve the combined regime, and record
-- whether it ends up fabricated (physical shortage ~0 with the cycle's internal
-- recipes running) or still imported, plus whether the problem collapsed. Cross-
-- tabulating fabricable-vs-fabricated tells us if the uniform tilt sorts the two
-- populations correctly with no per-material signal.
--
-- Single-shot (run_corpus): one row per active-shortage material, starts 'seed='.
-- Usage:
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_combined_verify.lua -Collect '^seed=' -Out <tsv>

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
local K_IMPORT = 1024
local E_ELASTIC = 1024

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("comb", c, l, nil, OPTS) end

local function scale_kind(p, kind, factor)
    for key, pr in pairs(p.primals) do
        if pr.kind == kind then
            local terms = p.subject_terms[key]
            if terms then for d, c in pairs(terms) do terms[d] = c / factor end end
        end
    end
end

local R = require "tests/research/research_lib"
local internal_recipes = R.internal_recipes
local internal_flow = R.internal_flow
local relax_total = R.target_relax

local COLS = { "label", "material", "group", "fabricable", "base_short",
    "comb_short", "comb_iflow", "comb_initial", "outcome", "collapsed" }

local function process(constraints, lines, label, emit)
    local ok, p0 = pcall(build, constraints, lines)
    if not ok then return end
    local st, v0 = solve(p0)
    if st ~= "finished" then return end
    local x0 = v0.x
    local th = ed.park_threshold(v0, p0.primals)
    local relax0 = relax_total(p0, x0)

    -- combined-regime solve (computed once per problem)
    local okc, pc = pcall(build, constraints, lines)
    if not okc then return end
    scale_kind(pc, "shortage_source", K_IMPORT)
    scale_kind(pc, "elastic", E_ELASTIC)
    local sc, vc = solve(pc)
    if sc ~= "finished" then return end
    local xc = vc.x
    local relax_c = relax_total(pc, xc)
    local collapsed = (relax_c > relax0 + 1e-4) and 1 or 0

    local adj = mc.build_material_graph(lines)
    for _, scc in ipairs(mc.find_sccs(adj)) do
        if mc.is_cyclic_scc(scc, adj) then
            local scc_set = {}
            for _, m in ipairs(scc) do scc_set[m] = true end
            -- active-shortage materials in this SCC at baseline
            local active = {} -- material -> {keys}
            for key, p in pairs(p0.primals) do
                if p.kind == "shortage_source" and p.material and scc_set[p.material] and (x0[key] or 0) > th then
                    active[p.material] = active[p.material] or {}
                    active[p.material][#active[p.material] + 1] = key
                end
            end
            local any = false
            for _ in pairs(active) do any = true; break end
            if any then
                local iset = internal_recipes(lines, scc_set)
                local self_sust = mc.is_self_sustaining(lines, scc)
                local iflow0 = internal_flow(x0, iset)
                for material, keys in pairs(active) do
                    local fabricable = mc.export_feasible(lines, material)
                    local group
                    if self_sust and fabricable and iflow0 < 1e-6 then group = "avoidable"
                    elseif not fabricable then group = "unavoidable"
                    else group = "other" end

                    local base_short = 0
                    for _, k in ipairs(keys) do base_short = base_short + (x0[k] or 0) end
                    -- physical shortage in combined regime (coeff scaled to 1/K)
                    local comb_short = 0
                    for _, k in ipairs(keys) do comb_short = comb_short + (xc[k] or 0) / K_IMPORT end
                    local comb_iflow = internal_flow(xc, iset)
                    -- this material's initial_source (raw) import in the combined solve
                    local comb_initial = 0
                    for key, p in pairs(pc.primals) do
                        if p.kind == "initial_source" and p.material == material then
                            comb_initial = comb_initial + math.abs(xc[key] or 0)
                        end
                    end
                    local outcome
                    if comb_short <= th then outcome = "fabricated"  -- import eliminated
                    else outcome = "imports" end

                    emit({ label = label, material = material, group = group,
                        fabricable = tostring(fabricable == true), base_short = base_short,
                        comb_short = comb_short, comb_iflow = comb_iflow, comb_initial = comb_initial,
                        outcome = outcome, collapsed = collapsed })
                end
            end
        end
    end
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
    for line in io.lines(manifest_path) do line = line:gsub("%s+$", ""); if line ~= "" then files[#files + 1] = line end end
end

local sink = io.write
local out_file = nil
if out_path then out_file = assert(io.open(out_path, "w")); sink = function(s) out_file:write(s) end end
local function fmt(v) if type(v) == "number" then return string.format("%.6g", v) end return tostring(v) end
sink("#" .. table.concat(COLS, "\t") .. "\n")
local function emit(r) local o = {}; for _, k in ipairs(COLS) do o[#o + 1] = fmt(r[k]) end; sink(table.concat(o, "\t") .. "\n") end

for _, path in ipairs(files) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local label = "seed=" .. tostring(prob.meta and prob.meta.seed) .. "|" .. (path:match("([^/\\]+)%.lua$") or path)
        pcall(process, prob.constraints, prob.normalized_lines, label, emit)
    end
end
if out_file then out_file:close() end
