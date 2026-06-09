---@diagnostic disable: undefined-global
-- Direction-of-tilt probe (research, no verdict).
--
-- The flip-ladder (probe_fabricate_flip) measured only ONE direction: raise the
-- importing |shortage_source| UP from the flat 1024 tier until fabrication wins.
-- It never asked whether that direction is forced, what the reference point is,
-- or whether a SINK lever flips the same cheat in the OPPOSITE direction. This
-- probe answers that on the same avoidable-cheat population.
--
-- For material M (self-sustaining cyclic SCC that CAN fabricate its shortage
-- material yet at baseline imports it via |shortage_source| while running none of
-- the cycle), the import-vs-fabricate inequality is, per unit:
--     import = shortage_source(1024)   vs   fabricate = dRaw*1 + dEsc*1024
-- (dEsc = byproduct dumps via surplus_sink + secondary deficits, the dominant
-- term per the flip-decomposition work). Levers that close the gap toward
-- fabricate, and the direction each must move:
--   sh_up  : SCC active shortage  x m   (import side UP)        [reference = flip-ladder]
--   su_dn  : surplus_sink         x 1/m (fabricate dump cheaper, DOMINANT term)
--   ini_dn : initial_source       x 1/m (raw cheaper, dRaw is tiny -> expect weak)
-- and the reverse directions, which should NOT flip (they push toward import,
-- and baseline already imports):
--   sh_dn  : SCC active shortage  x 1/m
--   su_up  : surplus_sink         x m
--
-- For each lever we record the smallest ladder m that flips (import eliminated,
-- shortage -> ~0) with the target NOT relaxed (fully fabricated), else -1.
-- su_dn comes in two scopings: GLOBAL (all surplus_sink) and BP (only the
-- surplus_sinks that M's fabrication activates, captured at the sh_up flip) --
-- BP isolates M's own fabricate-side lever from the global confound.
--
-- Key predictions to test:
--   * sh_up flips, su_dn flips, ini_dn weak/none  (direction is structural, not random)
--   * sh_dn / su_up never flip                    (reverse direction is inert)
--   * DUALITY: su_dn_bp flip m  ~=  sh_up flip M  (surplus x 1/M is the mirror of
--     shortage x M -- same number, opposite lever -- confirming pivot = 1024 tier,
--     source UP vs sink DOWN)
--
-- Single-shot (run_corpus): one row per avoidable-cheat material, starts 'seed='.
-- Usage:
--   pwsh tests/run_corpus.ps1 -Driver tests/probe_direction_map.lua -Collect '^seed=' -Out <tsv>

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
local LADDER = { 2, 4, 8, 16, 32, 64, 128, 256, 1024, 4096 }

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("dir", c, l, nil, OPTS) end

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

-- sum of the chosen active-shortage keys
local function shortage_of(x, keys)
    local s = 0
    for _, k in ipairs(keys) do s = s + (x[k] or 0) end
    return s
end

-- Try a lever (a closure that mutates p.primals costs) up the ladder; return the
-- smallest m that flips (active shortage -> <= th, target not relaxed beyond
-- relax0), as { m, fully } where fully = target kept. invert=true reads the
-- ladder as x(1/m) for "down" levers. Returns m=-1 if nothing flips.
local function ladder_flip(constraints, lines, active_sh, th, relax0, apply, invert)
    for _, base_m in ipairs(LADDER) do
        local m = invert and (1 / base_m) or base_m
        local okp, p2 = pcall(build, constraints, lines)
        if okp then
            apply(p2, m)
            local s2, v2 = solve(p2)
            if s2 == "finished" then
                local short2 = shortage_of(v2.x, active_sh)
                if short2 <= th then
                    local relax2 = target_relax(p2, v2.x)
                    local fully = relax2 <= relax0 + 1e-4
                    return base_m, fully, v2.x, p2
                end
            end
        end
    end
    return -1, false, nil, nil
end

local COLS = {
    "label", "scc_size", "material", "n_active_sh", "base_shortage",
    "sh_up", "sh_up_fully",
    "su_dn_g", "su_dn_g_fully",
    "su_dn_bp", "su_dn_bp_fully", "n_bp",
    "ini_dn", "ini_dn_fully",
    "sh_dn", "su_up", -- reverse-direction sanity (expect -1)
}

local function process(constraints, lines, label, emit)
    local ok, prob = pcall(build, constraints, lines)
    if not ok then return end
    local state, vars = solve(prob)
    if state ~= "finished" then return end
    local x0 = vars.x
    local th = ed.park_threshold(vars, prob.primals)
    local relax0 = target_relax(prob, x0)

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
                    local active_set = {}
                    for _, k in ipairs(active_sh) do active_set[k] = true end
                    local base_short = shortage_of(x0, active_sh)

                    -- sh_up: raise the SCC active shortage (the reference lever).
                    local sh_up, sh_up_fully, x_flip = ladder_flip(constraints, lines, active_sh, th, relax0,
                        function(p, m)
                            for _, k in ipairs(active_sh) do p.primals[k].cost = ELASTIC_COST * m end
                        end, false)

                    -- bp_set = surplus_sinks M's fabrication activates, captured at
                    -- the sh_up flip (the dEsc byproduct dump set).
                    local bp_set = {}
                    local n_bp = 0
                    if x_flip then
                        for key, p in pairs(prob.primals) do
                            if p.kind == "surplus_sink" and (x_flip[key] or 0) > th then
                                bp_set[key] = true; n_bp = n_bp + 1
                            end
                        end
                    end

                    -- su_dn_g: lower ALL surplus_sink (global fabricate-side lever).
                    local su_dn_g, su_dn_g_fully = ladder_flip(constraints, lines, active_sh, th, relax0,
                        function(p, m)
                            for _, pp in pairs(p.primals) do
                                if pp.kind == "surplus_sink" then pp.cost = pp.cost * m end
                            end
                        end, true)

                    -- su_dn_bp: lower ONLY M's byproduct surplus_sinks (isolated).
                    local su_dn_bp, su_dn_bp_fully = -1, false
                    if n_bp > 0 then
                        su_dn_bp, su_dn_bp_fully = ladder_flip(constraints, lines, active_sh, th, relax0,
                            function(p, m)
                                for key, pp in pairs(p.primals) do
                                    if bp_set[key] then pp.cost = pp.cost * m end
                                end
                            end, true)
                    end

                    -- ini_dn: lower ALL initial_source (raw-cheaper lever).
                    local ini_dn, ini_dn_fully = ladder_flip(constraints, lines, active_sh, th, relax0,
                        function(p, m)
                            for _, pp in pairs(p.primals) do
                                if pp.kind == "initial_source" then pp.cost = pp.cost * m end
                            end
                        end, true)

                    -- reverse-direction sanity (expect -1)
                    local sh_dn = ladder_flip(constraints, lines, active_sh, th, relax0,
                        function(p, m)
                            for _, k in ipairs(active_sh) do p.primals[k].cost = ELASTIC_COST * m end
                        end, true)
                    local su_up = ladder_flip(constraints, lines, active_sh, th, relax0,
                        function(p, m)
                            for _, pp in pairs(p.primals) do
                                if pp.kind == "surplus_sink" then pp.cost = pp.cost * m end
                            end
                        end, false)

                    table.sort(active_sh_mats)
                    emit({
                        label = label, scc_size = #scc,
                        material = table.concat(active_sh_mats, ","),
                        n_active_sh = #active_sh, base_shortage = base_short,
                        sh_up = sh_up, sh_up_fully = sh_up_fully and "yes" or "no",
                        su_dn_g = su_dn_g, su_dn_g_fully = su_dn_g_fully and "yes" or "no",
                        su_dn_bp = su_dn_bp, su_dn_bp_fully = su_dn_bp_fully and "yes" or "no", n_bp = n_bp,
                        ini_dn = ini_dn, ini_dn_fully = ini_dn_fully and "yes" or "no",
                        sh_dn = sh_dn, su_up = su_up,
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
