---@diagnostic disable: undefined-global
-- Import-vs-fabricate flip probe (research, no verdict).
--
-- Targets the avoidable-cheat population the cycle-elastic probe isolated: a
-- cyclic SCC that is self-sustaining AND can export its shortage material
-- (mc.export_feasible) -- i.e. the cycle CAN fabricate it -- yet at baseline the
-- LP runs none of the cycle (internal recipe flow ~ 0) and imports the material
-- via |shortage_source| instead. For each such case, raise ONLY that shortage's
-- cost up a ladder and record the multiplier (if any) at which the cycle starts
-- running (internal flow > threshold), whether the shortage then drops to ~0
-- (fully fabricated) and whether the target had to relax. Tests whether cost
-- alone flips the cheat to the correct fabrication. RAW numbers only.
--
-- Usage (from repo root):
--   <lua> tests/probe_fabricate_flip.lua --manifest <list> --out <file.tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"
local mc = require "solver/material_cycles"
local tn = require "manage/typed_name"

local TOL, ITER = 1e-7, 800
local OPTS = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
local ELASTIC_COST = 2 ^ 10
local LADDER = { 2, 4, 8, 16, 32, 64, 128, 256, 1024, 4096, 16384, 65536 }

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("flip", c, l, nil, OPTS) end

-- recipes internal to the SCC (>=1 ingredient AND >=1 product in S).
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

local function internal_flow(problem, x, internal_set)
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

local function rsum(problem, x)
    local s = 0
    for key in pairs(problem.primals) do
        if ed.is_recipe(key, problem.primals) then s = s + math.abs(x[key] or 0) end
    end
    return s
end

-- Sum |x| over initial_source (raws, cost ~1).
local function import_sum(problem, x)
    local s = 0
    for key, p in pairs(problem.primals) do
        if p.kind == "initial_source" then s = s + math.abs(x[key] or 0) end
    end
    return s
end

-- Sum |x| over escape-priced boundary (surplus_sink + shortage_source), each at
-- the flat 1024 tier, EXCLUDING the shortage keys we are raising (so this is the
-- "other escapes" the fabrication path drags in: byproduct dumps + secondary
-- deficits).
local function other_escape_sum(problem, x, exclude)
    local s = 0
    for key, p in pairs(problem.primals) do
        if (p.kind == "surplus_sink" or p.kind == "shortage_source") and not exclude[key] then
            s = s + math.abs(x[key] or 0)
        end
    end
    return s
end

local COLS = {
    "label", "scc_size", "material", "n_active_sh", "base_shortage",
    "flip_mult", "internal_flow_at_flip", "shortage_at_flip", "fully_fabricated",
    "relax_before", "relax_at_flip", "Rsum_before", "Rsum_at_flip",
    "import_before", "import_at_flip", "otheresc_before", "otheresc_at_flip",
}

local function process(constraints, lines, label, emit)
    local ok, prob = pcall(build, constraints, lines)
    if not ok then return end
    local state, vars = solve(prob)
    if state ~= "finished" then return end
    local x0 = vars.x
    local th = ed.park_threshold(vars, prob.primals)

    local adj = mc.build_material_graph(lines)
    local sccs = mc.find_sccs(adj)

    for _, scc in ipairs(sccs) do
        if mc.is_cyclic_scc(scc, adj) then
            local scc_set = {}
            for _, m in ipairs(scc) do scc_set[m] = true end

            -- active shortage materials in S
            local active_sh = {}     -- keys
            local active_sh_mats = {} -- materials
            for key, p in pairs(prob.primals) do
                if p.kind == "shortage_source" and p.material and scc_set[p.material] and (x0[key] or 0) > th then
                    active_sh[#active_sh + 1] = key
                    active_sh_mats[#active_sh_mats + 1] = p.material
                end
            end
            if #active_sh >= 1 then
                local internal_set = internal_recipes(lines, scc_set)
                local iflow0 = internal_flow(prob, x0, internal_set)
                local self_sust = mc.is_self_sustaining(lines, scc)
                -- fabricable iff every active shortage material can be exported
                local fab = true
                for _, m in ipairs(active_sh_mats) do
                    if not mc.export_feasible(lines, m) then fab = false; break end
                end
                -- qualify: self-sustaining, fabricable, idle (pure import)
                if self_sust and fab and iflow0 < 1e-6 then
                    local base_short = 0
                    local exclude = {}
                    for _, key in ipairs(active_sh) do base_short = base_short + (x0[key] or 0); exclude[key] = true end
                    local relax0 = target_relax(prob, x0)
                    local rsum0 = rsum(prob, x0)
                    local import0 = import_sum(prob, x0)
                    local esc0 = other_escape_sum(prob, x0, exclude)
                    local import_f, esc_f = -1, -1

                    -- Flip = the import (shortage) is eliminated. Trigger on the
                    -- shortage dropping to ~0 (NOT on internal-recipe flow, which
                    -- misses fabrication via an EXTERNAL producer -- limestone
                    -- gets made by py-sodium-hydroxide, an out-of-SCC recipe).
                    -- At that point relax tells us fabricated (relax flat) vs
                    -- target-abandoned (relax grew); internal_flow tells us
                    -- internal-cycle vs external-producer fabrication.
                    local flip_mult, iflow_f, short_f, relax_f, rsum_f = -1, -1, -1, -1, -1
                    for _, mult in ipairs(LADDER) do
                        local okp, p2 = pcall(build, constraints, lines)
                        if okp then
                            for _, key in ipairs(active_sh) do p2.primals[key].cost = ELASTIC_COST * mult end
                            local s2, v2 = solve(p2)
                            if s2 == "finished" then
                                local x2 = v2.x
                                local short2 = 0
                                for _, key in ipairs(active_sh) do short2 = short2 + (x2[key] or 0) end
                                if short2 <= th then
                                    flip_mult = mult
                                    short_f = short2
                                    iflow_f = internal_flow(p2, x2, internal_set)
                                    relax_f = target_relax(p2, x2)
                                    rsum_f = rsum(p2, x2)
                                    import_f = import_sum(p2, x2)
                                    esc_f = other_escape_sum(p2, x2, exclude)
                                    break
                                end
                            end
                        end
                    end

                    table.sort(active_sh_mats)
                    -- fabricated (target kept) vs abandoned: relax did not grow
                    local fully = (flip_mult > 0 and relax_f <= relax0 + 1e-4) and "yes" or "no"
                    emit({
                        label = label, scc_size = #scc,
                        material = table.concat(active_sh_mats, ","),
                        n_active_sh = #active_sh, base_shortage = base_short,
                        flip_mult = flip_mult, internal_flow_at_flip = iflow_f,
                        shortage_at_flip = short_f, fully_fabricated = fully,
                        relax_before = relax0, relax_at_flip = relax_f,
                        Rsum_before = rsum0, Rsum_at_flip = rsum_f,
                        import_before = import0, import_at_flip = import_f,
                        otheresc_before = esc0, otheresc_at_flip = esc_f,
                    })
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
