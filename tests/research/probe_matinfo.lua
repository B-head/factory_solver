---@diagnostic disable: undefined-global
-- Read everything about ONE material in ONE dump, to settle why the fork/SCC
-- classifier calls it "other" while the greedy necessity probe keeps it:
--   * every real line touching it (full products/ingredients with amounts,
--     fluid temperatures included),
--   * every boundary primal on it in the forced build (shortage / surplus /
--     initial_source / final_sink, per temperature window),
--   * its baseline violation flow.
--   luajit tests/research/probe_matinfo.lua <dump> <material-name-substring>
require "tests/headless_env"
local R = require "tests/research/research_lib"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local EPS = 2 ^ -10
local prob = assert(problem_dump.load_problem(arg[1]))
local NEEDLE = assert(arg[2], "material substring required")

local function vname(v)
    local s = (v.type or "?") .. "/" .. (v.name or "?")
    if v.temperature then s = s .. "@" .. tostring(v.temperature) end
    if v.minimum_temperature or v.maximum_temperature then
        s = s .. ("@[%s,%s]"):format(tostring(v.minimum_temperature), tostring(v.maximum_temperature))
    end
    return s
end
local function amt(v) return v.amount_per_second or v.amount or 0 end

io.write(("== %s : lines touching '%s'\n"):format(arg[1]:match("[^/\\]+$"), NEEDLE))
for _, line in ipairs(prob.normalized_lines) do
    local hit = false
    for _, v in ipairs(line.products or {}) do if (v.name or ""):find(NEEDLE, 1, true) then hit = true end end
    for _, v in ipairs(line.ingredients or {}) do if (v.name or ""):find(NEEDLE, 1, true) then hit = true end end
    if hit then
        local ps, is = {}, {}
        for _, v in ipairs(line.products or {}) do ps[#ps + 1] = ("%s x%.4g"):format(vname(v), amt(v)) end
        for _, v in ipairs(line.ingredients or {}) do is[#is + 1] = ("%s x%.4g"):format(vname(v), amt(v)) end
        io.write(("  %s%-36s  IN: %s\n%40s OUT: %s\n"):format(
            line.is_bridge and "[bridge] " or "",
            line.recipe_typed_name and line.recipe_typed_name.name or "?",
            table.concat(is, ", "), "", table.concat(ps, ", ")))
    end
end

local anchor = {}
for _, c in ipairs(prob.constraints) do
    anchor[#anchor + 1] = { type = c.type, name = c.name, quality = c.quality,
        limit_type = "lower", limit_amount_per_second = 0 }
    if (c.name or ""):find(NEEDLE, 1, true) then
        io.write(("  constraint: %s/%s %s %s\n"):format(c.type, c.name,
            tostring(c.limit_type), tostring(c.limit_amount_per_second)))
    end
end
local p = cp.create_problem("l2", anchor, prob.normalized_lines, nil,
    { reachability_gating = false, deficit_seeding = false, catalyst_closure = false,
        surplus_sink_gating = false, recipe_epsilon = EPS })
local recs = {}
for k, pr in pairs(p.primals) do if pr.kind == "recipe" then recs[#recs + 1] = k end end
for _, k in ipairs(recs) do
    local dual = "forcerec/" .. k
    p:add_lower_limit_constraint(dual, 1)
    p:add_subject_term(k, dual, 1)
end
cp.shape_l2(p, 2 ^ 11, 2 ^ -8)
local x0, st0 = R.drive_solve(p, prob.meta)
io.write(("  forced solve: %s\n"):format(tostring(st0)))
local rows = {}
for k, pr in pairs(p.primals) do
    if pr.material and pr.material:find(NEEDLE, 1, true)
        and (pr.kind == "shortage_source" or pr.kind == "surplus_sink"
            or pr.kind == "initial_source" or pr.kind == "final_sink") then
        local t = p.subject_terms[k]
        local c = (t and t[pr.material]) or 1
        rows[#rows + 1] = ("  port %-16s %-44s flow=%.6g"):format(pr.kind, k, math.abs(c * (x0 and x0[k] or 0)))
    end
end
table.sort(rows)
io.write(table.concat(rows, "\n"), "\n")
