---@diagnostic disable: undefined-global
-- Apply material_weights to the escape costs and measure the import-vs-fabricate
-- decision BEFORE vs AFTER (research, no verdict).
--
-- The flip probe (probe_flip_vs_weight) measured the THRESHOLD analytically.
-- This probe actually wires w(M) in: it re-prices the two 1024-tier escapes
--   |shortage_source| (the import)  ->  1024 * w(material)
--   |surplus_sink|   (byproduct dump) -> 1024 * w(material)
-- via create_problem's shortage_cost_fn / surplus_cost_fn hooks, re-solves, and
-- reports, for every avoidable-import material (self-sustaining cyclic SCC that
-- CAN fabricate yet imports at the flat baseline), whether applying the weights
-- flipped it to fabricate, left it imported, or collapsed the target.
--
-- BEFORE = flat (shortage=surplus=1024): by construction every such material
-- imports. AFTER = per mode {amount|main} x {min|mean}. RAW outcomes only, one
-- row per active-shortage material.
--
-- Usage (from repo root):
--   <lua> tests/probe_apply_weight.lua --manifest <list> --out <file.tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"
local mc = require "solver/material_cycles"
local mw = require "solver/material_weights"
local tn = require "manage/typed_name"

local TOL, ITER = 1e-7, 800
local OPTS = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
local ELASTIC_COST = 2 ^ 10

-- The four allocation x combiner modes, applied to BOTH escapes (shortage +
-- surplus) -- the faithful "weight every escape by w(M)" the module intends.
-- Plus two shortage-ONLY variants (surplus left flat) to isolate whether the
-- surplus weighting -- which re-prices the fabrication's own byproduct dumps --
-- is what tips a fabricable material into target-abandon collapse.
local MODES = {
    { key = "amt_min",     allocation = "amount", combiner = "min" },
    { key = "amt_mean",    allocation = "amount", combiner = "mean" },
    { key = "main_min",    allocation = "main",   combiner = "min" },
    { key = "main_mean",   allocation = "main",   combiner = "mean" },
    { key = "amt_min_sho", allocation = "amount", combiner = "min", shortage_only = true },
    { key = "main_min_sho",allocation = "main",   combiner = "min", shortage_only = true },
}

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end

-- Build with the flat baseline (no weighting).
local function build_flat(c, l) return create_problem.create_problem("aw", c, l, nil, OPTS) end

-- Build with escapes re-priced at 1024 * w(material) for both shortage and
-- surplus. A material absent from the weight table (raw root, never produced)
-- defaults to w=1 == flat.
local function build_weighted(c, l, w, shortage_only)
    local function priced(name) return ELASTIC_COST * (w[name] or 1) end
    local o = {}
    for k, v in pairs(OPTS) do o[k] = v end
    o.shortage_cost_fn = function(name, _) return priced(name) end
    if not shortage_only then o.surplus_cost_fn = function(name) return priced(name) end end
    return create_problem.create_problem("aw", c, l, nil, o)
end

local function internal_recipes(lines, scc_set)
    local out = {}
    for _, line in ipairs(lines) do
        local hi = false
        for _, ing in ipairs(line.ingredients) do
            if scc_set[tn.typed_name_to_variable_name(ing)] then hi = true; break end
        end
        if not hi and line.fuel_ingredient and scc_set[tn.typed_name_to_variable_name(line.fuel_ingredient)] then hi = true end
        if hi then
            local hp = false
            for _, prod in ipairs(line.products) do
                if scc_set[tn.typed_name_to_variable_name(prod)] then hp = true; break end
            end
            if not hp and line.fuel_burnt_result and scc_set[tn.typed_name_to_variable_name(line.fuel_burnt_result)] then hp = true end
            if hp then out[tn.typed_name_to_variable_name(line.recipe_typed_name)] = true end
        end
    end
    return out
end

local function internal_flow(x, internal_set)
    local s = 0
    for key in pairs(internal_set) do s = s + math.abs(x[key] or 0) end
    return s
end

local function target_relax(problem, x)
    local s = 0
    for key, p in pairs(problem.primals) do
        if p.kind == "elastic" then s = s + math.abs(x[key] or 0) end
    end
    return s
end

-- shortage value for one material (0 if absent).
local function shortage_of(problem, x, material)
    local s = 0
    for key, p in pairs(problem.primals) do
        if p.kind == "shortage_source" and p.material == material then s = s + math.abs(x[key] or 0) end
    end
    return s
end

