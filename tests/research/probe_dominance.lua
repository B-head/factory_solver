---@diagnostic disable: undefined-global
-- Dominance audit: is the shipped solution Pareto-dominated on its escapes?
--
-- For every solved corpus problem, take each ACTIVE elastic e (the three
-- escape/relaxation kinds: shortage_source = import, surplus_sink = dump,
-- elastic = target relaxation) and ask the LP itself whether e could have been
-- lower WITHOUT the moves the improvement definition forbids. Per candidate we
-- re-solve an auxiliary LP where:
--   * e's cost is raised to DRIVE_COST so the LP pushes it as low as the
--     remaining freedom allows (reading min_e off the solution avoids picking
--     an arbitrary reduction delta);
--   * baseline-parked variables are REMOVED from the restricted problem (the
--     "do not activate a zero variable" clause as a hard pin; a cost pin at
--     2^26 was tried first and stalled the IPM -- ~100 huge-cost columns x
--     the x=100 cold-start made the path numerically hopeless);
--   * every OTHER active elastic gets a hard upper-limit row at
--     baseline*(1+CAP_MARGIN) (no whack-a-mole: the relief must not move to a
--     neighbouring escape).
-- Two modes per candidate:
--   strict  pin all parked non-slack variables, cap all three elastic kinds.
--           Pure within-support Pareto dominance.
--   fab     the user's asymmetric improvement definition: parked recipes /
--           bridges / initial_source / final_sink stay FREE (fabrication and
--           extra raw are allowed), surplus_sink is FREE both ways (byproduct
--           dump is acceptable), only new imports (parked shortage_source) and
--           target relaxation (parked elastic) stay pinned, and only active
--           shortage/target elastics are capped.
-- min_e << base_e means a dominating solution exists under that mode's rules
-- (subject to cap_viol staying at dust level) -- evidence the cost vector
-- mispriced this escape. RAW numbers only, no verdict.
--
-- Single-shot (run_corpus): `lua probe_dominance.lua <onefile>` prints one
-- base row plus one row per candidate x mode (rows start with the label;
-- -Collect '^seed=' drops the header).
--
-- Usage:
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_dominance.lua -Collect '^seed=' -Out <tsv>
--   <lua> tests/research/probe_dominance.lua [--manifest <list>] [--out <tsv>] <dump...>

require "tests/headless_env"

local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local problem_dump = require "tests/problem_dump"
local R = require "tests/research/research_lib"

local TOL, ITER = 1e-7, 800
local DRIVE_COST = 2 ^ 22 -- push the candidate elastic to its constrained minimum
local CAP_MARGIN = 1e-3   -- headroom so the baseline point stays strictly interior to the caps
local MAX_CANDIDATES = 40 -- compute guard; the base row reports how many were dropped

local ELASTIC_KINDS = { shortage_source = true, surplus_sink = true, elastic = true }

-- Kinds pinned when parked, per mode. "slack" is row plumbing and never pinned.
local PIN_KINDS = {
    strict = { recipe = true, bridge = true, shortage_source = true, surplus_sink = true,
        elastic = true, initial_source = true, final_sink = true },
    fab = { shortage_source = true, elastic = true },
}
-- Active-elastic kinds capped at baseline, per mode.
local CAP_KINDS = {
    strict = { shortage_source = true, surplus_sink = true, elastic = true },
    fab = { shortage_source = true, elastic = true },
}

local function solve(p) return harness.solve_to_completion(lp, p, { tolerance = TOL, iterate_limit = ITER }) end

local problem_generator = require "solver/problem_generator"

