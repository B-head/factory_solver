local csr_matrix = require "solver/csr_matrix"
local vk = require "solver/var_key"

---@class Problem
---@field name string
---@field primals table<string, Primal>
---@field primal_length integer
---@field duals table<string, Dual>
---@field dual_length integer
---@field subject_terms number[][]
---@field has_quad boolean? True once set_quad puts a nonzero diagonal quadratic objective coefficient on any primal; gates the QP Newton path in linear_programming. nil/false = pure LP (the shipped/headless default).
---@field bridges NormalizedProductionLine[] Temperature bridges injected by create_problem; populated externally after construction.
---@field inactive_recipe_variables table<string, true>? Recipe variables omitted from the LP because they are not connected to any user Constraint; populated by create_problem.
---@field reduced Problem? Proportional row reduction (solver\substitution.lua): the smaller problem the IPM actually solves, built once per "ready" rebuild in manage\pre_solve.lua. nil when substitution is disabled.
---@field reconstruction Reconstruction? Companion to `reduced`: maps each folded-out variable back to k * x_rep so the reduced solution unfolds into full variable space.
local M = {}

---@alias PrimalKind "recipe"|"bridge"|"surplus_sink"|"final_sink"|"initial_source"|"shortage_source"|"elastic"|"slack"

---@class Primal
---@field key string
---@field index integer
---@field cost number
---@field is_result boolean
---@field kind PrimalKind? Variable class; builders set it so solution readers classify without parsing the key.
---@field material string? For an escape variable, the base material variable key it stands in for.
---@field quad number? Diagonal quadratic objective coefficient (the ½·quad·x² convex curvature; QP support). nil/0 = linear only.

---@class Dual
---@field key string
---@field index integer
---@field limit number

local metatable = { __index = M }

---Setup metatable.
---@param self Problem
---@return Problem
function M.setup_metatable(self)
    return setmetatable(self, metatable)
end

---Helper for generating linear programming problems.
---@param name string Name of the problem.
---@return Problem
function M.new(name)
    local self = {
        name = name,
        primals = {},
        primal_length = 0,
        duals = {},
        dual_length = 0,
        subject_terms = {},
        has_quad = false,
        bridges = {},
    }
    return M.setup_metatable(self)
end

---Add the variables to optimize and a term for the objective function.
---@param primal_variable string
---@param cost number
---@param is_result boolean? If ture, variables are included in the output of the solution.
---@param kind PrimalKind? Variable class recorded on the Primal so solution readers classify without parsing the key. Builders (create_problem, slack) always pass it; low-level test fixtures may omit it.
---@param material string? For an escape variable (shortage/elastic/source/sink), the base material variable key it stands in for, recorded so diagnose maps it back without parsing.
function M:add_objective(primal_variable, cost, is_result, kind, material)
    assert(
        not self.primals[primal_variable],
        "Already added a primal variable with the same name."
    )
    self.primal_length = self.primal_length + 1
    self.primals[primal_variable] = {
        key = primal_variable,
        index = self.primal_length,
        cost = cost,
        is_result = is_result or false,
        kind = kind,
        material = material,
    }
end

---comment
---@param primal_variable string
---@param cost number
function M:update_objective_cost(primal_variable, cost)
    local t = self.primals[primal_variable].cost
    self.primals[primal_variable].cost = t + cost
end

