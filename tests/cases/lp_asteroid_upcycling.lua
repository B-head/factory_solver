-- Space Age asteroid quality upcycling. This file holds two cases that
-- together establish what actually happens (an earlier "false negative in
-- find_deficit_materials" reading of this case was WRONG -- corrected below
-- after driving create_problem on the reconstructed recipes).
--
-- The cascade: three advanced-*-asteroid-crushing/legendary recipes consume
-- 0.19 of their legendary chunk and emit legendary ores. Twelve
-- *-asteroid-reprocessing recipes (normal/uncommon/rare/epic x three types)
-- form a 5-tier x 3-type quality cascade -- each reprocess consumes one chunk
-- and emits small probabilistic amounts of higher-quality chunks of the same
-- type plus same-tier chunks of the other two types. Mass leaks upward, so
-- the cascade needs an external base chunk supply to run.
--
-- EMPIRICAL finding (2026-05-28): driving create_problem on these recipes in
-- isolation, find_deficit_materials DOES flag oxide-asteroid-chunk/normal
-- (oxide reprocessing consumes 0.585 vs 0.2925 for metallic/carbonic, so o/
-- norm's unit-rate net is -73%, over the 50% threshold; m/norm and c/norm are
-- only -19% and stay unflagged). That single |basic_source|o/norm is enough:
-- oxide reprocessing cross-produces metallic and carbonic chunks too, so the
-- LP bootstraps the WHOLE cascade from oxide normal chunks and the upcycle
-- runs to completion with zero shortage. See the second case below.
--
-- So why did the in-game trace show shortage on legendary and an idle
-- cascade? Because in the full factory find_deficit ran over ALL lines and
-- o/norm came back `pre_reachable` (some other line produces it), so the
-- `deficits MINUS pre_reachable` filter in create_problem dropped it -- yet
-- that producing line was not in THIS solve's active set, leaving the active
-- LP with no chunk source. That is a reachability-vs-active-lines context
-- mismatch, separate from the deficit heuristic, and not reproducible without
-- the full-factory state. The first case below pins that captured in-game
-- matrix (no chunk source -> shortage) as a numerical-robustness + behaviour
-- snapshot; it is NOT a statement that the cascade "should" fail.
--
-- Variable names in the first (pg.new) case are shortened; mapping:
--   recipe/{m,c,o}-crush       = advanced-{metallic,carbonic,oxide}-asteroid-crushing/legendary
--   recipe/{m,c,o}-rp/<tier>    = {metallic,carbonic,oxide}-asteroid-reprocessing/<tier>
--   {m,c,o}/<tier>             = {metallic,carbonic,oxide}-asteroid-chunk/<tier>

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local pg = require "solver/problem_generator"
local cp = require "solver/create_problem"

-- Helpers for the create_problem-driven case.
local function ci(name, q, amt)
    return { type = "item", name = name, quality = q, amount_per_second = amt }
end
local function cl(rname, q, products, ingredients)
    return {
        recipe_typed_name = { type = "recipe", name = rname, quality = q },
        products = products, ingredients = ingredients,
        power_per_second = 0, pollution_per_second = 0,
    }
end

local cases = {}

