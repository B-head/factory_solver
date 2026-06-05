-- Shared loader + solve loop for explorer-dumped problem files.
--
-- The in-game producer (tests/chain_explorer.lua's explore_emit) writes one
-- problem per generated chain to script-output as a loadable Lua table
-- { meta, constraints, normalized_lines }. Two standalone `lua` consumers read
-- those files -- tests/solve_problem.lua (the worker-pool consumer) and
-- tests/sweep_cost.lua (the cost-sensitivity driver). Both did the exact same
-- two things by hand: load+validate the dump, and drive the IPM from "ready"
-- to a terminal state. This module is that shared pair.
--
-- The functions deliberately return raw status/error VALUES rather than
-- printing or exiting: the two callers diverge on error wording and exit codes
-- (solve_problem prints "ERROR seed=..." and exits 0 so the pool keeps going;
-- sweep_cost calls die() with exit 1/2), so each builds its own message from
-- the returned kind/detail. Keeping that here would force one wording on both.
--
-- NOTE: this is NOT tests/harness.lua's solve_to_completion. That one is a test
-- assertion: it raises on a runaway solve and caps at iterate_limit+4. This one
-- is for the open-ended explorer: it breaks gracefully at meta.step_cap and
-- never raises, so a pathological chain yields a HIT line instead of aborting
-- the sweep. The two semantics are opposite on purpose; do not merge them.
--
-- Requires that tests/headless_env has already set package.path (the caller
-- requires it first), so this module can require "solver/..." through it.

local M = {}

---Load and validate an explorer-dumped problem file. Does NOT print or exit --
---the caller formats its own message from `kind`/`detail` (the two consumers
---use different wording and exit codes). The problem table is the first return
---so `if not problem then ...` narrows it cleanly for the caller.
---@param path string Path to the dumped { meta, constraints, normalized_lines } file.
---@return table? problem The loaded table on success, nil on failure.
---@return string? kind "load" (loadfile failed) | "malformed" (not a problem table) on failure; nil on success.
---@return string? detail The underlying loadfile/pcall error string when kind == "load".
function M.load_problem(path)
    local chunk, load_err = loadfile(path)
    if not chunk then
        return nil, "load", tostring(load_err)
    end
    local ok, prob = pcall(chunk)
    if not ok or type(prob) ~= "table" or type(prob.meta) ~= "table" then
        return nil, "malformed", nil
    end
    return prob
end

---Drive the IPM exactly as pre_solve.forwerd_solve / the in-engine explore loop
---do: solve() advances one step per call, "ready" -> "calculating" -> terminal.
---tolerance / iterate_limit / step_cap come from `meta` so the headless solve
---matches the producer's knobs. Breaks gracefully at meta.step_cap and never
---raises; a solve() error is returned via `err` for the caller to report.
---@param lp table The required `solver/linear_programming` module.
---@param problem Problem The built problem (from create_problem.create_problem).
---@param meta { tolerance: number, iterate_limit: integer, step_cap: integer }
---@return string state Terminal solver_state; the sentinel "errored" if solve() raised (the caller checks `err` and never reads this on that path).
---@return integer steps IPM steps taken.
---@return PackedVariables? vars The solved variable set (nil if solve() raised).
---@return string? err The solve() error string when it raised; nil otherwise.
function M.solve_dumped(lp, problem, meta)
    local state, iteration, vars = "ready", nil, nil
    local steps = 0
    repeat
        local ok, s, it, v = pcall(lp.solve, problem, state, iteration, vars,
            meta.tolerance, meta.iterate_limit)
        if not ok then
            return "errored", steps, nil, tostring(s)
        end
        state, iteration, vars = s, it, v
        steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > meta.step_cap
    return state, steps, vars
end

return M