---Set the diagonal quadratic objective coefficient on a primal -- the ½·quad·x²
---convex curvature (QP support; create_problem's import_quad uses it to make a
---material's marginal import cost rise with import quantity). quad must be >= 0 so
---the objective stays convex; 0 leaves the variable purely linear. The first
---nonzero quad flips problem.has_quad, which switches linear_programming to the QP
---Newton path (D² = (S/X + Q)⁻¹). No-op if the variable does not exist.
---@param primal_variable string
---@param quad number
function M:set_quad(primal_variable, quad)
    local p = self.primals[primal_variable]
    if not p then return end
    p.quad = quad
    if quad ~= 0 then self.has_quad = true end
end

---Is there an objective term that corresponds to the key?
---@param primal_variable string
---@return boolean
function M:is_exist_objective(primal_variable)
    return self.primals[primal_variable] ~= nil
end

---Add equivalence the constraint.
---@param dual_variable string
---@param limit number
function M:add_equivalence_constraint(dual_variable, limit)
    assert(
        not self.duals[dual_variable],
        "Already added a dual variable with the same name."
    )
    assert(
        0 <= limit,
        "The limit must be a positive value."
    )
    self.dual_length = self.dual_length + 1
    self.duals[dual_variable] = {
        key = dual_variable,
        index = self.dual_length,
        limit = limit,
    }
end

---Add inequality the constraint of equal or less.
---@param dual_variable string
---@param limit number
---@return string
function M:add_upper_limit_constraint(dual_variable, limit)
    local slack_key = vk.pos_slack(dual_variable)
    M.add_equivalence_constraint(self, dual_variable, limit)
    M.add_objective(self, slack_key, 0, false, "slack")
    M.add_subject_term(self, slack_key, dual_variable, 1)
    return slack_key
end

---Add inequality the constraint of equal or greater.
---@param dual_variable string
---@param limit number
---@return string
function M:add_lower_limit_constraint(dual_variable, limit)
    local slack_key = vk.neg_slack(dual_variable)
    M.add_equivalence_constraint(self, dual_variable, limit)
    M.add_objective(self, slack_key, 0, false, "slack")
    M.add_subject_term(self, slack_key, dual_variable, -1)
    return slack_key
end

---Is there an constraint that corresponds to the key?
---@param dual_variable string
function M:is_exist_constraint(dual_variable)
    return self.duals[dual_variable] ~= nil
end

---Add the term for the constraint equation.
---A term with no related variables is removed when generating matrix.
---@param primal_variable string
---@param dual_variable string
---@param coefficient number
function M:add_subject_term(primal_variable, dual_variable, coefficient)
    if not self.subject_terms[primal_variable] then
        self.subject_terms[primal_variable] = {}
    end

    local t = self.subject_terms[primal_variable][dual_variable] or 0
    self.subject_terms[primal_variable][dual_variable] = t + coefficient
end

-- Tie-break: a tiny DISTINCT per-variable cost added to every objective so the
-- LP optimum is a unique point instead of a degenerate face. On a degenerate
-- face the IPM's stopping vertex depends on the starting point (cold Mehrotra vs
-- a warm seed) AND non-monotonically on the tolerance, so the cascade's vertex-
-- reading verdicts drift. A distinct perturbation collapses the face to one
-- point both starts converge to. 0 = off (default; research-set via set_tie_break).
local tie_break = 0
---@param x number
function M.set_tie_break(x) tie_break = x or 0 end

-- Research hook (C-2 magnitude normalization): an optional per-variable scale
-- map. When set, the tie-break on variable k is divided by max(|scale[k]|,
-- floor), so each variable's tie-break OBJECTIVE contribution (delta_k * x_k) is
-- ~uniform instead of being dominated by the largest-magnitude variables. The
-- motivation: the flat tie-break's leverage scales with x, so a single tau that
-- breaks a 1e4-magnitude degenerate tie overrides the cost tiers, while a tau
-- small enough to stay tier-safe cannot break the same tie. Normalizing by an
-- estimate of |x_k*| decouples leverage from magnitude. nil = flat (default).
-- Keys absent from the map are left flat (no division). Floor guards against
-- inflating the tie-break on near-zero estimates.
local tie_scale = nil ---@type table<string, number>?
local tie_floor = 1e-3
---@param map table<string, number>?
---@param floor number?
function M.set_tie_scale(map, floor) tie_scale = map; if floor then tie_floor = floor end end

-- Research hook: restrict the tie-break to a set of PrimalKinds. The escape
-- variables (initial_source / shortage_source / elastic / *_sink) carry the LP's
-- cost tiers, so perturbing them shifts the tier optimum; the genuine degenerate
-- freedom is in the flow variables (recipe / bridge). nil = every non-slack (the
-- original behaviour).
local tie_kinds = nil ---@type table<string, boolean>?
---@param set table<string, boolean>?
function M.set_tie_kinds(set) tie_kinds = set end

-- Deterministic hash of a variable key to [0,1): MP-safe (no RNG, no wall clock)
-- and portable across Lua 5.2 / LuaJIT / the engine (no bitwise ops). This hashes
-- the WHOLE opaque key, not a sliced prefix -- it reads no semantics out of the
-- string, so it is not the key-parsing the var_key contract forbids.
local function key_hash(s)
    local h = 0
    for i = 1, #s do h = (h * 131 + s:byte(i)) % 1000003 end
    return h / 1000003
end

