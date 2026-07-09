---@diagnostic disable: undefined-global
-- Minimal fixtures pinning the user's parallel-path refinement:
--   (a) same-START parallel paths (A->X, A->Y, then X+2Y->B): the two branch
--       recipes have independent machine counts, so any downstream ratio is
--       reachable -- NO elastic needed.
--   (b) same-END parallel paths (A->X+Y co-produced, but X->B and Y->B both
--       reconverge to B): the imbalance washes out at the junction material --
--       NO elastic needed.
--   (c) different-material endpoints (A->X+Y co-produced 1:1, consumed X+2Y):
--       the branch ratio is stoichiometrically rigid on BOTH sides -- an
--       elastic IS structurally forced.
-- Check = plain L2 on each: total violation ~0 for (a),(b), >0 for (c).
--   run from repo root:  lua tests/research/probe_fork_fixture.lua
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

local function run(label, lines)
    local constraints = {
        { type = "item", name = "B", quality = "normal",
            limit_type = "equal", limit_amount_per_second = 4 },
    }
    local p = cp.create_problem(label, constraints, lines, nil, {
        reachability_gating = false, deficit_seeding = false,
        catalyst_closure = false, surplus_sink_gating = false,
        recipe_epsilon = 2 ^ -10, target_budget = 1e-6,
    })
    cp.shape_l2(p, 2 ^ 11, 2 ^ -8)
    local state, vars = harness.solve_to_completion(lp, p,
        { tolerance = 1e-7, iterate_limit = 600 })
    local viol, detail = 0, {}
    if vars then
        for k, pr in pairs(p.primals) do
            if pr.kind == "shortage_source" or pr.kind == "surplus_sink" then
                local t = p.subject_terms[k]
                local c = (pr.material and t and t[pr.material]) or 1
                local v = math.abs(c * (vars.x[k] or 0))
                viol = viol + v
                if v > 1e-4 then
                    detail[#detail + 1] = ("%s=%.4g"):format(
                        k:gsub("|shortage_source|", "IMP "):gsub("|surplus_sink|", "DUMP "):gsub("/normal$", ""), v)
                end
            end
        end
    end
    table.sort(detail)
    io.write(("%-24s state=%-10s viol=%-10.4g %s\n"):format(
        label, tostring(state), viol, table.concat(detail, " ")))
end

-- (a) same start: A splits via two independent recipes, joined X+2Y.
run("a_same_start", {
    line("r_a", { it("A", 1) }, { it("raw", 1) }),
    line("r_sx", { it("X", 1) }, { it("A", 1) }),
    line("r_sy", { it("Y", 1) }, { it("A", 1) }),
    line("r_join", { it("B", 1) }, { it("X", 1), it("Y", 2) }),
})
-- (b) same end: rigid co-production 1:1, but both branches reconverge to B.
run("b_same_end", {
    line("r_a", { it("A", 1) }, { it("raw", 1) }),
    line("r_split", { it("X", 1), it("Y", 1) }, { it("A", 1) }),
    line("r_xb", { it("B", 1) }, { it("X", 1) }),
    line("r_yb", { it("B", 1) }, { it("Y", 1) }),
})
-- (c) different endpoints: rigid co-production 1:1, rigid co-consumption 1:2.
run("c_rigid_fork", {
    line("r_a", { it("A", 1) }, { it("raw", 1) }),
    line("r_split", { it("X", 1), it("Y", 1) }, { it("A", 1) }),
    line("r_join", { it("B", 1) }, { it("X", 1), it("Y", 2) }),
})
