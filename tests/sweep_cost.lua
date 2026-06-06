---@diagnostic disable: undefined-global
-- (io/os/arg are stdlib globals; LuaLS is configured for the Factorio sandbox
--  where they are stripped, but this file only runs in a standalone Lua host.)

-- Cost-sweep analysis driver. Takes ONE explorer-dumped problem (the same
-- { meta, constraints, normalized_lines } file tests/solve_problem.lua reads),
-- and lets you change the objective cost of INDIVIDUAL LP variables -- not whole
-- variable classes -- then re-solve and see how the solution moves. This is the
-- "take a failing formalized problem, perturb one cost term, watch the result"
-- loop, run entirely headless (no Factorio).
--
-- Per-variable, not per-tier: create_problem bakes a `cost` into every primal of
-- problem.primals (penalty escapes |shortage_source|/|elastic|, declared imports
-- |initial_source|, recipe flows, constraint slacks ...). This driver mutates
-- those `.cost` fields directly on the BUILT problem, so a single key -- e.g.
-- "|shortage_source|fluid/tuuphra-paste/normal" -- can be repriced on its own
-- while every other term keeps its create_problem default. The shipped solver is
-- untouched: all overrides live on the in-memory Problem this process builds.
--
-- Two modes:
--
--   INSPECT (no pattern):
--     lua tests/sweep_cost.lua <problem-file>
--   Solves the baseline once and lists the cost-bearing variables worth tweaking
--   (every penalty escape, every source/target-priced term, plus whatever the
--   solution actually leaned on), each with its current cost and solved value.
--   Use this first to discover the exact key to pass to a sweep.
--
--   SWEEP (pattern + values):
--     lua tests/sweep_cost.lua <problem-file> <key-substring> <v1,v2,v3,...>
--   The special pattern `@cheat` auto-resolves to the single highest-|value|
--   active penalty escape (|shortage_source|/|elastic|) in the baseline solve --
--   the material the LP leaned on hardest -- so a batch can sweep the dominant
--   cheat without first parsing inspect output for its exact key.
--   Prints the baseline (row "base"), then for each comma-separated cost value
--   re-solves with the `.cost` of EVERY primal whose key contains <key-substring>
--   set to that absolute value, and emits one CSV row of the detect() practicality
--   metrics. The matched keys (and their baseline costs) are printed once up top so
--   you can confirm the pattern hit what you meant -- widen or narrow it as needed.
--
--   ABLATE (leave-one-out cost zeroing):
--     lua tests/sweep_cost.lua <problem-file> --ablate [<key-substring>]
--   For every primal whose baseline cost is nonzero (optionally restricted to keys
--   containing <key-substring>), re-solves with JUST that one variable's cost set
--   to 0 and prints one row per variable: base_cost, resulting cheat, dcheat vs
--   baseline, active recipes, dactive, and the recipe-flow scale (Rsum = total
--   flow over real recipes, Rratio = Rsum / baseline Rsum, Rmax = largest single
--   recipe). Rows are sorted by |dcheat| so the single cost terms a failing case
--   hinges on surface first. The Rsum/Rratio columns exist to break the "cheat
--   down = improvement" assumption: a reducer that also blows Rratio up 100x has
--   not found a better factory, just a hugely-upscaled degenerate one. This is the
--   data-collection mode for "what causes the cheat in THIS problem" -- per case.
--
--   MEASURE (research dump -- wide neutral TSV):
--     lua tests/sweep_cost.lua <problem-file> --measure [<key-substring>]
--   Same leave-one-out cost zeroing as --ablate, but emits a tab-separated table
--   with NO judgment: per solution (a "(base)" row then one row per zeroed
--   variable) it reports every measurable quantity -- total mass and active-count
--   for each boundary class (shortage/surplus/initial/final/elastic/slack), recipe
--   stats (Rsum/Rmax/n_recipe/n_recipe_active), and the pinned-recipe value (NA for
--   material targets). Nothing is combined into a "cheat" or labelled good/bad. The
--   human "# ..." / "base ..." preamble lines carry no tabs, so isolate the table
--   with `awk -F'\t' 'NF>1'` and drop repeated `file` headers when concatenating.
--
-- Set SWEEP_VARS=1 in the environment to additionally dump, per solved row, the
-- non-parked variable vector (sorted) -- for diffing exactly which flows moved.
-- (SWEEP_VARS has no effect in --ablate/--measure modes -- one row per variable.)
--
-- Usage (from the repo root so require paths resolve):
--   lua tests/sweep_cost.lua <problem-file> [<key-substring> <v1,v2,...>]

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local linear_programming = require "solver/linear_programming"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"