---Make a vector of the coefficient of the primal problem.
---@return CsrMatrix
function M:generate_cost_vector()
    local ret = {}
    if tie_break ~= 0 then
        local scale, floor = tie_scale, tie_floor
        for _, v in pairs(self.primals) do
            -- Slacks carry no objective; perturbing them would bias the
            -- constraint balance, so only the genuine objective variables.
            local jit = 0
            if v.kind ~= "slack" and (not tie_kinds or tie_kinds[v.kind]) then
                jit = tie_break * key_hash(v.key)
                if scale then
                    local s = scale[v.key]
                    if s then
                        local a = s < 0 and -s or s
                        if a < floor then a = floor end
                        jit = jit / a
                    end
                end
            end
            ret[v.index] = v.cost + jit
        end
    else
        for _, v in pairs(self.primals) do
            ret[v.index] = v.cost
        end
    end
    return csr_matrix.with_vector(ret, self.primal_length)
end

---Diagonal of the quadratic objective term Q (½·xᵀ·Q·x). Mirrors
---generate_cost_vector; every primal without a set_quad contributes 0. Only built
---when problem.has_quad (the QP path), so the pure-LP solve never pays for it.
---@return CsrMatrix
function M:generate_quad_vector()
    local ret = {}
    for _, v in pairs(self.primals) do
        ret[v.index] = v.quad or 0
    end
    return csr_matrix.with_vector(ret, self.primal_length)
end

---Make a vector of the coefficient of the dual problem.
---@return CsrMatrix
function M:generate_limit_vector()
    local ret = {}
    for _, v in pairs(self.duals) do
        ret[v.index] = v.limit
    end
    return csr_matrix.with_vector(ret, self.dual_length)
end

---Make a sparse matrix of constraint equations.
---@return CsrMatrix
function M:generate_subject_matrix()
    local ret = {}
    for p, t in pairs(self.subject_terms) do
        if self.primals[p] then
            local x = self.primals[p].index
            for d, v in pairs(t) do
                if self.duals[d] then
                    local y = self.duals[d].index
                    table.insert(ret, { y = y, x = x, value = v })
                end
            end
        end
    end
    return csr_matrix.from_coordinate_list(self.primal_length, self.dual_length, ret)
end

---Make primal variables.
---@param raw_variables PackedVariables? The value returned by @{pack_variables}.
---@return CsrMatrix #Variables in vector form.
function M:make_primal_variables(raw_variables)
    local prev_x = raw_variables and raw_variables.x or {}
    -- Non-slack variables warm-start from prev_x (default 100). Slack variables
    -- are DEPENDENT: their constraint is Σ(non-slack terms) + coef·slack = limit
    -- (coef = +1 for an upper-limit pos_slack, -1 for a lower-limit neg_slack),
    -- so the only feasible value is slack = (limit - Σ non-slack) / coef. A
    -- carried-over or default-100 slack puts the warm point OUTSIDE any freshly
    -- added constraint (e.g. a cascade budget-lock or target-budget row), so the
    -- IPM starts infeasible and the iteration count explodes. Recomputing the
    -- slacks here keeps the warm start feasible.
    local x = {}
    local dual_sum = {} -- dual key -> Σ(non-slack primal value × coefficient)
    for k, p in pairs(self.primals) do
        if p.kind ~= "slack" then
            local val = prev_x[k] or 100
            x[k] = val
            local terms = self.subject_terms[k]
            if terms then
                for dk, coef in pairs(terms) do
                    dual_sum[dk] = (dual_sum[dk] or 0) + val * coef
                end
            end
        end
    end
    for k, p in pairs(self.primals) do
        if p.kind == "slack" then
            -- A slack carried over from the previous solve stays warm (so
            -- edit-to-edit warm-start is unchanged). Only a FRESHLY added slack
            -- -- one with no prev_x value, e.g. a new cascade budget-lock row --
            -- is derived feasibly from its constraint, so the warm point lands
            -- inside the new constraints instead of outside them.
            local val = prev_x[k]
            if not val then
                for dk, coef in pairs(self.subject_terms[k] or {}) do
                    local d = self.duals[dk]
                    if d then val = (d.limit - (dual_sum[dk] or 0)) / coef end
                end
            end
            x[k] = math.max(val or 100, 0)
        end
    end
    local ret = {}
    for k, p in pairs(self.primals) do ret[p.index] = x[k] end
    return csr_matrix.with_vector(ret, self.primal_length)
