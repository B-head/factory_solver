---@diagnostic disable: undefined-global
-- Discriminator for the eps-vanishing hypothesis: is the 2^-10 vs 2^-6 solution
-- gap a NUMERICAL artifact (the bottom epsilon lost in the wide-range normal
-- equations) or a genuine ECONOMIC difference?
--
-- The tell is tolerance. The IPM parks a driven-to-zero recipe at a "dust"
-- residual ~ tolerance/eps (see create_problem.lua's note), and as it nears the
-- optimum the A*D^2*A^T system's D^2 spans up to ~2^104 (x,s clamp at 2^-52, per
-- linear_programming.lua). So three outcomes separate cleanly when we solve the
-- SAME problem at eps=2^-10 under a loose tol and a tight tol, and at eps=2^-6:
--
--   * tighten-tol moves 2^-10 TOWARD 2^-6  (relshift(A,Atight) large, gap to B
--     shrinks): the divergence was removable convergence dust = tol/eps. Raising
--     eps and tightening tol are interchangeable knobs, NOT a hard wall.
--   * 2^-10 at tight tol FAILS to converge (stalls at the iterate limit) on the
--     wide-range problems: the residual floor is set by round-off in the squared
--     system -- the precision wall. eps sitting under that floor has vanished.
--   * tighten-tol does NOT move 2^-10, yet 2^-6 differs: the gap is economic --
--     eps=2^-6 is large enough to re-price a real trade-off, not numerical.
--
-- Single-shot run_corpus worker.
--   pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_eps_tolerance.lua -Collect '^ETOL\|' -Out s:\tmp\etol.txt

require "tests/headless_env"
local create_problem = require "solver/create_problem"
local linear_programming = require "solver/linear_programming"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"

local EPS_A = 2 ^ -10
local EPS_B = 2 ^ -6
local TOL_TIGHT = 1e-11        -- ~4 orders below the 1e-7 default
local TIGHT_ITER = 2000        -- generous cap so a non-stalling solve can reach it

local path = arg[1]
if not path then io.stderr:write("usage: ... <problem-file>\n"); os.exit(2) end
local prob, kind, detail = problem_dump.load_problem(path)
if not prob then print("# ERROR " .. tostring(path) .. " " .. tostring(kind)); os.exit(0) end
local meta = prob.meta
local tag = path:gsub("[\\/]", "/"):match("([^/]+)%.lua$") or path

local function solve(eps, tol, iter)
    local opts = { deficit_seeding = true, catalyst_closure = true,
        reachability_gating = true, surplus_sink_gating = false, recipe_epsilon = eps }
    local ok, problem = pcall(create_problem.create_problem, "explore",
        prob.constraints, prob.normalized_lines, nil, opts)
    if not ok then return nil end
    local m = { tolerance = tol, iterate_limit = iter, step_cap = iter + 4 }
    local state, steps, vars, err = problem_dump.solve_dumped(linear_programming, problem, m)
    if err then return nil end
    return { problem = problem, state = state, steps = steps, vars = vars }
end

-- relative recipe-flow distance between two solves (sum|xa-xb| / sum xa).
local function relshift(P, Q)
    if not P or not Q or not P.vars or not Q.vars then return -1 end
    local keys = {}
    for k in pairs(P.vars.x or {}) do if ed.is_recipe(k, P.problem.primals) then keys[k] = true end end
    for k in pairs(Q.vars.x or {}) do if ed.is_recipe(k, Q.problem.primals) then keys[k] = true end end
    local diff, base = 0, 0
    for k in pairs(keys) do
        local a = math.abs((P.vars.x or {})[k] or 0)
        local b = math.abs((Q.vars.x or {})[k] or 0)
        diff = diff + math.abs(a - b); base = base + a
    end
    return base > 0 and diff / base or 0
end

local function xrange(P)
    local lo, hi = math.huge, 0
    local th = ed.park_threshold(P.vars, P.problem.primals)
    for k, v in pairs(P.vars.x or {}) do
        if ed.is_recipe(k, P.problem.primals) then
            local a = math.abs(v)
            if a > th then if a < lo then lo = a end; if a > hi then hi = a end end
        end
    end
    return (lo == math.huge or lo == 0) and 0 or hi / lo
end

local A      = solve(EPS_A, meta.tolerance, meta.iterate_limit)  -- loose, shipped
local Atight = solve(EPS_A, TOL_TIGHT, TIGHT_ITER)                -- 2^-10 pushed hard
local B      = solve(EPS_B, meta.tolerance, meta.iterate_limit)  -- loose, raised eps
if not (A and Atight and B) then print("# ERROR " .. tag .. " build/solve failed"); os.exit(0) end

local gap_AB      = relshift(A, B)          -- the original divergence
local move_tight  = relshift(A, Atight)     -- did tightening tol move 2^-10?
local resid_gap   = relshift(Atight, B)     -- gap remaining after the tighten
local conv_tight  = Atight.state == "finished" and 1 or 0  -- did tight 2^-10 converge?

-- Cross-objective optimality test (the decisive economic-vs-numerical split).
-- recipe_epsilon changes ONLY the cost vector, not the constraint matrix or the
-- variable set, so xB is feasible for problem A and can be priced under cost_A.
-- If A is truly optimal under cost_A then objA(xB) >= objA(xA): B cannot beat A
-- on A's own ruler. A NEGATIVE regret means the loose 2^-10 solve returned a
-- point that is suboptimal in its OWN objective -- which a correctly working
-- solver never does -- i.e. the eps tie-break was lost to round-off (vanished).
local function objective(problem, vars, primals_for_cost)
    -- price `vars` using the cost field from `primals_for_cost` (defaults to the
    -- vars' own problem). Both builds share variable keys, so cross-pricing is a
    -- straight key lookup.
    local prim = primals_for_cost or problem.primals
    local total = 0
    for k, v in pairs(vars.x or {}) do
        local p = prim[k]
        local c = p and p.cost or 0
        local x = v > 0 and v or 0
        total = total + c * x
    end
    return total
end
local objA_A = objective(A.problem, A.vars)                       -- A priced under cost_A
local objA_B = objective(A.problem, B.vars, A.problem.primals)    -- B priced under cost_A
local objB_B = objective(B.problem, B.vars)                       -- B priced under cost_B
local objB_A = objective(B.problem, A.vars, B.problem.primals)    -- A priced under cost_B
local regretA = objA_B - objA_A   -- >=0 if A optimal under its own cost
local regretB = objB_A - objB_B   -- >=0 if B optimal under its own cost
-- normalize regret by the objective scale so the sign test is tolerance-aware
local relRegretA = objA_A ~= 0 and regretA / math.abs(objA_A) or 0
local relRegretB = objB_B ~= 0 and regretB / math.abs(objB_B) or 0

print(string.format(
    "ETOL|%s|xr=%.3g|gap_AB=%.4g|move_tight=%.4g|resid_gap=%.4g|conv_tight=%d|steps_tight=%d|conv_A=%d" ..
    "|objA_A=%.6g|objA_B=%.6g|regretA=%.4g|relRegA=%.4g|objB_B=%.6g|regretB=%.4g|relRegB=%.4g",
    tag, xrange(A), gap_AB, move_tight, resid_gap, conv_tight, Atight.steps,
    A.state == "finished" and 1 or 0,
    objA_A, objA_B, regretA, relRegretA, objB_B, regretB, relRegretB))
