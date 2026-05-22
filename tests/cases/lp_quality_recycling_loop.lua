-- Recycling-loop quality fixtures: the headline "kovarex / quality recycling
-- on Space Age" pattern in miniature. A producer recipe emits a cascade of
-- its product across qualities, and a recycler recipe takes that product back
-- and returns the ingredients (also cascaded), creating a multi-tier loop
-- where mass flows up the quality chain on each cycle. The recycler returns
-- 1/4 of input by Factorio convention (matches Space Age recipe-recycling).
--
-- These shapes are the simplest LPs that reproduce the structural difficulty
-- the mod exists to handle. lp_deep_recycling_xfail exercises the full
-- 5-tier Space Age case (currently not solvable by the IPM).

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

---Same helper as lp_quality_cascade; kept local so each case file is
---self-contained (the test runner loads files independently).
---@param name string
---@param base_amount number
---@param start_quality string
---@param tiers integer
---@param next_prob number?
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
    name = "2-tier producer + 2-tier recycler upgrade loop converges",
    -- iron-mining:       (no ingredients) -> ore/n   (bootstrap)
    -- iron-plate/normal: ore -> [n 0.9, u 0.1] plate
    -- recycler/normal:   plate/n -> [n 0.225, u 0.025] ore   (1/4 return)
    -- recycler/uncommon: plate/u -> [u 0.225, r 0.025] ore   (cascade from u)
    --
    -- The iron-mining line is what makes ore/normal reachable; without it
    -- the recycler-loop forms a closed cycle that compute_reachable_materials
    -- can't bootstrap, and the LP would resort to |shortage_source| (the
    -- reachability gate adds it for every material that has no path from
    -- a raw input). Real Factorio chains always have an entry like this
    -- (mining drill / pumpjack / asteroid collector).
    --
    -- Constraint: produce 0.1 iron-plate/uncommon/s. LP should run the
    -- producer at ~1 machine; routing normal byproduct through recycler or
    -- to surplus depends on cost weights, so the assertion is convergence
    -- + the producer actually running + the constraint being met.
    run = function()
        local lines = {
            line("iron-mining", "normal",
                { item("iron-ore", "normal", 1) },
                {}),
            line("iron-plate", "normal",
                cascade("iron-plate", 1, "normal", 2),
                { item("iron-ore", "normal", 1) }),
            line("iron-plate-recycling", "normal",
                cascade("iron-ore", 0.25, "normal", 2),
                { item("iron-plate", "normal", 1) }),
            line("iron-plate-recycling", "uncommon",
                cascade("iron-ore", 0.25, "uncommon", 2),
                { item("iron-plate", "uncommon", 1) }),
        }
        local constraints = {
            { type = "item", name = "iron-plate", quality = "uncommon",
              limit_type = "equal", limit_amount_per_second = 0.1 },
        }

        local problem = cp.create_problem("recycling-2t", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_true(
            vars.x["recipe/iron-plate/normal"] > 0.5,
            "iron-plate producer runs (got " .. tostring(vars.x["recipe/iron-plate/normal"]) .. ")"
        )
        -- positive_slack on the uncommon-plate limit should be ~0: the LP
        -- met the user constraint exactly.
        harness.assert_near(
            vars.x["%positive_slack%|limit|item/iron-plate/uncommon"] or 0,
            0, 0.01, "positive_slack on uncommon constraint")
    end,
})

table.insert(cases, {
    name = "3-tier recycling chain with per-tier producers and recyclers converges",
    -- A slightly deeper loop than the 2-tier case: producer and recycler at
    -- normal/uncommon/rare. Reaches rare via either the producer's cascade
    -- or repeated recycling. Constraint puts a small demand on rare plate.
    -- This is the largest recycling chain we currently expect to solve from
    -- a fresh start; 4-5 tier cases get progressively harder and the 5-tier
    -- one is captured in lp_deep_recycling_xfail.
    run = function()
        local lines = {
            line("iron-mining", "normal",
                { item("iron-ore", "normal", 1) },
                {}),
            line("iron-plate", "normal",
                cascade("iron-plate", 1, "normal", 3),
                { item("iron-ore", "normal", 1) }),
            line("iron-plate-recycling", "normal",
                cascade("iron-ore", 0.25, "normal", 3),
                { item("iron-plate", "normal", 1) }),
            line("iron-plate-recycling", "uncommon",
                cascade("iron-ore", 0.25, "uncommon", 3),
                { item("iron-plate", "uncommon", 1) }),
            line("iron-plate-recycling", "rare",
                cascade("iron-ore", 0.25, "rare", 3),
                { item("iron-plate", "rare", 1) }),
        }
        local constraints = {
            { type = "item", name = "iron-plate", quality = "rare",
              limit_type = "equal", limit_amount_per_second = 0.01 },
        }

        local problem = cp.create_problem("recycling-3t", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_true(
            vars.x["recipe/iron-plate/normal"] > 0.01,
            "iron-plate producer runs (got " .. tostring(vars.x["recipe/iron-plate/normal"]) .. ")"
        )
        harness.assert_near(
            vars.x["%positive_slack%|limit|item/iron-plate/rare"] or 0,
            0, 0.01, "positive_slack on rare constraint")
    end,
})

return cases
