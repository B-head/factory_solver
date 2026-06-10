---@diagnostic disable: undefined-global
-- Reference solver for the problem DEFINITION (user, 2026-06-11): the exact
-- 3-tier lexicographic optimum, solved as three staged LPs.
--
--   tier 1  minimize target violation        (kind == "elastic")
--   tier 2  minimize intermediate violation  (configurable kinds; see below)
--   tier 3  minimize machine count           (sum of recipe variables; x IS the
--           machine count -- manage/report.lua reads it as
--           quantity_of_machines_required)
--
-- Tier 2 scoring is under adjudication by case votes (the user holds NO firm
-- premise on shortage/surplus symmetry -- "looks symmetric" only). The current
-- candidate splits tier 2 by PRODUCIBILITY, because the defeat the user named
-- ("the solver outsourcing a makeable material to some other factory") is
-- positional, not quantitative -- per-unit counting always parks the import
-- boundary downstream whenever the upstream feed outweighs the product
-- (seed_17: formamide 718k/s vs fish 6.7k/s):
--   tier 2a  imports of PRODUCIBLE materials (the defeat; should reach its
--            structural minimum, usually 0)
--   tier 2b  imports of NON-producible materials (the legitimate makeup
--            boundary; minimized so a pure mass-losing cycle still RUNS --
--            makeup 0.75 < direct product import 1.0 -- instead of the
--            all-zero direct-import degenerate)
-- where: M is PRODUCIBLE iff the line set can net-produce M without importing
-- M itself, every OTHER material freely importable (one LP per material; no
-- fixpoint -- chained producibles resolve at stage-2a solve time, since the
-- whole producible set is minimized simultaneously). A mass-losing cycle
-- material needs itself as makeup, so it tests non-producible; a breeder /
-- boiler product tests producible no matter how heavy its feed is.
-- Dump carries no penalty anywhere -- gratuitous over-production is suppressed
-- by tier 3 (running machines to dump costs machines). SYMMETRIC_KINDS keeps
-- the literal "production must equal consumption" reading available for A/B.
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
M.SHORTAGE_KINDS = { shortage_source = true }
M.SYMMETRIC_KINDS = { shortage_source = true, surplus_sink = true }
M.VIOLATION_KINDS = M.SHORTAGE_KINDS -- the candidate under adjudication
M.SURPLUS_KINDS = { surplus_sink = true }
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

---Tier-2 violation of a solution: the configured violation kinds, plus any
---initial_source flow into an intermediate (see M.intermediates) -- a heuristic
---build's deficit promotion must not rebook an import as free.
---@param problem Problem
---@param x table<string, number>
---@param intermediates table<string, true>
---@param kinds table<string, true>? Defaults to M.VIOLATION_KINDS.
---@return number
function M.violation_of(problem, x, intermediates, kinds)
    kinds = kinds or M.VIOLATION_KINDS
    local s = 0
    for key, p in pairs(problem.primals) do
        if kinds[p.kind] then
            s = s + math.abs(x[key] or 0)
        elseif p.kind == "initial_source" and p.material and intermediates[p.material] then
            s = s + math.abs(x[key] or 0)
        end
    end
    return s
end

