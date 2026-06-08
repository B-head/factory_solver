---@diagnostic disable: undefined-global
-- Useful-candidate CLASSIFICATION driver (tilted-cost research, v2).
--
-- Adapted from tests/collect_useful.lua. Keeps every column that driver emits
-- (same "useful candidate" definition, same escape-cost-raising probe over the
-- original 4096 ladder = `activate_mult`), and adds two new columns that
-- classify -- via DETERMINISTIC PROBE EXPERIMENTS, never by eyeballing rows --
-- WHY a candidate is or is not activatable:
--
--   1. `blocked` (boolean): does the candidate's recipe carry a binding upper
--      constraint forcing it to ~0? Computed STRUCTURALLY from the dump's
--      `constraints` table (no solve): true iff some constraint has
--      type=="recipe", name == the candidate recipe's name, limit_type=="upper",
--      and limit_amount_per_second <= 0. (Maps "recipe/<name>/<quality>" -> name.)
--
--   2. `activate_mult_ext` (number): the SAME escape-cost-raising probe as
--      collect_useful, but over a COMPLETE extended power-of-2 ladder
--      2^1 .. 2^18. The smallest multiple of ELASTIC_COST at which X activates
--      (x_after > park_threshold), else -1. Raising a cost can never make the LP
--      unbounded, so this is safe; no negative / self-subsidy costs are used.
--
-- Everything else mirrors collect_useful.lua: EXPERIMENT_OPTIONS (deficit_seeding
-- / catalyst_closure / reachability_gating) all OFF by default (CP_<NAME>=1 turns
-- one back on); solve tolerance 1e-7; --manifest / --out / positional dump files
-- / --selftest; Lua writes the --out file itself (no native-stdout capture).
--
-- Usage (from repo root):
--   lua tests/classify_useful.lua <dump-file> [<dump-file> ...]
--   lua tests/classify_useful.lua --manifest <list.txt>
--   lua tests/classify_useful.lua --selftest
--   ... --out <file>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"

-- Penalty escapes whose nonzero use marks a relaxation/cheat to substitute away.
local ELASTIC_KINDS = { shortage_source = true, surplus_sink = true, elastic = true }

local function env_on(name) return os.getenv(name) == "1" end
local EXPERIMENT_OPTIONS = {
    deficit_seeding = env_on("CP_DEFICIT_SEEDING"),
    catalyst_closure = env_on("CP_CATALYST_CLOSURE"),
    reachability_gating = env_on("CP_REACHABILITY_GATING"),
}

local TOL = 1e-7
-- collect_useful used ITER=600; the user pinned 800 for the extended classify run.
local ITER = 800
local ELASTIC_COST = 2 ^ 10 -- the flat shortage/surplus cost tier in create_problem

-- Original ladder (mirrors collect_useful.lua) -> activate_mult.
local PROBE_LADDER = { 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 4096 }
-- Complete extended power-of-2 ladder 2^1 .. 2^18 -> activate_mult_ext.
local PROBE_LADDER_EXT = {
    2, 4, 8, 16, 32, 64, 128, 256, 512, 1024,
    2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144,
}

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

-- The candidate primal key for a recipe is "recipe/<name>/<quality>". Map it to
-- <name> for matching against the constraints table. We do NOT parse semantics
-- out of the key beyond the structural recipe-name field, and only for recipe
-- candidates; non-recipe candidates simply never match a recipe constraint.
local function recipe_name_of(key)
    local name = key:match("^recipe/(.+)/[^/]+$")
    return name
end

-- STRUCTURAL: is this candidate recipe forced to ~0 by a binding upper
-- constraint in the dump? No solve. Mirrors the constraint shape produced by
-- the explorer / selftest fixture (type/name/quality/limit_type/limit_amount).
local function is_blocked(key, constraints)
    local rname = recipe_name_of(key)
    if not rname or not constraints then return false end
    for _, c in ipairs(constraints) do
        if c.type == "recipe" and c.name == rname
            and c.limit_type == "upper"
            and (c.limit_amount_per_second or 0) <= 0 then
            return true
        end
    end
    return false
end

-- Run the escape-cost-raising probe over `ladder`; return the smallest mult at
-- which X activates (else -1), plus the last solved (probe) problem/state/vars
-- so callers can read the after-state. Early-exits on first activation.
local function probe(constraints, lines, c, ladder, thresh)
    local hit_mult, p_at, s_at, v_at = nil, nil, nil, nil
    for _, mult in ipairs(ladder) do
        local _, p2 = pcall(create_problem.create_problem, "classify-probe",
            constraints, lines, nil, EXPERIMENT_OPTIONS)
        p2.primals[c.via_elastic].cost = ELASTIC_COST * mult
        local s2, v2 = solve(p2)
        p_at, s_at, v_at = p2, s2, v2
        if s2 == "finished" and (v2.x[c.key] or 0) > thresh then
            hit_mult = mult
            break
        end
    end
    return hit_mult, p_at, s_at, v_at
end

---@return table[] rows, string? note
local function collect(constraints, lines, label)
    local ok, problem = pcall(create_problem.create_problem, "classify",
        constraints, lines, nil, EXPERIMENT_OPTIONS)
    if not ok then return {}, "create_problem raised: " .. tostring(problem) end

    local state, vars = solve(problem)
    if state ~= "finished" then return {}, "baseline state=" .. tostring(state) end

    local thresh = ed.park_threshold(vars, problem.primals)
    local function is_zero(key) return (vars.x[key] or 0) <= thresh end

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

    local rows = {}
    for _, c in ipairs(candidates) do
        -- Original 4096 ladder probe -> activate_mult + recorded after-state.
        local hit_mult, p_at, s_at, v_at = probe(constraints, lines, c, PROBE_LADDER, thresh)
        local after_tot = (s_at == "finished") and elastic_totals(p_at, v_at)
            or { shortage_source = -1, surplus_sink = -1, elastic = -1 }

        -- Extended 2^18 ladder probe -> activate_mult_ext (independent run).
        local hit_mult_ext = probe(constraints, lines, c, PROBE_LADDER_EXT, thresh)

        -- Structural blocked flag (no solve).
        local blocked = is_blocked(c.key, constraints)

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
            blocked = blocked,
            activate_mult_ext = hit_mult_ext or -1,
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
    "blocked", "activate_mult_ext",
}
local function fmt(v)
    if type(v) == "number" then return string.format("%.6g", v) end
    return tostring(v)
end
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
