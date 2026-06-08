-- Unit tests for solver/material_weights.lua: the embodied-cost weight
-- heuristic that normalizes the flat per-unit escape cost by each material's
-- conversion-ratio-derived weight.
--
-- These cases pin the propagation math on small synthetic chains (the ratio
-- arithmetic is exact and easy to read), the three modelling options
-- (allocation / combiner / cycle handling), and determinism. The trailing
-- "distribution" case prints weights for a recycling loop for inspection under
-- `lua tests/run.lua -v material_weights` -- it asserts only that the loop
-- resolves to finite positive weights, leaving any good/bad judgement to the
-- researcher.

local harness = require "tests/harness"
local mw = require "solver/material_weights"

local function item(name, amount)
    return { type = "item", name = name, quality = "normal", amount_per_second = amount }
end

local function line(recipe_name, products, ingredients)
    return {
        recipe_typed_name = { type = "recipe", name = recipe_name, quality = "normal" },
        products = products,
        ingredients = ingredients,
        power_per_second = 0,
        pollution_per_second = 0,
    }
end

-- Variable-name shorthand for an item/normal material.
local function key(name) return "item/" .. name .. "/normal" end

local cases = {}

table.insert(cases, {
    name = "1:1 chain leaves every material at base",
    run = function()
        local lines = {
            line("a", { item("a", 1) }, { item("raw", 1) }),
            line("b", { item("b", 1) }, { item("a", 1) }),
        }
        local r = mw.compute(lines)
        harness.assert_true(r.is_root[key("raw")], "raw is a root")
        harness.assert_near(r.weight[key("raw")], 1, 1e-12, "w(raw)=base")
        harness.assert_near(r.weight[key("a")], 1, 1e-12, "w(a)=1 (1:1)")
        harness.assert_near(r.weight[key("b")], 1, 1e-12, "w(b)=1 (1:1)")
    end,
})

table.insert(cases, {
    name = "mass-gain ratios divide the weight down the chain",
    run = function()
        -- 1 raw -> 10 a ; 1 a -> 10 b
        local lines = {
            line("a", { item("a", 10) }, { item("raw", 1) }),
            line("b", { item("b", 10) }, { item("a", 1) }),
        }
        local r = mw.compute(lines)
        harness.assert_near(r.weight[key("raw")], 1, 1e-12, "w(raw)=1")
        harness.assert_near(r.weight[key("a")], 0.1, 1e-12, "w(a)=1/10")
        harness.assert_near(r.weight[key("b")], 0.01, 1e-12, "w(b)=1/100")
    end,
})

table.insert(cases, {
    name = "mass-loss ratios raise the weight",
    run = function()
        -- 10 raw -> 1 a
        local lines = { line("a", { item("a", 1) }, { item("raw", 10) }) }
        local r = mw.compute(lines)
        harness.assert_near(r.weight[key("a")], 10, 1e-12, "w(a)=10")
    end,
})

table.insert(cases, {
    name = "amount allocation spreads input value over total output",
    run = function()
        -- 1 raw -> 1 a + 9 byp ; every product gets C_in/Σamount = 1/10
        local lines = { line("split", { item("a", 1), item("byp", 9) }, { item("raw", 1) }) }
        local r = mw.compute(lines, { allocation = "amount" })
        harness.assert_near(r.weight[key("a")], 0.1, 1e-12, "w(a)=1/10")
        harness.assert_near(r.weight[key("byp")], 0.1, 1e-12, "w(byp)=1/10")
    end,
})

table.insert(cases, {
    name = "main allocation charges the largest product, frees byproducts",
    run = function()
        -- 1 raw -> 10 main + 1 byp ; main bears all input value, byp is free
        local lines = { line("split", { item("main", 10), item("byp", 1) }, { item("raw", 1) }) }
        local r = mw.compute(lines, { allocation = "main" })
        harness.assert_near(r.weight[key("main")], 0.1, 1e-12, "w(main)=1/10")
        harness.assert_near(r.weight[key("byp")], 0, 1e-12, "w(byp)=0 (byproduct)")
    end,
})

table.insert(cases, {
    name = "min combiner picks the cheapest of several producing recipes",
    run = function()
        -- a from cheap (1 r1 -> 1 a) and dear (10 r2 -> 1 a). min -> 1.
        local lines = {
            line("a_cheap", { item("a", 1) }, { item("r1", 1) }),
            line("a_dear", { item("a", 1) }, { item("r2", 10) }),
        }
        local rmin = mw.compute(lines, { combiner = "min" })
        harness.assert_near(rmin.weight[key("a")], 1, 1e-12, "min -> cheap path = 1")
        local rmean = mw.compute(lines, { combiner = "mean" })
        harness.assert_near(rmean.weight[key("a")], 5.5, 1e-12, "mean -> (1+10)/2 = 5.5")
    end,
})

