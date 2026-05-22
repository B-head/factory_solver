local acc = require "manage/accessor"
local save = require "manage/save"
local tn = require "manage/typed_name"

local M = {}

---comment
---@param player_index integer
---@param solution Solution
---@return table<string, { typed_name: TypedName, amount_per_second: number }>
---@return table<string, { typed_name: TypedName, amount_per_second: number }>
---@return table<string, { typed_name: TypedName, amount_per_second: number }>
function M.get_total_amounts(player_index, solution)
    local bonuses = save.get_research_bonuses(player_index)
    ---@type table<string, { typed_name: TypedName, amount_per_second: number }>
    local item_totals = {}
    ---@type table<string, { typed_name: TypedName, amount_per_second: number }>
    local fluid_totals = {}
    ---@type table<string, { typed_name: TypedName, amount_per_second: number }>
    local virtual_totals = {}

    -- Items / virtuals / fluids are all aggregated per LP-variable identity
    -- (typed_name_to_variable_name) so quality variants of the same item
    -- (normal / uncommon / …) and temperature variants of the same fluid stay
    -- in their own buckets — collapsing them would hide recycling-loop flow
    -- that the LP has already solved as distinct variables.
    local function add(bucket, typed_name, amount_per_second)
        local key = tn.typed_name_to_variable_name(typed_name)
        local entry = bucket[key]
        if entry then
            entry.amount_per_second = entry.amount_per_second + amount_per_second
        else
            bucket[key] = {
                typed_name = typed_name,
                amount_per_second = amount_per_second,
            }
        end
    end

    for _, line in ipairs(solution.production_lines) do
        local n = acc.normalize_production_line(line, bonuses)
        local quantity_of_machines_required = save.get_quantity_of_machines_required(solution, line.recipe_typed_name)

        for _, amount in ipairs(n.products) do
            local filter_type = amount.type
            local name = amount.name
            local amount_per_second = amount.amount_per_second * quantity_of_machines_required

            if filter_type == "item" then
                add(item_totals, tn.create_typed_name("item", name, amount.quality), amount_per_second)
            elseif filter_type == "fluid" then
                -- Match the LP-side widening (pre_solve.resolve_bare_fluids):
                -- without this, a bare fluid here would land at a different
                -- key than the bridge endpoint that consumes it.
                local temperature, min_t, max_t = acc.resolve_bare_fluid_product(
                    name, amount.temperature, amount.minimum_temperature, amount.maximum_temperature)
                add(fluid_totals, tn.create_typed_name("fluid", name, nil, temperature, min_t, max_t),
                    amount_per_second)
            elseif filter_type == "virtual_material" then
                add(virtual_totals, tn.create_typed_name("virtual_material", name, amount.quality), amount_per_second)
            else
                add(virtual_totals, tn.create_typed_name("virtual_material", "<material-unknown>"), amount_per_second)
            end
        end

        for _, amount in ipairs(n.ingredients) do
            local filter_type = amount.type
            local name = amount.name
            local amount_per_second = amount.amount_per_second * quantity_of_machines_required

            if filter_type == "item" then
                add(item_totals, tn.create_typed_name("item", name, amount.quality), -amount_per_second)
            elseif filter_type == "fluid" then
                local temperature, min_t, max_t = acc.resolve_bare_fluid_ingredient(
                    name, amount.temperature, amount.minimum_temperature, amount.maximum_temperature)
                add(fluid_totals, tn.create_typed_name("fluid", name, nil, temperature, min_t, max_t),
                    -amount_per_second)
            elseif filter_type == "virtual_material" then
                add(virtual_totals, tn.create_typed_name("virtual_material", name, amount.quality), -amount_per_second)
            else
                add(virtual_totals, tn.create_typed_name("virtual_material", "<material-unknown>"), amount_per_second)
            end
        end

        local fuel_amount = n.fuel_ingredient
        if fuel_amount then
            local filter_type = fuel_amount.type
            local name = fuel_amount.name
            local amount_per_second = fuel_amount.amount_per_second * quantity_of_machines_required

            if filter_type == "item" then
                add(item_totals, tn.create_typed_name("item", name, fuel_amount.quality), -amount_per_second)
            elseif filter_type == "fluid" then
                -- line.fuel_typed_name may be bare on solutions migrated from
                -- pre-0.4.0 saves. Widen here so the totals key matches the
                -- ranged LP variable name the bridge target lands on.
                local temperature, min_t, max_t = acc.resolve_bare_fluid_ingredient(
                    name, fuel_amount.temperature, fuel_amount.minimum_temperature, fuel_amount.maximum_temperature)
                add(fluid_totals, tn.create_typed_name("fluid", name, fuel_amount.quality,
                    temperature, min_t, max_t), -amount_per_second)
            elseif filter_type == "virtual_material" then
                add(virtual_totals, tn.create_typed_name("virtual_material", name, fuel_amount.quality), -amount_per_second)
            else
                add(virtual_totals, tn.create_typed_name("virtual_material", "<material-unknown>"), amount_per_second)
            end
        end
    end

    -- Temperature bridges are injected by create_problem at solve time and do
    -- not appear in solution.production_lines, but their flow contributes to
    -- balancing the LP — without folding them in, a producer's steam@500 and
    -- a consumer's steam@[15,1000] would each show as a non-zero net entry
    -- even though the LP has them tied together. Walk the bridge lines stored
    -- on the Problem and credit/debit each endpoint by its LP-solved flow.
    if solution.problem and solution.raw_variables then
        local x = solution.raw_variables.x
        for _, bridge_line in ipairs(solution.problem.bridges) do
            local key = tn.typed_name_to_variable_name(bridge_line.recipe_typed_name)
            local flow = x[key]
            if flow then
                for _, ingredient in ipairs(bridge_line.ingredients) do
                    add(fluid_totals, tn.create_typed_name("fluid", ingredient.name, nil,
                        ingredient.temperature,
                        ingredient.minimum_temperature,
                        ingredient.maximum_temperature),
                        -flow * ingredient.amount_per_second)
                end
                for _, product in ipairs(bridge_line.products) do
                    add(fluid_totals, tn.create_typed_name("fluid", product.name, nil,
                        product.temperature,
                        product.minimum_temperature,
                        product.maximum_temperature),
                        flow * product.amount_per_second)
                end
            end
        end
    end

    return item_totals, fluid_totals, virtual_totals
end

---comment
---@param player_index integer
---@param solution Solution
---@return number
function M.get_total_power(player_index, solution)
    local bonuses = save.get_research_bonuses(player_index)
    local total = 0

    for _, line in ipairs(solution.production_lines) do
        local n = acc.normalize_production_line(line, bonuses)
        local quantity_of_machines_required = save.get_quantity_of_machines_required(solution, line.recipe_typed_name)
        total = total + n.power_per_second * quantity_of_machines_required
    end

    return total
end

---comment
---@param player_index integer
---@param solution Solution
---@return number
function M.get_total_pollution(player_index, solution)
    local bonuses = save.get_research_bonuses(player_index)
    local total = 0

    for _, line in ipairs(solution.production_lines) do
        local n = acc.normalize_production_line(line, bonuses)
        local quantity_of_machines_required = save.get_quantity_of_machines_required(solution, line.recipe_typed_name)
        total = total + n.pollution_per_second * quantity_of_machines_required
    end

    return total
end

return M
