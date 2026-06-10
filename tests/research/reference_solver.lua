---@diagnostic disable: undefined-global
-- Reference solver for the problem DEFINITION (user, 2026-06-11): the exact
-- 3-tier lexicographic optimum, solved as three staged LPs.
--
--   tier 1  minimize target violation        (kind == "elastic")
--   tier 2  minimize intermediate violation  (shortage_source + surplus_sink,
--           SYMMETRIC -- shortage and surplus are the same rank)
--   tier 3  minimize machine count           (sum of recipe variables; x IS the
--           machine count -- manage/report.lua reads it as
--           quantity_of_machines_required)
--
-- Each stage re-solves with the next tier as the objective and the previous
-- tiers locked by budget rows (sum <= optimum * (1+REL) + ABS). The build is
-- the bare structural problem -- every shipped escape-hatch heuristic off
-- (no deficit promotion, no catalyst closure, no reachability gate, no soft
-- gate, no observe-price): consumed-only materials get a free initial_source,
-- produced-only a free final_sink, produced-and-consumed (intermediates) get
-- the symmetric shortage/surplus violation pair. Costs are overridden per
-- stage, so the build's own cost tiers never matter here.
--
-- Stages keep a tiny epsilon on recipe/bridge variables so the optimal face
-- stays bounded for the IPM (futile zero-cost loops would otherwise drift);
-- the epsilon is ~2^-20 per machine, far below one violation unit, and tier 3
-- prices recipes at 1 anyway.
--
-- This is RESEARCH code: the gold answer to grade the shipped solver against,
-- not a production path.

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local tn = require "manage/typed_name"

local M = {}

M.OPTS = { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
M.TOL, M.ITER = 1e-7, 800
local EPS_RECIPE = 2 ^ -20  -- face regularizer (stages 1-2) / bridge tie-break (stage 3)
local BUDGET_REL, BUDGET_ABS = 1e-3, 1e-6

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = M.TOL, iterate_limit = M.ITER }) end

---Sum |x| over primals of the given kinds.
---@param problem Problem
---@param x table<string, number>
---@param kinds table<string, true>
---@return number
function M.total_of(problem, x, kinds)
    local s = 0
    for key, p in pairs(problem.primals) do
        if kinds[p.kind] then s = s + math.abs(x[key] or 0) end
    end
    return s
end

M.TARGET_KINDS = { elastic = true }
M.VIOLATION_KINDS = { shortage_source = true, surplus_sink = true }
M.MACHINE_KINDS = { recipe = true }

