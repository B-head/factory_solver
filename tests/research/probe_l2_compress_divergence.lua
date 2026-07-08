---@diagnostic disable: undefined-global
-- Divergence between the shipped L2 pipeline's two stages, per corpus dump:
--   x0 = the plain target-rescued L2 (QP) baseline (shape_l2, no folding)
--   xd = the mode-compressed answer (solver/mode_compress.lua's plan, applied
--        exactly as manage/pre_solve.lua's M.l2_compress_step does: hatch_exclude
--        / sink_exclude + the same locked target_budget, one re-solve)
-- Emits one RESULT line per dump with a recipe-space divergence measure (rdist,
-- the same normalized L1 distance probe_mode_compress_cheap.lua's grading uses)
-- so tests/research/run_corpus.ps1 can rank dumps by how much folding moved the
-- machine mix, not just how many channels it folded.
--   lua tests/research/probe_l2_compress_divergence.lua <dump>
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_l2_compress_divergence.lua -Out s:\tmp\l2_compress_divergence.txt
require "tests/headless_env"
local R = require "tests/research/research_lib"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local mode_compress = require "solver/mode_compress"

local VQ, VF, EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10
local PATH = arg[1]
local fid = (PATH or "?"):match("[^/\\]+$") or "?"

local okl, prob = pcall(problem_dump.load_problem, PATH)
if not okl or not prob then io.write("RESULT\tERR=load\t" .. fid .. "\n"); return end

local function build(opts_extra)
    local opts = { reachability_gating = false, deficit_seeding = false, catalyst_closure = false,
        surplus_sink_gating = false, recipe_epsilon = EPS }
    if opts_extra then for k, v in pairs(opts_extra) do opts[k] = v end end
    local p = create_problem.create_problem("l2", prob.constraints, prob.normalized_lines, nil, opts)
    create_problem.shape_l2(p, VQ, VF)
    return p
end
local function solve(p) return R.drive_solve(p, prob.meta) end
local function phys(problem, key, x)
    local p, t = problem.primals[key], problem.subject_terms[key]
    local c = (p and p.material and t and t[p.material]) or 1
    return math.abs(c * (x[key] or 0))
end
local function totals(problem, x)
    local imp, dmp, mach = 0, 0, 0
    for k, p in pairs(problem.primals) do
        if p.kind == "shortage_source" then imp = imp + phys(problem, k, x)
        elseif p.kind == "surplus_sink" then dmp = dmp + phys(problem, k, x)
        elseif p.kind == "recipe" then mach = mach + math.abs(x[k] or 0) end
    end
    return imp, dmp, mach
end

-- Stage 1: unlocked baseline for T0, then the locked baseline (matches the
-- shipped target-rescue: targets are never traded away by the compress step).
local base0 = build()
local x0u, st0u = solve(base0)
if st0u ~= "finished" then io.write("RESULT\tERR=baseline\t" .. fid .. "\n"); return end
local T0 = 0
for k, p in pairs(base0.primals) do
    if p.kind == "elastic" or p.kind == "headroom" then T0 = T0 + math.abs(x0u[k] or 0) end
end
local BUDGET = T0 * (1 + 1e-3) + 1e-6

local base = build({ target_budget = BUDGET })
local x0, st0 = solve(base)
if st0 ~= "finished" then io.write("RESULT\tERR=baseline_locked\t" .. fid .. "\n"); return end

local base_machines = 0
for k, p in pairs(base.primals) do if p.kind == "recipe" then base_machines = base_machines + math.abs(x0[k] or 0) end end
if base_machines < 1e-9 then base_machines = 1e-9 end
local imp0, dmp0, mach0 = totals(base, x0)

local plan = mode_compress.plan(base, x0)
if not plan then
    io.write(string.format("RESULT\tnofold\t%s\trdist=0\texcluded=0\timp0=%.6g\tdmp0=%.6g\tmach0=%.6g\n",
        fid, imp0, dmp0, mach0))
    return
end

local compressed = build({ target_budget = BUDGET, hatch_exclude = plan.hatch, sink_exclude = plan.sink })
local xd, std = solve(compressed)
if std ~= "finished" then
    io.write(string.format("RESULT\tERR=compress_%s\t%s\texcluded=%d\n", tostring(std), fid, plan.excluded))
    return
end

-- Recipe-space divergence: normalized L1 distance between the two machine
-- mixes (same metric probe_mode_compress_cheap.lua's `rdist` grades with).
local rdist = 0
for k, p in pairs(compressed.primals) do
    if p.kind == "recipe" then rdist = rdist + math.abs((xd[k] or 0) - (x0[k] or 0)) end
end
rdist = rdist / base_machines
local imp1, dmp1, mach1 = totals(compressed, xd)

io.write(string.format(
    "RESULT\tok\t%s\trdist=%.6g\texcluded=%d\timp0=%.6g\tdmp0=%.6g\tmach0=%.6g\timp1=%.6g\tdmp1=%.6g\tmach1=%.6g\n",
    fid, rdist, plan.excluded, imp0, dmp0, mach0, imp1, dmp1, mach1))
