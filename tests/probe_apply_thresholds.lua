---@diagnostic disable: undefined-global
-- Phase 2 confirm (honest yardstick): apply the per-material flip thresholds
-- SIMULTANEOUSLY and measure the PROBLEM-level effect.
--
-- probe_per_material_raise found, per importing material, an individual flip
-- threshold (A_m) -- but "flip" there = that material's own shortage -> 0, which
-- does NOT distinguish a real fabrication from whack-a-mole (the import hopping to
-- a sibling), and was measured one material at a time in isolation. This probe
-- closes both gaps: it reads those thresholds, raises EVERY flippable material's
-- |shortage_source| to its own 1024*A_m AT ONCE (leaving the stuck/unavoidable
-- ones at the flat baseline), solves, and records the TOTAL escape vector vs
-- baseline. Real improvement = total shortage drops (the cycle actually runs);
-- whack-a-mole = total shortage ~ flat despite the raises; collapse = target
-- relaxation rises. surplus changes are acceptable (dump-acceptable yardstick).
--
-- Usage (from repo root):
--   <lua> tests/probe_apply_thresholds.lua --thresholds <pmr.tsv> --manifest <list> --out <tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local problem_dump = require "tests/problem_dump"

local TOL, ITER = 1e-7, 800
local OPTS = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
local ELASTIC_COST = 2 ^ 10

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("apt", c, l, nil, OPTS) end

local function totals(p, x)
    local s, u, t = 0, 0, 0
    for key, pr in pairs(p.primals) do
        local v = math.abs(x[key] or 0)
        if pr.kind == "shortage_source" then s = s + v
        elseif pr.kind == "surplus_sink" then u = u + v
        elseif pr.kind == "elastic" then t = t + v end
    end
    return s, u, t
end

-- thresholds: map stem -> { material -> A_m }  (only A_outcome == "flip").
-- The pmr TSV comes from run_corpus (data rows only, no header, BOM) with the
-- fixed probe_per_material_raise column order:
--   1 label  2 material  3 scc_size  4 ns  5 nu  6 A_outcome  7 A_m  8 B..  9 B..
local function load_thresholds(path)
    local map = {}
    for line in io.lines(path) do
        line = line:gsub("^\239\187\191", "")
        if line:match("^seed=") then
            local c = {}; for f in (line .. "\t"):gmatch("([^\t]*)\t") do c[#c + 1] = f end
            if c[6] == "flip" then
                local stem = c[1]:match("|(.+)$") or c[1]
                map[stem] = map[stem] or {}
                map[stem][c[2]] = tonumber(c[7])
            end
        end
    end
    return map
end

local COLS = { "label", "n_raised", "short0", "short_after", "surplus0", "surplus_after",
    "target0", "target_after", "state_after" }

-- ---- main -------------------------------------------------------------------
local out_path, manifest_path, thr_path, files = nil, nil, nil, {}
do local i = 1; while arg[i] do local a = arg[i]
    if a == "--out" then i = i + 1; out_path = arg[i]
    elseif a == "--manifest" then i = i + 1; manifest_path = arg[i]
    elseif a == "--thresholds" then i = i + 1; thr_path = arg[i]
    else files[#files + 1] = a end; i = i + 1 end end
if manifest_path then for line in io.lines(manifest_path) do line = line:gsub("%s+$", ""); if line ~= "" then files[#files + 1] = line end end end
assert(thr_path, "need --thresholds")
local THR = load_thresholds(thr_path)

local sink = io.write; local out_file = nil
if out_path then out_file = assert(io.open(out_path, "w")); sink = function(s) out_file:write(s) end end
local function fmt(v) if v == nil then return "NA" end if type(v) == "number" then return string.format("%.6g", v) end return tostring(v) end
sink("#" .. table.concat(COLS, "\t") .. "\n")
local function emit(r) local o = {}; for _, k in ipairs(COLS) do o[#o + 1] = fmt(r[k]) end; sink(table.concat(o, "\t") .. "\n") end

for _, path in ipairs(files) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local stem = path:match("([^/\\]+)%.lua$") or path
        local thr = THR[stem]
        if thr and next(thr) then
            local label = "seed=" .. tostring(prob.meta and prob.meta.seed) .. "|" .. stem
            local ok, p0 = pcall(build, prob.constraints, prob.normalized_lines)
            if ok then
                local s0, v0 = solve(p0)
                if s0 == "finished" then
                    local sh0, su0, tg0 = totals(p0, v0.x)
                    -- apply all thresholds at once
                    local ok2, p2 = pcall(build, prob.constraints, prob.normalized_lines)
                    if ok2 then
                        local nraised = 0
                        for key, pr in pairs(p2.primals) do
                            if pr.kind == "shortage_source" and pr.material and thr[pr.material] then
                                pr.cost = ELASTIC_COST * thr[pr.material]; nraised = nraised + 1
                            end
                        end
                        local s2, v2 = solve(p2)
                        local sh2, su2, tg2 = -1, -1, -1
                        if s2 == "finished" then sh2, su2, tg2 = totals(p2, v2.x) end
                        emit({ label = label, n_raised = nraised, short0 = sh0, short_after = sh2,
                            surplus0 = su0, surplus_after = su2, target0 = tg0, target_after = tg2,
                            state_after = s2 })
                    end
                end
            end
        end
    end
end
if out_file then out_file:close() end
