local flib_table = require "__flib__/table"
local flib_math = require "__flib__/math"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local preset = require "manage/preset"
local relation = require "manage/relation"
local tn = require "manage/typed_name"
local problem_generator = require "solver/problem_generator"

-- See control.lua for why __DebugAdapter is mirrored as a local snapshot.
local __DebugAdapter = _G["__DebugAdapter"]

local M = {}

---comment
---@param player_index integer
function M.init_player_data(player_index)
    if not storage.players[player_index] then
        storage.players[player_index] = {
            selected_solution = "",
            selected_filter_type = "item",
            selected_filter_group = {
                item = "",
                fluid = "",
                recipe = "",
                virtual_recipe = "",
            },
            unresearched_craft_visible = __DebugAdapter ~= nil,
            hidden_craft_visible = __DebugAdapter ~= nil,
            time_scale = "minute",
            amount_unit = "time",
            presets = {
                fuel = preset.create_fuel_presets(),
                fluid_fuel = preset.create_fluid_fuel_preset(),
                resource = preset.create_resource_presets(),
                machine = preset.create_machine_presets(),
                pump = preset.create_pump_presets(),
                lab = preset.create_lab_presets(),
            },
            opened_gui = {},
        }
    end
end

---comment
---@param player_index integer
function M.reinit_player_data(player_index)
    ---@diagnostic disable: undefined-field
    ---@diagnostic disable: inject-field
    local player_data = storage.players[player_index]
    if player_data then
        if not fs_util.scale_per_second[player_data.time_scale] then
            player_data.time_scale = "minute"
        end
        if false then
            player_data.amount_unit = "time"
        end
        local presets = player_data.presets
        if presets then
            presets.fuel = preset.create_fuel_presets(presets.fuel)
            presets.fluid_fuel = preset.create_fluid_fuel_preset(presets.fluid_fuel)
            presets.resource = preset.create_resource_presets(presets.resource)
            presets.machine = preset.create_machine_presets(presets.machine)
            presets.pump = preset.create_pump_presets(presets.pump)
            presets.lab = preset.create_lab_presets(presets.lab)
        else
            player_data.presets = {
                fuel = preset.create_fuel_presets(player_data.fuel_presets),
                fluid_fuel = preset.create_fluid_fuel_preset(),
                resource = preset.create_resource_presets(player_data.resource_presets),
                machine = preset.create_machine_presets(player_data.machine_presets),
                pump = preset.create_pump_presets(),
                lab = preset.create_lab_presets(),
            }
            player_data.fuel_presets = nil
            player_data.resource_presets = nil
            player_data.machine_presets = nil
        end
    else
        M.init_player_data(player_index)
    end
    ---@diagnostic enable: undefined-field
    ---@diagnostic enable: inject-field
end

---Build a zeroed ResearchBonuses. Opt-in by design: the solver only sees
---research bonuses after the user explicitly clicks Apply in the dialog, so
---both fresh saves and migrated saves start with everything at 0 (and only
---"normal" quality unlocked). Quality expansion is similarly gated until the
---user opts in via the dialog.
---@return ResearchBonuses
function M.default_research_bonuses()
    return {
        recipe_productivity = {},
        mining_drill_productivity = 0,
        laboratory_productivity = 0,
        laboratory_speed = 0,
        beacon_distribution = 0,
        unlocked_qualities = { normal = true },
    }
end

---comment
---@param force_index integer
function M.init_force_data(force_index)
    if not storage.forces[force_index] then
        storage.forces[force_index] = {
            relation_to_recipes = { enabled_recipe = {}, item = {}, fluid = {}, virtual_recipe = {}, virtual_recipe_researched = {} },
            relation_to_recipes_needs_updating = true,
            group_infos = { item = {}, fluid = {}, recipe = {}, virtual_recipe = {} },
            group_infos_needs_updating = true,
            solutions = {},
            research_bonuses = M.default_research_bonuses(),
        }
    end
end

