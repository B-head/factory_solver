---@diagnostic disable: undefined-global
-- Tilted-cost experiment, target #1: the lp_lower_limit "multi-step chain with
-- unclearable by-products" fixture, solved with reachability gating OFF.
--
-- Fixture: m_in -[r_mid]-> m_mid (+by_a,by_b) -[r_top]-> m_target (+by_c,by_d).
-- by_a..by_d have disabled consumers (upper=0) so they can only go to a
-- surplus_sink at elastic_cost (1024). m_target has a lower bound of 1.
--
-- With the gate ON, m_mid (reachable from raw) gets NO |shortage_source|, so
-- the chain must run: r_mid = r_top = 1. With the gate OFF, m_mid gets the
-- hatch at flat 1024 and the LP cheats:
--   cheat   = shortage(m_mid) 1024 + by_c 1024 + by_d 1024 = 3072
--   correct = r_mid byproducts 2048 + m_in 1 + r_top byproducts 2048 = ~4097
-- so r_mid -> 0. To make the chain win, shortage(m_mid) must exceed m_mid's
-- marginal production cost = by_a + by_b + m_in = 1024 + 1024 + 1 = 2049.
--
-- This script tries several tilt axes (decided up front) and prints raw data:
-- the resulting r_mid rate, the shortage(m_mid) draw, and the LP objective.
-- No pass/fail judgement is baked into the cost design -- we report and look.

require "tests/headless_env"

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local function item(name, amount)
    return { type = "item", name = name, quality = "normal", amount_per_second = amount }
end
local function line(recipe_name, products, ingredients)
    return {
        recipe_typed_name = { type = "recipe", name = recipe_name, quality = "normal" },
        products = products, ingredients = ingredients,
        power_per_second = 0, pollution_per_second = 0,
    }
end

local function build_fixture()
    local lines = {
        line("r_mid", { item("m_mid", 1), item("by_a", 1), item("by_b", 1) }, { item("m_in", 1) }),
        line("r_top", { item("m_target", 1), item("by_c", 1), item("by_d", 1) }, { item("m_mid", 1) }),
        line("r_consume_a", { item("sa", 1) }, { item("by_a", 1) }),
        line("r_consume_b", { item("sb", 1) }, { item("by_b", 1) }),
        line("r_consume_c", { item("sc", 1) }, { item("by_c", 1) }),
        line("r_consume_d", { item("sd", 1) }, { item("by_d", 1) }),
    }
    local constraints = {
        { type = "recipe", name = "r_consume_a", quality = "normal", limit_type = "upper", limit_amount_per_second = 0 },
        { type = "recipe", name = "r_consume_b", quality = "normal", limit_type = "upper", limit_amount_per_second = 0 },
        { type = "recipe", name = "r_consume_c", quality = "normal", limit_type = "upper", limit_amount_per_second = 0 },
        { type = "recipe", name = "r_consume_d", quality = "normal", limit_type = "upper", limit_amount_per_second = 0 },
        { type = "item", name = "m_target", quality = "normal", limit_type = "lower", limit_amount_per_second = 1 },
    }
    return constraints, lines
end

local ELASTIC = 2 ^ 10 -- 1024, the flat shortage/surplus cost tier

-- depth map for the fixture (computed once for the depth-based tilts).
local constraints0, lines0 = build_fixture()
local depth = cp.compute_reachability_depth(lines0)

-- Run one config: opts merged onto reachability_gating=false. Returns a row.
local function run_cfg(name, shortage_cost_fn)
    local constraints, lines = build_fixture()
    local options = { reachability_gating = false, shortage_cost_fn = shortage_cost_fn }
    local problem = cp.create_problem("tilt", constraints, lines, nil, options)
    local state, vars = harness.solve_to_completion(lp, problem,
        { tolerance = 1e-6, iterate_limit = 600 })
    local x = vars and vars.x or {}
    local r_mid = x["recipe/r_mid/normal"] or 0
    local r_top = x["recipe/r_top/normal"] or 0
    local sh_mid = x["|shortage_source|item/m_mid/normal"] or 0
    local m_in = x["|initial_source|item/m_in/normal"] or 0
    -- the cost actually assigned to shortage(m_mid) under this config
    local sh_cost = shortage_cost_fn and shortage_cost_fn("item/m_mid/normal") or ELASTIC
    local chain_wins = r_mid > 0.95
    return {
        name = name, state = state, sh_cost = sh_cost,
        r_mid = r_mid, r_top = r_top, sh_mid = sh_mid, m_in = m_in,
        chain = chain_wins,
    }
