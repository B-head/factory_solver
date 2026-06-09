---@diagnostic disable: undefined-global
-- Useful-variable collection driver (tilted-cost research, v1).
--
-- Implements the user's operational definition of "useful" and "improvement":
--   * A currently-ZERO primal X is a USEFUL CANDIDATE if increasing it could
--     decrease a currently-NONZERO penalty escape (elastic) variable -- i.e. X
--     is structurally coupled to that elastic's material balance row with the
--     sign that lets X substitute for the escape.
--   * If a COST SET that actually activates X (drives it off zero) AND drops the
--     coupled elastic exists, that is an IMPROVEMENT for this problem.
--
-- The driver does NOT label rows good/bad and does NOT collapse anything into a
-- single "cheat" number (cf. tests/explore_detect.detect, deliberately unused
-- for the scoring). It emits raw before/after rows -- full per-kind elastic
-- totals, the candidate's reduced cost (= minimal cost cut to start activating
-- it), the probe cost used, and whether other elastics moved (trade-off) -- so
-- the make-vs-import requirements get mined later from the raw corpus.
--
-- PURE TILTED-COST EXPERIMENT: reachability_gating, deficit_seeding and
-- catalyst_closure all default OFF here (the shipped create_problem keeps them
-- on; only this research worker flips them). Set CP_<NAME>=1 to turn one back on.
--
-- Usage (from repo root):
--   lua tests/research/collect_useful.lua <dump-file> [<dump-file> ...]   -- one or many
--   lua tests/research/collect_useful.lua --manifest <list.txt>           -- paths, 1/line
--   lua tests/research/collect_useful.lua --selftest                      -- inline fixture
--   ... --out <file>   -- write the TSV here instead of stdout (Lua writes the
--                         file directly, so no shell stdout/stderr capture quirks
--                         and no command-line-length limit on big corpora).
-- Output: one '#'-prefixed header line, then one row per useful candidate, with
-- a '#file:'/'#note:' comment line per processed dump.

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"

-- Penalty escapes whose nonzero use marks a relaxation/cheat to substitute away.
-- Slack (cost 0, bound over/under-shoot) is NOT a violation and is excluded; the
-- priced boundaries initial_source/final_sink are measured but not "elastic".
local ELASTIC_KINDS = { shortage_source = true, surplus_sink = true, elastic = true }

-- Experiment options: the three cycle-material preprocessing mechanisms OFF by
-- default so this is a pure cost experiment; CP_<NAME>=1 turns one back on.
local function env_on(name) return os.getenv(name) == "1" end
local EXPERIMENT_OPTIONS = {
    deficit_seeding = env_on("CP_DEFICIT_SEEDING"),
    catalyst_closure = env_on("CP_CATALYST_CLOSURE"),
    reachability_gating = env_on("CP_REACHABILITY_GATING"),
}

local TOL = 1e-7
local ITER = 600
local ELASTIC_COST = 2 ^ 10 -- the flat shortage/surplus cost tier in create_problem

-- Probe LEVER = raise the competing escape (the via_elastic) cost. For both
-- coupling signs the elastic is the relaxation we want the real variable X to
-- take over, and making the escape dearer is what tips the LP toward X. (We do
-- NOT lower X's own cost: its reduced cost from this IPM is the analytic-centre
-- dual, not the simplex entry threshold, so it is an unreliable lever, and the
-- working self-cost is typically a large NEGATIVE subsidy = the rejected
-- make_recipe_cost knob. Raising the escape is the meaningful boundary lever.)
-- The ladder finds the smallest multiple of ELASTIC_COST at which X activates --
-- that threshold is the per-problem datum (it equals X's true chain marginal
-- cost), collected across the corpus for later analysis.
local PROBE_LADDER = { 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 4096 }

local function solve(problem)
    return harness.solve_to_completion(lp, problem, { tolerance = TOL, iterate_limit = ITER })
end

-- Per-kind elastic totals (sum of |value|) over a solved vars vector.
local function elastic_totals(problem, vars)
    local t = { shortage_source = 0, surplus_sink = 0, elastic = 0 }
    local x = vars and vars.x or {}
    for key, p in pairs(problem.primals) do
        if ELASTIC_KINDS[p.kind] then
            t[p.kind] = t[p.kind] + math.abs(x[key] or 0)
        end
    end
    return t
