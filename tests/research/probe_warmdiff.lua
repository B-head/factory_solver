---@diagnostic disable: undefined-global
-- Initial-point invariance probe: drive the cascade COLD and WARM in the SAME
-- process (same hash seed, so pairs() order is identical) and compare the final
-- solution variable-by-variable. The /goal metric: max |x_cold - x_warm| over
-- every variable must be <= 1e-4. Same-process isolation removes the
-- cross-process pairs-order nondeterminism, so any difference is purely the
-- warm-start landing on a different vertex.
--
--   <lua> probe_warmdiff.lua <dump> [<dump> ...]
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_warmdiff.lua -Collect '^seed=' -Out <tsv>
--
-- Emits one tab row per dump: label, n_vars, max_abs_diff, n_over_1e-4,
-- max_rel_diff, worst_key.

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local problem_generator = require "solver/problem_generator"
local harness = require "tests/harness"

-- FS_TIE sets the per-variable tie-break magnitude (solver/problem_generator):
-- a distinct tiny cost per variable that collapses the degenerate optimal face
-- to a unique point, so cold and warm pick the SAME vertex. Applied per build:
-- 0 on the classification (cascade.is_cold) builds -- they are cold in both runs
-- and their EPS=2^-20 producibility regularizer must not be swamped -- and FS_TIE
-- on every heavy / baseline build (where EPS only regularizes bridges). So it
-- must sit below the recipe cost 1 but above the heavy face's IPM resolution.
local TIE = tonumber(os.getenv("FS_TIE") or "") or 0
local problem_dump = require "tests/problem_dump"
local ref = require "tests/research/reference_solver"
local cascade = require "solver/cascade"
local substitution = require "solver/substitution"

local TOL = tonumber(os.getenv("FS_TOL") or "") or 1e-7
local ITER = tonumber(os.getenv("FS_ITER") or "") or 800
local RESCUE_TRIGGER = 1e-6
local BUDGET_REL, BUDGET_ABS = 1e-3, 1e-6
local SUBST = (os.getenv("FS_SUBST") or "off"):lower() == "on"
-- FS_WARMALL=on warms EVERY build incl. the classification builds (ignores
-- cascade.is_cold) -- the test of whether a tight tolerance ALONE drives every
-- build (degenerate or not) to the unique analytic center, making the solution
-- initial-point invariant without colding anything.
local WARMALL = (os.getenv("FS_WARMALL") or "off"):lower() == "on"

local function solve(p, warm) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }, warm) end
local function budget(opt) return opt * (1 + BUDGET_REL) + BUDGET_ABS end

local function build_ship(constraints, lines, target_budget, target_only)
    local opts = { reachability_gating = false, target_budget = target_budget, target_only_objective = target_only }
    local ok, p = pcall(create_problem.create_problem, "ship", constraints, lines, nil, opts)
    if not ok then return nil end
    return p
end
local function build_cascade(constraints, lines, build)
    local ok, p = pcall(create_problem.create_problem, "cascade", constraints, lines, nil, cascade.build_options(build))
    if not ok then return nil end
    cascade.shape_problem(p, build)
    return p
end
local function solve_cascade(p, warm)
    if not SUBST then return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }, warm) end
    local reduced, reconstruction = substitution.reduce(p)
    local s, v, steps = harness.solve_to_completion(lp, reduced, { tolerance = TOL, iterate_limit = ITER }, warm)
    if s ~= "finished" or not v then return s, v, steps end
    return s, substitution.unfold(v, reconstruction), steps
end

local function rescue_target(constraints, lines, prob, x0, s0)
    local T0 = ref.total_of(prob, x0, ref.TARGET_KINDS)
    if T0 <= RESCUE_TRIGGER then return prob, x0, s0, nil end
    local p1 = build_ship(constraints, lines, nil, true)
    if not p1 then return prob, x0, s0, nil end
    local s1, v1 = solve(p1)
    if s1 ~= "finished" then return prob, x0, s0, nil end
    local tmin = ref.total_of(p1, v1.x, ref.TARGET_KINDS)
    if tmin >= T0 then return prob, x0, s0, nil end
    local limit = budget(tmin)
    local p2 = build_ship(constraints, lines, limit)
    if not p2 then return prob, x0, s0, nil end
    local s2, v2 = solve(p2)
    if s2 ~= "finished" or not v2.x then return prob, x0, s0, nil end
    return p2, v2.x, v2.s, limit
end

-- Drive the cascade to settlement with the given warm policy. `warm`=false ->
-- every build cold; `warm`=true -> production path (cascade.is_cold builds cold,
-- the rest warm off the immediately preceding solve). Returns the final x.
local function run_cascade(constraints, lines, warm)
    problem_generator.set_tie_break(TIE) -- baseline + rescue are heavy builds
    local prob = build_ship(constraints, lines, nil)
    if not prob then return nil end
    local s, v = solve(prob)
    if s ~= "finished" then return nil end
    local p, x, sl, rescue_budget = rescue_target(constraints, lines, prob, v.x, v.s)
    local raw = { x = x, s = sl }
    local cc = cascade.begin(p, raw, lines, rescue_budget)
    local prev_any = warm and raw or nil
    local guard = 0
    while cc.build do
        guard = guard + 1
        if guard > 2000 then return nil end
        local b = cc.build
        local bp = build_cascade(constraints, lines, b)
        if not bp then
            cascade.advance(cc, p, nil, "unfeasible")
        else
            local cold_this = cascade.is_cold(b) and not WARMALL
            -- Tie-break the heavy builds only; classification builds keep their
            -- EPS regularizer clean (and are cold in both runs anyway).
            problem_generator.set_tie_break(cascade.is_cold(b) and 0 or TIE)
            local seed = (warm and not cold_this) and prev_any or nil
            local bs, bv = solve_cascade(bp, seed)
            if warm and bs == "finished" and bv then prev_any = bv end
            cascade.advance(cc, bp, bv, bs)
            if cc.phase == "restore" then return cc.adopted_raw.x end
        end
    end
    return cc.adopted_raw.x
end

local function compare(xa, xb)
    local keys = {}
    for k in pairs(xa) do keys[k] = true end
    for k in pairs(xb) do keys[k] = true end
    local n, n_over, max_abs, max_rel, worst = 0, 0, 0, 0, "-"
    for k in pairs(keys) do
        n = n + 1
        local a, b = xa[k] or 0, xb[k] or 0
        local d = math.abs(a - b)
        if d > 1e-4 then n_over = n_over + 1 end
        if d > max_abs then max_abs, worst = d, k end
        local rel = d / (1 + math.max(math.abs(a), math.abs(b)))
        if rel > max_rel then max_rel = rel end
    end
    return n, n_over, max_abs, max_rel, worst
end

local function process(prob, label, emit)
    local lines = prob.normalized_lines
    local x_cold = run_cascade(prob.constraints, lines, false)
    local x_warm = run_cascade(prob.constraints, lines, true)
    if not x_cold or not x_warm then
        emit({ label = label, n_vars = -1, max_abs = -1, n_over = -1, max_rel = -1, worst = "FAIL" })
        return
    end
    local n, n_over, max_abs, max_rel, worst = compare(x_cold, x_warm)
    emit({ label = label, n_vars = n, max_abs = max_abs, n_over = n_over, max_rel = max_rel, worst = worst })
end

local COLS = { "label", "n_vars", "max_abs", "n_over", "max_rel", "worst" }
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
        local ok, err = pcall(process, prob, label, emit)
        if not ok then sink("# ERROR " .. label .. ": " .. tostring(err) .. "\n") end
    end
end
if out_file then out_file:close() end
