---@diagnostic disable: undefined-global
-- CHEAP KKT-sensitivity predictor per active elastic (NO per-candidate free-solve).
-- Solve L2 baseline ONCE, factor N=A d2 A^T ONCE (equilibrated), then for each active
-- elastic back-solve dx=d x*/d c_M and read the raw (initial_source) pull. Emit one
-- `ks` line per elastic: predPull (raw-increase direction) and predPullX (×baseline x_M).
-- Joined offline with concentrate_corpus.txt (rdist/newRaw truth) on (seed,mat).
--   run via run_corpus.ps1 -Collect '^ks'
require "tests/headless_env"
local R = require "tests/research/research_lib"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local lp = require "solver/linear_programming"
local csr = require "solver/csr_matrix"
local hmul, hdiv, hpow = csr.hadamard_product, csr.hadamard_division, csr.hadamard_power
local VQ, VF, EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"
local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("ks ERR=load seed="..fid.."\n"); return end

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
if st ~= "finished" or not packed then io.write("ks ERR=baseline seed="..fid.."\n"); return end

local ok, err = pcall(function()
    local x = base:make_primal_variables(packed)
    local s = base:make_slack_variables(packed)
    local A = base:generate_subject_matrix()
    local AT = A:T()
    local q = base:generate_quad_vector()
    local d2 = hpow(hdiv(s, x) + q, -1)
    local d2_list = d2:to_list()
    local d2_diag = d2:diag()
    local p_diag = hpow(A, 2) * d2
    local e = hpow(p_diag, -0.5):clamp(2^-60, 2^60)
    local A_scaled = e:diag() * A
    local AST = A_scaled:T()
    local P_base = A_scaled * d2_diag * AST
    local L, Dd = csr.cholesky_decomposition(P_base)
    local px = packed.x
    local raw_idx = {}
    for k,p in pairs(base.primals) do if p.kind=="initial_source" then raw_idx[#raw_idx+1]=p.index end end

    local function densevec(i, val) local t={}; for j=1,base.primal_length do t[j]=0 end; t[i]=val; return csr.with_vector(t, base.primal_length) end
    local function sens(iM)
        local rhs = A * densevec(iM, d2_list[iM])
        local z = csr.backward_substitution(L:T(), csr.forward_substitution(L*Dd, hmul(e, rhs)))
        local dy = hmul(e, z)
        return hmul(d2, AT*dy - densevec(iM, 1)):to_list()
    end

    for k,p in pairs(base.primals) do
        if (p.kind=="shortage_source" or p.kind=="surplus_sink") and math.abs(px[k] or 0)>1e-6 then
            local dx = sens(p.index)
            local pull = 0
            for _, ri in ipairs(raw_idx) do local d = dx[ri] or 0; if d < 0 then pull = pull - d end end
            io.write(string.format("ks predPull=%.6g predPullX=%.6g seed=%s mat=%s\n",
                pull, pull*math.abs(px[k] or 0), fid, p.material))
        end
    end
end)
if not ok then io.write("ks ERR=sens seed="..fid.." msg="..tostring(err):gsub("%s","_").."\n") end
