---@diagnostic disable: undefined-global
-- Throwaway: count escape variables per corpus problem (default create_problem
-- build, no solve), so we can pick the problem with the most source/sink escapes
-- for the quadratic-cost observation. Prints one TSV row per file plus a final
-- ranking of the top files. Single-process; run from the worktree root.
--
--   luajit tests/research/probe_count_escapes.lua --manifest <list>

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"

local SOURCE = { initial_source = true, shortage_source = true }
local SINK = { surplus_sink = true, final_sink = true }
local TARGET = { elastic = true, headroom = true }

local function count(problem)
    local c = { src = 0, sink = 0, target = 0, recipe = 0, total_primals = 0 }
    for _, p in pairs(problem.primals) do
        c.total_primals = c.total_primals + 1
        if SOURCE[p.kind] then c.src = c.src + 1
        elseif SINK[p.kind] then c.sink = c.sink + 1
        elseif TARGET[p.kind] then c.target = c.target + 1
        elseif p.kind == "recipe" then c.recipe = c.recipe + 1 end
    end
    return c
end

-- args
local manifest_path, files = nil, {}
do
    local i = 1
    while arg[i] do
        if arg[i] == "--manifest" then i = i + 1; manifest_path = arg[i]
        else files[#files + 1] = arg[i] end
        i = i + 1
    end
end
if manifest_path then
    for line in io.lines(manifest_path) do
        line = line:gsub("%s+$", "")
        if line ~= "" then files[#files + 1] = line end
    end
end

local rows = {}
for _, path in ipairs(files) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local ok, problem = pcall(create_problem.create_problem, "count",
            prob.constraints, prob.normalized_lines, nil, nil)
        if ok then
            local c = count(problem)
            c.path = path
            c.src_sink = c.src + c.sink
            c.escapes = c.src + c.sink + c.target
            rows[#rows + 1] = c
        end
    end
end

table.sort(rows, function(a, b) return a.src_sink > b.src_sink end)

io.write("#rank\tsrc_sink\tsrc\tsink\ttarget\trecipe\tprimals\tfile\n")
for i = 1, math.min(30, #rows) do
    local r = rows[i]
    io.write(string.format("%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n",
        i, r.src_sink, r.src, r.sink, r.target, r.recipe, r.total_primals,
        (r.path:match("([^/\\]+)%.lua$") or r.path)))
end
io.write(string.format("# total files processed: %d\n", #rows))
