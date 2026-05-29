local flib_table = require "__flib__/table"
local acc = require "manage/accessor"
local create_problem = require "solver/create_problem"
local linear_programming = require "solver/linear_programming"

local iterate_limit = 600

local M = {}

---comment
---@return ForceLocalData?
---@return Solution?
function M.find_the_need_for_solve()
    for _, force in pairs(game.forces) do
        local force_data = storage.forces[force.index]
        if not force_data then
            goto continue
        end

        for _, solution in pairs(force_data.solutions) do
            if type(solution.solver_state) == "number" or solution.solver_state == "ready" then
                return force_data, solution
            end
        end

        ::continue::
    end
    return nil, nil
end

---comment
---@param force_data ForceLocalData
---@param solution Solution
function M.forwerd_solve(force_data, solution)
    local bonuses = force_data.research_bonuses

    if solution.solver_state == "ready" then
        solution.problem = create_problem.create_problem(
            solution.name,
            solution.constraints,
            M.to_normalized_production_lines(solution.production_lines, bonuses)
        )
        -- Mirror the inactive-recipe set onto the solution so save / UI lookups
        -- (which see solution, not problem) can gray out isolated lines without
        -- reaching through solution.problem (which is nil after migrations).
        solution.inactive_recipe_variables = solution.problem.inactive_recipe_variables
        -- raw_variables intentionally preserved across re-prepares: constraint
        -- and line edits change b (and sometimes the variable set), but recipe
        -- x values from the previous converged solve are near the new optimum
        -- and let the IPM warm-start instead of restarting from the default.
        -- make_primal_variables falls back to the default for keys missing from
        -- prev_x, so added/removed lines are handled automatically.
    end

    local problem = assert(solution.problem)

    solution.solver_state, solution.raw_variables = linear_programming.solve(
        problem,
        solution.solver_state,
        solution.raw_variables,
        acc.tolerance,
        iterate_limit
    )

    solution.quantity_of_machines_required = problem:filter_result(solution.raw_variables)
end

---comment
---@param production_lines ProductionLine[]
---@param bonuses ResearchBonuses?
---@return NormalizedProductionLine[]
function M.to_normalized_production_lines(production_lines, bonuses)
    local normalized_production_lines = {}
    for _, line in ipairs(production_lines) do
        local normalized_line, effectivity = acc.normalize_production_line(line, bonuses)

        -- Quality decomposition is LP-only: it splits one per-quality product
        -- amount into the distribution that module quality bonus would
        -- actually emit. UI and totals consume the pre-decomposition amount.
        local decomposed = {}
        for _, product in ipairs(normalized_line.products) do
            local unlocked = bonuses and bonuses.unlocked_qualities or nil
            for _, value in ipairs(M.quality_decomposition(product, effectivity.quality, unlocked)) do
                flib_table.insert(decomposed, value)
            end
        end
        normalized_line.products = decomposed

        flib_table.insert(normalized_production_lines, normalized_line)
    end
    M.resolve_bare_fluids(normalized_production_lines)
    return normalized_production_lines
end

---Fill in implicit temperature info on every fluid NormalizedAmount in the
---given lines (see acc.resolve_bare_fluid_product / _ingredient for the exact
---semantics). Mutates in place because the LP variable names downstream are
---computed from these same NormalizedAmounts.
---@param normalized_production_lines NormalizedProductionLine[]
function M.resolve_bare_fluids(normalized_production_lines)
    local function resolve_ingredient(amount)
        if amount.type ~= "fluid" then return end
        amount.minimum_temperature, amount.maximum_temperature =
            acc.resolve_bare_fluid_ingredient(amount.name,
                amount.minimum_temperature,
                amount.maximum_temperature)
    end

    for _, line in ipairs(normalized_production_lines) do
        for _, product in ipairs(line.products) do
            if product.type == "fluid" then
                product.minimum_temperature, product.maximum_temperature =
                    acc.resolve_bare_fluid_product(product.name,
                        product.minimum_temperature,
                        product.maximum_temperature)
            end
        end
        for _, ingredient in ipairs(line.ingredients) do
            resolve_ingredient(ingredient)
        end
        if line.fuel_ingredient then
            resolve_ingredient(line.fuel_ingredient)
        end
    end
end

---comment
---@param normalized_amount NormalizedAmount
---@param effectivity_quality number
---@param unlocked_qualities table<string, boolean>?
---@return NormalizedAmount[]
function M.quality_decomposition(normalized_amount, effectivity_quality, unlocked_qualities)
    if effectivity_quality <= 0 then
        return { normalized_amount }
    end

    local source_quality_proto = prototypes.quality[normalized_amount.quality]
    local source_level = source_quality_proto and source_quality_proto.level or 0
    -- utility_constants.maximum_quality_jump caps how many tier steps above the
    -- input quality a single craft can produce. Vanilla default is 255 (i.e.
    -- effectively unlimited), but mods may set it lower to model engines that
    -- only allow a one-tier jump per craft. Reading it through
    -- prototypes.utility_constants picks up any modded override without
    -- assuming a fixed value here.
    local max_jump = prototypes.utility_constants.maximum_quality_jump or 255

    local current_quality = normalized_amount.quality
    local current_probability = 1
    local ret = {}

    repeat
        local next_quality
        local next_probability
        local quality_prototype = prototypes.quality[current_quality]
        local next_proto = quality_prototype.next
        -- Walk to the next tier if (a) it exists in the prototype tree,
        -- (b) it's unlocked by the player's research snapshot, and
        -- (c) it's still within maximum_quality_jump tiers of the source.
        -- unlocked_qualities=nil means "no force snapshot" and falls back to
        -- the prototype-level chain (legacy behavior).
        local next_unlocked = next_proto
            and (not unlocked_qualities or unlocked_qualities[next_proto.name])
        local within_jump = next_proto and (next_proto.level - source_level) <= max_jump
        if next_unlocked and within_jump then
            next_quality = next_proto.name
            if quality_prototype.name == normalized_amount.quality then
                next_probability = math.min(effectivity_quality * quality_prototype.next_probability, 1)
            else
                next_probability = current_probability * quality_prototype.next_probability
            end
        else
            next_quality = "unknown-quality"
            next_probability = 0
        end

        ---@type NormalizedAmount
        local add_value = {
            type = normalized_amount.type,
            name = normalized_amount.name,
            quality = current_quality,
            amount_per_second = (current_probability - next_probability) * normalized_amount.amount_per_second,
            minimum_temperature = normalized_amount.minimum_temperature,
            maximum_temperature = normalized_amount.maximum_temperature,
        }
        flib_table.insert(ret, add_value)

        current_quality = next_quality
        current_probability = next_probability
    until 0 == current_probability

    return ret
end

return M