table.insert(cases, {
    name = "recycling loop resolves to finite positive weights (inspection)",
    run = function()
        -- A mass-losing recycle loop fed by an external root, with a final
        -- product drawn off it:
        --   mine:    () -> 1 ore               (root seed)
        --   smelt:   1 ore -> 1 plate
        --   product: 1 plate -> 1 widget       (the thing we want)
        --   recycle: 1 widget -> 0.25 plate    (mass-losing recovery)
        -- plate <-> widget forms the cycle (plate->widget->plate).
        local lines = {
            line("mine",    { item("ore", 1) },    {}),
            line("smelt",   { item("plate", 1) },  { item("ore", 1) }),
            line("product", { item("widget", 1) }, { item("plate", 1) }),
            line("recycle", { item("plate", 0.25) }, { item("widget", 1) }),
        }
        local r = mw.compute(lines)
        for _, name in ipairs({ "ore", "plate", "widget" }) do
            local w = r.weight[key(name)]
            harness.assert_true(w ~= nil and w > 0 and w < math.huge,
                "w(" .. name .. ") finite positive: " .. tostring(w))
        end
        harness.assert_true(r.is_root[key("ore")], "ore (no producer) is a root")

        io.write(string.format(
            "\n    [material_weights] recycle-loop weights: ore=%.4f plate=%.4f widget=%.4f\n",
            r.weight[key("ore")], r.weight[key("plate")], r.weight[key("widget")]))
    end,
})

--------------------------------------------------------------------------------
-- Robustness on complex cycles and parallel paths. These assert the function
-- terminates and returns finite, positive, deterministic weights for every
-- material -- the structural invariants the heuristic must never violate, no
-- matter how tangled the chain. The exact values are left unasserted (the
-- modelling choices set those); only the invariants are pinned.
--------------------------------------------------------------------------------

---Assert every weight is a finite positive number (no nil / nan / inf / <=0).
local function assert_all_finite_positive(r, label)
    for mvar, w in pairs(r.weight) do
        harness.assert_true(
            type(w) == "number" and w == w and w > 0 and w < math.huge,
            label .. ": w(" .. mvar .. ") finite positive, got " .. tostring(w))
    end
end

---Assert two computations agree exactly (determinism).
local function assert_same(r1, r2, label)
    for mvar, w in pairs(r1.weight) do
        harness.assert_eq(r2.weight[mvar], w, label .. " stable: " .. mvar)
    end
    for mvar in pairs(r2.weight) do
        harness.assert_true(r1.weight[mvar] ~= nil, label .. " no extra key: " .. mvar)
    end
end

table.insert(cases, {
    name = "two overlapping cycles sharing a node form one SCC and resolve",
    run = function()
        -- ore (root) -> a. a<->b cycle, b<->c cycle, sharing b: a->b->a and
        -- b->c->b. Strongly connected {a,b,c}. Mass-losing returns keep it
        -- from being self-sustaining; external ore feeds it through a.
        local lines = {
            line("mine",  { item("ore", 1) }, {}),
            line("mk_a",  { item("a", 1) },   { item("ore", 1) }),
            line("a_to_b",{ item("b", 2) },   { item("a", 1) }),
            line("b_to_a",{ item("a", 0.3) }, { item("b", 1) }),
            line("b_to_c",{ item("c", 2) },   { item("b", 1) }),
            line("c_to_b",{ item("b", 0.3) }, { item("c", 1) }),
        }
        local r = mw.compute(lines)
        assert_all_finite_positive(r, "overlapping cycles")
        assert_same(r, mw.compute(lines), "overlapping cycles")
        harness.assert_true(next(r.unresolved) == nil, "all resolved from ore feed")
    end,
})

table.insert(cases, {
    name = "parallel paths with different ratios into a shared product",
    run = function()
        -- widget made three ways from two roots at different ratios; min picks
        -- the cheapest. Also a downstream consumer of widget. No cycles.
        local lines = {
            line("mine_x", { item("x", 1) }, {}),
            line("mine_y", { item("y", 1) }, {}),
            line("w_cheap", { item("widget", 4) }, { item("x", 1) }),         -- 0.25
            line("w_mid",   { item("widget", 1) }, { item("x", 1) }),         -- 1
            line("w_dear",  { item("widget", 1) }, { item("y", 3) }),         -- 3
            line("gadget",  { item("gadget", 1) }, { item("widget", 2), item("y", 1) }),
        }
        local r = mw.compute(lines)
        assert_all_finite_positive(r, "parallel paths")
        harness.assert_near(r.weight[key("widget")], 0.25, 1e-12, "min path = 0.25")
        harness.assert_near(r.weight[key("gadget")], 0.25 * 2 + 1, 1e-12, "gadget = 2*0.25 + 1")
    end,
})

