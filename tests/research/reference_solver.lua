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
--   tier 2a  imports of PRODUCIBLE materials ("could make it, outsourced it"
--            -- the defeat)
--   tier 2b  imports of NON-producible materials (the legitimate makeup
--            boundary; minimized so a pure mass-losing cycle still RUNS --
--            makeup 0.75 < direct product import 1.0 -- instead of the
--            all-zero direct-import degenerate)
--   tier 2c  dumps of CONSUMABLE materials ("could consume it, trashed it" --
--            the dual defeat the user caught by inspecting frozen reference
--            solutions in the GUI: with dump entirely free, tier 3 actively
--            prefers NOT running a placed consumer, because consuming costs
--            machines). Ranked BELOW the makeup budget deliberately: at one
--            rank with the import defeats, a mass-losing cycle's operating
--            dumps (its members are consumable by the mirror of mass-positive
--            being producible) outlaw RUNNING the cycle and the all-zero
--            direct import returns (measured: seed_24 fell back to Vf=1.0,
--            and seed_109 bought +5.7 makeup to consume a 0.5 dump). Below
--            the budget it means exactly "consume what you can without buying
--            extra imports for it" -- raw and machines may still be spent.
-- where producibility / consumability are mirror greatest fixpoints (see
-- M.producible_set): M is producible iff the lines can net-produce M without
-- importing M itself; M is consumable iff they can net-absorb one unit of M
-- without dumping M itself -- everything else free in both tests. A
-- mass-losing cycle material needs itself as makeup, so it tests
-- non-producible; a mass-POSITIVE breeding loop's forced surplus tests
-- non-consumable (its only consumers net-produce it back), so its dump stays
-- legitimate -- the drill_seed18 verdict ("dumping the brood is correct")
-- falls out of the dual.
-- Non-consumable dump carries no penalty anywhere -- gratuitous
-- over-production is suppressed by tier 3 (running machines to dump costs
-- machines). SYMMETRIC_KINDS keeps the literal flat "production must equal
-- consumption" reading available for A/B.
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
---Shared engine for the two mirror fixpoints. `priced_kind` is the escape that
---must stay at zero for membership (shortage_source for producibility,
---surplus_sink for consumability); `demand_sign` is the synthetic probe's
---coefficient into the material row (-1 = a sink demanding net production,
---+1 = a source injecting a unit to absorb).
---
---Three phases (a joint demote-only sweep is ORDER-SENSITIVE: other demands
---pull a bulk flow through an innocent member, it reads as the worst offender,
---and once demoted it never recovers -- seed_109's water@[15,500], bridge-fed
---from free water@15, was misclassified as makeup that way and blocked the
---byproduct consumption the user expected):
---  1 individual screening: one LP per material, only it priced and demanded.
---    An individual failure can never pass under a stricter set (monotone), so
---    those are demoted immediately and finally.
---  2 joint demote-one over the survivors: only genuinely coupled ties remain
---    (a 2+ member mass-losing cycle where each member passes individually by
---    importing its partner); demoting the worst picks one makeup per tie.
---  3 promotion sweeps: re-test each phase-2 demotion against the settled set
---    (joint with it added back); promote when the WHOLE trial set is clean.
---@param constraints table
---@param lines NormalizedProductionLine[]
---@param priced_kind string
---@param demand_sign number
---@return table<string, true> members, integer n_tested, integer steps
local function fixpoint_set(constraints, lines, priced_kind, demand_sign)
    local base = create_problem.create_problem("reference", constraints, lines, nil, M.OPTS)
    local mats = {}
    for _, p in pairs(base.primals) do
        if p.kind == priced_kind and p.material then mats[#mats + 1] = p.material end
    end
    table.sort(mats)

    local TOL = 1e-4
    local steps_total = 0
    local TRACE = os.getenv("FS_REF_TRACE") ~= nil
    local function trace(fmt, ...) if TRACE then io.stderr:write(fmt:format(...) .. "\n") end end

    ---Price `priced_set` materials, demand one unit of each `demand_list`
    ---material, solve, and return the per-material own-escape residuals
    ---(nil when the solve did not finish).
    ---@param priced_set table<string, true>
    ---@param demand_list string[]
    ---@return table<string, number>? own
    local function joint_residuals(priced_set, demand_list)
        local p = create_problem.create_problem("fixtest", constraints, lines, nil, M.OPTS)
        for _, pr in pairs(p.primals) do
            if pr.kind == priced_kind and priced_set[pr.material] then
                pr.cost = 1
            elseif pr.kind == "recipe" or pr.kind == "bridge" then
                pr.cost = EPS_RECIPE
            else
                pr.cost = 0
            end
        end
        for _, mat in ipairs(demand_list) do
            local probe = "|ref_fixtest_probe|" .. mat
            p:add_objective(probe, 0, false, nil, mat)
            p:add_subject_term(probe, mat, demand_sign)
            local dual = "|ref_fixtest_demand|" .. mat
            p:add_lower_limit_constraint(dual, 1)
            p:add_subject_term(probe, dual, 1)
        end
        local ok, s, v, st = pcall(solve, p)
        if not ok or s ~= "finished" then return nil end
        steps_total = steps_total + st
        local own = {}
        for key, pr in pairs(p.primals) do
            if pr.kind == priced_kind and priced_set[pr.material] then
                own[pr.material] = (own[pr.material] or 0) + math.abs(v.x[key] or 0)
            end
        end
        return own
    end

    local function member_list(set)
        local list = {}
        for _, mat in ipairs(mats) do
            if set[mat] then list[#list + 1] = mat end
        end
        return list
    end

    -- Phase 1: individual screening.
    local members = {}
    for _, mat in ipairs(mats) do
        local own = joint_residuals({ [mat] = true }, { mat })
        if own and (own[mat] or 0) <= TOL then
            members[mat] = true
        else
            trace("[%s] phase1 FAIL %s (own=%s)", priced_kind, mat, own and tostring(own[mat]) or "unfinished")
        end
    end

    -- Phase 2: joint demote-one over the coupled ties.
    local tie_demoted = {}
    for _ = 1, #mats + 1 do
        local own = joint_residuals(members, member_list(members))
        if not own then break end
        local worst, wamt = nil, TOL
        for _, mat in ipairs(mats) do
            local amt = own[mat] or 0
            if members[mat] and amt > wamt then worst, wamt = mat, amt end
        end
        if not worst then break end
        trace("[%s] phase2 demote %s (own=%g)", priced_kind, worst, wamt)
        members[worst] = nil
        tie_demoted[#tie_demoted + 1] = worst
    end

    -- Phase 3: promotion sweeps over the phase-2 demotions.
    for _ = 1, #tie_demoted do
        local promoted = false
        for _, mat in ipairs(tie_demoted) do
            if not members[mat] then
                local trial = { [mat] = true }
                for m in pairs(members) do trial[m] = true end
                local own = joint_residuals(trial, member_list(trial))
                if own then
                    local clean, dirty, damt = true, nil, 0
                    for m in pairs(trial) do
                        if (own[m] or 0) > TOL then clean = false; dirty, damt = m, own[m]; break end
                    end
                    if clean then
                        members[mat] = true; promoted = true
                        trace("[%s] phase3 promote %s", priced_kind, mat)
                    else
                        trace("[%s] phase3 reject %s (dirty %s=%g)", priced_kind, mat, tostring(dirty), damt)
                    end
                else
                    trace("[%s] phase3 reject %s (unfinished)", priced_kind, mat)
                end
            end
        end
        if not promoted then break end
    end

    return members, #mats, steps_total
end

---@param constraints table
---@param lines NormalizedProductionLine[]
---@return table<string, true> producible, integer n_tested, integer steps
function M.producible_set(constraints, lines)
    return fixpoint_set(constraints, lines, "shortage_source", -1)
end

---Mirror of M.producible_set: M is consumable iff the line set can net-absorb
---one injected unit of M without dumping M itself (everything else free).
---@param constraints table
---@param lines NormalizedProductionLine[]
---@return table<string, true> consumable, integer n_tested, integer steps
function M.consumable_set(constraints, lines)
    return fixpoint_set(constraints, lines, "surplus_sink", 1)
end

---Split a solution's boundary mass by legitimacy: defeat imports (producible
---material), defeat dumps (consumable material), legitimate makeup imports
---(non-producible). Imports count shortage_source plus initial_source flows
---into intermediates (a heuristic build's deficit promotion must not rebook an
---import as free); dumps count surplus_sink only.
---@param problem Problem
---@param x table<string, number>
---@param intermediates table<string, true>
---@param producible table<string, true>
---@param consumable table<string, true>
---@return number Vp, number Vc, number Vf
function M.violation_split(problem, x, intermediates, producible, consumable)
    local vp, vc, vf = 0, 0, 0
    for key, p in pairs(problem.primals) do
        local is_import = p.kind == "shortage_source"
            or (p.kind == "initial_source" and p.material and intermediates[p.material])
        if is_import then
            local v = math.abs(x[key] or 0)
            if producible[p.material] then vp = vp + v else vf = vf + v end
        elseif p.kind == "surplus_sink" and consumable[p.material] then
            vc = vc + math.abs(x[key] or 0)
        end
    end
    return vp, vc, vf
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

---Solve the staged lexicographic reference:
---  target violation >> producible imports (defeat) >> non-producible imports
---  (legitimate makeup) >> consumable dumps (dual defeat) >> machines.
---All reported totals are measured on the FINAL solution (the budget rows keep
---them within (1+BUDGET_REL) of each stage's optimum). `state` is "finished"
---only when every stage finished.
---@param constraints table
---@param lines NormalizedProductionLine[]
---@return { state: string, T: number, Vp: number, Vc: number, Vf: number,
---  M: number, S: number, steps: integer, n_mats: integer, problem: Problem?,
---  x: table<string, number>?, producible: table<string, true>,
---  consumable: table<string, true> }
function M.solve_reference(constraints, lines)
    local producible, np_mats, steps_p = M.producible_set(constraints, lines)
    local consumable, _, steps_c = M.consumable_set(constraints, lines)

    local is_target = function(p) return p.kind == "elastic" end
    local is_prod_short = function(p) return p.kind == "shortage_source" and producible[p.material] end
    local is_cons_surplus = function(p) return p.kind == "surplus_sink" and consumable[p.material] end
    local is_free_short = function(p) return p.kind == "shortage_source" and not producible[p.material] end
    local is_machine = function(p) return p.kind == "recipe" end

    local r = { state = "finished", T = -1, Vp = -1, Vc = -1, Vf = -1, M = -1, S = -1,
        steps = steps_p + steps_c, n_mats = np_mats,
        producible = producible, consumable = consumable }

    -- Stage 1: minimize target violation.
    local p1 = build_stage(constraints, lines, is_target, nil)
    local s1, v1, st1 = solve(p1)
    r.steps = r.steps + st1
    if s1 ~= "finished" then r.state = "s1-" .. s1; return r end
    local T = sum_if(p1, v1.x, is_target)
    local budgets = { { fn = is_target, limit = budget(T) } }

    -- Stage 2a: minimize the import defeats under the target budget.
    local p2 = build_stage(constraints, lines, is_prod_short, budgets)
    local s2, v2, st2 = solve(p2)
    r.steps = r.steps + st2
    if s2 ~= "finished" then r.state = "s2a-" .. s2; return r end
    budgets[#budgets + 1] = { fn = is_prod_short, limit = budget(sum_if(p2, v2.x, is_prod_short)) }

    -- Stage 2b: minimize legitimate makeup imports under both budgets.
    local p3 = build_stage(constraints, lines, is_free_short, budgets)
    local s3, v3, st3 = solve(p3)
    r.steps = r.steps + st3
    if s3 ~= "finished" then r.state = "s2b-" .. s3; return r end
    budgets[#budgets + 1] = { fn = is_free_short, limit = budget(sum_if(p3, v3.x, is_free_short)) }

    -- Stage 2c: minimize the dump defeats with the makeup budget already
    -- locked ("consume what you can without buying extra imports for it").
    local p4 = build_stage(constraints, lines, is_cons_surplus, budgets)
    local s4, v4, st4 = solve(p4)
    r.steps = r.steps + st4
    if s4 ~= "finished" then r.state = "s2c-" .. s4; return r end
    budgets[#budgets + 1] = { fn = is_cons_surplus, limit = budget(sum_if(p4, v4.x, is_cons_surplus)) }

    -- Stage 3: minimize machines under all four budgets.
    local p5 = build_stage(constraints, lines, is_machine, budgets)
    local s5, v5, st5 = solve(p5)
    r.steps = r.steps + st5
    if s5 ~= "finished" then r.state = "s3-" .. s5; return r end

    r.T = sum_if(p5, v5.x, is_target)
    r.Vp = sum_if(p5, v5.x, is_prod_short)
    r.Vc = sum_if(p5, v5.x, is_cons_surplus)
    r.Vf = sum_if(p5, v5.x, is_free_short)
    r.M = sum_if(p5, v5.x, is_machine)
    r.S = M.total_of(p5, v5.x, M.SURPLUS_KINDS)
    r.problem, r.x = p5, v5.x
    return r
end

return M
