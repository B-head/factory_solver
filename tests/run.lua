---@diagnostic disable: undefined-global
-- (io/os/arg are stdlib globals; LuaLS is configured for the Factorio sandbox
--  where they are stripped, but this file only runs in a standalone Lua host.)

-- Headless test entry point for the pure-Lua solver pipeline.
--
-- Usage (run from the repo root so the require paths resolve):
--   lua tests/run.lua             -- run every case, terse output
--   lua tests/run.lua -v          -- also print captured solver dumps
--   lua tests/run.lua short_loop  -- run only cases whose file name matches
--
-- Lua 5.2+ or LuaJIT is required. The solver code targets the language subset
-- shared by Factorio's vendored Lua 5.2.1, so any modern standalone Lua works.
-- Install on Windows via `winget install DEVCOM.Lua`, `scoop install lua`, or
-- the binaries at https://luabinaries.sourceforge.net/.

-- Make `require "solver/foo"` and `require "manage/foo"` resolve against the
-- repo root. The trailing semicolons keep the standard search path as a
-- fallback (so `require "tests/harness"` also works).
package.path = "./?.lua;./?/init.lua;" .. package.path

local harness = require "tests/harness"
harness.install_log_capture()

local verbose = false
local filter = nil
for _, a in ipairs(arg) do
    if a == "-v" or a == "--verbose" then
        verbose = true
    elseif a:sub(1, 1) == "-" then
        io.stderr:write("unknown flag: " .. a .. "\n")
        os.exit(2)
    else
        filter = a
    end
end

-- Static registry of case files. Add new files here when introducing them —
-- explicit is friendlier to grep than directory scanning, and we don't have
-- LuaFileSystem available portably.
local case_files = {
    "csr_basics",
    "lp_direct",
    "lp_short_loop",
    "lp_quality_cascade",
    "lp_quality_recycling_loop",
    "fs_log",
    "typed_name_format",
    "lp_fluid_bridge",
    "lp_fluid_constraint",
    "isolated_line",
    "lp_scale_invariance",
    "lp_tiebreak",
    "material_cycles",
}

local total, passed, failed = 0, 0, 0
local failures = {}

for _, file in ipairs(case_files) do
    if filter and not file:find(filter, 1, true) then
        goto continue
    end

    local cases = require("tests/cases/" .. file)
    for _, case in ipairs(cases) do
        total = total + 1
        harness.reset_log_capture()

        local ok, err = pcall(case.run)
        -- xfail cases document a behaviour the solver does *not* yet have
        -- (e.g. preferring the material-efficient recipe among degenerate
        -- optima). They are expected to fail today; an unexpected pass
        -- (XPASS) means the spec is now satisfied and the case should be
        -- promoted to a normal assertion -- so XPASS is treated as failure.
        if case.xfail then
            if ok then
                failed = failed + 1
                io.write(string.format("  XPASS[%s] %s (expected failure but passed -- promote to normal case)\n",
                    file, case.name))
                table.insert(failures, string.format("[%s] %s (XPASS)", file, case.name))
            else
                passed = passed + 1
                io.write(string.format("  xfail[%s] %s\n", file, case.name))
                if verbose then
                    io.write("    (expected failure) ", tostring(err), "\n")
                    local dump = harness.dump_captured()
                    if dump ~= "" then
                        io.write(dump, "\n")
                    end
                end
            end
        elseif ok then
            passed = passed + 1
            io.write(string.format("  ok   [%s] %s\n", file, case.name))
            if verbose then
                local dump = harness.dump_captured()
                if dump ~= "" then
                    io.write(dump, "\n")
                end
            end
        else
            failed = failed + 1
            io.write(string.format("  FAIL [%s] %s\n", file, case.name))
            io.write("    ", tostring(err), "\n")
            local dump = harness.dump_captured()
            if dump ~= "" then
                io.write(dump, "\n")
            end
            table.insert(failures, string.format("[%s] %s", file, case.name))
        end
    end

    ::continue::
end

io.write(string.format("\n%d total, %d passed, %d failed\n", total, passed, failed))

if failed > 0 then
    io.write("\nFailed cases:\n")
    for _, f in ipairs(failures) do
        io.write("  " .. f .. "\n")
    end
    os.exit(1)
end

if total == 0 then
    io.stderr:write("no cases matched filter: " .. tostring(filter) .. "\n")
    os.exit(2)
end
