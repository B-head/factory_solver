---@diagnostic disable: undefined-global
-- Observe-once price probe (research, no verdict).
--
-- Tests the "appropriate cost is a solve OUTPUT" hypothesis as a SHORT fixed
-- point instead of a per-material ladder. Targets the same avoidable-cheat
-- population as probe_fabricate_flip: a cyclic SCC that is self-sustaining AND
-- export_feasible (the cycle CAN fabricate its material) yet at baseline runs
-- none of the cycle and imports the material via |shortage_source| instead.
--
-- The ladder probe FINDS each material's flip multiplier M* by climbing 2,4,8...
-- until the shortage drops to ~0 -- up to ~12 solves per material. The claim
-- this probe checks: M* can instead be PREDICTED from a single observation,
-- because M* ~= k * (dEsc/qty) where dEsc is the 1024-tier escape mass (byproduct
-- dumps + secondary deficits) that fabrication drags in, and dEsc is readable
-- from ONE solve in which the material is already fabricated. So:
--
--   Phase 0  baseline (flat 1024)    -> qty = base shortage, esc0 = other-escape mass
--   Phase 2  OBSERVE (1 solve)       -> price the SCC's shortage(s) at a high ceiling
--                                       so the cycle fabricates; read the new other-
--                                       escape mass; dEsc = esc_observe - esc0
--   Phase 3  PREDICT (no solve)      -> predicted_mult = max(2, k * dEsc / qty)
--   Phase 4  VERIFY (1 solve)        -> set the shortage(s) to predicted_mult; does
--                                       the material fabricate (shortage~0, target kept)?
--
-- If VERIFY fabricates, the ~12-rung ladder collapsed to 2 solves (observe+verify).
-- The full ladder is ALSO run, as ground truth (true_flip_mult), so each row shows
-- whether the one-shot prediction lands at/above the real threshold without
-- overshooting into collapse. RAW numbers only -- the user sets the yardstick.
--
-- CAVEATS (per the import-vs-fabricate memory -- read before trusting output):
--   * dEsc/qty predicted M* with corr ~0.77 (independent) .. 0.96 (non-independent
--     reuse). k=1.5 is therefore a STARTING price, not a formula; VERIFY is what
--     decides. A miss does not refute the structure, only this k / this observation.
--   * Attribution of dEsc to a material is clean only when the SCC has ONE active
--     shortage (n_active_sh == 1). Multi-shortage rows are emitted but the analysis
--     should filter to n_active_sh == 1 for the clean signal.
--   * Cone-over-promise materials (C_fab > target_cost) do NOT fabricate even at the
--     observe ceiling -- they relax the target. They surface as observe_fabricated=no
--     and are correctly out of scope (import is right for them).
--
-- Usage (from repo root):
--   <lua> tests/research/probe_observe_price.lua --manifest <list> --out <file.tsv>

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
local OBSERVE_MULT = 16384 -- high ceiling: import priced out so the cycle fabricates (eff price 2^24, well under the ~2^29 numerical wall)
local K_PRED = 1.5         -- substrate-analysis constant: predicted_mult = k * dEsc/qty

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("observe", c, l, nil, OPTS) end

local R = require "tests/research/research_lib"
local internal_recipes = R.internal_recipes
local internal_flow = R.internal_flow
local target_relax = R.target_relax
local other_escape_sum = R.other_escape_sum

-- Solve once with the SCC's active shortages priced at ELASTIC_COST*mult. Returns
-- shortage sum, target relax, and other-escape mass (or nil if not finished).
local function solve_at(constraints, lines, active_sh, exclude, mult)
    local ok, p = pcall(build, constraints, lines)
    if not ok then return nil end
    for _, key in ipairs(active_sh) do p.primals[key].cost = ELASTIC_COST * mult end
    local s, v = solve(p)
    if s ~= "finished" then return nil end
    local x = v.x
    local short = 0
    for _, key in ipairs(active_sh) do short = short + (x[key] or 0) end
    return short, target_relax(p, x), other_escape_sum(p, x, exclude)
end

local COLS = {
    "label", "scc_size", "material", "n_active_sh", "base_shortage",
    "otheresc_before", "observe_mult", "observe_fabricated", "otheresc_observe",
    "dEsc", "desc_per_qty", "predicted_mult", "verify_fabricated",
    "verify_shortage", "verify_relax", "true_flip_mult", "pred_vs_true",
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
                    local exclude, base_short = {}, 0
                    for _, key in ipairs(active_sh) do base_short = base_short + (x0[key] or 0); exclude[key] = true end
                    local relax0 = target_relax(prob, x0)
                    local esc0 = other_escape_sum(prob, x0, exclude)

                    -- Phase 2: OBSERVE at the high ceiling.
                    local observe_fab, esc_obs = "no", -1
                    local dEsc, desc_pq, pred_mult = -1, -1, -1
                    local short_o, relax_o, eo = solve_at(constraints, lines, active_sh, exclude, OBSERVE_MULT)
                    if short_o then
                        esc_obs = eo
                        if short_o <= th and relax_o <= relax0 + 1e-4 then
                            observe_fab = "yes"
                            dEsc = eo - esc0
                            desc_pq = base_short > 1e-12 and (dEsc / base_short) or 0
                            pred_mult = math.max(2, K_PRED * desc_pq)
                        end
                    end

                    -- Phase 4: VERIFY at the predicted price (only if observe fabricated).
                    local verify_fab, verify_short, verify_relax = "n/a", -1, -1
                    if observe_fab == "yes" then
                        local sv, rv = solve_at(constraints, lines, active_sh, exclude, pred_mult)
                        if sv then
                            verify_short, verify_relax = sv, rv
                            verify_fab = (sv <= th and rv <= relax0 + 1e-4) and "yes" or "no"
                        else
                            verify_fab = "unfin"
                        end
                    end

                    -- Ground truth: ladder flip threshold (evaluation only).
                    local true_flip = -1
                    for _, mult in ipairs(LADDER) do
                        local sl, rl = solve_at(constraints, lines, active_sh, exclude, mult)
                        if sl and sl <= th and rl <= relax0 + 1e-4 then true_flip = mult; break end
                    end

                    table.sort(active_sh_mats)
                    emit({
                        label = label, scc_size = #scc,
                        material = table.concat(active_sh_mats, ","),
                        n_active_sh = #active_sh, base_shortage = base_short,
                        otheresc_before = esc0, observe_mult = OBSERVE_MULT,
                        observe_fabricated = observe_fab, otheresc_observe = esc_obs,
                        dEsc = dEsc, desc_per_qty = desc_pq, predicted_mult = pred_mult,
                        verify_fabricated = verify_fab, verify_shortage = verify_short,
                        verify_relax = verify_relax, true_flip_mult = true_flip,
                        pred_vs_true = (pred_mult > 0 and true_flip > 0) and (pred_mult / true_flip) or -1,
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
