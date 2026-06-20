-- create_problem's per-variable-class cost configuration: the class_cost /
-- class_quad options (and the import_quad shorthand) set the base linear cost
-- and the diagonal quadratic of an entire variable class (Primal.kind). These
-- cases assert the emitted Primal.cost / Primal.quad directly (no solve), so a
-- regression in the cost wiring is caught at the source.
--
-- Fixture chain: raw -[r1]-> mid -[r2]-> final, with `final` pinned (equal) and
-- r1 capped (upper). That single problem carries all seven non-bridge classes:
--   raw   ingredient only      -> initial_source
--   mid   produced + consumed  -> surplus_sink + shortage_source (plain default)
--   final product only         -> final_sink
--   r1/r2 recipes              -> recipe
--   final = 5 (equal)          -> elastic
--   r1   <= 10 (upper)         -> headroom
-- The bridge class is exercised by a separate fluid-temperature fixture.

local harness = require "tests/harness"
local cp = require "solver/create_problem"

local fixture = require "tests/cases/fixture"
local item, line = fixture.item, fixture.line

local cases = {}

---First primal of a given kind (for classes whose key is awkward to spell, e.g.
---the headroom pull-slack and the auto-generated bridge recipe).
---@param problem Problem
---@param kind string
---@return Primal?
local function first_of_kind(problem, kind)
    for _, p in pairs(problem.primals) do
        if p.kind == kind then return p end
    end
    return nil
end

---The non-bridge fixture above.
local function non_bridge_lines()
    return {
        line("r1", { item("mid", 1) }, { item("raw", 1) }),
        line("r2", { item("final", 1) }, { item("mid", 1) }),
    }
end

local function non_bridge_constraints()
    return {
        { type = "recipe", name = "r1", quality = "normal",
          limit_type = "upper", limit_amount_per_second = 10 },
        { type = "item", name = "final", quality = "normal",
          limit_type = "equal", limit_amount_per_second = 5 },
    }
end

table.insert(cases, {
    name = "class_cost overrides the base linear cost of every steerable class",
    run = function()
        -- Distinct prime-ish values so a cross-wired class is obvious.
        local class_cost = {
            recipe = 7,
            initial_source = 11,
            final_sink = 13,
            surplus_sink = 17,
            shortage_source = 19,
            elastic = 23,
            headroom = 29,
        }
        local problem = cp.create_problem("class-cost", non_bridge_constraints(),
            non_bridge_lines(), nil, { class_cost = class_cost })

        local prim = problem.primals
        -- Exact-cost classes (no jitter, no per-material scaling).
        harness.assert_near(prim["|initial_source|item/raw/normal"].cost, 11, 1e-9, "initial_source")
        harness.assert_near(prim["|final_sink|item/final/normal"].cost, 13, 1e-9, "final_sink")
        harness.assert_near(prim["|surplus_sink|item/mid/normal"].cost, 17, 1e-9, "surplus_sink")
        harness.assert_near(prim["|shortage_source|item/mid/normal"].cost, 19, 1e-9, "shortage_source")
        harness.assert_near(prim["|elastic||limit|item/final/normal"].cost, 23, 1e-9, "elastic")
        harness.assert_near(first_of_kind(problem, "headroom").cost, 29, 1e-9, "headroom")

        -- recipe keeps the per-key jitter: cost = tier * (1 + jitter), jitter in
        -- [0, jitter_strength = 2^-4). r2 is not a source line, so no source_cost
        -- is added on top.
        local r2 = prim["recipe/r2/normal"].cost
        harness.assert_true(r2 >= 7 and r2 <= 7 * (1 + 2 ^ -4) + 1e-9,
            "recipe tier override drives recipe cost (got " .. tostring(r2) .. ")")
    end,
})

table.insert(cases, {
    name = "no class_cost leaves every class at its shipped default tier",
    -- Guards the resolver's fallback path: an absent class_cost must reproduce the
    -- hardcoded ladder exactly (source_cost 1 for an item, elastic_cost 2^10,
    -- target_cost 2^20, slack_cost 0).
    run = function()
        local problem = cp.create_problem("class-cost-default", non_bridge_constraints(),
            non_bridge_lines(), nil, nil)
        local prim = problem.primals
        harness.assert_near(prim["|initial_source|item/raw/normal"].cost, 1, 1e-9, "initial_source default = source_cost item")
        harness.assert_near(prim["|final_sink|item/final/normal"].cost, 0, 1e-9, "final_sink default = slack_cost 0")
        harness.assert_near(prim["|surplus_sink|item/mid/normal"].cost, 2 ^ 10, 1e-9, "surplus_sink default = elastic_cost")
        harness.assert_near(prim["|shortage_source|item/mid/normal"].cost, 2 ^ 10, 1e-9, "shortage_source default = elastic_cost")
        harness.assert_near(prim["|elastic||limit|item/final/normal"].cost, 2 ^ 20, 1e-9, "elastic default = target_cost")
        harness.assert_near(first_of_kind(problem, "headroom").cost, 2 ^ 20, 1e-9, "headroom default = target_cost")
        harness.assert_true(problem.has_quad == false, "no quad without class_quad / import_quad")
    end,
})

