---@diagnostic disable: undefined-global
-- Test whether the SATURATION verdict ("target-bounded demand": cap M's freed import
-- at C1 then C2=C1+room; does it keep using the extra room?) predicts the disruption
-- (rdist) of the uncapped free-solve. Per active elastic, 3 solves: capped@C1, capped@C2,
-- uncapped. Emit one `sat` line. Caps use a factory-scale ABSOLUTE margin (multiples of
-- max recipe activity), not a multiple of the tiny baseline.
--   run via run_corpus.ps1 -Collect '^sat'
require "tests/headless_env"
local R = require "tests/research/research_lib"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local D = R.dissect
local VQ, VF, EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10
local CAP = 30
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"
local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("sat ERR=load seed=" .. fid .. "\n"); return end

local function build()
    local p = create_problem.create_problem("l2", prob.constraints, prob.normalized_lines, nil,
        { reachability_gating=false, deficit_seeding=false, catalyst_closure=false, surplus_sink_gating=false, recipe_epsilon=EPS })
    create_problem.shape_l2(p, VQ, VF); return p
end
local function phys(problem, key, x)
    local p, t = problem.primals[key], problem.subject_terms[key]
    local c = (p and p.material and t and t[p.material]) or 1
    return math.abs(c * (x[key] or 0))
end
local base = build()
local x0, st0 = R.drive_solve(base, prob.meta)
if st0 ~= "finished" then io.write("sat ERR=baseline seed=" .. fid .. "\n"); return end
local maxr, base_machines = 0, 0
for k,p in pairs(base.primals) do if p.kind=="recipe" then local a=math.abs(x0[k] or 0); base_machines=base_machines+a; if a>maxr then maxr=a end end end
if maxr < 1e-9 then maxr = 1e-9 end
if base_machines < 1e-9 then base_machines = 1e-9 end
local lines = D.all_lines(prob.normalized_lines, base)
local raw0 = {}
for k,p in pairs(base.primals) do if p.kind=="initial_source" then raw0[k]=phys(base,k,x0) end end

local active = {}
for k,p in pairs(base.primals) do
    if (p.kind=="shortage_source" or p.kind=="surplus_sink") and math.abs(x0[k] or 0)>1e-6 then
        active[#active+1] = { key=k, mat=p.material, x0=math.abs(x0[k] or 0) }
    end
end
if #active==0 then io.write("sat NOACTIVE seed="..fid.."\n"); return end
local n,cnt,seen,sample = #active, math.min(CAP,#active), {}, {}
for i=1,cnt do local idx=(cnt==1) and 1 or math.floor((i-1)*(n-1)/(cnt-1)+0.5)+1; if not seen[idx] then seen[idx]=true; sample[#sample+1]=active[idx] end end

local function solve(key, cap)
    local problem = build(); problem:set_quad(key, 0)
    if cap then local dual="|sat_cap|"..key; problem:add_upper_limit_constraint(dual, cap); problem:add_subject_term(key, dual, 1) end
    local x1 = R.drive_solve(problem, prob.meta)
    return problem, x1
end

for _, e in ipairs(sample) do
    local _, x1c1 = solve(e.key, e.x0 + 2*maxr)
    local _, x1c2 = solve(e.key, e.x0 + 4*maxr)
    local prob_u, x1u = solve(e.key, nil)
    local i1, i2 = math.abs(x1c1[e.key] or 0), math.abs(x1c2[e.key] or 0)
    local sat = (i2 - i1) > 0.5*maxr and 1 or 0
    local rdiff = 0
    for k,p in pairs(prob_u.primals) do if p.kind=="recipe" then rdiff=rdiff+math.abs((x1u[k] or 0)-(x0[k] or 0)) end end
    local new_raw = 0
    for k,v0 in pairs(raw0) do local inc=phys(prob_u,k,x1u)-v0; if inc>0 then new_raw=new_raw+inc end end
    io.write(string.format("sat SAT=%d rdist=%.4f newRaw=%.4f seed=%s mat=%s\n",
        sat, rdiff/base_machines, new_raw/base_machines, fid, e.mat))
end