end

---Make dual variables.
---@param raw_variables PackedVariables? The value returned by @{pack_variables}.
---@return CsrMatrix #Variables in vector form.
function M:make_dual_variables(raw_variables)
    local prev_y = raw_variables and raw_variables.y or {}
    local ret = {}
    for k, v in pairs(self.duals) do
        ret[v.index] = prev_y[k] or 0
    end
    return csr_matrix.with_vector(ret, self.dual_length)
end

---Make slack variables.
---@param raw_variables PackedVariables? The value returned by @{pack_variables}.
---@return CsrMatrix #Variables in vector form.
function M:make_slack_variables(raw_variables)
    local prev_s = raw_variables and raw_variables.s or {}
    local ret = {}
    for k, v in pairs(self.primals) do
        ret[v.index] = prev_s[k] or 1
    end
    return csr_matrix.with_vector(ret, self.primal_length)
end

---Store the value of variables in a plain table.
---@param x CsrMatrix Primal variables.
---@param y CsrMatrix Dual variables.
---@param s CsrMatrix Slack variables.
---@return PackedVariables #Packed table.
function M:pack_variables(x, y, s)
    local list_x, list_s = x:to_list(), s:to_list()
    local ret_x, ret_s = {}, {}
    for k, v in pairs(self.primals) do
        ret_x[k] = list_x[v.index]
        ret_s[k] = list_s[v.index]
    end

    local list_y = y:to_list()
    local ret_y = {}
    for k, v in pairs(self.duals) do
        ret_y[k] = list_y[v.index]
    end

    return {
        x = ret_x,
        y = ret_y,
        s = ret_s,
    }
end

---Remove unnecessary variables from the solution of the problem.
---@param raw_variables PackedVariables?
---@return table<string, number>
function M:filter_result(raw_variables)
    local ret = {}
    for k, v in pairs(self.primals) do
        if v.is_result then
            if raw_variables then
                ret[k] = raw_variables.x[k] or 1
            else
                ret[k] = 1
            end
        end
    end
    return ret
end

---Put primal variables in readable format.
---@param vector CsrMatrix
---@return string
function M:dump_primal(vector)
    local list = vector:to_list()
    local ret = {}
    for k, v in pairs(self.primals) do
        table.insert(ret, string.format("  [%i]%q = %.17g\n", v.index, k, list[v.index]))
    end
    return table.concat(ret)
end

---Put dual variables in readable format.
---@param vector CsrMatrix
---@return string
function M:dump_dual(vector)
    local list = vector:to_list()
    local ret = {}
    for k, v in pairs(self.duals) do
        table.insert(ret, string.format("  [%i]%q = %.17g\n", v.index, k, list[v.index]))
    end
    return table.concat(ret)
end

---Put the subject matrix A in readable form, grouped by dual (constraint
---row) so each constraint header is followed by the primals that contribute
---to it.
---
---Mirrors the filtering in generate_subject_matrix: a subject_term is
---included only when both its primal and its dual are registered, so what
---this dump prints is exactly what the LP solver sees.
---@return string
function M:dump_subject_matrix()
    -- Resolve index -> key for both axes so output can be ordered by index
    -- (Lua dict iteration order is undefined, but stable indices make
    -- generated logs reproducible from run to run).
    local primal_key = {}
    for k, v in pairs(self.primals) do primal_key[v.index] = k end
    local dual_key = {}
    for k, v in pairs(self.duals) do dual_key[v.index] = k end

    local rows = {} ---@type table<integer, table<integer, number>>
    for p_key, terms in pairs(self.subject_terms) do
        local p_info = self.primals[p_key]
        if p_info then
            for d_key, coeff in pairs(terms) do
                local d_info = self.duals[d_key]
                if d_info then
                    rows[d_info.index] = rows[d_info.index] or {}
                    rows[d_info.index][p_info.index] = coeff
                end
            end
        end
    end

    local ret = {}
    for d_idx = 1, self.dual_length do
        local row = rows[d_idx]
        if row then
            table.insert(ret, string.format("  [%i]%q:\n", d_idx, dual_key[d_idx]))
            for p_idx = 1, self.primal_length do
                local coeff = row[p_idx]
                if coeff then
                    table.insert(ret, string.format("    [%i]%q = %f\n",
                        p_idx, primal_key[p_idx], coeff))
                end
            end
        end
    end
    return table.concat(ret)
end

return M