---Jointly-producible set (greatest fixpoint). A per-material test ("M makeable
---with every OTHER material importable") is too generous: in a 2+ material
---mass-losing cycle each member tests producible by importing its partner, yet
---the set cannot internalize itself. So instead: start with every
---shortage-carrying material presumed producible (set P), demand one unit of
---EVERY P material simultaneously through synthetic sinks, price only
---P-shortages, and solve once; a P material whose own shortage stays above
---dust at the optimum cannot be internalized jointly. Demote ONE offender per
---round (the largest shortage; name as the deterministic tie-break) and
---re-solve -- demoting the true leak frees it as makeup and can RESCUE its
---downstream (demoting everything at once would cascade: lignin falls with the
---fuel leak that made it unmakeable, and never recovers). A whack-a-mole pair
---(either of X/Y could be the makeup) resolves to one chosen makeup and one
---still-fabricated member -- the factory keeps running.
---Targets are ignored (elastic free) -- producibility is a property of the
---recipe set, not of what the user asked for. A non-finished round demotes
---nothing and stops the iteration (conservative for tier 2a: fewer defeats).
---@param constraints table
---@param lines NormalizedProductionLine[]
---@return table<string, true> producible, integer n_tested, integer steps
function M.producible_set(constraints, lines)
    local base = create_problem.create_problem("reference", constraints, lines, nil, M.OPTS)
    local mats = {}
    for _, p in pairs(base.primals) do
        if p.kind == "shortage_source" and p.material then mats[#mats + 1] = p.material end
    end
    table.sort(mats)

    local producible = {}
    for _, mat in ipairs(mats) do producible[mat] = true end

    local steps_total = 0
    for _ = 1, #mats + 1 do
        local p = create_problem.create_problem("prodtest", constraints, lines, nil, M.OPTS)
        for _, pr in pairs(p.primals) do
            if pr.kind == "shortage_source" and producible[pr.material] then
                pr.cost = 1
            elseif pr.kind == "recipe" or pr.kind == "bridge" then
                pr.cost = EPS_RECIPE
            else
                pr.cost = 0
            end
        end
        for _, mat in ipairs(mats) do
            if producible[mat] then
                local sink = "|ref_prodtest_sink|" .. mat
                p:add_objective(sink, 0, false, nil, mat)
                p:add_subject_term(sink, mat, -1)
                local dual = "|ref_prodtest_demand|" .. mat
                p:add_lower_limit_constraint(dual, 1)
                p:add_subject_term(sink, dual, 1)
            end
        end

        local ok, s, v, st = pcall(solve, p)
        if not ok or s ~= "finished" then break end
        steps_total = steps_total + st

        local own = {}
        for key, pr in pairs(p.primals) do
            if pr.kind == "shortage_source" and producible[pr.material] then
                own[pr.material] = (own[pr.material] or 0) + math.abs(v.x[key] or 0)
            end
        end
        local worst, wamt = nil, 1e-4
        for _, mat in ipairs(mats) do
            local amt = own[mat] or 0
            if producible[mat] and amt > wamt then worst, wamt = mat, amt end
        end
        if not worst then break end
        producible[worst] = nil
    end
    return producible, #mats, steps_total
end

---Split a solution's import mass by producibility: defeat imports (producible
---material) vs legitimate makeup (non-producible). Counts shortage_source plus
---initial_source flows into intermediates (a heuristic build's deficit
---promotion must not rebook an import as free).
---@param problem Problem
---@param x table<string, number>
---@param intermediates table<string, true>
---@param producible table<string, true>
---@return number Vp, number Vf
function M.violation_split(problem, x, intermediates, producible)
    local vp, vf = 0, 0
    for key, p in pairs(problem.primals) do
        local counts = p.kind == "shortage_source"
            or (p.kind == "initial_source" and p.material and intermediates[p.material])
        if counts then
            local v = math.abs(x[key] or 0)
            if producible[p.material] then vp = vp + v else vf = vf + v end
        end
    end
    return vp, vf
end

---Build the bare structural problem and apply one stage's objective: primals
---matched by `unit_fn` cost 1, recipe/bridge cost EPS_RECIPE (unless matched),
---all else 0. `budgets` is a list of { fn, limit } -- each adds one row capping
---the matched primals' sum at limit.
local function build_stage(constraints, lines, unit_fn, budgets)
    local problem = create_problem.create_problem("reference", constraints, lines, nil, M.OPTS)
    for _, p in pairs(problem.primals) do
        if unit_fn(p) then
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
            if b.fn(p) then problem:add_subject_term(key, dual, 1) end
        end
    end
    return problem
end

local function budget(opt) return opt * (1 + BUDGET_REL) + BUDGET_ABS end

local function sum_if(problem, x, fn)
    local s = 0
    for key, p in pairs(problem.primals) do
        if fn(p) then s = s + math.abs(x[key] or 0) end
    end
    return s
end

---Solve the 4-stage lexicographic reference:
---  target violation >> producible imports (defeat) >> non-producible imports
---  (legitimate makeup) >> machines.
---`state` is "finished" only when every stage finished.
---@param constraints table
---@param lines NormalizedProductionLine[]
---@return { state: string, T: number, Vp: number, Vf: number, M: number,
---  S: number, steps: integer, n_mats: integer, problem: Problem?,
---  x: table<string, number>?, producible: table<string, true> }
function M.solve_reference(constraints, lines)
    local producible, n_mats, steps_total = M.producible_set(constraints, lines)

    local is_target = function(p) return p.kind == "elastic" end
    local is_prod_short = function(p) return p.kind == "shortage_source" and producible[p.material] end
    local is_free_short = function(p) return p.kind == "shortage_source" and not producible[p.material] end

    local r = { state = "finished", T = -1, Vp = -1, Vf = -1, M = -1, S = -1,
        steps = steps_total, n_mats = n_mats, producible = producible }

    -- Stage 1: minimize target violation.
    local p1 = build_stage(constraints, lines, is_target, nil)
    local s1, v1, st1 = solve(p1)
    r.steps = r.steps + st1
    if s1 ~= "finished" then r.state = "s1-" .. s1; return r end
    r.T = sum_if(p1, v1.x, is_target)
    local budgets = { { fn = is_target, limit = budget(r.T) } }

    -- Stage 2a: minimize defeat imports under the target budget.
    local p2 = build_stage(constraints, lines, is_prod_short, budgets)
    local s2, v2, st2 = solve(p2)
    r.steps = r.steps + st2
    if s2 ~= "finished" then r.state = "s2a-" .. s2; return r end
    r.Vp = sum_if(p2, v2.x, is_prod_short)
    budgets[#budgets + 1] = { fn = is_prod_short, limit = budget(r.Vp) }

    -- Stage 2b: minimize legitimate makeup imports under both budgets.
    local p3 = build_stage(constraints, lines, is_free_short, budgets)
    local s3, v3, st3 = solve(p3)
    r.steps = r.steps + st3
    if s3 ~= "finished" then r.state = "s2b-" .. s3; return r end
    r.Vf = sum_if(p3, v3.x, is_free_short)
    budgets[#budgets + 1] = { fn = is_free_short, limit = budget(r.Vf) }

    -- Stage 3: minimize machines under all three budgets.
    local p4 = build_stage(constraints, lines, function(p) return p.kind == "recipe" end, budgets)
    local s4, v4, st4 = solve(p4)
    r.steps = r.steps + st4
    if s4 ~= "finished" then r.state = "s3-" .. s4; return r end
    r.M = sum_if(p4, v4.x, function(p) return p.kind == "recipe" end)
    r.S = M.total_of(p4, v4.x, M.SURPLUS_KINDS)
    r.problem, r.x = p4, v4.x
    return r
end

return M
