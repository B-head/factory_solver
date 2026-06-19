---@diagnostic disable: undefined-global
-- Enumerate solutions that live on the SAME target face (degenerate face after
-- tier-T is fixed). The escapes (shortage_source = import, surplus_sink = dump)
-- carry an elastic-net objective  lin*x + 1/2*quad*x^2  whose two knobs sweep a
-- one-parameter family between the two named corners of that face:
--     lin=1, quad=0   -> pure L1  : sparsest vertex (concentrate import in few)
--     lin=0, quad=2   -> pure L2  : QP interior     (spread thin across many)
--   lin=1, quad=small -> elastic-net : in between, smoothly
-- Targets are pinned hard at BIG (raw/final free), exactly as the QP probes do, so
-- every row is on the identical target face -- only the within-face selection rule
-- differs. Reports the concentration metrics per row, then a per-escape readout of
-- HOW the same materials get served (corner vs even split) across the sweep.
--
--   luajit tests/research/probe_face_spectrum.lua [dumpfile] [BIG]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e6
local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }
local prob = assert(problem_dump.load_problem(PATH))

-- pin targets hard at BIG, drop the target-elastic/headroom machinery (verbatim
-- from probe_qp_minimizes -- keeps every build on the same target face).
local function strip(problem)
    local rm = {}
    for _, c in ipairs(prob.constraints) do
        local dual = vk.limit(tn.typed_name_to_variable_name(c))
        if problem.duals[dual] then problem.duals[dual].limit = BIG end
        rm[vk.elastic(dual)] = true; rm[vk.pos_slack(dual)] = true; rm[vk.neg_slack(dual)] = true
    end
    for key, p in pairs(problem.primals) do if p.kind == "elastic" or p.kind == "headroom" then rm[key] = true end end
    for key in pairs(rm) do if problem.primals[key] then problem.primals[key] = nil; problem.subject_terms[key] = nil end end
    local keys = {}; for k in pairs(problem.primals) do keys[#keys + 1] = k end; table.sort(keys)
    for i, k in ipairs(keys) do problem.primals[k].index = i end
    problem.primal_length = #keys
end
local function solve(pp)
    local state, it, vars, last, steps = "ready", nil, nil, nil, 0
    repeat
        local ok, s, i2, v = pcall(lp.solve, pp, state, it, vars, prob.meta.tolerance, prob.meta.iterate_limit)
        if not ok then state = "errored"; break end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
    return (last and last.x) or {}, state
end

-- elastic-net build: linear weight `lin` + quadratic curvature `quad` on every
-- violation escape. quad==0 means a pure linear column (no set_quad call). ALL
-- non-escape costs (recipe machine costs etc.) are zeroed so the objective is the
-- pure escape norm -- machine count is a separate tier, not mixed into the norm.
local function build_net(lin, quad)
    local problem = create_problem.create_problem("net", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        p.cost = 0
        if VIO[p.kind] then
            p.cost = lin
            if quad > 0 then problem:set_quad(key, quad) end
        elseif FREEK[p.kind] then
            problem:set_quad(key, 0)
        end
    end
    strip(problem)
    return problem
end

-- escape key set is identical in every build; grab it once from a plain build.
local vio_keys = {}
do
    local p0 = build_net(1, 0)
    for k, p in pairs(p0.primals) do if VIO[p.kind] then vio_keys[#vio_keys + 1] = k end end
    table.sort(vio_keys)
end

local function park_thr(problem, x)
    local maxr = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
    return math.max(1e-9, maxr * 1e-6)
end
local function metrics(problem, x)
    local thr = park_thr(problem, x)
    local nesc, l1, l2, maxe = 0, 0, 0, 0
    for _, k in ipairs(vio_keys) do
        local v = math.abs(x[k] or 0)
        l1 = l1 + v; l2 = l2 + v * v
        if v > thr then nesc = nesc + 1 end
        if v > maxe then maxe = v end
    end
    local nrec = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" and math.abs(x[k] or 0) > thr then nrec = nrec + 1 end end
    return nesc, l1, l2, nrec, maxe
end

-- L-infinity (Chebyshev): minimize t  s.t.  esc_i <= t for every escape -> the
-- peak escape is equalized down as far as the face allows. `eps` is an optional
-- tiny L1 tiebreak so that, among the equal-peak optima, the least-total-mass one
-- is chosen (eps=0 lets the zero-cost escapes float anywhere under the ceiling).
local function build_linf(eps)
    local problem = create_problem.create_problem("linf", prob.constraints, prob.normalized_lines, nil, nil)
    for key, p in pairs(problem.primals) do
        p.cost = VIO[p.kind] and (eps or 0) or 0  -- only t (added below) carries cost 1
    end
    strip(problem)
    -- t (cost 1) appended after strip's reindex; cap rows esc_i - t <= 0
    local tkey = "|linf_t|"
    problem:add_objective(tkey, 1, false, "linf_t")
    for _, k in ipairs(vio_keys) do
        if problem.primals[k] then
            local dual = "|linf_cap|" .. k
            problem:add_upper_limit_constraint(dual, 0)
            problem:add_subject_term(k, dual, 1)
            problem:add_subject_term(tkey, dual, -1)
        end
    end
    return problem, tkey
end

io.write("============ spectrum of solutions on one target face ============\n")
io.write(string.format("file=%s  BIG=%g  (escapes=%d)\n\n", PATH:match("[^/]+$"), BIG, #vio_keys))
io.write(string.format("%-14s %-7s %-6s %-13s %-13s %-7s %-12s\n",
    "solution", "state", "n_esc", "L1 |esc|", "L2 esc^2", "n_rec", "max 1 esc"))

local solved = {}  -- label -> x

-- the elastic-net sweep: two named corners + three interiors (concentration->spread)
local SWEEP = {
    { "L1 (linear)",  1, 0 },
    { "net q=1e-3",   1, 1e-3 },
    { "net q=1e-1",   1, 1e-1 },
    { "net q=1",      1, 1 },
    { "L2 / QP",      0, 2 },
}
for _, row in ipairs(SWEEP) do
    local label, lin, quad = row[1], row[2], row[3]
    local p = build_net(lin, quad)
    local x, st = solve(p)
    solved[label] = x
    local nesc, l1, l2, nrec, maxe = metrics(p, x)
    io.write(string.format("%-14s %-7s %-6d %-13.6g %-13.6g %-7d %-12.6g\n",
        label, st, nesc, l1, l2, nrec, maxe))
end

-- the p->inf end: pure Chebyshev and the eps-L1-broken version
for _, row in ipairs({ { "Linf (pure)", 0 }, { "Linf+eps", 1e-4 } }) do
    local label, eps = row[1], row[2]
    local p, tkey = build_linf(eps)
    local x, st = solve(p)
    solved[label] = x
    local nesc, l1, l2, nrec, maxe = metrics(p, x)
    io.write(string.format("%-14s %-7s %-6d %-13.6g %-13.6g %-7d %-12.6g  t=%.6g\n",
        label, st, nesc, l1, l2, nrec, maxe, x[tkey] or 0))
end

-- per-escape readout: how the same materials are served at the two corners + mid.
-- rank by combined magnitude across L1 and L2 so the materials that actually move
-- bubble up. material label comes from Primal.material (never parsed off the key).
local matof, kindof = {}, {}
do
    local p0 = build_net(1, 0)
    for _, k in ipairs(vio_keys) do
        local p = p0.primals[k]
        matof[k] = p and tostring(p.material) or k
        kindof[k] = (p and p.kind == "surplus_sink") and "dump" or "imp"
    end
end
local xL1, xL2, xLinf = solved["L1 (linear)"], solved["L2 / QP"], solved["Linf+eps"]
local ranked = {}
for _, k in ipairs(vio_keys) do
    local s = math.abs(xL1[k] or 0) + math.abs(xL2[k] or 0) + math.abs(xLinf[k] or 0)
    if s > 1e-6 then ranked[#ranked + 1] = { k = k, s = s } end
end
table.sort(ranked, function(a, b) return a.s > b.s end)

io.write("\n---- per-escape: how the SAME materials get served (top 18 by combined |x|) ----\n")
io.write(string.format("%-4s %-32s %-12s %-12s %-12s\n", "kind", "material", "L1 x", "L2 x", "Linf x"))
for i = 1, math.min(18, #ranked) do
    local k = ranked[i].k
    io.write(string.format("%-4s %-32s %-12.6g %-12.6g %-12.6g\n",
        kindof[k], matof[k]:sub(1, 32), xL1[k] or 0, xL2[k] or 0, xLinf[k] or 0))
end
