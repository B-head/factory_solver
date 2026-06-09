---@diagnostic disable: undefined-global
-- Amount-lever vs cost-lever equivalence probe (research, no verdict).
--
-- Every prior tilt experiment moved the |shortage_source| OBJECTIVE cost c. The
-- user's insight: a |shortage_source| is synthetic, so its CONSTRAINT coefficient
-- a (the amount_per_second it adds to the material's balance + limit rows) is also
-- free. The effective per-unit import price is p = c/a, so shrinking a is a second
-- way to raise the price -- and (claim) it widens the adjustment range / collapse
-- grace because c stays in-tier (away from the 2^20 numerical ceiling).
--
-- Hypothesis under test (mine): scaling ALL of the source's subject terms by 1/m
-- uniformly is a PURE REPARAMETRIZATION of p = c/a. The LP's decisions (which
-- recipes run, fabricate-vs-import, target relax) depend only on p, so flipping a
-- material by a-shrink (a -> 1/m, c fixed at 1024) gives an IDENTICAL solution to
-- flipping it by c-raise (c -> 1024*m, a fixed at 1) at the matched price. If so,
-- the lever is economically inert (numerical grace only). If the solutions DIFFER,
-- the coefficient touches the geometry in a way price alone doesn't, and a is a
-- genuine new economic lever.
--
-- Per avoidable-cheat material, ladder both levers to the flip and compare the
-- flip multiplier and the full solution shape (target relax, recipe activity,
-- surplus mass) at the flip. Also record solver iterations to see the numerical
-- (conditioning) difference the reparametrization argument predicts.
--
-- Single-shot (run_corpus): one row per avoidable-cheat material, starts 'seed='.
-- Usage:
--   pwsh tests/run_corpus.ps1 -Driver tests/research/probe_amount_lever.lua -Collect '^seed=' -Out <tsv>

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
local function build(c, l) return create_problem.create_problem("amt", c, l, nil, OPTS) end

local R = require "tests/research/research_lib"
local internal_recipes = R.internal_recipes
local internal_flow = R.internal_flow
local target_relax = R.target_relax
local function rsum(p, x)
    local s = 0
    for key, pr in pairs(p.primals) do if pr.kind == "recipe" then s = s + math.abs(x[key] or 0) end end
    return s
end
local function surplus_total(p, x)
    local s = 0
    for key, pr in pairs(p.primals) do if pr.kind == "surplus_sink" then s = s + math.abs(x[key] or 0) end end
    return s
end

-- physical import that a shortage var contributes = (its balance coeff) * value.
-- coeff is read from subject_terms so it reflects any a-scaling we applied.
local function phys_import(p, x, keys, balance_dual)
    local s = 0
    for _, k in ipairs(keys) do
        local coeff = (p.subject_terms[k] and p.subject_terms[k][balance_dual[k]]) or 1
        s = s + math.abs((x[k] or 0) * coeff)
    end
    return s
end

local COLS = {
    "label", "scc_size", "material", "n_active_sh", "base_shortage",
    "m_cost", "relax_cost", "rsum_cost", "surp_cost", "iter_cost",
    "m_amt", "relax_amt", "rsum_amt", "surp_amt", "iter_amt",
}

local function iters(vr) return (vr and (vr.iterations or vr.iteration or vr.iter)) or -1 end

