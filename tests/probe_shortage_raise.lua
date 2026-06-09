---@diagnostic disable: undefined-global
-- Phase 2: does raising shortage cost improve, under the CORRECTED yardstick?
--
-- The improvement definition (user): activating a parked variable that reduces a
-- non-zero elastic is useful; byproduct DUMP is acceptable (do not penalise a
-- surplus increase). So the yardstick over the three escape totals
--   shortage_source (import)  surplus_sink (dump)  elastic (target relaxation)
-- is ASYMMETRIC: a drop in shortage (import -> fabricate) or surplus (use the
-- byproduct) is improvement; a RISE in target relaxation is collapse (bad); a
-- rise in surplus is acceptable (neutral).
--
-- This probe raises EVERY |shortage_source| cost by a global multiplier m (the
-- simplest "force fabrication over import" heuristic) up a ladder and records the
-- three escape totals at each m. The analysis then asks: does some m reduce
-- shortage without raising target (improvement, no collapse), and is the best m
-- the SAME across problems (a single global heuristic) or heterogeneous (=>
-- per-material needed, and since the per-material amount is a solve-output, only
-- an iterative/two-pass heuristic can hit it). RAW totals only, no verdict.
--
-- Single-shot (run_corpus): `lua probe_shortage_raise.lua <onefile>` prints one
-- row per m (rows start with the label; -Collect '^seed=' drops the header).
--
-- Usage:
--   pwsh tests/run_corpus.ps1 -Driver tests/probe_shortage_raise.lua -Collect '^seed=' -Out <tsv>
--   <lua> tests/probe_shortage_raise.lua --manifest <list> --out <tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local problem_dump = require "tests/problem_dump"

local TOL, ITER = 1e-7, 800
local OPTS = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
local ELASTIC_COST = 2 ^ 10
local LADDER = { 1, 2, 4, 8, 16, 32, 64, 128 }  -- m=1 is the flat baseline

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("sr", c, l, nil, OPTS) end

-- the three escape totals (sum of |x| per kind)
local function totals(problem, x)
    local s, u, t = 0, 0, 0
    for key, p in pairs(problem.primals) do
        local v = math.abs(x[key] or 0)
        if p.kind == "shortage_source" then s = s + v
        elseif p.kind == "surplus_sink" then u = u + v
        elseif p.kind == "elastic" then t = t + v end
    end
    return s, u, t
end

local COLS = { "label", "m", "state", "shortage", "surplus", "target" }

local function process(constraints, lines, label, emit)
    for _, m in ipairs(LADDER) do
        local ok, p = pcall(build, constraints, lines)
        if ok then
            if m ~= 1 then
                for _, pr in pairs(p.primals) do
                    if pr.kind == "shortage_source" then pr.cost = ELASTIC_COST * m end
                end
            end
            local st, vr = solve(p)
            if st == "finished" then
                local s, u, t = totals(p, vr.x)
                emit({ label = label, m = m, state = st, shortage = s, surplus = u, target = t })
            else
                emit({ label = label, m = m, state = st, shortage = -1, surplus = -1, target = -1 })
            end
        end
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