---Rebuild `problem` without the primal variables in `drop` (the hard pin).
---Duals are kept only while at least one surviving primal still references
---them; a dropped dual is always a limit==0 row whose every contributor was
---parked (keeping it would put an all-zero row into A and break Cholesky).
---A dropped dual with limit > 0 would mean the baseline was infeasible there,
---so it is asserted against rather than silently kept.
---@param problem Problem
---@param drop table<string, true>
---@return Problem
local function restricted(problem, drop)
    local q = problem_generator.new(problem.name .. "_dom")
    for k, p in pairs(problem.primals) do
        if not drop[k] then q:add_objective(k, p.cost, p.is_result, p.kind, p.material) end
    end
    local used = {}
    for k, terms in pairs(problem.subject_terms) do
        if q.primals[k] then
            for d, coeff in pairs(terms) do
                q:add_subject_term(k, d, coeff)
                used[d] = true
            end
        end
    end
    for d, dual in pairs(problem.duals) do
        if used[d] then
            q:add_equivalence_constraint(d, dual.limit)
        else
            assert(dual.limit == 0, "restricted: dropped a dual with limit > 0: " .. d)
        end
    end
    return q
end

---Sum |x| per escape kind plus initial_source, in one pass.
local function totals(problem, x)
    local t = { shortage_source = 0, surplus_sink = 0, elastic = 0, initial_source = 0 }
    for key, p in pairs(problem.primals) do
        if t[p.kind] then t[p.kind] = t[p.kind] + math.abs(x[key] or 0) end
    end
    return t
end

---Objective of solution x under the ORIGINAL cost map (so pinned/driven runs
---stay comparable to the baseline economy).
local function objective_under(costs, x)
    local o = 0
    for k, c in pairs(costs) do o = o + c * math.abs(x[k] or 0) end
    return o
end

local COLS = { "label", "mode", "ekey", "kind", "mat", "base_e", "min_e", "state", "steps",
    "cap_viol", "sh", "su", "tg", "init", "act_new", "obj_orig", "nE", "npin", "trunc" }

