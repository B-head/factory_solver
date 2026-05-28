-- Verify the leveled logger gates correctly and renders the expected shape.
-- The Factorio `log` global is absent in this harness; fs_log falls back to
-- print on require, and the tests then swap in a buffering sink.

local harness = require "tests/harness"
local fs_log = require "fs_log"

local cases = {}

---Run `fn`, capturing every emitted line into a buffer. Restores the sink
---and threshold afterwards so tests do not leak state into each other.
---@param fn fun(lines: string[])
---@return string[]
local function with_capture(fn)
    local lines = {}
    local prev_level = fs_log.get_level()
    fs_log.set_sink(function(line) table.insert(lines, line) end)
    local ok, err = pcall(fn, lines)
    fs_log.set_sink(nil)
    fs_log.set_level(prev_level)
    if not ok then error(err, 2) end
    return lines
end

table.insert(cases, {
    name = "info-level messages reach the sink with the expected shape",
    run = function()
        local lines = with_capture(function()
            fs_log.set_level("info")
            local log = fs_log.for_module("test.shape")
            log.info("hello %s = %d", "answer", 42)
        end)
        harness.assert_eq(#lines, 1, "one line emitted")
        local line = lines[1]
        harness.assert_true(line:find("INFO", 1, true) ~= nil, "level marker present")
        harness.assert_true(line:find("test.shape", 1, true) ~= nil, "module name present")
        harness.assert_true(line:find("hello answer = 42", 1, true) ~= nil, "formatted body")
    end,
})

table.insert(cases, {
    name = "level threshold gates emissions strictly below it",
    run = function()
        local lines = with_capture(function()
            fs_log.set_level("warn")
            local log = fs_log.for_module("test.gate")
            log.debug("d")
            log.info("i")
            log.warn("w")
            log.error("e")
        end)
        harness.assert_eq(#lines, 2, "only warn and error pass")
        harness.assert_true(lines[1]:find("WARN", 1, true) ~= nil, "first line is warn")
        harness.assert_true(lines[2]:find("ERROR", 1, true) ~= nil, "second line is error")
    end,
})

table.insert(cases, {
    name = "filtered calls do not invoke string.format",
    -- A format string with %s but no corresponding arg would raise inside
    -- string.format. If the level gate runs first the call must be a no-op,
    -- so this test passing means lazy evaluation is intact.
    run = function()
        with_capture(function()
            fs_log.set_level("info")
            local log = fs_log.for_module("test.lazy")
            log.debug("%s")
        end)
    end,
})

table.insert(cases, {
    name = "set_level rejects unknown names",
    run = function()
        local ok = pcall(fs_log.set_level, "verbose")
        harness.assert_true(not ok, "set_level('verbose') should error")
    end,
})

table.insert(cases, {
    name = "trace sits below debug and is opt-in",
    -- Default threshold is `debug` (under __DebugAdapter) or `info`, so trace
    -- lines must stay silent unless explicitly enabled, and once enabled
    -- they render with a TRACE marker.
    run = function()
        local lines = with_capture(function()
            fs_log.set_level("debug")
            local log = fs_log.for_module("test.trace")
            log.trace("hidden")
            log.debug("visible")
        end)
        harness.assert_eq(#lines, 1, "trace dropped at debug threshold")
        harness.assert_true(lines[1]:find("DEBUG", 1, true) ~= nil, "the surviving line is debug")

        lines = with_capture(function()
            fs_log.set_level("trace")
            local log = fs_log.for_module("test.trace")
            log.trace("now %d", 7)
            log.debug("also visible")
        end)
        harness.assert_eq(#lines, 2, "both lines pass at trace threshold")
        harness.assert_true(lines[1]:find("TRACE", 1, true) ~= nil, "trace marker present")
        harness.assert_true(lines[1]:find("now 7", 1, true) ~= nil, "trace body formatted")
    end,
})

return cases
