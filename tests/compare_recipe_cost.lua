---@diagnostic disable: undefined-global
-- Diagnostic runner: compare IPM behaviour between the current recipe-cost
-- formula and recipe_cost = 0 for every LP case in the headless suite.
--
-- Not part of the regression suite; intended for one-off investigation of
-- whether the negative recipe cost in create_problem.make_recipe_cost has
-- measurable impact on convergence (iteration count, terminal state, NaN-
-- retry frequency, assertion outcome). Run from the repo root:
--   lua tests/compare_recipe_cost.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local harness = require "tests/harness"
local cp = require "solver/create_problem"
harness.install_log_capture()

-- Same registry as tests/run.lua, minus the non-LP cases (they don't go
-- through solve_to_completion and would just report N/A).
local case_files = {
    "lp_direct",
    "lp_short_loop",
    "lp_quality_cascade",
    "lp_quality_recycling_loop",
    "lp_fluid_bridge",
    "lp_fluid_constraint",
    "isolated_line",
    "lp_scale_invariance",
}

-- Hook solve_to_completion so each case run records its own iteration count
-- and captures the final primal x vector. We snapshot per-solve so cases
-- that chain warm-starts (lp_scale_invariance) report each leg separately.
local original_solve = harness.solve_to_completion
local current_steps, current_calls, current_xs
harness.solve_to_completion = function(...)
    local state, vars, steps = original_solve(...)
    current_steps = current_steps + steps
    current_calls = current_calls + 1
    if vars and vars.x then
        -- Shallow copy: x is a {string -> number} table on the packed vars.
        local snap = {}
        for k, v in pairs(vars.x) do snap[k] = v end
        table.insert(current_xs, snap)
    else
        table.insert(current_xs, nil)
    end
    return state, vars, steps
end

local function run_all(label)
    local results = {}
    for _, file in ipairs(case_files) do
        local cases = require("tests/cases/" .. file)
        for _, case in ipairs(cases) do
            harness.reset_log_capture()
            current_steps = 0
            current_calls = 0
            current_xs = {}
            local ok, err = pcall(case.run)
            -- NaN-retry is detectable in the captured log via the "Cholesky
            -- lost precision" message linear_programming.lua emits when both
            -- the bias-free and regularised solves return NaN. It does not
            -- log the *successful* retry, but unfinished-by-NaN runs do show
            -- up here.
            local nan_retry_terminal = 0
            for _, line in ipairs(harness.captured_output) do
                if tostring(line):find("Cholesky lost precision", 1, true) then
                    nan_retry_terminal = nan_retry_terminal + 1
                end
            end
            table.insert(results, {
                file = file,
                name = case.name,
                ok = ok,
                err = err,
                steps = current_steps,
                calls = current_calls,
                nan_retry = nan_retry_terminal,
                xs = current_xs,
            })
        end
    end
    return results
end

io.write("Running baseline (current make_recipe_cost)...\n")
local baseline = run_all("baseline")

io.write("Running with recipe_cost = 0...\n")
local original_make = cp.make_recipe_cost
cp.make_recipe_cost = function(_) return 0 end
local modified = run_all("recipe_cost=0")
cp.make_recipe_cost = original_make

local function fmt_result(r)
    if not r.ok then return "FAIL" end
    return tostring(r.steps) .. (r.nan_retry > 0 and (" (nan=" .. r.nan_retry .. ")") or "")
end

io.write(string.format("\n%-32s | %-50s | %12s | %12s | %s\n",
    "file", "case", "baseline", "cost=0", "delta"))
io.write(string.rep("-", 130) .. "\n")
for i, b in ipairs(baseline) do
    local m = modified[i]
    local delta
    if b.ok and m.ok then
        delta = string.format("%+d", m.steps - b.steps)
    elseif b.ok and not m.ok then
        delta = "now FAILS"
    elseif not b.ok and m.ok then
        delta = "now PASSES"
    else
        delta = "both FAIL"
    end
    io.write(string.format("%-32s | %-50s | %12s | %12s | %s\n",
        b.file, b.name:sub(1, 50), fmt_result(b), fmt_result(m), delta))
end

local b_fail, m_fail = 0, 0
for i = 1, #baseline do
    if not baseline[i].ok then b_fail = b_fail + 1 end
    if not modified[i].ok then m_fail = m_fail + 1 end
