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

        if acc.is_use_fuel(machine) then
            local ftn = assert(line.fuel_typed_name)
            local amount_per_second = acc.get_fuel_amount_per_second(machine, machine_quality,
                tn.typed_name_to_material(ftn), ftn.quality, effectivity.consumption, ftn)

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
        end

        local power = acc.get_power_per_second(machine, machine_quality,
            effectivity.consumption, line.fuel_typed_name)

        ---@type NormalizedProductionLine
        local normalized_line = {
            recipe_typed_name = line.recipe_typed_name,
            products = products,
            ingredients = ingredients,
            power_per_second = power,
            pollution_per_second = acc.get_pollution_per_second(machine, "pollution",
                machine_quality, effectivity.consumption, effectivity.pollution,
                line.fuel_typed_name),
        }

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
    for _, line in ipairs(normalized_production_lines) do
        for _, product in ipairs(line.products) do
            if product.type == "fluid" then
                product.temperature, product.minimum_temperature, product.maximum_temperature =
                    acc.resolve_bare_fluid_product(product.name,
                        product.temperature,
                        product.minimum_temperature,
                        product.maximum_temperature)
            end
        end
        for _, ingredient in ipairs(line.ingredients) do
            if ingredient.type == "fluid" then
                ingredient.temperature, ingredient.minimum_temperature, ingredient.maximum_temperature =
                    acc.resolve_bare_fluid_ingredient(ingredient.name,
                        ingredient.temperature,
                        ingredient.minimum_temperature,
                        ingredient.maximum_temperature)
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
