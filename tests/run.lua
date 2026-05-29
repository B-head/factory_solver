---@diagnostic disable: undefined-global
-- (io/os/arg are stdlib globals; LuaLS is configured for the Factorio sandbox
--  where they are stripped, but this file only runs in a standalone Lua host.)

-- Headless test entry point for the pure-Lua solver pipeline.
--
-- Why headless: solver/* has no Factorio runtime dependencies (no game,
-- script, storage, prototypes), so it can be driven directly. The in-game
-- alternative requires building a UI scenario and watching on_tick, which is
-- slow and hard to assert on. Use this suite as the inner loop for changes to
-- LP math, CSR primitives, or create_problem's reachability / cost-tier logic.
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
--
-- Scope of tests/cases/: regressions for the solver, CSR primitives, and
-- translation logic that operates on plain NormalizedProductionLine[] /
-- Constraint[] fixtures. Anything that needs prototypes, storage.virtuals,
-- machine-speed / module / quality folding, or UI behaviour is out of scope
-- and stays in Factorio.
--
-- Bootstrap rule for loop fixtures: any fixture with a recycler or self-loop
-- includes at least one recipe with empty ingredients (a mining / pumping
-- analogue). solver/create_problem.lua's compute_reachable_materials seeds
-- reachability from "materials with no producer"; a fixture made entirely of
-- cyclic recipes leaves the seed empty, the shortage-source gate fires on
-- every loop material, and the LP "cheats" by paying shortage cost instead of
-- running the producer chain. Real Factorio always has mining-drill /
-- pumpjack / asteroid-collector providing seeds; headless fixtures don't.
-- See `iron-mining` in tests/cases/lp_quality_recycling_loop.lua for the
-- minimal shape, and assert the upstream producer's primal is > epsilon to
-- catch the cheat-by-shortage regression.

-- Make `require "solver/foo"` and `require "manage/foo"` resolve against the
-- repo root. The trailing semicolons keep the standard search path as a
-- fallback (so `require "tests/harness"` also works).
package.path = "./?.lua;./?/init.lua;" .. package.path

-- manage/typed_name pulls in __flib__/format for temperature label formatting.
-- flib ships as a separate Factorio mod and is not on the standalone search
-- path, so stub the one function the headless path touches (number) with a
-- faithful copy of flib's implementation, keeping in-game and headless output
-- identical for any future formatting assertions.
package.preload["__flib__/format"] = function()
    local suffix_list = {
        { "Q", 1e30 }, { "R", 1e27 }, { "Y", 1e24 }, { "Z", 1e21 }, { "E", 1e18 },
        { "P", 1e15 }, { "T", 1e12 }, { "G", 1e9 }, { "M", 1e6 }, { "k", 1e3 },
    }
    local fmt = {}
    function fmt.number(amount, append_suffix, fixed_precision)
        local suffix = ""
        if append_suffix then
            for _, data in ipairs(suffix_list) do
                if math.abs(amount) >= data[2] then
                    amount = amount / data[2]
                    suffix = " " .. data[1]
                    break
                end
            end
            if not fixed_precision then
                amount = math.floor(amount * 10) / 10
            end
        end
        local formatted, k = tostring(amount), nil
        if fixed_precision then
            local len_before = #tostring(math.floor(amount))
            local len_after = math.max(0, fixed_precision - len_before - 1)
            formatted = string.format("%." .. len_after .. "f", amount)
        end
        while true do
            formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
            if k == 0 then break end
        end
        return formatted .. suffix
    end
    return fmt
end

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
    "lp_lower_limit",
    "isolated_line",
    "lp_scale_invariance",
    "lp_tiebreak",
    "lp_source_sink",
    "lp_extreme_coefficients",
    "lp_branched_targets",
    "lp_dual_resource_caps",
    "lp_input_cap_output_target",
    "lp_gleba_loop",
    "lp_asteroid_upcycling",
    "lp_fusion_loop",
    "lp_solver_properties",
    "lp_material_kinds",
    "lp_constraint_types",
    "lp_material_classification",
    "material_cycles",
    "problem_dump",
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
