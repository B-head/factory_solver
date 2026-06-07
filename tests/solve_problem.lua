---@diagnostic disable: undefined-global
-- (io/os/arg are stdlib globals; LuaLS is configured for the Factorio sandbox
--  where they are stripped, but this file only runs in a standalone Lua host.)

-- Chain-explorer worker: the consumer half of the Option A producer/consumer
-- split. The in-game producer (tests/chain_explorer.lua's explore_emit) writes
-- one problem per generated chain to script-output/explore_problems/<tag>.lua as
-- a loadable Lua table { meta, constraints, normalized_lines }. This standalone
-- `lua` process solves ONE such file through the pure solver core and prints the
-- same status line the in-engine explorer would, so the launcher pools many of
-- these across CPU cores while no Factorio is running.
--
-- The solver core is Factorio-free (tests/run.lua proves this); the only inputs
-- that needed prototype reads -- the normalized lines, the constraints, and the
-- solver knobs (tolerance / iterate_limit / step_cap) -- are baked into the
-- dumped file by the producer, so this path reproduces the in-engine solve
-- byte-for-byte. ed.detect + ed.format_result are the single shared source of
-- the HIT taxonomy, identical to the in-engine explore().
--
-- Usage (from the repo root so require paths resolve):
--   lua tests/solve_problem.lua <path-to-problem.lua>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local linear_programming = require "solver/linear_programming"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"

local path = arg[1]
if not path then
    io.stderr:write("usage: lua tests/solve_problem.lua <problem-file>\n")
    os.exit(2)
end

-- Load + validate the dump (shared with sweep_cost via problem_dump). The wording
-- and exit 0 (so the worker pool keeps draining its queue) are this consumer's.
local prob, kind, detail = problem_dump.load_problem(path)
if not prob then
    if kind == "load" then
        print("ERROR " .. path .. " load: " .. tostring(detail))
    else
        print("ERROR " .. path .. " malformed problem file")
    end
    os.exit(0)
end

local meta = prob.meta

-- Research ablation switches for create_problem's cycle-material escape-hatch
-- preprocessing (the produced-AND-consumed branch). Each env var defaults to ON
-- (the shipped behaviour); set it to "0" to disable that ONE mechanism and
-- re-solve the SAME dumped corpus, isolating its effect. env vars are read here
-- -- the Factorio-free worker -- because create_problem itself runs in-engine
-- where os is stripped and the lockstep path forbids non-deterministic reads.
-- explore_chains.ps1 launches these workers as child processes, so a CP_* set in
-- the launching shell propagates automatically; --ReuseProblems makes the A/B
-- comparison a fixed-corpus, solver-only-variable experiment.
local function env_off(name) return os.getenv(name) == "0" end
local cp_options = {
    deficit_seeding = not env_off("CP_DEFICIT_SEEDING"),
    catalyst_closure = not env_off("CP_CATALYST_CLOSURE"),
    reachability_gating = not env_off("CP_REACHABILITY_GATING"),
}

local ok_cp, problem = pcall(create_problem.create_problem, "explore",
    prob.constraints, prob.normalized_lines, nil, cp_options)
if not ok_cp then
    print("ERROR seed=" .. tostring(meta.seed) .. " create_problem raised: " .. tostring(problem))
    os.exit(0)
end

-- Drive the IPM to a terminal state (shared with sweep_cost via problem_dump):
-- solve() advances one step per call, "ready" -> "calculating" -> terminal, with
-- tolerance / iterate_limit / step_cap from meta so it matches the producer.
local state, steps, vars, solve_err = problem_dump.solve_dumped(linear_programming, problem, meta)
if solve_err then
    print("ERROR seed=" .. tostring(meta.seed) .. " solve raised: " .. solve_err)
    os.exit(0)
end

print(ed.format_result(meta, state, steps, ed.detect(vars, problem.primals)))
