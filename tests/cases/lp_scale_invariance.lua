-- Scale-invariance regressions for the constraint right-hand side.
--
-- An LP whose constraints scale linearly with the user's `limit_amount_per_second`
-- has a feasible region that is a homothety of itself: doubling the limit
-- doubles every variable in the optimum. The IPM should reproduce that, so
-- the ratio of solutions at limit = k·L₀ vs limit = L₀ should be ~k for every
-- recipe variable that is non-trivially active.
--
-- The bug these cases pin down: at small constraint values (e.g. upper-limit
-- = 1 on legendary EC), the IPM has been observed to stall at the cold-start
-- vector x₀ = ‖b‖∞ ≈ 1 across every recipe, producing a degenerate
-- "everyone runs at 1.000" answer instead of the geometric recycling cascade.
-- Bumping the same problem to limit = 10 yields a believable cascade with
-- recipe values spanning ~500×. Both can't be optimal for a scale-invariant
-- LP — at least one is wrong, and the visible degenerate one is the bug.
--
-- Assertion strategy: solve each problem twice with independent cold starts,
-- then compare per-recipe ratios against the expected scale factor. We pick
-- a generous tolerance (15%) because the IPM's analytic-center bias on a
-- degenerate face can shift the centring slightly with the problem scale,
-- but anything inside that band is fine — what we are pinning down is the
-- order-of-magnitude divergence, not solver round-off.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

local fixture = require "tests/cases/fixture"
local QUALITY = fixture.QUALITY
local item, line, cascade = fixture.item, fixture.line, fixture.cascade

---Solve `problem` from a fresh cold start, asserting it converges.
---@param problem Problem
---@param tag string Diagnostic prefix for the assertion message.
---@param iterate_limit integer
---@return table<string, number> x
local function solve_fresh(problem, tag, iterate_limit)
    local state, vars = harness.solve_to_completion(lp, problem,
        { tolerance = 1e-6, iterate_limit = iterate_limit })
    harness.assert_eq(state, "finished", tag .. " solver_state")
    assert(vars, tag .. ": expected packed variables on finished state")
    return vars.x
end

---Compare two solutions for proportionality. For every `recipe/*` variable
---that is meaningfully non-zero in either solution, x_big[i] / x_small[i]
---must equal `scale` within `rel_tol` (relative).
---@param x_small table<string, number>
---@param x_big table<string, number>
---@param scale number
---@param rel_tol number
---@param activity_floor number Variables below this in BOTH solutions are skipped.
local function assert_proportional(x_small, x_big, scale, rel_tol, activity_floor)
    local seen = {}
    for name, _ in pairs(x_small) do seen[name] = true end
    for name, _ in pairs(x_big) do seen[name] = true end

    local mismatches = {}
    for name, _ in pairs(seen) do
        -- Only check recipe variables — the LP also carries slack / source /
        -- sink variables whose values depend on how the IPM splits residuals,
        -- and those can diverge between scales without indicating wrongness.
        if name:sub(1, 7) == "recipe/" then
            local vs = x_small[name] or 0
            local vb = x_big[name] or 0
            if math.max(vs, vb) >= activity_floor then
                local expected = vs * scale
                local diff = math.abs(vb - expected)
                local denom = math.max(math.abs(expected), activity_floor)
                if diff / denom > rel_tol then
                    table.insert(mismatches, string.format(
                        "  %s: small=%g, big=%g, big/small=%.3f (expected %.3f)",
                        name, vs, vb, (vs > 0 and vb / vs or math.huge), scale))
                end
            end
        end
    end

    if #mismatches > 0 then
        table.sort(mismatches)
        error("recipe ratios not proportional to constraint scale (×" .. scale .. "):\n"
            .. table.concat(mismatches, "\n"), 2)
    end
end

