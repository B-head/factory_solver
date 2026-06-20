---@diagnostic disable: undefined-global
-- SINGLE-SHOT corpus driver for the CONCENTRATION-HEURISTIC question (run via
-- run_corpus.ps1 -Collect '^pt'). For a sample of active violation-elastics per dump,
-- free the quad (free mode) and re-solve, then emit one `pt` line per elastic with:
--   GROUND TRUTH (needs the perturbed solve) -- the "did it break the factory" outcome:
--     rdist  = Sum|Δ recipe activity| / baseline total recipe activity (machine-move frac)
--     match  = sibling shed / E growth   (1 = pure concentration, 0 = structural new flow)
--     newRaw = Sum(raw import increase) / baseline total recipe activity
--     grow   = E physical growth (phys/s),  blow = phys1/phys0
--   PREDICTOR B (needs the perturbed solve): cyc = cyclic-share (the wash fraction)
--   PREDICTOR A (STATIC, NO perturbed solve, from material_cycles):
--     inCyc  = material is in a cyclic SCC
--     sccSS  = that SCC is self-sustaining (a circulation exists; is_self_sustaining)
-- Tests: does A (static) or B (per-solve) predict low rdist (= safe to concentrate)?
--   lua tests/research/probe_concentrate_corpus.lua <dump>
require "tests/headless_env"
local R = require "tests/research/research_lib"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local mc = require "solver/material_cycles"
local D = R.dissect

local VQ, VF, EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10
local KSAMPLE = 30 -- probe ALL active elastics when <=30 (full safe/breaker coverage), else 30 spanning the range
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"

local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("pt ERR=load seed=" .. fid .. "\n"); return end

local function build()
    local p = create_problem.create_problem("l2", prob.constraints, prob.normalized_lines, nil,
        { reachability_gating = false, deficit_seeding = false, catalyst_closure = false,
          surplus_sink_gating = false, recipe_epsilon = EPS })
    create_problem.shape_l2(p, VQ, VF); return p
end
local function phys(problem, key, x)
    local p, t = problem.primals[key], problem.subject_terms[key]
    local c = (p and p.material and t and t[p.material]) or 1
    return math.abs(c * (x[key] or 0))
end

local base = build()
local x0, st0 = R.drive_solve(base, prob.meta)
if st0 ~= "finished" then io.write("pt ERR=baseline seed=" .. fid .. "\n"); return end

local lines = D.all_lines(prob.normalized_lines, base)
local scc = D.cyclic_sccs(lines)
local prod0, cons0 = D.physical_flows(lines, x0, { fuel = true, eps = 1e-9 })

local base_machines = 0
for k, p in pairs(base.primals) do if p.kind == "recipe" then base_machines = base_machines + math.abs(x0[k] or 0) end end
if base_machines < 1e-9 then base_machines = 1e-9 end

-- static predictor A: cache is_self_sustaining per cyclic-SCC tag (SCC-level, cheap).
local ss_cache = {}
local function scc_self_sustaining(tag)
    if tag == nil then return false end
    if ss_cache[tag] == nil then ss_cache[tag] = mc.is_self_sustaining(lines, scc.members[tag]) end
    return ss_cache[tag]
end

local function snap(problem, x)
    local viol, raw = {}, {}
    for k, p in pairs(problem.primals) do
        if p.kind == "shortage_source" or p.kind == "surplus_sink" then viol[k] = phys(problem, k, x)
        elseif p.kind == "initial_source" then raw[k] = phys(problem, k, x) end
    end
    return viol, raw
end
local viol0, raw0 = snap(base, x0)

local active = {}
for k, p in pairs(base.primals) do
    if (p.kind == "shortage_source" or p.kind == "surplus_sink") and math.abs(x0[k] or 0) > 1e-6 then
        active[#active + 1] = { key = k, mat = p.material, xv = math.abs(x0[k] or 0) }
    end
end
if #active == 0 then io.write("pt NOACTIVE seed=" .. fid .. "\n"); return end
table.sort(active, function(a, b) return a.xv > b.xv end)

-- sample across the magnitude range
local n, cnt, seen, sample = #active, math.min(KSAMPLE, #active), {}, {}
for i = 1, cnt do
    local idx = (cnt == 1) and 1 or math.floor((i - 1) * (n - 1) / (cnt - 1) + 0.5) + 1
    if not seen[idx] then seen[idx] = true; sample[#sample + 1] = active[idx] end
end

for _, e in ipairs(sample) do
    local problem = build(); problem:set_quad(e.key, 0)
    local x1, st1 = R.drive_solve(problem, prob.meta)
    local viol1, raw1 = snap(problem, x1)

    local g = (viol1[e.key] or 0) - (viol0[e.key] or 0)
    local shed = 0
    for k, v0 in pairs(viol0) do if k ~= e.key then local d = v0 - (viol1[k] or 0); if d > 0 then shed = shed + d end end end
    local new_raw = 0
    for k, v0 in pairs(raw0) do local inc = (raw1[k] or 0) - v0; if inc > 0 then new_raw = new_raw + inc end end
    local rdiff = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" then rdiff = rdiff + math.abs((x1[k] or 0) - (x0[k] or 0)) end end

    -- cyclic-share (predictor B) from the perturbed solve
    local prod1, cons1 = D.physical_flows(lines, x1, { fuel = true, eps = 1e-9 })
    local seenm, cyc_circ, net_total, all_circ = {}, 0, 0, 0
    for m in pairs(prod0) do seenm[m] = true end; for m in pairs(prod1) do seenm[m] = true end
    for m in pairs(cons0) do seenm[m] = true end; for m in pairs(cons1) do seenm[m] = true end
    for m in pairs(seenm) do
        local dp = (prod1[m] or 0) - (prod0[m] or 0); local dc = (cons1[m] or 0) - (cons0[m] or 0)
        local circ = ((dp > 0) == (dc > 0)) and math.min(math.abs(dp), math.abs(dc)) or 0
        net_total = net_total + math.abs(dp - dc)
        all_circ = all_circ + circ
        if circ > 1e-9 and scc.tag[m] then cyc_circ = cyc_circ + circ end
    end
    local flux = all_circ + net_total
    local cyc = flux > 0 and cyc_circ / flux or 0

    local tag = scc.tag[e.mat]
    io.write(string.format(
        "pt cyc=%.3f rdist=%.4f match=%.3f grow=%.4g newRaw=%.4f inCyc=%d sccSS=%d blow=%.4g div=%d seed=%s mat=%s\n",
        cyc, rdiff / base_machines, g > 1e-9 and shed / g or 0, g, new_raw / base_machines,
        tag and 1 or 0, scc_self_sustaining(tag) and 1 or 0, (viol1[e.key] or 0) / math.max(e.xv, 1e-12),
        st1 ~= "finished" and 1 or 0, fid, e.mat))
end
