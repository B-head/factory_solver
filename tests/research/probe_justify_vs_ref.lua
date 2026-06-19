---@diagnostic disable: undefined-global
-- SINGLE-SHOT driver for run_corpus.ps1: for ONE dump, compute (a) my neutral-base
-- per-material import justification set and (b) the reference greedy exempt set, and
-- emit one RESULT line comparing them. Lets the parallel harness fan the (slow)
-- reference fixpoint across the corpus.
--
--   mine  = producible imports whose forcing-to-0 (from the neutral L1 point) induces
--           a dump  => "importing it avoids a forced dump" (the (B) justification).
--   ref   = the reference's greedy exempt set (strict base, exempt a producible whose
--           fabrication forces a dump when that lowers total violation w/o collapse).
-- Agreement is over the UNION of producible-import materials either side names.
--
--   lua tests/research/probe_justify_vs_ref.lua <dumpfile>

require "tests/headless_env"
local ref = require "tests/research/reference_solver"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1]
local BIG = 1e6
local DUST, ROUNDS = 1e-3, 5
local function seedid(p) return (p and (p:match("seed_%d+") or p:match("[^/\\]+$"))) or "?" end
local function strip_temp(m) return (tostring(m):gsub("@%[.-%]", "")) end

local ok, prob = pcall(problem_dump.load_problem, PATH)
if not ok or not prob then io.write("RESULT\tseed=" .. seedid(PATH) .. "\tERROR=load\n"); return end

local constraints, lines0 = prob.constraints, prob.normalized_lines
local producible = ref.producible_set(constraints, lines0)
local consumable = ref.consumable_set(constraints, lines0)
local intermediates = ref.intermediates(lines0)
local function is_import(p) return p.kind == "shortage_source" or (p.kind == "initial_source" and p.material and intermediates[p.material]) end

