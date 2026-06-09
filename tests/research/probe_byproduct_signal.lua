---@diagnostic disable: undefined-global
-- Static byproduct-disposal signal vs MEASURED dEsc/qty (research, solve-free).
--
-- The substrate analysis found that on the flat baseline the import-vs-fabricate
-- flip threshold is ~ the byproduct-disposal mass the fabrication drags in per
-- unit (dEsc/qty, corr 0.98). But dEsc/qty was MEASURED by solving + flipping.
-- To wire a cost rule into create_problem we need a STATIC estimate computable
-- from recipe structure alone, before solving. This probe computes several such
-- structural proxies for each flip material and joins them to the measured
-- dEsc/qty (from flip_weight_full.tsv) so we can see whether any static signal
-- tracks it. No solving here -- pure structure read of the dumped lines.
--
-- Proxies (per material M, over the lines that PRODUCE M):
--   coprod_all    : sum over co-products p!=M of amount_p / amount_M
--                   (mass of other outputs per unit M; min & mean over producers)
--   coprod_uncons : same but only co-products that are NEVER an ingredient
--                   anywhere in the chain (pure dead-end byproducts -> sure dumps)
--
-- Usage (from repo root):
--   <lua> tests/research/probe_byproduct_signal.lua --manifest <list> --flip <flip_weight.tsv> --out <tsv>

require "tests/headless_env"

local problem_dump = require "tests/problem_dump"
local mc = require "solver/material_cycles"
local tn = require "manage/typed_name"

-- ---- load the measured flip table, key by (stem, material) ------------------
local function load_flip(path)
    local map, header = {}, nil
    for line in io.lines(path) do
        if line:sub(1, 1) == "#" then
            header = {}; local i = 1
            for f in (line:sub(2)):gmatch("[^\t]+") do header[f] = i; i = i + 1 end
        elseif line ~= "" and header then
            local c = {}
            for f in (line .. "\t"):gmatch("([^\t]*)\t") do c[#c + 1] = f end
            local function gv(n) return c[header[n]] end
            if tonumber(gv("n_active_sh")) == 1 and gv("fully_fabricated") == "yes" then
                local label = gv("label")
                local stem = label:match("|(.+)$") or label
                local mat = gv("material")
                local qty = tonumber(gv("base_shortage")) or 0
                local desc = (tonumber(gv("otheresc_at_flip")) or 0) - (tonumber(gv("otheresc_before")) or 0)
                map[stem .. "\0" .. mat] = {
                    flip_mult = tonumber(gv("flip_mult")),
                    desc_per_qty = (qty > 0) and (desc / qty) or -1,
                    w_amt_min = tonumber(gv("w_amt_min")),
                    unresolved = gv("unresolved"),
                }
            end
        end
    end
    return map
end

-- ---- structural proxies -----------------------------------------------------
-- products + burnt result of a line as (var, amount)
local function out_terms(line)
    local t = {}
    for _, p in ipairs(line.products) do t[#t + 1] = { var = tn.typed_name_to_variable_name(p), amount = p.amount_per_second } end
    if line.fuel_burnt_result then t[#t + 1] = { var = tn.typed_name_to_variable_name(line.fuel_burnt_result), amount = line.fuel_burnt_result.amount_per_second } end
    return t
end
local function in_terms(line)
    local t = {}
    for _, ing in ipairs(line.ingredients) do t[#t + 1] = { var = tn.typed_name_to_variable_name(ing), amount = ing.amount_per_second } end
    if line.fuel_ingredient then t[#t + 1] = { var = tn.typed_name_to_variable_name(line.fuel_ingredient), amount = line.fuel_ingredient.amount_per_second } end
    return t
end

-- consumed set: every material that is an ingredient (or fuel) of some line.
local function consumed_set(lines)
    local s = {}
    for _, line in ipairs(lines) do
        for _, t in ipairs(in_terms(line)) do s[t.var] = true end
    end
    return s
end

-- co-product mass ratio per unit M for the lines producing M; min & mean over
-- producers, both for ALL co-products and for UNCONSUMED-only co-products.
local function coprod_ratios(lines, M, consumed)
    local all, unc = {}, {}
    for _, line in ipairs(lines) do
        if line.is_source or line.is_sink then goto cont end
        local amt_M = nil
        for _, t in ipairs(out_terms(line)) do if t.var == M then amt_M = (amt_M or 0) + t.amount end end
        if amt_M and amt_M > 0 then
            local sa, su = 0, 0
            for _, t in ipairs(out_terms(line)) do
                if t.var ~= M then
                    sa = sa + t.amount
                    if not consumed[t.var] then su = su + t.amount end
                end
            end
            all[#all + 1] = sa / amt_M
            unc[#unc + 1] = su / amt_M
        end
        ::cont::
    end
    local function minmean(t)
        if #t == 0 then return nil, nil end
        local mn, sm = math.huge, 0
        for _, v in ipairs(t) do if v < mn then mn = v end; sm = sm + v end
        return mn, sm / #t
    end
    local a_min, a_mean = minmean(all)
    local u_min, u_mean = minmean(unc)
    return a_min, a_mean, u_min, u_mean
end

local COLS = { "label", "material", "flip_mult", "desc_per_qty", "w_amt_min",
    "coprod_all_min", "coprod_all_mean", "coprod_unc_min", "coprod_unc_mean" }

-- ---- main -------------------------------------------------------------------
local out_path, manifest_path, flip_path, files = nil, nil, nil, {}
do
    local i = 1
    while arg[i] do
        local a = arg[i]
        if a == "--out" then i = i + 1; out_path = arg[i]
        elseif a == "--manifest" then i = i + 1; manifest_path = arg[i]
        elseif a == "--flip" then i = i + 1; flip_path = arg[i]
        else files[#files + 1] = a end
        i = i + 1
    end
end
if manifest_path then
    for line in io.lines(manifest_path) do line = line:gsub("%s+$", ""); if line ~= "" then files[#files + 1] = line end end
end
assert(flip_path, "need --flip <flip_weight.tsv>")
local flip = load_flip(flip_path)

local sink = io.write
local out_file = nil
if out_path then out_file = assert(io.open(out_path, "w")); sink = function(s) out_file:write(s) end end
local function fmt(v) if v == nil then return "NA" end if type(v) == "number" then return string.format("%.6g", v) end return tostring(v) end
sink("#" .. table.concat(COLS, "\t") .. "\n")
local function emit(r) local o = {}; for _, k in ipairs(COLS) do o[#o + 1] = fmt(r[k]) end; sink(table.concat(o, "\t") .. "\n") end

for _, path in ipairs(files) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local stem = path:match("([^/\\]+)%.lua$") or path
        local lines = prob.normalized_lines
        -- only do the structural work if this dump has any flip material we measured.
        local consumed = nil
        for key, meas in pairs(flip) do
            local s, mat = key:match("^(.-)%z(.+)$")
            if s == stem then
                consumed = consumed or consumed_set(lines)
                local a_min, a_mean, u_min, u_mean = coprod_ratios(lines, mat, consumed)
                emit({
                    label = stem, material = mat,
                    flip_mult = meas.flip_mult, desc_per_qty = meas.desc_per_qty,
                    w_amt_min = meas.w_amt_min,
                    coprod_all_min = a_min, coprod_all_mean = a_mean,
                    coprod_unc_min = u_min, coprod_unc_mean = u_mean,
                })
            end
        end
    end
end
if out_file then out_file:close() end