end

local function count_active_recipes(problem, vars, thresh)
    local n, x = 0, (vars and vars.x or {})
    for key, _ in pairs(problem.primals) do
        if ed.is_recipe(key, problem.primals) and (x[key] or 0) > thresh then n = n + 1 end
    end
    return n
end

-- Collect candidate rows for one problem (constraints + normalized lines).
---@return table[] rows, string? note
local function collect(constraints, lines, label)
    local ok, problem = pcall(create_problem.create_problem, "collect",
        constraints, lines, nil, EXPERIMENT_OPTIONS)
    if not ok then return {}, "create_problem raised: " .. tostring(problem) end

    local state, vars = solve(problem)
    if state ~= "finished" then return {}, "baseline state=" .. tostring(state) end

    local thresh = ed.park_threshold(vars, problem.primals)
    local function is_zero(key) return (vars.x[key] or 0) <= thresh end

    -- nonzero penalty escapes -> the relaxations we want a real variable to take over
    local elastics = {}
    for key, p in pairs(problem.primals) do
        if ELASTIC_KINDS[p.kind] and (vars.x[key] or 0) > thresh then
            elastics[#elastics + 1] = { key = key, kind = p.kind, material = p.material,
                                        value = vars.x[key] }
        end
    end
    if #elastics == 0 then return {}, "no nonzero elastic" end

    local base_tot = elastic_totals(problem, vars)
    local base_recipes = count_active_recipes(problem, vars, thresh)

    -- candidate zero variables coupled to a nonzero shortage/surplus material row.
    -- shortage(M) injects +M, so a zero PRODUCER of M (coef>0) can replace it.
    -- surplus(M) drains -M, so a zero CONSUMER of M (coef<0) can replace it.
    local seen = {}
    local candidates = {}
    for _, E in ipairs(elastics) do
        local Mrow = E.material
        if Mrow and (E.kind == "shortage_source" or E.kind == "surplus_sink") then
            for key, p in pairs(problem.primals) do
                if not seen[key] and is_zero(key)
                    and not ELASTIC_KINDS[p.kind] and p.kind ~= "slack" then
                    local terms = problem.subject_terms[key]
                    local coef = terms and terms[Mrow]
                    if coef and ((E.kind == "shortage_source" and coef > 0)
                            or (E.kind == "surplus_sink" and coef < 0)) then
                        seen[key] = true
                        candidates[#candidates + 1] = {
                            key = key, kind = p.kind, coef = coef,
                            via_elastic = E.key, via_kind = E.kind, via_value = E.value,
                            base_cost = p.cost, reduced_cost = vars.s[key],
                        }
                    end
                end
            end
        end
    end

    -- force-probe each candidate by raising its via_elastic cost up a ladder
    -- until X activates; record the threshold multiple and the raw before/after
    -- elastic vector at that point (no verdict). Early-exits on first activation.
    local rows = {}
    for _, c in ipairs(candidates) do
        local hit_mult, p_at, s_at, v_at = nil, nil, nil, nil
        for _, mult in ipairs(PROBE_LADDER) do
            local _, p2 = pcall(create_problem.create_problem, "collect-probe",
                constraints, lines, nil, EXPERIMENT_OPTIONS)
            p2.primals[c.via_elastic].cost = ELASTIC_COST * mult
            local s2, v2 = solve(p2)
            p_at, s_at, v_at = p2, s2, v2 -- retain the last solved (probe) problem
            if s2 == "finished" and (v2.x[c.key] or 0) > thresh then
                hit_mult = mult
                break
            end
        end
        local after_tot = (s_at == "finished") and elastic_totals(p_at, v_at)
            or { shortage_source = -1, surplus_sink = -1, elastic = -1 }
        rows[#rows + 1] = {
            label = label, candidate = c.key, kind = c.kind, coef = c.coef,
            via_elastic = c.via_elastic, via_kind = c.via_kind,
            base_cost = c.base_cost, reduced_cost = c.reduced_cost,
            activate_mult = hit_mult or -1, probe_state = s_at,
            x_after = (v_at and v_at.x[c.key]) or 0,
            via_before = c.via_value,
            via_after = (v_at and v_at.x[c.via_elastic]) or -1,
            short_before = base_tot.shortage_source, short_after = after_tot.shortage_source,
            surplus_before = base_tot.surplus_sink, surplus_after = after_tot.surplus_sink,
            elastic_before = base_tot.elastic, elastic_after = after_tot.elastic,
            recipes_before = base_recipes,
            recipes_after = (s_at == "finished") and count_active_recipes(p_at, v_at, thresh) or -1,
        }
    end
    return rows, nil
