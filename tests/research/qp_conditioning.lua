---@diagnostic disable: undefined-global
-- SINGLE-SHOT corpus driver: does a better-conditioned stage1 QP converge more?
-- The recipe-anchor consolidation's weak link is the least-norm QP that supplies
-- r_q -- it finishes on only ~69% of the corpus (mostly Cholesky-singular). This
-- driver solves a robust LINEAR pre-solve (always converges) to read per-variable
-- magnitudes, then tries several QP variants and reports each one's solver state,
-- so run_corpus.ps1 can measure which conditioning fix lifts the 69%.
--
-- Variants (stage1 QP only; we only care about convergence here):
--   v0_base : escapes q=2 uniform, recipes q=0, targets BIG=1e6   (current)
--   vBIG3   : same but targets BIG=1e3                            (global down-scale)
--   vRREG   : v0 + absolute tiny quad 1e-3 on recipes            (curvature floor on the flat block)
--   vNORM   : magnitude-normalized quad from the linear seed on BOTH escapes and
--             recipes (q = c / max(|m|, floor)^2)                (~equilibration)
--
--   lua tests/research/qp_conditioning.lua <dumpfile>

local VIO = { shortage_source = true, surplus_sink = true }
local FREEK = { initial_source = true, final_sink = true }
local NAME = (arg[1] or "?"):match("[^/\\]+$") or "?"

local ok, line = pcall(function()
    require "tests/headless_env"
    local create_problem = require "solver/create_problem"
    local problem_dump = require "tests/problem_dump"
    local tn = require "manage/typed_name"
    local vk = require "solver/var_key"
    local lp = require "solver/linear_programming"
    local prob = assert(problem_dump.load_problem(arg[1]))

    local function targets(problem, BIG)
        local rm = {}
        for _, c in ipairs(prob.constraints) do
            local dual = vk.limit(tn.typed_name_to_variable_name(c))
            if problem.duals[dual] then problem.duals[dual].limit = BIG end
            rm[vk.elastic(dual)] = true; rm[vk.pos_slack(dual)] = true; rm[vk.neg_slack(dual)] = true
        end
        for key, p in pairs(problem.primals) do if p.kind == "elastic" or p.kind == "headroom" then rm[key] = true end end
        for key in pairs(rm) do if problem.primals[key] then problem.primals[key] = nil; problem.subject_terms[key] = nil end end
    end
    local function reindex(problem)
        local keys = {}; for k in pairs(problem.primals) do keys[#keys + 1] = k end; table.sort(keys)
        for i, k in ipairs(keys) do problem.primals[k].index = i end
        problem.primal_length = #keys
    end
    local function solve(pp)
        local state, it, vars, last, steps = "ready", nil, nil, nil, 0
        repeat
            local s_ok, s, i2, v = pcall(lp.solve, pp, state, it, vars, prob.meta.tolerance, prob.meta.iterate_limit)
            if not s_ok then state = "errored"; break end
            state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
        until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap
        return (last and last.x) or {}, state
    end

    -- robust LINEAR pre-solve: escapes cost 1 (no quad), free I/O 0 -> magnitudes.
    local function build_lin(BIG)
        local p = create_problem.create_problem("lin", prob.constraints, prob.normalized_lines, nil, nil)
        for key, pr in pairs(p.primals) do
            if VIO[pr.kind] then pr.cost = 1 elseif FREEK[pr.kind] then pr.cost = 0 end
        end
        targets(p, BIG); reindex(p)
        return p
    end
    local plin = build_lin(1e6)
    local xlin, stlin = solve(plin)

    -- per-block magnitude + floor from the linear seed
    local mesc, mrec = {}, {}
    local maxe, maxr = 0, 0
    for key, pr in pairs(plin.primals) do
        local v = math.abs(xlin[key] or 0)
        if VIO[pr.kind] then mesc[key] = v; if v > maxe then maxe = v end
        elseif pr.kind == "recipe" or pr.kind == "bridge" then mrec[key] = v; if v > maxr then maxr = v end end
    end
    local efloor = math.max(1e-9, maxe * 1e-3)
    local rfloor = math.max(1e-9, maxr * 1e-3)

    -- QP variant builders ----------------------------------------------------
    local function build_qp(BIG, recipe_abs_q, normalize)
        local p = create_problem.create_problem("qp", prob.constraints, prob.normalized_lines, nil, nil)
        for key, pr in pairs(p.primals) do
            if VIO[pr.kind] then
                pr.cost = 0
                local q = 2
                if normalize then q = 2 / (math.max(mesc[key] or 0, efloor) ^ 2) end
                p:set_quad(key, q)
            elseif FREEK[pr.kind] then pr.cost = 0; p:set_quad(key, 0)
            elseif pr.kind == "recipe" or pr.kind == "bridge" then
                if normalize then p:set_quad(key, 1e-3 / (math.max(mrec[key] or 0, rfloor) ^ 2))
                elseif recipe_abs_q then p:set_quad(key, recipe_abs_q) end
            end
        end
        targets(p, BIG); reindex(p)
        return p
    end

    local _, s0 = solve(build_qp(1e6, nil, false))
    local _, sB = solve(build_qp(1e3, nil, false))
    local _, sR = solve(build_qp(1e6, 1e-3, false))
    local _, sN = solve(build_qp(1e6, nil, true))

    return string.format("RESULT\tname=%s\tlin=%s\tv0_base=%s\tvBIG3=%s\tvRREG=%s\tvNORM=%s",
        NAME, stlin, s0, sB, sR, sN)
end)

io.write((ok and line or string.format("RESULT\tname=%s\tlin=error\tv0_base=error\tvBIG3=error\tvRREG=error\tvNORM=error\terr=%s",
    NAME, tostring(line):gsub("%s+", " "):sub(1, 100))) .. "\n")