---The strict intermediate set: material variable names both produced and
---consumed by the line set (counting fuel). Needed to measure a SHIPPED-config
---solution with the definition's yardstick: the deficit-seeding heuristic gives
---some intermediates a free |initial_source|, which under the definition is
---still consumption > production -- a violation -- so flows through it must be
---counted, not reclassified away. (The reference build itself never promotes
---intermediates, so for reference solutions this set changes nothing.)
---@param lines NormalizedProductionLine[]
---@return table<string, true>
function M.intermediates(lines)
    -- Temperature bridges are injected by create_problem, not present in the
    -- caller's normalized lines, yet they produce/consume the range-form fluid
    -- variables -- without them a bridge-fed material (steam@[15,2000]) looks
    -- consumed-only and its import escapes the violation count (seed_109's
    -- false "ship wins": 12.5 steam rebooked as a free deficit source).
    local all = {}
    for _, line in ipairs(lines) do all[#all + 1] = line end
    for _, line in ipairs(create_problem.create_temperature_bridges(lines)) do all[#all + 1] = line end
    local produced, consumed = {}, {}
    for _, line in ipairs(all) do
        for _, prod in ipairs(line.products) do
            produced[tn.typed_name_to_variable_name(prod)] = true
        end
        if line.fuel_burnt_result then
            produced[tn.typed_name_to_variable_name(line.fuel_burnt_result)] = true
        end
        for _, ing in ipairs(line.ingredients) do
            consumed[tn.typed_name_to_variable_name(ing)] = true
        end
        if line.fuel_ingredient then
            consumed[tn.typed_name_to_variable_name(line.fuel_ingredient)] = true
        end
    end
    local both = {}
    for k in pairs(produced) do if consumed[k] then both[k] = true end end
    return both
end

---Tier-2 violation of a solution under the DEFINITION: symmetric
---shortage + surplus, plus any initial_source flow into an intermediate
---(see M.intermediates).
---@param problem Problem
---@param x table<string, number>
---@param intermediates table<string, true>
---@return number
function M.violation_of(problem, x, intermediates)
    local s = 0
    for key, p in pairs(problem.primals) do
        if M.VIOLATION_KINDS[p.kind] then
            s = s + math.abs(x[key] or 0)
        elseif p.kind == "initial_source" and p.material and intermediates[p.material] then
            s = s + math.abs(x[key] or 0)
        end
    end
    return s
end

---Build the bare structural problem and apply one stage's objective: `unit`
---kinds cost 1, recipe/bridge cost EPS_RECIPE (unless in `unit`), all else 0.
---`budgets` is a list of { kinds, limit } -- each adds one row capping the
---summed kinds at limit.
local function build_stage(constraints, lines, unit, budgets)
    local problem = create_problem.create_problem("reference", constraints, lines, nil, M.OPTS)
    for _, p in pairs(problem.primals) do
        if unit[p.kind] then
            p.cost = 1
        elseif p.kind == "recipe" or p.kind == "bridge" then
            p.cost = EPS_RECIPE
        else
            p.cost = 0
        end
    end
    for i, b in ipairs(budgets or {}) do
        local dual = "|reference_budget|" .. i
        problem:add_upper_limit_constraint(dual, b.limit)
        for key, p in pairs(problem.primals) do
            if b.kinds[p.kind] then problem:add_subject_term(key, dual, 1) end
        end
    end
    return problem
end

local function budget(opt) return opt * (1 + BUDGET_REL) + BUDGET_ABS end

---Solve the 3-stage lexicographic reference. Returns per-stage totals plus the
---final solution; `state` is "finished" only when all three stages finished.
---@param constraints table
---@param lines NormalizedProductionLine[]
---@return { state: string, T: number, V: number, M: number, steps: integer,
---  problem: Problem?, x: table<string, number>? }
function M.solve_reference(constraints, lines)
    local steps_total = 0

    -- Stage 1: minimize target violation.
    local p1 = build_stage(constraints, lines, M.TARGET_KINDS, nil)
    local s1, v1, st1 = solve(p1)
    steps_total = steps_total + st1
    if s1 ~= "finished" then return { state = "s1-" .. s1, T = -1, V = -1, M = -1, steps = steps_total } end
    local T = M.total_of(p1, v1.x, M.TARGET_KINDS)

    -- Stage 2: minimize symmetric intermediate violation under the target budget.
    local p2 = build_stage(constraints, lines, M.VIOLATION_KINDS,
        { { kinds = M.TARGET_KINDS, limit = budget(T) } })
    local s2, v2, st2 = solve(p2)
    steps_total = steps_total + st2
    if s2 ~= "finished" then return { state = "s2-" .. s2, T = T, V = -1, M = -1, steps = steps_total } end
    local V = M.total_of(p2, v2.x, M.VIOLATION_KINDS)

    -- Stage 3: minimize machines under both budgets.
    local p3 = build_stage(constraints, lines, M.MACHINE_KINDS,
        { { kinds = M.TARGET_KINDS, limit = budget(T) },
            { kinds = M.VIOLATION_KINDS, limit = budget(V) } })
    local s3, v3, st3 = solve(p3)
    steps_total = steps_total + st3
    if s3 ~= "finished" then return { state = "s3-" .. s3, T = T, V = V, M = -1, steps = steps_total } end
    local Mach = M.total_of(p3, v3.x, M.MACHINE_KINDS)

    return { state = "finished", T = T, V = V, M = Mach, steps = steps_total, problem = p3, x = v3.x }
end

return M
