---@diagnostic disable: undefined-global
-- Map each suite problem to the heuristic that fixes its all-off regression.
--
-- For the "true full replacement" path, observe-price must subsume whatever
-- deficit_seeding / catalyst_closure / reachability_gating each fixture relies
-- on. This solves every captured (constraints, lines) under all-off plus each
-- single heuristic turned on, so the column that clears the cheat names the
-- mechanism observe-price has to reproduce for that fixture.
--
-- cheat is ed.detect's shortage_source+elastic mass; act is active real recipes
-- (0 = the degenerate "conjure target, build nothing" solution). RAW numbers.
--
-- Usage:  lua tests/research/diagnose_regressions.lua [filter]

require "tests/headless_env"

local harness = require "tests/harness"
harness.install_log_capture()

local cp = require "solver/create_problem"
local lp = require "solver/linear_programming"
local ed = require "tests/explore_detect"

local orig_create = cp.create_problem
local captured, current_file = {}, "?"
cp.create_problem = function(name, constraints, lines, forced_imports, options)
    if forced_imports == nil and options == nil then
        captured[#captured + 1] = { file = current_file, name = name, constraints = constraints, lines = lines }
    end
    return orig_create(name, constraints, lines, forced_imports, options)
end

local case_files = {
    "lp_direct", "lp_short_loop", "lp_quality_cascade", "lp_quality_recycling_loop",
    "lp_fluid_bridge", "lp_fluid_constraint", "lp_lower_limit", "isolated_line",
    "lp_scale_invariance", "lp_tiebreak", "lp_recipe_epsilon", "lp_source_sink",
    "lp_extreme_coefficients", "lp_branched_targets", "lp_dual_resource_caps",
    "lp_input_cap_output_target", "lp_gleba_loop", "lp_asteroid_upcycling",
    "lp_fusion_loop", "lp_solver_properties", "lp_material_kinds",
    "lp_constraint_types", "lp_material_classification", "lp_fuel_burnt_result",
    "lp_masslosing_cycle_import", "lp_catalyst_loop_bootstrap", "lp_explorer_catalyst",
    "lp_explorer_constrained_material", "lp_explorer_pyanodon_chains",
    "lp_two_pass_reclassify",
}
local filter = arg[1]
for _, file in ipairs(case_files) do
    if not filter or file:find(filter, 1, true) then
        current_file = file
        for _, case in ipairs(require("tests/cases/" .. file)) do
            harness.reset_log_capture()
            pcall(case.run)
        end
    end
end
cp.create_problem = orig_create

local CONFIGS = {
    { tag = "off", o = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false } },
    { tag = "+def", o = { deficit_seeding = true, catalyst_closure = false, reachability_gating = false } },
    { tag = "+cat", o = { deficit_seeding = false, catalyst_closure = true, reachability_gating = false } },
    { tag = "+gate", o = { deficit_seeding = false, catalyst_closure = false, reachability_gating = true } },
    { tag = "on", o = nil }, -- shipped defaults
}

local function solve(constraints, lines, opts)
    local ok, prob = pcall(orig_create, "diag", constraints, lines, nil, opts)
    if not ok then return nil end
    local state, vars = harness.solve_to_completion(lp, prob, { tolerance = 1e-7, iterate_limit = 800 })
    if state ~= "finished" or not vars then return nil end
    return ed.detect(vars, prob.primals)
end

io.write("#idx\tfile\tname")
for _, cfg in ipairs(CONFIGS) do io.write("\t" .. cfg.tag .. "_cheat\t" .. cfg.tag .. "_act") end
io.write("\tfixed_by\n")

for i, c in ipairs(captured) do
    local results = {}
    for _, cfg in ipairs(CONFIGS) do results[cfg.tag] = solve(c.constraints, c.lines, cfg.o) end
    local off = results.off
    -- Only interesting where all-off has a cheat (or degenerates) that shipped doesn't.
    local off_cheat = off and off.cheat or -1
    local on = results.on
    local on_cheat = on and on.cheat or -1
    if off_cheat > 1e-6 and (on_cheat <= 1e-6 or (on and off and on.active > off.active)) then
        -- which single heuristic clears it?
        local fixed = {}
        for _, tag in ipairs({ "+def", "+cat", "+gate" }) do
            local r = results[tag]
            if r and r.cheat <= 1e-6 and r.active > 0 then fixed[#fixed + 1] = tag end
        end
        io.write(string.format("%d\t%s\t%s", i, c.file, (c.name or "?"):gsub("%s+", "_")))
        for _, cfg in ipairs(CONFIGS) do
            local r = results[cfg.tag]
            io.write(string.format("\t%.4g\t%s", r and r.cheat or -1, r and r.active or -1))
        end
        io.write("\t" .. (next(fixed) and table.concat(fixed, ",") or "NONE-single") .. "\n")
    end
end
