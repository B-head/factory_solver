---@diagnostic disable: undefined-global
-- Can the greedy feasibility oracle be replaced by linear algebra?
-- Equivalence used: an elastic column is a +-unit vector, so "material m still
-- has an elastic" == "m's balance row is relaxed". A greedy trial (delete
-- group set G') therefore asks: does the small system restricted to the
-- FORCED rows (materials whose elastics are deleted) have a solution with
-- recipe u >= 1 (u = 1 + w, w >= 0), bridge/ports >= 0?
-- Three oracles per greedy step, compared against the full-LP truth:
--   eqS  Gaussian elimination, ALL forced rows as equalities (rows where only
--        one side was deleted are over-constrained -> infeasible-leaning)
--   eqL  equalities only for rows whose EVERY existing side is deleted
--        (feasible-leaning); one-sided rows dropped
--   ph1  small Phase-I LP over exactly the forced rows (one-sided rows keep
--        their remaining elastic column) -- exact, but tiny vs the full LP
-- On contradictions, eqS/eqL report the Farkas y (elimination row-op record):
-- its support = the mutually-inconsistent balance rows. On ph1-infeasible the
-- support = rows whose artificials stay positive.
--   luajit tests/research/probe_linalg_oracle.lua <dump> [maxsteps]
require "tests/headless_env"
local harness = require "tests/harness"
local R = require "tests/research/research_lib"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"
local pg = require "solver/problem_generator"
local problem_dump = require "tests/problem_dump"
local EPS, PROBE_CAP = 2 ^ -10, tonumber(arg[2]) or 50
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"
local prob = assert(problem_dump.load_problem(PATH))

local function norm_mat(m)
    m = m:gsub("@%[.-%]$", "")
    local t, rest = m:match("^([^/]+)/(.+)$")
    if t == "item" then rest = rest:gsub("/[^/]+$", "") end
    return (t or "?") .. "/" .. (rest or m)
end
local function phys(p, k, x)
    local pr, t = p.primals[k], p.subject_terms[k]
    local c = (pr and pr.material and t and t[pr.material]) or 1
    return math.abs(c * (x[k] or 0))
end
local anchor = {}
for _, c in ipairs(prob.constraints) do
    anchor[#anchor + 1] = { type = c.type, name = c.name, quality = c.quality,
        limit_type = "lower", limit_amount_per_second = 0 }
