---@diagnostic disable: undefined-global
-- SAFE-GATE: predict which active violation-elastics can be CONCENTRATED (their L2
-- quad freed / cost lowered) WITHOUT breaking the factory. A calibrated logistic
-- "weather forecast" over CHEAP features read from a single baseline L2 solve + the
-- material graph -- no per-candidate perturbation solve, no KKT factorization.
--
-- Use it for the asymmetric, practically-useful direction: identifying SAFE variables.
-- Held-out validation (pyanodon corpus, seed-split): the model is well calibrated and
-- the SAFE end is far cleaner than the breaker end --
--   bottom 5% predicted-safest = 100% actually safe, bottom 10% = 99.8% (rdist < 0.1).
-- Confidence-gated, per factory (act only when a candidate's predicted P < tau):
--   tau 0.005 -> 37% of factories have a candidate, 100% of those are truly safe
--   tau 0.015 -> 44% coverage, 99.6% reliability
--   tau 0.040 -> 51% coverage, 99.4% reliability
--   tau 0.120 -> 53% coverage, 99.4% reliability
-- So "this variable won't break" is ~99%+ reliable WHEN the gate is confident; it
-- abstains (returns no safe candidate) on factories where nothing looks safe rather
-- than guessing. "break" is rdist > 0.1 (more than ~10% of machine-activity moves).
--
-- CAVEATS: trained on the synthetic pyanodon explorer corpus; it forecasts the L2
-- (QP) "free the quad" perturbation specifically. ~0.12 of the discrimination is
-- irreducible even with the per-candidate solve, so this is a probability, not a
-- proof. It is a RESEARCH heuristic, not shipped solver logic.
--
-- Model: FREE-only logistic, AUC 0.855 held-out (== the KKT-augmented model, so KKT
-- is dropped). Coefficients baked from tests/research (S:/tmp/train_safe_gate.lua).
--
--   as a module:  local sg = require "tests/research/safe_gate"
--                 local res = sg.safe(problem, packed, normalized_lines, tau)
--   as a CLI:     lua tests/research/safe_gate.lua <dump> [tau]

require "tests/headless_env"
local D = require "tests/research/dissect"
local tn = require "manage/typed_name"

local M = {}

-- ---- baked model (FREE features; order MUST match the feature builder below) -------
local FNAMES = { "log_net", "log_through", "log_xv", "l_inDeg", "l_outDeg", "l_sccSize",
    "bridge", "kind", "net2", "thr2", "net_thr", "net_br", "thr_out", "xv_in", "out_scc" }
local MEAN = { -3.0196004, -1.24403, -3.1185993, 0.88361579, 1.0157711, 1.2242701, 0.3901147,
    0.50564749, 15.254087, 7.8889532, 7.9778912, -0.90005271, -1.1075249, -2.7577548, 1.294458 }
local STD = { 2.4771153, 2.5182023, 1.8681639, 0.32069966, 0.45482828, 1.4464455, 0.48777579,
    0.49996811, 21.798246, 19.74455, 20.528865, 1.8556867, 2.4298485, 1.993813, 1.7909351 }
local W = { 0.47409022, 1.2667157, -0.71857454, 0.056424376, 0.10459452, 0.15724879, -0.2380313,
    -0.022179832, -2.0793812, -0.47671515, 0.034960199, 0.75509143, 0.019864467, 0.028187078, -0.080540545 }
local B = -1.5307572

-- Recommended confidence thresholds (held-out coverage / reliability above).
M.PROFILES = {
    strict   = 0.005, -- ~100% reliable, ~37% of factories covered
    balanced = 0.040, -- ~99.4% reliable, ~51% covered
    lenient  = 0.120, -- ~99.4% reliable, ~53% covered
}

local function lg(v) return math.log((v or 0) + 1e-12) / math.log(10) end
local function l1p(v) return math.log(1 + (v or 0)) end

---Feature vector (same transform/order as the training script).
local function feats(net, through, xv, inDeg, outDeg, sccSize, bridge, kind)
    local ln, lt, lx = lg(net), lg(through), lg(xv)
    local li, lo, ls = l1p(inDeg), l1p(outDeg), l1p(sccSize)
    return { ln, lt, lx, li, lo, ls, bridge, kind,
        ln * ln, lt * lt, ln * lt, ln * bridge, lt * lo, lx * li, lo * ls }
end

---Breakage probability from a feature vector (standardize -> logistic).
---@param f number[]
---@return number
function M.probability(f)
    local t = B
    for i = 1, #W do t = t + W[i] * (f[i] - MEAN[i]) / STD[i] end
    if t < -30 then return 0 elseif t > 30 then return 1 end
    return 1 / (1 + math.exp(-t))
end

local function vname(typed) return tn.typed_name_to_variable_name(typed) end

---Score every ACTIVE violation-elastic of a solved L2 problem: its predicted breakage
---probability if its quad is freed (concentrated). Cheap: one physical-flow pass + a
---material-graph build, no perturbation solve.
---@param problem Problem A built (L2-shaped) Problem.
---@param packed PackedVariables The solved baseline (packed.x keyed by primal key).
---@param normalized_lines NormalizedProductionLine[] The dump's lines (for graph + flows).
---@param thresh number? Active cutoff on |x| (default 1e-6).
---@return { key: string, material: string, kind: string, prob: number, net: number, through: number }[] #sorted by prob ascending (safest first)
function M.score(problem, packed, normalized_lines, thresh)
    thresh = thresh or 1e-6
    local px = packed.x or {}
    local lines = D.all_lines(normalized_lines, problem)
    local scc = D.cyclic_sccs(lines)
    local prod, cons = D.physical_flows(lines, px, { fuel = true, eps = 1e-9 })

    -- producer / consumer recipe counts + temperature-bridge coupling
    local prodc, consc = {}, {}
    for _, line in ipairs(lines) do
        for _, p in ipairs(line.products) do local m = vname(p); prodc[m] = (prodc[m] or 0) + 1 end
        if line.fuel_burnt_result then local m = vname(line.fuel_burnt_result); prodc[m] = (prodc[m] or 0) + 1 end
        for _, ig in ipairs(line.ingredients) do local m = vname(ig); consc[m] = (consc[m] or 0) + 1 end
        if line.fuel_ingredient then local m = vname(line.fuel_ingredient); consc[m] = (consc[m] or 0) + 1 end
    end
    local bridge_mat = {}
    for _, line in ipairs(problem.bridges or {}) do
        for _, p in ipairs(line.products) do bridge_mat[vname(p)] = true end
        for _, ig in ipairs(line.ingredients) do bridge_mat[vname(ig)] = true end
    end

    local out = {}
    for key, p in pairs(problem.primals) do
        if (p.kind == "shortage_source" or p.kind == "surplus_sink") and math.abs(px[key] or 0) > thresh then
            local m = p.material
            local net = math.abs((prod[m] or 0) - (cons[m] or 0))
            local through = (prod[m] or 0) + (cons[m] or 0)
            local f = feats(net, through, math.abs(px[key] or 0),
                prodc[m] or 0, consc[m] or 0,
                (scc.tag[m] and #scc.members[scc.tag[m]]) or 0,
                bridge_mat[m] and 1 or 0, p.kind == "surplus_sink" and 1 or 0)
            out[#out + 1] = { key = key, material = m, kind = p.kind,
                prob = M.probability(f), net = net, through = through }
        end
    end
    table.sort(out, function(a, b) return a.prob < b.prob end)
    return out
end

---Confidence-gated safe set: variables whose predicted breakage probability is below
---`tau` (concentrating them is forecast safe). Returns the safe list (safest first),
---an `abstain` flag (true = no variable is confidently safe here -> do not concentrate
---blind), and the full scored list.
---@param problem Problem
---@param packed PackedVariables
---@param normalized_lines NormalizedProductionLine[]
---@param tau number? Confidence threshold (default M.PROFILES.balanced = 0.04).
---@return { safe: table[], abstain: boolean, scored: table[], tau: number }
function M.safe(problem, packed, normalized_lines, tau)
    tau = tau or M.PROFILES.balanced
    local scored = M.score(problem, packed, normalized_lines)
    local safe = {}
    for _, s in ipairs(scored) do if s.prob < tau then safe[#safe + 1] = s end end
    return { safe = safe, abstain = #safe == 0, scored = scored, tau = tau }
end

-- ---- CLI self-test ----------------------------------------------------------------
if arg and arg[0] and arg[0]:find("safe_gate") then
    local create_problem = require "solver/create_problem"
    local problem_dump = require "tests/problem_dump"
    local lp = require "solver/linear_programming"
    local VQ, VF, EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10
    local path = arg[1] or error("usage: lua tests/research/safe_gate.lua <dump> [tau]")
    local tau = tonumber(arg[2]) or M.PROFILES.balanced
    local prob = assert(problem_dump.load_problem(path))
    local problem = create_problem.create_problem("l2", prob.constraints, prob.normalized_lines, nil,
        { reachability_gating = false, deficit_seeding = false, catalyst_closure = false,
          surplus_sink_gating = false, recipe_epsilon = EPS })
    create_problem.shape_l2(problem, VQ, VF)
    local state, it, vars, last, steps = "ready", nil, nil, nil, 0
    repeat
        local ok, s, i2, v = pcall(lp.solve, problem, state, it, vars, prob.meta.tolerance, prob.meta.iterate_limit)
        if not ok then state = "errored"; break end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
    if state ~= "finished" then print("baseline solve state=" .. tostring(state)); return end

    local res = M.safe(problem, last, prob.normalized_lines, tau)
    io.write(string.format("safe-gate  %s  tau=%.3f  (active elastics=%d)\n",
        path:match("[^/\\]+$"), tau, #res.scored))
    if res.abstain then
        io.write("  ABSTAIN: no variable is confidently safe to concentrate here.\n")
    else
        io.write(string.format("  SAFE to concentrate (%d), safest first:\n", #res.safe))
        for i = 1, math.min(10, #res.safe) do
            local s = res.safe[i]
            io.write(string.format("    P=%.4f  %-30s [%s]\n", s.prob, s.material, s.kind))
        end
    end
    io.write("  riskiest (avoid), top 5:\n")
    for i = #res.scored, math.max(1, #res.scored - 4), -1 do
        local s = res.scored[i]
        io.write(string.format("    P=%.4f  %-30s [%s]\n", s.prob, s.material, s.kind))
    end
end

return M
