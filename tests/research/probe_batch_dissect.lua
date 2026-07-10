---@diagnostic disable: undefined-global
-- Dissect the SHIPPED batch Phase-I placement on a dump_import_normalized
-- pair: replay the exact pipeline (base L2 -> all-closed Phase-I with recipe
-- floors + target budget -> open every supported group -> repeat), printing
-- each iteration's full artificial support, then grade the final opened set
-- against the DEFINITION -- for every opened group, close it ALONE
-- (everything else open, floors held) and ask the Phase-I oracle whether the
-- problem is infeasible. Opened-but-not-needed groups are the over-opening
-- the user reports.
--   luajit tests/research/probe_batch_dissect.lua <lines.lua> <constraints.lua>
require "tests/headless_env"
local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"
local placement = require "solver/placement"
local observe_price = require "solver/observe_price"

local lines = assert(loadfile(assert(arg[1])))()
local constraints = assert(loadfile(assert(arg[2])))()

local L2_RECIPE_EPS = 2 ^ -10
local VIOLATION_QUAD = 2 ^ 11
local VIOLATION_FLOOR = 2 ^ -8
local ART_TOL, SUPPORT_TOL -- set relative to the base violation total below

local function build(opts)
    opts = opts or {}
    local p = cp.create_problem("batch-dissect", constraints, lines, nil, {
        reachability_gating = false,
        deficit_seeding = false,
        catalyst_closure = false,
        surplus_sink_gating = false,
        recipe_epsilon = L2_RECIPE_EPS,
        hatch_exclude = opts.hatch,
        sink_exclude = opts.sink,
        target_budget = opts.budget,
    })
    return p
end
local function solve(p)
    return harness.solve_to_completion(lp, p, { tolerance = 1e-7, iterate_limit = 600 })
end

-- base
local base = build()
cp.shape_l2(base, VIOLATION_QUAD, VIOLATION_FLOOR)
local st0, v0 = solve(base)
assert(st0 == "finished" and v0, "base failed")
local S0 = placement.violation_stats(base, v0.x)
local groups = placement.violation_groups(base)
local mat2base = placement.invert_groups(groups)
local rates = placement.recipe_rates(base, v0.x)
local t0 = observe_price.target_relax(base.primals, v0.x)
local budget = t0 * (1 + 1e-3) + 1e-6
ART_TOL = math.max(1e-4 * (S0.imp + S0.dmp), 1e-6)
SUPPORT_TOL = math.max(1e-5 * (S0.imp + S0.dmp), 1e-7)
io.write(("base ok. target_relax=%.6g budget=%.6g groups=%d\n"):format(t0, budget, (function()
    local n = 0
    for _ in pairs(groups) do n = n + 1 end
    return n
end)()))

local function phase1(placed)
    local hatch, sink = placement.excludes(groups, placed)
    local p = build({ hatch = hatch, sink = sink, budget = budget })
    local arts = placement.shape_phase1(p)
    placement.apply_rate_floors(p, rates, 1.0)
    local st, v = solve(p)
    if st ~= "finished" or not v then return nil end
    local total, support = placement.phase1_support(arts, v.x, SUPPORT_TOL)
    return total, support
end

