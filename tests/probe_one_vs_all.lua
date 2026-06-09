---@diagnostic disable: undefined-global
-- Reconcile the cycle-grouped contradiction: this session's probe_cycle_group_raise
-- (force SCC shortage -> 0, aggressive) said cycle-grouped BACKFIRES; the past
-- session's probe_cycle_elastics (mild marginal raise-one vs raise-all) said
-- raise-all is the unique unlock for ~12% of hard cycles. This reproduces the
-- PAST experiment's lever (mild raise, raise-one vs raise-all per cyclic SCC)
-- but scores on the CORRECTED metric (total external = shortage + initial), so
-- the two are measured the same way.
--
-- Per importing cyclic SCC, at a mild multiplier m: (a) raise just ONE active
-- shortage in the SCC by m, (b) raise ALL the SCC's shortages by m. Each solved
-- in isolation; record global total external and target. The past claim holds if
-- raise-all reduces external where raise-one whack-a-moles (one unchanged, all
-- improves); my backfire holds if raise-all makes external worse.
--
-- Single-shot (run_corpus): one row per importing cyclic SCC, starts 'seed='.
-- Usage:
--   pwsh tests/run_corpus.ps1 -Driver tests/probe_one_vs_all.lua -Collect '^seed=' -Out <tsv>

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
local M = 4   -- mild push (the inverse-w winner / the past's marginal regime)

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("ova", c, l, nil, OPTS) end

local function totals(p, x)
    local sh, ini, tg = 0, 0, 0
    for key, pr in pairs(p.primals) do
        local a = math.abs(x[key] or 0)
        if pr.kind == "shortage_source" then sh = sh + a
        elseif pr.kind == "initial_source" then ini = ini + a
        elseif pr.kind == "elastic" then tg = tg + a end
    end
    return sh, ini, tg
end

-- solve with a chosen set of shortage_source keys raised by M; return ext, tg.
local function raise_and_solve(constraints, lines, raise_keys)
    local ok, p = pcall(build, constraints, lines); if not ok then return -1, -1, "builderr" end
    for key in pairs(raise_keys) do if p.primals[key] then p.primals[key].cost = ELASTIC_COST * M end end
    local st, vr = solve(p); if st ~= "finished" then return -1, -1, st end
    local sh, ini, tg = totals(p, vr.x)
    return sh + ini, tg, st
end

local COLS = { "label", "scc_size", "base_ext", "base_tg",
    "one_ext", "one_tg", "one_state", "all_ext", "all_tg", "all_state" }

local function process(constraints, lines, label, emit)
    local ok, p0 = pcall(build, constraints, lines); if not ok then return end
    local st, v0 = solve(p0); if st ~= "finished" then return end
    local thresh = ed.park_threshold(v0, p0.primals)
    local bsh, bini, btg = totals(p0, v0.x)
    if bsh <= thresh then return end

    local adj = mc.build_material_graph(lines)
    for _, scc in ipairs(mc.find_sccs(adj)) do
        if mc.is_cyclic_scc(scc, adj) then
            local set = {}; for _, mtl in ipairs(scc) do set[mtl] = true end
            -- active shortage keys whose material is in the SCC
            local sh_keys = {}
            for key, pr in pairs(p0.primals) do
                if pr.kind == "shortage_source" and pr.material and set[pr.material] and (v0.x[key] or 0) > thresh then
                    sh_keys[#sh_keys + 1] = key
                end
            end
            if #sh_keys >= 1 then
                -- raise-one: just the first active shortage in the SCC
                local one_set = { [sh_keys[1]] = true }
                local one_ext, one_tg, one_st = raise_and_solve(constraints, lines, one_set)
                -- raise-all: every active shortage in the SCC
                local all_set = {}; for _, k in ipairs(sh_keys) do all_set[k] = true end
                local all_ext, all_tg, all_st = raise_and_solve(constraints, lines, all_set)
                emit({ label = label, scc_size = #scc, base_ext = bsh + bini, base_tg = btg,
                    one_ext = one_ext, one_tg = one_tg, one_state = one_st,
                    all_ext = all_ext, all_tg = all_tg, all_state = all_st })
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
