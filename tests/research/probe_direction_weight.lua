---@diagnostic disable: undefined-global
-- Direction-of-tilt under material_weight (research, no verdict).
--
-- The no-w direction map (probe_direction_map) found: shortage_source flips UP
-- (universal 74/74), surplus_sink flips DOWN (partial), reverse directions inert,
-- pivot = the flat 1024 tier. This probe asks whether the inverse-w wiring
-- (source x 1/w, sink x w, amt_min mode) -- which shifts the pivot per material
-- by its embodied weight -- changes that map: does w PRE-PAY the flip for the
-- right materials (cheat already gone at the w-tilted baseline), how many fresh
-- collapses (target abandonment) does the w-tilt cause, and for the survivors is
-- the up/down direction still the same?
--
-- Population = the SAME avoidable-cheat materials the no-w map qualifies (active
-- |shortage_source| in a self-sustaining, fabricable, idle cyclic SCC), detected
-- on the UN-tilted baseline so the two runs compare like for like. For each:
--   no-w : sh_up (raise SCC shortage), su_dn_bp (lower M's byproduct dumps)  [reference]
--   w    : apply inverse-w tilt to every escape at baseline, then
--            * relax_w  -- did the w-tilt itself abandon target for this problem (collapse)?
--            * cheat_w  -- does M still import at the w baseline (cheat survives)?
--            * sh_up_w  -- residual shortage-up mult on top of the w tilt (1 = pre-flipped, -1 = can't)
--            * su_dn_bp_w -- residual surplus-down mult on M's byproducts
--   w(M) value + is_root + unresolved, for interpretation.
--
-- inverse-w wiring (the direction established earlier): high-w (expensive/unresolved
-- catalyst) -> import kept cheap; low-w (cheap to make) -> import expensive = fabricate.
--
-- Single-shot (run_corpus): one row per avoidable-cheat material, starts 'seed='.
-- Usage:
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_direction_weight.lua -Collect '^seed=' -Out <tsv>

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
local LADDER = { 2, 4, 8, 16, 32, 64, 128, 256, 1024, 4096 }
-- weight mode, default amt_min; override via CP_WMODE = amt_min|amt_mean|main_min|main_mean
local WMODES = {
    amt_min = { allocation = "amount", combiner = "min" },
    amt_mean = { allocation = "amount", combiner = "mean" },
    main_min = { allocation = "main", combiner = "min" },
    main_mean = { allocation = "main", combiner = "mean" },
}
local WMODE = WMODES[os.getenv("CP_WMODE") or "amt_min"] or WMODES.amt_min

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("dirw", c, l, nil, OPTS) end

-- Apply the inverse-w tilt to every escape cost in place: source x 1/w, sink x w.
-- weight[material] defaults to 1 when absent (root / unweighted).
local function apply_w(problem, weight)
    for _, p in pairs(problem.primals) do
        local w = (p.material and weight[p.material]) or 1
        if w and w > 0 then
            if p.kind == "shortage_source" or p.kind == "initial_source" then
                p.cost = p.cost / w
            elseif p.kind == "surplus_sink" then
                p.cost = p.cost * w
            end
        end
    end
end

local R = require "tests/research/research_lib"
local internal_recipes = R.internal_recipes
local internal_flow = R.internal_flow
local target_relax = R.target_relax
local shortage_of = R.shortage_of_keys

-- Ladder a lever (apply mutates costs) to flip; w_pre applies the w tilt first
-- when tilt=true. invert reads ladder as x1/m. Returns smallest base_m flipping,
-- with target not relaxed beyond relax_ref; else -1.
local function ladder_flip(constraints, lines, active_sh, th, relax_ref, apply, invert, tilt, weight)
    for _, base_m in ipairs(LADDER) do
        local m = invert and (1 / base_m) or base_m
        local okp, p2 = pcall(build, constraints, lines)
        if okp then
            if tilt then apply_w(p2, weight) end
            apply(p2, m)
            local s2, v2 = solve(p2)
            if s2 == "finished" then
                if shortage_of(v2.x, active_sh) <= th then
                    if target_relax(p2, v2.x) <= relax_ref + 1e-4 then return base_m end
                end
            end
        end
    end
    return -1
end

local COLS = {
    "label", "scc_size", "material", "base_shortage",
    "w", "is_root", "unresolved",
    "sh_up", "su_dn_bp", "n_bp",                 -- no-w reference
    "relax_w_grew", "cheat_w", "sh_up_w", "su_dn_bp_w", -- w outcomes
}

local function process(constraints, lines, label, emit)
    local ok, prob = pcall(build, constraints, lines)
    if not ok then return end
    local state, vars = solve(prob)
    if state ~= "finished" then return end
    local x0 = vars.x
    local th = ed.park_threshold(vars, prob.primals)
    local relax0 = target_relax(prob, x0)

    -- weights (amt_min)
    local weight, isroot, unres = {}, {}, {}
    local ok_w, res = pcall(mw.compute, lines, WMODE)
    if ok_w then weight, isroot, unres = res.weight, res.is_root, res.unresolved end

    -- w-tilted baseline (solved once; reused for cheat_w / relax_w detection)
    local wx, w_relax_grew = nil, false
    do
        local okw, pw = pcall(build, constraints, lines)
        if okw then
            apply_w(pw, weight)
            local sw, vw = solve(pw)
            if sw == "finished" then
                wx = vw.x
                w_relax_grew = target_relax(pw, vw.x) > relax0 + 1e-4
            end
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
                    local base_short = shortage_of(x0, active_sh)

                    -- no-w sh_up + capture byproduct dump set at the flip
                    local bp_set, n_bp = {}, 0
                    local sh_up = -1
                    for _, base_m in ipairs(LADDER) do
                        local okp, p2 = pcall(build, constraints, lines)
                        if okp then
                            for _, k in ipairs(active_sh) do p2.primals[k].cost = ELASTIC_COST * base_m end
                            local s2, v2 = solve(p2)
                            if s2 == "finished" and shortage_of(v2.x, active_sh) <= th then
                                if target_relax(p2, v2.x) <= relax0 + 1e-4 then sh_up = base_m end
                                for key, p in pairs(prob.primals) do
                                    if p.kind == "surplus_sink" and (v2.x[key] or 0) > th then
                                        bp_set[key] = true; n_bp = n_bp + 1
                                    end
                                end
                                break
                            end
                        end
                    end

                    -- no-w su_dn_bp (lower M's byproduct dumps only)
                    local su_dn_bp = -1
                    if n_bp > 0 then
                        su_dn_bp = ladder_flip(constraints, lines, active_sh, th, relax0,
                            function(p, m) for key, pp in pairs(p.primals) do if bp_set[key] then pp.cost = pp.cost * m end end end,
                            true, false, weight)
                    end

                    -- w outcomes: does the cheat survive the w baseline?
                    local cheat_w = "na"
                    if wx then
                        cheat_w = (shortage_of(wx, active_sh) > th) and "yes" or "no"
                    end

                    -- residual levers ON TOP of the w tilt
                    local sh_up_w, su_dn_bp_w = -1, -1
                    if cheat_w == "no" then
                        sh_up_w, su_dn_bp_w = 1, 1 -- pre-flipped by w alone, no lever needed
                    elseif cheat_w == "yes" then
                        sh_up_w = ladder_flip(constraints, lines, active_sh, th, relax0,
                            function(p, m) for _, k in ipairs(active_sh) do p.primals[k].cost = p.primals[k].cost * m end end,
                            false, true, weight)
                        if n_bp > 0 then
                            su_dn_bp_w = ladder_flip(constraints, lines, active_sh, th, relax0,
                                function(p, m) for key, pp in pairs(p.primals) do if bp_set[key] then pp.cost = pp.cost * m end end end,
                                true, true, weight)
                        end
                    end

                    table.sort(active_sh_mats)
                    local mat1 = active_sh_mats[1]
                    emit({
                        label = label, scc_size = #scc,
                        material = table.concat(active_sh_mats, ","),
                        base_shortage = base_short,
                        w = (weight[mat1] or 1), is_root = tostring(isroot[mat1] == true),
                        unresolved = tostring(unres[mat1] == true),
                        sh_up = sh_up, su_dn_bp = su_dn_bp, n_bp = n_bp,
                        relax_w_grew = w_relax_grew and "yes" or "no",
                        cheat_w = cheat_w, sh_up_w = sh_up_w, su_dn_bp_w = su_dn_bp_w,
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
