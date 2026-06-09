---@diagnostic disable: undefined-global
-- Import-vs-fabricate flip threshold vs per-material embodied weight (research).
--
-- Joins the flip probe (probe_fabricate_flip) with solver/material_weights: for
-- every avoidable-cheat material (self-sustaining cyclic SCC that CAN fabricate
-- its shortage material via mc.export_feasible, yet at baseline imports it via
-- |shortage_source| while running none of the cycle), record both:
--   * flip_mult M -- the |shortage_source| cost multiplier (over the flat 1024
--     tier) at which the import is eliminated (fabrication wins). C_fab ~ 1024*M.
--   * w(material) under each of the four material_weights modes
--     {allocation=amount|main} x {combiner=min|mean}.
-- The question: does w(M) track the flip threshold, and which mode tracks it
-- best -- i.e. would pricing the escape at 1024*w(M) collapse the ~64x spread of
-- M across materials into a uniform threshold? RAW numbers only, one row per
-- active-shortage material of a flipping SCC.
--
-- Usage (from repo root):
--   <lua> tests/research/probe_flip_vs_weight.lua --manifest <list> --out <file.tsv>

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
local LADDER = { 2, 4, 8, 16, 32, 64, 128, 256, 1024, 4096, 16384, 65536 }

-- The four material_weights modes (allocation x combiner).
local MODES = {
    { key = "amt_min",  allocation = "amount", combiner = "min" },
    { key = "amt_mean", allocation = "amount", combiner = "mean" },
    { key = "main_min", allocation = "main",   combiner = "min" },
    { key = "main_mean",allocation = "main",   combiner = "mean" },
}

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("flipw", c, l, nil, OPTS) end

local R = require "tests/research/research_lib"
local internal_recipes = R.internal_recipes
local internal_flow = R.internal_flow
local target_relax = R.target_relax
local other_escape_sum = R.other_escape_sum

local COLS = {
    "label", "scc_size", "material", "n_active_sh",
    "base_shortage", "flip_mult", "fully_fabricated",
    "otheresc_before", "otheresc_at_flip",
    "is_root", "unresolved",
    "w_amt_min", "w_amt_mean", "w_main_min", "w_main_mean",
}

local function process(constraints, lines, label, emit)
    local ok, prob = pcall(build, constraints, lines)
    if not ok then return end
    local state, vars = solve(prob)
    if state ~= "finished" then return end
    local x0 = vars.x
    local th = ed.park_threshold(vars, prob.primals)

    -- Per-chain embodied weights under all four modes (computed once).
    local W, ROOT, UNRES = {}, {}, {}
    for _, m in ipairs(MODES) do
        local ok_w, res = pcall(mw.compute, lines, { allocation = m.allocation, combiner = m.combiner })
        if ok_w then
            W[m.key] = res.weight
            ROOT[m.key] = res.is_root
            UNRES[m.key] = res.unresolved
        else
            W[m.key] = {}
            ROOT[m.key] = {}
            UNRES[m.key] = {}
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
                -- qualify: self-sustaining, fabricable, idle (pure import)
                if self_sust and fab and iflow0 < 1e-6 then
                    local exclude = {}
                    local base_short = {}
                    for i, key in ipairs(active_sh) do
                        exclude[key] = true
                        base_short[active_sh_mats[i]] = x0[key] or 0
                    end
                    local esc0 = other_escape_sum(prob, x0, exclude)

                    -- Ladder: raise ALL active shortage costs together; flip = the
                    -- import (shortage) is eliminated (shortage drops to ~0).
                    local flip_mult, relax_f, esc_f = -1, -1, -1
                    local relax0 = target_relax(prob, x0)
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
                                    relax_f = target_relax(p2, x2)
                                    esc_f = other_escape_sum(p2, x2, exclude)
                                    break
                                end
                            end
                        end
                    end
                    local fully = (flip_mult > 0 and relax_f <= relax0 + 1e-4) and "yes" or "no"

                    -- One row per active-shortage material, carrying the SCC's
                    -- joint flip_mult plus that material's weight under each mode.
                    table.sort(active_sh_mats)
                    for _, material in ipairs(active_sh_mats) do
                        emit({
                            label = label, scc_size = #scc, material = material,
                            n_active_sh = #active_sh,
                            base_shortage = base_short[material],
                            flip_mult = flip_mult, fully_fabricated = fully,
                            otheresc_before = esc0, otheresc_at_flip = esc_f,
                            is_root = tostring(ROOT.amt_min[material] == true),
                            unresolved = tostring(UNRES.amt_min[material] == true),
                            w_amt_min = W.amt_min[material],
                            w_amt_mean = W.amt_mean[material],
                            w_main_min = W.main_min[material],
                            w_main_mean = W.main_mean[material],
                        })
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
