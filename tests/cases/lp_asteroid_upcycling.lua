-- Space Age asteroid quality upcycling, captured from a real save as the
-- LP create_problem produces it TODAY. This pins the *current* (undesired)
-- behaviour: a large (54 primal x 24 dual) ill-conditioned system where the
-- upcycle cascade cannot run and the shortage_source gate fires on the top
-- tier instead. The intended end-state is the upcycle actually computing --
-- see the "what should happen" note below.
--
-- Setup: three advanced-*-asteroid-crushing/legendary recipes are pinned at
-- rate 1 (|limit| = 1 with a 2^20 slack, forcing equality). Each crush
-- consumes 0.19 of its legendary chunk and emits legendary ores
-- (iron/copper/carbon/sulfur/ice/calcite). The 12 *-asteroid-reprocessing
-- recipes (normal/uncommon/rare/epic of three types) form a 5-tier x 3-type
-- quality cascade: each reprocess consumes one chunk and emits small
-- probabilistic amounts of higher-quality chunks of the same type plus
-- same-tier chunks of the other two types. The cascade is mass-LOSING (each
-- reprocess leaks ~13% of its mass up a quality tier) and create_problem
-- supplies NO external chunk source.
--
-- What happens today (asserted below): with no base chunk supply the cascade
-- cannot bootstrap -- running any reprocessing recipe only burns chunks it
-- doesn't have -- so the cost-minimal answer leaves all 12 reprocessing
-- recipes idle and pays |shortage_source| for exactly the 0.19 legendary
-- chunk each crush demands.
--
-- What SHOULD happen (not yet implemented): the user wants the upcycle to
-- actually compute -- normal chunks fed in (representing asteroid-collector
-- output), reprocessed up the quality cascade, crushed at legendary. That
-- needs a create_problem fix: recognise the bottom-tier chunk cross-cycle as
-- a material that needs a base |basic_source|. It is NOT flagged today
-- because material_cycles.find_deficit_materials only sees the bottom tier's
-- near-balanced cross-cycle (m/norm net at unit rate is just -19% of its
-- consumption, well under the 50% deficit threshold) and cannot see the
-- cross-TIER upward mass leak that makes the cascade genuinely need external
-- input. This is the false-NEGATIVE face of the same coarse per-SCC
-- uniform-rate heuristic whose false-POSITIVE face the Gleba bioflux xfail
-- (lp_gleba_loop.lua) documents. See [[deficit-false-positive-grow-loops]].
--
-- Because this fixture is a hand-built Problem (the exact matrix create_
-- problem emits today), it cannot be an xfail that flips when create_problem
-- is fixed -- the matrix here would not change. It stays a NORMAL case
-- pinning two still-true facts: (1) the IPM converges on a 54x24 system whose
-- coefficients span 0.000011 .. 2.0 alongside the 1024 / 2^20 cost tiers, and
-- (2) given a matrix with no chunk source, the shortage signal stays
-- precisely localized to the demanded tier rather than smearing. The
-- create_problem fix, when it lands, gets its own create_problem-driven test.
--
-- Variable names are shortened for readability (the test only needs unique
-- keys); the mapping to the in-game typed names is:
--   recipe/{m,c,o}-crush       = advanced-{metallic,carbonic,oxide}-asteroid-crushing/legendary
--   recipe/{m,c,o}-rp/<tier>    = {metallic,carbonic,oxide}-asteroid-reprocessing/<tier>
--   {m,c,o}/<tier>             = {metallic,carbonic,oxide}-asteroid-chunk/<tier>

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local pg = require "solver/problem_generator"

local cases = {}

