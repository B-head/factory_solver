-- Shared helpers for headless solver RESEARCH drivers (NOT the pass/fail suite).
--
-- Every ad-hoc probe written against the explorer-dumped problems repeats the same
-- boilerplate: load the dump, build a fresh Problem through create_problem, drive
-- the IPM to a terminal state, then classify the solved variables (which are
-- recipes? which escapes are active? what is the objective value?) and sometimes
-- perturb the Problem (reprice a cost, force a recipe to carry flow). Those pieces
-- lived inline in a dozen throwaway s:\tmp scripts that were rewritten every
-- session. This module is that boilerplate, factored once, so a new probe is a few
-- lines of intent plus require "tests/research/research_lib".
--
-- It deliberately sits ON TOP of the committed primitives rather than replacing
-- them: load/solve come from tests/problem_dump, detect/park_threshold/is_recipe
-- from tests/explore_detect. What it adds is the escape / objective / force-recipe
-- layer those two don't cover.
--
-- The CALLER must `require "tests/headless_env"` before requiring this module
-- (headless_env sets package.path so "tests/..." and "solver/..." resolve). This
-- module re-requires it defensively (require is cached, so it is a no-op once set).
--
-- CAVEAT (hard-won this corpus -- read before trusting any output built on this):
-- these are SCREENING / exploration helpers, not verdicts. In particular
--   * judge an escape change by NET TOTAL escape mass, not a single escape's
--     direction (temperature-form reshuffles move one down and one up, net ~0);
--   * a single forced recipe is COORDINATION-BLIND -- it opens escapes a coalition
--     of other parked recipes might cancel, so "net positive in isolation" is not
--     proof of useless;
--   * Delta-objective only re-confirms LP optimality (forcing adds a constraint, so
--     the optimum can only rise) -- it says nothing about practicality, which lives
--     in the formulation, not in the optimum.
--
-- Conventions matched: single M table, LuaCATS annotations referencing meta.lua
-- types. The shipped solver and create_problem are never mutated -- every override
-- here lives on the in-memory Problem the caller built for this run.

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local linear_programming = require "solver/linear_programming"
local ed = require "tests/explore_detect"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"

local M = {}

-- Re-exports so a driver needs only this one require for the common reads.
M.detect = ed.detect
M.park_threshold = ed.park_threshold
M.is_recipe = ed.is_recipe
M.CHEAT_EPS = ed.CHEAT_EPS

-- Location of the canonical research corpus (explorer-dumped problems, promoted
-- by hand -- the explorer itself publishes to tests/explore_problems/). There is
-- deliberately NO baked-in default: the corpus lives wherever the maintainer
-- hosts it, named by the FS_CORPUS_DIR environment variable (the .ps1 research
-- launchers honour the same variable for their -DumpDir). nil when unset --
-- drivers that enumerate the corpus themselves must check before using it.
M.DUMP_DIR = os.getenv("FS_CORPUS_DIR")

---Load and validate an explorer-dumped problem file, raising on failure (the
---research drivers want a hard stop, not the kind/detail split solve_problem uses).
---@param path string
---@return table prob The { meta, constraints, normalized_lines } table.
function M.load(path)
    local prob, kind, detail = problem_dump.load_problem(path)
    if not prob then
        error(("research_lib.load %q: %s %s"):format(path, tostring(kind), tostring(detail)), 2)
    end
    return prob
end

---Build a FRESH Problem from a loaded dump (create_problem defaults, no overrides).
---Rebuilt per call so each perturbation variant starts clean. `forced_imports` is
---passed through for two-pass experiments; nil for the ordinary single solve.
---@param prob table A table from M.load (has .constraints, .normalized_lines).
---@param forced_imports table<string, true>? Optional create_problem forced imports.
---@return Problem
function M.build(prob, forced_imports)
    local ok, problem = pcall(create_problem.create_problem, "research",
        prob.constraints, prob.normalized_lines, forced_imports)
    if not ok then error("research_lib.build: create_problem raised: " .. tostring(problem), 2) end
    return problem
end

