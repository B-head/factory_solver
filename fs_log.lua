-- Leveled wrapper around Factorio's log(). Loggers are per-module so the
-- prefix in the output file tells you who emitted the line.
--
-- Usage:
--   local fs_log = require "fs_log"
--   local log = fs_log.for_module("solver.lp")
--   log.info("step %d: p=%f d=%f", step, p, d)
--   log.debug("primal: %s", problem:dump_primal(x))
--
-- Lockstep cost: the level check happens BEFORE string.format so a filtered
-- call only pays an integer compare. Keep format args side-effect-free even
-- so — every client runs every emit() call.

local M = {}

-- `trace` sits below `debug` for output that is too bulky to keep on by
-- default even when a developer asks for verbose logs — the per-solve A-matrix
-- dump in solver.lp is the motivating case. Opt-in only: even with
-- __DebugAdapter active the threshold starts at `debug`, so trace lines stay
-- silent until something calls `set_level("trace")`.
local LEVELS = { trace = 1, debug = 2, info = 3, warn = 4, error = 5 }
local LEVEL_PREFIXES = { "TRACE", "DEBUG", "INFO", "WARN", "ERROR" }

local threshold = rawget(_G, "__DebugAdapter") and LEVELS.debug or LEVELS.info

-- Factorio supplies `log` as a global in the data, settings, and control
-- stages; the headless test harness has neither, so we fall back to `print`
-- so this module is requireable in any context.
local default_sink = rawget(_G, "log") or print
local sink = default_sink

---Set the minimum level that reaches the sink. Levels strictly below this
---are dropped before any formatting work.
---@param name "trace" | "debug" | "info" | "warn" | "error"
function M.set_level(name)
    local n = LEVELS[name]
    assert(n, "fs_log: unknown level " .. tostring(name))
    threshold = n
end

---@return "trace" | "debug" | "info" | "warn" | "error"
function M.get_level()
    return LEVEL_PREFIXES[threshold]:lower()
end

---Replace the underlying sink. Pass `nil` to restore the default
---(`log` in Factorio, `print` in the headless test harness). Intended for
---tests that need to capture emissions; production code should not call this.
---@param fn fun(line: string)?
function M.set_sink(fn)
    sink = fn or default_sink
end

local function emit(level_num, module_name, fmt, ...)
    if level_num < threshold then return end
    local body
    if select("#", ...) == 0 then
        body = fmt
    else
        body = string.format(fmt, ...)
    end
    sink(string.format("[fs/%s] %s: %s", LEVEL_PREFIXES[level_num], module_name, body))
end

---@class FsLogger
---@field trace fun(fmt: string, ...: any)
---@field debug fun(fmt: string, ...: any)
---@field info  fun(fmt: string, ...: any)
---@field warn  fun(fmt: string, ...: any)
---@field error fun(fmt: string, ...: any)

---Build a logger bound to a module name. The returned table exposes one
---method per level; calls below the active threshold short-circuit before
---formatting.
---@param module_name string
---@return FsLogger
function M.for_module(module_name)
    return {
        trace = function(fmt, ...) emit(1, module_name, fmt, ...) end,
        debug = function(fmt, ...) emit(2, module_name, fmt, ...) end,
        info  = function(fmt, ...) emit(3, module_name, fmt, ...) end,
        warn  = function(fmt, ...) emit(4, module_name, fmt, ...) end,
        error = function(fmt, ...) emit(5, module_name, fmt, ...) end,
    }
end

return M
