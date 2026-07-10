---@diagnostic disable: undefined-global
-- Dissect a sparse-placement norm on a dump_import_normalized pair (the
-- share-string debugging path): rebuild the SHIPPED pipeline step by step --
-- base L2, the requested placement (candidates / smart / batch semantics via
-- solver/placement.lua, i.e. the real shipped module), rate floors,
-- restricted L2 -- and print per group WHY it was placed (SCC / self-edge /
-- self-loop / co-product / co-input / not-a-candidate) plus the physical
-- flows of both solves. For a user report "this material should not need an
-- escape", this shows whether the classification, the L2 economy, or the
-- guard widening put it there.
--   luajit tests/research/probe_place_dissect.lua <lines.lua> <constraints.lua> [norm]
require "tests/headless_env"
local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"
local placement = require "solver/placement"

local LINES = assert(arg[1], "lines dump path")
local CONSTRAINTS = assert(arg[2], "constraints dump path")
local NORM = arg[3] or "smart"
local lines = assert(loadfile(LINES))()
local constraints = assert(loadfile(CONSTRAINTS))()

local L2_RECIPE_EPS = 2 ^ -10
local VIOLATION_QUAD = 2 ^ 11
local VIOLATION_FLOOR = 2 ^ -8

local function build()
    local p = cp.create_problem("dissect", constraints, lines, nil, {
        reachability_gating = false,
        deficit_seeding = false,
        catalyst_closure = false,
        surplus_sink_gating = false,
        recipe_epsilon = L2_RECIPE_EPS,
    })
    cp.shape_l2(p, VIOLATION_QUAD, VIOLATION_FLOOR)
    return p
end
local function solve(p)
    return harness.solve_to_completion(lp, p, { tolerance = 1e-7, iterate_limit = 1200 })
end

-- ======== base ========
local base = build()
local st0, v0 = solve(base)
io.write(("base: %s\n"):format(tostring(st0)))
assert(st0 == "finished" and v0, "base did not converge")
local S0 = placement.violation_stats(base, v0.x)
local groups = placement.violation_groups(base)
local mat2base = placement.invert_groups(groups)
local g = placement.material_graph(base, lines, mat2base)

-- ======== classification table ========
-- Static placement simulation ("smart"; the "batch" pipeline replay lives in
-- probe_batch_dissect.lua). The reasons table below prints regardless.
local placed = placement.law_placement(base, lines, S0.gp)
local order = {}
for b in pairs(groups) do order[#order + 1] = b end
table.sort(order)
io.write(("groups=%d placed=%d (norm=%s)\n"):format(#order, (function()
    local n = 0
    for _ in pairs(placed) do n = n + 1 end
    return n
end)(), NORM))
io.write(("%-52s %-6s %-24s %10s\n"):format("group", "placed", "reasons", "base_phys"))
for _, b in ipairs(order) do
    local reasons = {}
    local scc, selfe, sloop, cop, coc = false, false, false, false, false
    for _, row in ipairs(groups[b]) do
        local id = g.sccid[row]
        if id and g.sccsize[id] >= 2 then scc = true end
        if g.adj[row] and g.adj[row][row] then selfe = true end
        if g.selfloop[b] then sloop = true end
        if g.coprod[row] then cop = true end
        if g.cocons[row] then coc = true end
    end
    if scc then reasons[#reasons + 1] = "scc" end
    if selfe then reasons[#reasons + 1] = "selfedge" end
    if sloop then reasons[#reasons + 1] = "selfloop" end
    if cop then reasons[#reasons + 1] = "coprod" end
    if coc then reasons[#reasons + 1] = "cocons" end
    io.write(("%-52s %-6s %-24s %10.4g\n"):format(b, placed[b] and "yes" or ".",
        (#reasons > 0) and table.concat(reasons, ",") or "-", S0.gp[b] or 0))
end

-- ======== restricted (floors + excludes), one guard-free solve ========
local rates = placement.recipe_rates(base, v0.x)
local restr = cp.create_problem("dissect-restricted", constraints, lines, nil, {
    reachability_gating = false,
    deficit_seeding = false,
    catalyst_closure = false,
    surplus_sink_gating = false,
    recipe_epsilon = L2_RECIPE_EPS,
    hatch_exclude = select(1, placement.excludes(groups, placed)),
    sink_exclude = select(2, placement.excludes(groups, placed)),
})
cp.shape_l2(restr, VIOLATION_QUAD, VIOLATION_FLOOR)
placement.apply_rate_floors(restr, rates, 1.0)
local st1, v1 = solve(restr)
io.write(("restricted: %s\n"):format(tostring(st1)))
if st1 == "finished" and v1 then
    local S1 = placement.violation_stats(restr, v1.x)
    local base_tot = S0.imp + S0.dmp
    io.write(("phys base imp=%.5g dmp=%.5g | restricted imp=%.5g dmp=%.5g | ratio=%.4g\n")
        :format(S0.imp, S0.dmp, S1.imp, S1.dmp,
            base_tot > 1e-9 and (S1.imp + S1.dmp) / base_tot or 1))
    io.write(("%-52s %12s %12s\n"):format("group (active either solve)", "base", "restricted"))
    for _, b in ipairs(order) do
        local a, c = S0.gp[b] or 0, S1.gp[b] or 0
        if a > 1e-6 or c > 1e-6 then
            io.write(("%-52s %12.5g %12.5g\n"):format(b, a, c))
        end
    end
end

-- ======== per-variant detail for materials named on the command line ========
for i = 4, #arg do
    local needle = arg[i]
    io.write(("== detail: %s\n"):format(needle))
    for _, b in ipairs(order) do
        if b:find(needle, 1, true) then
            for _, row in ipairs(groups[b]) do
                io.write(("  row %s scc=%s\n"):format(row, tostring(g.sccid[row])))
                for key, p in pairs(base.primals) do
                    if (p.kind == "recipe" or p.kind == "bridge") then
                        local coef = (base.subject_terms[key] or {})[row]
                        if coef and coef ~= 0 then
                            io.write(("    %-60s coef=%.6g x0=%.6g\n")
                                :format(key, coef, v0.x[key] or 0))
                        end
                    end
                end
            end
        end
    end
end