---Drive the IPM to a terminal state (delegates to problem_dump.solve_dumped), using
---the dump's own meta knobs. Raises if solve() raised.
---@param problem Problem
---@param meta { tolerance: number, iterate_limit: integer, step_cap: integer }
---@return string state Terminal solver_state.
---@return integer steps
---@return PackedVariables vars
function M.solve(problem, meta)
    local state, steps, vars, err = problem_dump.solve_dumped(linear_programming, problem, meta)
    if err then error("research_lib.solve: " .. err, 2) end
    return state, steps, vars
end

---Convenience: load is the caller's; this builds + solves a prob in one call.
---@param prob table
---@param forced_imports table<string, true>?
---@return Problem problem, string state, integer steps, PackedVariables vars
function M.build_solve(prob, forced_imports)
    local problem = M.build(prob, forced_imports)
    local state, steps, vars = M.solve(problem, prob.meta)
    return problem, state, steps, vars
end

-- ---- variable classification ------------------------------------------------

---True if the primal is a penalty escape (shortage_source = import-from-outside,
---surplus_sink = dump). Read off Primal.kind, never the key string.
---@param primals table<string, Primal>
---@param key string
---@return boolean
function M.is_escape(primals, key)
    local p = primals[key]
    return p ~= nil and (p.kind == "shortage_source" or p.kind == "surplus_sink")
end

---|value| of every escape variable, keyed. (0 for any escape absent from vars.)
---@param vars PackedVariables
---@param primals table<string, Primal>
---@return table<string, number>
function M.escape_vec(vars, primals)
    local m = {}
    for k in pairs(primals) do
        if M.is_escape(primals, k) then m[k] = math.abs((vars.x and vars.x[k]) or 0) end
    end
    return m
end

---Total |value| of the ACTIVE escapes (above the park threshold) -- the neutral
---"import + dump" boundary mass. thresh defaults to the recipe-relative park
---threshold detect() uses.
---@param vars PackedVariables
---@param primals table<string, Primal>
---@param thresh number?
---@return number
function M.escape_mass(vars, primals, thresh)
    thresh = thresh or M.park_threshold(vars, primals)
    local total = 0
    for _, v in pairs(M.escape_vec(vars, primals)) do
        if v > thresh then total = total + v end
    end
    return total
end

---Objective value of a solved point: sum of cost * |value| over every primal,
---weighting each variable class at its create_problem cost tier. This is the LP's
---OWN yardstick -- the complete one for "is this solution cheaper", but note it is
---NOT a practicality measure (practicality lives in the formulation, not here; see
---the module-header caveat -- Delta-objective only re-confirms LP optimality).
---@param problem Problem
---@param vars PackedVariables
---@return number
function M.objective(problem, vars)
    local o = 0
    for k, p in pairs(problem.primals) do
        o = o + (p.cost or 0) * math.abs((vars.x and vars.x[k]) or 0)
    end
    return o
end

---All recipe-flow primal keys (kind == "recipe"; excludes |bridge| plumbing,
---escapes, slacks), sorted.
---@param problem Problem
---@return string[]
function M.recipe_keys(problem)
    local keys = {}
    for k, p in pairs(problem.primals) do
        if p.kind == "recipe" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    return keys
end

