-- Captured failure case: a full 5-tier Space Age quality recycling chain
-- (iron-plate + copper-cable + electronic-circuit, each with producer and
-- recyclers at every quality tier, constraint on the legendary circuit).
-- This mirrors the in-game solution that exposed the IPM convergence wall
-- during the quality_decomposition bug-fix session.
--
-- Current expected outcome: solver_state == "unfinished" after the IPM
-- exhausts iterate_limit, with primal x stuck near the lower clamp. This
-- documents the known limitation; once the IPM is rewritten (see
-- project_ipm_rewrite_todo memory), flip this assertion to expect "finished"
-- with a non-trivial chain solution, and move the case into
-- lp_quality_recycling_loop as a normal regression test.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local QUALITY = { "normal", "uncommon", "rare", "epic", "legendary" }

local function item(name, quality, amount)
    return { type = "item", name = name, quality = quality or "normal", amount_per_second = amount }
end

local function line(recipe_name, recipe_quality, products, ingredients)
    return {
        recipe_typed_name = { type = "recipe", name = recipe_name, quality = recipe_quality or "normal" },
        products = products,
        ingredients = ingredients,
        power_per_second = 0,
        pollution_per_second = 0,
    }
end

local function cascade(name, base_amount, start_quality, tiers, next_prob)
    next_prob = next_prob or 0.1
    local start_idx
    for i, q in ipairs(QUALITY) do
        if q == start_quality then start_idx = i; break end
    end
    assert(start_idx, "unknown start_quality: " .. tostring(start_quality))

    local ret = {}
    local prob_left = 1
    for offset = 0, tiers - 1 do
        local idx = start_idx + offset
        if idx > #QUALITY then break end
        local p
        if offset < tiers - 1 and idx < #QUALITY then
            p = prob_left * (1 - next_prob)
            prob_left = prob_left * next_prob
        else
            p = prob_left
            prob_left = 0
        end
        table.insert(ret, item(name, QUALITY[idx], base_amount * p))
        if prob_left == 0 then break end
    end
    return ret
end

local cases = {}

table.insert(cases, {
    name = "deep 5-tier electronic-circuit quality recycling chain (xfail: current IPM cannot solve)",
    run = function()
        local lines = {}

        -- Material producers (only at normal quality; higher tiers come from
        -- recycler cascade or producer cascade).
        table.insert(lines, line("iron-plate", "normal",
            cascade("iron-plate", 1, "normal", 5),
            { item("iron-ore", "normal", 1) }))
        table.insert(lines, line("copper-cable", "normal",
            cascade("copper-cable", 2, "normal", 5),  -- 1 copper-plate -> 2 cable
            { item("copper-plate", "normal", 1) }))

        -- Electronic circuit recipe at every quality tier (consumes
        -- matching-quality iron-plate + copper-cable, produces cascade
        -- circuits at this tier and above).
        for i, q in ipairs(QUALITY) do
            local tiers = #QUALITY - i + 1
            table.insert(lines, line("electronic-circuit", q,
                cascade("electronic-circuit", 1, q, tiers),
                { item("iron-plate", q, 1), item("copper-cable", q, 3) }))
        end

        -- Recycler at every quality tier except legendary (legendary has no
        -- next tier to upgrade into; recycling it would just waste mass).
        for i = 1, #QUALITY - 1 do
            local q = QUALITY[i]
            local tiers = #QUALITY - i + 1
            -- recycler returns 1/4 of each ingredient
            local rec_products = {}
            for _, ingredient_amount in ipairs({
                { "iron-plate", 1 * 0.25 },
                { "copper-cable", 3 * 0.25 },
            }) do
                for _, amt in ipairs(cascade(ingredient_amount[1], ingredient_amount[2], q, tiers)) do
                    table.insert(rec_products, amt)
                end
            end
            table.insert(lines, line("electronic-circuit-recycling", q,
                rec_products,
                { item("electronic-circuit", q, 1) }))
        end

        local constraints = {
            { type = "item", name = "electronic-circuit", quality = "legendary",
              limit_type = "upper", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("deep-recycling", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })

        -- XFAIL: documented IPM convergence wall. When this assertion starts
        -- failing because the IPM rewrite landed and the solver now converges
        -- the chain, flip the expectation to "finished" and assert on the
        -- recipe activations (legendary circuit recipe > 0 etc.).
        harness.assert_eq(state, "unfinished",
            "deep 5-tier recycling currently exhausts iterate_limit; see project_ipm_rewrite_todo memory")
        -- vars is nil on unfinished (linear_programming.solve drops the
        -- partial primal so it doesn't poison the next warm start). This
        -- assertion will also need flipping when the IPM is fixed.
        harness.assert_true(vars == nil, "unfinished returns nil raw_variables")
    end,
})

return cases