table.insert(cases, {
    name = "asteroid upcycling, current behaviour: no base chunk source so cascade idles and shortage fires on legendary (intended fix is in create_problem)",
    run = function()
        local p = pg.new("asteroid-upcycle-no-source")

        local recipes = {
            "recipe/m-crush",
            "recipe/m-rp/epic", "recipe/m-rp/rare", "recipe/m-rp/unc", "recipe/m-rp/norm",
            "recipe/c-crush",
            "recipe/c-rp/epic", "recipe/c-rp/rare", "recipe/c-rp/unc", "recipe/c-rp/norm",
            "recipe/o-crush",
            "recipe/o-rp/epic", "recipe/o-rp/rare", "recipe/o-rp/unc", "recipe/o-rp/norm",
        }
        for _, r in ipairs(recipes) do
            p:add_objective(r, 0, true)
        end

        -- 15 chunk materials each get a surplus_sink + shortage_source pair.
        local chunks = {
            "m/leg", "m/epic", "c/epic", "c/leg", "o/epic", "o/leg",
            "m/rare", "c/rare", "o/rare",
            "m/unc", "c/unc", "o/unc",
            "m/norm", "c/norm", "o/norm",
        }
        for _, ch in ipairs(chunks) do
            p:add_objective("|surplus_sink|" .. ch, 1024, false)
            p:add_objective("|shortage_source|" .. ch, 1024, false)
        end

        local ores = { "iron", "copper", "carbon", "sulfur", "ice", "calcite" }
        for _, o in ipairs(ores) do
            p:add_objective("|final_sink|" .. o, 0, false)
        end

        p:add_objective("%positive_slack%|limit|m-crush", 1048576, false)
        p:add_objective("%positive_slack%|limit|c-crush", 1048576, false)
        p:add_objective("%positive_slack%|limit|o-crush", 1048576, false)

        -- Duals: 15 chunk balances + 6 ore balances (all limit 0) + 3 crush
        -- limit rows (limit 1).
        for _, ch in ipairs(chunks) do
            p:add_equivalence_constraint(ch, 0)
        end
        for _, o in ipairs(ores) do
            p:add_equivalence_constraint(o, 0)
        end
        p:add_equivalence_constraint("|limit|m-crush", 1)
        p:add_equivalence_constraint("|limit|c-crush", 1)
        p:add_equivalence_constraint("|limit|o-crush", 1)

        -- Every chunk row carries its surplus(-1) / shortage(+1) pair.
        for _, ch in ipairs(chunks) do
            p:add_subject_term("|surplus_sink|" .. ch, ch, -1)
            p:add_subject_term("|shortage_source|" .. ch, ch, 1)
        end

        -- Chunk-row recipe coefficients, transcribed from the trace's
        -- subject <A> dump (one block per chunk material).
        -- m/leg
        p:add_subject_term("recipe/m-crush",  "m/leg", -0.19)
        p:add_subject_term("recipe/m-rp/epic","m/leg", 0.0225)
        p:add_subject_term("recipe/m-rp/rare","m/leg", 0.00225)
        p:add_subject_term("recipe/m-rp/unc", "m/leg", 0.000225)
        p:add_subject_term("recipe/m-rp/norm","m/leg", 0.000022)
        p:add_subject_term("recipe/c-rp/epic","m/leg", 0.01125)
        p:add_subject_term("recipe/c-rp/rare","m/leg", 0.001125)
        p:add_subject_term("recipe/c-rp/unc", "m/leg", 0.000112)
        p:add_subject_term("recipe/c-rp/norm","m/leg", 0.000011)
        p:add_subject_term("recipe/o-rp/epic","m/leg", 0.0225)
        p:add_subject_term("recipe/o-rp/rare","m/leg", 0.00225)
        p:add_subject_term("recipe/o-rp/unc", "m/leg", 0.000225)
        p:add_subject_term("recipe/o-rp/norm","m/leg", 0.000022)
        -- m/epic
        p:add_subject_term("recipe/m-rp/epic","m/epic", -0.2925)
        p:add_subject_term("recipe/m-rp/rare","m/epic", 0.02025)
        p:add_subject_term("recipe/m-rp/unc", "m/epic", 0.002025)
        p:add_subject_term("recipe/m-rp/norm","m/epic", 0.000202)
        p:add_subject_term("recipe/c-rp/epic","m/epic", 0.07875)
        p:add_subject_term("recipe/c-rp/rare","m/epic", 0.010125)
        p:add_subject_term("recipe/c-rp/unc", "m/epic", 0.001012)
        p:add_subject_term("recipe/c-rp/norm","m/epic", 0.000101)
        p:add_subject_term("recipe/o-rp/epic","m/epic", 0.1575)
        p:add_subject_term("recipe/o-rp/rare","m/epic", 0.02025)
        p:add_subject_term("recipe/o-rp/unc", "m/epic", 0.002025)
        p:add_subject_term("recipe/o-rp/norm","m/epic", 0.000202)
        -- c/epic
        p:add_subject_term("recipe/m-rp/epic","c/epic", 0.07875)
        p:add_subject_term("recipe/m-rp/rare","c/epic", 0.010125)
        p:add_subject_term("recipe/m-rp/unc", "c/epic", 0.001012)
        p:add_subject_term("recipe/m-rp/norm","c/epic", 0.000101)
        p:add_subject_term("recipe/c-rp/epic","c/epic", -0.2925)
        p:add_subject_term("recipe/c-rp/rare","c/epic", 0.02025)
        p:add_subject_term("recipe/c-rp/unc", "c/epic", 0.002025)
        p:add_subject_term("recipe/c-rp/norm","c/epic", 0.000202)
        p:add_subject_term("recipe/o-rp/epic","c/epic", 0.1575)
        p:add_subject_term("recipe/o-rp/rare","c/epic", 0.02025)
        p:add_subject_term("recipe/o-rp/unc", "c/epic", 0.002025)
        p:add_subject_term("recipe/o-rp/norm","c/epic", 0.000202)
        -- c/leg
        p:add_subject_term("recipe/m-rp/epic","c/leg", 0.01125)
        p:add_subject_term("recipe/m-rp/rare","c/leg", 0.001125)
        p:add_subject_term("recipe/m-rp/unc", "c/leg", 0.000112)
        p:add_subject_term("recipe/m-rp/norm","c/leg", 0.000011)
        p:add_subject_term("recipe/c-crush",  "c/leg", -0.19)
        p:add_subject_term("recipe/c-rp/epic","c/leg", 0.0225)
        p:add_subject_term("recipe/c-rp/rare","c/leg", 0.00225)
        p:add_subject_term("recipe/c-rp/unc", "c/leg", 0.000225)
        p:add_subject_term("recipe/c-rp/norm","c/leg", 0.000022)
        p:add_subject_term("recipe/o-rp/epic","c/leg", 0.0225)
        p:add_subject_term("recipe/o-rp/rare","c/leg", 0.00225)
        p:add_subject_term("recipe/o-rp/unc", "c/leg", 0.000225)
        p:add_subject_term("recipe/o-rp/norm","c/leg", 0.000022)
        -- o/epic
        p:add_subject_term("recipe/m-rp/epic","o/epic", 0.07875)
        p:add_subject_term("recipe/m-rp/rare","o/epic", 0.010125)
        p:add_subject_term("recipe/m-rp/unc", "o/epic", 0.001012)
        p:add_subject_term("recipe/m-rp/norm","o/epic", 0.000101)
        p:add_subject_term("recipe/c-rp/epic","o/epic", 0.07875)
        p:add_subject_term("recipe/c-rp/rare","o/epic", 0.010125)
        p:add_subject_term("recipe/c-rp/unc", "o/epic", 0.001012)
        p:add_subject_term("recipe/c-rp/norm","o/epic", 0.000101)
        p:add_subject_term("recipe/o-rp/epic","o/epic", -0.585)
        p:add_subject_term("recipe/o-rp/rare","o/epic", 0.0405)
        p:add_subject_term("recipe/o-rp/unc", "o/epic", 0.00405)
        p:add_subject_term("recipe/o-rp/norm","o/epic", 0.000405)
        -- o/leg
        p:add_subject_term("recipe/m-rp/epic","o/leg", 0.01125)
        p:add_subject_term("recipe/m-rp/rare","o/leg", 0.001125)
        p:add_subject_term("recipe/m-rp/unc", "o/leg", 0.000112)
        p:add_subject_term("recipe/m-rp/norm","o/leg", 0.000011)
        p:add_subject_term("recipe/c-rp/epic","o/leg", 0.01125)
        p:add_subject_term("recipe/c-rp/rare","o/leg", 0.001125)
        p:add_subject_term("recipe/c-rp/unc", "o/leg", 0.000112)
        p:add_subject_term("recipe/c-rp/norm","o/leg", 0.000011)
        p:add_subject_term("recipe/o-crush",  "o/leg", -0.19)
        p:add_subject_term("recipe/o-rp/epic","o/leg", 0.045)
        p:add_subject_term("recipe/o-rp/rare","o/leg", 0.0045)
        p:add_subject_term("recipe/o-rp/unc", "o/leg", 0.00045)
        p:add_subject_term("recipe/o-rp/norm","o/leg", 0.000045)
        -- m/rare
        p:add_subject_term("recipe/m-rp/rare","m/rare", -0.2925)
        p:add_subject_term("recipe/m-rp/unc", "m/rare", 0.02025)
        p:add_subject_term("recipe/m-rp/norm","m/rare", 0.002025)
        p:add_subject_term("recipe/c-rp/rare","m/rare", 0.07875)
        p:add_subject_term("recipe/c-rp/unc", "m/rare", 0.010125)
        p:add_subject_term("recipe/c-rp/norm","m/rare", 0.001012)
        p:add_subject_term("recipe/o-rp/rare","m/rare", 0.1575)
        p:add_subject_term("recipe/o-rp/unc", "m/rare", 0.02025)
        p:add_subject_term("recipe/o-rp/norm","m/rare", 0.002025)
        -- c/rare
        p:add_subject_term("recipe/m-rp/rare","c/rare", 0.07875)
        p:add_subject_term("recipe/m-rp/unc", "c/rare", 0.010125)
        p:add_subject_term("recipe/m-rp/norm","c/rare", 0.001012)
        p:add_subject_term("recipe/c-rp/rare","c/rare", -0.2925)
        p:add_subject_term("recipe/c-rp/unc", "c/rare", 0.02025)
        p:add_subject_term("recipe/c-rp/norm","c/rare", 0.002025)
        p:add_subject_term("recipe/o-rp/rare","c/rare", 0.1575)
        p:add_subject_term("recipe/o-rp/unc", "c/rare", 0.02025)
        p:add_subject_term("recipe/o-rp/norm","c/rare", 0.002025)
        -- o/rare
        p:add_subject_term("recipe/m-rp/rare","o/rare", 0.07875)
        p:add_subject_term("recipe/m-rp/unc", "o/rare", 0.010125)
        p:add_subject_term("recipe/m-rp/norm","o/rare", 0.001012)
        p:add_subject_term("recipe/c-rp/rare","o/rare", 0.07875)
        p:add_subject_term("recipe/c-rp/unc", "o/rare", 0.010125)
        p:add_subject_term("recipe/c-rp/norm","o/rare", 0.001012)
        p:add_subject_term("recipe/o-rp/rare","o/rare", -0.585)
        p:add_subject_term("recipe/o-rp/unc", "o/rare", 0.0405)
        p:add_subject_term("recipe/o-rp/norm","o/rare", 0.00405)
        -- m/unc
        p:add_subject_term("recipe/m-rp/unc", "m/unc", -0.2925)
        p:add_subject_term("recipe/m-rp/norm","m/unc", 0.02025)
        p:add_subject_term("recipe/c-rp/unc", "m/unc", 0.07875)
        p:add_subject_term("recipe/c-rp/norm","m/unc", 0.010125)
        p:add_subject_term("recipe/o-rp/unc", "m/unc", 0.1575)
        p:add_subject_term("recipe/o-rp/norm","m/unc", 0.02025)
        -- c/unc
        p:add_subject_term("recipe/m-rp/unc", "c/unc", 0.07875)
        p:add_subject_term("recipe/m-rp/norm","c/unc", 0.010125)
        p:add_subject_term("recipe/c-rp/unc", "c/unc", -0.2925)
        p:add_subject_term("recipe/c-rp/norm","c/unc", 0.02025)
        p:add_subject_term("recipe/o-rp/unc", "c/unc", 0.1575)
        p:add_subject_term("recipe/o-rp/norm","c/unc", 0.02025)
        -- o/unc
        p:add_subject_term("recipe/m-rp/unc", "o/unc", 0.07875)
        p:add_subject_term("recipe/m-rp/norm","o/unc", 0.010125)
        p:add_subject_term("recipe/c-rp/unc", "o/unc", 0.07875)
        p:add_subject_term("recipe/c-rp/norm","o/unc", 0.010125)
        p:add_subject_term("recipe/o-rp/unc", "o/unc", -0.585)
        p:add_subject_term("recipe/o-rp/norm","o/unc", 0.0405)
        -- m/norm
        p:add_subject_term("recipe/m-rp/norm","m/norm", -0.2925)
        p:add_subject_term("recipe/c-rp/norm","m/norm", 0.07875)
        p:add_subject_term("recipe/o-rp/norm","m/norm", 0.1575)
        -- c/norm
        p:add_subject_term("recipe/m-rp/norm","c/norm", 0.07875)
        p:add_subject_term("recipe/c-rp/norm","c/norm", -0.2925)
        p:add_subject_term("recipe/o-rp/norm","c/norm", 0.1575)
        -- o/norm
        p:add_subject_term("recipe/m-rp/norm","o/norm", 0.07875)
        p:add_subject_term("recipe/c-rp/norm","o/norm", 0.07875)
        p:add_subject_term("recipe/o-rp/norm","o/norm", -0.585)

        -- Ore rows: crush produces ore, final_sink drains it.
        p:add_subject_term("recipe/m-crush", "iron",   2.0)
        p:add_subject_term("|final_sink|iron", "iron", -1)
        p:add_subject_term("recipe/m-crush", "copper", 0.8)
        p:add_subject_term("|final_sink|copper", "copper", -1)
        p:add_subject_term("recipe/c-crush", "carbon", 1.0)
        p:add_subject_term("|final_sink|carbon", "carbon", -1)
        p:add_subject_term("recipe/c-crush", "sulfur", 0.4)
        p:add_subject_term("|final_sink|sulfur", "sulfur", -1)
        p:add_subject_term("recipe/o-crush", "ice",    0.6)
        p:add_subject_term("|final_sink|ice", "ice", -1)
        p:add_subject_term("recipe/o-crush", "calcite", 0.4)
        p:add_subject_term("|final_sink|calcite", "calcite", -1)

        -- Crush limit rows: recipe + slack = 1.
        p:add_subject_term("recipe/m-crush", "|limit|m-crush", 1)
        p:add_subject_term("%positive_slack%|limit|m-crush", "|limit|m-crush", 1)
        p:add_subject_term("recipe/c-crush", "|limit|c-crush", 1)
        p:add_subject_term("%positive_slack%|limit|c-crush", "|limit|c-crush", 1)
        p:add_subject_term("recipe/o-crush", "|limit|o-crush", 1)
        p:add_subject_term("%positive_slack%|limit|o-crush", "|limit|o-crush", 1)

        local state, vars, steps = harness.solve_to_completion(lp, p,
            { tolerance = 1e-6, iterate_limit = 400 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "packed variables returned")
        harness.assert_true(steps < 150, "converged in under 150 iterations (took " .. steps .. ")")

        -- The three crush recipes are pinned at 1; their slacks idle.
        for _, c in ipairs({ "m-crush", "c-crush", "o-crush" }) do
            harness.assert_near(vars.x["recipe/" .. c], 1, 1e-4, c .. " pinned at 1")
            harness.assert_near(vars.x["%positive_slack%|limit|" .. c], 0, 1e-3, c .. " slack idle")
        end

        -- Every reprocessing recipe stays idle: the cascade can't bootstrap.
        for _, r in ipairs({
            "recipe/m-rp/epic", "recipe/m-rp/rare", "recipe/m-rp/unc", "recipe/m-rp/norm",
            "recipe/c-rp/epic", "recipe/c-rp/rare", "recipe/c-rp/unc", "recipe/c-rp/norm",
            "recipe/o-rp/epic", "recipe/o-rp/rare", "recipe/o-rp/unc", "recipe/o-rp/norm",
        }) do
            harness.assert_near(vars.x[r], 0, 1e-3, r .. " idle (no chunk source to feed the cascade)")
        end

        -- Shortage fires ONLY on the three legendary chunks the crushes
        -- demand, at exactly 0.19 each.
        harness.assert_near(vars.x["|shortage_source|m/leg"], 0.19, 1e-3, "metallic legendary shortage")
        harness.assert_near(vars.x["|shortage_source|c/leg"], 0.19, 1e-3, "carbonic legendary shortage")
        harness.assert_near(vars.x["|shortage_source|o/leg"], 0.19, 1e-3, "oxide legendary shortage")

        -- Every other chunk's shortage and ALL surplus sinks stay at zero:
        -- the signal is localized, not diffuse.
        for _, ch in ipairs(chunks) do
            harness.assert_near(vars.x["|surplus_sink|" .. ch], 0, 1e-3, "surplus|" .. ch .. " idle")
            if ch ~= "m/leg" and ch ~= "c/leg" and ch ~= "o/leg" then
                harness.assert_near(vars.x["|shortage_source|" .. ch], 0, 1e-3,
                    "shortage|" .. ch .. " idle (only the demanded legendary tier should fire)")
            end
        end

        -- Ores still come out at the crush yields (the usable part of the
        -- answer the user gets despite the missing source).
        harness.assert_near(vars.x["|final_sink|iron"],   2.0, 1e-3, "iron-ore output")
        harness.assert_near(vars.x["|final_sink|copper"], 0.8, 1e-3, "copper-ore output")
        harness.assert_near(vars.x["|final_sink|carbon"], 1.0, 1e-3, "carbon output")
        harness.assert_near(vars.x["|final_sink|sulfur"], 0.4, 1e-3, "sulfur output")
        harness.assert_near(vars.x["|final_sink|ice"],    0.6, 1e-3, "ice output")
        harness.assert_near(vars.x["|final_sink|calcite"],0.4, 1e-3, "calcite output")
    end,
})

return cases