table.insert(cases, {
    name = "the soft gate and per-material override scale the class_cost base",
    -- Composability: a shortage_source base override must flow through the soft
    -- gate (base * k) and the per-material override (base * mult), not the
    -- hardcoded elastic_cost.
    run = function()
        local problem = cp.create_problem("class-cost-compose", non_bridge_constraints(),
            non_bridge_lines(), nil, {
                class_cost = { shortage_source = 100 },
                reachability_soft_gate_k = 4,
                -- mid is reachable from raw, so the soft gate applies to it.
            })
        -- mid reachable -> soft gate: base(100) * k(4) = 400.
        harness.assert_near(problem.primals["|shortage_source|item/mid/normal"].cost, 400, 1e-9,
            "soft gate scales the class base")
    end,
})

table.insert(cases, {
    name = "class_quad puts a diagonal quadratic on every steerable class and flips has_quad",
    run = function()
        local class_quad = {
            recipe = 2,
            initial_source = 3,
            final_sink = 4,
            surplus_sink = 5,
            shortage_source = 6,
            elastic = 7,
            headroom = 8,
        }
        local problem = cp.create_problem("class-quad", non_bridge_constraints(),
            non_bridge_lines(), nil, { class_quad = class_quad })

        local prim = problem.primals
        harness.assert_true(problem.has_quad == true, "any class_quad flips has_quad")
        harness.assert_near(prim["recipe/r2/normal"].quad, 2, 1e-9, "recipe quad")
        harness.assert_near(prim["|initial_source|item/raw/normal"].quad, 3, 1e-9, "initial_source quad")
        harness.assert_near(prim["|final_sink|item/final/normal"].quad, 4, 1e-9, "final_sink quad")
        harness.assert_near(prim["|surplus_sink|item/mid/normal"].quad, 5, 1e-9, "surplus_sink quad")
        harness.assert_near(prim["|shortage_source|item/mid/normal"].quad, 6, 1e-9, "shortage_source quad")
        harness.assert_near(prim["|elastic||limit|item/final/normal"].quad, 7, 1e-9, "elastic quad")
        harness.assert_near(first_of_kind(problem, "headroom").quad, 8, 1e-9, "headroom quad")
    end,
})

table.insert(cases, {
    name = "import_quad is the shortage_source quad shorthand; explicit class_quad wins",
    run = function()
        -- Back-compat: import_quad alone sets the shortage_source quad.
        local p1 = cp.create_problem("imq", non_bridge_constraints(),
            non_bridge_lines(), nil, { import_quad = 0.5 })
        harness.assert_true(p1.has_quad == true, "import_quad flips has_quad")
        harness.assert_near(p1.primals["|shortage_source|item/mid/normal"].quad, 0.5, 1e-9,
            "import_quad -> shortage_source quad")

        -- An explicit class_quad.shortage_source takes precedence over import_quad.
        local p2 = cp.create_problem("imq-vs-class", non_bridge_constraints(),
            non_bridge_lines(), nil, { import_quad = 0.5, class_quad = { shortage_source = 9 } })
        harness.assert_near(p2.primals["|shortage_source|item/mid/normal"].quad, 9, 1e-9,
            "explicit class_quad.shortage_source wins over import_quad")
    end,
})

table.insert(cases, {
    name = "class_cost / class_quad reach the bridge class",
    -- A temperature bridge (steam@[165,165] produced, steam@[15,1000] consumed)
    -- is the only producer of a "bridge" kind. Its base cost is slack_cost by
    -- default plus a tiny per-key jitter; class_cost.bridge replaces the base.
    run = function()
        local function fluid(name, min, max, amount)
            return { type = "fluid", name = name, quality = "normal",
                     minimum_temperature = min, maximum_temperature = max,
                     amount_per_second = amount }
        end
        local lines = {
            line("boil", { fluid("steam", 165, 165, 1) }, { item("raw", 1) }),
            line("turb", { item("out", 1) }, { fluid("steam", 15, 1000, 1) }),
        }
        local constraints = {
            { type = "item", name = "out", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }
        local problem = cp.create_problem("bridge-cost", constraints, lines, nil,
            { class_cost = { bridge = 50 }, class_quad = { bridge = 0.25 } })

        local bridge = first_of_kind(problem, "bridge")
        harness.assert_true(bridge ~= nil, "a temperature bridge was generated")
        -- base 50 plus a jitter < recipe_epsilon * jitter_strength (~2^-10).
        harness.assert_near(bridge.cost, 50, 1e-2, "bridge base = class_cost.bridge (+ tiny jitter)")
        harness.assert_near(bridge.quad, 0.25, 1e-9, "bridge quad = class_quad.bridge")
    end,
})

return cases
