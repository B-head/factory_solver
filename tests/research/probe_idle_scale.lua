-- probe_idle_scale: scale audit of observe_price.collect_plan's idle test.
--
-- Loads explorer dumps, multiplies every constraint's limit_amount_per_second by
-- FS_SCALE (LP is positively homogeneous in b: the exact optimum scales linearly
-- and the active set is invariant, so a qualifying SCC should qualify at every
-- scale), solves under the production soft-gate config, and reports per candidate
-- SCC (cyclic + active shortage + self-sustaining + export-feasible) the verdict of
-- three idle tests side by side: fixed flow epsilon (1e-6), park_threshold
-- (scale-relative), and the dual certificate (x vs s).
--
-- Findings that drove the shipped cycle_idle (2026-06-10, 52 qualifying dumps):
--   * S >= 1: zero misfires anywhere -- purify_zeros snaps idle dust to exact 0.
--   * S <= 1e-4 (genuine cycle flows < 1e-6/s): unpurified dust sits at an
--     ABSOLUTE floor (~1e-7..3.5e-6, tolerance-coupled, scale-independent) while
--     real flows shrink with S, so the two bands overlap: the fixed epsilon fails
--     in both directions, park_threshold (floor 1e-9 < dust) is strictly worse,
--     and the dual certificate is the only test that never loses a truly idle
--     cycle (its errors are all in the bounded collect-a-running-cycle direction).
--   * Hence shipped = certificate OR fixed epsilon (see cycle_idle).
--
-- Usage: FS_SCALE=1e-4 luajit tests/research/probe_idle_scale.lua <dump1> [dump2 ...]
--   (single-shot contract; fan out via tests/research/run_corpus.ps1 -Collect '^ISC')

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local problem_dump = require "tests/problem_dump"
local op = require "solver/observe_price"
local mc = require "solver/material_cycles"
local tn = require "manage/typed_name"

local TOL, ITER = 1e-7, 800
local SOFT_GATE_K = 256
local SCALES = { tonumber(os.getenv("FS_SCALE")) or 1 }

local function deep_copy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deep_copy(v) end
    return o
end

local function scaled_constraints(constraints, s)
    local out = deep_copy(constraints)
    for _, c in ipairs(out) do
        c.limit_amount_per_second = c.limit_amount_per_second * s
    end
    return out
end

local function build_solve(constraints, lines)
    local ok, p = pcall(create_problem.create_problem, "probe", constraints, lines, nil,
        { reachability_gating = false, reachability_soft_gate_k = SOFT_GATE_K })
    if not ok then return nil, "build-error" end
    local ok2, s, v = pcall(harness.solve_to_completion, lp, p, { tolerance = TOL, iterate_limit = ITER })
    if not ok2 then return nil, "solve-raised" end
    if s ~= "finished" then return nil, s end
    return p, s, v.x, v.s
end

-- Copy of observe_price's local internal_flow (recipe flow internal to the SCC).
local function internal_flow(lines, scc_set, x)
    local s = 0
    for _, line in ipairs(lines) do
        local hi = false
        for _, ing in ipairs(line.ingredients) do
            if scc_set[tn.typed_name_to_variable_name(ing)] then hi = true; break end
        end
        if not hi and line.fuel_ingredient and scc_set[tn.typed_name_to_variable_name(line.fuel_ingredient)] then hi = true end
        if hi then
            local hp = false
            for _, prod in ipairs(line.products) do
                if scc_set[tn.typed_name_to_variable_name(prod)] then hp = true; break end
            end
            if not hp and line.fuel_burnt_result and scc_set[tn.typed_name_to_variable_name(line.fuel_burnt_result)] then hp = true end
            if hp then s = s + math.abs(x[tn.typed_name_to_variable_name(line.recipe_typed_name)] or 0) end
        end
    end
    return s
end