---comment
---@param force_index integer
function M.reinit_force_data(force_index)
    ---@diagnostic disable: undefined-field
    ---@diagnostic disable: inject-field
    local force_data = storage.forces[force_index]
    if force_data then
        force_data.relation_to_recipes_needs_updating = true
        force_data.group_infos_needs_updating = true

        -- Older saves predate research_bonuses. Initialize to zeros so the
        -- ongoing behavior is unchanged unless the user opens the dialog and
        -- opts in. LuaForce values are deliberately not snapshotted here.
        if not force_data.research_bonuses then
            force_data.research_bonuses = M.default_research_bonuses()
        end

        for _, solution in pairs(force_data.solutions) do
            for _, line in ipairs(solution.production_lines) do
                tn.typed_name_migration(line.recipe_typed_name)
                tn.typed_name_migration(line.machine_typed_name)
                tn.typed_name_migration(line.fuel_typed_name)

                -- Pre-machine-picker offshore-pump recipes were keyed
                -- <pump>{pump}:{tile}; the new form is <pump>{tile}, with
                -- the pump moved into machine_typed_name (already migrated
                -- above) and dispatched dynamically by pumped_fluid_name.
                local recipe_name = line.recipe_typed_name.name
                local _, tile_name = recipe_name:match("^(<pump>[^:]+):(.+)$")
                if tile_name then
                    line.recipe_typed_name.name = "<pump>" .. tile_name
                end

                -- Legacy lines for burns_fluid=false machines held a bare or
                -- range-only fluid TypedName; the picker now offers concrete
                -- temperature variants. Pin them to a sensible default so the
                -- selection lights up a picker button after upgrade.
                if line.fuel_typed_name
                    and line.fuel_typed_name.type == "fluid"
                    and line.fuel_typed_name.temperature == nil
                then
                    local machine = tn.typed_name_to_machine(line.machine_typed_name)
                    local variant = acc.get_default_fluid_fuel_variant(machine)
                    if variant then
                        line.fuel_typed_name = tn.craft_to_typed_name(variant)
                    end
                end

                if line.module_names then
                    local module_typed_names = {}
                    for _, name in pairs(line.module_names) do
                        local typed_name = tn.create_typed_name("item", name)
                        flib_table.insert(module_typed_names, typed_name)
                    end
                    line.module_typed_names = module_typed_names
                    line.module_names = nil
                else
                    for _, typed_name in pairs(line.module_typed_names) do
                        tn.typed_name_migration(typed_name)
                    end
                end

                for _, affected in ipairs(line.affected_by_beacons) do
                    if affected.beacon_name then
                        affected.beacon_typed_name = tn.create_typed_name("machine", affected.beacon_name)
                        affected.beacon_name = nil
                    else
                        tn.typed_name_migration(affected.beacon_typed_name)
                    end

                    if affected.module_names then
                        local module_typed_names = {}
                        for _, name in pairs(affected.module_names) do
                            local typed_name = tn.create_typed_name("item", name)
                            flib_table.insert(module_typed_names, typed_name)
                        end
                        affected.module_typed_names = module_typed_names
                        affected.module_names = nil
                    else
                        for _, typed_name in pairs(affected.module_typed_names) do
                            tn.typed_name_migration(typed_name)
                        end
                    end
                end
            end
            
            for _, constraint in ipairs(solution.constraints) do
                tn.typed_name_migration(constraint)
                if constraint.type == "virtual_recipe" then
                    local _, tile_name = constraint.name:match("^(<pump>[^:]+):(.+)$")
                    if tile_name then
                        constraint.name = "<pump>" .. tile_name
                    end
                end
            end

            -- Phase 4 / 5 (fluid temperature dimension) changed the LP variable
            -- name format for fluids. Any cached Problem holds variable keys in
            -- the old format and would silently mismatch the next solve. Discard
            -- the cache and let on_tick rebuild it; raw_variables (warm-start
            -- vector) is keyed by the same names, so drop it too.
            solution.problem = nil
            solution.raw_variables = nil
            solution.solver_state = "ready"
        end
    else
        M.init_force_data(force_index)
    end
    ---@diagnostic enable: undefined-field
    ---@diagnostic enable: inject-field
end

---comment
---@param force_data ForceLocalData
function M.resetup_force_data_metatable(force_data)
    if force_data then
        for _, solution in pairs(force_data.solutions) do
            if solution.problem then
                problem_generator.setup_metatable(solution.problem)
            end
        end
    end
