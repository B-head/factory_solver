---@diagnostic disable: undefined-global
-- Extend the eps grading up the binary ladder to (a) find the TRUE upper edge of
-- the "safe window" empirically -- the decimal 1e-2 bound in create_problem.lua
-- was never pinned on a power-of-two scale, so 2^-6 (0.0156) may well be safe --
-- and (b) measure how the SHIPPED "mini approx" pipeline's runtime (solve count
-- + total IPM iterations + CPU time) moves with eps.
--
-- The window's upper edge shows up as the eps where lexicographic REGRESSIONS vs
-- the reference (a bigger eps overriding source_cost's material-efficiency choice
-- and worsening a violation tier) start to climb. Runtime is reported as solves
-- and summed IPM steps (deterministic, hardware-independent) plus os.clock CPU
-- seconds (noisy under the parallel pool -- read it as a trend, not an absolute).
--
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_eps_ref_time.lua -Collect '^ERT\|' -Out s:\tmp\ert.txt

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local problem_dump = require "tests/problem_dump"
local op = require "solver/observe_price"
local ref = require "tests/research/reference_solver"
local refcache = require "tests/research/reference_cache"

local TOL, ITER = 1e-7, 800
local SOFT_GATE_K = 256
local LADDER = {
    { e = 2 ^ -10, tag = "e10" }, { e = 2 ^ -7, tag = "e7" }, { e = 2 ^ -6, tag = "e6" },
    { e = 2 ^ -5, tag = "e5" }, { e = 2 ^ -4, tag = "e4" }, { e = 2 ^ -3, tag = "e3" },
    { e = 2 ^ -2, tag = "e2" },
}

local function set_to_list(s) local t = {}; for k in pairs(s) do t[#t + 1] = k end; table.sort(t); return t end
local function list_to_set(l) local s = {}; for _, k in ipairs(l) do s[k] = true end; return s end

-- returns state, x, s, steps
local function build_solve_ship(constraints, lines, overrides, eps)
    local ok, p = pcall(create_problem.create_problem, "ship", constraints, lines, nil,
        { reachability_gating = false, reachability_soft_gate_k = SOFT_GATE_K,
            shortage_cost_overrides = overrides, recipe_epsilon = eps })
    if not ok then return nil, "build-error", nil, nil, 0 end
    local s, v, steps = harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER })
    if s ~= "finished" then return p, s, nil, nil, steps or 0 end
    return p, s, v.x, v.s, steps or 0
end

-- shipped pipeline at a given eps; returns final prob, state, x, solves, total_steps
local function solve_shipped(constraints, lines, eps)
    local solves, total_steps = 0, 0
    local prob, state, x0, s0, st0 = build_solve_ship(constraints, lines, nil, eps)
    solves = solves + 1; total_steps = total_steps + (st0 or 0)
    if state ~= "finished" or not x0 then return nil, state, nil, solves, total_steps end
    local plan = op.collect_plan(prob.primals, x0, s0 or {}, lines)
    if not plan then return prob, "finished", x0, solves, total_steps end
    for _, gid in ipairs(plan.groups) do
        local pobs, sobs, xobs, _, sti = build_solve_ship(constraints, lines, op.observe_overrides(plan, gid), eps)
        solves = solves + 1; total_steps = total_steps + (sti or 0)
        if sobs == "finished" and xobs then
            op.apply_observe(plan, gid, pobs.primals, xobs)
        else
            for _, k in ipairs(plan.keys) do if k.group == gid then k.frozen = true end end
        end
    end
    local round, final_prob, final_x = 0, prob, x0
    while round < op.MAX_ROUNDS do
        round = round + 1
        local pr, sr, xr, _, sti = build_solve_ship(constraints, lines, op.verify_overrides(plan), eps)
        solves = solves + 1; total_steps = total_steps + (sti or 0)
        if sr ~= "finished" or not xr then break end
        final_prob, final_x = pr, xr
        if not op.apply_verify(plan, xr, round) then break end
    end
    return final_prob, "finished", final_x, solves, total_steps
end

local path = arg[1]
if not path then io.stderr:write("usage: ... <dump>\n"); os.exit(2) end
local prob = problem_dump.load_problem(path)
if not prob then print("# ERROR " .. tostring(path) .. " load"); os.exit(0) end
local tag = path:gsub("[\\/]", "/"):match("([^/]+)%.lua$") or path

local ok, line = pcall(function()
    local intermediates = ref.intermediates(prob.normalized_lines)
    local entry = refcache.load(path)
    if not entry then
        local r = ref.solve_reference(prob.constraints, prob.normalized_lines)
        local Nv_r = (r.state == "finished" and r.x) and ref.violation_count(r.problem, r.x, intermediates) or -1
        entry = { state = r.state, n_mats = r.n_mats, T = r.T, Vp = r.Vp, Vc = r.Vc, Vf = r.Vf,
            M = r.M, S = r.S, Nv = Nv_r, steps = r.steps,
            producible = set_to_list(r.producible), consumable = set_to_list(r.consumable) }
        refcache.store(path, entry)
    end
    local producible = list_to_set(entry.producible)
    local consumable = list_to_set(entry.consumable)

    local parts = { "ERT|" .. tag,
        string.format("ref:T=%.6g,Vp=%.6g,Vf=%.6g,Vc=%.6g,M=%.6g", entry.T, entry.Vp, entry.Vf, entry.Vc, entry.M) }
    for _, L in ipairs(LADDER) do
        local t0 = os.clock()
        local sp, sstate, sx, solves, steps = solve_shipped(prob.constraints, prob.normalized_lines, L.e)
        local dt = os.clock() - t0
        if sstate == "finished" and sx then
            local T = ref.total_of(sp, sx, ref.TARGET_KINDS)
            local Vp, Vc, Vf = ref.violation_split(sp, sx, intermediates, producible, consumable)
            local M = ref.total_of(sp, sx, ref.MACHINE_KINDS)
            parts[#parts + 1] = string.format("%s:T=%.6g,Vp=%.6g,Vf=%.6g,Vc=%.6g,M=%.6g,solves=%d,steps=%d,clk=%.5g",
                L.tag, T, Vp, Vf, Vc, M, solves, steps, dt)
        else
            parts[#parts + 1] = string.format("%s:st=%s,solves=%d,steps=%d,clk=%.5g", L.tag, tostring(sstate), solves, steps, dt)
        end
    end
    return table.concat(parts, "|")
end)
if ok then print(line) else print("# ERROR " .. tag .. ": " .. tostring(line)) end
