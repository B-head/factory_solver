---@diagnostic disable: undefined-global
-- Corpus aggregate of the L2 dust fix: shipped (eps2^-20,q2,floor0) vs the new
-- shipped shaping (eps2^-6,q2^15,floor2^-8). For recipe + violation columns sum
-- across the sample: exact-0 count, mid-band [1e-6,1e-2) "parked, not reaching 0"
-- count, and convergence. The fix should move parked mass into exact-0.
--
--   lua tests/research/probe_l2_corpus_agg.lua [N]

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local lp = require "solver/linear_programming"

local DIR = os.getenv("FS_CORPUS_DIR") or "S:/tmp/explore_problems"
local N = tonumber(arg[1]) or 100

local files = {}
local p = io.popen('ls "' .. DIR .. '"')
for line in p:lines() do if line:match("%.lua$") then files[#files + 1] = line end end
p:close()
table.sort(files)
local sample, stride = {}, math.max(1, math.floor(#files / N))
for i = 1, #files, stride do sample[#sample + 1] = files[i]; if #sample >= N then break end end

local function solve(pp, prob)
    local state, it, vars, last, steps = "ready", nil, nil, nil, 0
    repeat
        local ok, s, i2, v = pcall(lp.solve, pp, state, it, vars, prob.meta.tolerance, prob.meta.iterate_limit)
        if not ok then return nil, "errored" end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
    return last, state
end
local function build(prob, eps, quad, floor)
    local problem = create_problem.create_problem("l2", prob.constraints, prob.normalized_lines, nil,
        { reachability_gating = false, recipe_epsilon = eps })
    create_problem.shape_l2(problem, quad, floor)
    return problem
end

-- counts over recipe + violation columns: exact0, mid-band [1e-6,1e-2)
local function tally(problem, vars)
    local exact0, mid = 0, 0
    for key, pr in pairs(problem.primals) do
        if pr.kind == "recipe" or pr.kind == "shortage_source" or pr.kind == "surplus_sink" then
            local v = math.abs(vars.x[key] or 0)
            if v == 0 then exact0 = exact0 + 1
            elseif v >= 1e-6 and v < 1e-2 then mid = mid + 1 end
        end
    end
    return exact0, mid
end

local configs = {
    { "old      (2^-20,q2,f0)", 2 ^ -20, 2, 0 },
    { "big-quad (2^-6,q2^15,f2^-8)", 2 ^ -6, 2 ^ 15, 2 ^ -8 },
    { "shipped  (2^-10,q2^11,f2^-8)", 2 ^ -10, 2 ^ 11, 2 ^ -8 },
}
for _, cfg in ipairs(configs) do
    local ex, mid, fin, bad, maxit = 0, 0, 0, 0, 0
    for _, f in ipairs(sample) do
        local prob = problem_dump.load_problem(DIR .. "/" .. f)
        if prob then
            local pp = build(prob, cfg[2], cfg[3], cfg[4])
            local vars, st = solve(pp, prob)
            if st == "finished" and vars then
                fin = fin + 1
                local e, m = tally(pp, vars)
                ex = ex + e; mid = mid + m
            else bad = bad + 1 end
        end
    end
    io.write(string.format("%-28s  Σexact0=%-6d  Σmid[1e-6,1e-2)=%-6d  finished=%d/%d unconv=%d\n",
        cfg[1], ex, mid, fin, #sample, bad))
end
