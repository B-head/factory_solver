---@diagnostic disable: undefined-global
-- Elastic-tighten probe (research, no verdict).
--
-- probe_coarse_tilt showed a coarse uniform import tilt collapses MORE targets as
-- K grows (economic, q-amplified: making target T needs q units of a tilted
-- material M at price p, and the LP abandons T once p*q exceeds the relaxation
-- price). The amount lever did not help -- the collapse is economic, not numerical.
--
-- User's follow-up insight: the target-relaxation (|elastic|) variable is also
-- synthetic, coefficient hardcoded 1, so its amount is free too. Its effective
-- relaxation price is target_cost / a_elastic. SHRINKING a_elastic raises that
-- price, so the LP is more reluctant to abandon a target -- and since the
-- collapse is "import got expensive, so relax instead", making relax expensive too
-- should push the unavoidable imports back to IMPORTING (correct) rather than
-- collapsing. Collapse threshold K*q*a_elastic > 1024 recedes to q > 1024/(K*a_e).
--
-- Test: hold the import tilt at a fixed K (amount lever, in the collapse regime),
-- and sweep an elastic-shrink factor E (a_elastic -> 1/E, via the elastic vars'
-- subject_terms). If shrinking the elastic converts the tilt-induced collapses
-- back into imports, the collapse count drops toward the baseline relax as E grows
-- and external (shortage+initial) rises to absorb the rescued imports.
--
-- Single-shot (run_corpus): one row per problem, starts 'seed='.
-- Usage:
--   pwsh tests/run_corpus.ps1 -Driver tests/probe_elastic_tighten.lua -Collect '^seed=' -Out <tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"

local TOL, ITER = 1e-7, 800
local OPTS = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
local ELASTIC_COST = 2 ^ 10
local K_IMPORT = 1024          -- fixed import tilt (amount lever), in the collapse regime
local ES = { 1, 64, 1024, 16384 } -- elastic-shrink factors to sweep

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("etight", c, l, nil, OPTS) end

local function baseline_totals(p, x)
    local sh, ini, tg = 0, 0, 0
    for key, pr in pairs(p.primals) do
        local a = math.abs(x[key] or 0)
        if pr.kind == "shortage_source" then sh = sh + a
        elseif pr.kind == "initial_source" then ini = ini + a
        elseif pr.kind == "elastic" then tg = tg + a end
    end
    return sh, ini, tg
end

-- scale every var of a kind by 1/factor across all its subject-term rows.
local function scale_kind(p, kind, factor)
    for key, pr in pairs(p.primals) do
        if pr.kind == kind then
            local terms = p.subject_terms[key]
            if terms then for d, c in pairs(terms) do terms[d] = c / factor end end
        end
    end
end

-- solve with import tilted (amount 1/K_IMPORT) and elastic shrunk (amount 1/E);
-- return physical external (shortage/K + initial) and physical relax (elastic/E).
local function tilt_solve(constraints, lines, E)
    local ok, p = pcall(build, constraints, lines)
    if not ok then return nil end
    scale_kind(p, "shortage_source", K_IMPORT)
    if E > 1 then scale_kind(p, "elastic", E) end
    local st, vr = solve(p)
    if st ~= "finished" then return { state = st } end
    local sh, ini, relax = 0, 0, 0
    for key, pr in pairs(p.primals) do
        local v = math.abs(vr.x[key] or 0)
        if pr.kind == "shortage_source" then sh = sh + v / K_IMPORT
        elseif pr.kind == "initial_source" then ini = ini + v
        elseif pr.kind == "elastic" then relax = relax + v / E end
    end
    return { state = "finished", ext = sh + ini, relax = relax }
end

local COLS = { "label", "ext0", "relax0" }
for _, E in ipairs(ES) do
    COLS[#COLS + 1] = "ext_E" .. E
    COLS[#COLS + 1] = "rlx_E" .. E
end

local function process(constraints, lines, label, emit)
    local ok, p0 = pcall(build, constraints, lines)
    if not ok then return end
    local st, v0 = solve(p0)
    if st ~= "finished" then return end
    local th = ed.park_threshold(v0, p0.primals)
    local sh0, ini0, tg0 = baseline_totals(p0, v0.x)
    if sh0 + ini0 <= th then return end

    local row = { label = label, ext0 = sh0 + ini0, relax0 = tg0 }
    for _, E in ipairs(ES) do
        local r = tilt_solve(constraints, lines, E)
        row["ext_E" .. E] = (r and r.ext) or -1
        row["rlx_E" .. E] = (r and r.relax) or -1
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
