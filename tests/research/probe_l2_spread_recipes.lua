---@diagnostic disable: undefined-global
-- How much machine mass in the shipped L2 solution is a QUADRATIC-SPREADING
-- artifact -- recipes that run in L2 but vanish under L1 (linear elastic_cost)?
-- seed_118's limestone-void (7.5 machines in L2, ~0 in L1) is the archetype: L2
-- recruits cheap conversion/disposal ("*-void") recipes as extra channels to
-- split its import load and halve the quadratic penalty (15^2+15^2 < 30^2),
-- burning machines tier-3 can't veto. Per dump emits an 'sp' line:
--   L2 total machines, machines in L2-only recipes (active L2, ~0 L1), the
--   subset of those whose name contains 'void', and import channel counts L1/L2.
--   lua tests/research/probe_l2_spread_recipes.lua <dump>   (run via run_corpus.ps1 -Collect '^sp')
require "tests/headless_env"
local R = require "tests/research/research_lib"
local cp = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local EPS = 2 ^ -10
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"

local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("sp ERR=load seed=" .. fid .. "\n"); return end
local function solve(l2)
    local p = cp.create_problem("l2", prob.constraints, prob.normalized_lines, nil,
        { reachability_gating = false, deficit_seeding = false, catalyst_closure = false,
          surplus_sink_gating = false, recipe_epsilon = EPS })
    if l2 then cp.shape_l2(p, 2 ^ 11, 2 ^ -8) end
    local x, st = R.drive_solve(p, prob.meta)
    return p, x, st
end
local function phys(p, k, x)
    local pr, t = p.primals[k], p.subject_terms[k]
    local c = (pr and pr.material and t and t[pr.material]) or 1
    return math.abs(c * (x[k] or 0))
end

local p1, x1, s1 = solve(false)
local p2, x2, s2 = solve(true)
if s1 ~= "finished" or s2 ~= "finished" then
    io.write(("sp st=%s/%s seed=%s\n"):format(tostring(s1), tostring(s2), fid)); return
end
local ACT = 1e-3 -- machine threshold to call a recipe "active"
local totL2, spreadMach, voidMach, nSpread, nVoid = 0, 0, 0, 0, 0
for k, pr in pairs(p2.primals) do
    if pr.kind == "recipe" then
        local m2 = math.abs(x2[k] or 0)
        totL2 = totL2 + m2
        if m2 > ACT then
            local m1 = math.abs(x1[k] or 0)
            if m1 <= ACT then -- active in L2, ~0 in L1 = spreading artifact
                spreadMach = spreadMach + m2; nSpread = nSpread + 1
                if k:find("void") then voidMach = voidMach + m2; nVoid = nVoid + 1 end
            end
        end
    end
end
local function nimp(p, x)
    local n = 0
    for k, pr in pairs(p.primals) do if pr.kind == "shortage_source" and phys(p, k, x) > 1e-6 then n = n + 1 end end
    return n
end
io.write(("sp totL2=%.6g spreadMach=%.6g nSpread=%d voidMach=%.6g nVoid=%d nimpL1=%d nimpL2=%d seed=%s\n")
    :format(totL2, spreadMach, nSpread, voidMach, nVoid, nimp(p1, x1), nimp(p2, x2), fid))
