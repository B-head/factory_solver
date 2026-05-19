-- Shared helpers for the headless solver test suite.
--
-- The whole suite is plain Lua: it deliberately does not load any Factorio
-- runtime symbols (game, script, storage, prototypes, defines). The pieces
-- under test are solver/* and the pure-string parts of manage/typed_name —
-- everything else in the mod requires a live Factorio VM.

local M = {}

local default_tolerance = 1e-6
local default_iterate_limit = 200

-- Swap solver `print` for a buffer the caller can inspect (and optionally
-- replay on failure). `linear_programming.lua` captures `print` once into a
-- local `debug_print` at module load time, so we have to override the global
-- BEFORE requiring the solver. `tests/run.lua` does that.

M.captured_output = {}

function M.install_print_capture()
    M.captured_output = {}
    _G.print = function(...)
        local n = select("#", ...)
        local parts = {}
        for i = 1, n do
            parts[i] = tostring(select(i, ...))
        end
        table.insert(M.captured_output, table.concat(parts, "\t"))
    end
end

function M.reset_print_capture()
    M.captured_output = {}
end

function M.dump_captured(prefix)
    prefix = prefix or "    | "
    local out = {}
    for _, line in ipairs(M.captured_output) do
        for sub in tostring(line):gmatch("[^\n]+") do
            table.insert(out, prefix .. sub)
        end
    end
    return table.concat(out, "\n")
end

local function format_value(v)
    if type(v) == "number" then
        return string.format("%.10g", v)
    end
    return tostring(v)
end

function M.assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format(
            "%sexpected %s, got %s",
            msg and (msg .. ": ") or "",
            format_value(expected),
            format_value(actual)
        ), 2)
    end
end

function M.assert_true(cond, msg)
    if not cond then
        error(msg or "expected true, got falsy", 2)
    end
end

function M.assert_near(actual, expected, tol, msg)
    tol = tol or 1e-6
    if type(actual) ~= "number" or actual ~= actual then
        error(string.format(
            "%sexpected number near %s, got %s",
            msg and (msg .. ": ") or "",
            format_value(expected),
            format_value(actual)
        ), 2)
    end
    if math.abs(actual - expected) > tol then
        error(string.format(
            "%sexpected %s (±%g), got %s (diff %g)",
            msg and (msg .. ": ") or "",
            format_value(expected), tol,
            format_value(actual), actual - expected
        ), 2)
    end
end

function M.assert_matrix_near(actual, expected, tol, msg)
    tol = tol or 1e-9
    M.assert_eq(#actual, #expected, (msg or "matrix") .. " row count")
    for y = 1, #expected do
        M.assert_eq(#actual[y], #expected[y], (msg or "matrix") .. " row " .. y .. " width")
        for x = 1, #expected[y] do
            M.assert_near(actual[y][x], expected[y][x], tol,
                string.format("%s[%d][%d]", msg or "matrix", y, x))
        end
    end
end

---Drive `linear_programming.M.solve` from "ready" until a terminal state.
---@param lp table The required `solver/linear_programming` module.
---@param problem Problem
---@param opts { tolerance?: number, iterate_limit?: number }?
---@return SolverState terminal_state
---@return PackedVariables? raw_variables
---@return integer step_count
function M.solve_to_completion(lp, problem, opts)
    opts = opts or {}
    local tol = opts.tolerance or default_tolerance
    local limit = opts.iterate_limit or default_iterate_limit

    local state = "ready"
    local vars = nil
    local steps = 0
    while type(state) == "number" or state == "ready" do
        state, vars = lp.solve(problem, state, vars, tol, limit)
        steps = steps + 1
        if steps > limit + 4 then
            error("solver did not reach a terminal state within " .. limit .. " IPM iterations")
        end
    end
    return state, vars, steps
end

return M