-- Dual-certificate idle test: every SCC-internal recipe variable is either exactly
-- 0 or dual-dominated (reduced cost s > value x, the same nonbasic certificate
-- certify_zeros uses). A genuinely basic (running) recipe has s -> 0 < x.
local function cert_idle(lines, scc_set, x, sl)
    for _, line in ipairs(lines) do
        local hi = false
        for _, ing in ipairs(line.ingredients) do
            if scc_set[tn.typed_name_to_variable_name(ing)] then hi = true; break end
        end
        if not hi and line.fuel_ingredient and scc_set[tn.typed_name_to_variable_name(line.fuel_ingredient)] then hi = true end
        if hi then
            local hp = false
            for _, prod in ipairs(line.products) do
                if scc_set[tn.typed_name_to_variable_name(prod)] then hp = true; break end
            end
            if not hp and line.fuel_burnt_result and scc_set[tn.typed_name_to_variable_name(line.fuel_burnt_result)] then hp = true end
            if hp then
                local key = tn.typed_name_to_variable_name(line.recipe_typed_name)
                local xv = math.abs(x[key] or 0)
                local sv = sl[key] or 0
                if xv > 0 and sv <= xv then return false end
            end
        end
    end
    return true
end

local function max_recipe(x, primals)
    local m = 0
    for k, v in pairs(x) do
        local p = primals[k]
        if p and p.kind == "recipe" and math.abs(v) > m then m = math.abs(v) end
    end
    return m
end

print("#ISC\tfile\tscale\tscc\tmaterials\tqty\tmax_recipe\tpark_th\tiflow\tidle_1e6\tidle_park\tidle_cert\tshipped_plan_keys")

for _, path in ipairs(arg) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local fname = path:match("([^/\\]+)%.lua$") or path
        for _, S in ipairs(SCALES) do
            local cons = scaled_constraints(prob.constraints, S)
            local p, state, x, sl = build_solve(cons, prob.normalized_lines)
            if not p or not x then
                print(string.format("ISC\t%s\t%g\tSOLVE_FAIL:%s", fname, S, tostring(state)))
            else
                local primals = p.primals
                local lines = prob.normalized_lines
                local th = op.park_threshold(x, primals)
                local plan = op.collect_plan(primals, x, sl, lines)
                local nkeys = plan and #plan.keys or 0

                -- Re-derive the candidate SCCs (qualification minus the idle check)
                -- so we can report internal_flow for each.
                local adj = mc.build_material_graph(lines)
                local sccs = mc.find_sccs(adj)
                local prim_keys = {}
                for k in pairs(primals) do prim_keys[#prim_keys + 1] = k end
                table.sort(prim_keys)
                local any = false
                for si, scc in ipairs(sccs) do
                    if mc.is_cyclic_scc(scc, adj) then
                        local scc_set = {}
                        for _, m in ipairs(scc) do scc_set[m] = true end
                        local active, mats, qty = {}, {}, 0
                        for _, key in ipairs(prim_keys) do
                            local pr = primals[key]
                            if pr.kind == "shortage_source" and pr.material and scc_set[pr.material]
                                and (x[key] or 0) > th then
                                active[#active + 1] = key
                                mats[#mats + 1] = pr.material
                                qty = qty + (x[key] or 0)
                            end
                        end
                        if #active >= 1 and mc.is_self_sustaining(lines, scc) then
                            local fab = true
                            for _, m in ipairs(mats) do
                                if not mc.export_feasible(lines, m) then fab = false; break end
                            end
                            if fab then
                                local ifl = internal_flow(lines, scc_set, x)
                                any = true
                                print(string.format("ISC\t%s\t%g\tscc:%d\t%s\t%.6g\t%.6g\t%.6g\t%.6g\t%s\t%s\t%s\t%d",
                                    fname, S, si, table.concat(mats, ","), qty,
                                    max_recipe(x, primals), th, ifl,
                                    ifl < 1e-6 and "IDLE" or "running",
                                    ifl < th and "IDLE" or "running",
                                    cert_idle(lines, scc_set, x, sl) and "IDLE" or "running",
                                    nkeys))
                            end
                        end
                    end
                end
                if not any then
                    print(string.format("ISC\t%s\t%g\t-\t(no candidate SCC)\t-\t%.6g\t%.6g\t-\t-\t-\t%d",
                        fname, S, max_recipe(x, primals), th, nkeys))
                end
            end
        end
    end
end
