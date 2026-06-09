---@diagnostic disable: undefined-global
-- material_weights normalization of ALL escapes, source x w / sink x (1/w).
--
-- The session's original premise (project_material_weight_normalization): a flat
-- per-unit escape cost mis-prices each material by the conversion-ratio drift of
-- its embodied cost, so any cost-adjustment heuristic that ignores w(M) cannot be
-- clean. Single-lever flat experiments confirmed "no clean form". This probe puts
-- w back in, on EVERY boundary variable at once, with the source/sink asymmetry
-- the user proposed:
--   sources (inject material): shortage_source, initial_source  ->  cost x w(M)
--   sinks   (drain  material): surplus_sink,    final_sink      ->  cost / w(M)
-- Story: a deep material (high w) gets an expensive import (favour fabricating it)
-- and a cheap dump (byproduct disposal is acceptable); a shallow/raw material
-- (w~1) stays near flat (import it). Base tiers are NOT sacred (user) -- start at
-- the current ones; w = amount/min only.
--
-- Solves flat vs w-normalized and reports the full escape vector (shortage,
-- surplus, initial, final, target) for both. RAW numbers; analysis classifies
-- improvement (shortage/surplus down, dump-acceptable) vs collapse (target up,
-- = failure, NOT strict infeasibility).
--
-- Single-shot (run_corpus): one row per problem, starts 'seed='.
-- Usage:
--   pwsh tests/run_corpus.ps1 -Driver tests/research/probe_w_normalize.lua -Collect '^seed=' -Out <tsv>
--   <lua> tests/research/probe_w_normalize.lua --manifest <list> --out <tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local problem_dump = require "tests/problem_dump"
local mw = require "solver/material_weights"

local TOL, ITER = 1e-7, 800
local OPTS = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
-- base tiers (current solver values; freely adjustable per the user).
local T_SHORT, T_INIT, T_SURP, T_FINAL = 2 ^ 10, 1, 2 ^ 10, 0

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("wn", c, l, nil, OPTS) end

-- five escape/boundary totals (sum |x| per kind)
local function vec(p, x)
    local v = { sh = 0, su = 0, ini = 0, fin = 0, tg = 0 }
    for key, pr in pairs(p.primals) do
        local a = math.abs(x[key] or 0)
        if pr.kind == "shortage_source" then v.sh = v.sh + a
        elseif pr.kind == "surplus_sink" then v.su = v.su + a
        elseif pr.kind == "initial_source" then v.ini = v.ini + a
        elseif pr.kind == "final_sink" then v.fin = v.fin + a
        elseif pr.kind == "elastic" then v.tg = v.tg + a end
    end
    return v
end

-- global push on the fabrication-forcing source (shortage). surplus/initial stay
-- at their fixed w-normalized base (dump stays cheap as we push fabrication).
local LADDER = { 1, 2, 4, 8, 16, 32, 64, 128 }

local COLS = { "label", "m", "f_sh", "f_su", "f_tg", "w_sh", "w_su", "w_tg", "w_state" }

local function process(constraints, lines, label, emit)
    -- flat baseline (original solver: shortage=surplus=1024, initial=1, no w)
    local ok, pf = pcall(build, constraints, lines); if not ok then return end
    local sf, vf = solve(pf); if sf ~= "finished" then return end
    local F = vec(pf, vf.x)
    if F.sh <= 1e-7 and F.su <= 1e-7 then return end  -- nothing to improve

    local okw, res = pcall(mw.compute, lines, { allocation = "amount", combiner = "min" })
    local w = okw and res.weight or {}
    local function wof(m) local x = w[m]; if not x or x <= 0 then return 1 end return x end

    for _, m in ipairs(LADDER) do
        -- w-normalized: shortage = m*1024*w (push, scaled per-material by w);
        -- initial = 1*w ; surplus = 1024/w (sink reciprocal, dump stays cheap);
        -- final = 0.
        local okn, pn = pcall(build, constraints, lines)
        if okn then
            for _, pr in pairs(pn.primals) do
                if pr.material then
                    local wm = wof(pr.material)
                    -- DIRECTION SWAPPED (user): source x (1/w), sink x w.
                    -- low-w (cheap to make) -> expensive import -> fabricate;
                    -- high-w (expensive / unresolved catalyst) -> cheap import.
                    if pr.kind == "shortage_source" then pr.cost = m * T_SHORT / wm
                    elseif pr.kind == "initial_source" then pr.cost = T_INIT / wm
                    elseif pr.kind == "surplus_sink" then pr.cost = T_SURP * wm
                    elseif pr.kind == "final_sink" then pr.cost = T_FINAL * wm end
                end
            end
            local sn, vn = solve(pn)
            local W = (sn == "finished") and vec(pn, vn.x) or { sh = -1, su = -1, tg = -1 }
            emit({ label = label, m = m, f_sh = F.sh, f_su = F.su, f_tg = F.tg,
                w_sh = W.sh, w_su = W.su, w_tg = W.tg, w_state = sn })
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
