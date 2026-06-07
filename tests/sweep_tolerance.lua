---@diagnostic disable: undefined-global
-- (io/os/arg are stdlib globals stripped in the Factorio sandbox LuaLS targets;
--  this file only runs in a standalone Lua host.)

-- Tolerance-sweep driver (research, NOT a pass/fail gate). Re-solves ONE
-- explorer-dumped problem (tests/chain_explorer.lua's explore_emit output) at
-- several IPM tolerances and prints a TSV row per tolerance: convergence state,
-- IPM step count, and the recipe-variable degeneracy (interior-point "dust")
-- distribution. A sweep over a large pyanodon problem set then answers "can the
-- tolerance be tightened?" -- does it still converge, at what iteration cost, and
-- how much dust survives at each tier.
--
-- Each tolerance gets a FRESH create_problem + cold IPM (no warm-start carryover
-- between tolerances), so the rows are independent. iterate_limit / step_cap are
-- overridden generously so a non-"finished" state means the solve genuinely could
-- not converge at that tolerance, not that it ran out of the explorer's budget.
--
-- Degeneracy is reported as raw bucket counts over the result recipe variables,
-- no good/bad labelling -- the distribution shift across tolerance is the signal.
--
-- Usage (from repo root): lua tests/sweep_tolerance.lua <problem.lua> <tol,tol,...>
--   The tolerance list may also come from the SWEEP_TOLS env var (so a parallel
--   `xargs -P` pool can append just the file as the sole argument).
-- Columns (tab-separated):
--   tag  seed  tol  state  steps  n_recipe  active  d2_4  d4_6  d6_9
--     active = x>=1e-2 ; d2_4 = [1e-4,1e-2) ; d4_6 = [1e-6,1e-4) ; d6_9 = [1e-9,1e-6)

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local problem_dump = require "tests/problem_dump"

local path = arg[1]
local tol_arg = arg[2] or os.getenv("SWEEP_TOLS")
if not path or not tol_arg then
    io.stderr:write("usage: lua tests/sweep_tolerance.lua <problem-file> <tol,tol,...>\n")
    io.stderr:write("       (or set SWEEP_TOLS env and pass just the file)\n")
    os.exit(2)
end

local tolerances = {}
for t in tol_arg:gmatch("[^,]+") do
    tolerances[#tolerances + 1] = assert(tonumber(t), "bad tolerance: " .. t)
end

local prob, kind, detail = problem_dump.load_problem(path)
if not prob then
    io.stderr:write("ERROR " .. path .. " " .. tostring(kind) .. " " .. tostring(detail) .. "\n")
    os.exit(0)
end
local meta = prob.meta
local tag = tostring(meta.tag or meta.seed or path)
local seed = tostring(meta.seed or "?")

-- Generous fixed budgets so a non-converged state is real, not budget-starved.
local SWEEP_ITERATE_LIMIT = 4000
local SWEEP_STEP_CAP = 4010

for _, tol in ipairs(tolerances) do
    local ok_cp, problem = pcall(create_problem.create_problem, "sweep",
        prob.constraints, prob.normalized_lines)
    if not ok_cp then
        io.stderr:write("ERROR seed=" .. seed .. " create_problem raised: " .. tostring(problem) .. "\n")
        os.exit(0)
    end

    local state, steps, vars = problem_dump.solve_dumped(lp, problem, {
        tolerance = tol,
        iterate_limit = SWEEP_ITERATE_LIMIT,
        step_cap = SWEEP_STEP_CAP,
    })

    local n_recipe, active, d2_4, d4_6, d6_9 = 0, 0, 0, 0, 0
    local x = vars and vars.x or {}
    for key, p in pairs(problem.primals) do
        if p.kind == "recipe" and p.is_result then
            n_recipe = n_recipe + 1
            local v = x[key] or 0
            if v >= 1e-2 then
                active = active + 1
            elseif v >= 1e-4 then
                d2_4 = d2_4 + 1
            elseif v >= 1e-6 then
                d4_6 = d4_6 + 1
            elseif v >= 1e-9 then
                d6_9 = d6_9 + 1
            end
        end
    end

    print(string.format("%s\t%s\t%g\t%s\t%d\t%d\t%d\t%d\t%d\t%d",
        tag, seed, tol, state, steps, n_recipe, active, d2_4, d4_6, d6_9))
end
