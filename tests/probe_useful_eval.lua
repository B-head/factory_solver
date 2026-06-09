---@diagnostic disable: undefined-global
-- Definitive evaluation of the inverse-w(m=4) cost scheme via the USEFUL judgment
-- (the only single metric that has held up -- user). Aggregate metrics only
-- rough-target; this asks the improvement definition directly:
--   possibly-useful : a parked variable X (=0 at flat baseline) whose forced
--                     activation reduces a non-zero escape (shortage/surplus),
--                     target relaxation not rising (no collapse).
--   captured        : the inverse-w scheme activates that same X naturally
--                     (x>thresh under source x 1/w, sink x w, shortage push m=4).
-- An improvement (per the user's definition) is a cost set that activates a
-- possibly-useful X. So the scheme's score = of the possibly-useful parked
-- variables, how many it actually activates (and how many it activates that are
-- NOT possibly-useful = spurious). RAW per-candidate rows.
--
-- Candidate filter (bounds the force-probing) = collect_useful's: a zero primal
-- coupled to a non-zero shortage/surplus escape's material row with the
-- substituting sign (producer for shortage, consumer for surplus).
--
-- Single-shot (run_corpus): one row per candidate, starts 'seed='.
-- Usage:
--   pwsh tests/run_corpus.ps1 -Driver tests/probe_useful_eval.lua -Collect '^seed=' -Out <tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"
local mw = require "solver/material_weights"

local TOL, ITER = 1e-7, 800
local OPTS = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
local T_SHORT, T_INIT, T_SURP = 2 ^ 10, 1, 2 ^ 10
local INV_M = 4       -- the mild push that won the rough guide
local FORCE_EPS = 0.1
local MAX_CAND = 50   -- cap force-probes per problem
local ELASTIC_KINDS = { shortage_source = true, surplus_sink = true, elastic = true }

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("ue", c, l, nil, OPTS) end

local function vec(p, x)
    local v = { sh = 0, su = 0, tg = 0 }
    for key, pr in pairs(p.primals) do
        local a = math.abs(x[key] or 0)
        if pr.kind == "shortage_source" then v.sh = v.sh + a
        elseif pr.kind == "surplus_sink" then v.su = v.su + a
        elseif pr.kind == "elastic" then v.tg = v.tg + a end
    end
    return v
end

local function process(constraints, lines, label, emit)
    local ok, p0 = pcall(build, constraints, lines); if not ok then return end
    local s0, v0 = solve(p0); if s0 ~= "finished" then return end
    local x0 = v0.x
    local thresh = ed.park_threshold(v0, p0.primals)
    local B = vec(p0, x0)
    if B.sh <= thresh and B.su <= thresh then return end
    local function is_zero(k) return (x0[k] or 0) <= thresh end

    -- nonzero shortage/surplus escapes -> coupling targets
    local escapes = {}
    for key, pr in pairs(p0.primals) do
        if (pr.kind == "shortage_source" or pr.kind == "surplus_sink") and (x0[key] or 0) > thresh then
            escapes[#escapes + 1] = { material = pr.material, kind = pr.kind }
        end
    end

    -- candidate parked variables coupled with the substituting sign
    local seen, cands = {}, {}
    for _, E in ipairs(escapes) do
        if E.material then
            for key, pr in pairs(p0.primals) do
                if not seen[key] and is_zero(key) and not ELASTIC_KINDS[pr.kind] and pr.kind ~= "slack" then
                    local terms = p0.subject_terms[key]
                    local coef = terms and terms[E.material]
                    if coef and ((E.kind == "shortage_source" and coef > 0)
                            or (E.kind == "surplus_sink" and coef < 0)) then
                        seen[key] = true
                        cands[#cands + 1] = { key = key, via_kind = E.kind }
                        if #cands >= MAX_CAND then goto done_cands end
                    end
                end
            end
        end
    end
    ::done_cands::
    if #cands == 0 then return end

    -- inverse-w(m=4) solve once; record which candidates it activates
    local invw_active, invw_state = {}, "skip"
    do
        local okw, res = pcall(mw.compute, lines, { allocation = "amount", combiner = "min" })
        local w = okw and res.weight or {}
        local function wof(m) local x = w[m]; if not x or x <= 0 then return 1 end return x end
        local oki, pi = pcall(build, constraints, lines)
        if oki then
            for _, pr in pairs(pi.primals) do
                if pr.material then
                    local wm = wof(pr.material)
                    if pr.kind == "shortage_source" then pr.cost = INV_M * T_SHORT / wm
                    elseif pr.kind == "initial_source" then pr.cost = T_INIT / wm
                    elseif pr.kind == "surplus_sink" then pr.cost = T_SURP * wm end
                end
            end
            local si, vi = solve(pi); invw_state = si
            if si == "finished" then
                local ith = ed.park_threshold(vi, pi.primals)
                for _, c in ipairs(cands) do invw_active[c.key] = (vi.x[c.key] or 0) > ith end
            end
        end
    end

    -- force-probe each candidate at the flat baseline
    for _, c in ipairs(cands) do
        local fsh, fsu, ftg, fstate = -1, -1, -1, "skip"
        local okf, pf = pcall(build, constraints, lines)
        if okf then
            pf:add_lower_limit_constraint("|force_active|", FORCE_EPS)
            pf:add_subject_term(c.key, "|force_active|", 1)
            local sf, vf = solve(pf); fstate = sf
            if sf == "finished" then local V = vec(pf, vf.x); fsh, fsu, ftg = V.sh, V.su, V.tg end
        end
        emit({
            label = label, cand = c.key, via_kind = c.via_kind,
            b_sh = B.sh, b_su = B.su, b_tg = B.tg,
            f_sh = fsh, f_su = fsu, f_tg = ftg, f_state = fstate,
            invw_active = invw_active[c.key] and 1 or 0, invw_state = invw_state,
        })
    end
end

-- ---- output -----------------------------------------------------------------
local COLS = { "label", "cand", "via_kind", "b_sh", "b_su", "b_tg",
    "f_sh", "f_su", "f_tg", "f_state", "invw_active", "invw_state" }
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
