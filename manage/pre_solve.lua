local flib_table = require "__flib__/table"
local acc = require "manage/accessor"
local save = require "manage/save"
local tn = require "manage/typed_name"
local create_problem = require "solver/create_problem"
local linear_programming = require "solver/linear_programming"

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
    end

    local problem = assert(solution.problem)

    solution.solver_state, solution.raw_variables = linear_programming.solve(
        problem,
        solution.solver_state,
        solution.raw_variables
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
        local machine = tn.typed_name_to_machine(line.machine_typed_name)
        local machine_quality = line.machine_typed_name.quality
        local craft_energy = assert(recipe.energy)
        local crafting_speed = acc.get_crafting_speed(machine, machine_quality)
        local module_counts = save.get_total_modules(machine, line.module_typed_names, line.affected_by_beacons)
        local effectivity = save.get_total_effectivity(module_counts)

        ---@type NormalizedAmount[]
        local products = {}
        for _, value in pairs(recipe.products) do
            local amount_per_second = acc.raw_product_to_amount(value, craft_energy, crafting_speed,
                effectivity.speed, effectivity.productivity)

            ---@type NormalizedAmount
            local amount = {
                type = value.type,
                name = value.name,
                amount_per_second = amount_per_second,
            }
            flib_table.insert(products, amount)
        end

        ---@type NormalizedAmount[]
        local ingredients = {}
        for _, value in pairs(recipe.ingredients) do
            local amount_per_second = acc.raw_ingredient_to_amount(value, craft_energy, crafting_speed, effectivity.speed)
            amount_per_second = amount_per_second * effectivity.speed

            ---@type NormalizedAmount
            local amount = {
                type = value.type,
                name = value.name,
                amount_per_second = amount_per_second,
            }
            flib_table.insert(ingredients, amount)
        end

        local power = acc.raw_energy_to_power(machine, machine_quality, effectivity.consumption)
        if acc.is_use_fuel(machine) then
            local ftn = assert(line.fuel_typed_name)
            local fuel = tn.typed_name_to_material(ftn)
            local amount_per_second = acc.get_fuel_amount_per_second(power, fuel, machine)

            if acc.is_generator(machine) then
                amount_per_second = -amount_per_second
            end

            ---@type NormalizedAmount
            local amount = {
                type = ftn.type,
                name = ftn.name,
                amount_per_second = amount_per_second,
            }
            flib_table.insert(ingredients, amount)
        end

        ---@type NormalizedProductionLine
        local normalized_line = {
            recipe_typed_name = line.recipe_typed_name,
            products = products,
            ingredients = ingredients,
            power_per_second = power,
            pollution_per_second = acc.raw_emission_to_pollution(machine, "pollution", machine_quality, effectivity.consumption, effectivity.pollution),
        }

        flib_table.insert(normalized_production_lines, normalized_line)
    end
    return normalized_production_lines
end

return M