-- ============ REFERENCE exempt set (greedy, mirrors probe_unified_strict) ============
local p0 = create_problem.create_problem("u", constraints, lines0, nil, ref.OPTS)
local lines = {}
for _, l in ipairs(lines0) do lines[#lines + 1] = l end
for _, l in ipairs(p0.bridges) do lines[#lines + 1] = l end
local function rkey(line) return tn.typed_name_to_variable_name(line.recipe_typed_name) end

local function measure(r)
    local problem, x = r.problem, r.x
    local maxr = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
    local thr = math.max(1e-9, maxr * 1e-6)
    local Vp, Vf, Vc, T, nrec = 0, 0, 0, 0, 0
    local dumps = {}
    for k, p in pairs(problem.primals) do
        local v = math.abs(x[k] or 0)
        if p.kind == "recipe" and v > thr then nrec = nrec + 1 end
        if (p.kind == "elastic" or p.kind == "headroom") then T = T + v end
        if v > thr then
            if is_import(p) then if producible[p.material] then Vp = Vp + v else Vf = Vf + v end
            elseif (p.kind == "surplus_sink" or p.kind == "final_sink") and consumable[p.material] then Vc = Vc + v; dumps[#dumps + 1] = { m = p.material, v = v } end
        end
    end
    return { Vp = Vp, Vf = Vf, Vc = Vc, T = T, nrec = nrec, dumps = dumps, thr = thr, total = Vp + Vf + Vc, x = x, problem = problem }
end
local function candidates(m, justified)
    local consumed = {}
    for _, line in ipairs(lines) do
        local xr = m.x[rkey(line)] or 0
        if xr > 1e-9 then for _, ing in ipairs(line.ingredients or {}) do local mm = tn.typed_name_to_variable_name(ing); consumed[mm] = (consumed[mm] or 0) + xr * (ing.amount_per_second or 0) end end
    end
    local set = {}
    for _, d in ipairs(m.dumps) do
        for _, line in ipairs(lines) do
            local xr = m.x[rkey(line)] or 0
            if xr > m.thr then
                local makes_d = false
                for _, pr in ipairs(line.products or {}) do if tn.typed_name_to_variable_name(pr) == d.m then makes_d = true end end
                if makes_d then for _, pr in ipairs(line.products or {}) do
                    local mm = tn.typed_name_to_variable_name(pr); local bm = strip_temp(mm)
                    if mm ~= d.m and producible[mm] and (consumed[mm] or 0) > 0 and not justified[bm] then set[bm] = true end
                end end
            end
        end
    end
    return set
end

local ref_set, ref_verdict = {}, "?"
local base_r = ref.solve_reference(constraints, lines0, {})
if base_r.state ~= "finished" then
    ref_verdict = "ref_" .. base_r.state
else
    local base = measure(base_r)
    local justified = {}
    local cur = base
    for _ = 1, ROUNDS do
        local cands = candidates(cur, justified)
        local best
        for bm in pairs(cands) do
            local trial = {}; for k in pairs(justified) do trial[k] = true end; trial[bm] = true
            local r = ref.solve_reference(constraints, lines0, trial)
            if r.state == "finished" then
                local mm = measure(r)
                if mm.total < cur.total - 1e-6 and mm.nrec >= 0.5 * base.nrec and mm.T <= DUST then
                    if not best or mm.total < best.m.total then best = { bm = bm, m = mm } end
                end
            end
        end
        if not best then break end
        justified[best.bm] = true; cur = best.m
    end
    ref_set = justified
    local collapsed = (cur.T > DUST and base.T <= DUST) or (base.nrec > 0 and cur.nrec < 0.5 * base.nrec)
    local g, b = (cur.total < DUST and 0 or cur.total), (base.total < DUST and 0 or base.total)
    ref_verdict = collapsed and "COLLAPSE" or (next(ref_set) == nil and "none") or (g < b - DUST and "improve") or "flat"
end

-- ============ MINE: neutral-base per-material justification ============
local function strip(problem)
    local rm = {}
    for _, c in ipairs(constraints) do
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
        local okk, s, i2, v = pcall(lp.solve, pp, state, it, vars, prob.meta.tolerance, prob.meta.iterate_limit)
        if not okk then return {}, "errored" end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
    return (last and last.x) or {}, state
end
local function build(zero_mat)
    local p = create_problem.create_problem("just", constraints, lines0, nil, nil)
    for _, pp in pairs(p.primals) do pp.cost = (pp.kind == "shortage_source" or pp.kind == "surplus_sink") and 1 or 0 end
    strip(p)
    if zero_mat then
        local dual = "|zero|"; local any = false
        for k, pp in pairs(p.primals) do
            if pp.kind == "shortage_source" and strip_temp(pp.material) == zero_mat then
                if not any then p:add_upper_limit_constraint(dual, 0); any = true end
                p:add_subject_term(k, dual, 1)
            end
        end
    end
    return p
end
local function totdump(problem, x) local s = 0 for k, p in pairs(problem.primals) do if p.kind == "surplus_sink" then s = s + math.abs(x[k] or 0) end end return s end

local pb = build(); local xb = solve(pb)
local base_dump = totdump(pb, xb)
local base_imp = 0; for k, p in pairs(pb.primals) do if p.kind == "shortage_source" then base_imp = base_imp + math.abs(xb[k] or 0) end end
-- producible imports active at the neutral baseline, grouped by base material
local active = {}
for k, p in pairs(pb.primals) do
    if p.kind == "shortage_source" and producible[p.material] and math.abs(xb[k] or 0) > 1e-3 then
        active[strip_temp(p.material)] = true
    end
end
local mine_set = {}
local thresh = math.max(1.0, 1e-3 * (base_imp + base_dump))
for mat in pairs(active) do
    local pm = build(mat); local x = solve(pm)
    local d = totdump(pm, x)
    if (d - base_dump) > thresh then mine_set[mat] = true end
end

-- ============ compare ============
local union = {}
for m in pairs(ref_set) do union[m] = true end
for m in pairs(mine_set) do union[m] = true end
local n, agree = 0, 0
for m in pairs(union) do n = n + 1; if (ref_set[m] and true) == (mine_set[m] and true) then agree = agree + 1 end end
local function csv(set) local t = {} for m in pairs(set) do t[#t + 1] = m end table.sort(t); return (#t > 0 and table.concat(t, ",") or "-") end

io.write(string.format("RESULT\tseed=%s\tunion=%d\tagree=%d\tmatch=%s\tmine=[%s]\tref=[%s]\trefv=%s\n",
    seedid(PATH), n, agree, (n == agree) and "Y" or "N", csv(mine_set), csv(ref_set), ref_verdict))
