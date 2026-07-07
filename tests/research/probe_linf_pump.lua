---@diagnostic disable: undefined-global
-- End-to-end probe for the SHIPPED L-infinity state machine: drive the REAL
-- manage/pre_solve.lua forwerd_solve pump (target_rescue_step + linf_step and
-- the "ready" preserve list included) on one dumped problem with
-- solver_norm = "linf", exactly as the on_tick pump would.
--
-- This differs from probe_linf_ship.lua, which REPLICATES the dispatch by hand
-- (and always threaded target_budget into both stages -- the behaviour the
-- engine was supposed to have). This probe runs the engine's own orchestration,
-- so it catches state-machine bugs the replication can't: the 2026-07-08
-- lf_restart preserve-list omission livelocked the pump (rescue re-arming
-- mid-linf) on every rescue-firing problem while probe_linf_ship kept reporting
-- OK.
--
--   luajit tests/research/probe_linf_pump.lua <dumpfile>
-- Driver contract: single dump arg, prints one "RESULT ..." line, exit 0.
-- Fan out with tests/research/run_corpus.ps1 -Driver tests/research/probe_linf_pump.lua
--
-- Verdicts:
--   OK        settled ("finished", linf phase "done") within the step cap.
--   NOSETTLE  a stage ended on a non-finished terminal state (numerics, not
--             orchestration -- the pump correctly stops there).
--   LIVELOCK  still ready/calculating after the step cap (the preserve-list bug).
--   ERRORED   forwerd_solve raised.

require "tests/headless_env"
local pre_solve = require "manage/pre_solve"
local problem_dump = require "tests/problem_dump"

local path = arg[1]
if not path then
    io.stderr:write("usage: luajit tests/research/probe_linf_pump.lua <dumpfile>\n")
    os.exit(2)
end

local prob, kind = problem_dump.load_problem(path)
if not prob then
    print("RESULT file=" .. tostring(path) .. " verdict=LOAD_FAIL kind=" .. tostring(kind))
    os.exit(0)
end
local seedid = (path:match("seed_%d+")) or "?"
local fname = (path:match("[^/\\]+$")) or path

-- The dump carries already-normalized lines; bypass the prototype-reading
-- normalizer (forwerd_solve reaches it through the module table).
pre_solve.to_normalized_production_lines = function() return prob.normalized_lines end

local solution = {
    name = "linf-pump",
    constraints = prob.constraints,
    production_lines = {},
    solver_state = "ready",
    solver_norm = "linf",
}
local force_data = { research_bonuses = nil }

-- The pipeline is at most 6 solves (baseline + 3 rescue + 2 stages) x
-- iterate_limit (600) IPM steps; 6000 leaves headroom without letting a
-- livelock spin for minutes.
local MAX_STEPS = 6000
local rebuilds, steps = 0, 0
local verdict = nil
while solution.solver_state == "ready" or solution.solver_state == "calculating" do
    if solution.solver_state == "ready" then rebuilds = rebuilds + 1 end
    local ok, err = pcall(pre_solve.forwerd_solve, force_data, solution)
    if not ok then
        print(string.format("RESULT seed=%s file=%s verdict=ERRORED err=%s",
            seedid, fname, tostring(err):gsub("%s+", " ")))
        os.exit(0)
    end
    steps = steps + 1
    if steps > MAX_STEPS then
        verdict = "LIVELOCK"
        break
    end
end

local rescue = solution.target_rescue
local rescued = (rescue and rescue.budget) and 1 or 0
local linf_phase = solution.linf and solution.linf.phase or "nil"
local t_limit = solution.linf and solution.linf.t_limit or -1

-- Final target relaxation (physical: how much requested output was given up).
local relax = -1
if solution.raw_variables and solution.problem then
    relax = 0
    for key, p in pairs(solution.problem.primals) do
        if p.kind == "elastic" or p.kind == "headroom" then
            relax = relax + math.abs(solution.raw_variables.x[key] or 0)
        end
    end
end

if not verdict then
    if solution.solver_state == "finished" and linf_phase == "done" then
        verdict = "OK"
    else
        verdict = "NOSETTLE"
    end
end

print(string.format(
    "RESULT seed=%s file=%s verdict=%s state=%s linf=%s resc=%d rebuilds=%d steps=%d "
    .. "t_limit=%.6g relax=%.6g",
    seedid, fname, verdict, solution.solver_state, linf_phase, rescued, rebuilds, steps,
    t_limit, relax))
os.exit(0)