local function process(prob, label, emit)
    -- Baseline: shipped create_problem defaults.
    local problem0 = R.build(prob)
    local costs0 = {}
    for k, p in pairs(problem0.primals) do costs0[k] = p.cost end
    local state0, vars0, steps0 = solve(problem0)
    local thr0 = R.park_threshold(vars0, problem0.primals)
    local x0 = vars0 and vars0.x or {}
    local tot0 = totals(problem0, x0)
    local obj0 = objective_under(costs0, x0)

    -- Active-elastic candidates, deterministic order (value desc, key asc).
    local candidates = {}
    if state0 == "finished" then
        for k, p in pairs(problem0.primals) do
            if ELASTIC_KINDS[p.kind] and math.abs(x0[k] or 0) > thr0 then
                candidates[#candidates + 1] = { key = k, kind = p.kind, mat = p.material, v = math.abs(x0[k]) }
            end
        end
        table.sort(candidates, function(a, b)
            if a.v ~= b.v then return a.v > b.v end
            return a.key < b.key
        end)
    end
    local n_all = #candidates
    local trunc = 0
    if n_all > MAX_CANDIDATES then
        trunc = n_all - MAX_CANDIDATES
        for i = n_all, MAX_CANDIDATES + 1, -1 do candidates[i] = nil end
    end

    -- Baseline-parked keys per pinnable kind (shared by both modes).
    local parked = {} ---@type table<string, string> key -> kind
    for k, p in pairs(problem0.primals) do
        if p.kind and p.kind ~= "slack" and math.abs(x0[k] or 0) <= thr0 then parked[k] = p.kind end
    end

    emit({ label = label, mode = "base", ekey = "-", kind = "-", mat = "-", base_e = -1, min_e = -1,
        state = state0, steps = steps0, cap_viol = -1,
        sh = tot0.shortage_source, su = tot0.surplus_sink, tg = tot0.elastic, init = tot0.initial_source,
        act_new = -1, obj_orig = obj0, nE = n_all, npin = -1, trunc = trunc })
    if state0 ~= "finished" then return end

    for _, cand in ipairs(candidates) do
        for _, mode in ipairs({ "strict", "fab" }) do
            -- Hard-pin baseline-parked variables of this mode's kinds by
            -- removing them from a restricted rebuild.
            local drop, npin = {}, 0
            for k, kind in pairs(parked) do
                if PIN_KINDS[mode][kind] then
                    drop[k] = true
                    npin = npin + 1
                end
            end
            local problem = restricted(R.build(prob), drop)
            -- Cap the OTHER active elastics of this mode's kinds at baseline.
            local caps = {} ---@type table<string, number>
            for _, other in ipairs(candidates) do
                if other.key ~= cand.key and CAP_KINDS[mode][other.kind] then
                    local cap = other.v * (1 + CAP_MARGIN)
                    local dual = "|research_domcap|" .. other.key
                    problem:add_upper_limit_constraint(dual, cap)
                    problem:add_subject_term(other.key, dual, 1)
                    caps[other.key] = cap
                end
            end
            -- Drive the candidate down.
            problem.primals[cand.key].cost = DRIVE_COST

            local ok, state, vars, steps = pcall(solve, problem)
            if not ok then
                emit({ label = label, mode = mode, ekey = cand.key, kind = cand.kind, mat = cand.mat,
                    base_e = cand.v, min_e = -1, state = "error", steps = -1, cap_viol = -1,
                    sh = -1, su = -1, tg = -1, init = -1, act_new = -1, obj_orig = -1,
                    nE = n_all, npin = npin, trunc = trunc })
            else
                local x1 = vars and vars.x or {}
                local thr1 = R.park_threshold(vars, problem.primals)
                local cap_viol = 0
                for k, cap in pairs(caps) do
                    local over = math.abs(x1[k] or 0) - cap
                    if over > cap_viol then cap_viol = over end
                end
                local act_new = 0
                for k, p in pairs(problem.primals) do
                    if p.kind == "recipe" and parked[k] and math.abs(x1[k] or 0) >= thr1 then
                        act_new = act_new + 1
                    end
                end
                local tot1 = totals(problem, x1)
                emit({ label = label, mode = mode, ekey = cand.key, kind = cand.kind, mat = cand.mat,
                    base_e = cand.v, min_e = math.abs(x1[cand.key] or 0), state = state, steps = steps,
                    cap_viol = cap_viol,
                    sh = tot1.shortage_source, su = tot1.surplus_sink, tg = tot1.elastic,
                    init = tot1.initial_source, act_new = act_new,
                    obj_orig = objective_under(costs0, x1), nE = n_all, npin = npin, trunc = trunc })
            end
        end
    end
end

-- ---- main -------------------------------------------------------------------
local out_path, manifest_path, files = nil, nil, {}
do local i = 1; while arg[i] do local a = arg[i]
    if a == "--out" then i = i + 1; out_path = arg[i]
    elseif a == "--manifest" then i = i + 1; manifest_path = arg[i]
    else files[#files + 1] = a end; i = i + 1 end end
if manifest_path then for line in io.lines(manifest_path) do line = line:gsub("%s+$", ""); if line ~= "" then files[#files + 1] = line end end end

local sink = io.write; local out_file = nil
if out_path then out_file = assert(io.open(out_path, "w")); sink = function(s) out_file:write(s) end end
local function fmt(v) if v == nil then return "NA" end if type(v) == "number" then return string.format("%.6g", v) end return tostring(v) end
if out_path then sink("#" .. table.concat(COLS, "\t") .. "\n") end
local function emit(r) local o = {}; for _, k in ipairs(COLS) do o[#o + 1] = fmt(r[k]) end; sink(table.concat(o, "\t") .. "\n") end

for _, path in ipairs(files) do
    local prob = problem_dump.load_problem(path)
    if prob then
        local label = "seed=" .. tostring(prob.meta and prob.meta.seed) .. "|" .. (path:match("([^/\\]+)%.lua$") or path)
        local ok, err = pcall(process, prob, label, emit)
        if not ok then sink("# ERROR " .. label .. ": " .. tostring(err) .. "\n") end
    end
end
if out_file then out_file:close() end