local DUMP_VARS = os.getenv("SWEEP_VARS") == "1"

local function die(msg, code)
    io.stderr:write(msg .. "\n")
    os.exit(code or 2)
end

-- ---- shard flags ------------------------------------------------------------
-- Two flags orthogonal to the positional `<file> <mode> [<filter>]` grammar keep
-- this worker a pure single-shot box the shell can fan out (tests/sweep_fanout.sh):
--   --list-units    print how many leave-one-out targets this file has, then exit
--                   (the shell uses the count to carve index ranges); no solving.
--   --units <m-n>   process only sorted-target indices m..n (1-based, inclusive).
--                   `m-` is open-ended; a bare `m` is the single index m.
-- A heavy problem whose --ablate/--measure takes minutes is thus split into
-- (file, range) work items that run on separate cores instead of pinning one.
-- Both flags are stripped from `arg` here so the positional parse below is intact.
local list_units = false
local unit_lo, unit_hi = 1, math.huge ---@type number, number
do
    local positional = {}
    local i = 1
    while arg[i] ~= nil do
        local a = arg[i]
        local range = nil
        if a == "--list-units" then
            list_units = true
        elseif a == "--units" then
            i = i + 1
            range = arg[i]
        elseif a:sub(1, 8) == "--units=" then
            range = a:sub(9)
        else
            positional[#positional + 1] = a
        end
        if range then
            local lo, hi = range:match("^(%d+)%-(%d+)$")
            if lo then
                unit_lo, unit_hi = tonumber(lo) or 1, tonumber(hi) or math.huge
            elseif range:match("^%d+%-$") then
                unit_lo, unit_hi = tonumber(range:match("^(%d+)%-$")) or 1, math.huge
            elseif range:match("^%d+$") then
                unit_lo = tonumber(range) or 1; unit_hi = unit_lo
            else
                die("bad --units range '" .. tostring(range) .. "' (expected m-n, m-, or m)")
            end
        end
        i = i + 1
    end
    local n0 = #arg
    for k = 1, n0 do arg[k] = positional[k] end -- nil-fills the tail = clean positional argv
end

-- ---- args -------------------------------------------------------------------
local path = arg[1]
if not path then
    die("usage: lua tests/sweep_cost.lua <problem-file> [<key-substring> <v1,v2,...>]")
end
local pattern = arg[2] -- nil => inspect mode
-- For --ablate / --measure, arg[3] is an optional key-substring FILTER, not a
-- numeric value list, so the CSV-of-numbers parse below must not run for them.
local mode_flag = pattern == "--ablate" or pattern == "--measure"
local values = {}
if arg[3] and not mode_flag then
    for tok in string.gmatch(arg[3], "[^,]+") do
        local n = tonumber(tok)
        if not n then die("bad cost value '" .. tok .. "' (must be a number)") end
        values[#values + 1] = n
    end
    if #values == 0 then die("no cost values parsed from '" .. tostring(arg[3]) .. "'") end
end

-- ---- load the dumped problem ------------------------------------------------
-- Shared loader (problem_dump) with tests/solve_problem.lua; the die() wording
-- and exit code 1 are this driver's own.
local prob, kind, detail = problem_dump.load_problem(path)
if not prob then
    if kind == "load" then
        die("load " .. path .. ": " .. tostring(detail), 1)
    else
        die("malformed problem file: " .. path, 1)
    end
end
prob = assert(prob) -- die() above exits on nil; narrows prob for the closures below
local meta = prob.meta

-- ---- helpers ----------------------------------------------------------------

-- RECIPE_EPS (env): when set, add this tiny per-unit cost to every user-facing
-- recipe flow variable (recipe/ and non-bridge virtual_recipe/, EXCLUDING |bridge|
-- temperature plumbing). It is the experimental "penalise pointless production"
-- tie-break: a net-zero futile cycle (e.g. barrel-fill ↔ barrel-empty) has zero
-- objective benefit, so any eps>0 makes running it strictly costly and the LP
-- drops it to 0 -- testing whether a recipe cost collapses degenerate loops
-- WITHOUT distorting solutions that ship real output. Kept additive so <source>
-- recipes keep their source_cost + eps.
local RECIPE_EPS = tonumber(os.getenv("RECIPE_EPS"))

-- Build a fresh Problem from the dump. Rebuilt per solve so each cost variant
-- starts from create_problem's defaults rather than inheriting a prior override.
local function build_problem()
    local ok, problem = pcall(create_problem.create_problem, "sweep",
        prob.constraints, prob.normalized_lines)
    if not ok then die("create_problem raised: " .. tostring(problem), 1) end
    if RECIPE_EPS then
        for key, term in pairs(problem.primals) do
            if ed.is_recipe(key) then
                term.cost = term.cost + RECIPE_EPS
            end
        end
    end
    return problem
end

-- Set the cost of every primal whose key contains `substr` to `cost` (absolute).
-- Returns the matched keys with their previous costs, so the caller can show what
-- moved. Plain (non-pattern) substring match -- LP keys carry |...| and /, which
-- would otherwise be Lua-pattern metacharacters.
local function override_cost(problem, substr, cost)
    local matched = {}
    for key, term in pairs(problem.primals) do
        if string.find(key, substr, 1, true) then
            matched[#matched + 1] = { key = key, was = term.cost }
            term.cost = cost
        end
    end
    table.sort(matched, function(a, b) return a.key < b.key end)
    return matched
end

-- Drive the IPM exactly as tests/solve_problem.lua does (shared via problem_dump):
-- solve() advances one step per call, "ready" -> "calculating" -> terminal. The
-- die() wording on a raised solve is this driver's own.
local function solve(problem)
    local state, steps, vars, err = problem_dump.solve_dumped(linear_programming, problem, meta)
    if err then die("solve raised: " .. err, 1) end
    return state, steps, vars
end

-- One detect() result -> compact, machine-readable field set.
local function row_fields(state, steps, d)
    return string.format(
        "state=%s steps=%d cheat=%.4g active=%d recipes=%d ship=%s/%s noship=%s degen=%s",
        tostring(state), steps, d.cheat, d.active, d.recipes,
        d.has_initial and "i" or "-", d.has_final and "f" or "-",
        tostring(d.noship), tostring(d.degenerate))
end

-- Dump the non-parked variable vector (sorted) for diffing across solves. Uses
-- the same park threshold detect() uses so the two stay consistent.
local function dump_vars(vars, primals)
    if not vars or not vars.x then return end
    local thresh = ed.park_threshold(vars, primals)
    local keys = {}
    for k, v in pairs(vars.x) do
        if math.abs(v) >= thresh then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        print(string.format("    %-60s %.6g", k, vars.x[k]))
    end
end

-- Recipe-flow scale of a solved vars set: how much real production the solution
-- actually runs. sum = total flow over real recipes (recipe/ + virtual_recipe/,
-- excluding |bridge| plumbing), max = the single largest recipe value. These let
-- a reader test whether a cheat DROP is a genuine improvement or just a jump to a
-- hugely-upscaled solution -- "cheat down" and "recipe flow exploded 100x" can be
-- the same row. Mirrors detect()'s is_recipe filter so counts stay consistent.
local function recipe_stats(vars, primals)
    local sum, max = 0, 0
    if vars and vars.x then
        for k, v in pairs(vars.x) do
            if ed.is_recipe(k, primals) then
                local a = math.abs(v)
                sum = sum + a
                if a > max then max = a end
            end
        end
    end
    return sum, max
end

-- Full neutral measurement of a solved vars set: total |mass| and active-count
-- (value above the park threshold) per boundary class, plus recipe-flow stats.
-- Deliberately makes NO judgment -- it does not combine shortage+elastic into a
-- "cheat" or call any class good/bad. It just reports every quantity so the
-- caller can decide later which, if any, mean something. Park threshold is the
-- same recipe-relative floor detect() uses, so "active" counts stay consistent.
local function measure(vars, primals)
    local m = {
        shortage = 0, surplus = 0, initial = 0, final = 0, elastic = 0, slack = 0,
        n_shortage = 0, n_surplus = 0, n_initial = 0, n_final = 0, n_elastic = 0,
        rsum = 0, rmax = 0, n_recipe = 0, n_recipe_active = 0,
    }
    if not (vars and vars.x) then return m end
    local th = ed.park_threshold(vars, primals)
    for k, v in pairs(vars.x) do
        local a = math.abs(v)
        if k:find("|shortage_source|", 1, true) then
            m.shortage = m.shortage + a; if a > th then m.n_shortage = m.n_shortage + 1 end
        elseif k:find("|surplus_sink|", 1, true) then
            m.surplus = m.surplus + a; if a > th then m.n_surplus = m.n_surplus + 1 end
        elseif k:find("|initial_source|", 1, true) then
            m.initial = m.initial + a; if a > th then m.n_initial = m.n_initial + 1 end
        elseif k:find("|final_sink|", 1, true) then
            m.final = m.final + a; if a > th then m.n_final = m.n_final + 1 end
        elseif k:find("|elastic|", 1, true) then
            m.elastic = m.elastic + a; if a > th then m.n_elastic = m.n_elastic + 1 end
        elseif k:find("slack%", 1, true) then
            m.slack = m.slack + a
        elseif ed.is_recipe(k, primals) then
            m.rsum = m.rsum + a; if a > m.rmax then m.rmax = a end
            m.n_recipe = m.n_recipe + 1
            if a > th then m.n_recipe_active = m.n_recipe_active + 1 end
        end
    end
    return m
end

-- Variable keys of any recipe-typed constraints (the "placed" recipes the user
-- pinned). Material targets (netneg/trapdown on an item/fluid) yield none, so the
-- pinned-recipe column is NA for those -- itself a fact worth seeing in the dump.
local pinned_recipe_keys = {}
for _, c in ipairs(prob.constraints or {}) do
    if c.type == "recipe" then
        pinned_recipe_keys[#pinned_recipe_keys + 1] =
            "recipe/" .. c.name .. "/" .. (c.quality or "normal")
    end
end
local function pinned_recipe_value(vars)
    if #pinned_recipe_keys == 0 then return nil end -- NA: material target
    local total = 0
    for _, k in ipairs(pinned_recipe_keys) do
        total = total + ((vars and vars.x and vars.x[k]) or 0)
    end
    return total
end

-- ---- baseline ---------------------------------------------------------------
local base_problem = build_problem()

-- The leave-one-out targets (nonzero-cost primals, optional filter) in a STABLE
-- sorted-by-key order, so a --units index range means the same thing in the
-- --list-units planning pass and in every sharded run of the same file.
local function collect_targets(filter)
    local targets = {}
    for key, term in pairs(base_problem.primals) do
        if term.cost ~= 0 and (not filter or string.find(key, filter, 1, true)) then
            targets[#targets + 1] = { key = key, cost = term.cost }
        end
    end
    table.sort(targets, function(a, b) return a.key < b.key end)
    return targets
end

-- --list-units: report the target count and exit WITHOUT solving -- the shell
-- carves (file, index-range) work items from it. Filter (arg[3]) honours the same
-- substring the --ablate/--measure modes accept, so the count matches what they
-- would process.
if list_units then
    print(#collect_targets(arg[3]))
    os.exit(0)
end

-- On a sharded run (--units with lo>1) the human preamble and the baseline row
-- are suppressed so concatenated shard output stays clean; the baseline SOLVE
-- still runs (every shard needs b_detect/b_vars for --ablate's dcheat and for the
-- --measure (base) row when it owns index 1). Non-sharded runs have lo==1, so
-- their output is unchanged.
if unit_lo == 1 then
    print("# problem: " .. path)
    print("# seed=" .. tostring(meta.seed) .. " sr=" .. tostring(meta.seed_recipe)
        .. " tgt=" .. tostring(meta.target_label))
end

local b_state, b_steps, b_vars = solve(base_problem)
local b_detect = ed.detect(b_vars, base_problem.primals)
local b_rsum, b_rmax = recipe_stats(b_vars, base_problem.primals)
if unit_lo == 1 then
    print("base " .. row_fields(b_state, b_steps, b_detect)
        .. string.format(" Rsum=%.4g Rmax=%.4g", b_rsum, b_rmax))
end
if DUMP_VARS then dump_vars(b_vars, base_problem.primals) end

-- ABLATE: leave-one-out cost zeroing. For every primal whose baseline cost is
-- nonzero (optionally restricted to keys containing the filter substring),
-- rebuild the problem with JUST that one variable's cost set to 0, re-solve, and
-- report how cheat/activity moved vs baseline. This is the per-variable
-- sensitivity map: it surfaces which single cost term each failing case actually
-- hinges on, without assuming the cheated location is the load-bearing one.
-- Rows are sorted by |dcheat| so the terms that matter float to the top.
if pattern == "--ablate" then
    local filter = arg[3] -- optional substring; nil => every nonzero-cost var
    local targets = collect_targets(filter)
    -- Preamble only on the first shard (lo==1) -- a sharded run concatenates many
    -- of these and only wants it once.
    if unit_lo == 1 then
        print(string.format("# ablate: %d nonzero-cost variable(s)%s; base cheat=%.4g active=%d",
            #targets, filter and (" matching '" .. filter .. "'") or "",
            b_detect.cheat, b_detect.active))
    end
    local rows = {}
    for idx = unit_lo, math.min(#targets, unit_hi) do
        local t = targets[idx]
        local problem = build_problem()
        local term = problem.primals[t.key]
        if term then term.cost = 0 end
        local state, steps, vars = solve(problem)
        local d = ed.detect(vars, problem.primals)
        local rsum, rmax = recipe_stats(vars, problem.primals)
        rows[#rows + 1] = {
            key = t.key, cost = t.cost, cheat = d.cheat,
            dcheat = d.cheat - b_detect.cheat, active = d.active, state = state,
            rsum = rsum, rmax = rmax,
            -- Recipe-flow ratio vs baseline: >1 the solution upscaled real
            -- production, <1 it shrank. The whole point of recording this is so a
            -- cheat drop can be checked against "did flow explode" -- a reducer
            -- that 100x's Rratio is not obviously an improvement.
            rratio = (b_rsum > 0) and (rsum / b_rsum) or 0,
            dactive = d.active - b_detect.active,
        }
    end
    table.sort(rows, function(a, b)
        local ma, mb = math.abs(a.dcheat), math.abs(b.dcheat)
        if ma ~= mb then return ma > mb end
        return a.key < b.key
    end)
    for _, r in ipairs(rows) do
        print(string.format(
            "ablate0 %-56s base_cost=%-10.4g cheat=%-10.4g dcheat=%+.4g active=%d dactive=%+d Rsum=%.4g Rratio=%.3g Rmax=%.4g state=%s",
            r.key, r.cost, r.cheat, r.dcheat, r.active, r.dactive,
            r.rsum, r.rratio, r.rmax, r.state))
    end
    os.exit(0)
end

-- MEASURE: the research dump. Same leave-one-out cost zeroing as --ablate, but
-- instead of a judged "cheat/dcheat" view it emits a WIDE, neutral TSV -- every
-- measurable quantity per solution (all class masses + active counts, recipe
-- stats, pinned-recipe value), no combination, no verdict. One header, then a
-- "(base)" row, then one row per nonzero-cost variable zeroed. Pipe many files'
-- output together (drop repeated headers) to get the full corpus dataset.
if pattern == "--measure" then
    local filter = arg[3] -- optional substring; nil => every nonzero-cost var
    local fileid = path:match("[^/\\]+$") or path
    local function classify(k)
        if k:find("|elastic|", 1, true) then return "elastic" end
        if k:find("|surplus_sink|", 1, true) then return "surplus_sink" end
        if k:find("|shortage_source|", 1, true) then return "shortage_source" end
        if k:find("|initial_source|", 1, true) then return "initial_source" end
        if k:find("|final_sink|", 1, true) then return "final_sink" end
        return "other"
    end
    local function emit(ablated, cls, cost, state, steps, m, pinval)
        print(table.concat({
            fileid, ablated, cls, cost, state, steps,
            string.format("%.6g", m.shortage), string.format("%.6g", m.surplus),
            string.format("%.6g", m.initial), string.format("%.6g", m.final),
            string.format("%.6g", m.elastic), string.format("%.6g", m.slack),
            m.n_shortage, m.n_surplus, m.n_initial, m.n_final, m.n_elastic,
            string.format("%.6g", m.rsum), string.format("%.6g", m.rmax),
            m.n_recipe, m.n_recipe_active,
            pinval == nil and "NA" or string.format("%.6g", pinval),
        }, "\t"))
    end
    -- The header and the (base) row are global to a file, so on a sharded run only
    -- the shard that owns index 1 emits them; concatenated shard output then has a
    -- single header + base per file. Non-sharded runs (lo==1) emit them as before.
    if unit_lo == 1 then
        print(table.concat({
            "file", "ablated", "ablated_class", "ablated_cost", "state", "steps",
            "sum_shortage", "sum_surplus", "sum_initial", "sum_final", "sum_elastic", "sum_slack",
            "n_shortage", "n_surplus", "n_initial", "n_final", "n_elastic",
            "Rsum", "Rmax", "n_recipe", "n_recipe_active", "pinned_recipe_val",
        }, "\t"))
        emit("(base)", "(base)", "NA", b_state, b_steps, measure(b_vars, base_problem.primals), pinned_recipe_value(b_vars))
    end
    local targets = collect_targets(filter)
    for idx = unit_lo, math.min(#targets, unit_hi) do
        local t = targets[idx]
        local problem = build_problem()
        local term = problem.primals[t.key]
        if term then term.cost = 0 end
        local state, steps, vars = solve(problem)
        emit(t.key, classify(t.key), string.format("%.6g", t.cost), state, steps,
            measure(vars, problem.primals), pinned_recipe_value(vars))
    end
    os.exit(0)
end

-- `@cheat` resolves to the single highest-|value| ACTIVE penalty escape
-- (|shortage_source| / |elastic|) in the baseline solution -- the material the
-- LP leaned on hardest. Lets a batch sweep the dominant cheat without first
-- parsing inspect output for the exact key. No active cheat => nothing to sweep.
if pattern == "@cheat" then
    local best_key, best_val = nil, 0
    if b_vars and b_vars.x then
        for k, v in pairs(b_vars.x) do
            if (k:find("|shortage_source|", 1, true) or k:find("|elastic|", 1, true))
                and math.abs(v) > best_val then
                best_key, best_val = k, math.abs(v)
            end
        end
    end
    if not best_key or best_val <= ed.CHEAT_EPS then
        print("# @cheat: no active penalty escape above CHEAT_EPS -- nothing to sweep.")
        os.exit(0)
    end
    print(string.format("# @cheat resolved to %s (val=%.6g)", best_key, best_val))
    pattern = best_key
end

if not pattern then
    -- INSPECT: list the cost-bearing variables worth repricing, with their
    -- baseline cost and solved value, so the user knows what key to sweep.
    print("\n# cost-bearing variables (key | cost | solved value)")
    local rows = {}
    for key, term in pairs(base_problem.primals) do
        local v = (b_vars and b_vars.x and b_vars.x[key]) or 0
        -- Surface the penalty escapes and priced terms (the meaningful cost
        -- locations), plus anything the solution actually carries flow on.
        local interesting = term.cost ~= 0
            or key:find("|shortage_source|", 1, true)
            or key:find("|elastic|", 1, true)
            or key:find("|initial_source|", 1, true)
            or key:find("|final_sink|", 1, true)
            or math.abs(v) > 1e-6
        if interesting then
            rows[#rows + 1] = { key = key, cost = term.cost, val = v }
        end
    end
    table.sort(rows, function(a, b)
        if a.cost ~= b.cost then return a.cost > b.cost end
        return a.key < b.key
    end)
    for _, r in ipairs(rows) do
        print(string.format("  %-58s cost=%-10.4g val=%.6g", r.key, r.cost, r.val))
    end
    print("\n# to sweep: lua tests/sweep_cost.lua <file> '<key-substring>' <v1,v2,...>")
    os.exit(0)
end

-- ---- sweep ------------------------------------------------------------------
-- Confirm the pattern by listing the matched keys + their baseline cost once.
do
    local preview = build_problem()
    local matched = override_cost(preview, pattern, 0)
    if #matched == 0 then
        die("pattern '" .. pattern .. "' matched NO primal variables; "
            .. "run inspect mode (no pattern) to list valid keys.", 1)
    end
    print(string.format("\n# pattern '%s' matched %d variable(s):", pattern, #matched))
    for _, m in ipairs(matched) do
        print(string.format("    %-58s base_cost=%.4g", m.key, m.was))
    end
    print("# sweeping cost = {" .. table.concat((function()
        local s = {}
        for _, v in ipairs(values) do s[#s + 1] = string.format("%g", v) end
        return s
    end)(), ", ") .. "}\n")
end

for _, cost in ipairs(values) do
    local problem = build_problem()
    override_cost(problem, pattern, cost)
    local state, steps, vars = solve(problem)
    local d = ed.detect(vars, problem.primals)
    print(string.format("cost=%-10g %s", cost, row_fields(state, steps, d)))
    if DUMP_VARS then dump_vars(vars, problem.primals) end
end
