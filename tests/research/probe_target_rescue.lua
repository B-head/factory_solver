---@diagnostic disable: undefined-global
-- Target-rescue experiment: fix the tier1 collapse (the shipped LP abandoning
-- the target) with a lexicographic rescue, and grade the result against the
-- reference definition.
--
-- CAUSE (drilled 2026-06-12, S:/tmp/corpus/drill_tier1.lua): the single weighted
-- LP trades the target against violations at the finite exchange rate
-- target_cost / elastic_cost = 2^20 / 2^10 = 1024. Every tier1-loss problem
-- (30/1678, the same set under hardgate and observer) needs MORE than 1024
-- violation units per target unit (min observed 1499.5, max 3.8e7), so the LP
-- rationally prefers the all-zero solution -- and since the trade is linear it
-- is all-or-nothing (T = 1 exactly). Reachability is NOT the cause: a
-- target-only objective reaches T_min = 0 on the same builds.
--
-- RESCUE (the fix candidate, mirroring reference stage 1): when the baseline
-- finishes with active target relaxation,
--   stage 1   re-solve with the target elastics as the ONLY objective
--             (recipe/bridge at a 2^-20 face regularizer) -> T_min
--   re-solve  ship costs plus one budget row  sum(elastic) <= budget(T_min)
-- and keep the budget row in every later build (the observer's observe/verify
-- solves would otherwise re-collapse). Best-effort: any unfinished rescue solve
-- keeps the baseline.
--
-- Config via env (run_corpus.ps1 passes only the dump path):
--   FS_RESCUE_CONFIG  observer (default) | hardgate
--   FS_RESCUE         on (default) | off   (off = replicate the old grading)
--
-- Single-shot contract: `<lua> probe_target_rescue.lua <dump>` -> one row, same
-- 21-column layout as probe_reference_compare (grade_two_solvers.lua parses it;
-- columns 22-23 add rescued + T_min and are ignored by the grader).
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_target_rescue.lua -Collect '^seed=' -Out <tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local problem_dump = require "tests/problem_dump"
local op = require "solver/observe_price"
local ref = require "tests/research/reference_solver"
local refcache = require "tests/research/reference_cache"

local CONFIG = (os.getenv("FS_RESCUE_CONFIG") or "observer"):lower()
local RESCUE = (os.getenv("FS_RESCUE") or "on"):lower() ~= "off"
assert(CONFIG == "observer" or CONFIG == "hardgate", "FS_RESCUE_CONFIG must be observer|hardgate")

local TOL, ITER = 1e-7, 800
local SOFT_GATE_K = 256
local RESCUE_TRIGGER = 1e-6
local BUDGET_REL, BUDGET_ABS = 1e-3, 1e-6

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end

