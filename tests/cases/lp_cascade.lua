-- The cascade staged rescue (solver/cascade.lua), driven headless.
--
-- The shipped pipeline runs across the incremental solver's ticks
-- (manage/pre_solve.lua M.cascade_step): a finished solve feeds cascade.advance,
-- which either wants another build (re-arm "ready"), settles ("done"), or asks
-- to restore the adopted answer ("restore"). This file drives that exact loop
-- SYNCHRONOUSLY -- a minimal mirror of the pump and of
-- tests/research/probe_vp_rescue.lua's solve_shipped -- and pins the state
-- machine's observable behaviour: a producible import is rescued to zero, a
-- clean chain passes through untouched (exercising the restore path), a
-- non-consumable dump is correctly left alone, and the whole thing is
-- deterministic. The corpus equivalence driver
-- (tests/research/probe_cascade_ship.lua) covers the numeric fidelity against
-- the reference on real problems; this covers the wiring.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"
local cascade = require "solver/cascade"

local fixture = require "tests/cases/fixture"
local it = fixture.item
local line = fixture.line

local TOL, ITER = 1e-7, 800

local function solve(problem)
    return harness.solve_to_completion(lp, problem, { tolerance = TOL, iterate_limit = ITER })
end

-- Sum |x| over the variable keys carrying a given primal prefix.
local function escape_mass(x, prefix)
    local s = 0
    for k, v in pairs(x) do
        if k:find(prefix, 1, true) then s = s + math.abs(v) end
    end
    return s
end

local function machine_total(problem, x)
    local s = 0
    for key, p in pairs(problem.primals) do
        if p.kind == "recipe" then s = s + math.abs(x[key] or 0) end
    end
    return s
end

-- Drive the cascade to settlement exactly as manage/pre_solve.lua does, but
-- synchronously. Returns the final (problem, x) and the cascade state for
-- inspection. Cascade builds are solved cold (like the probe); the in-engine
-- pump warm-starts, a difference within the solver's degenerate-face noise.
local function drive(name, constraints, lines)
    local prob = cp.create_problem(name, constraints, lines, nil, { reachability_gating = false })
    local bstate, bvars = solve(prob)
    harness.assert_eq(bstate, "finished", name .. " baseline solver_state")

    -- No target collapse in these fixtures, so no target rescue (budget nil).
    local cc = cascade.begin(prob, bvars, lines, nil)
    local guard = 0
    while cc.build do
        guard = guard + 1
        assert(guard < 600, name .. ": cascade failed to settle (loop guard)")
        local build = cc.build
        local p = cp.create_problem(name, constraints, lines, nil, cascade.build_options(build))
        cascade.shape_problem(p, build)
        local s, v = solve(p)
        cascade.advance(cc, p, v, s)
        if cc.phase == "restore" then
            -- The last stage was rejected: rebuild the adopted problem (no
            -- solve) and report its answer, exactly as M.cascade_step does.
            local b = cc.build
            local rp = cp.create_problem(name, constraints, lines, nil, cascade.build_options(b))
            cascade.shape_problem(rp, b)
            return rp, cc.adopted_raw.x, cc
        end
    end
    -- Settled "done": the held solution is the adopted answer.
    local fp = cp.create_problem(name, constraints, lines, nil, cascade.build_options(cc.adopted_build))
    cascade.shape_problem(fp, cc.adopted_build)
    return fp, cc.adopted_raw.x, cc
end

local cases = {}