local function process(constraints, lines, label, emit)
    local ok, prob = pcall(build, constraints, lines)
    if not ok then return end
    local st, v0 = solve(prob)
    if st ~= "finished" then return end
    local x0 = v0.x
    local th = ed.park_threshold(v0, prob.primals)
    local relax0 = target_relax(prob, x0)

    local adj = mc.build_material_graph(lines)
    for _, scc in ipairs(mc.find_sccs(adj)) do
        if mc.is_cyclic_scc(scc, adj) then
            local scc_set = {}
            for _, m in ipairs(scc) do scc_set[m] = true end
            local active_sh, active_mats = {}, {}
            for key, p in pairs(prob.primals) do
                if p.kind == "shortage_source" and p.material and scc_set[p.material] and (x0[key] or 0) > th then
                    active_sh[#active_sh + 1] = key
                    active_mats[#active_mats + 1] = p.material
                end
            end
            if #active_sh >= 1 then
                local iset = internal_recipes(lines, scc_set)
                if mc.is_self_sustaining(lines, scc) and internal_flow(x0, iset) < 1e-6 then
                    local fab = true
                    for _, m in ipairs(active_mats) do if not mc.export_feasible(lines, m) then fab = false; break end end
                    if fab then
                        local base_short = 0
                        for _, k in ipairs(active_sh) do base_short = base_short + (x0[k] or 0) end

                        -- COST lever: raise c by m (a stays 1).
                        local m_cost, relax_c, rsum_c, surp_c, iter_c = -1, -1, -1, -1, -1
                        for _, m in ipairs(LADDER) do
                            local okp, p2 = pcall(build, constraints, lines)
                            if okp then
                                for _, k in ipairs(active_sh) do p2.primals[k].cost = ELASTIC_COST * m end
                                local s2, v2 = solve(p2)
                                if s2 == "finished" then
                                    local sh = 0; for _, k in ipairs(active_sh) do sh = sh + (v2.x[k] or 0) end
                                    if sh <= th then
                                        m_cost = m; relax_c = target_relax(p2, v2.x)
                                        rsum_c = rsum(p2, v2.x); surp_c = surplus_total(p2, v2.x); iter_c = iters(v2)
                                        break
                                    end
                                end
                            end
                        end

                        -- AMOUNT lever: shrink a by 1/m (scale subject terms), c fixed.
                        -- Need each shortage var's balance dual (the material's
                        -- balance row = constraint_name = its material key) to read
                        -- the physical import after scaling. shortage var touches
                        -- {material balance, limit, bare_limit}; scale ALL uniformly.
                        local m_amt, relax_a, rsum_a, surp_a, iter_a = -1, -1, -1, -1, -1
                        for _, m in ipairs(LADDER) do
                            local okp, p2 = pcall(build, constraints, lines)
                            if okp then
                                local balance_dual = {}
                                for _, k in ipairs(active_sh) do
                                    -- balance row of material M is the dual keyed by M's material name;
                                    -- the shortage var's material field IS that key.
                                    balance_dual[k] = p2.primals[k].material
                                    local terms = p2.subject_terms[k]
                                    if terms then
                                        for dual, coeff in pairs(terms) do terms[dual] = coeff / m end
                                    end
                                end
                                local s2, v2 = solve(p2)
                                if s2 == "finished" then
                                    local phys = phys_import(p2, v2.x, active_sh, balance_dual)
                                    if phys <= th then
                                        m_amt = m; relax_a = target_relax(p2, v2.x)
                                        rsum_a = rsum(p2, v2.x); surp_a = surplus_total(p2, v2.x); iter_a = iters(v2)
                                        break
                                    end
                                end
                            end
                        end

                        table.sort(active_mats)
                        emit({
                            label = label, scc_size = #scc, material = table.concat(active_mats, ","),
                            n_active_sh = #active_sh, base_shortage = base_short,
                            m_cost = m_cost, relax_cost = relax_c, rsum_cost = rsum_c, surp_cost = surp_c, iter_cost = iter_c,
                            m_amt = m_amt, relax_amt = relax_a, rsum_amt = rsum_a, surp_amt = surp_a, iter_amt = iter_a,
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
    for line in io.lines(manifest_path) do line = line:gsub("%s+$", ""); if line ~= "" then files[#files + 1] = line end end
end

local sink = io.write
local out_file = nil
if out_path then out_file = assert(io.open(out_path, "w")); sink = function(s) out_file:write(s) end end
local function fmt(v) if type(v) == "number" then return string.format("%.6g", v) end return tostring(v) end
sink("#" .. table.concat(COLS, "\t") .. "\n")
local function emit(r) local o = {}; for _, k in ipairs(COLS) do o[#o + 1] = fmt(r[k]) end; sink(table.concat(o, "\t") .. "\n") end

for _, path in ipairs(files) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local label = "seed=" .. tostring(prob.meta and prob.meta.seed) .. "|" .. (path:match("([^/\\]+)%.lua$") or path)
        pcall(process, prob.constraints, prob.normalized_lines, label, emit)
    end
end
if out_file then out_file:close() end
