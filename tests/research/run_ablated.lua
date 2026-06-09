---@diagnostic disable: undefined-global
-- Research-only variant of tests/run.lua that runs the headless solver suite
-- with create_problem's cycle-material escape-hatch preprocessing ablated.
--
-- The shipped cases call cp.create_problem(name, constraints, lines) with no
-- options, so we monkeypatch the cached create_problem module to inject the
-- ablation switches from env vars. This is NOT a shipped path -- it only exists
-- to find which fixtures break when a mechanism is disabled, so a tilted-cost
-- strategy can be tried against the simplest failures first.
--
-- Usage (from repo root):
--   CP_REACHABILITY_GATING=0 lua tests/research/run_ablated.lua
--   CP_REACHABILITY_GATING=0 CP_DEFICIT_SEEDING=0 lua tests/research/run_ablated.lua [filter]
--
-- env vars (each defaults ON; "0" disables that one mechanism):
--   CP_DEFICIT_SEEDING, CP_CATALYST_CLOSURE, CP_REACHABILITY_GATING

require "tests/headless_env"

local harness = require "tests/harness"
harness.install_log_capture()

local function env_off(name) return os.getenv(name) == "0" end
local cp_options = {
    deficit_seeding = not env_off("CP_DEFICIT_SEEDING"),
    catalyst_closure = not env_off("CP_CATALYST_CLOSURE"),
    reachability_gating = not env_off("CP_REACHABILITY_GATING"),
}

io.write(string.format("ablation: deficit_seeding=%s catalyst_closure=%s reachability_gating=%s\n",
    tostring(cp_options.deficit_seeding), tostring(cp_options.catalyst_closure),
    tostring(cp_options.reachability_gating)))

-- Optional tilted-cost re-pricing of the un-gated |shortage_source|.
--   CP_TILT_FLAT=K       shortage cost = elastic_cost * K (flat bump)
--   CP_TILT_DEPTH_BASE=b shortage cost = elastic_cost * b^depth (deep=costlier)
-- depth is computed per problem from its own lines, so the wrapper can build
-- the cost fn even though the cases pass no options.
--   CP_SURPLUS_MULT=m    surplus_sink cost = elastic_cost * m (lower it < 1 to
--                        test "byproduct disposal is bookkeeping" -- a chain
--                        whose cost is byproduct-dominated then beats the import
--                        while a raw-dominated chain is unaffected).
--   CP_TILT_FLAT_REACHABLE=K  soft gate: shortage cost = elastic_cost * K for
--                        REACHABLE materials only; unreachable stay at
--                        elastic_cost (keep their cheap import hatch). Tests
--                        whether reachability is the signal that separates
--                        "should manufacture" (reachable) from "should import"
--                        (unreachable) -- a finite-K softening of the gate.
local ELASTIC = 2 ^ 10
local tilt_flat = tonumber(os.getenv("CP_TILT_FLAT"))
local tilt_depth_base = tonumber(os.getenv("CP_TILT_DEPTH_BASE"))
local surplus_mult = tonumber(os.getenv("CP_SURPLUS_MULT"))
local tilt_flat_reach = tonumber(os.getenv("CP_TILT_FLAT_REACHABLE"))
if tilt_flat or tilt_depth_base or surplus_mult or tilt_flat_reach then
    cp_options.reachability_gating = false -- a tilt only makes sense un-gated
    io.write(string.format("tilt: flat=%s depth_base=%s surplus_mult=%s flat_reachable=%s (reachability_gating forced off)\n",
        tostring(tilt_flat), tostring(tilt_depth_base), tostring(surplus_mult), tostring(tilt_flat_reach)))
end

-- Inject the options into every cp.create_problem call the cases make.
local cp = require "solver/create_problem"
local orig_create = cp.create_problem
cp.create_problem = function(name, constraints, lines, forced_imports, options)
    local opts = options or cp_options
    if (tilt_flat or tilt_depth_base or surplus_mult or tilt_flat_reach)
        and not (options and (options.shortage_cost_fn or options.surplus_cost_fn)) then
        -- shallow-copy so we don't mutate the shared cp_options across cases
        local merged = {}
        for k, v in pairs(opts) do merged[k] = v end
        if tilt_flat or tilt_depth_base or tilt_flat_reach then
            local depth = tilt_depth_base and cp.compute_reachability_depth(lines) or nil
            merged.shortage_cost_fn = function(cn, is_reachable)
                if tilt_flat_reach then
                    -- soft gate: use create_problem's OWN reachability verdict
                    -- (is_reachable), not a plain recompute, so it matches the
                    -- gate (active lines + deficits + catalyst closure).
                    return is_reachable and (ELASTIC * tilt_flat_reach) or ELASTIC
                end
                if tilt_depth_base then
                    return ELASTIC * (tilt_depth_base ^ (depth[cn] or 0))
                end
                return ELASTIC * tilt_flat
            end
        end
        if surplus_mult then
            merged.surplus_cost_fn = function() return ELASTIC * surplus_mult end
        end
        opts = merged
    end
    return orig_create(name, constraints, lines, forced_imports, opts)
end

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

local case_files = {
    "csr_basics", "lp_direct", "lp_short_loop", "lp_quality_cascade",
    "lp_quality_recycling_loop", "fs_log", "typed_name_format", "number_format",
    "var_key", "lp_fluid_bridge", "lp_fluid_constraint", "lp_lower_limit",
    "isolated_line", "lp_scale_invariance", "lp_tiebreak", "lp_recipe_epsilon",
    "lp_source_sink", "lp_extreme_coefficients", "lp_branched_targets",
    "lp_dual_resource_caps", "lp_input_cap_output_target", "lp_gleba_loop",
    "lp_asteroid_upcycling", "lp_fusion_loop", "lp_solver_properties",
    "lp_material_kinds", "lp_constraint_types", "lp_material_classification",
    "material_cycles", "problem_dump", "lp_fuel_burnt_result",
    "lp_masslosing_cycle_import", "lp_catalyst_loop_bootstrap",
    "lp_explorer_catalyst", "lp_explorer_constrained_material",
    "lp_explorer_pyanodon_chains", "lp_two_pass_reclassify", "chain_reachability",
    "explore_detect", "lp_substitution",
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
        if case.xfail then
            if ok then
                failed = failed + 1
                io.write(string.format("  XPASS[%s] %s\n", file, case.name))
                table.insert(failures, string.format("[%s] %s (XPASS)", file, case.name))
            else
                passed = passed + 1
                if verbose then io.write(string.format("  xfail[%s] %s\n", file, case.name)) end
            end
        elseif ok then
            passed = passed + 1
            if verbose then io.write(string.format("  ok   [%s] %s\n", file, case.name)) end
        else
            failed = failed + 1
            io.write(string.format("  FAIL [%s] %s\n", file, case.name))
            io.write("    ", tostring(err), "\n")
            if verbose then
                local dump = harness.dump_captured()
                if dump ~= "" then io.write(dump, "\n") end
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
