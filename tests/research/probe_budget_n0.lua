---@diagnostic disable: undefined-global
-- Cheap: baseline active-boundary count with vs without the target-rescue lock,
-- to see how much the shipped-style lock spreads the import (and how many dumps
-- exceed PERTCAP=60, which would make the full mode-compress run truncation-noisy).
--   lua tests/research/probe_budget_n0.lua <dump>   (run via run_corpus.ps1 -Collect '^bn')
require "tests/headless_env"
local R = require "tests/research/research_lib"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local VQ, VF, EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10
local PATH = arg[1]; local fid = (PATH or "?"):match("[^/\\]+$") or "?"
local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("bn ERR=load seed=" .. fid .. "\n"); return end
local BUDGET
local function build()
    local o = { reachability_gating = false, deficit_seeding = false, catalyst_closure = false,
        surplus_sink_gating = false, recipe_epsilon = EPS }
    if BUDGET then o.target_budget = BUDGET end
    local p = cp.create_problem("l2", prob.constraints, prob.normalized_lines, nil, o)
    cp.shape_l2(p, VQ, VF); return p
end
local function phys(p, k, x) local pr, t = p.primals[k], p.subject_terms[k]; local c = (pr and pr.material and t and t[pr.material]) or 1; return math.abs(c * (x[k] or 0)) end
local function nact(p, x) local n = 0 for k, pr in pairs(p.primals) do if (pr.kind == "shortage_source" or pr.kind == "surplus_sink") and phys(p, k, x) > 1e-6 then n = n + 1 end end return n end
local p0 = build(); local x0, s0 = R.drive_solve(p0, prob.meta)
if s0 ~= "finished" then io.write("bn st=" .. tostring(s0) .. " seed=" .. fid .. "\n"); return end
local T0 = 0
for k, pr in pairs(p0.primals) do if pr.kind == "elastic" or pr.kind == "headroom" then T0 = T0 + math.abs(x0[k] or 0) end end
local n_unlocked = nact(p0, x0)
BUDGET = T0 * (1 + 1e-3) + 1e-6
local p1 = build(); local x1, s1 = R.drive_solve(p1, prob.meta)
local n_locked = (s1 == "finished") and nact(p1, x1) or -1
io.write(("bn T0=%.6g n_unlocked=%d n_locked=%d locked_st=%s seed=%s\n"):format(T0, n_unlocked, n_locked, tostring(s1), fid))
