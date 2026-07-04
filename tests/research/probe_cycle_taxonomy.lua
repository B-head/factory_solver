---@diagnostic disable: undefined-global
-- CYCLE TAXONOMY probe (2026-07-04, user question: "we never classified cycles
-- finer than SCC"). Enumerate short simple directed cycles in the material
-- graph (ingredient -> product edges, length <= MAXLEN), classify each by its
-- LOOP GAIN g = product of (produced/consumed) stoichiometric ratios around
-- the loop (per edge, the best-ratio line is chosen -- g is an upper bound):
--   g > 1  : mass-amplifying loop (kovarex/grow type)
--   g ~ 1  : balanced loop
--   g < 1  : mass-losing loop (needs makeup -- what elastics feed)
-- and by whether it can run for free: FREE = g >= 0.999 AND every side-input
-- (ingredients of the chosen lines outside the cycle, fuel included) is a raw
-- (has an |initial_source| in the problem) or none. Pure 2-cycles made of two
-- temperature-bridge lines are counted separately (known temp-sibling pairs).
-- Emits one 'cyd' taxonomy line per dump and one 'cy' feature line per active
-- violation-elastic for offline join with conc2_c*.txt:
--   cycN/freeN/maxG : cycles containing E's material (count / free count / max gain)
--   sideInN/sideInG1: cycles where E's material is a SIDE-INPUT (feeding-loop
--                     mechanism; G1 = gain>=0.999 and all OTHER side-ins raw ->
--                     freeing E's import makes the loop free: water/drilling-fluid)
--   sideOutN/sideOutG1: cycles where E's material is a SIDE-OUTPUT (disposal
--                     mechanism; freeing E's dump frees the loop: limestone)
--   dFree           : BFS hops from E's material to the nearest free-cycle
--                     material (-1 = none reachable)
-- No perturbation solves: one baseline L2 solve + enumeration (DFS step cap +
-- cycle cap; trunc=1 on the cyd line when either cap hit -- no silent caps).
--   run via run_corpus.ps1 -Collect '^cy'
require "tests/headless_env"
local R = require "tests/research/research_lib"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local D = R.dissect

local VQ, VF, EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10
local MAXLEN, CYCCAP, STEPCAP = tonumber(arg[2]) or 4, 30000, 2e7
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"
local function vname(t) return tn.typed_name_to_variable_name(t) end

local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("cy ERR=load seed=" .. fid .. "\n"); return end

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
if st0 ~= "finished" then io.write("cy ERR=baseline seed=" .. fid .. "\n"); return end

local lines = D.all_lines(prob.normalized_lines, base)

-- raw set: materials with an |initial_source| primal
local raw = {}
for _, p in pairs(base.primals) do
    if p.kind == "initial_source" and p.material then raw[p.material] = true end
end

-- integer ids for materials
local id_of, mat_of, nmat = {}, {}, 0
local function mid(m)
    local i = id_of[m]
    if not i then nmat = nmat + 1; i = nmat; id_of[m] = i; mat_of[i] = m end
    return i
end

-- directed edges u->v: keep the best-ratio line per (u,v); remember bridge-ness.
-- ratio r = line_out(line, v) / line_in(line, u)
local edges = {}   -- edges[u] = { {v=, r=, li=, br=} sorted later }
local edge_best = {} -- key u*1e6+v -> index into edges[u]
for li, line in ipairs(lines) do
    local ings, prods = {}, {}
    for _, ig in ipairs(line.ingredients or {}) do local m = vname(ig); ings[m] = true end
    if line.fuel_ingredient then ings[vname(line.fuel_ingredient)] = true end
    for _, pr in ipairs(line.products or {}) do local m = vname(pr); prods[m] = true end
    if line.fuel_burnt_result then prods[vname(line.fuel_burnt_result)] = true end
    for mi in pairs(ings) do
        local u = mid(mi)
        local cin = D.line_in(line, mi)
        if cin > 0 then
            for mp in pairs(prods) do
                local v = mid(mp)
                local r = D.line_out(line, mp) / cin
                if r > 0 then
                    local key = u * 1e6 + v
                    local lst = edges[u]; if not lst then lst = {}; edges[u] = lst end
                    local bi = edge_best[key]
                    if not bi then
                        lst[#lst + 1] = { v = v, r = r, li = li, br = line.is_bridge == true }
                        edge_best[key] = #lst
                    elseif r > lst[bi].r then
                        lst[bi].r = r; lst[bi].li = li; lst[bi].br = line.is_bridge == true
                    end
                end
            end
        end
    end
end

-- enumerate simple directed cycles, length <= MAXLEN, smallest-id start rule
local cycles, steps, trunc = {}, 0, 0
local onpath, path = {}, {}
local function dfs(start, u, depth)
    if #cycles >= CYCCAP or steps >= STEPCAP then trunc = 1; return end
    local lst = edges[u]
    if not lst then return end
    for _, e in ipairs(lst) do
        steps = steps + 1
        if steps >= STEPCAP then trunc = 1; return end
        local v = e.v
        if v == start then
            local cyc = { edges = {}, mats = {} }
            for i = 1, #path do cyc.edges[i] = path[i]; cyc.mats[i] = path[i].u end
            cyc.edges[#cyc.edges + 1] = { u = u, e = e }
            cyc.mats[#cyc.mats + 1] = u
            -- normalize stored edge records: list of {u=node, e=edge}
            cycles[#cycles + 1] = cyc
            if #cycles >= CYCCAP then trunc = 1; return end
        elseif v > start and depth < MAXLEN and not onpath[v] then
            onpath[v] = true
            path[#path + 1] = { u = u, e = e }
            dfs(start, v, depth + 1)
            path[#path] = nil
            onpath[v] = nil
        end
    end
end
for s = 1, nmat do
    if edges[s] then
        onpath[s] = true
        dfs(s, s, 1)
        onpath[s] = nil
        if trunc == 1 then break end
    end
end

-- classify each cycle
local n2bridge = 0
local per_mat = {}   -- mat id -> {cycN, freeN, maxG}
local side_in = {}   -- mat id -> {n, g1}
local side_out = {}  -- mat id -> {n, g1}
local free_mats = {} -- mats on any free cycle
local ngain = { lo = 0, bal = 0, hi = 0 }
local nfree = 0
local function bump(t, i, f, d) local e = t[i]; if not e then e = { n = 0, g1 = 0, cycN = 0, freeN = 0, maxG = -1 }; t[i] = e end; e[f] = (e[f] or 0) + (d or 1); return e end

for _, cyc in ipairs(cycles) do
    local es = cyc.edges
    -- pure temperature-pair 2-cycle?
    if #es == 2 and es[1].e.br and es[2].e.br then
        n2bridge = n2bridge + 1
    else
        local inset = {}
        for _, rec in ipairs(es) do inset[rec.u] = true end
        local g = 1
        for _, rec in ipairs(es) do g = g * rec.e.r end
        -- side inputs / outputs of the chosen lines
        local sin_all_raw, sins, souts = true, {}, {}
        for _, rec in ipairs(es) do
            local line = lines[rec.e.li]
            for _, ig in ipairs(line.ingredients or {}) do
                local m = vname(ig); local i = mid(m)
                if not inset[i] and not sins[i] then
                    sins[i] = true
                    if not raw[m] then sin_all_raw = false end
                end
            end
            if line.fuel_ingredient then
                local m = vname(line.fuel_ingredient); local i = mid(m)
                if not inset[i] and not sins[i] then
                    sins[i] = true
                    if not raw[m] then sin_all_raw = false end
                end
            end
            for _, pr in ipairs(line.products or {}) do
                local m = vname(pr); local i = mid(m)
                if not inset[i] then souts[i] = true end
            end
            if line.fuel_burnt_result then
                local i = mid(vname(line.fuel_burnt_result))
                if not inset[i] then souts[i] = true end
            end
        end
        local isfree = (g >= 0.999) and sin_all_raw
        if g < 0.999 then ngain.lo = ngain.lo + 1
        elseif g <= 1.001 then ngain.bal = ngain.bal + 1
        else ngain.hi = ngain.hi + 1 end
        if isfree then
            nfree = nfree + 1
            for i in pairs(inset) do free_mats[i] = true end
        end
        for i in pairs(inset) do
            local e = bump(per_mat, i, "cycN")
            if isfree then e.freeN = e.freeN + 1 end
            if g > e.maxG then e.maxG = g end
        end
        for i in pairs(sins) do
            -- G1: gain ok and every OTHER side-input raw (recheck excluding i)
            local ok = g >= 0.999
            if ok then
                for j in pairs(sins) do
                    if j ~= i and not raw[mat_of[j]] then ok = false; break end
                end
            end
            local e = bump(side_in, i, "n")
            if ok then e.g1 = e.g1 + 1 end
        end
        for i in pairs(souts) do
            local ok = g >= 0.999 and sin_all_raw
            local e = bump(side_out, i, "n")
            if ok then e.g1 = e.g1 + 1 end
        end
    end
end

io.write(string.format(
    "cyd nCyc=%d n2bridge=%d gLo=%d gBal=%d gHi=%d free=%d trunc=%d nmat=%d seed=%s\n",
    #cycles, n2bridge, ngain.lo, ngain.bal, ngain.hi, nfree, trunc, nmat, fid))

if arg[3] == "dump" then
    for ci, cyc in ipairs(cycles) do
        local g, names = 1, {}
        for _, rec in ipairs(cyc.edges) do g = g * rec.e.r; names[#names + 1] = mat_of[rec.u] end
        io.write(("cycle %d  g=%.4g  %s\n"):format(ci, g, table.concat(names, " -> ")))
    end
end

-- BFS distance to nearest free-cycle material (undirected over edges)
local uadj = {}
for u, lst in pairs(edges) do
    for _, e in ipairs(lst) do
        local a = uadj[u]; if not a then a = {}; uadj[u] = a end; a[e.v] = true
        local b = uadj[e.v]; if not b then b = {}; uadj[e.v] = b end; b[u] = true
    end
end
local dfree = {}
do -- multi-source BFS from all free mats
    local q, qi = {}, 1
    for i in pairs(free_mats) do dfree[i] = 0; q[#q + 1] = i end
    while qi <= #q do
        local u = q[qi]; qi = qi + 1
        local a = uadj[u]
        if a then
            for v in pairs(a) do
                if dfree[v] == nil then dfree[v] = dfree[u] + 1; q[#q + 1] = v end
            end
        end
    end
end

for k, p in pairs(base.primals) do
    if (p.kind == "shortage_source" or p.kind == "surplus_sink") then
        local v = phys(base, k, x0)
        if v > 1e-6 then
            local i = id_of[p.material]
            local pm = i and per_mat[i]
            local si = i and side_in[i]
            local so = i and side_out[i]
            io.write(string.format(
                "cy cycN=%d freeN=%d maxG=%.4g sideInN=%d sideInG1=%d sideOutN=%d sideOutG1=%d dFree=%d xv=%.6g kind=%d seed=%s mat=%s\n",
                pm and pm.cycN or 0, pm and pm.freeN or 0, pm and pm.maxG or -1,
                si and si.n or 0, si and si.g1 or 0, so and so.n or 0, so and so.g1 or 0,
                (i and dfree[i]) or -1, v, p.kind == "surplus_sink" and 1 or 0, fid, p.material))
        end
    end
end
