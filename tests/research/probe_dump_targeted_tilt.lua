---@diagnostic disable: undefined-global
-- General form of the per-material import tilt. Automate the manual CO2 trick:
-- fabricate-biased base (import=HI, dump=DUMP, raw/final free), then iteratively
-- find the biggest CONSUMABLE dump P, identify the running recipe forcing it and
-- THAT recipe's main useful (consumed) co-product Q, and cheapen Q's import (LO)
-- so the LP can buy Q instead of running the dump-forcing recipe. Re-solve; move
-- to the next biggest dump. Loop until dumps are gone / no mapping found.
--
-- Tests whether this converges to "import the dump-forcing intermediates, fabricate
-- the clean rest" on seed_143, and whether it generalises past CO2.
--
--   luajit tests/research/probe_dump_targeted_tilt.lua [dumpfile] [HI] [DUMP] [LO] [ROUNDS]

require "tests/headless_env"
local ref = require "tests/research/reference_solver"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local HI = tonumber(arg[2]) or 1024
local DUMP = tonumber(arg[3]) or 1
local LO = tonumber(arg[4]) or 1
local ROUNDS = tonumber(arg[5]) or 8
local BIG = 1e6

local prob = assert(problem_dump.load_problem(PATH))
for _, c in ipairs(prob.constraints) do c.limit_amount_per_second = BIG end
local producible = ref.producible_set(prob.constraints, prob.normalized_lines)
local consumable = ref.consumable_set(prob.constraints, prob.normalized_lines)
local intermediates = ref.intermediates(prob.normalized_lines)
local function is_import(p) return p.kind == "shortage_source" or (p.kind == "initial_source" and p.material and intermediates[p.material]) end
local function is_dump(p) return (p.kind == "surplus_sink" or p.kind == "final_sink") and p.material and consumable[p.material] end
local function base(mat) return (tostring(mat):gsub("@%[.-%]", "")) end

