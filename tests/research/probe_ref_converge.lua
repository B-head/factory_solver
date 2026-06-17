---@diagnostic disable: undefined-global
-- Single-shot: measure reference-solver CONVERGENCE per dump under candidate fixes
-- for the budget-lock near-zero-slack stall (see reference_solver.lua M.BUDGET_ABS).
-- Configs:
--   base   current      (BUDGET_ABS=1e-6, TOL=1e-7)
--   babs5  budget floor  (BUDGET_ABS=1e-5, TOL=1e-7)  -- relieve near-zero slack
--   tol5   loose tol     (BUDGET_ABS=1e-6, TOL=1e-5)  -- global precision drop
-- Prints one row: seed=<file>\t<cfg>=<finished|state>:<M> ...   (M for correctness
-- spot-check -- a config that "converges" to a collapsed M is not a real win).
--
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_ref_converge.lua -Collect '^seed=' -Out <tsv>
require "tests/headless_env"

local problem_dump = require "tests/problem_dump"
local ref = require "tests/research/reference_solver"

local path = assert(arg[1], "usage: lua probe_ref_converge.lua <dump>")
local name = path:gsub("[\\/]+$", ""):match("([^\\/]+)%.lua$") or path

local prob, kind, detail = problem_dump.load_problem(path)
if not prob then
    print(string.format("seed=%s\tLOAD-ERROR:%s:%s", name, tostring(kind), tostring(detail)))
    return
end

local CONFIGS = {
    { tag = "base",  tol = 1e-7, abs = 1e-6 },
    { tag = "babs5", tol = 1e-7, abs = 1e-5 },
    { tag = "tol5",  tol = 1e-5, abs = 1e-6 },
}

local cells = { "seed=" .. name }
for _, c in ipairs(CONFIGS) do
    ref.TOL = c.tol
    ref.BUDGET_ABS = c.abs
    ref.BUDGET_REL = 1e-3
    local ok, r = pcall(ref.solve_reference, prob.constraints, prob.normalized_lines)
    if ok then
        local m = (r.state == "finished") and string.format("%.6g", r.M) or "-"
        cells[#cells + 1] = string.format("%s=%s:%s", c.tag, r.state, m)
    else
        cells[#cells + 1] = string.format("%s=PCALL-ERR:-", c.tag)
    end
end
print(table.concat(cells, "\t"))
