---@diagnostic disable: undefined-global
-- Both shapes the user asked to explore, on the serial-spread fixture:
--   (a) the non-minimal shape = plain L2, every hatch open (the spread);
--   (b) minimal-elastic shapes = L2 restricted to exactly ONE import hatch,
--       for each candidate material in turn (hatch_exclude closes the rest).
-- The point: the minimal feasible set is NOT unique -- each choice is a
-- different discrete import-vs-fabricate answer, and the quantity within the
-- chosen set is what L2 is good at. Dump side stays open (byproduct escape).
--   run from repo root:  lua tests/research/probe_minimal_sets.lua
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
local MATS = { "cell", "spent", "P", "Q", "R" }

local function phys(p, k, x)
    local pr, t = p.primals[k], p.subject_terms[k]
    local c = (pr and pr.material and t and t[pr.material]) or 1
    return math.abs(c * (x[k] or 0))
end

local function run(label, allowed_import)
    local hatch_exclude = nil
    if allowed_import then
        hatch_exclude = {}
        for _, m in ipairs(MATS) do
            if m ~= allowed_import then
                hatch_exclude["item/" .. m .. "/normal"] = true
            end
        end
    end
    local p = cp.create_problem(label, constraints, lines, nil, {
        reachability_gating = false, deficit_seeding = false,
        catalyst_closure = false, surplus_sink_gating = false,
        recipe_epsilon = 2 ^ -10, target_budget = 1e-6,
        hatch_exclude = hatch_exclude,
    })
    cp.shape_l2(p, 2 ^ 11, 2 ^ -8)
    local state, vars = harness.solve_to_completion(lp, p,
        { tolerance = 1e-7, iterate_limit = 600 })
    io.write(("== %-28s state=%s\n"):format(label, tostring(state)))
    if not vars or state ~= "finished" then return end
    local rows = {}
    for k, pr in pairs(p.primals) do
        local v
        if pr.kind == "recipe" then v = math.abs(vars.x[k] or 0)
        elseif pr.kind == "shortage_source" or pr.kind == "surplus_sink"
            or pr.kind == "initial_source" or pr.kind == "final_sink" then
            v = phys(p, k, vars.x)
        end
        if v and v > 1e-4 then
            rows[#rows + 1] = ("  %-16s %-40s %.6g"):format(pr.kind, k, v)
        end
    end
    table.sort(rows)
    io.write(table.concat(rows, "\n"), "\n")
end

run("L2 all hatches (spread)", nil)
for _, m in ipairs(MATS) do
    run("L2 import={" .. m .. "} only", m)
end
