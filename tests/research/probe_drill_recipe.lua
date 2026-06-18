---@diagnostic disable: undefined-global
-- Dissect ONE recipe inside the REFERENCE solution: its run rate, all ingredients
-- (with where each comes from) and all products (with the FATE of each: consumed
-- by running recipes / dumped / final / bridged). The product that is ~fully used
-- is the one PINNING the recipe's run rate; the others are co-products (forced
-- byproducts). Tells us whether a big dump is a co-product of a binding recipe.
--
--   luajit tests/research/probe_drill_recipe.lua [dumpfile] [recipe] [BIG]
-- e.g. recipe = recipe/psc-gh/normal

require "tests/headless_env"
local ref = require "tests/research/reference_solver"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local RECIPE = arg[2] or "recipe/psc-gh/normal"
local BIG = tonumber(arg[3]) or 1e6

local prob = assert(problem_dump.load_problem(PATH))
for _, c in ipairs(prob.constraints) do c.limit_amount_per_second = BIG end

local p0 = create_problem.create_problem("d", prob.constraints, prob.normalized_lines, nil, nil)
local lines = {}
for _, l in ipairs(prob.normalized_lines) do lines[#lines + 1] = l end
for _, l in ipairs(p0.bridges) do lines[#lines + 1] = l end

local r = ref.solve_reference(prob.constraints, prob.normalized_lines)
assert(r.state == "finished", "reference state " .. tostring(r.state))
local x = r.x
local function rkey(line) return tn.typed_name_to_variable_name(line.recipe_typed_name) end

-- in-solution produced / consumed per material, and per-material list of running consumers
local produced, consumed = {}, {}
local consumers_of = {}
for _, line in ipairs(lines) do
    local xr = x[rkey(line)] or 0
    for _, ing in ipairs(line.ingredients or {}) do
        local m = tn.typed_name_to_variable_name(ing)
        if xr > 1e-9 then consumed[m] = (consumed[m] or 0) + xr * (ing.amount_per_second or 0) end
        consumers_of[m] = consumers_of[m] or {}
        consumers_of[m][#consumers_of[m] + 1] = { k = rkey(line), per = ing.amount_per_second or 0, x = xr }
    end
    if xr > 1e-9 then
        for _, prod in ipairs(line.products or {}) do
            local m = tn.typed_name_to_variable_name(prod); produced[m] = (produced[m] or 0) + xr * (prod.amount_per_second or 0)
        end
    end
end

-- escape totals per material
local esc = {}
for key, p in pairs(r.problem.primals) do
    if p.material then
        local v = math.abs(x[key] or 0)
        if v > 1e-6 then esc[p.material] = esc[p.material] or {}; esc[p.material][p.kind] = (esc[p.material][p.kind] or 0) + v end
    end
end
local function esc_str(m)
    local e = esc[m]; if not e then return "" end
    local parts = {}
    for k, v in pairs(e) do parts[#parts + 1] = string.format("%s=%.4g", k, v) end
    return "  [" .. table.concat(parts, " ") .. "]"
end

-- find the line
local target_line
for _, line in ipairs(lines) do if rkey(line) == RECIPE then target_line = line end end
assert(target_line, "recipe not found: " .. RECIPE)
local xr = x[RECIPE] or 0

io.write(string.format("================ DISSECT RECIPE %s ================\n", RECIPE))
io.write(string.format("run rate x = %.6g machines  (producible/consumable apply to materials, not recipes)\n", xr))

io.write("\n-- INGREDIENTS (consumes; total = x*per) --\n")
for _, ing in ipairs(target_line.ingredients or {}) do
    local m = tn.typed_name_to_variable_name(ing)
    io.write(string.format("  %-38s %.4g/u  total=%-12.6g  (prod_in_soln=%.4g)%s\n",
        m, ing.amount_per_second or 0, xr * (ing.amount_per_second or 0), produced[m] or 0, esc_str(m)))
end
if target_line.fuel_ingredient then io.write("  fuel " .. tn.typed_name_to_variable_name(target_line.fuel_ingredient) .. "\n") end

io.write("\n-- PRODUCTS (makes; total = x*per ; fate) --\n")
for _, prod in ipairs(target_line.products or {}) do
    local m = tn.typed_name_to_variable_name(prod)
    local total = xr * (prod.amount_per_second or 0)
    local cons = consumed[m] or 0
    local pall = produced[m] or 0
    -- this recipe's share of total production of m
    local frac = pall > 0 and (total / pall) or 0
    io.write(string.format("  %-38s %.4g/u  total=%-12.6g  consumed_in_soln=%-12.6g  (this recipe = %.0f%% of all %s produced)%s\n",
        m, prod.amount_per_second or 0, total, cons, 100 * frac, m, esc_str(m)))
    -- who consumes it
    local cs = consumers_of[m] or {}
    local running = {}
    for _, c in ipairs(cs) do if (c.x or 0) > 1e-9 and c.per > 0 then running[#running + 1] = c end end
    table.sort(running, function(a, b) return a.x * a.per > b.x * b.per end)
    for i = 1, math.min(#running, 6) do
        local c = running[i]
        io.write(string.format("       used by %-40s %.6g\n", c.k, c.x * c.per))
    end
    if #running == 0 then io.write("       (no running consumer -> dumped/final)\n") end
end
