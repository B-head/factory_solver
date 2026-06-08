---@diagnostic disable: undefined-global
-- Cyclic-SCC elastic whack-a-mole probe (research, no verdict).
--
-- Tests two maintainer hypotheses about penalty escapes ("elastics":
-- shortage_source / surplus_sink / elastic) inside a cyclic material SCC:
--
--   HYP1 (raise-one / whack-a-mole): raising the cost of the elastic(s) active
--     at baseline inside a cyclic SCC moves relief to a SIBLING elastic in the
--     SAME SCC, while variables OUTSIDE the SCC barely move.
--   HYP2 (raise-all): to move variables OUTSIDE the SCC you must raise ALL of
--     the SCC's elastics simultaneously.
--
-- For each dump: build+solve baseline with the pure tilted-cost experiment
-- options (deficit_seeding / catalyst_closure / reachability_gating all OFF),
-- compute the park threshold, build the material graph + SCCs from the
-- problem's normalized lines, then for each CYCLIC SCC with >=1 baseline-active
-- elastic, partition every primal into "inside" / "outside" the SCC and run the
-- two re-solves, emitting one TSV row per such SCC. RAW numbers only; the
-- researcher draws every line. Lua opens --out and writes it directly (the
-- PowerShell side never captures native stdout -- truncation bug).
--
-- Usage (from repo root):
--   <lua> tests/probe_cycle_elastics.lua --manifest <list.txt> --out <file.tsv>
--   <lua> tests/probe_cycle_elastics.lua <dump.lua> [<dump.lua> ...] --out <f>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"
local mc = require "solver/material_cycles"
local tn = require "manage/typed_name"

local ELASTIC_KINDS = { shortage_source = true, surplus_sink = true, elastic = true }
local CHEAT_KINDS = { shortage_source = true, surplus_sink = true } -- cheat_sum
local EXPERIMENT_OPTIONS = {
    deficit_seeding = false,
    catalyst_closure = false,
    reachability_gating = false,
}
local TOL = 1e-7
local ITER = 800
local ELASTIC_COST = 2 ^ 10 -- 1024, the flat shortage/surplus tier in create_problem

-- HYP1 ladder: smallest multiple where a sibling activates OR outside moves.
local PROBE_LADDER = { 2, 4, 8, 16, 32, 64, 256, 1024, 4096, 16384, 65536, 262144 }
-- HYP2 raise-all level.
local RAISE_ALL_COST = 1024 * 262144

local function solve(problem)
    return harness.solve_to_completion(lp, problem, { tolerance = TOL, iterate_limit = ITER })
end

local function build(constraints, lines)
    return create_problem.create_problem("probe", constraints, lines, nil, EXPERIMENT_OPTIONS)
end

-- Sum |value| over primals of given kinds.
local function sum_kinds(problem, x, kinds)
    local s = 0
    for key, p in pairs(problem.primals) do
        if kinds[p.kind] then s = s + math.abs(x[key] or 0) end
    end
    return s
end

local function sum_kind(problem, x, kind)
    local s = 0
    for key, p in pairs(problem.primals) do
        if p.kind == kind then s = s + math.abs(x[key] or 0) end
    end
    return s
end

-- Total flow over real recipe variables (kind == "recipe").
local function rsum(problem, x)
    local s = 0
    for key, _ in pairs(problem.primals) do
        if ed.is_recipe(key, problem.primals) then s = s + math.abs(x[key] or 0) end
    end
    return s
end

-- Build the set of recipe variable keys that are INTERNAL to an SCC: a recipe
-- with >=1 ingredient (incl. fuel) in S AND >=1 product (incl. burnt result) in
-- S. Returns a set of recipe-variable-name keys.
local function internal_recipes(lines, scc_set)
    local out = {}
    for _, line in ipairs(lines) do
        local has_ing_in = false
        for _, ing in ipairs(line.ingredients) do
            if scc_set[tn.typed_name_to_variable_name(ing)] then has_ing_in = true; break end
        end
        if not has_ing_in and line.fuel_ingredient
            and scc_set[tn.typed_name_to_variable_name(line.fuel_ingredient)] then
            has_ing_in = true
        end
        if has_ing_in then
            local has_prod_in = false
            for _, prod in ipairs(line.products) do
                if scc_set[tn.typed_name_to_variable_name(prod)] then has_prod_in = true; break end
            end
            if not has_prod_in and line.fuel_burnt_result
                and scc_set[tn.typed_name_to_variable_name(line.fuel_burnt_result)] then
                has_prod_in = true
            end
            if has_prod_in then
                out[tn.typed_name_to_variable_name(line.recipe_typed_name)] = true
            end
        end
    end
    return out