end

-- ---- output -----------------------------------------------------------------
local COLS = {
    "label", "candidate", "kind", "coef", "via_elastic", "via_kind",
    "base_cost", "reduced_cost", "activate_mult", "probe_state", "x_after",
    "via_before", "via_after",
    "short_before", "short_after", "surplus_before", "surplus_after",
    "elastic_before", "elastic_after", "recipes_before", "recipes_after",
}
local function fmt(v)
    if type(v) == "number" then return string.format("%.6g", v) end
    return tostring(v)
end
-- `sink` is io.write or a file:write closure; set in main from --out.
local function emit_header(sink) sink("#" .. table.concat(COLS, "\t") .. "\n") end
local function emit_rows(sink, rows)
    for _, r in ipairs(rows) do
        local out = {}
        for _, k in ipairs(COLS) do out[#out + 1] = fmt(r[k]) end
        sink(table.concat(out, "\t") .. "\n")
    end
end

-- ---- selftest fixture (lp_lower_limit multi-step) ---------------------------
local function selftest_fixture()
    local function item(n, a) return { type = "item", name = n, quality = "normal", amount_per_second = a } end
    local function line(r, prod, ing)
        return { recipe_typed_name = { type = "recipe", name = r, quality = "normal" },
                 products = prod, ingredients = ing, power_per_second = 0, pollution_per_second = 0 }
    end
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

-- ---- main -------------------------------------------------------------------
-- Parse args: --selftest, --out <file>, --manifest <file>, and/or positional
-- dump files. Lua writes the output itself (to --out or stdout), so the corpus
-- driver never has to capture native stdout/stderr (which WinPS mangles).
local selftest, out_path, manifest_path = false, nil, nil
local files = {}
do
    local i = 1
    while arg[i] do
        local a = arg[i]
        if a == "--selftest" then selftest = true
        elseif a == "--out" then i = i + 1; out_path = arg[i]
        elseif a == "--manifest" then i = i + 1; manifest_path = arg[i]
        else files[#files + 1] = a end
        i = i + 1
    end
end
if manifest_path then
    for line in io.lines(manifest_path) do
        line = line:gsub("%s+$", "")
        if line ~= "" then files[#files + 1] = line end
    end
end

local sink = io.write
local out_file = nil
if out_path then
    out_file = assert(io.open(out_path, "w"))
    sink = function(s) out_file:write(s) end
end

sink(string.format("#options: deficit_seeding=%s catalyst_closure=%s reachability_gating=%s\n",
    tostring(EXPERIMENT_OPTIONS.deficit_seeding), tostring(EXPERIMENT_OPTIONS.catalyst_closure),
    tostring(EXPERIMENT_OPTIONS.reachability_gating)))
emit_header(sink)

if selftest or (#files == 0) then
    local constraints, lines = selftest_fixture()
    local rows, note = collect(constraints, lines, "selftest:lp_lower_limit")
    sink("#file: selftest:lp_lower_limit" .. (note and (" note: " .. note) or "") .. "\n")
    emit_rows(sink, rows)
else
    for _, path in ipairs(files) do
        local prob, kind, detail = problem_dump.load_problem(path)
        if not prob then
            sink("#file: " .. path .. " LOAD-FAILED (" .. tostring(kind) .. "): " .. tostring(detail) .. "\n")
        else
            local label = "seed=" .. tostring(prob.meta and prob.meta.seed) ..
                "|" .. (path:match("([^/\\]+)%.lua$") or path)
            local ok, rows, note = pcall(collect, prob.constraints, prob.normalized_lines, label)
            if not ok then
                sink("#file: " .. label .. " RAISED: " .. tostring(rows) .. "\n")
            else
                sink("#file: " .. label .. (note and (" note: " .. note) or "") .. "\n")
                emit_rows(sink, rows)
            end
        end
    end
end

if out_file then out_file:close() end