end
local function build(forced)
    local p = cp.create_problem("l2", anchor, prob.normalized_lines, nil,
        { reachability_gating = false, deficit_seeding = false, catalyst_closure = false,
            surplus_sink_gating = false, recipe_epsilon = EPS })
    if forced then
        local recs = {}
        for k, pr in pairs(p.primals) do if pr.kind == "recipe" then recs[#recs + 1] = k end end
        for _, k in ipairs(recs) do
            local dual = "forcerec/" .. k
            p:add_lower_limit_constraint(dual, 1)
            p:add_subject_term(k, dual, 1)
        end
        cp.shape_l2(p, 2 ^ 11, 2 ^ -8)
    end
    return p
end
local function del(p, keys)
    for _, k in ipairs(keys) do p:set_quad(k, 0); p.primals[k] = nil; p.subject_terms[k] = nil end
    local ks = {}
    for k in pairs(p.primals) do ks[#ks + 1] = k end
    table.sort(ks)
    for i, k in ipairs(ks) do p.primals[k].index = i end
    p.primal_length = #ks
end

-- ============ extraction (plain build, no forcerec rows) ============
local base = build(true)
local x0, st0 = R.drive_solve(base, prob.meta)
assert(st0 == "finished", "forced baseline did not converge")
local plain = build(false)
local colkeys, colkind = {}, {}
for k, pr in pairs(plain.primals) do
    if pr.kind == "recipe" or pr.kind == "bridge" or pr.kind == "initial_source" or pr.kind == "final_sink" then
        colkeys[#colkeys + 1] = k; colkind[k] = pr.kind
    end
end
table.sort(colkeys)
local Acol = {}  -- colkey -> {row: coef}
local rowset = {}
for _, k in ipairs(colkeys) do
    local t = {}
    for cname, coef in pairs(plain.subject_terms[k] or {}) do
        if cname:sub(1, 1) ~= "|" then t[cname] = coef; rowset[cname] = true end
    end
    Acol[k] = t
end
local bvec = {} -- row -> rhs after u_recipe = 1 + w shift
for _, k in ipairs(colkeys) do
    if colkind[k] == "recipe" then
        for r, c in pairs(Acol[k]) do bvec[r] = (bvec[r] or 0) - c end
    end
end
-- elastic presence per material row
local hasShort, hasSur = {}, {}
for _, pr in pairs(plain.primals) do
    if pr.kind == "shortage_source" and pr.material then hasShort[pr.material] = true end
    if pr.kind == "surplus_sink" and pr.material then hasSur[pr.material] = true end
end

-- ============ gauss with row-op record ============
-- rows: array of row names. Returns verdict, contra_y (rowname->weight) or nil,
-- nullity (nil unless solvable), and (if nullity==0) negcount of unique w.
local function gauss(rows)
    local m, n = #rows, #colkeys
    local M, rhs, Y = {}, {}, {}
    for i = 1, m do
        local r = rows[i]
        local row = {}
        for j = 1, n do row[j] = Acol[colkeys[j]][r] or 0 end
        -- scale
        local mx = math.abs(bvec[r] or 0)
        for j = 1, n do mx = math.max(mx, math.abs(row[j])) end
        if mx == 0 then mx = 1 end
        for j = 1, n do row[j] = row[j] / mx end
        M[i], rhs[i] = row, (bvec[r] or 0) / mx
        Y[i] = {}
        for q = 1, m do Y[i][q] = (q == i) and (1 / mx) or 0 end
    end
    local TOL = 1e-9
    local rank = 0
    for j = 1, n do
        if rank >= m then break end
        local piv, pv = nil, TOL
        for i = rank + 1, m do
            if math.abs(M[i][j]) > pv then piv, pv = i, math.abs(M[i][j]) end
        end
        if piv then
            rank = rank + 1
            M[piv], M[rank] = M[rank], M[piv]
            rhs[piv], rhs[rank] = rhs[rank], rhs[piv]
            Y[piv], Y[rank] = Y[rank], Y[piv]
            local d = M[rank][j]
            for i = 1, m do
                if i ~= rank and math.abs(M[i][j]) > 0 then
                    local f = M[i][j] / d
                    for jj = j, n do M[i][jj] = M[i][jj] - f * M[rank][jj] end
                    M[i][j] = 0
                    rhs[i] = rhs[i] - f * rhs[rank]
                    for q = 1, m do Y[i][q] = Y[i][q] - f * Y[rank][q] end
                end
            end
            M[rank]._pivcol = j
        end
    end
    for i = rank + 1, m do
        if math.abs(rhs[i]) > 1e-6 then
            local y = {}
            for q = 1, m do if math.abs(Y[i][q]) > 1e-7 then y[rows[q]] = Y[i][q] end end
            return "infeasible", y, nil, nil
        end
    end
    local nullity = n - rank
    local neg = nil
    if nullity == 0 then
        neg = 0
        local w = {}
        for i = rank, 1, -1 do
            local j = M[i]._pivcol
            local s = rhs[i]
            for jj = j + 1, n do if w[jj] then s = s - M[i][jj] * w[jj] end end
            w[j] = s / M[i][j]
            if colkind[colkeys[j]] and w[j] < -1e-6 then neg = neg + 1 end
        end
    end
    return "feasible", nil, nullity, neg
end

-- ============ small Phase-I over the forced rows ============
-- forcedRows: array of {row, keepShort, keepSur} (remaining one-sided elastics)
local function phase1(forcedRows)
    local p = pg.new("ph1")
    local touched = {}
    for _, fr in ipairs(forcedRows) do touched[fr.row] = fr end
    local artificial = {}
    -- problem_generator rejects negative rhs; flip those rows' signs.
    local sign = {}
    for _, fr in ipairs(forcedRows) do
        local rhs = bvec[fr.row] or 0
        sign[fr.row] = (rhs < 0) and -1 or 1
        p:add_equivalence_constraint(fr.row, math.abs(rhs))
    end
    for _, k in ipairs(colkeys) do
        local hit = false
        for r in pairs(Acol[k]) do if touched[r] then hit = true break end end
        if hit then
            p:add_objective(k, 0, false, "recipe")
            for r, c in pairs(Acol[k]) do
                if touched[r] then p:add_subject_term(k, r, c * sign[r]) end
            end
        end
    end
    for _, fr in ipairs(forcedRows) do
        if fr.keepShort then
            local k = "keepshort/" .. fr.row
            p:add_objective(k, 0, false, "recipe")
            p:add_subject_term(k, fr.row, sign[fr.row])
        end
        if fr.keepSur then
            local k = "keepsur/" .. fr.row
            p:add_objective(k, 0, false, "recipe")
            p:add_subject_term(k, fr.row, -sign[fr.row])
        end
        local tp, tm = "art+/" .. fr.row, "art-/" .. fr.row
        p:add_objective(tp, 1, false, "recipe")
        p:add_subject_term(tp, fr.row, 1)
        p:add_objective(tm, 1, false, "recipe")
        p:add_subject_term(tm, fr.row, -1)
        artificial[#artificial + 1] = { tp, tm, fr.row }
    end
    local st, vars = harness.solve_to_completion(lp, p, { tolerance = 1e-7, iterate_limit = 600 })
    if st ~= "finished" or not vars then return "solver_" .. tostring(st), nil end
    local tot, support = 0, {}
    for _, a in ipairs(artificial) do
        local v = math.abs(vars.x[a[1]] or 0) + math.abs(vars.x[a[2]] or 0)
        tot = tot + v
        if v > 1e-4 then support[#support + 1] = a[3] end
    end
    if tot > 1e-3 then return "infeasible", support end
    return "feasible", nil
end

-- ============ greedy with all oracles ============
local groups, order2, gphys = {}, {}, {}
for k, pr in pairs(base.primals) do
    if (pr.kind == "shortage_source" or pr.kind == "surplus_sink") and phys(base, k, x0) > 1e-6 then
        local b = norm_mat(pr.material or "?")
        if not groups[b] then groups[b] = {}; order2[#order2 + 1] = b; gphys[b] = 0 end
        groups[b][#groups[b] + 1] = k
        gphys[b] = gphys[b] + phys(base, k, x0)
    end
end
table.sort(order2, function(a, b) return gphys[a] < gphys[b] end)
io.write(("== %s  groups=%d rows=%d cols=%d\n"):format(fid, #order2,
    (function() local n = 0 for _ in pairs(rowset) do n = n + 1 end return n end)(), #colkeys))

local removed = {}
local delShort, delSur = {}, {}
local agree = { eqS = 0, eqL = 0, ph1 = 0 }
local total, nkept, negcase = 0, 0, 0
for i, b in ipairs(order2) do
    if i > PROBE_CAP then break end
    total = total + 1
    local trial = {}
    for _, k in ipairs(removed) do trial[#trial + 1] = k end
    for _, k in ipairs(groups[b]) do trial[#trial + 1] = k end
    -- forced-row bookkeeping for the trial
    local tShort, tSur = {}, {}
    for m, v in pairs(delShort) do tShort[m] = v end
    for m, v in pairs(delSur) do tSur[m] = v end
    for _, k in ipairs(trial) do
        local pr = base.primals[k]
        if pr then
            if pr.kind == "shortage_source" then tShort[pr.material] = true
            else tSur[pr.material] = true end
        end
    end
    local strictRows, looseRows, ph1Rows = {}, {}, {}
    local seen = {}
    for m in pairs(tShort) do seen[m] = true end
    for m in pairs(tSur) do seen[m] = true end
    for m in pairs(seen) do
        if rowset[m] then
            strictRows[#strictRows + 1] = m
            local fullyClosed = (not hasShort[m] or tShort[m]) and (not hasSur[m] or tSur[m])
            if fullyClosed then looseRows[#looseRows + 1] = m end
            ph1Rows[#ph1Rows + 1] = { row = m,
                keepShort = hasShort[m] and not tShort[m] or false,
                keepSur = hasSur[m] and not tSur[m] or false }
        end
    end
    table.sort(strictRows); table.sort(looseRows)
    table.sort(ph1Rows, function(a, c) return a.row < c.row end)

    -- truth
    local p = build(true); del(p, trial)
    local _, st = R.drive_solve(p, prob.meta)
    local truth = (st == "finished") and "feasible" or "infeasible"
    -- oracles
    local vS, yS = gauss(strictRows)
    local vL, yL, nullity, neg = gauss(looseRows)
    local vP, supP = phase1(ph1Rows)
    if vS == truth then agree.eqS = agree.eqS + 1 end
    if vL == truth then agree.eqL = agree.eqL + 1 end
    if vP == truth then agree.ph1 = agree.ph1 + 1 end
    if truth == "infeasible" and vL == "feasible" then negcase = negcase + 1 end

    local mark = (st == "finished") and "rm  " or "KEPT"
    if st ~= "finished" then nkept = nkept + 1 end
    io.write(("%s %-36s LP=%-10s eqS=%-10s eqL=%-10s ph1=%-12s\n")
        :format(mark, b, truth, vS, vL, tostring(vP)))
    if st ~= "finished" then
        local y = yS or yL
        if y then
            local names = {}
            for r in pairs(y) do names[#names + 1] = r end
            table.sort(names)
            io.write("      farkas(elim): ", table.concat(names, " , "), "\n")
        end
        if vP == "infeasible" and supP and #supP > 0 then
            table.sort(supP)
            io.write("      farkas(ph1):  ", table.concat(supP, " , "), "\n")
        end
    end
    if st == "finished" then
        for _, k in ipairs(groups[b]) do removed[#removed + 1] = k end
        delShort, delSur = tShort, tSur
    end
end
io.write(("-- steps=%d kept=%d  agree: eqS=%d/%d eqL=%d/%d ph1=%d/%d   LPinfeas-but-eqL-feas(nonneg-only)=%d\n")
    :format(total, nkept, agree.eqS, total, agree.eqL, total, agree.ph1, total, negcase))
