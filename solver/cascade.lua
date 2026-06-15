-- The cascade: the shipped staged-rescue pipeline approximating the problem
-- definition's 5-tier lexicographic optimum (target >> producible imports >>
-- makeup imports >> consumable dumps >> machines) on the ship build shape.
--
-- A single weighted LP trades every tier at FINITE exchange rates (the cost
-- ladder), so any chain whose collateral-per-unit exceeds a rate is rationally
-- defeated -- all-or-nothing. The reference solver
-- (tests/research/reference_solver.lua) fixes that lexicographically with
-- staged budget-locked solves; the cascade is its lazy, ship-shaped
-- approximation, validated corpus-wide by tests/research/probe_vp_rescue.lua
-- (1678 pyanodon explorer problems: 91% reference ties; 97% on the Space Age
-- explorer set). Pipeline, paid only when the corresponding defeat actually
-- flows:
--
--   baseline   the plain ship-cost solve. UN-gated: no reachability gate, no
--              soft gate -- under the full rescue pipeline the gate is a
--              solve-count damper, not a quality device, and its price
--              pressure hides the very cheats the stages detect (k=1/256/4096
--              corpus A/B, 2026-06-13).
--   T          the lexicographic target rescue (manage/pre_solve.lua
--              M.target_rescue_step, shipped separately). Its settled budget
--              -- or the baseline's current target level -- threads into
--              every cascade build as the target_budget row: a stage whose
--              makeup exceeds target_cost per target unit would otherwise
--              reintroduce the tier-1 collapse through this pipeline.
--   Vp         producible-import rescue. Classify the FLOWING import hatches
--              by producibility (the joint synthetic-demand fixpoint, lazy:
--              prescreen joint -> individual screens -> demote-one -> promote
--              sweeps, plus ONE support probe that reveals the import support
--              the rescue itself wants -- whack-a-mole partners, from-zero
--              feedstock); price the producible (and every never-flowed)
--              hatch as the only objective, lock the optimum, re-solve at
--              ship costs under the lock.
--   Vf         makeup-import rescue: minimize the complement (the hatches Vp
--              does not price -- no extra adjudication), lock, re-solve.
--   Vc         consumable-dump rescue ("consume what you can without buying
--              extra imports for it" -- the Vf lock threads even when the Vf
--              stage never fired, or this stage would buy makeup to consume
--              dumps). Consumability classification is the approx form:
--              per-material INDIVIDUAL tests over the flowing dumps plus one
--              support probe's discoveries, never-flowed sinks priced
--              wholesale, NO joint phase -- the joint demote-one is what
--              mis-demoted innocents on a partial universe, so dropping it
--              removes the regression mechanism (cache-free, hole-free; the
--              full fixpoint only beats it via per-recipe-set caching that
--              real edit cycles never hit).
--   polish     machine minimization under every established budget. The
--              lowest tier, so the stage solution IS the final solution: one
--              extra solve. Adoption requires the win to exceed the grading
--              REL -- that threshold is the margin-spend guard (the polish
--              gladly converts the budget rows' slack into a machine win of
--              the same order, which grades as an upper-tier loss).
--
-- Fallbacks, fired when a ship-cost final diverges (the budget row pins live
-- hatch variables against sum <= ~0, a face the IPM interior cannot
-- approach; only sound because the stage solution witnesses feasibility):
--   deletion final  DELETE the priced hatches (create_problem hatch_exclude)
--                   and re-run the final on the structural face.
--   staged relay    ship-cost finals diverge on this problem outright (the
--                   optimum is a full fabricate cascade the 2^20-tier cost
--                   regime cannot converge to): every stage adopts its own
--                   stage solution -- the reference's exact staged shape.
--
-- This module is pure (no Factorio runtime, no tests/ dependency) so the
-- headless suite drives it directly. It owns only the DATA: pre_solve runs
-- the actual solves across the incremental solver's ticks and calls
-- M.begin / M.advance between them; each call either settles or leaves
-- state.build describing the next solve (M.build_options + M.shape_problem
-- turn a build into a Problem). The state is plain string/number/bool
-- tables -- it rides solution.cascade in `storage` and needs no metatable on
-- load. Every table iteration that feeds an output is sorted, so the state
-- is byte-identical across multiplayer clients.

local create_problem = require "solver/create_problem"
local vk = require "solver/var_key"
local tn = require "manage/typed_name"
local fs_log = require "fs_log"

local log = fs_log.for_module("solver.cascade")

local M = {}

