---@diagnostic disable: undefined-global
-- Paired A/B comparison of the flat recipe_epsilon tier.
--
-- Hypothesis under test (user, 2026-06-12): when a problem's effective cost
-- range exceeds the IPM's working precision (~1e26 was the figure floated), the
-- bottom-tier recipe_epsilon (2^-10) drops below the floating-point floor of the
-- normal-equations system and effectively VANISHES -- so it no longer collapses
-- futile / net-zero recipe flow. Raising it to 2^-6 (16x larger) should restore
-- the collapse on exactly those high-range problems if the hypothesis holds.
--
-- This driver is a single-shot run_corpus worker: it loads ONE dumped problem,
-- builds + solves it TWICE in the same process -- once with the shipped
-- recipe_epsilon (2^-10) and once with the override (2^-6) -- and emits one
-- pipe-delimited "EPS|..." line carrying both outcomes plus per-problem scale
-- proxies, so a corpus pass needs no fragile tag-join across two source trees.
--
--   lua tests/research/probe_eps_compare.lua <problem-file>
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_eps_compare.lua -Collect '^EPS\|' -Out s:\tmp\eps.txt

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local linear_programming = require "solver/linear_programming"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"

local EPS_A = 2 ^ -10  -- shipped baseline
local EPS_B = 2 ^ -6   -- the experiment

local path = arg[1]
if not path then
    io.stderr:write("usage: lua tests/research/probe_eps_compare.lua <problem-file>\n")
    os.exit(2)
end

local prob, kind, detail = problem_dump.load_problem(path)
if not prob then
    print("# ERROR " .. tostring(path) .. " " .. tostring(kind) .. " " .. tostring(detail))
    os.exit(0)
end
local meta = prob.meta
local tag = path:gsub("[\\/]", "/"):match("([^/]+)%.lua$") or path

-- Shipped escape-hatch preprocessing, every mechanism on (matches solve_problem.lua
-- defaults). The ONLY variable across the two solves is recipe_epsilon.
local function build_and_solve(eps)
    local opts = {
        deficit_seeding = true,
        catalyst_closure = true,
        reachability_gating = true,
        surplus_sink_gating = false,
        recipe_epsilon = eps,
    }
    local ok, problem = pcall(create_problem.create_problem, "explore",
        prob.constraints, prob.normalized_lines, nil, opts)
    if not ok then return nil, "create:" .. tostring(problem) end
    local state, steps, vars, err = problem_dump.solve_dumped(linear_programming, problem, meta)
    if err then return nil, "solve:" .. err end
    return { problem = problem, state = state, steps = steps, vars = vars }
end

local A, ea = build_and_solve(EPS_A)
local B, eb = build_and_solve(EPS_B)
if not A then print("# ERROR " .. tag .. " A " .. ea); os.exit(0) end
if not B then print("# ERROR " .. tag .. " B " .. eb); os.exit(0) end

local dA = ed.detect(A.vars, A.problem.primals)
local dB = ed.detect(B.vars, B.problem.primals)

-- Objective cost range actually present in the built LP (verifies that the
-- *objective* cost spread is fixed ~2^30 regardless of problem; the real dynamic
-- range that could swamp eps lives in the A-matrix amounts, proxied separately).
local function cost_range(problem)
    local lo, hi = math.huge, 0
    for _, p in pairs(problem.primals) do
        local c = p.cost
        if c and c > 0 then
            if c < lo then lo = c end
            if c > hi then hi = c end
        end
    end
    if lo == math.huge or lo == 0 then return 0 end
    return hi / lo
end

-- Solution-side dynamic range: max active recipe flow / min active recipe flow.
-- A wide spread is the situation where a small additive eps on a small-flow
-- recipe is most at risk of being lost against a large-flow recipe in the
-- shared normal-equations system.
local function active_x_range(problem, vars)
    local lo, hi = math.huge, 0
    local th = ed.park_threshold(vars, problem.primals)
    for k, v in pairs(vars.x or {}) do
        if ed.is_recipe(k, problem.primals) then
            local a = math.abs(v)
            if a > th then
                if a < lo then lo = a end
                if a > hi then hi = a end
            end
        end
    end
    if lo == math.huge or lo == 0 then return 0 end
    return hi / lo
end

-- Structural change: how many recipe variables flip on<->off between the two
-- solves (each judged against its OWN solve's park threshold). This is the
-- sharpest "did raising eps change the factory" signal -- a futile recipe that
-- 2^-10 failed to collapse but 2^-6 collapsed shows up here.
local function on_set(problem, vars)
    local th = ed.park_threshold(vars, problem.primals)
    local set = {}
    for k, v in pairs(vars.x or {}) do
        if ed.is_recipe(k, problem.primals) and math.abs(v) > th then
            set[k] = true
        end
    end
    return set
end
local onA, onB = on_set(A.problem, A.vars), on_set(B.problem, B.vars)
local flips_off, flips_on = 0, 0  -- on in A but off in B / off in A but on in B
for k in pairs(onA) do if not onB[k] then flips_off = flips_off + 1 end end
for k in pairs(onB) do if not onA[k] then flips_on = flips_on + 1 end end

-- Relative flow shift across all recipe variables: sum|xA-xB| / sum xA. Catches
-- quantitative redistribution even when the on/off set is unchanged.
local sum_abs_diff, sum_a = 0, 0
local allk = {}
for k in pairs(A.vars.x or {}) do if ed.is_recipe(k, A.problem.primals) then allk[k] = true end end
for k in pairs(B.vars.x or {}) do if ed.is_recipe(k, B.problem.primals) then allk[k] = true end end
for k in pairs(allk) do
    local va = math.abs((A.vars.x or {})[k] or 0)
    local vb = math.abs((B.vars.x or {})[k] or 0)
    sum_abs_diff = sum_abs_diff + math.abs(va - vb)
    sum_a = sum_a + va
end
local rel_shift = sum_a > 0 and sum_abs_diff / sum_a or 0

local function conv(s) return s == "finished" and 1 or 0 end

-- One machine-readable line. Fields are pipe-delimited; downstream aggregation
-- reads by position.
print(string.format(
    "EPS|%s|cr=%.3g|xr=%.3g|" ..
    "A:conv=%d,steps=%d,R=%d,act=%d,nz=%d,cheat=%.4g,noship=%s|" ..
    "B:conv=%d,steps=%d,R=%d,act=%d,nz=%d,cheat=%.4g,noship=%s|" ..
    "d:flips_off=%d,flips_on=%d,dact=%d,dsteps=%d,relshift=%.4g,dcheat=%.4g",
    tag, cost_range(A.problem), active_x_range(A.problem, A.vars),
    conv(A.state), A.steps, dA.recipes, dA.active, dA.near_zero, dA.cheat, dA.noship and "1" or "0",
    conv(B.state), B.steps, dB.recipes, dB.active, dB.near_zero, dB.cheat, dB.noship and "1" or "0",
    flips_off, flips_on, dB.active - dA.active, B.steps - A.steps, rel_shift, dB.cheat - dA.cheat))
