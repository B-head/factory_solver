---@diagnostic disable: undefined-global
-- Phase 2: per-SCC cycle-grouped shortage raise, scored on total shortage.
--
-- Per-material individual raise was 75% whack-a-mole (probe_apply_thresholds):
-- raising only the baseline-importing materials lets the import hop to an
-- unraised sibling, so total shortage stays flat. The fix (the prior cycle-elastic
-- work / the user's pointer): raise the WHOLE cycle's shortage together so there
-- is no sibling to hop to, with a PER-SCC threshold (global single-m can't fit the
-- 2..2048 spread).
--
-- Per problem: (1) baseline solve; (2) for each importing cyclic SCC raise ALL its
-- |shortage_source| together up a ladder, find the SCC threshold where the SCC's
-- own total shortage drops to ~0 with target relaxation flat (flip), else target
-- rose first (traded) or stuck; (3) apply every flipping SCC's threshold AT ONCE
-- (non-flippers left flat) and solve; (4) report GLOBAL total shortage before/after
-- (catches cross-SCC hopping too) + target. Raw numbers; analysis classifies
-- improved-fabricate / target-traded / whack-a-mole. (collapse=infeasible cannot
-- arise from cost changes.)
--
-- Single-shot (run_corpus): one row per problem, starts 'seed='.
-- Usage:
--   pwsh tests/run_corpus.ps1 -Driver tests/research/probe_cycle_group_raise.lua -Collect '^seed=' -Out <tsv>
--   <lua> tests/research/probe_cycle_group_raise.lua --manifest <list> --out <tsv>

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
local function build(c, l) return create_problem.create_problem("cgr", c, l, nil, OPTS) end

local function target_total(p, x)
    local t = 0; for key, pr in pairs(p.primals) do if pr.kind == "elastic" then t = t + math.abs(x[key] or 0) end end; return t
end
local function shortage_total(p, x)
    local s = 0; for key, pr in pairs(p.primals) do if pr.kind == "shortage_source" then s = s + math.abs(x[key] or 0) end end; return s
end
local function initial_total(p, x)
    local s = 0; for key, pr in pairs(p.primals) do if pr.kind == "initial_source" then s = s + math.abs(x[key] or 0) end end; return s
end
local function shortage_in_set(p, x, set)
    local s = 0
    for key, pr in pairs(p.primals) do if pr.kind == "shortage_source" and pr.material and set[pr.material] then s = s + math.abs(x[key] or 0) end end
    return s
end

-- raise all shortage in scc_set up the ladder; return flip m (scc shortage ~0,
-- target flat), or "traded"/-1 (target rose first), or "stuck"/-1.
local function scc_threshold(constraints, lines, scc_set, target0, thresh)
    for _, m in ipairs(LADDER) do
        local ok, p = pcall(build, constraints, lines); if not ok then return "builderr", -1 end
        for key, pr in pairs(p.primals) do
            if pr.kind == "shortage_source" and pr.material and scc_set[pr.material] then pr.cost = ELASTIC_COST * m end
        end
        local st, vr = solve(p); if st ~= "finished" then return "unfin", -1 end
        local tgt = target_total(p, vr.x)
        local ssh = shortage_in_set(p, vr.x, scc_set)
        if tgt > target0 + 1e-4 and ssh > thresh then return "traded", m end
        if ssh <= thresh and tgt <= target0 + 1e-4 then return "flip", m end
    end
    return "stuck", -1
end

local COLS = { "label", "n_scc_import", "n_flip", "n_traded", "n_stuck",
    "short0", "short_after", "ini0", "ini_after", "target0", "target_after", "state_after" }

local function process(constraints, lines, label, emit)
    local ok, p0 = pcall(build, constraints, lines); if not ok then return end
    local st, v0 = solve(p0); if st ~= "finished" then return end
    local thresh = ed.park_threshold(v0, p0.primals)
    local S0, T0, I0 = shortage_total(p0, v0.x), target_total(p0, v0.x), initial_total(p0, v0.x)
    if S0 <= thresh then return end  -- no import at baseline

    local adj = mc.build_material_graph(lines)
    local sccs = mc.find_sccs(adj)
    -- importing cyclic SCCs + their flip thresholds
    local flip_sets = {}  -- list of { set, m }
    local n_import, n_flip, n_traded, n_stuck = 0, 0, 0, 0
    for _, scc in ipairs(sccs) do
        if mc.is_cyclic_scc(scc, adj) then
            local set = {}; for _, mtl in ipairs(scc) do set[mtl] = true end
            if shortage_in_set(p0, v0.x, set) > thresh then
                n_import = n_import + 1
                local out, m = scc_threshold(constraints, lines, set, T0, thresh)
                if out == "flip" then n_flip = n_flip + 1; flip_sets[#flip_sets + 1] = { set = set, m = m }
                elseif out == "traded" then n_traded = n_traded + 1
                else n_stuck = n_stuck + 1 end
            end
        end
    end

    -- apply all flip thresholds at once, measure global totals
    local S_after, I_after, T_after, state_after = -1, -1, -1, "noflip"
    if #flip_sets > 0 then
        local ok2, p2 = pcall(build, constraints, lines)
        if ok2 then
            for _, fs in ipairs(flip_sets) do
                for key, pr in pairs(p2.primals) do
                    if pr.kind == "shortage_source" and pr.material and fs.set[pr.material] then pr.cost = ELASTIC_COST * fs.m end
                end
            end
            local s2, v2 = solve(p2)
            state_after = s2
            if s2 == "finished" then
                S_after, T_after, I_after = shortage_total(p2, v2.x), target_total(p2, v2.x), initial_total(p2, v2.x)
            end
        end
    end
    emit({ label = label, n_scc_import = n_import, n_flip = n_flip, n_traded = n_traded, n_stuck = n_stuck,
        short0 = S0, short_after = S_after, ini0 = I0, ini_after = I_after,
        target0 = T0, target_after = T_after, state_after = state_after })
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