---Build the 5-tier electronic-circuit recycling chain used by both
---lp_quality_recycling_loop and this file. Returns the line set;
---the caller picks the constraint limit.
---
---The shape and amount magnitudes are tuned to mirror the in-game LP
---captured in the user's factorio-current.log: iron-ore / copper-ore
---enter as |initial_source| inputs, iron-plate and copper-plate smelters
---bring them to plate form, copper-cable comes off copper-plate with
---a heavy productivity multiplier (the player's actual recipe carries
---enough productivity research + quality modules to push net product
---per craft to ~9× the input amount), and the EC chain runs through
---every quality tier with recyclers at every tier except legendary.
---The extreme product amounts on copper-cable / electronic-circuit
---are what make the LP's Cholesky factorisation numerically delicate.
local function build_5tier_lines()
    local lines = {}

    table.insert(lines, line("iron-plate", "normal",
        cascade("iron-plate", 1, "normal", 5, 0.248),
        { item("iron-ore", "normal", 1) }))
    -- copper-plate stays at normal only: matches the in-game log where the
    -- player's furnace has no quality modules, so the LP only ever needs
    -- copper-plate/normal as an ingredient for copper-cable.
    table.insert(lines, line("copper-plate", "normal",
        { item("copper-plate", "normal", 1) },
        { item("copper-ore", "normal", 1) }))
    -- copper-cable normal cost ≈ -1/(2·9) = -0.944 in-game → product/ingredient
    -- net = 8. With 1 copper-plate input the per-craft output is ~9 cables.
    table.insert(lines, line("copper-cable", "normal",
        cascade("copper-cable", 9, "normal", 5, 0.248),
        { item("copper-plate", "normal", 1) }))

    -- EC normal non-legendary cost ≈ -1/17 → ingredient - product = 7.5. With
    -- 4 items in (1 iron-plate + 3 copper-cable) and quality cascade we set
    -- per-craft product = 4 - 7.5 isn't possible; the in-game value reflects
    -- productivity also adding cascade output but the player's recipe must
    -- carry extra ingredient terms. Mirror by stacking the ingredient side:
    -- 1 iron-plate + 9 copper-cable, with 2.5 EC out per craft.
    --
    -- Legendary EC cost ≈ -1/6 → net = 2. Keep ingredient = 1 iron-plate +
    -- 9 copper-cable = 10, product = 8 EC (legendary tip of cascade has no
    -- further tier, so the whole 8 lands at legendary).
    -- The player's setup has 4× Q3 quality modules => ~24.8% next-tier
    -- cascade probability. Use that instead of the 10% default so A
    -- matrix entries match the in-game LP shape.
    local cascade_p = 0.248
    local ec_product_total = { 2.5, 2.5, 2.5, 2.5, 8 }
    for i, q in ipairs(QUALITY) do
        local tiers = #QUALITY - i + 1
        table.insert(lines, line("electronic-circuit", q,
            cascade("electronic-circuit", ec_product_total[i], q, tiers, cascade_p),
            { item("iron-plate", q, 1), item("copper-cable", q, 9) }))
    end

    -- Factorio recycler returns 1/4 of the BASE recipe ingredients
    -- (productivity doesn't apply to recycler returns). The in-game EC's
    -- BASE recipe is 1 iron + 3 cable = 4 items, quartered to 0.25 iron +
    -- 0.75 cable = 1 total. The corresponding LP cost ends up at -0.5
    -- (net = 0) for every recycler tier, matching the in-game log.
    for i = 1, #QUALITY - 1 do
        local q = QUALITY[i]
        local tiers = #QUALITY - i + 1
        local rec_products = {}
        for _, ingredient_amount in ipairs({
            { "iron-plate", 1 * 0.25 },
            { "copper-cable", 3 * 0.25 },
        }) do
            for _, amt in ipairs(cascade(ingredient_amount[1], ingredient_amount[2], q, tiers, cascade_p)) do
                table.insert(rec_products, amt)
            end
        end
        table.insert(lines, line("electronic-circuit-recycling", q,
            rec_products,
            { item("electronic-circuit", q, 1) }))
    end

    return lines
end

local cases = {}

table.insert(cases, {
    name = "2-tier recycling: solution scales 10× when constraint scales 10×",
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
        local function make(limit)
            return {
                { type = "item", name = "iron-plate", quality = "uncommon",
                  limit_type = "equal", limit_amount_per_second = limit },
            }
        end

        local p_small = cp.create_problem("scale-2t-small", make(0.1), lines)
        local x_small = solve_fresh(p_small, "limit=0.1", 400)
        local p_big = cp.create_problem("scale-2t-big", make(1.0), lines)
        local x_big = solve_fresh(p_big, "limit=1.0", 400)

        -- activity_floor = 1e-2: the deepest recycling tier (iron-plate-
        -- recycling/uncommon here) is a dead-end -- it consumes the target
        -- quality and emits an ore tier nothing else uses -- so create_problem's
        -- recipe_epsilon correctly drives it toward zero. The interior-point
        -- method parks it at ~tolerance/epsilon (~4e-4 here) rather than exactly
        -- 0, and that residual is constant across scale (it depends on tol and
        -- eps, not the target rate), so its ratio is meaningless. The genuine
        -- recipes all sit at >= 0.9 in this fixture, far above 1e-2, so the floor
        -- cleanly skips only the dust. See the recipe_epsilon note in
        -- solver/create_problem.lua.
        assert_proportional(x_small, x_big, 10, 0.15, 1e-2)
    end,
})

table.insert(cases, {
    name = "3-tier recycling: solution scales 10× when constraint scales 10×",
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
        local function make(limit)
            return {
                { type = "item", name = "iron-plate", quality = "rare",
                  limit_type = "equal", limit_amount_per_second = limit },
            }
        end

        local p_small = cp.create_problem("scale-3t-small", make(0.01), lines)
        local x_small = solve_fresh(p_small, "limit=0.01", 600)
        local p_big = cp.create_problem("scale-3t-big", make(0.1), lines)
        local x_big = solve_fresh(p_big, "limit=0.1", 600)

        -- activity_floor = 1e-2: same recipe_epsilon dust as the 2-tier case --
        -- the dead-end iron-plate-recycling/rare parks at ~5e-4 (scale-constant
        -- tol/eps residual) while the genuine recipes sit at >= 0.9. The floor
        -- skips only the dust. (Was 1e-4 before recipe_epsilon; the dead-end's
        -- pre-epsilon degenerate value happened to scale within tolerance, so the
        -- lower floor sufficed then.)
        assert_proportional(x_small, x_big, 10, 0.15, 1e-2)
    end,
})

---Solve from a warm start: take `prev_vars` (a `PackedVariables` table from
---an earlier solve) and feed it into the IPM as the new starting point. This
---mirrors `manage/pre_solve.lua`'s `forwerd_solve`, which deliberately
---preserves `raw_variables` across constraint edits so the IPM only needs to
---adjust an already-near-optimal point.
---@param problem Problem
---@param prev_vars PackedVariables
---@param tag string
---@param iterate_limit integer
---@param tolerance number?
---@return table<string, number> x
local function solve_warm(problem, prev_vars, tag, iterate_limit, tolerance)
    local tol = tolerance or 1e-6
    ---@type SolverState
    local state = "ready"
    ---@type integer?
    local iteration = nil
    ---@type PackedVariables?
    local vars = prev_vars
    local steps = 0
    while state == "calculating" or state == "ready" do
        state, iteration, vars = lp.solve(problem, state, iteration, vars, tol, iterate_limit)
        steps = steps + 1
        if steps > iterate_limit + 4 then
            error(tag .. ": solver did not reach a terminal state within "
                .. iterate_limit .. " IPM iterations")
        end
    end
    harness.assert_eq(state, "finished", tag .. " solver_state")
    assert(vars, tag .. ": expected packed variables on finished state")
    return vars.x
end

table.insert(cases, {
    name = "5-tier EC recycling: warm-start from limit=10 then re-solve at limit=1 stays proportional",
    -- This case reproduces the in-game flow: the user solves once, then edits
    -- the constraint and the solver is re-prepared with `solver_state =
    -- "ready"` but `raw_variables` retained (see `forwerd_solve` in
    -- manage/pre_solve.lua, comment "raw_variables intentionally preserved
    -- across re-prepares"). The IPM therefore warm-starts from a primal that
    -- is 10× the new optimum. Cold-start of the same problem (the previous
    -- case in this file) already passes; if THIS case fails, the bug is the
    -- warm-start path stalling before x shrinks back to the new scale.
    run = function()
        local lines = build_5tier_lines()

        local function make(limit)
            return {
                { type = "item", name = "electronic-circuit", quality = "legendary",
                  limit_type = "upper", limit_amount_per_second = limit },
            }
        end

        -- Cold-solve at limit=10 first to establish the reference solution
        -- and produce the warm-start packed variables.
        local p_big = cp.create_problem("warm-5t-big", make(10), lines)
        local state, big_vars = harness.solve_to_completion(lp, p_big,
            { tolerance = 1e-6, iterate_limit = 800 })
        harness.assert_eq(state, "finished", "limit=10 (cold) solver_state")
        assert(big_vars, "expected packed variables on finished state")
        local x_big = big_vars.x

        -- Now warm-start from x_big into the limit=1 problem. With a
        -- scale-invariant LP, the new optimum is x_big / 10 — the warm-start
        -- IPM must converge to that, not stall at the 10× starting point.
        local p_small = cp.create_problem("warm-5t-small", make(1), lines)
        local x_small = solve_warm(p_small, big_vars, "limit=1 warm", 800)

        assert_proportional(x_small, x_big, 10, 0.15, 1e-3)
    end,
})

table.insert(cases, {
    name = "5-tier EC recycling: three-solve chain 1/min → 10/min → 1/min stays converged",
    -- Exact in-game sequence captured in factorio-current.log:
    --   Solve 1: cold-start at limit=1/min  -> finished in 4 iter
    --   Solve 2: warm-start at limit=10/min -> finished in 4 iter
    --   Solve 3: warm-start at limit=1/min  -> UNFINISHED at iter=2
    --     (Cholesky lost precision).
    --
    -- The pair-wise warm-start case above only covers Solve 1→Solve 2
    -- (cold then warm). The third solve carries forward the s vector
    -- from a solution that *already* had boundary-clamped slack
    -- variables, and when the next problem scales x down 10× while s
    -- stays pinned at the 2⁻⁵² lower clamp, D² = X·S⁻¹ spans ~2⁵² and
    -- A·D²·Aᵀ's Cholesky factorisation drops a near-zero pivot. The
    -- chain reproduces this exactly.
    run = function()
        local lines = build_5tier_lines()
        local function make(limit)
            return {
                { type = "item", name = "electronic-circuit", quality = "legendary",
                  limit_type = "upper", limit_amount_per_second = limit },
            }
        end

        -- Match the in-game tolerance: manage/accessor.lua sets it to
        -- (10^-6)/2 = 5e-7, half of the default test harness uses. A
        -- tighter tolerance pushes the IPM further along the central
        -- path, leaving more s components stuck at the 2⁻⁵² lower clamp
        -- — which is what makes the next warm-start unstable.
        local tol = 0.5e-6

        -- Solve 1: cold-start at 1/min.
        local p1 = cp.create_problem("chain-1pm-a", make(1 / 60), lines)
        local state1, vars1 = harness.solve_to_completion(lp, p1,
            { tolerance = tol, iterate_limit = 800 })
        harness.assert_eq(state1, "finished", "Solve 1 (cold 1/min) solver_state")
        assert(vars1)

        -- Solve 2: warm-start at 10/min from Solve 1's vars. solve_warm
        -- asserts convergence; we re-run it the long way here so we can
        -- recover the full PackedVariables for the next warm-start.
        local p2 = cp.create_problem("chain-10pm", make(10 / 60), lines)
        ---@type SolverState
        local state2 = "ready"
        ---@type integer?
        local iteration2 = nil
        ---@type PackedVariables?
        local vars2 = vars1
        for _ = 1, 800 do
            state2, iteration2, vars2 = lp.solve(p2, state2, iteration2, vars2, tol, 800)
            if state2 == "finished" or state2 == "unfinished"
                or state2 == "unbounded" or state2 == "unfeasible" then
                break
            end
        end
        harness.assert_eq(state2, "finished", "Solve 2 (warm 10/min) solver_state")
        assert(vars2, "Solve 2 must produce vars (got nil)")

        -- Solve 3: warm-start at 1/min from Solve 2's vars. This is the
        -- step that broke in-game.
        local p3 = cp.create_problem("chain-1pm-b", make(1 / 60), lines)
        local x3 = solve_warm(p3, vars2, "Solve 3 (warm 1/min)", 800, tol)

        -- The final solution should match Solve 1's (same constraint).
        assert_proportional(vars1.x, x3, 1, 0.15, 1e-5)
    end,
})

table.insert(cases, {
    name = "5-tier EC recycling: warm-start limit=10/min then re-solve limit=1/min (in-game scale)",
    -- Direct reproduction of the in-game failure:
    --   * User cold-solves at "10 / min" -> limit_amount_per_second = 10/60.
    --   * User edits the constraint to "1 / min" -> limit_amount_per_second
    --     = 1/60. In manage/pre_solve.lua's forwerd_solve the
    --     `solver_state = "ready"` is set but `raw_variables` is kept,
    --     so the IPM warm-starts at x ≈ 10× the new optimum.
    --   * In-game log shows `unfinished (Cholesky lost precision)` at the
    --     first iteration of the re-solve.
    --
    -- The per-minute (‖b‖∞ < 1) regime is what makes this case bite. The
    -- per-second case above slides through because both solves stay in the
    -- well-conditioned ‖b‖∞ ≥ 1 band.
    run = function()
        local lines = build_5tier_lines()
        local function make(limit)
            return {
                { type = "item", name = "electronic-circuit", quality = "legendary",
                  limit_type = "upper", limit_amount_per_second = limit },
            }
        end

        local p_big = cp.create_problem("warm-5t-10pm", make(10 / 60), lines)
        local state, big_vars = harness.solve_to_completion(lp, p_big,
            { tolerance = 1e-6, iterate_limit = 800 })
        harness.assert_eq(state, "finished", "limit=10/min (cold) solver_state")
        assert(big_vars, "expected packed variables on finished state")
        local x_big = big_vars.x

        local p_small = cp.create_problem("warm-5t-1pm", make(1 / 60), lines)
        local x_small = solve_warm(p_small, big_vars, "limit=1/min warm", 800)

        assert_proportional(x_small, x_big, 10, 0.15, 1e-5)
    end,
})

table.insert(cases, {
    name = "5-tier EC recycling (upper limit 1 vs 10) scales linearly",
    -- This is the exact shape behind the screenshots that motivated this
    -- test file: upper-bound constraint on legendary EC, full 5-tier
    -- cascade. At limit=1 the in-game solver pins every recipe at ~1.000
    -- (the cold-start vector). At limit=10 it produces a believable
    -- geometric cascade. The two cannot both be correct.
    run = function()
        local lines = build_5tier_lines()

        local function make(limit)
            return {
                { type = "item", name = "electronic-circuit", quality = "legendary",
                  limit_type = "upper", limit_amount_per_second = limit },
            }
        end

        local p_small = cp.create_problem("scale-5t-small", make(1), lines)
        local x_small = solve_fresh(p_small, "limit=1", 800)
        local p_big = cp.create_problem("scale-5t-big", make(10), lines)
        local x_big = solve_fresh(p_big, "limit=10", 800)

        -- The user-visible "Required" column is each recipe's x value.
        -- assert_proportional checks every recipe/* in either solution.
        assert_proportional(x_small, x_big, 10, 0.15, 1e-3)
    end,
})

table.insert(cases, {
    name = "5-tier EC recycling at 1/min (in-game scale) converges",
    -- Direct reproduction of the bug visible in
    -- factorio-current.log: with `limit_amount_per_second = 1/60` (the
    -- internal per-second form of the UI's "1/min" entry) the in-game
    -- IPM aborts at iterate=1 with `Cholesky lost precision`, leaving
    -- raw_variables = nil. The UI then displays every recipe pinned to
    -- the cold-start vector x₀ = max(1, ‖b‖∞) = 1.
    --
    -- The cold start sets x₀ uniformly to max(1, ‖b‖∞). When
    -- ‖b‖∞ = 1/60 ≈ 0.017 the max() floor clamps x₀ at 1 — about 60×
    -- larger than the true optimum. That mismatch drives the first
    -- Newton step's find_step ratios to the boundary, S collapses to
    -- the 2⁻⁵² clamp, and A·S·X⁻¹·Aᵀ becomes too ill-conditioned for
    -- the unpivoted Cholesky to survive even with the 2⁻¹² fallback
    -- regularisation. Same fixture as the other 5-tier cases — only
    -- the limit value differs, which is exactly what makes this a LP
    -- scaling bug.
    run = function()
        local lines = build_5tier_lines()
        local constraints = {
            { type = "item", name = "electronic-circuit", quality = "legendary",
              limit_type = "upper", limit_amount_per_second = 1 / 60 },
        }
        local problem = cp.create_problem("5t-in-game-scale", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 800 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")

        -- The legendary EC recipe must run -- it is the only producer of
        -- the constrained material.
        harness.assert_true(
            (vars.x["recipe/electronic-circuit/legendary"] or 0) > 0,
            "legendary EC recipe runs (got "
                .. tostring(vars.x["recipe/electronic-circuit/legendary"]) .. ")"
        )
        -- The constraint should be met by the LP -- |final_sink| equals
        -- the requested limit and positive_slack stays near zero.
        harness.assert_near(
            vars.x["|final_sink|item/electronic-circuit/legendary"] or 0,
            1 / 60, 1e-4, "final_sink hits the per-second limit")
        harness.assert_near(
            vars.x["%positive_slack%|limit|item/electronic-circuit/legendary"] or 0,
            0, 1e-4, "no positive_slack consumed")
    end,
})

table.insert(cases, {
    name = "5-tier EC recycling at 1/min vs 10/min scales linearly (in-game scale)",
    -- Same as the 1-vs-10 case above, but at the per-minute scale the
    -- in-game UI actually feeds the solver. With ‖b‖∞ < 1 in both runs
    -- the cold-start cap kicks in for both, so this case stresses the
    -- bug from a different angle: when both solves start from the same
    -- (mis-scaled) initial x₀ = 1, the IPM still has to find solutions
    -- whose ratio is exactly 10×.
    run = function()
        local lines = build_5tier_lines()
        local function make(limit)
            return {
                { type = "item", name = "electronic-circuit", quality = "legendary",
                  limit_type = "upper", limit_amount_per_second = limit },
            }
        end

        local p_small = cp.create_problem("5t-1pm", make(1 / 60), lines)
        local x_small = solve_fresh(p_small, "limit=1/min", 800)
        local p_big = cp.create_problem("5t-10pm", make(10 / 60), lines)
        local x_big = solve_fresh(p_big, "limit=10/min", 800)

        assert_proportional(x_small, x_big, 10, 0.15, 1e-5)
    end,
})

return cases