end

---comment
---@param player_index integer
---@return PlayerLocalData
function M.get_player_data(player_index)
    return storage.players[player_index]
end

---comment
---@param player_index integer
---@return table<string, Solution>
function M.get_solutions(player_index)
    local force_index = game.players[player_index].force_index
    return storage.forces[force_index].solutions
end

---comment
---@param player_index integer
---@return Solution?
function M.get_selected_solution(player_index)
    local force_index = game.players[player_index].force_index
    local player_data = storage.players[player_index]
    return storage.forces[force_index].solutions[player_data.selected_solution]
end

---Enumerate every recipe that has at least one technology effect of type
---`change-recipe-productivity`. Stable across forces (data-stage prototype
---scan), so the dialog can render a fixed row list and Sync can iterate over
---the same recipe set.
---@return string[]
function M.list_productivity_research_recipes()
    local seen = {}
    local result = {}
    for _, tech in pairs(prototypes.technology) do
        for _, effect in ipairs(tech.effects or {}) do
            if effect.type == "change-recipe-productivity" and effect.recipe then
                if not seen[effect.recipe] then
                    seen[effect.recipe] = true
                    flib_table.insert(result, effect.recipe)
                end
            end
        end
    end
    flib_table.sort(result)
    return result
end

---Round-trip through %g so float noise from research-unit additions
---(e.g. 0.10000000149012) lands on the same value as the user would have
---typed (0.1). The discarded tail is ~1e-9, well below the LP tolerance,
---so this is cosmetic from the solver's standpoint but keeps the dialog's
---displayed text and the committed snapshot identical.
---@param value number
---@return number
local function cleanup_float(value)
    return tonumber(string.format("%g", value)) or 0
end

---Snapshot the current LuaForce research-bonus values into a fresh
---ResearchBonuses table. Reading individual force properties by name is
---deterministic across clients (per-name lookups, no iteration over engine
---tables), so this is safe to call from a lockstep GUI handler.
---@param force LuaForce
---@return ResearchBonuses
function M.snapshot_force_research_bonuses(force)
    local bonuses = M.default_research_bonuses()
    bonuses.mining_drill_productivity = cleanup_float(force.mining_drill_productivity_bonus)
    bonuses.laboratory_productivity = cleanup_float(force.laboratory_productivity_bonus)
    bonuses.laboratory_speed = cleanup_float(force.laboratory_speed_modifier)
    bonuses.beacon_distribution = cleanup_float(force.beacon_distribution_modifier)

    for _, recipe_name in ipairs(M.list_productivity_research_recipes()) do
        local raw = force.recipes[recipe_name] and force.recipes[recipe_name].productivity_bonus or 0
        local value = cleanup_float(raw)
        if value ~= 0 then
            bonuses.recipe_productivity[recipe_name] = value
        end
    end

    bonuses.unlocked_qualities = { normal = true }
    for _, quality in pairs(prototypes.quality) do
        if not quality.hidden and force.is_quality_unlocked(quality) then
            bonuses.unlocked_qualities[quality.name] = true
        end
    end

    return bonuses
end

---Commit a new ResearchBonuses snapshot into the force and mark every
---solution as needing a fresh solve. Heavy IPM work is deferred to
---`on_tick` so the click handler itself stays cheap (multiplayer lockstep
---would otherwise pay the convergence cost on every client at the same
---tick).
---@param force_data ForceLocalData
---@param new_bonuses ResearchBonuses
function M.apply_research_bonuses(force_data, new_bonuses)
    force_data.research_bonuses = new_bonuses
    for _, solution in pairs(force_data.solutions) do
        solution.problem = nil
        solution.raw_variables = nil
        solution.solver_state = "ready"
    end
end

---comment
---@param player_index integer
---@return ResearchBonuses
function M.get_research_bonuses(player_index)
    local force_index = game.players[player_index].force_index
    return storage.forces[force_index].research_bonuses
end

---comment
---@param player_index integer
---@return RelationToRecipes
function M.get_relation_to_recipes(player_index)
    local force_index = game.players[player_index].force_index
    local force_data = storage.forces[force_index]
    if force_data.relation_to_recipes_needs_updating then
        force_data.relation_to_recipes_needs_updating = false
        force_data.relation_to_recipes = relation.create_relation_to_recipes(force_index)
    end
    return force_data.relation_to_recipes
