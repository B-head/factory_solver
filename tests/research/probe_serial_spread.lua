---@diagnostic disable: undefined-global
-- Minimal reproduction of the user's observation: L2 spreads an unavoidable
-- violation onto SERIAL-CHAIN intermediates that are not part of any cycle.
-- Fixture = a mass-losing reprocessing cycle (cell -> P + spent, spent -> 0.8 cell)
-- feeding a cycle-free downstream chain P -> Q -> R with target R = 8.
-- The unavoidable deficit is 0.2 cell per use. The question: does L2 pay it
-- as a single cell import (the physically meaningful answer), or smear it
-- across cell/P/Q/R imports (balancing mid-chain, outside the cycle)?
--   run from repo root:  lua tests/research/probe_serial_spread.lua
require "tests/headless_env"
local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local function it(name, amount)
    return { type = "item", name = name, quality = "normal", amount_per_second = amount }
end
local function line(recipe, products, ingredients)
    return {
        recipe_typed_name = { type = "recipe", name = recipe, quality = "normal" },
        products = products, ingredients = ingredients,
        power_per_second = 0, pollution_per_second = 0,
    }
end

local lines = {
    line("r_use", { it("P", 1), it("spent", 1) }, { it("cell", 1) }),
    line("r_rep", { it("cell", 0.8) }, { it("spent", 1) }),
    line("r_q", { it("Q", 1) }, { it("P", 1) }),
    line("r_r", { it("R", 1) }, { it("Q", 1) }),
}
local constraints = {
    { type = "item", name = "R", quality = "normal",
        limit_type = "equal", limit_amount_per_second = 8 },
}

local function phys(p, k, x)
    local pr, t = p.primals[k], p.subject_terms[k]
    local c = (pr and pr.material and t and t[pr.material]) or 1
    return math.abs(c * (x[k] or 0))
end

local function run(name, l2)
    local p = cp.create_problem(name, constraints, lines, nil, {
        reachability_gating = false, deficit_seeding = false,
        catalyst_closure = false, surplus_sink_gating = false,
        recipe_epsilon = 2 ^ -10, target_budget = 1e-6,
    })
    if l2 then cp.shape_l2(p, 2 ^ 11, 2 ^ -8) end
    local state, vars = harness.solve_to_completion(lp, p,
        { tolerance = 1e-7, iterate_limit = 600 })
    io.write(("== %s  state=%s\n"):format(name, tostring(state)))
    if not vars then return end
    local rows = {}
    for k, pr in pairs(p.primals) do
        local v
        if pr.kind == "recipe" then v = math.abs(vars.x[k] or 0)
        elseif pr.kind == "shortage_source" or pr.kind == "surplus_sink"
            or pr.kind == "initial_source" or pr.kind == "final_sink" then
            v = phys(p, k, vars.x)
        end
        if v and v > 1e-6 then
            rows[#rows + 1] = ("  %-16s %-40s %.6g"):format(pr.kind, k, v)
        end
    end
    table.sort(rows)
    io.write(table.concat(rows, "\n"), "\n")
end

run("L1 baseline", false)
run("L2 shaped", true)
