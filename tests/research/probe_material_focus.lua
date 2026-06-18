---@diagnostic disable: undefined-global
-- Focus diagnostic: rebuild the run2 QP framing (initial/final FREE, shortage/
-- surplus = 1*x^2, target hard-equality at BIG), solve, then decompose the flow
-- of ONE material -- which recipes produce it, which consume it, at what solved
-- rate -- plus its escape values and its position in the material graph (SCC,
-- upstream producers, downstream consumers). Answers "why is a non-cycle
-- material's surplus_sink active?".
--
--   luajit tests/research/probe_material_focus.lua [material] [dumpfile] [BIG] [QUAD]

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local material_cycles = require "solver/material_cycles"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local FOCUS = arg[1] or "item/paragen/normal"
local PATH = arg[2] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[3]) or 1e6
local QUAD = tonumber(arg[4]) or 2

local QUAD_KINDS = { shortage_source = true, surplus_sink = true }
local FREE_KINDS = { initial_source = true, final_sink = true }

local prob = assert(problem_dump.load_problem(PATH))
local problem = create_problem.create_problem("focus", prob.constraints, prob.normalized_lines, nil, nil)

for key, p in pairs(problem.primals) do
    if QUAD_KINDS[p.kind] then p.cost = 0; problem:set_quad(key, QUAD)
    elseif FREE_KINDS[p.kind] then p.cost = 0; problem:set_quad(key, 0) end
end
local to_remove = {}
for _, c in ipairs(prob.constraints) do
    local dual = vk.limit(tn.typed_name_to_variable_name(c))
    if problem.duals[dual] then problem.duals[dual].limit = BIG end
    to_remove[vk.elastic(dual)] = true
    to_remove[vk.pos_slack(dual)] = true
    to_remove[vk.neg_slack(dual)] = true
end
for key, p in pairs(problem.primals) do
    if p.kind == "elastic" or p.kind == "headroom" then to_remove[key] = true end
end
for key in pairs(to_remove) do
    if problem.primals[key] then problem.primals[key] = nil; problem.subject_terms[key] = nil end
end
local keys = {}
for k in pairs(problem.primals) do keys[#keys + 1] = k end
table.sort(keys)
for i, k in ipairs(keys) do problem.primals[k].index = i end
problem.primal_length = #keys

-- solve, retain last iterate
local state, iteration, vars, last, steps = "ready", nil, nil, nil, 0
repeat
    local ok, s, it, v = pcall(lp.solve, problem, state, iteration, vars, prob.meta.tolerance, prob.meta.iterate_limit)
    if not ok then state = "errored:" .. tostring(s); break end
    state, iteration = s, it
    if v ~= nil then vars = v; last = v end
    steps = steps + 1
until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
local x = (last and last.x) or {}

-- material graph (with bridges) for SCC + neighbor context
local scc_lines = {}
for _, l in ipairs(prob.normalized_lines) do scc_lines[#scc_lines + 1] = l end
for _, l in ipairs(problem.bridges) do scc_lines[#scc_lines + 1] = l end
local adj = material_cycles.build_material_graph(scc_lines)
local sccs = material_cycles.find_sccs(adj)
local in_cyclic = false
for _, s in ipairs(sccs) do
    if material_cycles.is_cyclic_scc(s, adj) then
        for _, m in ipairs(s) do if m == FOCUS then in_cyclic = true end end
    end
end

local function amount_of(line, want, is_ing)
    local list = is_ing and line.ingredients or line.products
    local total = 0
    for _, a in ipairs(list) do
        if tn.typed_name_to_variable_name(a) == want then total = total + a.amount_per_second end
    end
    if is_ing and line.fuel_ingredient and tn.typed_name_to_variable_name(line.fuel_ingredient) == want then
        total = total + line.fuel_ingredient.amount_per_second
    end
    if (not is_ing) and line.fuel_burnt_result and tn.typed_name_to_variable_name(line.fuel_burnt_result) == want then
        total = total + line.fuel_burnt_result.amount_per_second
    end
    return total
end

io.write(string.format("solve state=%s steps=%d ; FOCUS=%s ; in_cyclic_SCC=%s\n",
    state, steps, FOCUS, tostring(in_cyclic)))
io.write(string.format("graph: out-degree(downstream materials)=%d, producers feed via these edges\n",
    adj[FOCUS] and (function() local n = 0 for _ in pairs(adj[FOCUS]) do n = n + 1 end return n end)() or 0))
if adj[FOCUS] then
    local outs = {}; for m in pairs(adj[FOCUS]) do outs[#outs + 1] = m end; table.sort(outs)
    io.write("  downstream (FOCUS -> M): " .. table.concat(outs, ", ") .. "\n")
end

local prod_total, cons_total = 0, 0
io.write("\n-- PRODUCERS (recipe produces FOCUS) --   flow = per_sec * activity\n")
for _, l in ipairs(scc_lines) do
    local a = amount_of(l, FOCUS, false)
    if a > 0 then
        local rv = tn.typed_name_to_variable_name(l.recipe_typed_name)
        local act = x[rv] or 0
        local flow = a * act
        prod_total = prod_total + flow
        io.write(string.format("  %-45s per_sec=%-10.5g activity=%-14.6g flow=%.6g\n",
            l.recipe_typed_name.name, a, act, flow))
    end
end
io.write(string.format("  >> total production = %.6g\n", prod_total))

io.write("\n-- CONSUMERS (recipe consumes FOCUS) --\n")
for _, l in ipairs(scc_lines) do
    local a = amount_of(l, FOCUS, true)
    if a > 0 then
        local rv = tn.typed_name_to_variable_name(l.recipe_typed_name)
        local act = x[rv] or 0
        local flow = a * act
        cons_total = cons_total + flow
        io.write(string.format("  %-45s per_sec=%-10.5g activity=%-14.6g flow=%.6g\n",
            l.recipe_typed_name.name, a, act, flow))
    end
end
io.write(string.format("  >> total consumption = %.6g\n", cons_total))

io.write("\n-- ESCAPES on FOCUS --\n")
for _, mk in ipairs({ vk.initial_source(FOCUS), vk.shortage_source(FOCUS), vk.surplus_sink(FOCUS), vk.final_sink(FOCUS) }) do
    if problem.primals[mk] then
        io.write(string.format("  %-55s = %.6g\n", mk, x[mk] or 0))
    end
end
io.write(string.format("\n-- BALANCE: production %.6g - consumption %.6g = net %.6g (escapes must absorb this)\n",
    prod_total, cons_total, prod_total - cons_total))
