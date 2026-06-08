---@diagnostic disable: undefined-global
-- One-off dissection of the seed_18 ttrapdown_h24 unique-unlock COLLAPSE case:
-- small-lamp is shortage-active inside a cyclic SCC and HAS a topological
-- external producer (extP=1), yet raise-all collapses (Rsum->0, target relaxes)
-- instead of routing through that producer. Goal: see WHY the external producer
-- is not economical. Not a test; raw dump. Run from repo root:
--   <lua> tests/drill_seed18.lua <dump.lua> <material-var>
require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"
local mc = require "solver/material_cycles"
local tn = require "manage/typed_name"

local TOL, ITER = 1e-7, 800
local OPTS = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
local ELASTIC_COST = 2 ^ 10
local RAISE_ALL = 1024 * 262144

local path = arg[1]
local target_mat = arg[2] or "item/small-lamp/normal"

local prob_dump = assert(problem_dump.load_problem(path))
local constraints, lines = prob_dump.constraints, prob_dump.normalized_lines

local function build() return create_problem.create_problem("drill", constraints, lines, nil, OPTS) end
local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end

local prob = build()
local _, vars = solve(prob)
local x0 = vars.x
local th = ed.park_threshold(vars, prob.primals)
print(string.format("park threshold = %.3g", th))

-- SCC containing target_mat
local adj = mc.build_material_graph(lines)
local sccs = mc.find_sccs(adj)
local scc, scc_set
for _, s in ipairs(sccs) do
    for _, m in ipairs(s) do
        if m == target_mat then scc = s end
    end
    if scc then break end
end
assert(scc, "material not in any SCC: " .. target_mat)
scc_set = {}
for _, m in ipairs(scc) do scc_set[m] = true end
print("\n== SCC (" .. #scc .. " materials) ==")
for _, m in ipairs(scc) do print("  " .. m) end
print("  is_cyclic=" .. tostring(mc.is_cyclic_scc(scc, adj)) ..
    " self_sustaining=" .. tostring(mc.is_self_sustaining(lines, scc)) ..
    " source_scc=" .. tostring(mc.is_source_scc(scc_set, adj)))

-- the target the problem demands (constraints with a lower limit > 0)
print("\n== problem constraints (limits) ==")
for _, c in ipairs(constraints) do
    print(string.format("  %-40s type=%s limit=%s",
        tn.typed_name_to_variable_name(c) or c.name or "?",
        tostring(c.limit_type), tostring(c.limit_amount or c.amount)))
end

-- recipes that produce target_mat: inside vs outside SCC, with ingredients
print("\n== recipes producing " .. target_mat .. " ==")
local function line_makes(line, mat)
    for _, prod in ipairs(line.products) do
        if tn.typed_name_to_variable_name(prod) == mat then return prod.amount_per_second end
    end
    if line.fuel_burnt_result and tn.typed_name_to_variable_name(line.fuel_burnt_result) == mat then
        return line.fuel_burnt_result.amount_per_second
    end
    return nil
end
for _, line in ipairs(lines) do
    local out = line_makes(line, target_mat)
    if out then
        local rkey = tn.typed_name_to_variable_name(line.recipe_typed_name)
        -- inside SCC iff >=1 ingredient also in SCC
        local inside = false
        for _, ing in ipairs(line.ingredients) do
            if scc_set[tn.typed_name_to_variable_name(ing)] then inside = true break end
        end
        print(string.format("  [%s] %s  (out=%.4g/s, x0=%.4g)",
            inside and "IN " or "OUT", rkey, out, x0[rkey] or 0))
        for _, ing in ipairs(line.ingredients) do
            local iv = tn.typed_name_to_variable_name(ing)
            print(string.format("      ing %-38s %.4g/s  inSCC=%s",
                iv, ing.amount_per_second, tostring(scc_set[iv] == true)))
        end
        if line.fuel_ingredient then
            print("      fuel " .. tn.typed_name_to_variable_name(line.fuel_ingredient))
        end
    end
end

-- baseline active escapes touching the SCC + the SCC's escapes
print("\n== baseline-active escapes (whole problem, |x|>th) ==")
local KINDS = { shortage_source = true, surplus_sink = true, elastic = true, initial_source = true }
for key, p in pairs(prob.primals) do
    if KINDS[p.kind] and (x0[key] or 0) > th then
        print(string.format("  %-12s %-40s x0=%.4g  inSCC=%s",
            p.kind, p.material or key, x0[key], tostring(p.material and scc_set[p.material] == true)))
    end
end

-- raise ALL S-elastics: what fills the gap?
print("\n== raise-all (all SCC escapes -> " .. RAISE_ALL .. ") ==")
local p3 = build()
local raised = {}
for key, p in pairs(p3.primals) do
    if (p.kind == "shortage_source" or p.kind == "surplus_sink" or p.kind == "elastic")
        and p.material and scc_set[p.material] then
        p3.primals[key].cost = RAISE_ALL
        raised[#raised + 1] = key
    end
end
local st3, v3 = solve(p3)
print("  state=" .. tostring(st3) .. ", raised " .. #raised .. " escapes")
local x3 = v3.x
print("  -- variables that MOVED (|x3-x0|>th), kind in {recipe,escape,initial_source,target-elastic} --")
local moved = {}
for key, p in pairs(prob.primals) do
    local d = (x3[key] or 0) - (x0[key] or 0)
    if math.abs(d) > th then moved[#moved + 1] = { key = key, kind = p.kind, mat = p.material, d = d, x0 = x0[key] or 0, x3 = x3[key] or 0 } end
end
table.sort(moved, function(a, b) return math.abs(a.d) > math.abs(b.d) end)
for i = 1, math.min(#moved, 40) do
    local m = moved[i]
    print(string.format("    %-12s %-40s x0=%.4g -> x3=%.4g (d=%+.4g)",
        m.kind, m.mat or m.key, m.x0, m.x3, m.d))
end
