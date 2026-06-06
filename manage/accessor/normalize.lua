-- Top-level orchestration: fold one ProductionLine into a per-second
-- NormalizedProductionLine by pulling together the amount / energy / recipe /
-- modules helpers. This is the sink of the accessor dependency graph (it
-- depends on every other accessor sub-module). Part of the manage/accessor.lua
-- family; reached through the accessor facade.

local flib_table = require "__flib__/table"
local tn = require "manage/typed_name"
local amount_acc = require "manage/accessor/amount"
local recipe_acc = require "manage/accessor/recipe"
local energy_acc = require "manage/accessor/energy"
local modules_acc = require "manage/accessor/modules"

local M = {}

---Fold one ProductionLine into a per-second NormalizedProductionLine:
---products, ingredients (with lab input productivity), fuel, power and
---pollution all live on the returned table. Quality decomposition and
---bare-fluid temperature widening are deliberately NOT applied here — they
---are LP-only post-steps owned by pre_solve and would distort UI / totals
---views that need the raw per-recipe-quality amounts.
---The companion ModuleEffects is returned so pre_solve can drive
---quality_decomposition with effectivity.quality without recomputing.
---UI / totals callers that don't need it can drop the second return.
---@param line ProductionLine
---@param bonuses ResearchBonuses?
---@return NormalizedProductionLine
---@return ModuleEffects
function M.normalize_production_line(line, bonuses)
    local recipe = tn.typed_name_to_recipe(line.recipe_typed_name)
    local recipe_quality = line.recipe_typed_name.quality
    local machine = tn.typed_name_to_machine(line.machine_typed_name)
    local machine_quality = line.machine_typed_name.quality
    local total_modules = modules_acc.get_total_modules(machine, machine_quality, line.module_typed_names,
        line.affected_by_beacons, bonuses)
    local maximum_productivity = recipe_acc.get_maximum_productivity(recipe)
    local effectivity = modules_acc.get_total_effectivity(recipe, total_modules, machine.effect_receiver,
        line.recipe_typed_name, machine, bonuses, maximum_productivity)
    local crafting_energy = recipe_acc.get_crafting_energy(recipe)
    local crafting_speed_cap = recipe_acc.get_crafting_speed_cap(recipe)
    -- Dispatch by recipe object kind. Real recipes (LuaRecipePrototype) are
    -- crafted at rate machine.get_crafting_speed(quality) / recipe.energy and
    -- product/ingredient .amount values are per-craft quantities. Virtual
    -- recipes carry per-craft ratios in .amount (default 1) and the per-second
    -- baseline comes from get_virtual_recipe_rates, which dispatches per
    -- machine type to whichever quality-aware runtime API actually scales for
    -- that entity (boiler -> get_max_energy_usage, generator family ->
    -- get_fluid_usage_per_tick, ...). crafting_energy stays 1 for virtual
    -- recipes so the downstream raw_*_to_amount formula (amount * speed /
    -- energy) collapses to ratio * rate.
    local crafting_speed
    ---@diagnostic disable-next-line: undefined-field
    if recipe.object_name == "LuaRecipePrototype" then
        crafting_speed = machine.get_crafting_speed(machine_quality)
            or machine.mining_speed
            or 0
    else
        crafting_speed = recipe_acc.get_virtual_recipe_rates(machine, machine_quality, bonuses)
    end
    crafting_speed = math.min(crafting_speed * effectivity.speed, crafting_speed_cap)

    ---@type NormalizedAmount[]
    local products = {}
    for _, product in ipairs(recipe.products) do
        local amount = amount_acc.raw_product_to_amount(
            product, recipe_quality, crafting_energy, crafting_speed, effectivity.productivity)
        flib_table.insert(products, amount)
    end

    ---@type NormalizedAmount[]
    local ingredients = {}
    for _, ingredient in ipairs(recipe.ingredients) do
        local amount = amount_acc.raw_ingredient_to_amount(
            ingredient, recipe_quality, crafting_energy, crafting_speed)
        amount_acc.apply_lab_input_productivity_to_ingredient(amount, machine)
        flib_table.insert(ingredients, amount)
    end

    ---@type NormalizedAmount?
    local fuel_ingredient = nil
    if energy_acc.is_use_fuel(machine) then
        local ftn = assert(line.fuel_typed_name)
        local fuel = tn.typed_name_to_material(ftn)
        local amount_per_second = energy_acc.get_fuel_amount_per_second(machine, machine_quality,
            fuel, ftn.quality, effectivity.consumption, ftn)
        ---@type NormalizedAmount
        fuel_ingredient = {
            type = ftn.type, ---@diagnostic disable-line: assign-type-mismatch
            name = ftn.name,
            quality = ftn.quality,
            amount_per_second = amount_per_second,
            minimum_temperature = ftn.minimum_temperature,
            maximum_temperature = ftn.maximum_temperature,
        }
    end

    -- Spent fuel: a burning machine emits the fuel's burnt_result 1:1 with the
    -- fuel it consumes (one uranium-fuel-cell burned -> one used-up cell). Kept
    -- as a dedicated field rather than folded into `products` so it bypasses
    -- pre_solve.quality_decomposition (the spent cell is a deterministic byproduct,
    -- not a module-quality cascade) and the UI can render it apart from recipe
    -- outputs, mirroring how fuel_ingredient sits apart from ingredients. Only
    -- item fuels carry a burnt_result; the spent cell inherits the fuel's quality.
    ---@type NormalizedAmount?
    local fuel_burnt_result = nil
    if fuel_ingredient and fuel_ingredient.type == "item" then
        local burnt = energy_acc.try_get_burnt_result(tn.typed_name_to_material(line.fuel_typed_name))
        if burnt then
            ---@type NormalizedAmount
            fuel_burnt_result = {
                type = "item",
                name = burnt.name,
                quality = fuel_ingredient.quality,
                amount_per_second = fuel_ingredient.amount_per_second,
            }
        end
    end

    local power = energy_acc.get_power_per_second(machine, machine_quality,
        effectivity.consumption, line.fuel_typed_name)
    local pollution = energy_acc.get_pollution_per_second(machine, "pollution",
        machine_quality, effectivity.consumption, effectivity.pollution,
        line.fuel_typed_name)

    -- Recipe-intrinsic pollution (plant.harvest_emissions baked into
    -- VirtualRecipe.pollution_per_craft by manage/virtual.lua). Real recipes
    -- and other virtual recipes leave this nil and contribute nothing here.
    -- Approximation: per-harvest emission scaled by craft rate so module
    -- pollution effectivity still applies symmetrically with the energy-
    -- source pollution above.
    -- LuaRecipePrototype rejects unknown-key indexing at the C++ layer, so
    -- gate the lookup on the VirtualRecipe branch (see get_crafting_speed_cap
    -- for the same pattern).
    ---@diagnostic disable-next-line: undefined-field
    if recipe.object_name ~= "LuaRecipePrototype" then
        ---@diagnostic disable-next-line: undefined-field
        local pollution_per_craft = recipe.pollution_per_craft
        if pollution_per_craft then
            pollution = pollution
                + pollution_per_craft * (crafting_speed / crafting_energy) * effectivity.pollution
        end
    end

    -- Propagate the source/sink class from the VirtualRecipe so create_problem
    -- and report read it as a flag instead of parsing the "<source>"/"<sink>"
    -- prefix off the prototype name. LuaRecipePrototype rejects unknown-key
    -- indexing at the C++ layer (same gate as pollution_per_craft above), so
    -- guard the read on the VirtualRecipe branch.
    local is_source, is_sink
    ---@diagnostic disable-next-line: undefined-field
    if recipe.object_name ~= "LuaRecipePrototype" then
        ---@diagnostic disable-next-line: undefined-field
        is_source = recipe.is_source or nil
        ---@diagnostic disable-next-line: undefined-field
        is_sink = recipe.is_sink or nil
    end

    ---@type NormalizedProductionLine
    local normalized_line = {
        recipe_typed_name = line.recipe_typed_name,
        products = products,
        ingredients = ingredients,
        fuel_ingredient = fuel_ingredient,
        fuel_burnt_result = fuel_burnt_result,
        power_per_second = power,
        pollution_per_second = pollution,
        is_source = is_source,
        is_sink = is_sink,
    }
    return normalized_line, effectivity
end

return M
