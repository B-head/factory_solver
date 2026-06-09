---@diagnostic disable: undefined-global
-- Phase A suite-verification driver for observe-price.
--
-- Question this answers: if production replaces reachability-gating / deficit-
-- seeding / catalyst-closure / two-pass with observe-price (the validated all-off
-- configuration), does any headless-suite fixture regress?
--
-- It does NOT run the fixtures' own literal assertions (those test the very
-- mechanisms being removed). Instead it captures every (constraints, lines) the
-- suite builds, then solves each problem TWO ways and compares practical
-- invariants:
--   * SHIPPED  -- create_problem defaults (all heuristics ON, current behaviour);
--   * OBSERVE  -- all-off + the observe-price fixed-point loop.
-- A fixture where OBSERVE is no worse than SHIPPED (no new cheat, no collapse, no
-- over-dump) is safe under the replacement. Where OBSERVE is worse, it is a
-- candidate class-3 regression (the Fulgora-style "un-gating opened a cheat
-- observe-price's self-sustaining-idle filter does not catch").
--
-- RAW numbers only -- classification is the researcher's call (no verdict column).
--
-- Usage:  lua tests/research/verify_observe_suite.lua [filter]

require "tests/headless_env"

local harness = require "tests/harness"
harness.install_log_capture()

local cp = require "solver/create_problem"
local lp = require "solver/linear_programming"
local ed = require "tests/explore_detect"
local R = require "tests/research/research_lib"
local opl = require "tests/research/observe_price_lib"

local orig_create = cp.create_problem

-- ---- capture every problem the suite builds ---------------------------------
local captured = {}
local current_file = "?"
cp.create_problem = function(name, constraints, lines, forced_imports, options)
    -- Only the user's PRIMARY problem (pass-1, no forced imports / no research
    -- options) is the thing observe-price would own; skip the two-pass re-solves
    -- and ablation rebuilds so we don't double-count.
    if forced_imports == nil and options == nil then
        captured[#captured + 1] = { file = current_file, name = name, constraints = constraints, lines = lines }
    end
    return orig_create(name, constraints, lines, forced_imports, options)
end

-- Only the case files that actually build LP problems are worth driving; the
-- pure-utility files (csr/format/var_key/...) never call create_problem so they
-- would just no-op, but listing the LP ones keeps the run fast and focused.
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
        local cases = require("tests/cases/" .. file)
        for _, case in ipairs(cases) do
            harness.reset_log_capture()
            pcall(case.run) -- assertions may fail under the captured config; ignore
        end
    end
end

-- Restore so the observe-price loop below builds through the real create_problem.
cp.create_problem = orig_create

-- ---- shipped-baseline solve (all heuristics ON) -----------------------------
local function shipped(constraints, lines)
    local ok, prob = pcall(orig_create, "shipped", constraints, lines)
    if not ok then return { ok = false } end
    local state, vars = harness.solve_to_completion(lp, prob, { tolerance = 1e-7, iterate_limit = 800 })
    if state ~= "finished" or not vars then return { ok = false, state = state } end
    local d = ed.detect(vars, prob.primals)
    return { ok = true, cheat = d.cheat, active = d.active, noship = d.noship,
        relax = R.target_relax(prob, vars.x) }
end

-- "worse than shipped": observe-price (under some opts base) left a new cheat,
-- a new collapse, an over-dump, or failed to solve where shipped succeeded.
-- Frozen imports (cone-over-promise) are NOT worse: import is correct there and
-- shipped imports too.
local function worse_than(s, o)
    local ship_cheat = s.ok and s.cheat or 0
    local obs_cheat = o.ok and (o.final_cheat or 0) or 0
    local new_cheat = obs_cheat > 1e-6 and obs_cheat > ship_cheat + 1e-6
    local new_collapse = o.ok and o.collapse and not (s.ok and s.relax > 1e-4)
    local over_dump = o.ok and (o.over_dump_ratio or 1) > 2.0
    local solve_fail = (not o.ok) and s.ok
    return new_cheat or new_collapse or over_dump or solve_fail
end

-- ---- compare three configs: shipped / all-off+observe / all-on+observe -------
local COLS = {
    "idx", "file", "name",
    "ship_cheat", "ship_active",
    -- all-off + observe-price (the planned replacement config)
    "off_qual", "off_keys", "off_solves", "off_basecheat", "off_cheat", "off_active", "off_collapse", "off_overdump", "OFF_WORSE",
    -- all-on (shipped heuristics) + observe-price layered on top
    "on_qual", "on_keys", "on_solves", "on_cheat", "on_active", "on_collapse", "on_overdump", "ON_WORSE",
}
local function fmt(v)
    if type(v) == "number" then return string.format("%.4g", v) end
    if type(v) == "boolean" then return v and "Y" or "n" end
    return tostring(v)
end
io.write("#" .. table.concat(COLS, "\t") .. "\n")

local n_off_worse, n_on_worse = 0, 0
for i, c in ipairs(captured) do
    local name = (c.name or "?"):gsub("%s+", "_")
    local s = shipped(c.constraints, c.lines)
    local off = opl.run(c.constraints, c.lines, opl.ALL_OFF)
    local on = opl.run(c.constraints, c.lines, {}) -- all heuristics ON + observe-price

    local off_worse = worse_than(s, off)
    local on_worse = worse_than(s, on)
    if off_worse then n_off_worse = n_off_worse + 1 end
    if on_worse then n_on_worse = n_on_worse + 1 end

    local row = {
        idx = i, file = c.file, name = name,
        ship_cheat = s.ok and s.cheat or -1, ship_active = s.ok and s.active or -1,
        off_qual = off.qualified or false, off_keys = off.n_keys or 0, off_solves = off.total_solves or 0,
        off_basecheat = off.base_cheat or -1, off_cheat = off.final_cheat or -1, off_active = off.final_active or -1,
        off_collapse = off.collapse or false, off_overdump = off.over_dump_ratio or 1, OFF_WORSE = off_worse,
        on_qual = on.qualified or false, on_keys = on.n_keys or 0, on_solves = on.total_solves or 0,
        on_cheat = on.final_cheat or -1, on_active = on.final_active or -1,
        on_collapse = on.collapse or false, on_overdump = on.over_dump_ratio or 1, ON_WORSE = on_worse,
    }
    local cells = {}
    for _, k in ipairs(COLS) do cells[#cells + 1] = fmt(row[k]) end
    io.write(table.concat(cells, "\t") .. "\n")
end

io.write(string.format("\n# %d problems captured\n# all-off + observe-price worse than shipped: %d\n# all-on  + observe-price worse than shipped: %d\n",
    #captured, n_off_worse, n_on_worse))
