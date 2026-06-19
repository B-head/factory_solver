---@diagnostic disable: undefined-global
-- Dissect ONE material inside the REFERENCE (definition) solution: who produces
-- it, who consumes it, who COULD consume it but is idle, and -- for each idle
-- consumer -- whether its OTHER ingredients are already available without buying
-- new imports. That last point decides whether a big dump is a FORCED byproduct
-- (consuming it needs extra makeup imports, so the dump is legitimate) or a
-- HIDDEN DEFEAT (an idle consumer whose inputs are all already on hand / being
-- dumped themselves).
--
--   luajit tests/research/probe_drill_material.lua [dumpfile] [material] [BIG]
-- e.g. material = fluid/psc@[10,10]

require "tests/headless_env"
local ref = require "tests/research/reference_solver"
local dissect = require "tests/research/dissect"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local material_cycles = require "solver/material_cycles"
local tn = require "manage/typed_name"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local MAT = arg[2] or "fluid/psc@[10,10]"
local BIG = tonumber(arg[3]) or 1e6

local prob = assert(problem_dump.load_problem(PATH))
for _, c in ipairs(prob.constraints) do c.limit_amount_per_second = BIG end

-- all lines = real recipes + temperature bridges
local p0 = create_problem.create_problem("d", prob.constraints, prob.normalized_lines, nil, nil)
local lines = dissect.all_lines(prob.normalized_lines, p0)

local r = ref.solve_reference(prob.constraints, prob.normalized_lines)
assert(r.state == "finished", "reference did not finish: " .. tostring(r.state))
local x = r.x

local rkey = dissect.recipe_key
local out_of, in_of = dissect.line_out, dissect.line_in

-- per-material in-solution production / consumption totals (for availability test)
local produced, consumed = dissect.physical_flows(lines, x, { fuel = true, eps = 0 })

-- escape values for a material, split by kind
local esc = dissect.escape_by_material(r.problem.primals, x, 1e-6)
local function esck(kind)
    local t = {}
    for m, kv in pairs(esc) do if kv[kind] then t[m] = kv[kind] end end
    return t
end
local surplus_items = esck("surplus_sink")
local final_items = esck("final_sink")
local shortage_items = esck("shortage_source")
local initial_items = esck("initial_source")

-- availability verdict for a material (could we consume MORE without a new import?)
local function avail(m)
    if (surplus_items[m] or 0) > 1e-6 then return string.format("DUMPED %.4g (free to consume!)", surplus_items[m]) end
    if (initial_items[m] or 0) > 1e-6 then return string.format("free raw in %.4g (more is free)", initial_items[m]) end
    if (shortage_items[m] or 0) > 1e-6 then return string.format("already makeup-imported %.4g (more = more import)", shortage_items[m]) end
    local prod = produced[m] or 0
    local cons = consumed[m] or 0
    if prod > cons + 1e-6 then return string.format("produced surplus %.4g", prod - cons) end
    if prod > 1e-6 then return string.format("produced, fully used (more needs scaling its chain)") end
    return "NOT available (would need a new import)"
end

io.write(string.format("================ DISSECT %s (reference solution) ================\n", MAT))
local adj = material_cycles.build_material_graph(lines)
local sccs = material_cycles.find_sccs(adj)
local scc_of
for _, s in ipairs(sccs) do for _, m in ipairs(s) do if m == MAT then scc_of = s end end end
io.write(string.format("producible=%s  consumable=%s  scc_size=%s\n",
    tostring(r.producible[MAT]), tostring(r.consumable[MAT]), scc_of and #scc_of or "n/a"))
io.write(string.format("in-solution: produced=%.6g  consumed=%.6g  dumped(surplus)=%.6g  raw_in=%.6g  shortage=%.6g  final=%.6g\n",
    produced[MAT] or 0, consumed[MAT] or 0, surplus_items[MAT] or 0, initial_items[MAT] or 0, shortage_items[MAT] or 0, final_items[MAT] or 0))

io.write("\n-- PRODUCERS of " .. MAT .. " (running) --\n")
local prods = {}
for _, line in ipairs(lines) do local o = out_of(line, MAT); local xr = x[rkey(line)] or 0; if o > 0 and xr > 1e-9 then prods[#prods + 1] = { k = rkey(line), per = o, x = xr, tot = o * xr } end end
table.sort(prods, function(a, b) return a.tot > b.tot end)
for _, e in ipairs(prods) do io.write(string.format("  %-12.6g  (x=%.6g * %.4g/u)  %s\n", e.tot, e.x, e.per, e.k)) end

io.write("\n-- CONSUMERS of " .. MAT .. " (any recipe that takes it as input) --\n")
local cons = {}
for _, line in ipairs(lines) do local i = in_of(line, MAT); if i > 0 then local xr = x[rkey(line)] or 0; cons[#cons + 1] = { k = rkey(line), per = i, x = xr, tot = i * xr, line = line } end end
table.sort(cons, function(a, b) return a.tot > b.tot end)
for _, e in ipairs(cons) do
    local idle = e.x <= 1e-9
    io.write(string.format("  %s consumes %-12.6g  (x=%.6g * %.4g/u)  %s\n",
        idle and "[IDLE]" or "[RUN ]", e.tot, e.x, e.per, e.k))
    if idle then
        -- show the idle consumer's OTHER ingredients + availability
        for _, ing in ipairs(e.line.ingredients or {}) do
            local iv = tn.typed_name_to_variable_name(ing)
            if iv ~= MAT then io.write(string.format("        needs %-38s %.4g/u  -> %s\n", iv, ing.amount_per_second or 0, avail(iv))) end
        end
    end
end
