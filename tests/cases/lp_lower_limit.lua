-- Regression net for the lower-limit Constraint type.
--
-- A `lower` Constraint is *soft* in the current LP: create_problem emits an
-- |elastic| primal with `elastic_cost` (2^10 = 1024) that can satisfy the
-- bound without running any producer recipe. Whenever the producer chain
-- generates by-products that can't be cleared, each unit of unclearable
-- by-product also costs `elastic_cost` through |surplus_sink|. Because both
-- penalties share the same magnitude, the LP picks the cheaper bookkeeping
-- path — and the user observes the lower bound being silently violated.
--
-- Observed in the wild (Fulgora factory pinning electromagnetic-science-pack
-- at lower=0.5/s): every recipe primal converged to 0 while
-- `|elastic||limit|item/electromagnetic-science-pack/normal` = 0.5 absorbed
-- the bound. scrap-recycling alone emits ~13 by-products into the surplus
-- ledger, so a single unit of the chain pays 13×1024 in surplus sinks vs.
-- 1×1024 to give up on the bound entirely — and the LP correctly minimises
-- by ignoring the recipe chain.
--
-- These cases pin the *intent*: a `lower` Constraint should force the
-- producer chain to satisfy the bound regardless of by-product accounting.
-- They are expected to FAIL against the current solver and pass once the
-- elastic/surplus cost balance is fixed (e.g. by raising elastic_cost on
-- lower / equal Constraints to `target_cost` so it dominates the surplus
-- ledger, mirroring the role target_cost already plays for `upper`).

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local fixture = require "tests/cases/fixture"
local item, line = fixture.item, fixture.line

local cases = {}

