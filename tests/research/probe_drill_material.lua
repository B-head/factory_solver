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
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local material_cycles = require "solver/material_cycles"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local MAT = arg[2] or "fluid/psc@[10,10]"
local BIG = tonumber(arg[3]) or 1e6

local prob = assert(problem_dump.load_problem(PATH))
for _, c in ipairs(prob.constraints) do c.limit_amount_per_second = BIG end

-- all lines = real recipes + temperature bridges
local p0 = create_problem.create_problem("d", prob.constraints, prob.normalized_lines, nil, nil)
local lines = {}
for _, l in ipairs(prob.normalized_lines) do lines[#lines + 1] = l end
for _, l in ipairs(p0.bridges) do lines[#lines + 1] = l end

local r = ref.solve_reference(prob.constraints, prob.normalized_lines)
assert(r.state == "finished", "reference did not finish: " .. tostring(r.state))
local x = r.x

local function rkey(line) return tn.typed_name_to_variable_name(line.recipe_typed_name) end
local function out_of(line, mat)
    local s = 0
    for _, prod in ipairs(line.products or {}) do if tn.typed_name_to_variable_name(prod) == mat then s = s + (prod.amount_per_second or 0) end end
    if line.fuel_burnt_result and tn.typed_name_to_variable_name(line.fuel_burnt_result) == mat then s = s + (line.fuel_burnt_result.amount_per_second or 0) end
    return s
end
local function in_of(line, mat)
    local s = 0
    for _, ing in ipairs(line.ingredients or {}) do if tn.typed_name_to_variable_name(ing) == mat then s = s + (ing.amount_per_second or 0) end end
    if line.fuel_ingredient and tn.typed_name_to_variable_name(line.fuel_ingredient) == mat then s = s + (line.fuel_ingredient.amount_per_second or 0) end
    return s
end

-- per-material in-solution production / consumption totals (for availability test)
local produced, consumed = {}, {}
for _, line in ipairs(lines) do
    local xr = x[rkey(line)] or 0
    if xr > 0 then
        for _, prod in ipairs(line.products or {}) do
            local m = tn.typed_name_to_variable_name(prod); produced[m] = (produced[m] or 0) + xr * (prod.amount_per_second or 0)
        end
        if line.fuel_burnt_result then local m = tn.typed_name_to_variable_name(line.fuel_burnt_result); produced[m] = (produced[m] or 0) + xr * (line.fuel_burnt_result.amount_per_second or 0) end
        for _, ing in ipairs(line.ingredients or {}) do
            local m = tn.typed_name_to_variable_name(ing); consumed[m] = (consumed[m] or 0) + xr * (ing.amount_per_second or 0)
        end
        if line.fuel_ingredient then local m = tn.typed_name_to_variable_name(line.fuel_ingredient); consumed[m] = (consumed[m] or 0) + xr * (line.fuel_ingredient.amount_per_second or 0) end
    end
end

-- escape values for a material
local function escape_val(kindfn)
    local total, items = 0, {}
    for key, p in pairs(r.problem.primals) do
        if p.material and kindfn(p.kind) then
            local v = math.abs(x[key] or 0)
            if v > 1e-6 then items[p.material] = (items[p.material] or 0) + v end
        end
    end
    return items
end
local surplus_items = escape_val(function(k) return k == "surplus_sink" end)
local final_items = escape_val(function(k) return k == "final_sink" end)
local shortage_items = escape_val(function(k) return k == "shortage_source" end)
local initial_items = escape_val(function(k) return k == "initial_source" end)

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
