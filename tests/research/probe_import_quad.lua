---@diagnostic disable: undefined-global
-- project_import_fabricate_convex, probe 2 (the QP route): a separable convex
-- quadratic on each |shortage_source| import column (create_problem import_quad),
-- so the marginal import cost rises with import quantity. This is the artifact-
-- free "curve" the 2-segment PWL only approximates: NO cap row, so the cap-row
-- convergence tax the PWL probe measured (~20-32% non-convergence) should vanish,
-- and the import/craft crossover self-selects per material.
--
-- Same un-gated base as the PWL probe (every produced+consumed material owns a
-- |shortage_source|). Configs:
--   flat              baseline, linear import at elastic_cost (1024).
--   pen16             uniform 16x penalty, no curve (the target-sacrificing anti-
--                     import comparator from the PWL probe).
--   quad<Q>           linear floor 1024 + quadratic Q: marginal = 1024 + Q*x.
--   floor64_quad<Q>   cheap linear floor (elastic/16 = 64) + quadratic Q: the
--                     "cheap top-up, expensive over-import" framing.
--
-- RAW totals only, no verdict. One row per (dump, config). Single-shot
-- (run_corpus): rows start with the seed= label.
--
-- Usage:
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_import_quad.lua -DumpDir <subset> -Collect '^seed=' -Out <tsv>
--   <lua> tests/research/probe_import_quad.lua --manifest <list> --out <tsv>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local problem_dump = require "tests/problem_dump"
local R = require "tests/research/research_lib"

local TOL, ITER = 1e-7, 300
local ELASTIC = 2 ^ 10

local function base_opts()
    return { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
end

local CONFIGS = {
    { name = "flat", mk = function() return base_opts() end },
    { name = "pen16", mk = function() local o = base_opts(); o.shortage_cost_fn = function() return 16 * ELASTIC end; return o end },
    { name = "quad8", mk = function() local o = base_opts(); o.import_quad = 8; return o end },
    { name = "quad64", mk = function() local o = base_opts(); o.import_quad = 64; return o end },
    { name = "quad512", mk = function() local o = base_opts(); o.import_quad = 512; return o end },
    { name = "floor64_quad64", mk = function()
        local o = base_opts(); o.shortage_cost_fn = function() return ELASTIC / 16 end; o.import_quad = 64; return o end },
    { name = "floor64_quad512", mk = function()
        local o = base_opts(); o.shortage_cost_fn = function() return ELASTIC / 16 end; o.import_quad = 512; return o end },
}

local function kind_masses(problem, x)
    local m = { recipe = 0, shortage_source = 0, surplus_sink = 0, elastic = 0 }
    for key, p in pairs(problem.primals) do
        local acc = m[p.kind]
        if acc ~= nil then m[p.kind] = acc + math.abs((x and x[key]) or 0) end
    end
    return m
end

local COLS = {
    "label", "config", "state", "steps",
    "recipes_active", "craft_flow", "dear_mass",
    "surplus_mass", "target_mass", "objective",
}

local function process(constraints, lines, label, emit)
    for _, cfg in ipairs(CONFIGS) do
        local ok, problem = pcall(create_problem.create_problem, "qp", constraints, lines, nil, cfg.mk())
        if not ok then
            emit({ label = label, config = cfg.name, state = "build_error" })
        else
            local st, vars, steps = harness.solve_to_completion(lp, problem, { tolerance = TOL, iterate_limit = ITER })
            if st == "finished" then
                local m = kind_masses(problem, vars.x)
                local active = select(1, R.recipe_partition(vars, problem))
                emit({
                    label = label, config = cfg.name, state = st, steps = steps,
                    recipes_active = #active,
                    craft_flow = m.recipe,
                    dear_mass = m.shortage_source,
                    surplus_mass = m.surplus_sink,
                    target_mass = m.elastic,
                    objective = R.objective(problem, vars),
                })
            else
                emit({ label = label, config = cfg.name, state = st, steps = steps })
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
if out_path then sink("#" .. table.concat(COLS, "\t") .. "\n") end
local function emit(r)
    local o = {}
    for _, k in ipairs(COLS) do o[#o + 1] = fmt(r[k]) end
    sink(table.concat(o, "\t") .. "\n")
end

for _, path in ipairs(files) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local label = "seed=" .. tostring(prob.meta and prob.meta.seed) .. "|" .. (path:match("([^/\\]+)%.lua$") or path)
        pcall(process, prob.constraints, prob.normalized_lines, label, emit)
    end
end
if out_file then out_file:close() end
