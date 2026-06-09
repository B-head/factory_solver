---@diagnostic disable: undefined-global
-- End-to-end driver for the SHIPPED observe-price module (solver/observe_price.lua)
-- on the production soft-gate config. Unlike observe_price_lib.lua (a research COPY
-- of the loop that predates the module), this drives the real module synchronously,
-- mirroring manage/pre_solve.lua's incremental state machine, so it measures exactly
-- what production does -- including reading each escape's real primal.cost (the soft
-- gate's 256x secondary shortages) through the module's cost-weighted escape_cost.
--
-- Per dump it emits the convergence outcome: total solves, one-shot vs corrected
-- keys, avoidable still importing at the end (a genuine miss), collapse, over-dump.
-- RAW only. Single-shot contract: `<lua> drive_observe_e2e.lua <dump>` -> one or
-- more rows; run_corpus.ps1 fans it across the corpus (Collect '^e2e').

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"
local op = require "solver/observe_price"

local TOL, ITER = 1e-7, 800
local SOFT_GATE_K = 256
local OPTS_BASE = { reachability_gating = false, reachability_soft_gate_k = SOFT_GATE_K }

-- A/B switch: FS_LEGACY=1 restores the pre-recalibration predictor (mass-weighted
-- escape_cost over surplus_sink + shortage_source only, K_PRED=1.5) so the same
-- driver measures BEFORE vs AFTER the cost-weighted + K=2.0 change. Default = the
-- shipped module as-is.
if os.getenv("FS_LEGACY") then
    op.K_PRED = 1.5
    op.escape_cost = function(primals, x, exclude)
        local s = 0
        for key, p in pairs(primals) do
            if (p.kind == "surplus_sink" or p.kind == "shortage_source") and not exclude[key] then
                s = s + math.abs(x[key] or 0)
            end
        end
        return s
    end
end

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end

-- Build under the soft-gate config with optional per-material shortage overrides
-- (the same channel pre_solve feeds the module's observe/verify maps through).
local function build_solve(constraints, lines, overrides)
    local ok, p = pcall(create_problem.create_problem, "e2e", constraints, lines, nil,
        { reachability_gating = false, reachability_soft_gate_k = SOFT_GATE_K,
          shortage_cost_overrides = overrides })
    if not ok then return nil, "build-error", nil end
    local s, v = solve(p)
    if s ~= "finished" then return p, s, nil end
    return p, s, v.x
end

local function surplus_mass(primals, x)
    local s = 0
    for key, p in pairs(primals) do
        if p.kind == "surplus_sink" then s = s + math.abs(x[key] or 0) end
    end
    return s
end

local COLS = {
    "tag", "label", "n_keys", "n_groups", "n_oneshot", "n_corrected", "n_frozen",
    "total_solves", "avoidable_remaining", "base_cheat", "final_cheat",
    "collapse", "over_dump_ratio",
}

local function process(constraints, lines, label, emit)
    -- Baseline (soft-gate only).
    local prob, state, x0 = build_solve(constraints, lines, nil)
    if state ~= "finished" or not x0 then return end
    local primals = prob.primals
    local base = ed.detect({ x = x0 }, primals)
    local relax0 = op.target_relax(primals, x0)
    local surp0 = surplus_mass(primals, x0)

    local plan = op.collect_plan(primals, x0, lines)
    if not plan then return end -- nothing to fabricate; baseline stands

    local total_solves = 1

    -- Phase 2: per-group observe (one solve each).
    for _, gid in ipairs(plan.groups) do
        local ov = op.observe_overrides(plan, gid)
        local pobs, sobs, xobs = build_solve(constraints, lines, ov)
        total_solves = total_solves + 1
        if sobs == "finished" and xobs then
            op.apply_observe(plan, gid, pobs.primals, xobs)
        else
            -- observe failed to solve: freeze the group (import stays).
            for _, k in ipairs(plan.keys) do if k.group == gid then k.frozen = true end end
        end
    end

    -- Phase 3+: verify + correct loop.
    local round = 0
    local final_prob, final_x = prob, x0
    while round < op.MAX_ROUNDS do
        round = round + 1
        local ov = op.verify_overrides(plan)
        local pr, sr, xr = build_solve(constraints, lines, ov)
        total_solves = total_solves + 1
        if sr ~= "finished" or not xr then break end
        final_prob, final_x = pr, xr
        local live = op.apply_verify(plan, xr, round)
        if not live then break end
    end

    -- Outcomes.
    local th = op.park_threshold(final_x, final_prob.primals)
    local n_oneshot, n_corrected, n_frozen, avoidable_remaining = 0, 0, 0, 0
    for _, k in ipairs(plan.keys) do
        if k.frozen then
            n_frozen = n_frozen + 1
        elseif k.resolved_round == 1 then
            n_oneshot = n_oneshot + 1
        elseif k.resolved_round > 1 then
            n_corrected = n_corrected + 1
        end
        if not k.frozen and (final_x[k.key] or 0) > th then
            avoidable_remaining = avoidable_remaining + 1
        end
    end
    local final = ed.detect({ x = final_x }, final_prob.primals)
    local relax_f = op.target_relax(final_prob.primals, final_x)
    local surp_f = surplus_mass(final_prob.primals, final_x)

    emit({
        tag = "e2e", label = label, n_keys = #plan.keys, n_groups = #plan.groups,
        n_oneshot = n_oneshot, n_corrected = n_corrected, n_frozen = n_frozen,
        total_solves = total_solves, avoidable_remaining = avoidable_remaining,
        base_cheat = base.cheat, final_cheat = final.cheat,
        collapse = (relax_f > relax0 + 1e-4) and "Y" or "n",
        over_dump_ratio = (surp0 > 1e-9) and (surp_f / surp0) or (surp_f > 1e-6 and 999 or 1),
    })
end

-- ---- main -------------------------------------------------------------------
local files = {}
for _, a in ipairs(arg) do files[#files + 1] = a end

local printed_header = false
local function fmt(v) if type(v) == "number" then return string.format("%.6g", v) end return tostring(v) end
local function emit(r)
    if not printed_header then io.write("#" .. table.concat(COLS, "\t") .. "\n"); printed_header = true end
    local o = {}
    for _, k in ipairs(COLS) do o[#o + 1] = fmt(r[k]) end
    io.write(table.concat(o, "\t") .. "\n")
end

for _, path in ipairs(files) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local label = "seed=" .. tostring(prob.meta and prob.meta.seed) ..
            "|" .. (path:match("([^/\\]+)%.lua$") or path)
        pcall(process, prob.constraints, prob.normalized_lines, label, emit)
    end
end