end

-- Partition primals into inside/outside the SCC. inside = (elastic whose
-- material is in S) OR (recipe internal to S). Returns two lists of keys.
local function partition(problem, scc_set, internal_recipe_set)
    local inside, outside = {}, {}
    for key, p in pairs(problem.primals) do
        local is_inside = false
        if ELASTIC_KINDS[p.kind] and p.material and scc_set[p.material] then
            is_inside = true
        elseif p.kind == "recipe" and internal_recipe_set[key] then
            is_inside = true
        end
        if is_inside then inside[#inside + 1] = key else outside[#outside + 1] = key end
    end
    return inside, outside
end

-- max |x1-x0| and count over a key list with threshold th.
local function delta_stats(keys, x0, x1, th)
    local maxd, n = 0, 0
    for _, key in ipairs(keys) do
        local d = math.abs((x1[key] or 0) - (x0[key] or 0))
        if d > maxd then maxd = d end
        if d > th then n = n + 1 end
    end
    return maxd, n
end

-- Count active S-elastics (kind in 3, material in S, value > th).
local function active_Sel(problem, x, scc_set, th)
    local n = 0
    for key, p in pairs(problem.primals) do
        if ELASTIC_KINDS[p.kind] and p.material and scc_set[p.material]
            and (x[key] or 0) > th then
            n = n + 1
        end
    end
    return n
end

-- All S-elastic keys present in the problem (regardless of active).
local function all_Sel_keys(problem, scc_set)
    local out = {}
    for key, p in pairs(problem.primals) do
        if ELASTIC_KINDS[p.kind] and p.material and scc_set[p.material] then
            out[#out + 1] = key
        end
    end
    return out
end

---Process one problem; returns rows + note. Each row is one cyclic SCC with
---a baseline-active elastic.
local function process(constraints, lines, label)
    local ok, prob = pcall(build, constraints, lines)
    if not ok then return {}, "create_problem raised: " .. tostring(prob) end

    local state, vars = solve(prob)
    if state ~= "finished" then return {}, "baseline state=" .. tostring(state) end
    local x0 = vars.x
    local th = ed.park_threshold(vars, prob.primals)

    -- material graph + SCCs from the problem's normalized lines.
    local adj = mc.build_material_graph(lines)
    local sccs = mc.find_sccs(adj)

    local rows = {}
    for _, scc in ipairs(sccs) do
        if mc.is_cyclic_scc(scc, adj) then
            local scc_set = {}
            for _, m in ipairs(scc) do scc_set[m] = true end

            -- baseline-active S-elastics + present S-elastics
            local sel_present = all_Sel_keys(prob, scc_set)
            local active_base = {} -- keys active at baseline
            local active_base_mats = {}
            for _, key in ipairs(sel_present) do
                if (x0[key] or 0) > th then
                    active_base[#active_base + 1] = key
                    active_base_mats[#active_base_mats + 1] = prob.primals[key].material or "?"
                end
            end

            if #active_base >= 1 then
                local internal_recipe_set = internal_recipes(lines, scc_set)
                local inside, outside = partition(prob, scc_set, internal_recipe_set)
                table.sort(active_base_mats)

                -- baseline raw sums
                local cheat_b = sum_kinds(prob, x0, CHEAT_KINDS)
                local relax_b = sum_kind(prob, x0, "elastic")
                local import_b = sum_kind(prob, x0, "initial_source")
                local rsum_b = rsum(prob, x0)

                -- ---- HYP1: raise-one ladder -----------------------------
                local h1_mult = -1
                local h1_sibling = false
                local h1_dOut, h1_nOut, h1_dIn = -1, -1, -1
                for _, mult in ipairs(PROBE_LADDER) do
                    local okp, p2 = pcall(build, constraints, lines)
                    if not okp then break end
                    for _, key in ipairs(active_base) do
                        p2.primals[key].cost = ELASTIC_COST * mult
                    end
                    local s2, v2 = solve(p2)
                    if s2 == "finished" then
                        local x2 = v2.x
                        -- did a sibling (not active at baseline) activate?
                        local sibling = false
                        local baseset = {}
                        for _, k in ipairs(active_base) do baseset[k] = true end
                        for _, k in ipairs(sel_present) do
                            if not baseset[k] and (x2[k] or 0) > th then sibling = true; break end
                        end
                        local dOut, nOut = delta_stats(outside, x0, x2, th)
                        if sibling or dOut > th then
                            local dIn = select(1, delta_stats(inside, x0, x2, th))
                            h1_mult = mult
                            h1_sibling = sibling
                            h1_dOut, h1_nOut, h1_dIn = dOut, nOut, dIn
                            break
                        end
                    end
                    -- non-finished probe: keep climbing the ladder
                end

                -- ---- HYP2: raise-all -----------------------------------
                local h2_dOut, h2_nOut, h2_dIn, h2_nActive = -1, -1, -1, -1
                local cheat_a, relax_a, import_a, rsum_a = -1, -1, -1, -1
                do
                    local okp, p3 = pcall(build, constraints, lines)
                    if okp then
                        for _, key in ipairs(sel_present) do
                            p3.primals[key].cost = RAISE_ALL_COST
                        end
                        local s3, v3 = solve(p3)
                        if s3 == "finished" then
                            local x3 = v3.x
                            h2_dOut, h2_nOut = delta_stats(outside, x0, x3, th)
                            h2_dIn = select(1, delta_stats(inside, x0, x3, th))
                            h2_nActive = active_Sel(p3, x3, scc_set, th)
                            cheat_a = sum_kinds(p3, x3, CHEAT_KINDS)
                            relax_a = sum_kind(p3, x3, "elastic")
                            import_a = sum_kind(p3, x3, "initial_source")
                            rsum_a = rsum(p3, x3)
                        end
                    end
                end

                rows[#rows + 1] = {
                    label = label,
                    scc_size = #scc,
                    n_Sel_present = #sel_present,
                    n_active_base = #active_base,
                    active_base_materials = table.concat(active_base_mats, ","),
                    h1_mult = h1_mult,
                    h1_sibling_activated = h1_sibling,
                    h1_dOut_max = h1_dOut,
                    h1_nOut = h1_nOut,
                    h1_dIn_max = h1_dIn,
                    h2_dOut_max = h2_dOut,
                    h2_nOut = h2_nOut,
                    h2_dIn_max = h2_dIn,
                    h2_nActiveSel_after = h2_nActive,
                    cheat_before = cheat_b, cheat_after = cheat_a,
                    relax_before = relax_b, relax_after = relax_a,
                    import_before = import_b, import_after = import_a,
                    Rsum_before = rsum_b, Rsum_after = rsum_a,
                }
            end
        end
    end
    return rows, nil
end

-- ---- output -----------------------------------------------------------------
local COLS = {
    "label", "scc_size", "n_Sel_present", "n_active_base", "active_base_materials",
    "h1_mult", "h1_sibling_activated", "h1_dOut_max", "h1_nOut", "h1_dIn_max",
    "h2_dOut_max", "h2_nOut", "h2_dIn_max", "h2_nActiveSel_after",
    "cheat_before", "cheat_after", "relax_before", "relax_after",
    "import_before", "import_after", "Rsum_before", "Rsum_after",
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

-- ---- main -------------------------------------------------------------------
local out_path, manifest_path = nil, nil
local files = {}
do
    local i = 1
    while arg[i] do
        local a = arg[i]
        if a == "--out" then i = i + 1; out_path = arg[i]
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

for _, path in ipairs(files) do
    local prob, kind, detail = problem_dump.load_problem(path)
    if not prob then
        sink("#file: " .. path .. " LOAD-FAILED (" .. tostring(kind) .. "): " .. tostring(detail) .. "\n")
    else
        local label = "seed=" .. tostring(prob.meta and prob.meta.seed) ..
            "|" .. (path:match("([^/\\]+)%.lua$") or path)
        local ok, rows, note = pcall(process, prob.constraints, prob.normalized_lines, label)
        if not ok then
            sink("#file: " .. label .. " RAISED: " .. tostring(rows) .. "\n")
        else
            sink("#file: " .. label .. (note and (" note: " .. note) or "") .. "\n")
            emit_rows(sink, rows)
        end
    end
end

if out_file then out_file:close() end
