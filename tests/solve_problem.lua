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

local path = arg[1]
if not path then
    io.stderr:write("usage: lua tests/solve_problem.lua <problem-file>\n")
    os.exit(2)
end

local chunk, load_err = loadfile(path)
if not chunk then
    print("ERROR " .. path .. " load: " .. tostring(load_err))
    os.exit(0)
end
local ok_load, prob = pcall(chunk)
if not ok_load or type(prob) ~= "table" or type(prob.meta) ~= "table" then
    print("ERROR " .. path .. " malformed problem file")
    os.exit(0)
end

local meta = prob.meta
local ok_cp, problem = pcall(create_problem.create_problem, "explore",
    prob.constraints, prob.normalized_lines)
if not ok_cp then
    print("ERROR seed=" .. tostring(meta.seed) .. " create_problem raised: " .. tostring(problem))
    os.exit(0)
end

-- Drive the IPM exactly as pre_solve.forwerd_solve / the in-engine explore loop
-- do: solve() advances one step per call, "ready" -> "calculating" -> terminal.
-- tolerance / iterate_limit / step_cap come from meta so they match the producer.
local state, iteration, vars = "ready", nil, nil
local steps = 0
repeat
    local ok_solve, s, it, v = pcall(linear_programming.solve, problem, state, iteration, vars,
        meta.tolerance, meta.iterate_limit)
    if not ok_solve then
        print("ERROR seed=" .. tostring(meta.seed) .. " solve raised: " .. tostring(s))
        os.exit(0)
    end
    state, iteration, vars = s, it, v
    steps = steps + 1
until (state ~= "ready" and state ~= "calculating") or steps > meta.step_cap

print(ed.format_result(meta, state, steps, ed.detect(vars)))
