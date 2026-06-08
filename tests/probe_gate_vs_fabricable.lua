---@diagnostic disable: undefined-global
-- Gate-vs-fabricable cross-check (research, no verdict).
--
-- For every material that is shortage-active inside a cyclic SCC under the PURE
-- EXPERIMENT options (reachability_gating / deficit_seeding / catalyst_closure
-- all OFF), compare two independent "import-or-fabricate" signals:
--   * export_feasible (cone, mc.export_feasible): can the SCC net-produce a unit
--     of the material at some rate => FABRICABLE.
--   * what the SHIPPED solver (all three options ON) actually does with it:
--       ship-fabricate      : cycle's internal recipes run, no import of m
--       ship-import-cheap   : m supplied by |initial_source| (deficit-seeded)
--       ship-import-penalty : m still supplied by |shortage_source| (penalty)
--       ship-absent/relaxed : m not used / target relaxed
-- Disagreements are the point: gate forbids import of an unfabricable material
-- (would force impossible fabrication => collapse), or gate allows importing a
-- fabricable one (a missed cheat). RAW counts only.
--
-- Usage (from repo root):
--   <lua> tests/probe_gate_vs_fabricable.lua --manifest <list> --out <file.tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"
local mc = require "solver/material_cycles"
local tn = require "manage/typed_name"

local TOL, ITER = 1e-7, 800
local OPTS_EXP = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
local OPTS_SHIP = { deficit_seeding = true, catalyst_closure = true, reachability_gating = true }

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l, o) return create_problem.create_problem("gate", c, l, nil, o) end

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

-- find the primal value of a given kind for a material (0 if absent).
local function kind_value_for_material(problem, x, material, kind)
    local total, present = 0, false
    for key, p in pairs(problem.primals) do
        if p.kind == kind and p.material == material then
            total = total + math.abs(x[key] or 0)
            present = true
        end
    end
    return total, present
end

local function target_relax(problem, x)
    local s = 0
    for key, p in pairs(problem.primals) do
        if p.kind == "elastic" then s = s + math.abs(x[key] or 0) end
    end
    return s
end

local COLS = {
    "label", "scc_size", "material", "export_feasible",
    "ship_state", "ship_shortage", "ship_initial", "ship_internal_flow",
    "ship_shortage_present", "ship_target_relax",
}

local function process(constraints, lines, label, emit)
    local ok_e, ep = pcall(build, constraints, lines, OPTS_EXP)
    if not ok_e then return end
    local es, ev = solve(ep)
    if es ~= "finished" then return end
    local ex = ev.x
    local eth = ed.park_threshold(ev, ep.primals)

    -- shipped solve
    local ok_s, sp = pcall(build, constraints, lines, OPTS_SHIP)
    if not ok_s then return end
    local ss, sv = solve(sp)
    local sx = ss == "finished" and sv.x or {}
    local sth = ss == "finished" and ed.park_threshold(sv, sp.primals) or 1e-7
    local ship_relax = ss == "finished" and target_relax(sp, sx) or -1

    local adj = mc.build_material_graph(lines)
    local sccs = mc.find_sccs(adj)

    for _, scc in ipairs(sccs) do
        if mc.is_cyclic_scc(scc, adj) then
            local scc_set = {}
            for _, m in ipairs(scc) do scc_set[m] = true end
            local internal_set = internal_recipes(lines, scc_set)

            -- active-shortage materials under the EXPERIMENT solve
            local active = {}
            for key, p in pairs(ep.primals) do
                if p.kind == "shortage_source" and p.material and scc_set[p.material] and (ex[key] or 0) > eth then
                    active[p.material] = true
                end
            end

            for material in pairs(active) do
                local fab = mc.export_feasible(lines, material)
                -- ship behavior for this material
                local ship_state, ship_short, ship_init, ship_iflow, short_present
                if ss ~= "finished" then
                    ship_state = "ship-" .. tostring(ss)
                    ship_short, ship_init, ship_iflow, short_present = -1, -1, -1, false
                else
                    ship_short, short_present = kind_value_for_material(sp, sx, material, "shortage_source")
                    ship_init = kind_value_for_material(sp, sx, material, "initial_source")
                    ship_iflow = 0
                    for key in pairs(internal_set) do ship_iflow = ship_iflow + math.abs(sx[key] or 0) end
                    if ship_short > sth then
                        ship_state = "ship-import-penalty"
                    elseif ship_init > sth then
                        ship_state = "ship-import-cheap"
                    elseif ship_iflow > sth then
                        ship_state = "ship-fabricate"
                    else
                        ship_state = "ship-absent"
                    end
                end
                emit({
                    label = label, scc_size = #scc, material = material,
                    export_feasible = tostring(fab),
                    ship_state = ship_state, ship_shortage = ship_short,
                    ship_initial = ship_init, ship_internal_flow = ship_iflow,
                    ship_shortage_present = tostring(short_present),
                    ship_target_relax = ship_relax,
                })
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

local function fmt(v) if type(v) == "number" then return string.format("%.6g", v) end return tostring(v) end
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
