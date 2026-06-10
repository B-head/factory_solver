---@diagnostic disable: undefined-global
-- Grade the SHIPPED pipeline against the problem-definition reference solver.
--
-- Per dump, two solutions are produced and measured with the SAME yardsticks
-- (the three lexicographic tiers of tests/research/reference_solver.lua):
--   ref   the staged lexicographic optimum (the definition's gold answer)
--   ship  the shipped config -- soft gate (reachability_soft_gate_k = 256) plus
--         the observe-price fixed point, replicated synchronously exactly like
--         drive_observe_e2e.lua (same caveats: no two-pass diagnose forced
--         imports, no keep-best revert).
-- The row reports T (target violation), V (symmetric intermediate violation =
-- shortage + surplus) and M (machine count = sum of recipe variables) for both,
-- so the analysis can bucket: ship loses tier 1 (dT > 0), loses tier 2
-- (dV > 0), wins tier 2 (dV < 0 would mean the reference is NOT optimal -- a
-- bug in one of the two), loses tier 3 (dV ~ 0 and dM > 0). RAW numbers only.
--
-- Single-shot contract: `<lua> probe_reference_compare.lua <dump>` -> one row.
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_reference_compare.lua -Collect '^seed=' -Out <tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local problem_dump = require "tests/problem_dump"
local op = require "solver/observe_price"
local ref = require "tests/research/reference_solver"

local TOL, ITER = 1e-7, 800
local SOFT_GATE_K = 256
local SHIP_OPTS = { reachability_gating = false, reachability_soft_gate_k = SOFT_GATE_K }

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end

local function build_solve_ship(constraints, lines, overrides)
    local ok, p = pcall(create_problem.create_problem, "ship", constraints, lines, nil,
        { reachability_gating = false, reachability_soft_gate_k = SOFT_GATE_K,
            shortage_cost_overrides = overrides })
    if not ok then return nil, "build-error", nil, nil end
    local s, v = solve(p)
    if s ~= "finished" then return p, s, nil, nil end
    return p, s, v.x, v.s
end

---The shipped pipeline, synchronous (drive_observe_e2e's replication): soft-gate
---baseline, then the observe-price fixed point when a plan exists. Returns the
---final problem/x plus the solve count.
local function solve_shipped(constraints, lines)
    local prob, state, x0, s0 = build_solve_ship(constraints, lines, nil)
    if state ~= "finished" or not x0 then return nil, state, nil, 1 end
    local solves = 1

    local plan = op.collect_plan(prob.primals, x0, s0 or {}, lines)
    if not plan then return prob, "finished", x0, solves end

    for _, gid in ipairs(plan.groups) do
        local pobs, sobs, xobs = build_solve_ship(constraints, lines, op.observe_overrides(plan, gid))
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
        local pr, sr, xr = build_solve_ship(constraints, lines, op.verify_overrides(plan))
        solves = solves + 1
        if sr ~= "finished" or not xr then break end
        final_prob, final_x = pr, xr
        if not op.apply_verify(plan, xr, round) then break end
    end
    return final_prob, "finished", final_x, solves
end

local COLS = { "label", "n_mats", "ref_state", "T_ref", "Vp_ref", "Vf_ref", "M_ref", "S_ref", "ref_steps",
    "ship_state", "T_ship", "Vp_ship", "Vf_ship", "M_ship", "S_ship", "ship_solves" }

local function process(prob, label, emit)
    local r = ref.solve_reference(prob.constraints, prob.normalized_lines)

    -- The shipped build's deficit promotion turns some intermediate violations
    -- into free |initial_source| flows; measure with the definition's yardstick
    -- (violation_of counts those back in) so V is comparable across builds.
    local intermediates = ref.intermediates(prob.normalized_lines)
    local sp, sstate, sx, ssolves = solve_shipped(prob.constraints, prob.normalized_lines)
    local T_s, Vp_s, Vf_s, M_s, S_s = -1, -1, -1, -1, -1
    if sstate == "finished" and sx then
        T_s = ref.total_of(sp, sx, ref.TARGET_KINDS)
        Vp_s, Vf_s = ref.violation_split(sp, sx, intermediates, r.producible)
        M_s = ref.total_of(sp, sx, ref.MACHINE_KINDS)
        S_s = ref.total_of(sp, sx, ref.SURPLUS_KINDS)
    end

    emit({ label = label, n_mats = r.n_mats, ref_state = r.state, T_ref = r.T, Vp_ref = r.Vp,
        Vf_ref = r.Vf, M_ref = r.M, S_ref = r.S, ref_steps = r.steps, ship_state = sstate,
        T_ship = T_s, Vp_ship = Vp_s, Vf_ship = Vf_s, M_ship = M_s, S_ship = S_s,
        ship_solves = ssolves })
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
        local ok, err = pcall(process, prob, label, emit)
        if not ok then sink("# ERROR " .. label .. ": " .. tostring(err) .. "\n") end
    end
end
if out_file then out_file:close() end
