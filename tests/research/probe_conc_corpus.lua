---@diagnostic disable: undefined-global
-- SINGLE-SHOT corpus driver for the CONCENTRATION-AMOUNT question (2026-07-04,
-- run via run_corpus.ps1 -Collect '^ct'). Sibling study to
-- probe_concentrate_corpus.lua (which measured the BREAKAGE side, rdist/newRaw):
-- here the response of interest is HOW MUCH CONCENTRATION happens when one
-- active violation-elastic E gets its quad freed (same perturbation), split into
-- the three mechanisms observed in the sample-read phase:
--   fold  -- violation mass RELOCATING onto E (siblings shed while E grows):
--            shS = same-material shed, shT = temperature-sibling shed,
--            shO = other-material shed  (all physical/s of the SHEDDING material)
--   heal  -- shed without matching growth (the chain that produced E shuts down,
--            taking its attendant violations with it; E barely grows)
--   expand-- growth without shed (new flow: E grows fed by new raw imports)
-- plus the distributional shape of the violation vector before/after:
--   n (active count), V (total physical mass -- MIXED UNITS, compare per-dump
--   only), h (HHI over physical shares -- same caveat), shE (E's share of V1).
-- Breakage responses (rdist, newRaw) are re-emitted for joining with the old
-- forecast axis. CHEAP features (baseline solve + material graph only, no
-- per-candidate work) ride along on each line:
--   xv (E baseline phys), sib (active elastic mass on the same base material:
--   temperature siblings + opposite-kind twin), upv/dnv (active violation mass
--   1 hop upstream/downstream of E's material -- chain-fold candidates),
--   net/thr (baseline |prod-cons| / prod+cons), inD/outD, scc, br, kind.
-- NOTE mat_base(): strips the temperature window off a MATERIAL id string for
-- sibling grouping. Research-probe-only shortcut (this is a material id, not an
-- LP var key; the var_key parsing ban still stands).
--   lua tests/research/probe_conc_corpus.lua <dump>
require "tests/headless_env"
local R = require "tests/research/research_lib"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local D = R.dissect

local VQ, VF, EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10
local KSAMPLE = 30 -- probe ALL active elastics when <=30, else 30 spanning the phys-magnitude range
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"
local function vname(t) return tn.typed_name_to_variable_name(t) end
local function mat_base(m) return (m:gsub("@%[.-%]$", "")) end

local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("ct ERR=load seed=" .. fid .. "\n"); return end

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
if st0 ~= "finished" then io.write("ct ERR=baseline seed=" .. fid .. "\n"); return end

local lines = D.all_lines(prob.normalized_lines, base)
local scc = D.cyclic_sccs(lines)
local prod0, cons0 = D.physical_flows(lines, x0, { fuel = true, eps = 1e-9 })

local base_machines = 0
for k, p in pairs(base.primals) do if p.kind == "recipe" then base_machines = base_machines + math.abs(x0[k] or 0) end end
if base_machines < 1e-9 then base_machines = 1e-9 end

local function snap(problem, x)
    local viol, raw = {}, {}
    for k, p in pairs(problem.primals) do
        if p.kind == "shortage_source" or p.kind == "surplus_sink" then viol[k] = phys(problem, k, x)
        elseif p.kind == "initial_source" then raw[k] = phys(problem, k, x) end
    end
    return viol, raw
end
local viol0, raw0 = snap(base, x0)

local function dist_stats(viol, ekey)
    local n, total, sumsq, emass = 0, 0, 0, 0
    for k, v in pairs(viol) do
        if v > 1e-6 then n = n + 1; total = total + v end
        if k == ekey then emass = v end
    end
    if total > 0 then
        for _, v in pairs(viol) do if v > 1e-6 then local s = v / total; sumsq = sumsq + s * s end end
    end
    return n, total, sumsq, emass
end
local n0, V0, hhi0 = dist_stats(viol0, "")

-- cheap graph features -----------------------------------------------------
local prodc, consc = {}, {}          -- degree counts
local prod_in, cons_out = {}, {}     -- m -> set of 1-hop neighbour materials
for _, line in ipairs(lines) do
    local prods, ings = {}, {}
    for _, p in ipairs(line.products) do prods[#prods + 1] = vname(p) end
    if line.fuel_burnt_result then prods[#prods + 1] = vname(line.fuel_burnt_result) end
    for _, ig in ipairs(line.ingredients) do ings[#ings + 1] = vname(ig) end
    if line.fuel_ingredient then ings[#ings + 1] = vname(line.fuel_ingredient) end
    for _, m in ipairs(prods) do
        prodc[m] = (prodc[m] or 0) + 1
        local set = prod_in[m]; if not set then set = {}; prod_in[m] = set end
        for _, mi in ipairs(ings) do if mi ~= m then set[mi] = true end end
    end
    for _, m in ipairs(ings) do
        consc[m] = (consc[m] or 0) + 1
        local set = cons_out[m]; if not set then set = {}; cons_out[m] = set end
        for _, mp in ipairs(prods) do if mp ~= m then set[mp] = true end end
    end
end
local bridge_mat = {}
for _, line in ipairs(base.bridges) do
    for _, p in ipairs(line.products) do bridge_mat[vname(p)] = true end
    for _, ig in ipairs(line.ingredients) do bridge_mat[vname(ig)] = true end
end
-- active violation mass per material (all kinds pooled)
local viol_mat = {}
for k, p in pairs(base.primals) do
    if (p.kind == "shortage_source" or p.kind == "surplus_sink") then
        local v = viol0[k] or 0
        if v > 1e-6 then viol_mat[p.material] = (viol_mat[p.material] or 0) + v end
    end
end
local function hop_viol(set, own)
    if not set then return 0 end
    local s = 0
    for m in pairs(set) do if m ~= own then s = s + (viol_mat[m] or 0) end end
    return s
end

local active = {}
for k, p in pairs(base.primals) do
    if (p.kind == "shortage_source" or p.kind == "surplus_sink") and (viol0[k] or 0) > 1e-6 then
        active[#active + 1] = { key = k, mat = p.material, kind = p.kind, xv = viol0[k] }
    end
end
if #active == 0 then io.write("ct NOACTIVE seed=" .. fid .. "\n"); return end
table.sort(active, function(a, b) return a.xv > b.xv end)

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
    local shS, shT, shO = 0, 0, 0
    for k, v0 in pairs(viol0) do
        if k ~= e.key then
            local dec = v0 - (viol1[k] or 0)
            if dec > 0 then
                local m = problem.primals[k].material
                if m == e.mat then shS = shS + dec
                elseif m and e.mat and mat_base(m) == mat_base(e.mat) then shT = shT + dec
                else shO = shO + dec end
            end
        end
    end
    local new_raw = 0
    for k, v0 in pairs(raw0) do local inc = (raw1[k] or 0) - v0; if inc > 0 then new_raw = new_raw + inc end end
    local rdiff = 0
    for k, p in pairs(problem.primals) do
        if p.kind == "recipe" then rdiff = rdiff + math.abs((x1[k] or 0) - (x0[k] or 0)) end
    end
    local n1, V1, hhi1, e1 = dist_stats(viol1, e.key)

    -- gross transition counts (user observation 2026-07-04: net dn hides
    -- simultaneous zeroing + lighting; count both directions).
    -- elastics at two thresholds (1e-6 = everything, 1e-4 = above dust);
    -- recipes (kind=="recipe" only, so temperature bridges are excluded):
    --   zeroed = was >1e-2 machines, fell below 1% of itself
    --   lit    = was <1e-4, rose above 1e-2 machines
    local zE6, lE6, zE4, lE4 = 0, 0, 0, 0
    for k, v0 in pairs(viol0) do
        if k ~= e.key then
            local v1 = viol1[k] or 0
            if v0 > 1e-6 and v1 < 1e-6 then zE6 = zE6 + 1 elseif v0 < 1e-6 and v1 > 1e-6 then lE6 = lE6 + 1 end
            if v0 > 1e-4 and v1 < 1e-4 then zE4 = zE4 + 1 elseif v0 < 1e-4 and v1 > 1e-4 then lE4 = lE4 + 1 end
        end
    end
    local zR, lR = 0, 0
    for k, p in pairs(problem.primals) do
        if p.kind == "recipe" then
            local a, b = math.abs(x0[k] or 0), math.abs(x1[k] or 0)
            if a > 1e-2 and b < 0.01 * a then zR = zR + 1
            elseif a < 1e-4 and b > 1e-2 then lR = lR + 1 end
        end
    end

    -- sibling mass: active elastic mass on the same base material, excluding E itself
    local sib = 0
    for _, o in ipairs(active) do
        if o.key ~= e.key and mat_base(o.mat) == mat_base(e.mat) then sib = sib + o.xv end
    end

    io.write(string.format(
        "ct grow=%.6g blow=%.4g shS=%.6g shT=%.6g shO=%.6g n0=%d n1=%d V0=%.6g V1=%.6g h0=%.4f h1=%.4f shE=%.4f" ..
        " rdist=%.4f newRaw=%.4f div=%d zE6=%d lE6=%d zE4=%d lE4=%d zR=%d lR=%d" ..
        " xv=%.6g sib=%.6g upv=%.6g dnv=%.6g net=%.6g thr=%.6g inD=%d outD=%d scc=%d br=%d kind=%d seed=%s mat=%s\n",
        g, (viol1[e.key] or 0) / math.max(e.xv, 1e-12), shS, shT, shO, n0, n1, V0, V1, hhi0, hhi1,
        V1 > 0 and e1 / V1 or 0,
        rdiff / base_machines, new_raw / base_machines, st1 ~= "finished" and 1 or 0,
        zE6, lE6, zE4, lE4, zR, lR,
        e.xv, sib, hop_viol(prod_in[e.mat], e.mat), hop_viol(cons_out[e.mat], e.mat),
        math.abs((prod0[e.mat] or 0) - (cons0[e.mat] or 0)), (prod0[e.mat] or 0) + (cons0[e.mat] or 0),
        prodc[e.mat] or 0, consc[e.mat] or 0,
        (scc.tag[e.mat] and #scc.members[scc.tag[e.mat]]) or 0, bridge_mat[e.mat] and 1 or 0,
        e.kind == "surplus_sink" and 1 or 0, fid, e.mat))
end
