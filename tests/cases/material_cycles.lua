-- Headless validation of solver/material_cycles.lua.
--
-- The cases mirror the three deficit-detection scenarios from the design
-- discussion (kovarex / simple recycling / 5-tier quality recycling), plus
-- a no-cycle sanity case. Each test verifies the SCC structure produced by
-- Tarjan and the deficit set produced by the uniform-rate + 50% threshold
-- heuristic, before any wiring into create_problem.lua.

local harness = require "tests/harness"
local mc = require "solver/material_cycles"

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

local function set_size(s)
    local n = 0
    for _ in pairs(s) do n = n + 1 end
    return n
end

local function set_keys(s)
    local out = {}
    for k in pairs(s) do out[#out + 1] = k end
    table.sort(out)
    return out
end

local QUALITY = { "normal", "uncommon", "rare", "epic", "legendary" }

---Helper identical to lp_quality_recycling_loop's cascade: spreads the base
---amount across consecutive quality tiers using a fixed next-tier probability
---(default 0.1), so consumed mass of a recipe shows up at the start quality
---plus a small tail at each higher tier.
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
    name = "linear chain has no cyclic SCCs and no deficits",
    -- m1 -> m2 -> m3 -> m4. Each material has at most one predecessor and
    -- at most one successor; no SCC contains more than one node, and no
    -- node has a self-edge.
    run = function()
        local lines = {
            line("r1", "normal", { item("m2", "normal", 1) }, { item("m1", "normal", 1) }),
            line("r2", "normal", { item("m3", "normal", 1) }, { item("m2", "normal", 1) }),
            line("r3", "normal", { item("m4", "normal", 1) }, { item("m3", "normal", 1) }),
        }
        local deficits, cyclic = mc.find_deficit_materials(lines)
        harness.assert_eq(#cyclic, 0, "no cyclic SCCs")
        harness.assert_eq(set_size(deficits), 0, "no deficits")
    end,
})