local function set_to_list(set)
    local t = {}
    for k in pairs(set) do t[#t + 1] = k end
    table.sort(t)
    return t
end

local function list_to_set(list)
    local s = {}
    for _, k in ipairs(list) do s[k] = true end
    return s
end

---Build one ship problem for the configured pipeline through the SHIPPED
---rescue options (create_problem's target_budget / target_only_objective).
---@param overrides table<string, number>? observe-price shortage overrides
---@param target_budget number? upper limit on sum(elastic)
---@param target_only boolean? stage-1 target-only objective
local function build_ship(constraints, lines, overrides, target_budget, target_only)
    local opts
    if CONFIG == "hardgate" then
        opts = { shortage_cost_overrides = overrides }
    else
        opts = { reachability_gating = false, reachability_soft_gate_k = SOFT_GATE_K,
            shortage_cost_overrides = overrides }
    end
    opts.target_budget = target_budget
    opts.target_only_objective = target_only
    local ok, p = pcall(create_problem.create_problem, "ship", constraints, lines, nil, opts)
    if not ok then return nil end
    return p
end

local function build_solve_ship(constraints, lines, overrides, target_budget)
    local p = build_ship(constraints, lines, overrides, target_budget)
    if not p then return nil, "build-error", nil, nil end
    local s, v = solve(p)
    if s ~= "finished" then return p, s, nil, nil end
    return p, s, v.x, v.s
end

---The lexicographic target rescue. Returns the (possibly replaced) baseline
---plus the budget limit to thread through later builds, and the solve count.
---@return Problem prob, table x, table s, number? budget_limit, integer solves, number tmin
local function rescue_target(constraints, lines, prob, x0, s0)
    local T0 = ref.total_of(prob, x0, ref.TARGET_KINDS)
    if not RESCUE or T0 <= RESCUE_TRIGGER then return prob, x0, s0, nil, 0, -1 end

    -- Stage 1: minimize the target relaxation alone on the same build shape.
    local p1 = build_ship(constraints, lines, nil, nil, true)
    if not p1 then return prob, x0, s0, nil, 0, -1 end
    local s1, v1 = solve(p1)
    if s1 ~= "finished" then return prob, x0, s0, nil, 1, -1 end
    local tmin = ref.total_of(p1, v1.x, ref.TARGET_KINDS)
    if tmin >= T0 then return prob, x0, s0, nil, 1, tmin end -- no headroom; keep baseline

    -- Re-solve at ship costs under the locked target budget.
    local limit = tmin * (1 + BUDGET_REL) + BUDGET_ABS
    local p2, s2, x2, sl2 = build_solve_ship(constraints, lines, nil, limit)
    if s2 ~= "finished" or not x2 then return prob, x0, s0, nil, 2, tmin end
    return p2, x2, sl2, limit, 2, tmin
end

---The shipped pipeline with the rescue inserted after the baseline. The
---observer's observe/verify builds carry the budget row.
local function solve_shipped(constraints, lines)
    local prob, state, x0, s0 = build_solve_ship(constraints, lines, nil, nil)
    if state ~= "finished" or not x0 then return nil, state, nil, 1, 0, -1 end
    local solves = 1

    local budget_limit, rsolves, tmin
    prob, x0, s0, budget_limit, rsolves, tmin = rescue_target(constraints, lines, prob, x0, s0)
    solves = solves + rsolves
    local rescued = budget_limit and 1 or (rsolves > 0 and -1 or 0)

    if CONFIG == "hardgate" then return prob, "finished", x0, solves, rescued, tmin end

    local plan = op.collect_plan(prob.primals, x0, s0 or {}, lines)
    if not plan then return prob, "finished", x0, solves, rescued, tmin end

    for _, gid in ipairs(plan.groups) do
        local pobs, sobs, xobs = build_solve_ship(constraints, lines, op.observe_overrides(plan, gid), budget_limit)
        solves = solves + 1
        if sobs == "finished" and xobs then
            op.apply_observe(plan, gid, pobs.primals, xobs)
        else
            for _, k in ipairs(plan.keys) do if k.group == gid then k.frozen = true end end
        end
    end

    local round, final_prob, final_x = 0, prob, x0
    while round < op.MAX_ROUNDS do
        round = round + 1
        local pr, sr, xr = build_solve_ship(constraints, lines, op.verify_overrides(plan), budget_limit)
        solves = solves + 1
        if sr ~= "finished" or not xr then break end
        final_prob, final_x = pr, xr
        if not op.apply_verify(plan, xr, round) then break end
    end
    return final_prob, "finished", final_x, solves, rescued, tmin
end

local COLS = { "label", "n_mats", "ref_state", "T_ref", "Vp_ref", "Vc_ref", "Vf_ref", "M_ref", "S_ref", "Nv_ref", "ref_steps", "ref_cached",
    "ship_state", "T_ship", "Vp_ship", "Vc_ship", "Vf_ship", "M_ship", "S_ship", "Nv_ship", "ship_solves", "rescued", "T_min" }

local function process(prob, label, path, emit)
    local intermediates = ref.intermediates(prob.normalized_lines)

    local entry = refcache.load(path)
    local cached = entry ~= nil
    if not entry then
        local r = ref.solve_reference(prob.constraints, prob.normalized_lines)
        local Nv_r = (r.state == "finished" and r.x)
            and ref.violation_count(r.problem, r.x, intermediates) or -1
        entry = {
            state = r.state, n_mats = r.n_mats,
            T = r.T, Vp = r.Vp, Vc = r.Vc, Vf = r.Vf, M = r.M, S = r.S,
            Nv = Nv_r, steps = r.steps,
            producible = set_to_list(r.producible),
            consumable = set_to_list(r.consumable),
        }
        refcache.store(path, entry)
    end
    local producible = list_to_set(entry.producible)
    local consumable = list_to_set(entry.consumable)

    local sp, sstate, sx, ssolves, rescued, tmin = solve_shipped(prob.constraints, prob.normalized_lines)
    local T_s, Vp_s, Vc_s, Vf_s, M_s, S_s, Nv_s = -1, -1, -1, -1, -1, -1, -1
    if sstate == "finished" and sx then
        T_s = ref.total_of(sp, sx, ref.TARGET_KINDS)
        Vp_s, Vc_s, Vf_s = ref.violation_split(sp, sx, intermediates, producible, consumable)
        M_s = ref.total_of(sp, sx, ref.MACHINE_KINDS)
        S_s = ref.total_of(sp, sx, ref.SURPLUS_KINDS)
        Nv_s = ref.violation_count(sp, sx, intermediates)
    end

    emit({ label = label, n_mats = entry.n_mats, ref_state = entry.state, T_ref = entry.T, Vp_ref = entry.Vp,
        Vc_ref = entry.Vc, Vf_ref = entry.Vf, M_ref = entry.M, S_ref = entry.S, Nv_ref = entry.Nv,
        ref_steps = entry.steps, ref_cached = cached and 1 or 0,
        ship_state = sstate, T_ship = T_s, Vp_ship = Vp_s, Vc_ship = Vc_s, Vf_ship = Vf_s,
        M_ship = M_s, S_ship = S_s, Nv_ship = Nv_s, ship_solves = ssolves,
        rescued = rescued, T_min = tmin })
end

-- ---- main -------------------------------------------------------------------
local out_path, manifest_path, files = nil, nil, {}
do local i = 1; while arg[i] do local a = arg[i]
    if a == "--out" then i = i + 1; out_path = arg[i]
    elseif a == "--manifest" then i = i + 1; manifest_path = arg[i]
    else files[#files + 1] = a end; i = i + 1 end end
if manifest_path then for line in io.lines(manifest_path) do line = line:gsub("%s+$", ""); if line ~= "" then files[#files + 1] = line end end end

local sink = io.write; local out_file = nil
if out_path then out_file = assert(io.open(out_path, "w")); sink = function(s) out_file:write(s) end end
local function fmt(v) if v == nil then return "NA" end if type(v) == "number" then return string.format("%.6g", v) end return tostring(v) end
if out_path then sink("#" .. table.concat(COLS, "\t") .. "\n") end
local function emit(r) local o = {}; for _, k in ipairs(COLS) do o[#o + 1] = fmt(r[k]) end; sink(table.concat(o, "\t") .. "\n") end

for _, path in ipairs(files) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local label = "seed=" .. tostring(prob.meta and prob.meta.seed) .. "|" .. (path:match("([^/\\]+)%.lua$") or path)
        local ok, err = pcall(process, prob, label, path, emit)
        if not ok then sink("# ERROR " .. label .. ": " .. tostring(err) .. "\n") end
    end
end
if out_file then out_file:close() end
