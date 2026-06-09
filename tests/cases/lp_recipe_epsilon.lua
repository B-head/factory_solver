-- recipe_epsilon fixtures: the tiny per-recipe tie-break cost added in
-- solver/create_problem.lua (2^-10) must collapse degenerate "futile" recipe
-- activity that the three boundary costs (source / sink / target) cannot see.
--
-- A net-zero cycle (barrel fill <-> empty, temperature-bridge round-trip,
-- productivity recirculation) consumes no net raw input and feeds no demand, so
-- source_cost is blind to it and the interior-point method, left to its own
-- analytic-centre bias, parks it at an arbitrary positive flow. recipe_epsilon
-- makes running any recipe strictly (if tinily) costly, so a pointless loop is
-- driven to zero. These cases pin that behaviour down -- if recipe_epsilon is
-- ever removed, the futile loop re-inflates and they fail.
--
-- The residual is not exactly 0: the IPM parks a driven-to-zero variable at
-- ~tolerance/epsilon (~1e-3 here), so the assertions use a threshold an order of
-- magnitude above that dust and well below any inflated value.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local fixture = require "tests/cases/fixture"
local item, line = fixture.item, fixture.line

local function solve(lines, constraints)
    local problem = cp.create_problem("recipe-epsilon", constraints, lines)
    local state, vars = harness.solve_to_completion(lp, problem,
        { tolerance = 1e-6, iterate_limit = 400 })
    return state, vars
end

local function rx(vars, name)
    return (vars and vars.x and vars.x["recipe/" .. name .. "/normal"]) or 0
end

local function demand(name, amount)
    return { type = "item", name = name, quality = "normal",
             limit_type = "equal", limit_amount_per_second = amount }
end

local cases = {}

table.insert(cases, {
    name = "futile net-zero loop is driven to zero by recipe_epsilon",
    -- mine-W -> W -> make-Z -> Z is the real chain. barrel-W / unbarrel-W form a
    -- net-zero W <-> WB cycle that contributes nothing: running both at any rate
    -- k leaves every material balance unchanged and draws no extra raw, so it is
    -- a free degenerate direction the IPM would otherwise inflate. recipe_epsilon
    -- must collapse it.
    run = function()
        local state, vars = solve(
            {
                line("mine-W", { item("W", 1) }, {}),
                line("make-Z", { item("Z", 1) }, { item("W", 1) }),
                line("barrel-W", { item("WB", 1) }, { item("W", 1) }),
                line("unbarrel-W", { item("W", 1) }, { item("WB", 1) }),
            },
            { demand("Z", 1) })

        harness.assert_eq(state, "finished", "solver_state")
        -- The real chain runs to meet demand.
        harness.assert_near(rx(vars, "make-Z"), 1, 0.01, "make-Z meets the Z demand")
        harness.assert_near(rx(vars, "mine-W"), 1, 0.01, "mine-W feeds make-Z")
        -- The futile barrel loop is collapsed (only interior-point dust remains).
        harness.assert_near(rx(vars, "barrel-W"), 0, 0.01, "barrel-W driven to zero")
        harness.assert_near(rx(vars, "unbarrel-W"), 0, 0.01, "unbarrel-W driven to zero")
    end,
})

return cases