-- Tunables, verbatim from the corpus-validated probe (probe_vp_rescue.lua).
M.TRIGGER = 1e-4 -- stage trigger: below the grader's ABS tie threshold, dust not worth the solves
M.FLOW_TH = 1e-4 -- an escape above this is "flowing" (classification universe membership)
M.FIX_TOL = 1e-4 -- fixpoint own-residual dust threshold (= the reference's)
M.ADOPT_REL = 5e-3 -- stage adoption threshold; REL on purpose -- the margin-spend guard
M.BUDGET_REL, M.BUDGET_ABS = 1e-3, 1e-6
local EPS_RECIPE = 2 ^ -20 -- stage face regularizer (the reference's). NOT a tie-break: it lets recipes run at near-zero cost so a fix-test measures whether a material is producible. Raising it (tried 2^-6) makes recipes costly enough that fix-tests prefer import, mis-classifying producibility (cold drifts to Vp=832 vs ref 0 on seed_100). Keep at the reference's value.

---Budget-row limit over a stage optimum: relative slack for the IPM's
---relative-residual convergence plus an absolute floor when the optimum is 0.
---@param opt number
---@return number
function M.budget(opt) return opt * (1 + M.BUDGET_REL) + M.BUDGET_ABS end

---Whether a build MUST be solved cold (no warm seed). A classification-
---determining build reads which variables are nonzero (a fix-test's own-escape
---residual for the verdict; a support probe's flow for the universe growth) --
---a vertex-dependent read on a degenerate face. A warm seed picks a different
---optimal vertex than the cold Mehrotra central path that the reference solves
---on, so warming these builds corrupts the classification (and does so
---non-deterministically). Measured: warming every cascade build off the previous
---solve drifts SA30 to tie 304 (45 verdict diffs vs the cold 349, far past the
---4-row self-diff floor) and runs 4.3x more IPM iterations; colding the
---classification builds restores the cold/reference verdicts within noise. The
---heavy stage / final / polish builds read only optimal VALUES (unique), so they
---may warm. The driver (pre_solve's pump, the probe) honours this; cascade.lua
---only declares it.
---@param build CascadeBuild
---@return boolean
function M.is_cold(build) return build.fix ~= nil or build.cold == true end

--------------------------------------------------------------------------------
-- Small helpers (deterministic by construction).
--------------------------------------------------------------------------------

---@param set table<string, true>
---@return string[]
local function sorted_keys(set)
    local t = {}
    for k in pairs(set) do t[#t + 1] = k end
    table.sort(t)
    return t
end

---@param list string[]
---@return table<string, true>
local function list_to_set(list)
    local s = {}
    for _, k in ipairs(list) do s[k] = true end
    return s
end

---@param x table<string, number>
---@param keys string[]
---@return number
local function sum_keys(x, keys)
    local s = 0
    for _, key in ipairs(keys) do s = s + math.abs(x[key] or 0) end
    return s
end

---@param set table<string, true>
---@return integer
local function count(set)
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    return n
end

---Per-material own-escape residuals of a fix-test solution: sum |x| over the
---priced-kind escapes of the given materials.
---@param problem Problem
---@param x table<string, number>
---@param priced_kind string
---@param priced_set table<string, true>
---@return table<string, number>
local function own_residuals(problem, x, priced_kind, priced_set)
    local own = {}
    for key, p in pairs(problem.primals) do
        if p.kind == priced_kind and p.material and priced_set[p.material] then
            own[p.material] = (own[p.material] or 0) + math.abs(x[key] or 0)
        end
    end
    return own
end

---The strict intermediate set: material variable names both produced and
---consumed by the line set (counting fuel). Temperature bridges are injected
---by create_problem, not present in the caller's normalized lines, yet they
---produce/consume the range-form fluid variables -- without them a bridge-fed
---material looks consumed-only and its |initial_source| import escapes the
---defeat accounting.
---@param lines NormalizedProductionLine[]
---@return table<string, true>
function M.intermediates(lines)
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

--------------------------------------------------------------------------------
-- Build descriptors. A CascadeBuild is a plain, storage-safe description of
-- one solve; pre_solve turns it into a Problem with
-- create_problem(..., M.build_options(build)) + M.shape_problem(problem, build).
--------------------------------------------------------------------------------

---create_problem options for a build. Fix tests run on the bare structural
---problem (the reference's shape: every escape-hatch heuristic off); every
---other build is the un-gated ship shape carrying the target budget and, once
---the deletion fallback fired, the hatch exclusion.
---@param build CascadeBuild
---@return CreateProblemOptions
function M.build_options(build)
    if build.fix then
        return { deficit_seeding = false, catalyst_closure = false, reachability_gating = false }
    end
    return {
        reachability_gating = false,
        target_budget = build.target_budget,
        hatch_exclude = build.hatch_exclude,
    }
end

---Apply a build's post-construction shape: budget-lock rows first (their
---slack variables then fall into the cost loop's else-branch), then the stage
---objective. Ship-cost finals only add rows; fix tests get the synthetic
---demand probes (one free probe variable forced to 1 unit into the material
---row, exactly the reference's fixpoint mechanics).
---@param problem Problem
---@param build CascadeBuild
function M.shape_problem(problem, build)
    if build.fix then
        local priced = list_to_set(build.fix.priced)
        for _, p in pairs(problem.primals) do
            if p.kind == build.fix.priced_kind and p.material and priced[p.material] then
                p.cost = 1
            elseif p.kind == "recipe" or p.kind == "bridge" then
                p.cost = EPS_RECIPE
            else
                p.cost = 0
            end
        end
        for _, mat in ipairs(build.fix.demand) do
            local probe = vk.cascade_probe(mat)
            problem:add_objective(probe, 0, false, nil, mat)
            problem:add_subject_term(probe, mat, build.fix.demand_sign)
            local dual = vk.cascade_demand(mat)
            problem:add_lower_limit_constraint(dual, 1)
            problem:add_subject_term(probe, dual, 1)
        end
        return
    end
    for _, lock in ipairs(build.locks or {}) do
        local dual = vk.cascade_budget(lock.tier)
        problem:add_upper_limit_constraint(dual, lock.limit)
        for _, key in ipairs(lock.keys) do
            -- A lock key can be absent from this build (the deletion fallback
            -- removed its hatch); the lock row simply loses that term.
            if problem.primals[key] then problem:add_subject_term(key, dual, 1) end
        end
    end
    if build.stage_keys then
        local priced = list_to_set(build.stage_keys)
        for key, p in pairs(problem.primals) do
            if priced[key] then
                p.cost = 1
            elseif p.kind == "recipe" or p.kind == "bridge" then
                p.cost = EPS_RECIPE
            else
                p.cost = 0
            end
        end
    elseif build.stage_machine then
        for _, p in pairs(problem.primals) do
            if p.kind == "recipe" then
                p.cost = 1
            elseif p.kind == "bridge" then
                p.cost = EPS_RECIPE
            else
                p.cost = 0
            end
        end
    end
end

--------------------------------------------------------------------------------
-- State machine internals. Each enter_*/settle function either sets
-- state.build + state.phase (a solve is wanted) or chains into the next
-- stage; M.advance dispatches a finished/terminal solve back into the chain.
--------------------------------------------------------------------------------

---@param state CascadeState
---@param phase string
---@param build CascadeBuild
local function set_build(state, phase, build)
    state.phase = phase
    state.build = build
    -- The next solve will overwrite solution.raw_variables, so the held
    -- answer no longer matches the adopted one until adopt() runs again.
    state.current_adopted = false
    log.debug("cascade -> %s", phase)
end

---A ship-shaped build: target budget always threaded, the hatch exclusion
---sticky once the deletion fallback fired.
---@param state CascadeState
---@param extra CascadeBuild?
---@return CascadeBuild
local function ship_build(state, extra)
    local b = extra or {}
    b.target_budget = state.t_limit
    b.hatch_exclude = state.hatch_exclude
    return b
end

---@param priced_kind string
---@param demand_sign number
---@param mats string[]
---@return CascadeBuild
local function fix_build(priced_kind, demand_sign, mats)
    return { fix = { priced_kind = priced_kind, demand_sign = demand_sign, priced = mats, demand = mats } }
end

---Enumerate the variables the stages read, sorted by key: the import hatches
---(|shortage_source|, plus |initial_source| into an intermediate -- the
---defeat accounting must not let deficit seeding rebook an import as free),
---the dumps (|surplus_sink|), and the recipe variables (the machine count).
---@param problem Problem
---@param intermediates table<string, true>
---@return CascadeEntry[] imports, CascadeEntry[] sinks, string[] recipes
local function capture_entries(problem, intermediates)
    local imports, sinks, recipes = {}, {}, {}
    for key, p in pairs(problem.primals) do
        if p.material and (p.kind == "shortage_source"
                or (p.kind == "initial_source" and intermediates[p.material])) then
            imports[#imports + 1] = { key = key, material = p.material }
        elseif p.kind == "surplus_sink" and p.material then
            sinks[#sinks + 1] = { key = key, material = p.material }
        elseif p.kind == "recipe" then
            recipes[#recipes + 1] = key
        end
    end
    local by_key = function(a, b) return a.key < b.key end
    table.sort(imports, by_key)
    table.sort(sinks, by_key)
    table.sort(recipes)
    return imports, sinks, recipes
end

---Adopt a finished solve as the cascade's current answer: later stages
---measure their baselines on it, and the finalizer restores it when the last
---stage's result was rejected.
---@param state CascadeState
---@param problem Problem
---@param raw PackedVariables
---@param build CascadeBuild
local function adopt(state, problem, raw, build)
    state.adopted_raw = raw
    state.adopted_build = build
    state.current_adopted = true
    state.imports, state.sinks, state.recipes = capture_entries(problem, state.intermediates)
    state.m_adopted = sum_keys(raw.x, state.recipes)
end

---The locks established so far, in tier order. Stage locks are recorded at
---the CURRENT level even when their stage never fired (the hole-plugging
---rule: a free prior tier would be the next tier's whack-a-mole hole); the
---Vp lock is absent when nothing flowed or the deletion fallback removed the
---hatches outright.
---@param state CascadeState
---@param vp boolean
---@param vf boolean
---@param vc boolean
---@return CascadeLock[]
local function current_locks(state, vp, vf, vc)
    local locks = {}
    if vp and state.vp_lock_keys and state.vp_lock_limit then
        locks[#locks + 1] = { tier = "vp", keys = state.vp_lock_keys, limit = state.vp_lock_limit }
    end
    if vf and state.vf_lock_keys and state.vf_lock_limit then
        locks[#locks + 1] = { tier = "vf", keys = state.vf_lock_keys, limit = state.vf_lock_limit }
    end
    if vc and state.vc_lock_keys and state.vc_lock_limit then
        locks[#locks + 1] = { tier = "vc", keys = state.vc_lock_keys, limit = state.vc_lock_limit }
    end
    return locks
end

-- Forward declarations: the chain is written top-down but wired bottom-up.
local start_vp_fixpoint, vp_fixpoint_settle, vp_promote_init, vp_fixpoint_done,
vp_price, enter_vf, enter_vc, vc_after_individual, vc_price, enter_polish, finalize

---Start (or restart, after the support probe grew the universe) the
---producibility fixpoint over state.vp_univ. Individual verdicts survive the
---restart (the individual test prices only the material itself, so it is
---universe-independent); members are re-derived.
---@param state CascadeState
start_vp_fixpoint = function(state)
    state.vp_members = {}
    state.vp_coupled = false
    state.vp_demoted = {}
    local mats = sorted_keys(state.vp_univ)
    if #mats == 1 then
        -- No joint context to prescreen or demote: the individual verdict IS
        -- the classification.
        local mat = mats[1]
        local v = state.vp_verdicts[mat]
        if v ~= nil then
            if v then state.vp_members[mat] = true end
            return vp_fixpoint_done(state)
        end
        state.vp_pending = { mat }
        return set_build(state, "vp_individual", fix_build("shortage_source", -1, { mat }))
    end
    -- Joint PRESCREEN: the joint prices and demands a superset of the
    -- individual test, so joint-clean is the harder certificate; only the
    -- violators pay the individual screen.
    set_build(state, "vp_prescreen", fix_build("shortage_source", -1, mats))
end

---After phase 1 (prescreen + individual screens): joint demote-one only when
---a coupled violator re-joined (couples need >= 2 members; otherwise the
---prescreen certificate stands).
---@param state CascadeState
vp_fixpoint_settle = function(state)
    if state.vp_coupled and count(state.vp_members) >= 2 then
        state.vp_demote_rounds = 0
        return set_build(state, "vp_demote",
            fix_build("shortage_source", -1, sorted_keys(state.vp_members)))
    end
    vp_promote_init(state)
end

---Phase 3: promotion sweeps over the phase-2 demotions (re-test each against
---the settled set; promote when the WHOLE trial set is clean).
---@param state CascadeState
vp_promote_init = function(state)
    if #state.vp_demoted == 0 then return vp_fixpoint_done(state) end
    state.vp_sweeps_left = #state.vp_demoted
    state.vp_promoted_any = false
    state.vp_promote_queue = {}
    for _, mat in ipairs(state.vp_demoted) do
        if not state.vp_members[mat] then
            state.vp_promote_queue[#state.vp_promote_queue + 1] = mat
        end
    end
    if #state.vp_promote_queue == 0 then return vp_fixpoint_done(state) end
    local trial = { state.vp_promote_queue[1] }
    for _, mat in ipairs(sorted_keys(state.vp_members)) do trial[#trial + 1] = mat end
    table.sort(trial)
    set_build(state, "vp_promote", fix_build("shortage_source", -1, trial))
end

---Classification settled. ONE support probe (members priced, all else
---genuinely free) reveals the import support the rescue wants -- whack-a-mole
---partners, from-zero feedstock -- then the grown universe is adjudicated
---once more and the stage runs straight through.
---@param state CascadeState
vp_fixpoint_done = function(state)
    if not state.vp_support_done then
        state.vp_support_done = true
        local member_keys = {}
        for _, e in ipairs(state.imports) do
            if state.vp_members[e.material] then member_keys[#member_keys + 1] = e.key end
        end
        if #member_keys > 0 then
            -- cold: this probe's nonzero set grows the classification universe
            -- (a vertex-dependent read); a warm seed would drift the universe.
            return set_build(state, "vp_support", ship_build(state, { stage_keys = member_keys, cold = true }))
        end
    end
    vp_price(state)
end

---Priced = adjudicated members plus every never-flowed hatch (default-P,
---hole-safe); adjudicated makeup (universe minus members) is free. Then the
---Vp stage proper, when the priced flow clears the trigger.
---@param state CascadeState
vp_price = function(state)
    local priced = {}
    for _, e in ipairs(state.imports) do
        if state.vp_members[e.material] or not state.vp_univ[e.material] then
            priced[#priced + 1] = e.key
        end
    end
    state.vp_priced = priced
    local vp0 = sum_keys(state.adopted_raw.x, priced)
    state.vp0 = vp0
    state.vp_lock_keys, state.vp_lock_limit = priced, M.budget(math.max(vp0, 0))
    if #priced == 0 or vp0 <= M.TRIGGER then return enter_vf(state) end
    set_build(state, "vp_stage", ship_build(state, { stage_keys = priced }))
end

---The Vf tier. The makeup complement and its lock are computed even when the
---stage does not fire: the Vc stage threads the Vf budget regardless --
---without the lock it would buy makeup to consume dumps, the exact inversion
---the definition's ordering forbids.
---@param state CascadeState
enter_vf = function(state)
    local vpset = list_to_set(state.vp_lock_keys or {})
    local makeup = {}
    for _, e in ipairs(state.imports) do
        if not vpset[e.key] then makeup[#makeup + 1] = e.key end
    end
    state.vf_lock_keys = makeup
    local vf0 = sum_keys(state.adopted_raw.x, makeup)
    state.vf0 = vf0
    state.vf_lock_limit = M.budget(math.max(vf0, 0))
    if #makeup == 0 or vf0 <= M.TRIGGER then return enter_vc(state) end
    set_build(state, "vf_stage", ship_build(state, {
        stage_keys = makeup,
        locks = current_locks(state, true, false, false),
    }))
end

---The Vc tier (consumability = approx). Trigger pre-check on the FLAT sum
---first: the priced subset can only be smaller, so below the trigger the
---adjudication is not worth its solves. Even then the NEXT tier (the polish)
---needs a Vc ceiling, or it freely grows consumable dumps to shed machines --
---with nothing flowing the lock is the flat sum over every sink (over-strict
---only on the freedom to grow dumps from nothing).
---@param state CascadeState
enter_vc = function(state)
    local flat0, nflow = 0, 0
    state.vc_univ = {}
    for _, e in ipairs(state.sinks) do
        local v = math.abs(state.adopted_raw.x[e.key] or 0)
        flat0 = flat0 + v
        if v > M.FLOW_TH and not state.vc_univ[e.material] then
            state.vc_univ[e.material] = true
            nflow = nflow + 1
        end
    end
    state.vc0 = flat0
    if flat0 <= M.TRIGGER or nflow == 0 then
        local all = {}
        for _, e in ipairs(state.sinks) do all[#all + 1] = e.key end
        state.vc_lock_keys = all
        state.vc_lock_limit = M.budget(math.max(flat0, 0))
        return enter_polish(state)
    end
    -- Individual screens over the flowing dumps. The individual test is the
    -- reference's own phase 1, trustworthy in both directions on the surplus
    -- side; the joint refinements it forgoes cost only no-headroom misses
    -- (coupled ties keep both partners priced), never holes.
    state.vc_members = {}
    local pending = {}
    for _, mat in ipairs(sorted_keys(state.vc_univ)) do
        local v = state.vc_verdicts[mat]
        if v == nil then
            pending[#pending + 1] = mat
        elseif v then
            state.vc_members[mat] = true
        end
    end
    state.vc_pending = pending
    if #pending > 0 then
        return set_build(state, "vc_individual", fix_build("surplus_sink", 1, { pending[1] }))
    end
    vc_after_individual(state)
end

---After the first round of individual screens: one support probe (members
---priced under the full lock set -- the stage's own environment, all else
---free); where the displaced surplus flows is the support to adjudicate.
---@param state CascadeState
vc_after_individual = function(state)
    if not state.vc_support_done then
        state.vc_support_done = true
        if next(state.vc_members) then
            local member_keys = {}
            for _, e in ipairs(state.sinks) do
                if state.vc_members[e.material] then member_keys[#member_keys + 1] = e.key end
            end
            return set_build(state, "vc_support", ship_build(state, {
                stage_keys = member_keys,
                locks = current_locks(state, true, true, false),
                cold = true, -- universe-growth probe: vertex-dependent, must not warm
            }))
        end
    end
    vc_price(state)
end

---Priced = consumable members plus every never-flowed sink; then the Vc stage
---proper when the priced surplus clears the trigger.
---@param state CascadeState
vc_price = function(state)
    local priced = {}
    for _, e in ipairs(state.sinks) do
        if state.vc_members[e.material] or not state.vc_univ[e.material] then
            priced[#priced + 1] = e.key
        end
    end
    local vc0 = sum_keys(state.adopted_raw.x, priced)
    state.vc0 = vc0
    state.vc_lock_keys, state.vc_lock_limit = priced, M.budget(math.max(vc0, 0))
    if #priced == 0 or vc0 <= M.TRIGGER then return enter_polish(state) end
    set_build(state, "vc_stage", ship_build(state, {
        stage_keys = priced,
        locks = current_locks(state, true, true, false),
    }))
end

---The machine polish (the lowest tier; its stage solution is final).
---@param state CascadeState
enter_polish = function(state)
    state.m0 = state.m_adopted
    set_build(state, "polish", ship_build(state, {
        stage_machine = true,
        locks = current_locks(state, true, true, true),
    }))
end

---The pipeline has consumed its last solve. When the held answer is not the
---adopted one (the last stage's result was rejected), ask pre_solve to
---rebuild the adopted shape and restore the adopted answer -- a build, not a
---solve.
---@param state CascadeState
finalize = function(state)
    if state.current_adopted then
        state.phase = "done"
        state.build = nil
        log.debug("cascade settled: %d solves", state.solves)
    else
        state.phase = "restore"
        state.build = state.adopted_build
        log.debug("cascade settled (restoring adopted answer): %d solves", state.solves)
    end
end

--------------------------------------------------------------------------------
-- Public driver.
--------------------------------------------------------------------------------

---Start a cascade on a finished (target-rescued) baseline. Always leaves
---state.build set: the pipeline ends with the polish, so at least one stage
---solve is wanted.
---@param problem Problem The baseline build.
---@param raw PackedVariables The baseline's packed solution.
---@param lines NormalizedProductionLine[]
---@param rescue_budget number? The settled target-rescue budget, when one was locked.
---@return CascadeState
function M.begin(problem, raw, lines, rescue_budget)
    ---@type CascadeState
    local state = {
        phase = "start",
        solves = 0,
        intermediates = M.intermediates(lines),
        vp_univ = {}, vp_members = {}, vp_verdicts = {}, vp_demoted = {},
        vc_verdicts = {},
    }
    adopt(state, problem, raw, { target_budget = rescue_budget })

    -- The target budget threads into EVERY cascade build, rescued or not: a
    -- stage whose makeup can exceed target_cost per target unit would
    -- otherwise reintroduce the tier-1 collapse through this pipeline.
    local T = 0
    for key, p in pairs(problem.primals) do
        if p.kind == "elastic" then T = T + math.abs(raw.x[key] or 0) end
    end
    state.t_limit = rescue_budget or M.budget(T)

    local nflow = 0
    for _, e in ipairs(state.imports) do
        if not state.vp_univ[e.material] and math.abs(raw.x[e.key] or 0) > M.FLOW_TH then
            state.vp_univ[e.material] = true
            nflow = nflow + 1
        end
    end
    if nflow == 0 then
        -- Nothing flowing to classify: no Vp adjudication and no Vp lock
        -- (every hatch is the Vf tier's makeup).
        enter_vf(state)
    else
        start_vp_fixpoint(state)
    end
    return state
end

---Consume the finished (or terminally failed) solve of state.build and chain
---to the next phase. On return either state.build holds the next wanted
---solve, or state.phase == "restore" (rebuild state.build WITHOUT solving and
---restore state.adopted_raw), or state.phase == "done".
---@param state CascadeState
---@param problem Problem The just-solved build.
---@param raw PackedVariables? Its packed solution (nil only on a hard failure).
---@param solver_state SolverState
function M.advance(state, problem, raw, solver_state)
    local done_build = state.build
    state.build = nil
    state.solves = state.solves + 1
    local finished = solver_state == "finished" and raw ~= nil and raw.x ~= nil
    local x = raw and raw.x or nil
    local phase = state.phase

    if phase == "vp_prescreen" then
        local mats = sorted_keys(state.vp_univ)
        local pending = {}
        if finished then
            local own = own_residuals(problem, x, "shortage_source", state.vp_univ)
            for _, mat in ipairs(mats) do
                if (own[mat] or 0) <= M.FIX_TOL then
                    state.vp_members[mat] = true
                else
                    local v = state.vp_verdicts[mat]
                    if v == nil then
                        pending[#pending + 1] = mat
                    elseif v then
                        -- An individually-passing violator re-joins: a coupled
                        -- tie -- it can push formerly-clean members over, so
                        -- the demote-one phase must run.
                        state.vp_members[mat] = true
                        state.vp_coupled = true
                    end
                end
            end
        else
            -- Prescreen unfinished: fall back to full individual screening,
            -- and run phase 2 since no joint certificate exists.
            state.vp_coupled = true
            for _, mat in ipairs(mats) do
                local v = state.vp_verdicts[mat]
                if v == nil then
                    pending[#pending + 1] = mat
                elseif v then
                    state.vp_members[mat] = true
                end
            end
        end
        state.vp_pending = pending
        if #pending > 0 then
            return set_build(state, "vp_individual", fix_build("shortage_source", -1, { pending[1] }))
        end
        return vp_fixpoint_settle(state)
    elseif phase == "vp_individual" then
        local mat = state.vp_pending[1]
        local pass = false
        if finished then
            local own = own_residuals(problem, x, "shortage_source", { [mat] = true })
            pass = (own[mat] or 0) <= M.FIX_TOL
        end
        state.vp_verdicts[mat] = pass
        if pass then
            state.vp_members[mat] = true
            state.vp_coupled = true
        end
        table.remove(state.vp_pending, 1)
        if state.vp_pending[1] then
            return set_build(state, "vp_individual",
                fix_build("shortage_source", -1, { state.vp_pending[1] }))
        end
        return vp_fixpoint_settle(state)
    elseif phase == "vp_demote" then
        local mats = sorted_keys(state.vp_univ)
        if finished then
            local own = own_residuals(problem, x, "shortage_source", state.vp_members)
            local worst, wamt = nil, M.FIX_TOL
            for _, mat in ipairs(mats) do
                local amt = own[mat] or 0
                if state.vp_members[mat] and amt > wamt then worst, wamt = mat, amt end
            end
            if worst then
                state.vp_members[worst] = nil
                state.vp_demoted[#state.vp_demoted + 1] = worst
                state.vp_demote_rounds = state.vp_demote_rounds + 1
                if state.vp_demote_rounds <= #mats and count(state.vp_members) >= 1 then
                    return set_build(state, "vp_demote",
                        fix_build("shortage_source", -1, sorted_keys(state.vp_members)))
                end
            end
        end
        return vp_promote_init(state)
    elseif phase == "vp_promote" then
        local mat = state.vp_promote_queue[1]
        if finished then
            local trial = { [mat] = true }
            for m in pairs(state.vp_members) do trial[m] = true end
            local own = own_residuals(problem, x, "shortage_source", trial)
            local clean = true
            for m in pairs(trial) do
                if (own[m] or 0) > M.FIX_TOL then clean = false; break end
            end
            if clean then
                state.vp_members[mat] = true
                state.vp_promoted_any = true
            end
        end
        table.remove(state.vp_promote_queue, 1)
        while state.vp_promote_queue[1] and state.vp_members[state.vp_promote_queue[1]] do
            table.remove(state.vp_promote_queue, 1)
        end
        if state.vp_promote_queue[1] then
            local next_mat = state.vp_promote_queue[1]
            local trial = { next_mat }
            for _, m in ipairs(sorted_keys(state.vp_members)) do trial[#trial + 1] = m end
            table.sort(trial)
            return set_build(state, "vp_promote", fix_build("shortage_source", -1, trial))
        end
        state.vp_sweeps_left = state.vp_sweeps_left - 1
        if state.vp_promoted_any and state.vp_sweeps_left > 0 then
            state.vp_promoted_any = false
            for _, m in ipairs(state.vp_demoted) do
                if not state.vp_members[m] then
                    state.vp_promote_queue[#state.vp_promote_queue + 1] = m
                end
            end
            if state.vp_promote_queue[1] then
                local next_mat = state.vp_promote_queue[1]
                local trial = { next_mat }
                for _, m in ipairs(sorted_keys(state.vp_members)) do trial[#trial + 1] = m end
                table.sort(trial)
                return set_build(state, "vp_promote", fix_build("shortage_source", -1, trial))
            end
        end
        return vp_fixpoint_done(state)
    elseif phase == "vp_support" then
        if finished then
            local grew = false
            for _, e in ipairs(state.imports) do
                if not state.vp_univ[e.material] and math.abs(x[e.key] or 0) > M.FLOW_TH then
                    state.vp_univ[e.material] = true
                    grew = true
                end
            end
            -- The union is adjudicated once more (individual verdicts cached;
            -- the joint phases re-run on the grown universe).
            if grew then return start_vp_fixpoint(state) end
        end
        return vp_price(state)
    elseif phase == "vp_stage" then
        if not finished then
            state.vp_rescued = -1
            return enter_vf(state)
        end
        local vpmin = sum_keys(x, state.vp_priced)
        state.vpmin = vpmin
        if state.vp0 - vpmin <= math.max(M.TRIGGER, state.vp0 * M.ADOPT_REL) then
            -- No headroom: improvements inside the grading tolerance are not
            -- worth the final solve, and the tighter lock would pin the lower
            -- tiers for nothing.
            state.vp_rescued = -1
            return enter_vf(state)
        end
        -- Keep the stage answer around: the staged-relay fallback adopts it
        -- when ship-cost finals prove unconvergeable on this problem.
        state.vp_stage_raw = raw
        state.vp_stage_build = done_build
        return set_build(state, "vp_final", ship_build(state, {
            locks = { { tier = "vp", keys = state.vp_priced, limit = M.budget(vpmin) } },
        }))
    elseif phase == "vp_final" then
        if finished then
            adopt(state, problem, raw, done_build)
            state.vp_rescued = 1
            state.vp_lock_limit = M.budget(state.vpmin)
            state.vp_stage_raw, state.vp_stage_build = nil, nil
            return enter_vf(state)
        end
        if state.vpmin > M.TRIGGER then
            -- The final diverged but the stage did NOT prove a ~zero face:
            -- no witness that deleting the hatches stays feasible. Keep the
            -- baseline.
            state.vp_rescued = -1
            state.vp_stage_raw, state.vp_stage_build = nil, nil
            return enter_vf(state)
        end
        -- Deletion final: the budget row pins LIVE hatch variables against
        -- sum <= ~0, a face the IPM interior cannot approach -- but the stage
        -- proved Vp_min ~ 0, so the hatches can be removed outright (elastic
        -- necessity is not violated; the stage solution is the witness). The
        -- lock row disappears with the variables.
        local mats = {}
        local priced_set = list_to_set(state.vp_priced)
        for _, e in ipairs(state.imports) do
            if priced_set[e.key] then mats[e.material] = true end
        end
        state.hatch_exclude = mats
        state.vp_lock_keys, state.vp_lock_limit = nil, nil
        return set_build(state, "vp_deletion", ship_build(state, {}))
    elseif phase == "vp_deletion" then
        if finished then
            adopt(state, problem, raw, done_build)
            state.vp_rescued = 1
            state.vp_deleted = 1
            state.vp_stage_raw, state.vp_stage_build = nil, nil
            return enter_vf(state)
        end
        -- Staged relay: ship-cost finals diverge on this problem outright.
        -- Adopt the Vp stage solution and let every later stage adopt its own
        -- stage solution too -- the reference's exact staged shape.
        state.relay = true
        state.vp_rescued = 1
        state.vp_deleted = 2
        state.adopted_raw = state.vp_stage_raw
        state.adopted_build = state.vp_stage_build
        state.current_adopted = false
        -- The stage build shares the baseline's variable space, so the entry
        -- captures stay; only the machine total moves.
        state.m_adopted = sum_keys(state.adopted_raw.x, state.recipes)
        state.vp_stage_raw, state.vp_stage_build = nil, nil
        return enter_vf(state)
    elseif phase == "vf_stage" then
        if not finished then
            state.vf_rescued = -1
            return enter_vc(state)
        end
        local vfmin = sum_keys(x, state.vf_lock_keys)
        state.vfmin = vfmin
        if state.relay then
            adopt(state, problem, raw, done_build)
            state.vf_rescued = 1
            state.vf_lock_limit = M.budget(vfmin)
            return enter_vc(state)
        end
        if state.vf0 - vfmin <= math.max(M.TRIGGER, state.vf0 * M.ADOPT_REL) then
            state.vf_rescued = -1
            return enter_vc(state)
        end
        local locks = current_locks(state, true, false, false)
        locks[#locks + 1] = { tier = "vf", keys = state.vf_lock_keys, limit = M.budget(vfmin) }
        return set_build(state, "vf_final", ship_build(state, { locks = locks }))
    elseif phase == "vf_final" then
        if finished then
            adopt(state, problem, raw, done_build)
            state.vf_rescued = 1
            state.vf_lock_limit = M.budget(state.vfmin)
        else
            state.vf_rescued = -1
        end
        return enter_vc(state)
    elseif phase == "vc_individual" then
        local mat = state.vc_pending[1]
        local pass = false
        if finished then
            local own = own_residuals(problem, x, "surplus_sink", { [mat] = true })
            pass = (own[mat] or 0) <= M.FIX_TOL
        end
        state.vc_verdicts[mat] = pass
        if pass then state.vc_members[mat] = true end
        table.remove(state.vc_pending, 1)
        if state.vc_pending[1] then
            return set_build(state, "vc_individual",
                fix_build("surplus_sink", 1, { state.vc_pending[1] }))
        end
        return vc_after_individual(state)
    elseif phase == "vc_support" then
        if finished then
            local pending = {}
            for _, e in ipairs(state.sinks) do
                if not state.vc_univ[e.material] and math.abs(x[e.key] or 0) > M.FLOW_TH then
                    state.vc_univ[e.material] = true
                    local v = state.vc_verdicts[e.material]
                    if v == nil then
                        pending[#pending + 1] = e.material
                    elseif v then
                        state.vc_members[e.material] = true
                    end
                end
            end
            if #pending > 0 then
                state.vc_pending = pending
                return set_build(state, "vc_individual",
                    fix_build("surplus_sink", 1, { pending[1] }))
            end
        end
        return vc_price(state)
    elseif phase == "vc_stage" then
        if not finished then
            state.vc_rescued = -1
            return enter_polish(state)
        end
        local vcmin = sum_keys(x, state.vc_lock_keys)
        state.vcmin = vcmin
        if state.relay then
            adopt(state, problem, raw, done_build)
            state.vc_rescued = 1
            state.vc_lock_limit = M.budget(vcmin)
            return enter_polish(state)
        end
        if state.vc0 - vcmin <= math.max(M.TRIGGER, state.vc0 * M.ADOPT_REL) then
            state.vc_rescued = -1
            return enter_polish(state)
        end
        local locks = current_locks(state, true, true, false)
        locks[#locks + 1] = { tier = "vc", keys = state.vc_lock_keys, limit = M.budget(vcmin) }
        return set_build(state, "vc_final", ship_build(state, { locks = locks }))
    elseif phase == "vc_final" then
        if finished then
            adopt(state, problem, raw, done_build)
            state.vc_rescued = 1
            state.vc_lock_limit = M.budget(state.vcmin)
        else
            state.vc_rescued = -1
        end
        return enter_polish(state)
    elseif phase == "polish" then
        if finished then
            local mmin = sum_keys(x, state.recipes)
            state.mmin = mmin
            -- The REL threshold is the margin-spend guard, not noise
            -- protection: the polish converts the budget locks' slack into a
            -- machine win of the same order, and a margin-sized win grades as
            -- an upper-tier loss. Real polishes clear it untouched.
            if state.m0 - mmin > math.max(M.TRIGGER, state.m0 * M.ADOPT_REL) then
                adopt(state, problem, raw, done_build)
                state.polish = 1
            else
                state.polish = -1
            end
        else
            state.polish = -1
        end
        return finalize(state)
    end

    -- Unknown phase (corrupt state): settle on whatever is adopted.
    log.warn("cascade advance on unexpected phase '%s'", tostring(phase))
    return finalize(state)
end

return M
