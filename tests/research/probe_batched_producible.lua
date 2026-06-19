---@diagnostic disable: undefined-global
-- SINGLE-SHOT: can the producibility structural probe's PHASE 1 (individual screen
-- -- one LP per shortage material, the O(#mats) cost) be batched into FEWER solves
-- without changing the verdict?
--
-- The individual screen prices ONLY material M's shortage, demands 1 unit of M,
-- and frees everything else; M is producible-individually iff its own shortage
-- stays at dust. It is per-material because two members of a mass-losing CYCLE,
-- tested together, each fail by being unable to internalize the other -- a
-- contamination that only happens between materials in a common cycle (the same
-- SCC of the material dependency graph). Materials in DIFFERENT SCCs (chains /
-- independent) give the same verdict batched or alone.
--
-- So: color shortage materials by SCC; build batches holding at most ONE material
-- per SCC; one joint solve per batch reads every member's own-shortage verdict.
-- Solve count drops from #mats to the LARGEST SCC's size (1 solve when acyclic).
--
-- This proves the batching is verdict-identical to per-material phase 1 (the
-- claim), measured against ref.producible_set's own phase-1 members. Phases 2/3
-- (the coupled-tie demote/promote) are unchanged and operate on the members set.
--
--   lua tests/research/probe_batched_producible.lua <dump>

local NAME = (arg[1] or "?"):match("[^/\\]+$") or "?"
local EPS_RECIPE = 2 ^ -20
local TOL = 1e-4

local ok, line = pcall(function()
    require "tests/headless_env"
    local create_problem = require "solver/create_problem"
    local problem_dump = require "tests/problem_dump"
    local ref = require "tests/research/reference_solver"
    local lp = require "solver/linear_programming"
    local harness = require "tests/harness"
    local tn = require "manage/typed_name"
    local prob = assert(problem_dump.load_problem(arg[1]))

    -- shortage-material domain (== reference's producibility test domain)
    local base = create_problem.create_problem("scan", prob.constraints, prob.normalized_lines, nil, ref.OPTS)
    local mats = {}
    for _, p in pairs(base.primals) do
        if p.kind == "shortage_source" and p.material then mats[#mats + 1] = p.material end
    end
    table.sort(mats)

    -- material dependency graph: edge ingredient -> product over every line
    -- (plus the create_problem temperature bridges, which carry range-form fluids).
    local all = {}
    for _, l in ipairs(prob.normalized_lines) do all[#all + 1] = l end
    for _, l in ipairs(create_problem.create_temperature_bridges(prob.normalized_lines)) do all[#all + 1] = l end
    local adj, nodes = {}, {}
    local function node(v) if not adj[v] then adj[v] = {}; nodes[#nodes + 1] = v end end
    for _, l in ipairs(all) do
        local ings, prods = {}, {}
        for _, ing in ipairs(l.ingredients or {}) do ings[#ings + 1] = tn.typed_name_to_variable_name(ing) end
        if l.fuel_ingredient then ings[#ings + 1] = tn.typed_name_to_variable_name(l.fuel_ingredient) end
        for _, prd in ipairs(l.products or {}) do prods[#prods + 1] = tn.typed_name_to_variable_name(prd) end
        if l.fuel_burnt_result then prods[#prods + 1] = tn.typed_name_to_variable_name(l.fuel_burnt_result) end
        for _, i in ipairs(ings) do node(i); for _, p in ipairs(prods) do node(p); adj[i][p] = true end end
    end

    -- iterative Tarjan SCC over the material graph -> scc_id[material]
    local scc_id, idx, low, onstk, stk, S, cnt, sccn = {}, {}, {}, {}, {}, {}, 0, 0
    local function strongconnect(root)
        local work = { { v = root, ei = nil } }
        while #work > 0 do
            local top = work[#work]
            local v = top.v
            if top.ei == nil then
                cnt = cnt + 1; idx[v] = cnt; low[v] = cnt
                stk[#stk + 1] = v; onstk[v] = true
                top.succ = {}; for w in pairs(adj[v]) do top.succ[#top.succ + 1] = w end
                top.ei = 0
            end
            local advanced = false
            while top.ei < #top.succ do
                top.ei = top.ei + 1
                local w = top.succ[top.ei]
                if idx[w] == nil then
                    work[#work + 1] = { v = w, ei = nil }; advanced = true; break
                elseif onstk[w] then
                    if idx[w] < low[v] then low[v] = idx[w] end
                end
            end
            if advanced then goto continue end
            if low[v] == idx[v] then
                sccn = sccn + 1
                while true do
                    local w = stk[#stk]; stk[#stk] = nil; onstk[w] = false; scc_id[w] = sccn
                    if w == v then break end
                end
            end
            work[#work] = nil
            if #work > 0 then
                local parent = work[#work].v
                if low[v] < low[parent] then low[parent] = low[v] end
            end
            ::continue::
        end
    end
    for _, v in ipairs(nodes) do if idx[v] == nil then strongconnect(v) end end
    -- materials with no graph node (pure terminals) get a fresh singleton id each
    local function id_of(m) if scc_id[m] then return scc_id[m] end sccn = sccn + 1; scc_id[m] = sccn; return sccn end

    local solves_ind, solves_batch = 0, 0
    local function joint_residuals(priced_set, demand_list, which)
        local p = create_problem.create_problem("fix", prob.constraints, prob.normalized_lines, nil, ref.OPTS)
        for _, pr in pairs(p.primals) do
            if pr.kind == "shortage_source" and priced_set[pr.material] then pr.cost = 1
            elseif pr.kind == "recipe" or pr.kind == "bridge" then pr.cost = EPS_RECIPE
            else pr.cost = 0 end
        end
        for _, mat in ipairs(demand_list) do
            local probe = "|bp_probe|" .. mat
            p:add_objective(probe, 0, false, nil, mat)
            p:add_subject_term(probe, mat, -1)
            local dual = "|bp_demand|" .. mat
            p:add_lower_limit_constraint(dual, 1)
            p:add_subject_term(probe, dual, 1)
        end
        local s, v = harness.solve_to_completion(lp, p, { tolerance = 1e-7, iterate_limit = 800 })
        if which == "ind" then solves_ind = solves_ind + 1 else solves_batch = solves_batch + 1 end
        if s ~= "finished" or not v then return nil end
        local own = {}
        for key, pr in pairs(p.primals) do
            if pr.kind == "shortage_source" and priced_set[pr.material] then
                own[pr.material] = (own[pr.material] or 0) + math.abs(v.x[key] or 0)
            end
        end
        return own
    end

    -- per-material phase 1 (the baseline: #mats solves)
    local members_ind = {}
    for _, mat in ipairs(mats) do
        local own = joint_residuals({ [mat] = true }, { mat }, "ind")
        if own and (own[mat] or 0) <= TOL then members_ind[mat] = true end
    end

    -- SCC-batched phase 1: <= 1 material per SCC per batch
    local by_scc = {}
    for _, mat in ipairs(mats) do
        local id = id_of(mat); by_scc[id] = by_scc[id] or {}; local t = by_scc[id]; t[#t + 1] = mat
    end
    local nbatch = 0
    for _, list in pairs(by_scc) do if #list > nbatch then nbatch = #list end end
    local batches = {}
    for b = 1, nbatch do batches[b] = {} end
    for _, list in pairs(by_scc) do
        for b, mat in ipairs(list) do batches[b][#batches[b] + 1] = mat end
    end
    local members_batch = {}
    for _, batch in ipairs(batches) do
        local set = {}; for _, m in ipairs(batch) do set[m] = true end
        local own = joint_residuals(set, batch, "batch")
        if own then
            for _, m in ipairs(batch) do if (own[m] or 0) <= TOL then members_batch[m] = true end end
        end
    end

    -- Strategy 2: ALL-BATCH then individual re-test of failers. One joint solve
    -- with EVERY material priced+demanded is the STRICTEST test; a passer there
    -- (shortage=0) passes the easier individual test too (monotone), so it is
    -- classified producible for free. Only the FAILERS (genuinely non-producible
    -- OR cycle-contaminated) need an individual re-test. Cost = 1 + #failers.
    local ab_pass = {}
    do
        local set = {}; for _, m in ipairs(mats) do set[m] = true end
        local own = joint_residuals(set, mats, "skip")  -- counted separately below
        if own then for _, m in ipairs(mats) do if (own[m] or 0) <= TOL then ab_pass[m] = true end end end
    end
    local ab_failers = 0
    for _, mat in ipairs(mats) do if not ab_pass[mat] then ab_failers = ab_failers + 1 end end
    -- members via all-batch: passers + (failers that pass individual, reuse members_ind)
    local ab_mismatch = 0
    for _, mat in ipairs(mats) do
        local final = ab_pass[mat] or members_ind[mat] or false  -- failers fall back to individual
        if (final and 1 or 0) ~= (members_ind[mat] and 1 or 0) then ab_mismatch = ab_mismatch + 1 end
    end

    -- Strategy 3: RECURSIVE all-batch. The cascade re-tests prescreen failers ONE
    -- AT A TIME (vp_individual). Instead, re-prescreen the failers as a batch: a
    -- smaller demand set has less contention, so more pass (monotone-safe). Recurse
    -- until a round makes no progress (the irreducible tight-cycle core), then
    -- individual-test that core. Always safe (every batched passer is monotone).
    local rec_members, rec_solves = {}, 0
    do
        local pending = {}
        for _, m in ipairs(mats) do pending[#pending + 1] = m end
        while #pending > 0 do
            if #pending == 1 then
                local own = joint_residuals({ [pending[1]] = true }, pending, "skip"); rec_solves = rec_solves + 1
                if own and (own[pending[1]] or 0) <= TOL then rec_members[pending[1]] = true end
                break
            end
            local set = {}; for _, m in ipairs(pending) do set[m] = true end
            local own = joint_residuals(set, pending, "skip"); rec_solves = rec_solves + 1
            local nextp = {}
            for _, m in ipairs(pending) do
                if own and (own[m] or 0) <= TOL then rec_members[m] = true else nextp[#nextp + 1] = m end
            end
            if #nextp == #pending then
                -- no progress: irreducible core, individual-test each (reuse members_ind)
                for _, m in ipairs(nextp) do rec_solves = rec_solves + 1; if members_ind[m] then rec_members[m] = true end end
                break
            end
            pending = nextp
        end
    end
    local rec_mismatch = 0
    for _, mat in ipairs(mats) do
        if (rec_members[mat] and 1 or 0) ~= (members_ind[mat] and 1 or 0) then rec_mismatch = rec_mismatch + 1 end
    end

    -- compare the two phase-1 member sets
    local mismatch, n_ind, n_batch = 0, 0, 0
    for _, mat in ipairs(mats) do
        local a = members_ind[mat] and 1 or 0
        local b = members_batch[mat] and 1 or 0
        if a ~= b then mismatch = mismatch + 1 end
        n_ind = n_ind + a; n_batch = n_batch + b
    end
    local maxscc = 0
    for _, list in pairs(by_scc) do if #list > maxscc then maxscc = #list end end

    return string.format(
        "RESULT\tname=%s\tnmats=%d\tmismatch=%d\tab_mismatch=%d\trec_mismatch=%d\tmembers_ind=%d"
        .. "\tsolves_ind=%d\tsolves_sccbatch=%d\tsolves_allbatch=%d\tsolves_rec=%d\tab_failers=%d\tmaxscc=%d",
        NAME, #mats, mismatch, ab_mismatch, rec_mismatch, n_ind,
        solves_ind, solves_batch, 1 + ab_failers, rec_solves, ab_failers, maxscc)
end)

io.write((ok and line or string.format("RESULT\tname=%s\terr=%s",
    NAME, tostring(line):gsub("%s+", " "):sub(1, 120))) .. "\n")