-- ======== the shipped batch loop (single-open + prune), verbose ========
local placed = {}
for iter = 1, 24 do
    local total, support = phase1(placed)
    if not total then
        io.write(("iter %d: phase1 UNFINISHED\n"):format(iter))
        break
    end
    local mapped = 0
    for _, s in ipairs(support) do
        if mat2base[s.row] then mapped = mapped + s.art end
    end
    io.write(("iter %d: art total=%.6g mapped=%.6g support=%d rows\n")
        :format(iter, total, mapped, #support))
    for _, s in ipairs(support) do
        io.write(("   %10.5g  %-52s %s\n"):format(s.art, s.row,
            mat2base[s.row] and "" or "(unmapped)"))
    end
    if mapped <= ART_TOL then
        io.write(("iter %d: feasible.\n"):format(iter))
        break
    end
    local opened = nil
    for _, s in ipairs(support) do
        local b = mat2base[s.row]
        if b and not placed[b] then
            placed[b] = true
            opened = b
            break
        end
    end
    if not opened then
        io.write("no progress -> place-all fallback would fire\n")
        break
    end
    io.write(("   => open %s\n"):format(opened))
end

-- prune (physically smallest first)
local prune = {}
for b in pairs(placed) do prune[#prune + 1] = b end
table.sort(prune, function(a, b)
    local pa, pb = S0.gp[a] or 0, S0.gp[b] or 0
    if pa ~= pb then return pa < pb end
    return a < b
end)
for _, b in ipairs(prune) do
    placed[b] = nil
    local total, support = phase1(placed)
    local mapped = 0
    for _, s in ipairs(support or {}) do
        if mat2base[s.row] then mapped = mapped + s.art end
    end
    if total and mapped <= ART_TOL then
        io.write(("prune %-52s DROPPED (art=%.6g)\n"):format(b, mapped))
    else
        placed[b] = true
        io.write(("prune %-52s kept (art=%.6g)\n"):format(b, mapped))
    end
end
io.write("final placement:\n")
local final = {}
for b in pairs(placed) do final[#final + 1] = b end
table.sort(final)
for _, b in ipairs(final) do io.write(("   %s\n"):format(b)) end

-- ======== restricted L2 + guard simulation (the shipped tail) ========
local base_total = S0.imp + S0.dmp
for round = 0, 4 do
    local hatch, sink = placement.excludes(groups, placed)
    local p = build({ hatch = hatch, sink = sink, budget = budget })
    cp.shape_l2(p, VIOLATION_QUAD, VIOLATION_FLOOR)
    placement.apply_rate_floors(p, rates, 1.0)
    local st, v = solve(p)
    if st == "finished" and v then
        local S1 = placement.violation_stats(p, v.x)
        local ratio = base_total > 1e-9 and (S1.imp + S1.dmp) / base_total or 1
        local act = 0
        for _, phys in pairs(S1.gp) do
            if phys > 1e-6 then act = act + 1 end
        end
        io.write(("restricted round %d: finished imp=%.5g dmp=%.5g ratio=%.4g active=%d placed=%d\n")
            :format(round, S1.imp, S1.dmp, ratio, act, (function()
                local n = 0
                for _ in pairs(placed) do n = n + 1 end
                return n
            end)()))
        if ratio <= 1.5 then
            io.write("guard: PASS\n")
            break
        end
    else
        io.write(("restricted round %d: %s\n"):format(round, tostring(st)))
    end
    if round == 4 then
        io.write("guard: rounds exhausted\n")
        break
    end
    local before = {}
    for b in pairs(placed) do before[b] = true end
    local added = placement.widen_rank(S0.gp, placed, 6)
    io.write(("guard: widen_rank added %d:\n"):format(added))
    local names = {}
    for b in pairs(placed) do
        if not before[b] then names[#names + 1] = b end
    end
    table.sort(names)
    for _, b in ipairs(names) do
        io.write(("     + %s (base_gp=%.5g)\n"):format(b, S0.gp[b] or 0))
    end
    if added == 0 then break end
end

-- ======== grade the opened set against the definition ========
local all_open = {}
for b in pairs(groups) do all_open[b] = true end
local floor_total = select(1, phase1(all_open)) or 0
io.write(("\nall-open artificial floor = %.6g\n"):format(floor_total))
io.write("marginal necessity of each opened group (close it ALONE):\n")
local opened = {}
for b in pairs(placed) do opened[#opened + 1] = b end
table.sort(opened)
for _, b in ipairs(opened) do
    local solo = {}
    for k in pairs(groups) do solo[k] = k ~= b or nil end
    local total = select(1, phase1(solo))
    local needed = total and (total > floor_total + ART_TOL)
    io.write(("  %-52s %s (art=%.6g)\n"):format(b,
        needed and "NEEDED" or "not needed", total or -1))
end
