---@diagnostic disable: undefined-global
-- Per-material import justification = the (B) predicate made into an LP test.
-- Baseline: neutral L1 (import & dump both cost 1, recipe 0, targets hard BIG) gives
-- a balanced point. Then, for each import material M active at baseline, force its
-- import to 0 (what strict Vp>>Vc wants) and re-minimize -> measure the INDUCED dump.
--   induced dump >> 0  => importing M was avoiding a forced dump  => JUSTIFIED import
--   induced dump ~ 0   => M's import bought no dump avoidance       => DEFEAT / lazy
-- This is the structural good-vs-cheat split magnitude can't make, computed per
-- material from the face. Also reports the induced OTHER-import (substitution).
--
--   luajit tests/research/probe_import_justify.lua [dumpfile]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"
local ref = require "tests/research/reference_solver"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
-- arg[2]: optional comma-separated temp-stripped base-material names to ALSO test
-- (so neutral-inactive imports like the reference's exempt picks can be probed too).
local EXTRA = {}
if arg[2] then for m in tostring(arg[2]):gmatch("[^,]+") do EXTRA[m] = true end end
local BIG = 1e6
local prob = assert(problem_dump.load_problem(PATH))
local function strip_temp(mat) return (tostring(mat):gsub("@%[.-%]", "")) end
local producible = ref.producible_set(prob.constraints, prob.normalized_lines)

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
        if not ok then return {}, "errored" end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
    return (last and last.x) or {}, state
end

-- neutral L1, with an optional list of import-material substrings forced to 0.
local function build(zero_materials)
    local p = create_problem.create_problem("just", prob.constraints, prob.normalized_lines, nil, nil)
    for _, pp in pairs(p.primals) do
        pp.cost = (pp.kind == "shortage_source" or pp.kind == "surplus_sink") and 1 or 0
    end
    strip(p)
    if zero_materials then
        local i = 0
        for _, mat in ipairs(zero_materials) do  -- mat = temp-stripped base name; zeros ALL its temperature variants
            i = i + 1
            local dual = "|zero" .. i .. "|"
            local any = false
            for k, pp in pairs(p.primals) do
                if pp.kind == "shortage_source" and strip_temp(pp.material) == mat then
                    if not any then p:add_upper_limit_constraint(dual, 0); any = true end
                    p:add_subject_term(k, dual, 1)
                end
            end
        end
    end
    return p
end
local function totkind(problem, x, kind)
    local s = 0; for k, p in pairs(problem.primals) do if p.kind == kind then s = s + math.abs(x[k] or 0) end end; return s
end

-- baseline
local pb = build(); local xb, stb = solve(pb)
local base_dump = totkind(pb, xb, "surplus_sink")
local base_imp = totkind(pb, xb, "shortage_source")
io.write(string.format("baseline neutral L1: import=%.6g  dump=%.6g  (%s)\n\n", base_imp, base_dump, stb))

-- group baseline imports by TEMP-STRIPPED base material; union with EXTRA names
local imp_by_mat = {}
for k, p in pairs(pb.primals) do
    if p.kind == "shortage_source" then
        local v = math.abs(xb[k] or 0)
        local bm = strip_temp(p.material)
        if v > 1e-3 then imp_by_mat[bm] = (imp_by_mat[bm] or 0) + v end
    end
end
for m in pairs(EXTRA) do if not imp_by_mat[m] then imp_by_mat[m] = 0 end end  -- neutral-inactive, test anyway
local mats = {}
for m, v in pairs(imp_by_mat) do mats[#mats + 1] = { m = m, v = v } end
table.sort(mats, function(a, b) return a.v > b.v end)

io.write("-- force each import (base material, all temps) to 0; measure induced dump --\n")
io.write(string.format("%-32s %-5s %-12s %-13s %-13s %-9s %s\n",
    "import material", "prod?", "baseline", "dump after", "d-dump", "d-otherImp", "state"))
for _, e in ipairs(mats) do
    local p = build({ e.m }); local x, st = solve(p)
    local d = totkind(p, x, "surplus_sink")
    local imp = totkind(p, x, "shortage_source")
    io.write(string.format("%-32s %-5s %-12.6g %-13.6g %-13.6g %-9.4g %s\n",
        tostring(e.m):sub(1, 32), producible[e.m] and "P" or "raw", e.v, d, d - base_dump,
        imp - (base_imp - e.v), st))
end
io.write("\nd-dump >> 0 => JUSTIFIED (forcing fabricate forces a dump); ~0 => defeat/substitutable\n")
io.write("prod?=P producible (Vp candidate); raw=non-producible (always legit Vf)\n")