end

---comment
---@param player_index integer
---@param filter_type FilterType
---@return GroupInfos
function M.get_group_infos(player_index, filter_type)
    local force_index = game.players[player_index].force_index
    local force_data = storage.forces[force_index]
    if force_data.group_infos_needs_updating then
        local relation_to_recipes = M.get_relation_to_recipes(player_index)
        force_data.group_infos_needs_updating = false
        force_data.group_infos = relation.create_group_infos(force_index, relation_to_recipes)
    end
    return assert(force_data.group_infos[filter_type])
end

---comment
---@param solution Solution
---@param typed_name TypedName
---@return number
function M.get_quantity_of_machines_required(solution, typed_name)
    local variable_name = string.format("%s/%s/%s", typed_name.type, typed_name.name, typed_name.quality)
    local solved = solution.quantity_of_machines_required[variable_name]
    if solved then
        return solved
    end
    -- A line that create_problem flagged as inactive has no LP variable, so no
    -- solved quantity exists. Return 0 instead of the 1-fallback so the UI
    -- shows "0 machines / 0 / unit" and grayed-out totals; the fallback itself
    -- still applies before the first solve completes, when inactive set is nil.
    if solution.inactive_recipe_variables and solution.inactive_recipe_variables[variable_name] then
        return 0
    end
    return 1
end

---comment
---@param solutions table<string, Solution>
---@param solution_name string?
---@return string
function M.new_solution(solutions, solution_name)
    solution_name = solution_name or "Solution"

    local new_solution_name
    local postfix_number = 1
    repeat
        new_solution_name = string.format("%s %i", solution_name, postfix_number)
        postfix_number = postfix_number + 1
    until not solutions[new_solution_name]

    ---@type Solution
    local solution = {
        name = new_solution_name,
        constraints = {},
        production_lines = {},
        quantity_of_machines_required = {},
        solver_state = "finished",
    }
    solutions[new_solution_name] = solution

    return new_solution_name
end

---comment
---@param solutions table<string, Solution>
---@param solution_name string
function M.delete_solution(solutions, solution_name)
    solutions[solution_name] = nil
end

---Materialize a decoded payload (from manage/solution_codec) as a new
---Solution. Tries the payload's name as-is, falling back to "<name> N" only
---when the slot is taken so an import into an empty save preserves the
---original name. Derived state (solver caches, machine counts) is left at
---defaults and solver_state="ready" lets the on_tick pump fill it in.
---@param solutions table<string, Solution>
---@param payload table
---@return string
function M.import_solution(solutions, payload)
    local base_name = payload.name
    local new_solution_name = base_name
    local postfix_number = 1
    while solutions[new_solution_name] do
        new_solution_name = string.format("%s %i", base_name, postfix_number)
        postfix_number = postfix_number + 1
    end

    ---@type Solution
    local solution = {
        name = new_solution_name,
        constraints = payload.constraints,
        production_lines = payload.production_lines,
        quantity_of_machines_required = {},
        solver_state = "ready",
    }
    solutions[new_solution_name] = solution

    return new_solution_name
end

---comment
---@param solutions table<string, Solution>
---@param solution_name string
---@param new_solution_name string
---@return string
function M.rename_solution(solutions, solution_name, new_solution_name)
    local temp = solutions[solution_name]
    solutions[solution_name] = nil

    local postfix_number = 1
    while solutions[new_solution_name] do
        new_solution_name = string.format("%s %i", new_solution_name, postfix_number)
        postfix_number = postfix_number + 1
    end

    temp.name = new_solution_name
    solutions[new_solution_name] = temp

    return new_solution_name
end

---comment
---@param solution Solution
function M.sort_constraints(solution)
    -- TODO
end

