---@diagnostic disable: undefined-global
-- Grade the eps variants against the problem-definition reference solver.
--
-- The earlier sweeps proved that raising recipe_epsilon re-selects a DIFFERENT
-- (but equally cost-optimal) vertex on degenerate faces. Cost-optimality cannot
-- say which vertex is BETTER -- only the user's definition can. So here we solve
-- the SHIPPED pipeline (soft gate 256 + observe-price fixed point, replicated
-- like probe_reference_compare.lua) at each epsilon, and grade every result with
-- the reference's lexicographic yardstick:
--     T (target) >> Vp (producible import) >> Vf (makeup) >> Vc (consumable dump) >> M (machines)
-- The reference itself is epsilon-independent (its stage epsilon is fixed), so a
-- single cached gold answer per dump grades all variants.
--
-- Single-shot run_corpus worker.
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_eps_reference.lua -Collect '^EREF\|' -Out s:\tmp\eref.txt

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
local FOCUS = { { e = 2 ^ -10, tag = "e10" }, { e = 2 ^ -7, tag = "e7" }, { e = 2 ^ -6, tag = "e6" } }

local function set_to_list(s) local t = {}; for k in pairs(s) do t[#t + 1] = k end; table.sort(t); return t end
local function list_to_set(l) local s = {}; for _, k in ipairs(l) do s[k] = true end; return s end
local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end

-- build+solve the soft-gate ship at a given epsilon and shortage overrides.
local function build_solve_ship(constraints, lines, overrides, eps)
    local ok, p = pcall(create_problem.create_problem, "ship", constraints, lines, nil,
        { reachability_gating = false, reachability_soft_gate_k = SOFT_GATE_K,
            shortage_cost_overrides = overrides, recipe_epsilon = eps })
    if not ok then return nil, "build-error", nil, nil end
    local s, v = solve(p)
    if s ~= "finished" then return p, s, nil, nil end
    return p, s, v.x, v.s
end

-- the full shipped pipeline at a given epsilon (drive_observe_e2e replication).
local function solve_shipped(constraints, lines, eps)
    local prob, state, x0, s0 = build_solve_ship(constraints, lines, nil, eps)
    if state ~= "finished" or not x0 then return nil, state, nil end
    local plan = op.collect_plan(prob.primals, x0, s0 or {}, lines)
    if not plan then return prob, "finished", x0 end
    for _, gid in ipairs(plan.groups) do
        local pobs, sobs, xobs = build_solve_ship(constraints, lines, op.observe_overrides(plan, gid), eps)
        if sobs == "finished" and xobs then
            op.apply_observe(plan, gid, pobs.primals, xobs)
        else
            for _, k in ipairs(plan.keys) do if k.group == gid then k.frozen = true end end
        end
    end
    local round, final_prob, final_x = 0, prob, x0
    while round < op.MAX_ROUNDS do
        round = round + 1
        local pr, sr, xr = build_solve_ship(constraints, lines, op.verify_overrides(plan), eps)
        if sr ~= "finished" or not xr then break end
        final_prob, final_x = pr, xr
        if not op.apply_verify(plan, xr, round) then break end
    end
    return final_prob, "finished", final_x
end

local path = arg[1]
if not path then io.stderr:write("usage: ... <dump>\n"); os.exit(2) end
local prob = problem_dump.load_problem(path)
if not prob then print("# ERROR " .. tostring(path) .. " load"); os.exit(0) end
local tag = path:gsub("[\\/]", "/"):match("([^/]+)%.lua$") or path

local ok, line = pcall(function()
    local intermediates = ref.intermediates(prob.normalized_lines)
    -- cached, epsilon-independent reference gold answer
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

    local parts = { "EREF|" .. tag,
        string.format("ref:st=%s,T=%.6g,Vp=%.6g,Vf=%.6g,Vc=%.6g,M=%.6g",
            entry.state, entry.T, entry.Vp, entry.Vf, entry.Vc, entry.M) }
    for _, F in ipairs(FOCUS) do
        local sp, sstate, sx = solve_shipped(prob.constraints, prob.normalized_lines, F.e)
        if sstate == "finished" and sx then
            local T = ref.total_of(sp, sx, ref.TARGET_KINDS)
            local Vp, Vc, Vf = ref.violation_split(sp, sx, intermediates, producible, consumable)
            local M = ref.total_of(sp, sx, ref.MACHINE_KINDS)
            parts[#parts + 1] = string.format("%s:st=fin,T=%.6g,Vp=%.6g,Vf=%.6g,Vc=%.6g,M=%.6g",
                F.tag, T, Vp, Vf, Vc, M)
        else
            parts[#parts + 1] = string.format("%s:st=%s", F.tag, tostring(sstate))
        end
    end
    return table.concat(parts, "|")
end)
if ok then print(line) else print("# ERROR " .. tag .. ": " .. tostring(line)) end