-- A producible import is rescued to zero. M is an intermediate (made by rMake
-- from a priced raw, consumed by rUse to make the target T). Making M the real
-- way costs 2000 raw per unit, ABOVE the 1024 |shortage_source| penalty, so the
-- un-gated baseline outsources M instead of running its chain. But M is
-- unambiguously producible -- rMake yields it from a free input, no
-- whack-a-mole partner -- so the cascade's Vp stage classifies it producible,
-- prices the hatch as the only objective, drives it to zero, and re-solves: the
-- chain now runs (raw flows as the priced makeup) and the producible import is
-- gone. (Contrast a 2-cycle like {target,mid}, where EITHER member can be the
-- makeup: the fixpoint keeps one producible and demotes the other to makeup, so
-- the import that actually flowed lands in the Vf tier, not Vp.)
table.insert(cases, {
    name = "cascade Vp: a producible import is fabricated, not outsourced",
    run = function()
        local lines = {
            line("rMake", { it("M", 1) }, { it("raw", 2000) }),
            line("rUse", { it("T", 1) }, { it("M", 1) }),
        }
        local constraints = {
            { type = "item", name = "T", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        local base = cp.create_problem("vp-base", constraints, lines, nil, { reachability_gating = false })
        local bs, bv = solve(base)
        harness.assert_eq(bs, "finished", "baseline solver_state")
        harness.assert_true((bv.x["|shortage_source|item/M/normal"] or 0) > 0.1,
            "baseline outsources the producible intermediate M (got shortage " ..
            (bv.x["|shortage_source|item/M/normal"] or 0) .. ")")

        local prob, x, cc = drive("vp", constraints, lines)
        harness.assert_true(cc.vp_rescued == 1, "the Vp stage fired (vp_rescued=" ..
            tostring(cc.vp_rescued) .. ")")
        harness.assert_near(escape_mass(x, "|shortage_source|"), 0, 1e-3,
            "the producible import is rescued to zero (got " ..
            escape_mass(x, "|shortage_source|") .. ")")
        -- The real chain is what now runs: rMake feeds rUse, drawing the priced
        -- raw |initial_source| as the legitimate makeup.
        harness.assert_true((x["|initial_source|item/raw/normal"] or 0) > 0.1,
            "the chain runs on the priced makeup (raw) instead")
        harness.assert_true(machine_total(prob, x) > 0.1, "recipes actually run")
    end,
})

-- A clean cheap chain is untouched. No producible import, no dump to consume,
-- no machine slack -- every stage is a no-op and the polish is rejected, so the
-- cascade RESTORES the baseline answer (exercising M.cascade_step's restore
-- path). The reported machine count must equal the baseline's exactly.
table.insert(cases, {
    name = "cascade passthrough: a clean chain settles to the baseline (restore path)",
    run = function()
        local lines = {
            line("mk", { it("T", 1) }, { it("ore", 1) }),
        }
        local constraints = {
            { type = "item", name = "T", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        local base = cp.create_problem("pass-base", constraints, lines, nil, { reachability_gating = false })
        local bs, bv = solve(base)
        harness.assert_eq(bs, "finished", "baseline solver_state")
        local m_base = machine_total(base, bv.x)

        local prob, x, cc = drive("pass", constraints, lines)
        harness.assert_near(machine_total(prob, x), m_base, 1e-4,
            "the settled machine count equals the baseline (got " ..
            machine_total(prob, x) .. " vs " .. m_base .. ")")
        harness.assert_near(escape_mass(x, "|shortage_source|"), 0, 1e-6,
            "no producible import was invented")
        harness.assert_true(cc.vp_rescued ~= 1, "Vp did not fire on a clean chain")
        harness.assert_near(escape_mass(x, "|initial_source|item/ore"), 1, 1e-3,
            "the single ore is still drawn as makeup")
    end,
})

-- A mass-positive breeding loop's overflow is a NON-consumable dump and is
-- correctly left alone (the drill_seed18 verdict: dumping the brood is right).
-- mk emits a joint byproduct X while making T; X is an intermediate whose only
-- consumer (breed) produces MORE X, so X can never be net-absorbed -- the
-- consumability fix-test (inject one X, absorb it without dumping X) fails and X
-- is not a Vc member, so its |surplus_sink| dump is never priced. This drives
-- the Vc individual-screen path (X enters vc_univ, gets classified) and asserts
-- the cascade does NOT spuriously rescue an irreducible overflow.
table.insert(cases, {
    name = "cascade Vc: a mass-positive breeding overflow is not rescued",
    run = function()
        local lines = {
            line("mk", { it("T", 1), it("X", 1) }, { it("ore", 1) }),
            line("breed", { it("X", 2) }, { it("X", 1) }),
        }
        local constraints = {
            { type = "item", name = "T", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        local prob, x, cc = drive("vc", constraints, lines)
        -- The 1 X that mk emits cannot be absorbed (breed only makes more), so
        -- it must leave through |surplus_sink|; the Vc stage must not price it.
        harness.assert_true((x["|surplus_sink|item/X/normal"] or 0) > 0.1,
            "the breeding overflow still dumps (got " ..
            (x["|surplus_sink|item/X/normal"] or 0) .. ")")
        harness.assert_true(cc.vc_rescued ~= 1, "Vc did not fire on a non-consumable overflow")
        harness.assert_near(machine_total(prob, x), 1, 1e-3,
            "exactly one mk machine runs to meet T (breed stays idle)")
    end,
})

-- Determinism: the cascade is part of the deterministic-lockstep solve path, so
-- the same problem must produce a bit-identical solution across runs.
table.insert(cases, {
    name = "cascade is deterministic across repeated runs",
    run = function()
        local lines = {
            line("r1", { it("mid", 1) }, { it("target", 1), it("raw", 2000) }),
            line("r2", { it("target", 2) }, { it("mid", 1) }),
        }
        local constraints = {
            { type = "item", name = "target", quality = "normal",
              limit_type = "equal", limit_amount_per_second = 1 },
        }
        local _, x1 = drive("det1", constraints, lines)
        local _, x2 = drive("det2", constraints, lines)
        for k, v in pairs(x1) do
            harness.assert_near(x2[k] or 0, v, 1e-9, "x[" .. k .. "] differs between runs")
        end
        for k, v in pairs(x2) do
            harness.assert_near(x1[k] or 0, v, 1e-9, "x[" .. k .. "] only in run 2")
        end
    end,
})

return cases