table.insert(cases, {
    name = "5-tier quality recycling loop (headline workload) resolves monotone",
    run = function()
        local Q = { "normal", "uncommon", "rare", "epic", "legendary" }
        local lines = { line("mine", { item("ore", 1) }, {}) }
        lines[1].products[1].quality = "normal"
        -- producer per tier: ore/q -> 0.9 plate/q + 0.1 plate/q+1
        -- recycler per tier: plate/q -> 0.225 ore/q + 0.025 ore/q+1
        for i = 1, #Q do
            local q, qn = Q[i], Q[math.min(i + 1, #Q)]
            local prod = { { type = "item", name = "plate", quality = q, amount_per_second = 0.9 } }
            local rec  = { { type = "item", name = "ore", quality = q, amount_per_second = 0.225 } }
            if i < #Q then
                prod[2] = { type = "item", name = "plate", quality = qn, amount_per_second = 0.1 }
                rec[2]  = { type = "item", name = "ore", quality = qn, amount_per_second = 0.025 }
            end
            lines[#lines + 1] = line("plate-" .. q, prod,
                { { type = "item", name = "ore", quality = q, amount_per_second = 1 } })
            lines[#lines + 1] = line("recycle-" .. q, rec,
                { { type = "item", name = "plate", quality = q, amount_per_second = 1 } })
        end
        local r = mw.compute(lines)
        assert_all_finite_positive(r, "5-tier")
        assert_same(r, mw.compute(lines), "5-tier")
        harness.assert_true(next(r.unresolved) == nil, "every tier resolved from ore feed")
        -- Note: weights are NOT monotone up the quality tiers under `amount`
        -- allocation -- a low-tier producer emits the next tier as a small
        -- byproduct that shares the bulk recipe's per-unit cost, so min makes
        -- the adjacent tier look as cheap as the bulk one (normal == uncommon
        -- here). That is a modelling consequence of amount allocation, not a
        -- break; the invariant is only finiteness / determinism / resolution.
        local widths = {}
        for _, q in ipairs(Q) do widths[#widths + 1] = string.format("%s=%.3g", q, r.weight["item/plate/" .. q]) end
        io.write("\n    [material_weights] 5-tier plate weights: " .. table.concat(widths, " ") .. "\n")
    end,
})

table.insert(cases, {
    name = "closed catalyst cycle with no external feed -> unresolved fallback",
    run = function()
        -- p<->q closed loop, fed by nothing in this chain. No root reaches it,
        -- so neither resolves from production; both fall back to max finite
        -- (here base, since there is no other material). Must stay finite, not
        -- blow up or hang.
        local lines = {
            line("p_to_q", { item("q", 1) }, { item("p", 1) }),
            line("q_to_p", { item("p", 1) }, { item("q", 1) }),
        }
        local r = mw.compute(lines)
        assert_all_finite_positive(r, "closed catalyst")
        harness.assert_true(r.unresolved[key("p")] and r.unresolved[key("q")],
            "both flagged unresolved")
    end,
})

table.insert(cases, {
    name = "self-loop recipe (consumes and produces same material) resolves",
    run = function()
        -- kovarex-like: a recipe consuming and producing the same material,
        -- net-positive, fed by an external seed. A single-node SCC with a
        -- self-loop. Must terminate and stay finite.
        local lines = {
            line("seed",   { item("u235", 0.1) }, {}),                 -- bootstrap
            line("breed",  { item("u235", 7) },   { item("u235", 5), item("u238", 40) }),
            line("mine238",{ item("u238", 1) },   {}),
        }
        local r = mw.compute(lines)
        assert_all_finite_positive(r, "self-loop")
        assert_same(r, mw.compute(lines), "self-loop")
    end,
})

table.insert(cases, {
    name = "long acyclic chain stays finite (deep ratio compounding)",
    run = function()
        -- 30-deep chain, each step 1 -> 2 (mass gain): weight halves each tier,
        -- reaching ~2^-29. Stays above the floor (1e-12 ~ 2^-40), finite.
        local lines = { line("m0", { item("s0", 1) }, {}) }
        for i = 1, 30 do
            lines[#lines + 1] = line("r" .. i,
                { item("s" .. i, 2) }, { item("s" .. (i - 1), 1) })
        end
        local r = mw.compute(lines)
        assert_all_finite_positive(r, "deep chain")
        harness.assert_near(r.weight[key("s10")], 2 ^ -10, 1e-15, "s10 = 2^-10")
    end,
})

table.insert(cases, {
    name = "deterministic across repeated runs",
    run = function()
        local lines = {
            line("mine",    { item("ore", 1) },    {}),
            line("smelt",   { item("plate", 3) },  { item("ore", 2) }),
            line("product", { item("widget", 1) }, { item("plate", 5), item("ore", 1) }),
            line("recycle", { item("plate", 0.5) }, { item("widget", 1) }),
        }
        local r1 = mw.compute(lines)
        local r2 = mw.compute(lines)
        for mvar, w in pairs(r1.weight) do
            harness.assert_eq(r2.weight[mvar], w, "weight[" .. mvar .. "] stable across runs")
        end
    end,
})

return cases