table.insert(cases, {
    name = "kovarex-like productivity cycle has cycle but no deficits",
    -- 40 U-235 + 5 U-238 -> 41 U-235 + 5 U-238. U-235 is net +1/run, U-238
    -- is net 0/run -- the canonical productivity cycle that should pass
    -- through SCC detection without any deficit flag.
    run = function()
        local lines = {
            line("kovarex", "normal",
                { item("u-235", "normal", 41), item("u-238", "normal", 5) },
                { item("u-235", "normal", 40), item("u-238", "normal", 5) }),
        }
        local deficits, cyclic = mc.find_deficit_materials(lines)
        harness.assert_eq(#cyclic, 1, "one cyclic SCC")
        harness.assert_eq(#cyclic[1], 2, "kovarex SCC contains both uranium isotopes")
        harness.assert_eq(set_size(deficits), 0,
            "no deficits in productivity cycle (got " ..
            table.concat(set_keys(deficits), ", ") .. ")")
    end,
})

table.insert(cases, {
    name = "simple recycling loop flags only the consumed ingredients",
    -- ec-make: 3 cu + 1 ir -> 1 ec.
    -- ec-recycle: 1 ec -> 0.75 cu + 0.25 ir (25% yield like Factorio recyclers).
    -- At unit rates: cu net = -2.25, ir net = -0.75, ec net = 0. cu and ir
    -- are mass-losing; ec is balanced at recipe_rate * 0.9 = recycle_rate
    -- (off by 10% at unit rates, well under the 50% threshold).
    run = function()
        local lines = {
            line("ec-make", "normal",
                { item("ec", "normal", 1) },
                { item("cu", "normal", 3), item("ir", "normal", 1) }),
            line("ec-recycle", "normal",
                { item("cu", "normal", 0.75), item("ir", "normal", 0.25) },
                { item("ec", "normal", 1) }),
        }
        local deficits, cyclic = mc.find_deficit_materials(lines)
        harness.assert_eq(#cyclic, 1, "one cyclic SCC")
        harness.assert_eq(#cyclic[1], 3, "SCC contains cu, ir, ec")

        harness.assert_true(deficits["item/cu/normal"], "cu flagged as deficit")
        harness.assert_true(deficits["item/ir/normal"], "ir flagged as deficit")
        harness.assert_true(not deficits["item/ec/normal"],
            "ec is balanceable, not a deficit")
        harness.assert_eq(set_size(deficits), 2,
            "exactly cu and ir flagged (got " ..
            table.concat(set_keys(deficits), ", ") .. ")")
    end,
})

table.insert(cases, {
    name = "5-tier quality recycling: only the source SCC (normal tier) is flagged",
    -- All-in-cycle variant of the lp_quality_recycling_loop 5-tier fixture:
    -- electronic-circuit producers and recyclers at every quality tier
    -- (legendary has no recycler since there's nowhere to upgrade it to),
    -- but no iron-plate / copper-cable producer recipes -- the chain
    -- never reaches an open boundary. Without external supply for cu/ir at
    -- some quality, the LP can only return the zero solution.
    --
    -- Expected structure: four cyclic SCCs (one per recyclable tier),
    -- each containing {cu/q, ir/q, ec/q}. Quality cascade is unidirectional
    -- (higher only), so each tier's SCC is closed off from the next tier.
    -- The legendary tier's materials are non-cyclic singletons.
    --
    -- Source-SCC gate: only the normal-quality cycle has no upstream
    -- producer feeding it. Uncommon..epic each receive their cu/ir/ec
    -- from the normal cycle's recycling cascade tail, so they are not
    -- source SCCs and their materials must not be flagged as deficits.
    -- Without this gate the LP would get a free copy of cu/legendary +
    -- ir/legendary and short-circuit straight to the legendary recipe,
    -- bypassing the cascade.
    run = function()
        local lines = {}
        for i, q in ipairs(QUALITY) do
            local tiers = #QUALITY - i + 1
            table.insert(lines, line("ec-make", q,
                cascade("ec", 1, q, tiers),
                { item("ir", q, 1), item("cu", q, 3) }))
        end
        for i = 1, #QUALITY - 1 do
            local q = QUALITY[i]
            local tiers = #QUALITY - i + 1
            local rec_products = {}
            for _, ingredient_amount in ipairs({
                { "ir", 1 * 0.25 },
                { "cu", 3 * 0.25 },
            }) do
                for _, amt in ipairs(cascade(ingredient_amount[1], ingredient_amount[2], q, tiers)) do
                    table.insert(rec_products, amt)
                end
            end
            table.insert(lines, line("ec-recycle", q, rec_products,
                { item("ec", q, 1) }))
        end

        local deficits, cyclic = mc.find_deficit_materials(lines)
        harness.assert_eq(#cyclic, 4,
            "four cyclic SCCs (one per recyclable tier; legendary has no recycler)")
        for _, scc in ipairs(cyclic) do
            harness.assert_eq(#scc, 3, "each cyclic SCC has cu/q, ir/q, ec/q")
        end

        -- Only the normal-tier source SCC supplies deficits.
        harness.assert_true(deficits["item/cu/normal"], "cu/normal flagged as deficit")
        harness.assert_true(deficits["item/ir/normal"], "ir/normal flagged as deficit")
        harness.assert_true(not deficits["item/ec/normal"],
            "ec/normal is balanceable, not flagged")
        harness.assert_eq(set_size(deficits), 2,
            "exactly cu/normal and ir/normal (got " ..
            table.concat(set_keys(deficits), ", ") .. ")")

        -- Higher tiers receive cascade input from the normal cycle, so
        -- their SCCs are non-source and nothing in them is flagged.
        for i = 2, #QUALITY - 1 do
            local q = QUALITY[i]
            harness.assert_true(not deficits["item/cu/" .. q],
                "cu/" .. q .. " is downstream of normal cascade, not a deficit")
            harness.assert_true(not deficits["item/ir/" .. q],
                "ir/" .. q .. " is downstream of normal cascade, not a deficit")
        end
        harness.assert_true(not deficits["item/cu/legendary"],
            "cu/legendary outside any cyclic SCC")
        harness.assert_true(not deficits["item/ir/legendary"],
            "ir/legendary outside any cyclic SCC")
        harness.assert_true(not deficits["item/ec/legendary"],
            "ec/legendary outside any cyclic SCC")
    end,
})

return cases
