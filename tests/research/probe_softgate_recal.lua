---@diagnostic disable: undefined-global
-- Soft-gate recalibration probe (research, no verdict).
--
-- observe_price's K_PRED=1.5 and its dEsc definition (surplus_sink + shortage_source
-- only) were validated on the ALL_OFF config (every escape-hatch heuristic off,
-- flat 1024 everywhere). Production (manage/pre_solve.lua) instead runs the module
-- on the SOFT-GATE config: reachability_gating=false + reachability_soft_gate_k=256,
-- with deficit_seeding and catalyst_closure at their default ON. Two follow-ups:
--
--   (1) RECAL: under the soft-gate baseline, is K_PRED=1.5 * dEsc/qty still the
--       price that flips an SCC from import to fabricate? The qualifying SCC set,
--       the baseline shortage mass (qty), and the observed dEsc all move when the
--       gate prices reachable shortages at 256x and deficit_seeding seeds raw
--       inputs as |initial_source|, so the calibration may shift.
--   (2) INIT_SOURCE: dEsc excludes |initial_source| (the cheap external raw supply
--       a forced fabrication drags in). With deficit_seeding ON the fabrication
--       pulls raw mass through initial_source that dEsc cannot see -- does counting
--       it (dEsc_init) predict true_flip better than dEsc?
--
-- Per qualifying SCC (self-sustaining, export-feasible, idle cyclic) it emits the
-- baseline shortage qty, dEsc / dEsc_init (escape-mass delta the ceiling-observe
-- drags in, without / with initial_source), and the LADDER ground-truth true_flip
-- (minimal mult at which the SCC fabricates with no extra target relax). RAW only;
-- the best-K fit and the dEsc-vs-dEsc_init comparison are the analyzer's call.
--
-- Usage:
--   <lua> tests/research/probe_softgate_recal.lua --config softgate|alloff \
--         --manifest <list> --out <file.tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"
local mc = require "solver/material_cycles"

local TOL, ITER = 1e-7, 800
local ELASTIC_COST = 2 ^ 10
local LADDER = { 2, 4, 8, 16, 32, 64, 128, 256, 1024, 4096, 16384, 65536 }
local OBSERVE_MULT = 16384
local K_PRED = 1.5

local CONFIGS = {
    alloff   = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false },
    softgate = { reachability_gating = false, reachability_soft_gate_k = 256 },
}

local R = require "tests/research/research_lib"
local internal_recipes = R.internal_recipes
local internal_flow = R.internal_flow
local target_relax = R.target_relax

local cfg_name = os.getenv("FS_CONFIG") or "softgate"
local OPTS = assert(CONFIGS[cfg_name], "bad FS_CONFIG")

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end
local function build(c, l) return create_problem.create_problem("recal", c, l, nil, OPTS) end

-- Escape mass, EXCLUDING the avoidable keys. `with_init` adds |initial_source| to
-- the surplus_sink + shortage_source set so the caller can measure the raw supply
-- a forced fabrication drags in.
local function escape_sum(problem, x, exclude, with_init)
    local s = 0
    for key, p in pairs(problem.primals) do
        if not exclude[key] then
            local k = p.kind
            if k == "surplus_sink" or k == "shortage_source"
                or (with_init and k == "initial_source") then
                s = s + math.abs(x[key] or 0)
            end
        end
    end
    return s
end

-- Objective cost carried by every NON-avoidable escape (surplus_sink +
-- shortage_source + initial_source), in elastic_cost units. This weights each kind
-- by its real objective cost, so initial_source enters at source_cost/elastic
-- (~1/1024 for items) instead of at mass parity -- the cost-weighted alternative
-- to escape_sum's raw mass.
local function escape_cost(problem, x, exclude)
    local s = 0
    for key, p in pairs(problem.primals) do
        if not exclude[key] then
            local k = p.kind
            if k == "surplus_sink" or k == "shortage_source" or k == "initial_source" then
                s = s + (p.cost or 0) * math.abs(x[key] or 0)
            end
        end
    end
    return s / ELASTIC_COST
end

-- Solve with the SCC's active shortages at ELASTIC_COST*mult. Returns shortage sum,
-- target relax, escape mass (no-init), escape mass (with-init), cost-weighted
-- escape (elastic units), or nil if unfinished.
local function solve_at(constraints, lines, active_sh, exclude, mult)
    local ok, p = pcall(build, constraints, lines)
    if not ok then return nil end
    for _, key in ipairs(active_sh) do p.primals[key].cost = ELASTIC_COST * mult end
    local s, v = solve(p)
    if s ~= "finished" then return nil end
    local x = v.x
    local short = 0
    for _, key in ipairs(active_sh) do short = short + (x[key] or 0) end
    return short, target_relax(p, x),
        escape_sum(p, x, exclude, false), escape_sum(p, x, exclude, true),
        escape_cost(p, x, exclude)
end

-- Does the SCC fabricate (shortage parked, no extra relax) at this exact mult?
local function fabricates_at(constraints, lines, active_sh, exclude, mult, th, relax0)
    if mult <= 0 then return false end
    local so, ro = solve_at(constraints, lines, active_sh, exclude, mult)
    return so ~= nil and so <= th and ro <= relax0 + 1e-4
end

