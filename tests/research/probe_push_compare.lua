---@diagnostic disable: undefined-global
-- Rough guide (NOT a verdict -- aggregate metric): flat shortage push vs
-- w-inverse push, compared on TOTAL EXTERNAL DEPENDENCY = shortage + initial.
--
-- shortage-only "improved" over-counts: flat pushes high-w materials to fabricate,
-- dropping shortage but exploding raw import (initial_source) -- a relabel, not a
-- real reduction in what the factory pulls from outside. source x (1/w) leaves
-- high-w as cheap import instead. Total external (shortage + initial) is the
-- honest aggregate: did the factory actually pull less from outside? Per the user
-- this aggregate is still only good for rough targeting; the definitive test is
-- the per-variable useful-judgment (force a parked var, watch a non-zero elastic).
--
-- Two push schemes at each m, both vs the flat no-push baseline (m=1 flat):
--   flat : shortage = m*1024            (uniform)
--   inv  : shortage = m*1024 / w(M) ; initial = 1 / w(M) ; surplus = 1024 * w(M)
-- (w = amount/min). Emits full vectors; analysis compares sh+ini and target.
--
-- Single-shot (run_corpus): rows start 'seed='.
-- Usage:
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_push_compare.lua -Collect '^seed=' -Out <tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local problem_dump = require "tests/problem_dump"
local mw = require "solver/material_weights"

local TOL, ITER = 1e-7, 800
local OPTS = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
local T_SHORT, T_INIT, T_SURP = 2 ^ 10, 1, 2 ^ 10
local LADDER = { 1, 4, 16, 64, 128 }

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("pc", c, l, nil, OPTS) end

local function vec(p, x)
    local v = { sh = 0, su = 0, ini = 0, tg = 0 }
    for key, pr in pairs(p.primals) do
        local a = math.abs(x[key] or 0)
        if pr.kind == "shortage_source" then v.sh = v.sh + a
        elseif pr.kind == "surplus_sink" then v.su = v.su + a
        elseif pr.kind == "initial_source" then v.ini = v.ini + a
        elseif pr.kind == "elastic" then v.tg = v.tg + a end
    end
    return v
end

local COLS = { "label", "m",
    "f_sh", "f_ini", "f_su", "f_tg", "f_state",
    "i_sh", "i_ini", "i_su", "i_tg", "i_state" }

local function process(constraints, lines, label, emit)
    -- need weights up front
    local ok0, p0 = pcall(build, constraints, lines); if not ok0 then return end
    local s0, v0 = solve(p0); if s0 ~= "finished" then return end
    local B = vec(p0, v0.x)
    if B.sh <= 1e-7 and B.su <= 1e-7 then return end

    local okw, res = pcall(mw.compute, lines, { allocation = "amount", combiner = "min" })
    local w = okw and res.weight or {}
    local function wof(m) local x = w[m]; if not x or x <= 0 then return 1 end return x end

    for _, m in ipairs(LADDER) do
        -- flat push
        local F = { sh = -1, ini = -1, su = -1, tg = -1 }; local fs = "skip"
        do
            local okf, pf = pcall(build, constraints, lines)
            if okf then
                if m ~= 1 then for _, pr in pairs(pf.primals) do if pr.kind == "shortage_source" then pr.cost = m * T_SHORT end end end
                local sf, vf = solve(pf); fs = sf
                if sf == "finished" then F = vec(pf, vf.x) end
            end
        end
        -- inverse-w push
        local I = { sh = -1, ini = -1, su = -1, tg = -1 }; local is = "skip"
        do
            local oki, pi = pcall(build, constraints, lines)
            if oki then
                for _, pr in pairs(pi.primals) do
                    if pr.material then
                        local wm = wof(pr.material)
                        if pr.kind == "shortage_source" then pr.cost = m * T_SHORT / wm
                        elseif pr.kind == "initial_source" then pr.cost = T_INIT / wm
                        elseif pr.kind == "surplus_sink" then pr.cost = T_SURP * wm end
                    end
                end
                local si, vi = solve(pi); is = si
                if si == "finished" then I = vec(pi, vi.x) end
            end
        end
        emit({ label = label, m = m,
            f_sh = F.sh, f_ini = F.ini, f_su = F.su, f_tg = F.tg, f_state = fs,
            i_sh = I.sh, i_ini = I.ini, i_su = I.su, i_tg = I.tg, i_state = is })
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
if out_path then sink("#" .. table.concat(COLS, "\t") .. "\n") end
local function emit(r) local o = {}; for _, k in ipairs(COLS) do o[#o + 1] = fmt(r[k]) end; sink(table.concat(o, "\t") .. "\n") end

for _, path in ipairs(files) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local label = "seed=" .. tostring(prob.meta and prob.meta.seed) .. "|" .. (path:match("([^/\\]+)%.lua$") or path)
        pcall(process, prob.constraints, prob.normalized_lines, label, emit)
    end
end
if out_file then out_file:close() end
