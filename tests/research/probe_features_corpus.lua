---@diagnostic disable: undefined-global
-- CHEAP feature vector per active elastic (NO per-candidate free-solve), for the
-- breakage-probability forecast. All features come from the single baseline L2 solve
-- + the material graph -- never from per-candidate perturbation. Joined offline with
-- concentrate_corpus.txt (rdist label) on (seed,mat).
--   features: xv (baseline |x|), predPull / predPullX (KKT sensitivity, one factor +
--   back-solve), inDeg/outDeg (# producer/consumer recipes), sccSize (cyclic-SCC size,
--   0 if acyclic), through (baseline produced+consumed phys), net (|prod-cons|),
--   kind (0 shortage / 1 surplus), bridge (1 if touches a temperature bridge).
--   run via run_corpus.ps1 -Collect '^feat'
require "tests/headless_env"
local R = require "tests/research/research_lib"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local lp = require "solver/linear_programming"
local csr = require "solver/csr_matrix"
local tn = require "manage/typed_name"
local D = R.dissect
local hmul, hdiv, hpow = csr.hadamard_product, csr.hadamard_division, csr.hadamard_power
local VQ, VF, EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"
local function vname(t) return tn.typed_name_to_variable_name(t) end
local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("feat ERR=load seed="..fid.."\n"); return end

local function build()
    local p = create_problem.create_problem("l2", prob.constraints, prob.normalized_lines, nil,
        { reachability_gating=false, deficit_seeding=false, catalyst_closure=false, surplus_sink_gating=false, recipe_epsilon=EPS })
    create_problem.shape_l2(p, VQ, VF); return p
end
local function solve_full(problem)
    local state,it,vars,last,steps = "ready",nil,nil,nil,0
    repeat
        local ok,s,i2,v = pcall(lp.solve, problem, state, it, vars, prob.meta.tolerance, prob.meta.iterate_limit)
        if not ok then return nil,"errored" end
        state,it = s,i2; if v then vars=v; last=v end; steps=steps+1
    until (state~="ready" and state~="calculating") or steps>prob.meta.step_cap
    return last, state
end

local base = build()
local packed, st = solve_full(base)
if st ~= "finished" or not packed then io.write("feat ERR=baseline seed="..fid.."\n"); return end
local px = packed.x

local ok, err = pcall(function()
    local lines = D.all_lines(prob.normalized_lines, base)
    local scc = D.cyclic_sccs(lines)
    local prod0, cons0 = D.physical_flows(lines, px, { fuel = true, eps = 1e-9 })

    -- graph degree (producer / consumer recipe counts) per material
    local prodc, consc = {}, {}
    for _, line in ipairs(lines) do
        for _, p in ipairs(line.products) do local m=vname(p); prodc[m]=(prodc[m] or 0)+1 end
        if line.fuel_burnt_result then local m=vname(line.fuel_burnt_result); prodc[m]=(prodc[m] or 0)+1 end
        for _, ig in ipairs(line.ingredients) do local m=vname(ig); consc[m]=(consc[m] or 0)+1 end
        if line.fuel_ingredient then local m=vname(line.fuel_ingredient); consc[m]=(consc[m] or 0)+1 end
    end
    -- temperature-bridge coupling (read line structure, not the key string)
    local bridge_mat = {}
    for _, line in ipairs(base.bridges) do
        for _, p in ipairs(line.products) do bridge_mat[vname(p)]=true end
        for _, ig in ipairs(line.ingredients) do bridge_mat[vname(ig)]=true end
    end

    -- KKT sensitivity factorization (once)
    local x = base:make_primal_variables(packed)
    local s = base:make_slack_variables(packed)
    local A = base:generate_subject_matrix()
    local AT = A:T()
    local q = base:generate_quad_vector()
    local d2 = hpow(hdiv(s, x) + q, -1)
    local d2_list = d2:to_list()
    local p_diag = hpow(A, 2) * d2
    local e = hpow(p_diag, -0.5):clamp(2^-60, 2^60)
    local A_scaled = e:diag() * A
    local P_base = A_scaled * d2:diag() * A_scaled:T()
    local L, Dd = csr.cholesky_decomposition(P_base)
    local raw_idx = {}
    for k,p in pairs(base.primals) do if p.kind=="initial_source" then raw_idx[#raw_idx+1]=p.index end end
    local function densevec(i, val) local t={}; for j=1,base.primal_length do t[j]=0 end; t[i]=val; return csr.with_vector(t, base.primal_length) end
    local function pull_of(iM)
        local rhs = A * densevec(iM, d2_list[iM])
        local z = csr.backward_substitution(L:T(), csr.forward_substitution(L*Dd, hmul(e, rhs)))
        local dx = hmul(d2, AT*hmul(e, z) - densevec(iM, 1)):to_list()
        local pull = 0
        for _, ri in ipairs(raw_idx) do local d = dx[ri] or 0; if d < 0 then pull = pull - d end end
        return pull
    end

    for k, p in pairs(base.primals) do
        if (p.kind=="shortage_source" or p.kind=="surplus_sink") and math.abs(px[k] or 0)>1e-6 then
            local m = p.material
            local xv = math.abs(px[k] or 0)
            local pull = pull_of(p.index)
            io.write(string.format(
                "feat xv=%.6g predPull=%.6g predPullX=%.6g inDeg=%d outDeg=%d sccSize=%d through=%.6g net=%.6g kind=%d bridge=%d seed=%s mat=%s\n",
                xv, pull, pull*xv, prodc[m] or 0, consc[m] or 0,
                (scc.tag[m] and #scc.members[scc.tag[m]]) or 0,
                (prod0[m] or 0)+(cons0[m] or 0), math.abs((prod0[m] or 0)-(cons0[m] or 0)),
                p.kind=="surplus_sink" and 1 or 0, bridge_mat[m] and 1 or 0, fid, m))
        end
    end
end)
if not ok then io.write("feat ERR=sens seed="..fid.."\n") end
