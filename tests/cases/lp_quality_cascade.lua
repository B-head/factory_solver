-- Single-producer quality cascade fixtures: a recipe that emits its product
-- split across several quality tiers (what pre_solve.quality_decomposition
-- produces). No recycler loops here — those live in lp_quality_recycling_loop.
-- These cases exercise the LP's ability to balance flow when a producer
-- generates multiple sibling materials at once, with mismatched per-quality
-- consumers.

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

---Build a quality-decomposition cascade product list with the same shape
---pre_solve.quality_decomposition produces for a recipe with quality modules.
---`base_amount` is the recipe's native (un-decomposed) per-second amount.
---`start_quality` is the recipe-quality of the producer. `tiers` is how many
---cascade levels to emit (will not exceed the QUALITY chain length).
---`next_prob` is the per-step upgrade probability (Factorio default is 0.1).
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
    name = "2-tier cascade with constraint on the dominant (normal) tier converges",
    -- iron-plate recipe with 10% quality module: 1 iron-ore -> [normal 0.9,
    -- uncommon 0.1] iron-plate per machine. Constraint: produce 0.9 normal
    -- iron-plate/s (= exactly one machine's normal output). uncommon iron-plate
    -- has no consumer so it goes to its own free final_sink.
    run = function()
        local lines = {
            line("iron-plate", "normal",
                cascade("iron-plate", 1, "normal", 2),
                { item("iron-ore", "normal", 1) }),
        }
        local constraints = {
            { type = "item", name = "iron-plate", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 0.9 },
        }

        local problem = cp.create_problem("cascade-2t-normal", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_near(vars.x["recipe/iron-plate/normal"], 1, 0.05, "iron-plate machine count")
        harness.assert_near(vars.x["|final_sink|item/iron-plate/uncommon"], 0.1, 0.02,
            "uncommon iron-plate flows to its final_sink")
    end,
})

table.insert(cases, {
    name = "2-tier cascade with constraint on the rare (uncommon) tier converges",
    -- Same producer, but constrain the uncommon tier. The LP must run the
    -- recipe 10x harder (since only 10% of its output is uncommon), then the
    -- normal tier flows out at 9x the constrained rate. This is the basic
    -- "produce one rare thing, dump everything else" pattern.
    run = function()
        local lines = {
            line("iron-plate", "normal",
                cascade("iron-plate", 1, "normal", 2),
                { item("iron-ore", "normal", 1) }),
        }
        local constraints = {
            { type = "item", name = "iron-plate", quality = "uncommon",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("cascade-2t-uncommon", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_near(vars.x["recipe/iron-plate/normal"], 10, 0.2, "iron-plate machine count")
        harness.assert_near(vars.x["|final_sink|item/iron-plate/normal"], 9, 0.2,
            "normal iron-plate flows out at 9x the constrained tier")
        harness.assert_near(vars.x["|final_sink|item/iron-plate/uncommon"], 1, 0.05,
            "uncommon iron-plate matches the constraint")
    end,
})

table.insert(cases, {
    name = "3-tier cascade with per-tier consumers picks the right balance",
    -- Producer iron-plate -> [n 0.9, u 0.09, r 0.01]. Two per-tier consumer
    -- recipes (circuit/normal and circuit/uncommon) drain the lower two
    -- tiers; rare has no consumer so it must flow to surplus_sink (priced).
    -- Constraint: produce 0.09 uncommon circuits/s. The optimum is one
    -- iron-plate machine (which produces the matching uncommon flow) with
    -- circuit/normal absorbing the 0.9 normal byproduct for free via its
    -- own final_sink.
    run = function()
        local lines = {
            line("iron-plate", "normal",
                cascade("iron-plate", 1, "normal", 3),
                { item("iron-ore", "normal", 1) }),
            line("circuit", "normal",
                { item("circuit", "normal", 1) },
                { item("iron-plate", "normal", 1) }),
            line("circuit", "uncommon",
                { item("circuit", "uncommon", 1) },
                { item("iron-plate", "uncommon", 1) }),
        }
        local constraints = {
            { type = "item", name = "circuit", quality = "uncommon",
              limit_type = "equal", limit_amount_per_second = 0.09 },
        }

        local problem = cp.create_problem("cascade-3t-per-tier", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 300 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")
        harness.assert_near(vars.x["recipe/iron-plate/normal"], 1, 0.05, "iron-plate machine count")
        harness.assert_near(vars.x["recipe/circuit/uncommon"], 0.09, 0.01,
            "uncommon circuit recipe matches constraint")
        harness.assert_near(vars.x["recipe/circuit/normal"], 0.9, 0.05,
            "normal circuit recipe absorbs the 0.9 normal byproduct")
    end,
})

return cases