-- lines = recipes + bridges
local p0 = create_problem.create_problem("d", prob.constraints, prob.normalized_lines, nil, nil)
local lines = {}
for _, l in ipairs(prob.normalized_lines) do lines[#lines + 1] = l end
for _, l in ipairs(p0.bridges) do lines[#lines + 1] = l end
local function rkey(line) return tn.typed_name_to_variable_name(line.recipe_typed_name) end

local function build(cheap_bases)
    local problem = create_problem.create_problem("tt", prob.constraints, prob.normalized_lines, nil, nil)
    for _, p in pairs(problem.primals) do
        if p.kind == "shortage_source" then p.cost = (p.material and cheap_bases[base(p.material)]) and LO or HI
        elseif p.kind == "surplus_sink" then p.cost = DUMP
        elseif p.kind == "initial_source" or p.kind == "final_sink" then p.cost = 0 end
    end
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
    return problem
end

local function solve(pp)
    local state, it, vars, last, steps = "ready", nil, nil, nil, 0
    repeat
        local ok, s, i2, v = pcall(lp.solve, pp, state, it, vars, prob.meta.tolerance, prob.meta.iterate_limit)
        if not ok then state = "errored"; break end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
    return (last and last.x) or {}, state, steps
end

-- per-material produced/consumed under a solution x
local function flows(x)
    local produced, consumed = {}, {}
    for _, line in ipairs(lines) do
        local xr = x[rkey(line)] or 0
        if xr > 1e-9 then
            for _, pr in ipairs(line.products or {}) do local m = tn.typed_name_to_variable_name(pr); produced[m] = (produced[m] or 0) + xr * (pr.amount_per_second or 0) end
            for _, ing in ipairs(line.ingredients or {}) do local m = tn.typed_name_to_variable_name(ing); consumed[m] = (consumed[m] or 0) + xr * (ing.amount_per_second or 0) end
        end
    end
    return produced, consumed
end

local function summarize(problem, x)
    local maxr = 0
    for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
    local thr = math.max(1e-9, maxr * 1e-6)
    local Vp, Vf, Vc, nrec = 0, 0, 0, 0
    local dumps = {}
    for k, p in pairs(problem.primals) do
        local v = math.abs(x[k] or 0)
        if p.kind == "recipe" and v > thr then nrec = nrec + 1 end
        if v > thr then
            if is_import(p) then if producible[p.material] then Vp = Vp + v else Vf = Vf + v end
            elseif p.kind == "surplus_sink" and consumable[p.material] then Vc = Vc + v; dumps[#dumps + 1] = { m = p.material, v = v } end
        end
    end
    table.sort(dumps, function(a, b) return a.v > b.v end)
    return Vp, Vf, Vc, nrec, dumps, thr
end

-- evaluate a cheap-import set: solve and return the full picture
local function evaluate(cheap_set)
    local problem = build(cheap_set)
    local x, st = solve(problem)
    local Vp, Vf, Vc, nrec, dumps, thr = summarize(problem, x)
    return { total = Vp + Vf + Vc, Vp = Vp, Vf = Vf, Vc = Vc, nrec = nrec, dumps = dumps, thr = thr, x = x, st = st }
end

-- candidate co-product Q for a dump d under solution x: most-consumed co-product
-- of a running recipe that makes d, not already cheap
local function candidate_Q(d, x, thr)
    local produced, consumed = flows(x)
    local bestQ, bestC = nil, 0
    for _, line in ipairs(lines) do
        local xr = x[rkey(line)] or 0
        if xr > thr then
            local makes_d = false
            for _, pr in ipairs(line.products or {}) do if tn.typed_name_to_variable_name(pr) == d.m then makes_d = true end end
            if makes_d then
                for _, pr in ipairs(line.products or {}) do
                    local m = tn.typed_name_to_variable_name(pr)
                    if m ~= d.m and (consumed[m] or 0) > bestC and not cheap_set_has(m) then bestQ = m; bestC = consumed[m] or 0 end
                end
            end
        end
    end
    return bestQ, bestC
end

io.write(string.format("================ DUMP-TARGETED TILT (GUARDED, HI=%g DUMP=%g LO=%g) ================\n", HI, DUMP, LO))
local cheap, cheap_list = {}, {}
function cheap_set_has(m) return cheap[base(m)] == true end

local cur = evaluate(cheap)
io.write(string.format("\n[round 0] cheap-import={}  state=%s recipes=%d  Vp=%.6g Vf=%.6g Vc=%.6g total=%.6g\n",
    cur.st, cur.nrec, cur.Vp, cur.Vf, cur.Vc, cur.total))

for round = 1, ROUNDS do
    -- try each consumable dump (biggest first); accept the first Q whose import cheapening REDUCES total
    local accepted
    for _, d in ipairs(cur.dumps) do
        local Q = candidate_Q(d, cur.x, cur.thr)
        if Q then
            local trial_set = {}
            for k in pairs(cheap) do trial_set[k] = true end
            trial_set[base(Q)] = true
            local res = evaluate(trial_set)
            local verdict = res.total < cur.total - 1e-6 and "ACCEPT" or "reject"
            io.write(string.format("   try: dump %s (%.4g) -> cheapen %s  => total %.6g  [%s]\n",
                d.m, d.v, base(Q), res.total, verdict))
            if res.total < cur.total - 1e-6 then accepted = { Q = Q, res = res }; break end
        end
    end
    if not accepted then io.write("   -> no improving import this round; stop.\n"); break end
    cheap[base(accepted.Q)] = true
    cheap_list[#cheap_list + 1] = base(accepted.Q)
    cur = accepted.res
    io.write(string.format("[round %d] cheap-import={%s}  recipes=%d  Vp=%.6g Vf=%.6g Vc=%.6g total=%.6g\n",
        round, table.concat(cheap_list, ", "), cur.nrec, cur.Vp, cur.Vf, cur.Vc, cur.total))
end

io.write("\n== final ==\n")
io.write(string.format("cheap-import materials: {%s}\n", table.concat(cheap_list, ", ")))
io.write(string.format("Vp=%.6g Vf=%.6g Vc=%.6g  total violation=%.6g  recipes=%d\n", cur.Vp, cur.Vf, cur.Vc, cur.total, cur.nrec))
io.write("remaining consumable dumps (legitimate / not worth importing to avoid):\n")
for i = 1, math.min(#cur.dumps, 8) do io.write(string.format("   %-13.6g %s\n", cur.dumps[i].v, cur.dumps[i].m)) end
