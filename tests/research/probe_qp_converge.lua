---@diagnostic disable: undefined-global
-- QP convergence harness: build the research least-norm QP (hard targets at BIG,
-- quad on the elastic escapes, free initial/final) and solve, reporting only the
-- terminal state and iteration count. Used to measure/repair corpus-wide QP
-- convergence (the L2 solution the practical-optimum work now leans on).
--
-- Single-shot (run_corpus): one RESULT line per file.
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_qp_converge.lua -Collect '^RESULT' -Out <tsv>
--   lua tests/research/probe_qp_converge.lua <dump> [BIG]    (single file, prints RESULT)

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local BIG = 1e3
local QUAD0 = 2
if os.getenv("FS_QP_ACCEPT") then lp.qp_accept_tolerance = tonumber(os.getenv("FS_QP_ACCEPT")) end
local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }

local function build_qp(prob)
    local problem = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil,
        { recipe_epsilon = (2 ^ -6) * BIG / 1e6 })
    -- Optional tiny ridge on the free (recipe/bridge) columns: makes the QP
    -- strictly convex in EVERY direction, pinning the recipe null-space (the
    -- multi-valued futile-circulation freedom the import-only quad leaves loose)
    -- to its minimal-norm representative -- the cure for the primal oscillation the
    -- hardest cycle problems show even after equilibration. FS_QP_RIDGE = the η.
    -- η=1e-10 is the adopted default (see the QP-convergence work): negligible vs
    -- the import quad (q=2, 2e10× larger) so the import-violation L2 is essentially
    -- unchanged, while it pins the recipe null-space to its minimal-norm
    -- representative. FS_QP_RIDGE overrides for sweeps; 0 disables.
    local RIDGE = tonumber(os.getenv("FS_QP_RIDGE")) or 1e-10
    for key, p in pairs(problem.primals) do
        if VIO[p.kind] then p.cost = 0; problem:set_quad(key, QUAD0)
        elseif FREEK[p.kind] then p.cost = 0; problem:set_quad(key, 0)
        elseif RIDGE > 0 and (p.kind == "recipe" or p.kind == "bridge") then problem:set_quad(key, RIDGE) end
    end
    -- strip targets to hard equality at BIG; drop target elastic/headroom/slacks; reindex.
    local rm = {}
    for _, c in ipairs(prob.constraints) do
        local dual = vk.limit(tn.typed_name_to_variable_name(c))
        if problem.duals[dual] then problem.duals[dual].limit = BIG end
        rm[vk.elastic(dual)] = true; rm[vk.pos_slack(dual)] = true; rm[vk.neg_slack(dual)] = true
    end
    for key, p in pairs(problem.primals) do if p.kind == "elastic" or p.kind == "headroom" then rm[key] = true end end
    for key in pairs(rm) do if problem.primals[key] then problem.primals[key] = nil; problem.subject_terms[key] = nil end end
    local keys = {}; for k in pairs(problem.primals) do keys[#keys + 1] = k end; table.sort(keys)
    for i, k in ipairs(keys) do problem.primals[k].index = i end
    problem.primal_length = #keys
    return problem
end

local ITER_OVERRIDE = tonumber(os.getenv("FS_QP_ITERS")) -- raise iterate_limit AND step_cap to probe slow-vs-stuck
local function solve(problem, prob)
    local iter_limit = ITER_OVERRIDE or prob.meta.iterate_limit
    local step_cap = ITER_OVERRIDE and (ITER_OVERRIDE + 10) or prob.meta.step_cap
    local state, it, vars, steps = "ready", nil, nil, 0
    local total_iters = 0
    repeat
        local ok, s, i2, v = pcall(lp.solve, problem, state, it, vars, prob.meta.tolerance, iter_limit)
        if not ok then return "errored", total_iters end
        state, it = s, i2; if v then vars = v end; steps = steps + 1
        total_iters = it or total_iters
    until (state ~= "ready" and state ~= "calculating") or steps > step_cap
    return state, total_iters
end

local function process(path)
    local prob = problem_dump.load_problem(path)
    if not prob then return end
    local ok, problem = pcall(build_qp, prob)
    if not ok then
        io.write(string.format("RESULT\tname=%s\tstate=builderr\titers=0\n", path:match("[^/\\]+$") or path))
        return
    end
    local state, iters = solve(problem, prob)
    io.write(string.format("RESULT\tname=%s\tstate=%s\titers=%d\twidth=%d\tbest=%.4g\n",
        path:match("[^/\\]+$") or path, state, iters or 0, problem.primal_length,
        problem.qp_best_crit or 0))
end

-- main
local files = {}
local i = 1
while arg[i] do
    if arg[i] == "--manifest" then
        i = i + 1
        for line in io.lines(arg[i]) do line = line:gsub("%s+$", ""); if line ~= "" then files[#files + 1] = line end end
    else files[#files + 1] = arg[i] end
    i = i + 1
end
for _, path in ipairs(files) do pcall(process, path) end
