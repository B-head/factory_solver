---@diagnostic disable: undefined-global
-- Sweep the flat recipe_epsilon across a ladder and, for each value, measure how
-- far the solution moves from the shipped 2^-10 baseline -- the "blast radius"
-- of each choice -- while confirming the move stays a legitimate canonical-vertex
-- re-selection (optimal for its own cost), not a numerical failure.
--
-- Focus value: 2^-7 (~0.0078), the in-window alternative (the safe epsilon band
-- is 1e-4..1e-2; 2^-6 = 0.0156 sits just above it, 2^-10 is the shipped floor).
--
-- recipe_epsilon changes ONLY the cost vector, never the constraint matrix or
-- variable set, so every solve shares variable keys: cross-pricing a solution
-- under another epsilon's cost is a straight lookup, and a feasible point for one
-- build is feasible for all.
--
-- Single-shot run_corpus worker.
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_eps_sweep.lua -Collect '^ESW\|' -Out s:\tmp\esw.txt

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local linear_programming = require "solver/linear_programming"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"

-- baseline first; the rest are the ladder up to the out-of-window 2^-6.
local LADDER = { { e = 2 ^ -10, tag = "e10" }, { e = 2 ^ -9, tag = "e9" },
    { e = 2 ^ -8, tag = "e8" }, { e = 2 ^ -7, tag = "e7" }, { e = 2 ^ -6, tag = "e6" } }

local path = arg[1]
if not path then io.stderr:write("usage: ... <problem-file>\n"); os.exit(2) end
local prob, kind = problem_dump.load_problem(path)
if not prob then print("# ERROR " .. tostring(path) .. " " .. tostring(kind)); os.exit(0) end
local meta = prob.meta
local tag = path:gsub("[\\/]", "/"):match("([^/]+)%.lua$") or path

local function solve(eps)
    local opts = { deficit_seeding = true, catalyst_closure = true,
        reachability_gating = true, surplus_sink_gating = false, recipe_epsilon = eps }
    local ok, problem = pcall(create_problem.create_problem, "explore",
        prob.constraints, prob.normalized_lines, nil, opts)
    if not ok then return nil end
    local state, steps, vars, err = problem_dump.solve_dumped(linear_programming, problem, meta)
    if err then return nil end
    return { problem = problem, state = state, steps = steps, vars = vars,
        detect = ed.detect(vars, problem.primals) }
end

-- relative recipe-flow distance between two solves.
local function relshift(P, Q)
    local keys = {}
    for k in pairs(P.vars.x or {}) do if ed.is_recipe(k, P.problem.primals) then keys[k] = true end end
    for k in pairs(Q.vars.x or {}) do if ed.is_recipe(k, Q.problem.primals) then keys[k] = true end end
    local diff, base = 0, 0
    for k in pairs(keys) do
        diff = diff + math.abs((math.abs((P.vars.x or {})[k] or 0)) - (math.abs((Q.vars.x or {})[k] or 0)))
        base = base + math.abs((P.vars.x or {})[k] or 0)
    end
    return base > 0 and diff / base or 0
end

-- on/off recipe-set flip count between two solves (each vs its own park floor).
local function flips(P, Q)
    local function onset(S)
        local th = ed.park_threshold(S.vars, S.problem.primals); local s = {}
        for k, v in pairs(S.vars.x or {}) do
            if ed.is_recipe(k, S.problem.primals) and math.abs(v) > th then s[k] = true end
        end
        return s
    end
    local a, b = onset(P), onset(Q)
    local n = 0
    for k in pairs(a) do if not b[k] then n = n + 1 end end
    for k in pairs(b) do if not a[k] then n = n + 1 end end
    return n
end

-- objective of `vars` priced under `pricing_problem`'s cost vector (same keys).
local function objective(vars, pricing_problem)
    local total = 0
    for k, v in pairs(vars.x or {}) do
        local p = pricing_problem.primals[k]
        total = total + (p and p.cost or 0) * (v > 0 and v or 0)
    end
    return total
end

local sols = {}
for _, L in ipairs(LADDER) do
    sols[L.tag] = solve(L.e)
    if not sols[L.tag] then print("# ERROR " .. tag .. " solve " .. L.tag .. " failed"); os.exit(0) end
end

local base = sols.e10
local fields = { "ESW|" .. tag, string.format("conv_base=%d", base.state == "finished" and 1 or 0) }
for i = 2, #LADDER do
    local L = LADDER[i]
    local S = sols[L.tag]
    -- regret of THIS eps's solution under ITS OWN cost vs the baseline point
    -- priced the same way: >=0 means S is optimal for its own cost (legitimate
    -- re-selection); a negative value beyond tolerance would be a numerical loss.
    local objS = objective(S.vars, S.problem)
    local objBaseUnderS = objective(base.vars, S.problem)
    local regret = objBaseUnderS - objS
    local relRegret = objS ~= 0 and regret / math.abs(objS) or 0
    fields[#fields + 1] = string.format(
        "%s:rel=%.4g,flip=%d,relreg=%.4g,dcheat=%.4g",
        L.tag, relshift(base, S), flips(base, S), relRegret, S.detect.cheat - base.detect.cheat)
end
print(table.concat(fields, "|"))
