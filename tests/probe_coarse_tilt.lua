---@diagnostic disable: undefined-global
-- Coarse global tilt: cost lever (ceiling-bound) vs amount lever (ceiling-safe).
--
-- The amount lever (probe_amount_lever) removes the COST-COEFFICIENT ceiling: a
-- large effective import tilt can be applied with cost coefficients staying flat
-- at 1024 (the steepness goes into the constraint amounts). The open question this
-- probe settles: does a COARSE LARGE uniform tilt then flip most importing
-- material to fabrication WITHOUT collapsing targets -- i.e. is the heuristic now
-- "tilt everything hard and most cases land right"?
--
-- Two collapse mechanisms must be separated:
--   * numerical -- cost coefficient near 2^20 ill-conditions the solve. The amount
--     lever AVOIDS this (coefficients stay 1024).
--   * economic  -- making target T needs q units of a tilted material M at price p;
--     if p*q > target_cost the LP abandons T. Governed by effective price, so the
--     amount lever does NOT avoid it, and for deep chains (large q) it collapses
--     at p = target_cost/q, well below the 2^20 ceiling.
-- Phase 2 (global COST raise) already collapsed 96 problems at m=128 (coeff 2^17,
-- far below 2^20). This probe re-applies the SAME effective tilt via the amount
-- lever (cost fixed at 1024, well-conditioned) and asks whether those collapses
-- shrink (they were numerical -> amount recovers them, the reframing holds) or
-- stay (economic / q-amplified -> the wall stands).
--
-- Per problem, for each global effective multiplier K, apply it two ways to ALL
-- |shortage_source|: cost x K, or amount x 1/K (scaling the vars' subject_terms),
-- and record total external (shortage+initial), target relax, and recipe sum.
-- Cost is invalid past the ceiling (K>~1024 -> coeff>2^20); amount is the only
-- lever that can reach K=4096/16384, exactly the regime the reframing needs.
--
-- Single-shot (run_corpus): one row per problem, starts 'seed='.
-- Usage:
--   pwsh tests/run_corpus.ps1 -Driver tests/probe_coarse_tilt.lua -Collect '^seed=' -Out <tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"

local TOL, ITER = 1e-7, 800
local OPTS = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
local ELASTIC_COST = 2 ^ 10
local KS = { 64, 1024, 4096, 16384 }

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("coarse", c, l, nil, OPTS) end

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

-- apply a global tilt K to every shortage_source, via "cost" or "amount".
local function tilt_solve(constraints, lines, K, mode)
    local ok, p = pcall(build, constraints, lines)
    if not ok then return nil end
    for key, pr in pairs(p.primals) do
        if pr.kind == "shortage_source" then
            if mode == "cost" then
                pr.cost = ELASTIC_COST * K
            else -- amount: shrink the var's coefficient in every row it touches
                local terms = p.subject_terms[key]
                if terms then for d, c in pairs(terms) do terms[d] = c / K end end
            end
        end
    end
    local st, vr = solve(p)
    if st ~= "finished" then return { state = st } end
    -- physical external: for the amount-tilted shortage, the real import is
    -- coeff*value; recompute shortage physically. initial/elastic are untouched.
    local sh, ini, tg = 0, 0, 0
    for key, pr in pairs(p.primals) do
        local v = math.abs(vr.x[key] or 0)
        if pr.kind == "shortage_source" then
            local coeff = 1
            if mode == "amount" then
                local terms = p.subject_terms[key]
                coeff = (terms and terms[pr.material]) or (1 / K)
            end
            sh = sh + v * coeff
        elseif pr.kind == "initial_source" then ini = ini + v
        elseif pr.kind == "elastic" then tg = tg + v end
    end
    return { state = "finished", ext = sh + ini, relax = tg }
end

local COLS = { "label", "ext0", "relax0" }
for _, K in ipairs(KS) do
    COLS[#COLS + 1] = "c_ext_" .. K
    COLS[#COLS + 1] = "c_rlx_" .. K
    COLS[#COLS + 1] = "a_ext_" .. K
    COLS[#COLS + 1] = "a_rlx_" .. K
end

local function process(constraints, lines, label, emit)
    local ok, p0 = pcall(build, constraints, lines)
    if not ok then return end
    local st, v0 = solve(p0)
    if st ~= "finished" then return end
    local th = ed.park_threshold(v0, p0.primals)
    local sh0, ini0, tg0 = totals(p0, v0.x)
    if sh0 + ini0 <= th then return end -- no external dependence at baseline

    local row = { label = label, ext0 = sh0 + ini0, relax0 = tg0 }
    for _, K in ipairs(KS) do
        local rc = tilt_solve(constraints, lines, K, "cost")
        local ra = tilt_solve(constraints, lines, K, "amount")
        row["c_ext_" .. K] = (rc and rc.ext) or -1
        row["c_rlx_" .. K] = (rc and rc.relax) or -1
        row["a_ext_" .. K] = (ra and ra.ext) or -1
        row["a_rlx_" .. K] = (ra and ra.relax) or -1
    end
    emit(row)
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
