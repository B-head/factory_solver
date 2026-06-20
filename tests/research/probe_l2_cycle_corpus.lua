---@diagnostic disable: undefined-global
-- SINGLE-SHOT corpus driver (run via tests/research/run_corpus.ps1 -Collect '^seed=').
-- For ONE dump: solve L2 (QP) baseline, then for a sample of active violation-elastics
-- spanning the baseline-magnitude range, zero ONLY that elastic's quad (free mode) and
-- re-solve COLD. Decompose each Δx into circulation (cycle wash) vs net-throughput
-- (Method 1) and aggregate, emitting ONE raw `seed=...` line. The questions this feeds:
--   Q1 graded?       -- does cyclic-share span a continuous range (shareMin..shareMax)?
--   Q2 fixed locus?  -- do different freed elastics surface the SAME circulating
--                       materials (locusJaccard) and the SAME dominant SCC (domSccStable)?
--   Q3 one loop?     -- is circulation concentrated in one SCC (domFracMean high)?
--
-- Raw numbers only -- no good/bad labels (the line is graded by the reader, not here).
-- Every number is physical (phys/s) except the *blowup ratio (this-elastic phys1/phys0).
--
--   lua tests/research/probe_l2_cycle_corpus.lua <dump>

require "tests/headless_env"
local R = require "tests/research/research_lib"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local D = R.dissect

local VIOLATION_QUAD, VIOLATION_FLOOR, L2_RECIPE_EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10
local KSAMPLE = 5 -- active elastics probed per dump (sampled across baseline magnitude)

local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"

local function emit(rest) io.write("seed=" .. fid .. " " .. rest .. "\n") end

local okload, prob = pcall(problem_dump.load_problem, PATH)
if not okload or not prob then emit("ERR=load"); return end

local function build_l2()
    local p = create_problem.create_problem("l2", prob.constraints, prob.normalized_lines, nil, {
        reachability_gating = false, deficit_seeding = false,
        catalyst_closure = false, surplus_sink_gating = false, recipe_epsilon = L2_RECIPE_EPS,
    })
    create_problem.shape_l2(p, VIOLATION_QUAD, VIOLATION_FLOOR)
    return p
end

local function phys(problem, key, x)
    local p = problem.primals[key]
    local t = problem.subject_terms[key]
    local c = (p and p.material and t and t[p.material]) or 1
    return math.abs(c * (x[key] or 0))
end

-- ---- baseline ----
local base = build_l2()
local x0, st0 = R.drive_solve(base, prob.meta)
if st0 ~= "finished" then emit("ERR=baseline state=" .. tostring(st0)); return end

local maxr = 0
for k, p in pairs(base.primals) do
    if p.kind == "recipe" then local a = math.abs(x0[k] or 0); if a > maxr then maxr = a end end
end
local chg = math.max(1e-9, maxr * 1e-6)

local lines = D.all_lines(prob.normalized_lines, base)
local scc = D.cyclic_sccs(lines)
local prod0, cons0 = D.physical_flows(lines, x0, { fuel = true, eps = 1e-9 })

-- recipe topology context
local rtot, rcyc = 0, 0
local rms = D.recipe_material_sets(lines)
for rk, p in pairs(base.primals) do
    if p.kind == "recipe" then
        rtot = rtot + 1
        for m in pairs(rms[rk] or {}) do if scc.tag[m] then rcyc = rcyc + 1; break end end
    end
end