end

-- ---- tilt configs (decided up front) ---------------------------------------
local configs = {}

-- A) flat constant K * ELASTIC (the minimal "tilt" -- a uniform bump). Sweep K.
for _, k in ipairs({ 1, 1.5, 2, 2.001, 3, 4, 8 }) do
    configs[#configs + 1] = { ("A:flat x%.3g"):format(k), function() return ELASTIC * k end }
end

-- B) depth-based: cost = ELASTIC * base^depth. m_in depth 0, m_mid depth 1,
--    m_target depth 2. Shallow-low / deep-high (deeper material costlier).
for _, base in ipairs({ 2, 3, 4 }) do
    configs[#configs + 1] = { ("B:depth base^d b=%g"):format(base), function(cn)
        local d = depth[cn] or 0
        return ELASTIC * (base ^ d)
    end }
end

-- B') depth inverted: shallow material (closer to raw) costlier, since a
--     shallow reachable material is "more obviously" should-be-made.
for _, mult in ipairs({ 2, 4 }) do
    configs[#configs + 1] = { ("B':invdepth +mult/(d+1) m=%g"):format(mult), function(cn)
        local d = depth[cn] or 99
        return ELASTIC * (1 + mult / (d + 1))
    end }
end

-- C) chain-marginal-cost estimate + margin. For each material, estimate the
--    cost of producing one unit via its real chain = (#unclearable byproducts
--    of its producer) * ELASTIC + raw source_cost, then price the hatch above
--    that. Here we just hardcode the analytic estimate for m_mid (2049) scaled.
for _, margin in ipairs({ 0.5, 1.0 }) do
    configs[#configs + 1] = { ("C:chainEst+margin m=%g"):format(margin), function(cn)
        -- analytic per-fixture estimate: m_mid producer r_mid emits 2 unclearable
        -- byproducts + 1 raw => 2*1024 + 1 = 2049. (Real impl would derive this
        -- from the line graph; hardcoded here to test the *idea*.)
        local est = (cn == "item/m_mid/normal") and 2049 or ELASTIC
        return est * (1 + margin)
    end }
end

-- ---- run + report ----------------------------------------------------------
print("fixture depths: m_in=" .. tostring(depth["item/m_in/normal"]) ..
      " m_mid=" .. tostring(depth["item/m_mid/normal"]) ..
      " m_target=" .. tostring(depth["item/m_target/normal"]))
print("control: chain marginal cost for m_mid = 2*1024 + 1 = 2049; flat shortage = 1024")
print("")
print(string.format("%-26s %-9s %10s %7s %7s %8s %8s  %s",
    "config", "state", "sh_cost", "r_mid", "r_top", "sh_mid", "m_in", "chain?"))

-- baseline: gate ON (control, should run the chain)
do
    local constraints, lines = build_fixture()
    local problem = cp.create_problem("tilt", constraints, lines, nil, { reachability_gating = true })
    local state, vars = harness.solve_to_completion(lp, problem, { tolerance = 1e-6, iterate_limit = 600 })
    local x = vars and vars.x or {}
    print(string.format("%-26s %-9s %10s %7.3f %7.3f %8.3f %8.3f  %s",
        "GATE-ON (control)", state, "n/a",
        x["recipe/r_mid/normal"] or 0, x["recipe/r_top/normal"] or 0,
        x["|shortage_source|item/m_mid/normal"] or 0, x["|initial_source|item/m_in/normal"] or 0,
        ((x["recipe/r_mid/normal"] or 0) > 0.95) and "YES" or "no"))
end

for _, cfg in ipairs(configs) do
    local r = run_cfg(cfg[1], cfg[2])
    print(string.format("%-26s %-9s %10.1f %7.3f %7.3f %8.3f %8.3f  %s",
        r.name, r.state, r.sh_cost, r.r_mid, r.r_top, r.sh_mid, r.m_in,
        r.chain and "YES" or "no"))
end