-- AFTER state for one material under a weighted solve.
--   fab      : its import is eliminated (shortage ~0) and target not relaxed
--   import   : still imported (shortage > th)
--   collapse : import gone but target relaxed grew (factory shrank/abandoned)
--   unfin    : solve did not converge
local function after_state(state, problem, x, material, th, relax0)
    if state ~= "finished" then return "unfin", -1 end
    local short = shortage_of(problem, x, material)
    if short > th then return "import", short end
    local relax = target_relax(problem, x)
    if relax > relax0 + 1e-4 then return "collapse", short end
    return "fab", short
end

local COLS = { "label", "scc_size", "material", "n_active_sh", "base_shortage" }
for _, m in ipairs(MODES) do
    COLS[#COLS + 1] = "w_" .. m.key
    COLS[#COLS + 1] = "after_" .. m.key
end

local function process(constraints, lines, label, emit)
    local ok, prob = pcall(build_flat, constraints, lines)
    if not ok then return end
    local state, vars = solve(prob)
    if state ~= "finished" then return end
    local x0 = vars.x
    local th = ed.park_threshold(vars, prob.primals)
    local relax0 = target_relax(prob, x0)

    -- weights + weighted solves, one per mode (computed once per dump).
    local Wmode, Smode = {}, {}
    for _, m in ipairs(MODES) do
        local ok_w, res = pcall(mw.compute, lines, { allocation = m.allocation, combiner = m.combiner })
        local w = ok_w and res.weight or {}
        Wmode[m.key] = w
        local okb, p2 = pcall(build_weighted, constraints, lines, w, m.shortage_only)
        if okb then
            local s2, v2 = solve(p2)
            Smode[m.key] = { prob = p2, state = s2, x = (s2 == "finished" and v2.x or {}),
                th = (s2 == "finished" and ed.park_threshold(v2, p2.primals) or 1e-7),
                relax0 = relax0 }
        else
            Smode[m.key] = { state = "builderr" }
        end
    end

    local adj = mc.build_material_graph(lines)
    local sccs = mc.find_sccs(adj)

    for _, scc in ipairs(sccs) do
        if mc.is_cyclic_scc(scc, adj) then
            local scc_set = {}
            for _, m in ipairs(scc) do scc_set[m] = true end

            local active_sh, active_sh_mats = {}, {}
            for key, p in pairs(prob.primals) do
                if p.kind == "shortage_source" and p.material and scc_set[p.material] and (x0[key] or 0) > th then
                    active_sh[#active_sh + 1] = key
                    active_sh_mats[#active_sh_mats + 1] = p.material
                end
            end
            if #active_sh >= 1 then
                local internal_set = internal_recipes(lines, scc_set)
                local iflow0 = internal_flow(x0, internal_set)
                local self_sust = mc.is_self_sustaining(lines, scc)
                local fab = true
                for _, m in ipairs(active_sh_mats) do
                    if not mc.export_feasible(lines, m) then fab = false; break end
                end
                if self_sust and fab and iflow0 < 1e-6 then
                    local base_short = {}
                    for i, key in ipairs(active_sh) do base_short[active_sh_mats[i]] = x0[key] or 0 end
                    table.sort(active_sh_mats)
                    for _, material in ipairs(active_sh_mats) do
                        local row = {
                            label = label, scc_size = #scc, material = material,
                            n_active_sh = #active_sh, base_shortage = base_short[material],
                        }
                        for _, m in ipairs(MODES) do
                            local S = Smode[m.key]
                            local st, _ = after_state(S.state, S.prob, S.x, material, S.th or th, S.relax0 or relax0)
                            row["w_" .. m.key] = (Wmode[m.key] or {})[material]
                            row["after_" .. m.key] = st
                        end
                        emit(row)
                    end
                end
            end
        end
    end
end

-- ---- main -------------------------------------------------------------------
local out_path, manifest_path, files = nil, nil, {}
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
if out_path then out_file = assert(io.open(out_path, "w")); sink = function(s) out_file:write(s) end end

local function fmt(v)
    if v == nil then return "NA" end
    if type(v) == "number" then return string.format("%.6g", v) end
    return tostring(v)
end
sink("#" .. table.concat(COLS, "\t") .. "\n")
local function emit(r)
    local o = {}
    for _, k in ipairs(COLS) do o[#o + 1] = fmt(r[k]) end
    sink(table.concat(o, "\t") .. "\n")
end

for _, path in ipairs(files) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local label = "seed=" .. tostring(prob.meta and prob.meta.seed) ..
            "|" .. (path:match("([^/\\]+)%.lua$") or path)
        pcall(process, prob.constraints, prob.normalized_lines, label, emit)
    end
end

if out_file then out_file:close() end