---comment
---@param solution Solution
---@param typed_name TypedName
function M.new_constraint(solution, typed_name)
    local constraints = solution.constraints

    local pos = fs_util.find(constraints, function(value)
        return tn.equals_typed_name(value, typed_name)
    end)
    if pos then
        return
    end

    local amount
    if typed_name.type == "recipe" or typed_name.type == "virtual_recipe" then
        amount = 1
    else
        amount = 0.5
    end

    ---@type Constraint
    local add_data = {
        type = typed_name.type,
        name = typed_name.name,
        quality = typed_name.quality,
        temperature = typed_name.temperature,
        minimum_temperature = typed_name.minimum_temperature,
        maximum_temperature = typed_name.maximum_temperature,
        limit_type = "upper",
        limit_amount_per_second = amount,
    }
    flib_table.insert(constraints, add_data)

    M.sort_constraints(solution)
    solution.solver_state = "ready"
end

---comment
---@param solution Solution
---@param constraint_index integer
function M.delete_constraint(solution, constraint_index)
    local constraints = solution.constraints
    flib_table.remove(constraints, constraint_index)

    M.sort_constraints(solution)
    solution.solver_state = "ready"
end

---comment
---@param solution Solution
---@param constraint_index integer
---@param data table
function M.update_constraint(solution, constraint_index, data)
    solution.constraints[constraint_index] = flib_table.shallow_merge {
        solution.constraints[constraint_index],
        data,
    }

    M.sort_constraints(solution)
    solution.solver_state = "ready"
end

---comment
---@param player_index integer
---@param solution Solution
---@param recipe_typed_name TypedName
---@param fuel_typed_name TypedName?
---@param line_index integer?
function M.new_production_line(player_index, solution, recipe_typed_name, fuel_typed_name, line_index)
    local production_lines = solution.production_lines
    line_index = line_index or #production_lines + 1

    local pos = fs_util.find(production_lines, function(value)
        return tn.equals_typed_name(value.recipe_typed_name, recipe_typed_name)
    end)
    if pos then
        M.move_production_line(solution, pos, line_index)
        return
    end

    local machine_typed_name = preset.get_machine_preset(player_index, recipe_typed_name)
    fuel_typed_name = fuel_typed_name or preset.get_fuel_preset(player_index, machine_typed_name)

    -- Plant lines default substrate to the first tile listed in the plant's
    -- autoplace_specification.tile_restriction. Non-plant recipes leave it
    -- nil. Mutated later through the substrate widget in solution_editor.
    local machine = tn.typed_name_to_machine(machine_typed_name)
    local substrate_tile_name = nil
    if machine.type == "plant" then
        local tiles = acc.get_plant_substrate_tiles(machine)
        substrate_tile_name = tiles[1]
    end

    ---@type ProductionLine
    local line = {
        recipe_typed_name = recipe_typed_name,
        machine_typed_name = machine_typed_name,
        module_typed_names = {},
        affected_by_beacons = {},
        fuel_typed_name = fuel_typed_name,
        substrate_tile_name = substrate_tile_name,
    }
    flib_table.insert(production_lines, line_index, line)

    solution.solver_state = "ready"
end

---comment
---@param solution Solution
---@param line_index integer?
function M.delete_production_line(solution, line_index)
    local production_lines = solution.production_lines
    flib_table.remove(production_lines, line_index)

    solution.solver_state = "ready"
end

---comment
---@param solution Solution
---@param line_index integer
---@param data ProductionLine
function M.update_production_line(solution, line_index, data)
    local line = solution.production_lines[line_index]
    line.recipe_typed_name = data.recipe_typed_name
    line.machine_typed_name = data.machine_typed_name
    line.module_typed_names = data.module_typed_names
    line.affected_by_beacons = data.affected_by_beacons
    line.fuel_typed_name = data.fuel_typed_name
    line.substrate_tile_name = data.substrate_tile_name

    solution.solver_state = "ready"
end

---comment
---@param solution Solution
---@param from_line_index integer
---@param to_line_index integer
function M.move_production_line(solution, from_line_index, to_line_index)
    local production_lines = solution.production_lines
    local tail = #solution.production_lines

    from_line_index = flib_math.clamp(from_line_index, 1, tail)
    to_line_index = flib_math.clamp(to_line_index, 1, tail)

    local temp = flib_table.remove(production_lines, from_line_index)
    flib_table.insert(production_lines, to_line_index, temp)
end

return M