end
io.write(string.format("\nbaseline: %d/%d passed.  recipe_cost=0: %d/%d passed.\n",
    #baseline - b_fail, #baseline, #modified - m_fail, #modified))

-- Surface failure messages on the modified side so we can see *why* a case
-- that used to pass now fails (typically a tie-break the negative cost was
-- silently choosing for us, or an assertion on a variable value the LP can
-- now legitimately set to 0).
local printed_header = false
for i, m in ipairs(modified) do
    if not m.ok and baseline[i].ok then
        if not printed_header then
            io.write("\nNew failures under recipe_cost=0:\n")
            printed_header = true
        end
        io.write(string.format("  [%s] %s\n    %s\n",
            m.file, m.name, tostring(m.err)))
    end
end

-- Per-case primal x diff. For each solve invocation inside the case, compare
-- baseline vs modified primal vectors. We report:
--   * variables present in one but not the other (structural diff -- should
--     be empty since recipe cost is a coefficient change, not a structure
--     change, but verifying that is itself useful)
--   * variables whose values differ above tolerances. Relative tolerance
--     1e-4 matches the headless suite's loose-end assertions; absolute
--     tolerance 1e-8 handles values near zero where relative is meaningless.
local rel_tol = 1e-4
local abs_tol = 1e-8

local function diff_x(a, b)
    local missing_in_b, missing_in_a = {}, {}
    local mismatches = {}
    local max_abs, max_rel = 0, 0
    local max_abs_key, max_rel_key
    if not a or not b then return nil end
    for k, va in pairs(a) do
        local vb = b[k]
        if vb == nil then
            table.insert(missing_in_b, k)
        else
            local d = math.abs(va - vb)
            local denom = math.max(math.abs(va), math.abs(vb), 1e-30)
            local rel = d / denom
            if d > abs_tol and rel > rel_tol then
                table.insert(mismatches, { key = k, a = va, b = vb, abs = d, rel = rel })
            end
            if d > max_abs then max_abs, max_abs_key = d, k end
            if rel > max_rel then max_rel, max_rel_key = rel, k end
        end
    end
    for k, _ in pairs(b) do
        if a[k] == nil then table.insert(missing_in_a, k) end
    end
    return {
        missing_in_b = missing_in_b,
        missing_in_a = missing_in_a,
        mismatches = mismatches,
        max_abs = max_abs, max_abs_key = max_abs_key,
        max_rel = max_rel, max_rel_key = max_rel_key,
    }
end

io.write("\nPrimal x diff (per-solve, tol rel<=1e-4 abs<=1e-8):\n")
io.write(string.rep("-", 130) .. "\n")
local any_solution_drift = false
for i, b in ipairs(baseline) do
    local m = modified[i]
    if not b.xs or #b.xs == 0 then
        -- non-LP cases or cases that didn't call solve_to_completion
    else
        local case_label = string.format("[%s] %s", b.file, b.name:sub(1, 50))
        for solve_idx = 1, math.max(#b.xs, #m.xs) do
            local bx, mx = b.xs[solve_idx], m.xs[solve_idx]
            local d = diff_x(bx, mx)
            if d == nil then
                io.write(string.format("%s  solve#%d: vars unavailable on one side\n",
                    case_label, solve_idx))
            elseif #d.missing_in_b > 0 or #d.missing_in_a > 0 or #d.mismatches > 0 then
                any_solution_drift = true
                io.write(string.format("%s  solve#%d: %d mismatch  max_abs=%.3g(%s)  max_rel=%.3g(%s)\n",
                    case_label, solve_idx, #d.mismatches,
                    d.max_abs, d.max_abs_key or "-",
                    d.max_rel, d.max_rel_key or "-"))
                for _, mm in ipairs(d.mismatches) do
                    io.write(string.format("    %s : baseline=%.6g  cost=0=%.6g  abs=%.3g  rel=%.3g\n",
                        mm.key, mm.a, mm.b, mm.abs, mm.rel))
                end
                if #d.missing_in_b > 0 then
                    io.write("    missing on cost=0 side: " .. table.concat(d.missing_in_b, ", ") .. "\n")
                end
                if #d.missing_in_a > 0 then
                    io.write("    missing on baseline side: " .. table.concat(d.missing_in_a, ", ") .. "\n")
                end
            end
        end
    end
end

if not any_solution_drift then
    io.write("All primal vectors match within tolerance — no tie-break selection driven by recipe cost.\n")
end
