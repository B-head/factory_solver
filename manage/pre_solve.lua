local flib_table = require "__flib__/table"
local acc = require "manage/accessor"
local save = require "manage/save"
local tn = require "manage/typed_name"
local create_problem = require "solver/create_problem"
local linear_programming = require "solver/linear_programming"

local iterate_limit = 600

local M = {}

---comment
---@return Solution?
function M.find_the_need_for_solve()
    for _, force in pairs(game.forces) do
        local force_data = storage.forces[force.index]
        if not force_data then
            goto continue
        end

        for _, solution in pairs(force_data.solutions) do
            if type(solution.solver_state) == "number" or solution.solver_state == "ready" then
                return solution
            end
        end

        ::continue::
    end
    return nil
end

---comment
---@param solution Solution
function M.forwerd_solve(solution)
    if solution.solver_state == "ready" then
        solution.problem = create_problem.create_problem(
            solution.name,
            solution.constraints,
            M.to_normalized_production_lines(solution.production_lines)
        )
        solution.raw_variables = nil
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
---@return NormalizedProductionLine[]
function M.to_normalized_production_lines(production_lines)
    local normalized_production_lines = {}
    for _, line in ipairs(production_lines) do
        local recipe = tn.typed_name_to_recipe(line.recipe_typed_name)
        local recipe_quality = line.recipe_typed_name.quality
        local machine = tn.typed_name_to_machine(line.machine_typed_name)
        local machine_quality = line.machine_typed_name.quality
        local module_counts = save.get_total_modules(machine, line.module_typed_names, line.affected_by_beacons)
        local effectivity = save.get_total_effectivity(module_counts, machine.effect_receiver)
        local crafting_energy = acc.get_crafting_energy(recipe)
        local crafting_speed_cap = acc.get_crafting_speed_cap(recipe)
        local crafting_speed = acc.get_crafting_speed(machine, machine_quality, effectivity.speed, crafting_speed_cap)

        ---@type NormalizedAmount[]
        local products = {}
        for _, product in ipairs(recipe.products) do
            local amount = acc.raw_product_to_amount(
                product,
                recipe_quality,
                crafting_energy,
                crafting_speed,
                effectivity.productivity
            )

            local decomposed = M.quality_decomposition(amount, effectivity.quality)
            for _, value in ipairs(decomposed) do
                flib_table.insert(products, value)
            end
        end

        ---@type NormalizedAmount[]
        local ingredients = {}
        for _, ingredient in ipairs(recipe.ingredients) do
            local amount = acc.raw_ingredient_to_amount(
                ingredient,
                recipe_quality,
                crafting_energy,
                crafting_speed
            )

            flib_table.insert(ingredients, amount)
        end

        local power = 0
        if acc.is_use_fuel(machine) then
            local ftn = assert(line.fuel_typed_name)
            local fuel = tn.typed_name_to_material(ftn)
            local amount_per_second = acc.get_fuel_amount_per_second(machine, machine_quality,
                fuel, ftn.quality, effectivity.consumption)

            ---@type NormalizedAmount
            local amount = {
                type = ftn.type, ---@diagnostic disable-line: assign-type-mismatch
                name = ftn.name,
                quality = ftn.quality,
                amount_per_second = amount_per_second,
                temperature = ftn.temperature,
                minimum_temperature = ftn.minimum_temperature,
                maximum_temperature = ftn.maximum_temperature,
            }
            flib_table.insert(ingredients, amount)
        elseif acc.is_generator(machine) then
            power = acc.raw_energy_production_to_power(machine, machine_quality)
        else
            power = acc.raw_energy_usage_to_power(machine, machine_quality, effectivity.consumption)
        end

        ---@type NormalizedProductionLine
        local normalized_line = {
            recipe_typed_name = line.recipe_typed_name,
            products = products,
            ingredients = ingredients,
            power_per_second = power,
            pollution_per_second = acc.raw_emission_to_pollution(machine, "pollution", machine_quality,
                effectivity.consumption, effectivity.pollution),
        }

        flib_table.insert(normalized_production_lines, normalized_line)
    end
    M.resolve_bare_fluids(normalized_production_lines)
    return normalized_production_lines
end

---Fill in implicit temperature info for fluid NormalizedAmounts and clamp
---explicit bounds to the fluid's physical range. Bare fluid products resolve
---to the fluid's default_temperature (single). Bare or partially-tagged fluid
---ingredients resolve to [default_temperature, max_temperature]; the clamp
---also tames the FLT-sentinel values Factorio returns for unset bounds
---(e.g. -3.4e38 for an unset minimum_temperature).
---Non-fluid amounts and tagged single-temperature outputs pass through.
---@param normalized_production_lines NormalizedProductionLine[]
function M.resolve_bare_fluids(normalized_production_lines)
    for _, line in ipairs(normalized_production_lines) do
        for _, product in ipairs(line.products) do
            if product.type == "fluid" and product.temperature == nil
                and product.minimum_temperature == nil
                and product.maximum_temperature == nil
            then
                local proto = prototypes.fluid[product.name]
                if proto then
                    product.temperature = proto.default_temperature
                end
            end
        end
        for _, ingredient in ipairs(line.ingredients) do
            if ingredient.type == "fluid" and ingredient.temperature == nil then
                local proto = prototypes.fluid[ingredient.name]
                if proto then
                    local min = ingredient.minimum_temperature or proto.default_temperature
                    local max = ingredient.maximum_temperature or proto.max_temperature
                    if min < proto.default_temperature then min = proto.default_temperature end
                    if max > proto.max_temperature then max = proto.max_temperature end
                    ingredient.minimum_temperature = min
                    ingredient.maximum_temperature = max
                end
            end
        end
    end
end

---comment
---@param normalized_amount NormalizedAmount
---@param effectivity_quality number
---@return NormalizedAmount[]
function M.quality_decomposition(normalized_amount, effectivity_quality)
    if effectivity_quality <= 0 then
        return { normalized_amount }
    end

    local current_quality = normalized_amount.quality
    local current_probability = 1
    local ret = {}

    repeat
        local next_quality
        local next_probability
        local quality_prototype = prototypes.quality[current_quality]
        if quality_prototype.next then
            next_quality = quality_prototype.next.name
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
            amount_per_second = current_probability - next_probability,
            temperature = normalized_amount.temperature,
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