table.insert(cases, {
    name = "asteroid upcycling, in-game matrix snapshot: no chunk source so cascade idles and shortage fires on legendary (54x24 numerical robustness)",
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

table.insert(cases, {
    name = "asteroid upcycle, isolated cascade via create_problem: find_deficit flags o/norm and the whole upcycle runs",
    -- The empirical counterpart to the snapshot above: the SAME cascade fed
    -- through create_problem from recipe fixtures. find_deficit_materials
    -- flags only oxide-asteroid-chunk/normal (-73% at unit rate), which gets
    -- a |basic_source|. Oxide reprocessing cross-produces metallic/carbonic
    -- chunks, so that single base supply bootstraps the entire cascade: all
    -- 12 reprocessing recipes run, every tier upcycles, the three crushers
    -- hit their pinned rate, and NO shortage_source fires.
    --
    -- This is the "upcycle works" regression: it pins that the deficit /
    -- reachability / shortage gating in create_problem produces a usable
    -- upcycle on the isolated cascade. It is the control proving the in-game
    -- shortage was a full-factory reachability artifact, not a property of
    -- the cascade itself. NOTE: if the planned find_deficit_materials
    -- feasibility fix changes which chunk(s) get the base supply, the exact
    -- per-recipe rates below may shift -- the load-bearing assertions are
    -- "crushers pinned, all reprocessing > 0, no shortage", which any
    -- correct supply choice must satisfy.
    run = function()
        local m = function(q, amt) return ci("metallic-asteroid-chunk", q, amt) end
        local c = function(q, amt) return ci("carbonic-asteroid-chunk", q, amt) end
        local o = function(q, amt) return ci("oxide-asteroid-chunk", q, amt) end

        local lines = {
            cl("advanced-metallic-asteroid-crushing", "legendary",
                { ci("iron-ore","legendary",2.0), ci("copper-ore","legendary",0.8) },
                { m("legendary",0.19) }),
            cl("advanced-carbonic-asteroid-crushing", "legendary",
                { ci("carbon","legendary",1.0), ci("sulfur","legendary",0.4) },
                { c("legendary",0.19) }),
            cl("advanced-oxide-asteroid-crushing", "legendary",
                { ci("ice","legendary",0.6), ci("calcite","legendary",0.4) },
                { o("legendary",0.19) }),
            cl("metallic-asteroid-reprocessing","epic",
                { m("legendary",0.0225), c("epic",0.07875), c("legendary",0.01125), o("epic",0.07875), o("legendary",0.01125) },
                { m("epic",0.2925) }),
            cl("metallic-asteroid-reprocessing","rare",
                { m("legendary",0.00225), m("epic",0.02025), c("epic",0.010125), c("legendary",0.001125), c("rare",0.07875), o("epic",0.010125), o("legendary",0.001125), o("rare",0.07875) },
                { m("rare",0.2925) }),
            cl("metallic-asteroid-reprocessing","uncommon",
                { m("legendary",0.000225), m("epic",0.002025), m("rare",0.02025), c("epic",0.001012), c("legendary",0.000112), c("rare",0.010125), c("uncommon",0.07875), o("epic",0.001012), o("legendary",0.000112), o("rare",0.010125), o("uncommon",0.07875) },
                { m("uncommon",0.2925) }),
            cl("metallic-asteroid-reprocessing","normal",
                { m("legendary",0.000022), m("epic",0.000202), m("rare",0.002025), m("uncommon",0.02025), c("epic",0.000101), c("legendary",0.000011), c("rare",0.001012), c("uncommon",0.010125), c("normal",0.07875), o("epic",0.000101), o("legendary",0.000011), o("rare",0.001012), o("uncommon",0.010125), o("normal",0.07875) },
                { m("normal",0.2925) }),
            cl("carbonic-asteroid-reprocessing","epic",
                { m("legendary",0.01125), m("epic",0.07875), c("legendary",0.0225), o("epic",0.07875), o("legendary",0.01125) },
                { c("epic",0.2925) }),
            cl("carbonic-asteroid-reprocessing","rare",
                { m("legendary",0.001125), m("epic",0.010125), m("rare",0.07875), c("legendary",0.00225), c("epic",0.02025), o("epic",0.010125), o("legendary",0.001125), o("rare",0.07875) },
                { c("rare",0.2925) }),
            cl("carbonic-asteroid-reprocessing","uncommon",
                { m("legendary",0.000112), m("epic",0.001012), m("rare",0.010125), m("uncommon",0.07875), c("epic",0.002025), c("legendary",0.000225), c("rare",0.02025), o("epic",0.001012), o("legendary",0.000112), o("rare",0.010125), o("uncommon",0.07875) },
                { c("uncommon",0.2925) }),
            cl("carbonic-asteroid-reprocessing","normal",
                { m("legendary",0.000011), m("epic",0.000101), m("rare",0.001012), m("uncommon",0.010125), m("normal",0.07875), c("epic",0.000202), c("legendary",0.000022), c("rare",0.002025), c("uncommon",0.02025), o("epic",0.000101), o("legendary",0.000011), o("rare",0.001012), o("uncommon",0.010125), o("normal",0.07875) },
                { c("normal",0.2925) }),
            cl("oxide-asteroid-reprocessing","epic",
                { m("legendary",0.0225), m("epic",0.1575), c("legendary",0.0225), c("epic",0.1575), o("legendary",0.045) },
                { o("epic",0.585) }),
            cl("oxide-asteroid-reprocessing","rare",
                { m("legendary",0.00225), m("epic",0.02025), m("rare",0.1575), c("legendary",0.00225), c("epic",0.02025), c("rare",0.1575), o("legendary",0.0045), o("epic",0.0405) },
                { o("rare",0.585) }),
            cl("oxide-asteroid-reprocessing","uncommon",
                { m("legendary",0.000225), m("epic",0.002025), m("rare",0.02025), m("uncommon",0.1575), c("legendary",0.000225), c("epic",0.002025), c("rare",0.02025), c("uncommon",0.1575), o("legendary",0.00045), o("epic",0.00405), o("rare",0.0405) },
                { o("uncommon",0.585) }),
            cl("oxide-asteroid-reprocessing","normal",
                { m("legendary",0.000022), m("epic",0.000202), m("rare",0.002025), m("uncommon",0.02025), m("normal",0.1575), c("legendary",0.000022), c("epic",0.000202), c("rare",0.002025), c("uncommon",0.02025), c("normal",0.1575), o("legendary",0.000045), o("epic",0.000405), o("rare",0.00405), o("uncommon",0.0405) },
                { o("normal",0.585) }),
        }
        local constraints = {
            { type = "recipe", name = "advanced-metallic-asteroid-crushing", quality = "legendary",
              limit_type = "equal", limit_amount_per_second = 1 },
            { type = "recipe", name = "advanced-carbonic-asteroid-crushing", quality = "legendary",
              limit_type = "equal", limit_amount_per_second = 1 },
            { type = "recipe", name = "advanced-oxide-asteroid-crushing", quality = "legendary",
              limit_type = "equal", limit_amount_per_second = 1 },
        }

        local problem = cp.create_problem("asteroid-upcycle-isolated", constraints, lines)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })

        harness.assert_eq(state, "finished", "solver_state")
        assert(vars, "expected packed variables on finished state")

        -- Crushers pinned at the requested rate.
        harness.assert_near(vars.x["recipe/advanced-metallic-asteroid-crushing/legendary"], 1, 1e-3, "metallic crush pinned")
        harness.assert_near(vars.x["recipe/advanced-carbonic-asteroid-crushing/legendary"], 1, 1e-3, "carbonic crush pinned")
        harness.assert_near(vars.x["recipe/advanced-oxide-asteroid-crushing/legendary"],    1, 1e-3, "oxide crush pinned")

        -- The whole cascade runs: every reprocessing recipe is active.
        for _, r in ipairs({
            "metallic-asteroid-reprocessing", "carbonic-asteroid-reprocessing", "oxide-asteroid-reprocessing",
        }) do
            for _, q in ipairs({ "normal", "uncommon", "rare", "epic" }) do
                local key = "recipe/" .. r .. "/" .. q
                harness.assert_true((vars.x[key] or 0) > 0.1,
                    key .. " must run (upcycle active, got " .. tostring(vars.x[key]) .. ")")
            end
        end

        -- A base chunk supply bootstraps the cascade (today: o/norm).
        harness.assert_true((vars.x["|basic_source|item/oxide-asteroid-chunk/normal"] or 0) > 0.1,
            "a base chunk |basic_source| is active to seed the cascade")

        -- Crucially: NO shortage anywhere. The upcycle is fully supplied by
        -- the recipe chain off the base chunk(s).
        for _, t in ipairs({ "metallic", "carbonic", "oxide" }) do
            for _, q in ipairs({ "normal", "uncommon", "rare", "epic", "legendary" }) do
                local key = "|shortage_source|item/" .. t .. "-asteroid-chunk/" .. q
                harness.assert_near(vars.x[key] or 0, 0, 1e-3, key .. " idle (no shortage; cascade supplies itself)")
            end
        end
    end,
})

return cases
