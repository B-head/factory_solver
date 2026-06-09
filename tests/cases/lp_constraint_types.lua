-- create_problem's three Constraint limit_types (upper / lower / equal) and
-- the soft-constraint semantics they compile to. These are non-obvious:
-- because the slack on an `upper` cap and the elastic on `lower`/`equal` are
-- both priced at target_cost (2^20), a constraint does not merely *bound*
-- production -- it *pulls production to the limit*. The cases below pin both
-- that pull and how each type behaves when an upstream coupling forces the
-- constrained material away from its limit.
--
-- Summary of the observed behaviour (all verified against the solver):
--                       free chain        co-product forces B high
--   upper B<=5          B produced = 5    hard ceiling: caps the shared
--                                         recipe, sacrifices the co-product
--   equal B==5          B produced = 5    same ceiling behaviour as upper
--   lower B>=3          B produced = 3    floor only: permits overproduction,
--                                         co-product demand fully met

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local fixture = require "tests/cases/fixture"
local item, line = fixture.item, fixture.line

local cases = {}

table.insert(cases, {
    name = "all three limit_types fill production up to the limit on a free chain",
    -- A -[mk]-> B with A a free raw input. With nothing else pulling, an
    -- intuitive reading of `upper B<=5` would allow B=0. It does not: the
    -- target_cost slack penalises headroom, so upper, lower, and equal all
    -- drive B to exactly 5. This is the "a constraint is a target, not just a
    -- bound" property that the rest of the suite relies on implicitly.
    run = function()
        for _, ctype in ipairs({ "upper", "lower", "equal" }) do
            local problem = cp.create_problem("fill-" .. ctype,
                { { type = "item", name = "B", quality = "normal",
                    limit_type = ctype, limit_amount_per_second = 5 } },
                { line("mk", { item("B", 1) }, { item("A", 1) }) })
            local state, vars = harness.solve_to_completion(lp, problem,
                { tolerance = 1e-7, iterate_limit = 400 })

            harness.assert_eq(state, "finished", ctype .. " solver_state")
            harness.assert_near(vars.x["recipe/mk/normal"], 5, 0.02,
                ctype .. " fills production to the limit (got " ..
                tostring(vars.x["recipe/mk/normal"]) .. ")")
        end
    end,
})

-- The conflict fixtures all share this shape: recipe R turns one X into one P
-- AND one B (a fixed 1:1 co-product). P is demanded at 10/s (equal), so the
-- co-product B is *forced* toward 10/s. A constraint on B then either fights
-- that (ceiling) or tolerates it (floor).
local function conflict_problem(name, b_type, b_limit)
    return cp.create_problem(name,
        {
            { type = "item", name = "P", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 10 },
            { type = "item", name = "B", quality = "normal",
              limit_type = b_type, limit_amount_per_second = b_limit },
        },
        { line("R", { item("P", 1), item("B", 1) }, { item("X", 1) }) })
end

table.insert(cases, {
    name = "upper is a hard ceiling: it caps the shared recipe and sacrifices the co-product",
    -- B<=5 cannot be reconciled with P=10 (which would force B=10), so the LP
    -- holds B at its cap of 5, which pins recipe R at 5 -- and therefore only
    -- 5 P is made, with P's elastic absorbing the 5/s shortfall. The upper
    -- bound on B wins over the equality demand on P.
    run = function()
        local state, vars = harness.solve_to_completion(lp,
            conflict_problem("upper-ceiling", "upper", 5),
            { tolerance = 1e-6, iterate_limit = 500 })

        harness.assert_eq(state, "finished", "solver_state")
        harness.assert_near(vars.x["recipe/R/normal"], 5, 0.05, "R capped by B's upper bound")
        harness.assert_near(vars.x["|final_sink|item/B/normal"], 5, 0.05, "B held at its cap")
        harness.assert_near(vars.x["|elastic||limit|item/P/normal"], 5, 0.1,
            "P's demand is sacrificed -- elastic absorbs the 5/s it cannot make")
    end,
})

table.insert(cases, {
    name = "equal behaves as a ceiling under forced overproduction (same as upper)",
    -- B==5 is also unreconcilable with the forced B=10; the hard equality
    -- caps R at 5 exactly as the upper bound did, again sacrificing P. This
    -- pins that `equal` and `upper` are indistinguishable when the conflict
    -- pushes the material *above* the limit -- they differ only in internal
    -- slack vs elastic plumbing, not in the solved rates here.
    run = function()
        local state, vars = harness.solve_to_completion(lp,
            conflict_problem("equal-ceiling", "equal", 5),
            { tolerance = 1e-6, iterate_limit = 500 })

        harness.assert_eq(state, "finished", "solver_state")
        harness.assert_near(vars.x["recipe/R/normal"], 5, 0.05, "R capped by B's equality")
        harness.assert_near(vars.x["|final_sink|item/B/normal"], 5, 0.05, "B held at the equality value")
        harness.assert_near(vars.x["|elastic||limit|item/P/normal"], 5, 0.1,
            "P sacrificed exactly as with the upper bound")
    end,
})

table.insert(cases, {
    name = "lower is a floor only: it permits overproduction and leaves the co-product demand intact",
    -- B>=3 is already satisfied by the forced B=10, so there is no conflict:
    -- R runs at the full 10 to meet P, B overshoots to 10, and B's
    -- %negative_slack% absorbs the 7/s above the floor. P's demand is met in
    -- full (no elastic). This is the asymmetry that distinguishes `lower`
    -- from `upper`/`equal`.
    run = function()
        local state, vars = harness.solve_to_completion(lp,
            conflict_problem("lower-floor", "lower", 3),
            { tolerance = 1e-6, iterate_limit = 500 })

        harness.assert_eq(state, "finished", "solver_state")
        harness.assert_near(vars.x["recipe/R/normal"], 10, 0.05, "R runs at full P demand")
        harness.assert_near(vars.x["|final_sink|item/B/normal"], 10, 0.1, "B overproduces above its floor")
        harness.assert_near(vars.x["%negative_slack%|limit|item/B/normal"], 7, 0.1,
            "B's negative slack absorbs the 7/s overshoot above the floor")
        harness.assert_near(vars.x["|elastic||limit|item/P/normal"] or 0, 0, 0.05,
            "P's demand is met in full -- a floor does not fight overproduction")
    end,
})

return cases