table.insert(cases, {
    name = "lower bound holds on the automation-science-pack chain (user case 1)",
    -- Reconstruction of the user's case-1 log: a 4-recipe vanilla chain
    --   iron-ore  -[iron-plate]->  iron-plate
    --   copper-ore -[copper-plate]-> copper-plate
    --   2 iron-plate -[iron-gear-wheel]-> 1 gear
    --   1 gear + 1 copper-plate -[ASP]-> 1 ASP
    -- pinned at lower=0.5/s on ASP. No producer in this set has unclearable
    -- by-products, so the chain runs without surplus_sink pressure and the
    -- lower bound should bind cleanly.
    run = function()
        local lines = {
            line("iron-plate",       { item("iron-plate", 1) },   { item("iron-ore", 1) }),
            line("copper-plate",     { item("copper-plate", 1) }, { item("copper-ore", 1) }),
            line("iron-gear-wheel",  { item("iron-gear-wheel", 1) },
                                     { item("iron-plate", 2) }),
            line("automation-science-pack",
                 { item("automation-science-pack", 1) },
                 { item("iron-gear-wheel", 1), item("copper-plate", 1) }),
        }
        local constraints = {
            { type = "item", name = "automation-science-pack", quality = "normal",
              limit_type = "lower", limit_amount_per_second = 0.5 },
        }

        local problem = cp.create_problem("asp-lower", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_near(vars.x["recipe/automation-science-pack/normal"], 0.5, 0.05,
            "ASP runs at the lower bound")
        harness.assert_near(vars.x["recipe/iron-gear-wheel/normal"], 0.5, 0.05,
            "gear feeds ASP 1:1")
        harness.assert_near(vars.x["recipe/copper-plate/normal"], 0.5, 0.05,
            "copper-plate feeds ASP 1:1")
        harness.assert_near(vars.x["recipe/iron-plate/normal"], 1.0, 0.05,
            "iron-plate feeds gear 2:1")
        harness.assert_near(
            vars.x["|elastic||limit|item/automation-science-pack/normal"] or 0, 0, 0.05,
            "elastic stays at zero")
    end,
})

table.insert(cases, {
    name = "lower bound holds when the producer emits one unclearable by-product",
    -- Minimal reproduction of the surplus-vs-elastic tie:
    --   r_main: m_in -> m_target + by  (by is a by-product)
    --   r_consume: by -> sink           (would clear by, but capped at 0)
    --   constraint upper recipe/r_consume = 0 (force the by-clearer off)
    --   constraint lower m_target = 0.5
    -- With r_consume disabled, by sits in surplus_sink, and per-unit-r_main
    -- cost is ~ -0.83 (recipe) + 1024 (surplus_sink on by) ≈ +1023. Per 0.5
    -- m_target that's +511.6. Elastic at 0.5 costs +512. Recipe wins by
    -- ~0.4 — a hair. The LP should still satisfy the bound.
    run = function()
        local lines = {
            line("r_main",
                { item("m_target", 1), item("by", 1) },
                { item("m_in", 1) }),
            line("r_consume",
                { item("sink", 1) },
                { item("by", 1) }),
        }
        local constraints = {
            { type = "recipe", name = "r_consume", quality = "normal",
              limit_type = "upper", limit_amount_per_second = 0 },
            { type = "item", name = "m_target", quality = "normal",
              limit_type = "lower", limit_amount_per_second = 0.5 },
        }

        local problem = cp.create_problem("lower-1-surplus", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_true(
            vars.x["recipe/r_main/normal"] >= 0.5 - 0.05,
            "r_main must satisfy the lower bound (got " ..
            tostring(vars.x["recipe/r_main/normal"]) .. ")"
        )
        harness.assert_near(
            vars.x["|elastic||limit|item/m_target/normal"] or 0, 0, 0.05,
            "elastic must stay at zero when surplus penalty ties the elastic cost"
        )
    end,
})

table.insert(cases, {
    name = "lower bound holds when producer emits many unclearable by-products (Fulgora shape)",
    -- This is the canonical reproduction of the Fulgora log:
    --   r_main produces m_target + 5 by-products, each with a disabled
    --   consumer. Per-unit-r_main cost ≈ 5 × 1024 = +5119 (surplus sinks
    --   dominate). Per 0.5 m_target that's +2560. Elastic at 0.5 costs +512.
    --   The LP picks elastic → m_target produced = 0, bound silently
    --   violated. This is exactly what the user observed.
    run = function()
        local n = 5
        local products = { item("m_target", 1) }
        local extra_lines = {}
        local constraints = {
            { type = "item", name = "m_target", quality = "normal",
              limit_type = "lower", limit_amount_per_second = 0.5 },
        }
        for i = 1, n do
            local by = "by_" .. i
            products[#products + 1] = item(by, 1)
            local consume_name = "r_consume_" .. i
            extra_lines[#extra_lines + 1] = line(consume_name,
                { item("sink_" .. i, 1) },
                { item(by, 1) })
            constraints[#constraints + 1] = {
                type = "recipe", name = consume_name, quality = "normal",
                limit_type = "upper", limit_amount_per_second = 0,
            }
        end
        local lines = { line("r_main", products, { item("m_in", 1) }) }
        for _, l in ipairs(extra_lines) do lines[#lines + 1] = l end

        local problem = cp.create_problem("lower-fulgora-shape", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_true(
            vars.x["recipe/r_main/normal"] >= 0.5 - 0.05,
            "r_main must satisfy the lower bound regardless of surplus ledger size (got " ..
            tostring(vars.x["recipe/r_main/normal"]) ..
            "; elastic = " ..
            tostring(vars.x["|elastic||limit|item/m_target/normal"]) .. ")"
        )
        harness.assert_near(
            vars.x["|elastic||limit|item/m_target/normal"] or 0, 0, 0.05,
            "elastic must stay at zero — the user's lower bound is intent, not a soft hint"
        )
    end,
})

table.insert(cases, {
    name = "lower bound holds across a multi-step chain with unclearable by-products at every step",
    -- m_in -> m_mid (+ by_a, by_b) -> m_target (+ by_c, by_d). Each step
    -- emits 2 disabled-consumer by-products, so per unit m_target the
    -- chain pays roughly 4 × 1024 in surplus sinks vs. 1024 for elastic.
    -- Lower bound must still bind.
    run = function()
        local lines = {
            line("r_mid",
                { item("m_mid", 1), item("by_a", 1), item("by_b", 1) },
                { item("m_in", 1) }),
            line("r_top",
                { item("m_target", 1), item("by_c", 1), item("by_d", 1) },
                { item("m_mid", 1) }),
            line("r_consume_a", { item("sa", 1) }, { item("by_a", 1) }),
            line("r_consume_b", { item("sb", 1) }, { item("by_b", 1) }),
            line("r_consume_c", { item("sc", 1) }, { item("by_c", 1) }),
            line("r_consume_d", { item("sd", 1) }, { item("by_d", 1) }),
        }
        local constraints = {
            { type = "recipe", name = "r_consume_a", quality = "normal",
              limit_type = "upper", limit_amount_per_second = 0 },
            { type = "recipe", name = "r_consume_b", quality = "normal",
              limit_type = "upper", limit_amount_per_second = 0 },
            { type = "recipe", name = "r_consume_c", quality = "normal",
              limit_type = "upper", limit_amount_per_second = 0 },
            { type = "recipe", name = "r_consume_d", quality = "normal",
              limit_type = "upper", limit_amount_per_second = 0 },
            { type = "item", name = "m_target", quality = "normal",
              limit_type = "lower", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("lower-chain-surplus", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_true(
            vars.x["recipe/r_top/normal"] >= 1 - 0.05,
            "r_top must satisfy the lower bound (got " ..
            tostring(vars.x["recipe/r_top/normal"]) .. ")"
        )
        harness.assert_true(
            vars.x["recipe/r_mid/normal"] >= 1 - 0.05,
            "r_mid must feed r_top (got " ..
            tostring(vars.x["recipe/r_mid/normal"]) .. ")"
        )
        harness.assert_near(
            vars.x["|elastic||limit|item/m_target/normal"] or 0, 0, 0.05,
            "elastic must stay at zero — chain length must not let surplus cost dominate"
        )
    end,
})

return cases