local COLS = {
    "config", "label", "scc_size", "material", "n_active_sh", "base_shortage",
    "esc0", "esc0_init", "ecost0", "observe_fab",
    "dEsc", "dEsc_init", "dCost",
    "pred_mult", "pred_mult_init", "pred_cost", "true_flip",
    "verify_fab", "verify_fab_cost", "verify_cost15", "verify_cost20", "verify_mass20",
    "pred_vs_true", "pred_init_vs_true", "pred_cost_vs_true",
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
            local active_sh, active_mats = {}, {}
            for key, p in pairs(prob.primals) do
                if p.kind == "shortage_source" and p.material and scc_set[p.material]
                    and (x0[key] or 0) > th then
                    active_sh[#active_sh + 1] = key
                    active_mats[#active_mats + 1] = p.material
                end
            end
            if #active_sh >= 1 then
                local iset = internal_recipes(lines, scc_set)
                local self_sust = mc.is_self_sustaining(lines, scc)
                local fab = true
                for _, m in ipairs(active_mats) do
                    if not mc.export_feasible(lines, m) then fab = false; break end
                end
                if self_sust and fab and internal_flow(x0, iset) < 1e-6 then
                    local exclude, base_short = {}, 0
                    for _, key in ipairs(active_sh) do
                        base_short = base_short + (x0[key] or 0); exclude[key] = true
                    end
                    local esc0 = escape_sum(prob, x0, exclude, false)
                    local esc0_init = escape_sum(prob, x0, exclude, true)
                    local ecost0 = escape_cost(prob, x0, exclude)

                    -- OBSERVE at the high ceiling.
                    local observe_fab = "no"
                    local dEsc, dEsc_init, dCost = -1, -1, -1
                    local pred, pred_init, pred_cost = -1, -1, -1
                    local so, ro, eo, eo_init, ecost_o = solve_at(constraints, lines, active_sh, exclude, OBSERVE_MULT)
                    if so and so <= th and ro <= relax0 + 1e-4 then
                        observe_fab = "yes"
                        dEsc = eo - esc0
                        dEsc_init = eo_init - esc0_init
                        dCost = ecost_o - ecost0
                        local pq = base_short > 1e-12 and (dEsc / base_short) or 0
                        local pq_i = base_short > 1e-12 and (dEsc_init / base_short) or 0
                        local pq_c = base_short > 1e-12 and (dCost / base_short) or 0
                        pred = math.max(2, K_PRED * pq)
                        pred_init = math.max(2, K_PRED * pq_i)
                        -- cost-weighted predictor uses K=1 (dCost is already the
                        -- objective-cost the fabrication pays, in elastic units, so
                        -- mult = dCost/qty is the break-even import price).
                        pred_cost = math.max(2, pq_c)
                    end

                    -- Ground truth: minimal LADDER mult that fabricates.
                    local true_flip = -1
                    for _, mult in ipairs(LADDER) do
                        local sl, rl = solve_at(constraints, lines, active_sh, exclude, mult)
                        if sl and sl <= th and rl <= relax0 + 1e-4 then true_flip = mult; break end
                    end

                    -- Direct verify: does the SCC actually fabricate at the predicted
                    -- price (the real one-shot test, immune to LADDER quantization)?
                    -- Compare predictor families: mass-dEsc (K=1.5 / K=2) vs cost-dEsc
                    -- (K=1 / K=1.5 / K=2), so the analyzer can pick the best (def, K).
                    local pq_c = base_short > 1e-12 and (dCost / base_short) or 0
                    local vf = (pred > 0 and fabricates_at(constraints, lines, active_sh, exclude, pred, th, relax0)) and "yes" or "no"
                    local vfc = (pred_cost > 0 and fabricates_at(constraints, lines, active_sh, exclude, pred_cost, th, relax0)) and "yes" or "no"
                    local vfc15 = (observe_fab == "yes" and fabricates_at(constraints, lines, active_sh, exclude, math.max(2, 1.5 * pq_c), th, relax0)) and "yes" or "no"
                    local vfc20 = (observe_fab == "yes" and fabricates_at(constraints, lines, active_sh, exclude, math.max(2, 2.0 * pq_c), th, relax0)) and "yes" or "no"
                    local vm20 = (observe_fab == "yes" and fabricates_at(constraints, lines, active_sh, exclude, math.max(2, 2.0 * (base_short > 1e-12 and dEsc / base_short or 0)), th, relax0)) and "yes" or "no"

                    table.sort(active_mats)
                    emit({
                        config = cfg_name, label = label, scc_size = #scc,
                        material = table.concat(active_mats, ","),
                        n_active_sh = #active_sh, base_shortage = base_short,
                        esc0 = esc0, esc0_init = esc0_init, ecost0 = ecost0, observe_fab = observe_fab,
                        dEsc = dEsc, dEsc_init = dEsc_init, dCost = dCost,
                        pred_mult = pred, pred_mult_init = pred_init, pred_cost = pred_cost,
                        true_flip = true_flip, verify_fab = vf, verify_fab_cost = vfc,
                        verify_cost15 = vfc15, verify_cost20 = vfc20, verify_mass20 = vm20,
                        pred_vs_true = (pred > 0 and true_flip > 0) and (pred / true_flip) or -1,
                        pred_init_vs_true = (pred_init > 0 and true_flip > 0) and (pred_init / true_flip) or -1,
                        pred_cost_vs_true = (pred_cost > 0 and true_flip > 0) and (pred_cost / true_flip) or -1,
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
        elseif a == "--config" then i = i + 1; cfg_name = arg[i]; OPTS = assert(CONFIGS[cfg_name], "bad config")
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