---Recipe keys split into active (carrying flow above the park threshold) and
---parked (at the interior floor). thresh defaults to the park threshold.
---@param vars PackedVariables
---@param problem Problem
---@param thresh number?
---@return string[] active, string[] parked
function M.recipe_partition(vars, problem, thresh)
    thresh = thresh or M.park_threshold(vars, problem.primals)
    local active, parked = {}, {}
    for _, k in ipairs(M.recipe_keys(problem)) do
        if math.abs((vars.x and vars.x[k]) or 0) >= thresh then
            active[#active + 1] = k
        else
            parked[#parked + 1] = k
        end
    end
    return active, parked
end

-- ---- perturbation -----------------------------------------------------------

---Force a recipe primal to carry flow >= eps, by adding a fresh lower-limit row
---whose single term is the recipe variable (recipe - neg_slack = eps). Mutates the
---passed (research-owned) Problem only. The cheapest min-cost optimum is always
--->= the unconstrained one, so this can only raise the objective -- use the
---resulting Delta-objective to tell a degenerate free addition (Delta~0) from a
---strictly-worse one (Delta>0). (And recall: a single force is coordination-blind.)
---@param problem Problem
---@param recipe_key string
---@param eps number Forced minimum flow (e.g. 0.1, well above a typical park threshold).
function M.force_recipe(problem, recipe_key, eps)
    local dual = "|research_force|" .. recipe_key
    problem:add_lower_limit_constraint(dual, eps)
    problem:add_subject_term(recipe_key, dual, 1)
end

---Set the cost of a single primal (absolute). Returns the previous cost (nil if
---the key does not exist), so a driver can restore or report it.
---@param problem Problem
---@param key string
---@param cost number
---@return number? previous
function M.set_cost(problem, key, cost)
    local p = problem.primals[key]
    if not p then return nil end
    local was = p.cost
    p.cost = cost
    return was
end

---Basename of a path (the dump's tag stem + .lua), for tagging batch output.
---@param path string
---@return string
function M.fileid(path)
    return path:match("[^/\\]+$") or path
end

-- ---- SCC / escape aggregation (shared probe reads) --------------------------
--
-- These five were copy-pasted, verbatim, into a dozen cyclic-SCC probes. The
-- signatures here are the canonical ones; probes alias them (local internal_flow
-- = R.internal_flow, ...) so existing call sites are untouched. `shortage_of`
-- had two incompatible shapes in the wild, so it is exposed as two named
-- helpers (by-material vs by-key-list) rather than one overloaded function.

---Recipe-flow variable names internal to an SCC: lines with >= 1 ingredient AND
--->= 1 product (counting fuel_ingredient / fuel_burnt_result) whose variable is
---in `scc_set`. Keyed set of recipe variable names.
---@param lines NormalizedProductionLine[]
---@param scc_set table<string, true> Material variable names that form the SCC.
---@return table<string, true>
function M.internal_recipes(lines, scc_set)
    local out = {}
    for _, line in ipairs(lines) do
        local hi = false
        for _, ing in ipairs(line.ingredients) do
            if scc_set[tn.typed_name_to_variable_name(ing)] then hi = true; break end
        end
        if not hi and line.fuel_ingredient and scc_set[tn.typed_name_to_variable_name(line.fuel_ingredient)] then hi = true end
        if hi then
            local hp = false
            for _, prod in ipairs(line.products) do
                if scc_set[tn.typed_name_to_variable_name(prod)] then hp = true; break end
            end
            if not hp and line.fuel_burnt_result and scc_set[tn.typed_name_to_variable_name(line.fuel_burnt_result)] then hp = true end
            if hp then out[tn.typed_name_to_variable_name(line.recipe_typed_name)] = true end
        end
    end
    return out
end

---Sum |x| over a keyed set of recipe variables (the SCC's internal flow).
---@param x table<string, number>
---@param internal_set table<string, true>
---@return number
function M.internal_flow(x, internal_set)
    local s = 0
    for key in pairs(internal_set) do s = s + math.abs(x[key] or 0) end
    return s
end

---Sum |x| over every elastic (target-relaxation) variable.
---@param problem Problem
---@param x table<string, number>
---@return number
function M.target_relax(problem, x)
    local s = 0
    for key, p in pairs(problem.primals) do
        if p.kind == "elastic" then s = s + math.abs(x[key] or 0) end
    end
    return s
end

---Sum |x| over the escape-priced boundary (surplus_sink + shortage_source),
---excluding keys in `exclude` -- the "other escapes" a fabrication path drags in.
---@param problem Problem
---@param x table<string, number>
---@param exclude table<string, true>
---@return number
function M.other_escape_sum(problem, x, exclude)
    local s = 0
    for key, p in pairs(problem.primals) do
        if (p.kind == "surplus_sink" or p.kind == "shortage_source") and not exclude[key] then
            s = s + math.abs(x[key] or 0)
        end
    end
    return s
end

---Total shortage_source |x| for one material (0 if absent).
---@param problem Problem
---@param x table<string, number>
---@param material string
---@return number
function M.shortage_of_material(problem, x, material)
    local s = 0
    for key, p in pairs(problem.primals) do
        if p.kind == "shortage_source" and p.material == material then s = s + math.abs(x[key] or 0) end
    end
    return s
end

---Sum x over an explicit list of shortage variable keys (signed, as the
---direction probes read it).
---@param x table<string, number>
---@param keys string[]
---@return number
function M.shortage_of_keys(x, keys)
    local s = 0
    for _, k in ipairs(keys) do s = s + (x[k] or 0) end
    return s
end

return M
