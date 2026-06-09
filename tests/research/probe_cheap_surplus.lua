---@diagnostic disable: undefined-global
-- Cheap-surplus (byproduct-disposal) test on the flat substrate (research).
--
-- The substrate analysis said the import-vs-fabricate flip threshold ~ the
-- byproduct-disposal mass the fabrication drags in (dEsc/qty). That signal is a
-- solve-output, not a static recipe property (probe_byproduct_signal: local
-- proxy corr ~0). The DUAL of raising a material's import cost to its dEsc is to
-- lower the PRICE OF DISPOSAL globally: if "byproduct disposal is bookkeeping,
-- not real economic cost", a cheap surplus_sink makes fabrication beat the import
-- for every raw-reachable material WITHOUT any per-material signal.
--
-- For each avoidable-import material (self-sustaining cyclic SCC, fabricable,
-- imports at flat baseline) this re-solves with surplus_cost_fn = S for a ladder
-- of global surplus prices S and records whether the material fabricates,
-- still imports, or collapses (target relaxed). It also records the dump's TOTAL
-- surplus mass at each S vs baseline -- the over-dump side effect (the factory
-- shedding free byproduct everywhere), which is the cost of this lever.
--
-- Single-shot (run_corpus contract): `lua probe_cheap_surplus.lua <onefile>`
-- prints one row per active-shortage material. Rows start with the label so
-- `-Collect '^seed='` drops the header.
--
-- Usage:
--   pwsh tests/run_corpus.ps1 -Driver tests/research/probe_cheap_surplus.lua -Collect '^seed=' -Out <tsv>
--   <lua> tests/research/probe_cheap_surplus.lua --manifest <list> --out <tsv>

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
-- Descending global surplus prices. Flat baseline is 1024; flip needs
-- S < 1024/flip_mult, and flip_mult ranges 2..64 => threshold S in [16,512].
local LADDER = { 512, 128, 32, 8, 2 }

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build_flat(c, l) return create_problem.create_problem("cs", c, l, nil, OPTS) end
local function build_surplus(c, l, S)
    local o = {}; for k, v in pairs(OPTS) do o[k] = v end
    o.surplus_cost_fn = function(_) return S end
    return create_problem.create_problem("cs", c, l, nil, o)
end

local R = require "tests/research/research_lib"
local internal_recipes = R.internal_recipes
local internal_flow = R.internal_flow
local target_relax = R.target_relax
local function surplus_total(p, x) local s = 0; for k, pr in pairs(p.primals) do if pr.kind == "surplus_sink" then s = s + math.abs(x[k] or 0) end end; return s end
local shortage_of = R.shortage_of_material

local COLS = { "label", "scc_size", "material", "n_active_sh", "base_shortage", "surplus0" }
for _, S in ipairs(LADDER) do COLS[#COLS + 1] = "after_S" .. S end
for _, S in ipairs(LADDER) do COLS[#COLS + 1] = "gsurp_S" .. S end

local function after_state(state, p, x, m, th, relax0)
    if state ~= "finished" then return "unfin" end
    if shortage_of(p, x, m) > th then return "import" end
    if target_relax(p, x) > relax0 + 1e-4 then return "collapse" end
    return "fab"
end

local function process(constraints, lines, label, emit)
    local ok, prob = pcall(build_flat, constraints, lines)
    if not ok then return end
    local st, vr = solve(prob); if st ~= "finished" then return end
    local x0, th = vr.x, ed.park_threshold(vr, prob.primals)
    local relax0 = target_relax(prob, x0)
    local surp0 = surplus_total(prob, x0)

    -- surplus-priced solves (one per S), computed once per dump.
    local Sres = {}
    for _, S in ipairs(LADDER) do
        local okb, p2 = pcall(build_surplus, constraints, lines, S)
        if okb then
            local s2, v2 = solve(p2)
            Sres[S] = { prob = p2, state = s2, x = (s2 == "finished" and v2.x or {}),
                th = (s2 == "finished" and ed.park_threshold(v2, p2.primals) or 1e-7),
                gsurp = (s2 == "finished" and surplus_total(p2, v2.x) or -1) }
        else
            Sres[S] = { state = "builderr", gsurp = -1 }
        end
    end

    local adj = mc.build_material_graph(lines)
    for _, scc in ipairs(mc.find_sccs(adj)) do
        if mc.is_cyclic_scc(scc, adj) then
            local scc_set = {}; for _, m in ipairs(scc) do scc_set[m] = true end
            local active, mats = {}, {}
            for key, p in pairs(prob.primals) do
                if p.kind == "shortage_source" and p.material and scc_set[p.material] and (x0[key] or 0) > th then
                    active[#active + 1] = p.material; mats[p.material] = key
                end
            end
            if #active >= 1 then
                local iset = internal_recipes(lines, scc_set)
                if mc.is_self_sustaining(lines, scc) and internal_flow(x0, iset) < 1e-6 then
                    local fab = true
                    for _, m in ipairs(active) do if not mc.export_feasible(lines, m) then fab = false; break end end
                    if fab then
                        table.sort(active)
                        for _, m in ipairs(active) do
                            local row = { label = label, scc_size = #scc, material = m,
                                n_active_sh = #active, base_shortage = x0[mats[m]] or 0, surplus0 = surp0 }
                            for _, S in ipairs(LADDER) do
                                local R = Sres[S]
                                row["after_S" .. S] = after_state(R.state, R.prob, R.x, m, R.th or th, relax0)
                                row["gsurp_S" .. S] = R.gsurp
                            end
                            emit(row)
                        end
                    end
                end
            end
        end
    end
end

-- ---- main -------------------------------------------------------------------
local out_path, manifest_path, files = nil, nil, {}
do local i = 1; while arg[i] do local a = arg[i]
    if a == "--out" then i = i + 1; out_path = arg[i]
    elseif a == "--manifest" then i = i + 1; manifest_path = arg[i]
    else files[#files + 1] = a end; i = i + 1 end end
if manifest_path then for line in io.lines(manifest_path) do line = line:gsub("%s+$", ""); if line ~= "" then files[#files + 1] = line end end end

local sink = io.write; local out_file = nil
if out_path then out_file = assert(io.open(out_path, "w")); sink = function(s) out_file:write(s) end end
local function fmt(v) if v == nil then return "NA" end if type(v) == "number" then return string.format("%.6g", v) end return tostring(v) end
if out_path then sink("#" .. table.concat(COLS, "\t") .. "\n") end  -- single-shot: no header (run_corpus collects ^seed=)
local function emit(r) local o = {}; for _, k in ipairs(COLS) do o[#o + 1] = fmt(r[k]) end; sink(table.concat(o, "\t") .. "\n") end

for _, path in ipairs(files) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local label = "seed=" .. tostring(prob.meta and prob.meta.seed) .. "|" .. (path:match("([^/\\]+)%.lua$") or path)
        pcall(process, prob.constraints, prob.normalized_lines, label, emit)
    end
end
if out_file then out_file:close() end