-- active violation-elastics (the L2 quad columns), sorted by baseline xvar.
local active = {}
for key, p in pairs(base.primals) do
    if (p.kind == "shortage_source" or p.kind == "surplus_sink") and math.abs(x0[key] or 0) > chg then
        active[#active + 1] = { key = key, material = p.material, xvar = math.abs(x0[key] or 0), phys0 = phys(base, key, x0) }
    end
end
table.sort(active, function(a, b) return a.xvar > b.xvar end)

if #active == 0 then
    emit(string.format("nSCC=%d nActive=0 nProbed=0 rTot=%d rCyc=%d (no active violation-elastics)",
        #scc.cyclic, rtot, rcyc))
    return
end

-- sample up to KSAMPLE elastics at evenly-spaced ranks (spans the magnitude range,
-- so both the boring high-baseline and the blow-up low-baseline ends are covered).
local sample = {}
local n = #active
local count = math.min(KSAMPLE, n)
local seen = {}
for i = 1, count do
    local idx = (count == 1) and 1 or math.floor((i - 1) * (n - 1) / (count - 1) + 0.5) + 1
    if not seen[idx] then seen[idx] = true; sample[#sample + 1] = active[idx] end
end

-- ---- per-perturbation Method-1 decomposition ----
---@return { share:number, dom_scc:string, dom_frac:number, top1:string, topset:table<string,true>, blowup:number, diverged:boolean }
local function probe(elt)
    local problem = build_l2()
    problem:set_quad(elt.key, 0) -- free mode: zero ONLY the quad, value left free
    local x1, st1 = R.drive_solve(problem, prob.meta)
    local prod1, cons1 = D.physical_flows(lines, x1, { fuel = true, eps = 1e-9 })

    local seenm = {}
    for m in pairs(prod0) do seenm[m] = true end
    for m in pairs(prod1) do seenm[m] = true end
    for m in pairs(cons0) do seenm[m] = true end
    for m in pairs(cons1) do seenm[m] = true end

    local circ_by_scc, circ_acyc, net_total = {}, 0, 0
    local clist = {}
    for m in pairs(seenm) do
        local dp = (prod1[m] or 0) - (prod0[m] or 0)
        local dc = (cons1[m] or 0) - (cons0[m] or 0)
        if math.abs(dp) + math.abs(dc) > chg then
            local circ = ((dp > 0) == (dc > 0)) and math.min(math.abs(dp), math.abs(dc)) or 0
            net_total = net_total + math.abs(dp - dc)
            if circ > chg then
                local tg = scc.tag[m]
                if tg then circ_by_scc[tg] = (circ_by_scc[tg] or 0) + circ else circ_acyc = circ_acyc + circ end
                clist[#clist + 1] = { m = m, circ = circ, tg = tg }
            end
        end
    end
    local cyc_circ, dom_scc, dom_v = 0, "-", 0
    for t, v in pairs(circ_by_scc) do
        cyc_circ = cyc_circ + v
        if v > dom_v then dom_v = v; dom_scc = t end
    end
    local flux = cyc_circ + circ_acyc + net_total
    table.sort(clist, function(a, b) return a.circ > b.circ end)
    local topset = {}
    for i = 1, math.min(5, #clist) do topset[clist[i].m] = true end
    return {
        share = flux > 0 and cyc_circ / flux or 0,
        dom_scc = dom_scc,
        dom_frac = cyc_circ > 0 and dom_v / cyc_circ or 0,
        top1 = clist[1] and clist[1].m or "-",
        topset = topset,
        blowup = phys(problem, elt.key, x1) / math.max(elt.phys0, 1e-12),
        diverged = st1 ~= "finished",
    }
end

local res = {}
for _, elt in ipairs(sample) do res[#res + 1] = probe(elt) end

-- ---- aggregate ----
local shares, blowups, fracs = {}, {}, {}
local ndiv = 0
local dom_count, top1_count = {}, {}
for _, r in ipairs(res) do
    shares[#shares + 1] = r.share
    blowups[#blowups + 1] = r.blowup
    fracs[#fracs + 1] = r.dom_frac
    if r.diverged then ndiv = ndiv + 1 end
    dom_count[r.dom_scc] = (dom_count[r.dom_scc] or 0) + 1
    top1_count[r.top1] = (top1_count[r.top1] or 0) + 1
end
table.sort(shares)
local function pick(t, q) return t[math.max(1, math.min(#t, math.floor(q * (#t - 1) + 0.5) + 1))] end
local share_min, share_med, share_max = shares[1], pick(shares, 0.5), shares[#shares]
local max_blowup = 0; for _, b in ipairs(blowups) do if b > max_blowup then max_blowup = b end end
local frac_mean = 0; for _, f in ipairs(fracs) do frac_mean = frac_mean + f end; frac_mean = frac_mean / #fracs

-- dominant-SCC stability and modal identity
local dom_scc, dom_n = "-", 0
for t, c in pairs(dom_count) do if c > dom_n then dom_n = c; dom_scc = t end end
local dom_stable = (dom_n == #res and dom_scc ~= "-") and 1 or 0
local top1, top1_n = "-", 0
for m, c in pairs(top1_count) do if c > top1_n then top1_n = c; top1 = m end end

-- mean pairwise Jaccard of the top-circulating-material sets (1 = identical locus).
local function jacc(a, b)
    local inter, uni = 0, 0
    local seen = {}
    for k in pairs(a) do seen[k] = true end
    for k in pairs(b) do seen[k] = true end
    for k in pairs(seen) do uni = uni + 1; if a[k] and b[k] then inter = inter + 1 end end
    return uni > 0 and inter / uni or 0
end
local jsum, jn = 0, 0
for i = 1, #res do for j = i + 1, #res do jsum = jsum + jacc(res[i].topset, res[j].topset); jn = jn + 1 end end
local locus_jacc = jn > 0 and jsum / jn or (#res == 1 and 1 or 0)

emit(string.format(
    "nSCC=%d nActive=%d nProbed=%d nDiv=%d rTot=%d rCyc=%d | shareMin=%.3f shareMed=%.3f shareMax=%.3f | locusJacc=%.3f domSccStable=%d domScc=%s domFracMean=%.3f | top1=%s top1Stable=%.2f | maxBlowup=%.4g",
    #scc.cyclic, #active, #res, ndiv, rtot, rcyc,
    share_min, share_med, share_max,
    locus_jacc, dom_stable, dom_scc, frac_mean,
    top1, top1_n / #res, max_blowup))
