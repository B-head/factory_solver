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
                external = "",
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

        -- Older saves predate the Shift+Click clipboard. Leave it nil so the
        -- next paste shows "Nothing to paste" rather than reviving stale data.
        -- When a clipboard does exist, re-run typed_name_migration over every
        -- TypedName so quality renames (etc.) don't ghost-survive in saved
        -- player state.
        local clipboard = player_data.machine_clipboard
        if clipboard then
            tn.typed_name_migration(clipboard.machine_typed_name)
            tn.typed_name_migration(clipboard.fuel_typed_name)
            for _, typed_name in pairs(clipboard.module_typed_names) do
                tn.typed_name_migration(typed_name)
            end
            for _, affected in ipairs(clipboard.affected_by_beacons) do
                tn.typed_name_migration(affected.beacon_typed_name)
                for _, typed_name in pairs(affected.module_typed_names) do
                    tn.typed_name_migration(typed_name)
                end
            end
        end
        tn.typed_name_migration(player_data.module_clipboard)
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
        research_unit_energy = 30,
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
            group_infos = { item = {}, fluid = {}, recipe = {}, virtual_recipe = {}, external = {} },
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
        -- Saves opted in before research_unit_energy existed still have the
        -- field nil, which would silently fall back to "no scaling" in the
        -- lab branch of get_crafting_speed. Backfill with the 30s default so
        -- the opted-in user gets the new behaviour without having to reopen
        -- the dialog and re-Sync.
        if force_data.research_bonuses and not force_data.research_bonuses.research_unit_energy then
            force_data.research_bonuses.research_unit_energy = 30
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
                    and (line.fuel_typed_name.minimum_temperature == nil
                        or line.fuel_typed_name.minimum_temperature
                            ~= line.fuel_typed_name.maximum_temperature)
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
    -- research_unit_energy is per-technology, so we snapshot the active
    -- research's value (or 30s as the vanilla automation-science-pack default
    -- when no research is queued). The runtime field returns ticks at the
    -- baseline lab power draw, so we divide by acc.second_per_tick (=60 here)
    -- to land on the seconds-per-unit semantics the rest of the mod uses.
    -- cleanup_float is unnecessary: the value is read directly from the
    -- prototype, not accumulated through additive deltas the way the
    -- modifier-based scalars above are.
    local rue_ticks = force.current_research and force.current_research.research_unit_energy
    bonuses.research_unit_energy = rue_ticks and (rue_ticks / acc.second_per_tick) or 30

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

---Build-progress "done" flags for the build assistant's TODO column. Keyed by
---the recipe variable name (the same per-line identity the solver uses), so
---they survive line reordering and never collide. Stored on the Solution
---because the flags describe progress on a shared (force-scoped) factory plan,
---not per-player state.
---@param solution Solution
---@param recipe_typed_name TypedName
---@return boolean
function M.is_line_done(solution, recipe_typed_name)
    local set = solution.done_lines
    if not set then
        return false
    end
    local key = string.format("%s/%s/%s", recipe_typed_name.type, recipe_typed_name.name, recipe_typed_name.quality)
    return set[key] == true
end

---@param solution Solution
---@param recipe_typed_name TypedName
---@param done boolean
function M.set_line_done(solution, recipe_typed_name, done)
    local key = string.format("%s/%s/%s", recipe_typed_name.type, recipe_typed_name.name, recipe_typed_name.quality)
    local set = solution.done_lines
    if not set then
        set = {}
        solution.done_lines = set
    end
    set[key] = done or nil
end

---@param solution Solution
function M.reset_done(solution)
    solution.done_lines = nil
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

---Import a list of payloads (one per FP Factory) as separate Solutions and
---return the name of the last one. The caller selects which to focus.
---@param solutions table<string, Solution>
---@param payloads table[]
---@return string?
function M.import_solutions(solutions, payloads)
    local last_name = nil
    for _, payload in ipairs(payloads) do
        last_name = M.import_solution(solutions, payload)
    end
    return last_name
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
        minimum_temperature = typed_name.minimum_temperature,
        maximum_temperature = typed_name.maximum_temperature,
        limit_type = "upper",
        limit_amount_per_second = amount,
    }
    flib_table.insert(constraints, add_data)

    solution.solver_state = "ready"
end

---comment
---@param solution Solution
---@param constraint_index integer
function M.delete_constraint(solution, constraint_index)
    local constraints = solution.constraints
    flib_table.remove(constraints, constraint_index)

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
    local machine = tn.typed_name_to_machine(machine_typed_name)

    -- A caller-supplied fluid fuel (the recipe picker passes the clicked
    -- material as the fuel when browsing the fuel category) carries that
    -- material's own temperature, which is the producer's, not what this machine
    -- accepts. Re-derive the temperature from the machine's intake — its fixed
    -- fuel range for a fixed-fuel machine (generator, fluid-energy), or the
    -- fluid's physical range otherwise — while keeping the chosen fluid.
    -- Without this the fuel is pinned to the referenced single temperature.
    -- Only newly created lines are corrected here; production lines already
    -- saved with a wrongly pinned fuel temperature are not migrated (the user
    -- can re-pick the fuel to refresh it). A machine change on an existing line
    -- is reconciled separately by acc.reconcile_fuel_for_machine (the
    -- on_make_fuel_table / apply_machine_clipboard paths); this branch keeps its
    -- own bare-fluid fallback because a recipe-picker fuel may name a fluid the
    -- chosen machine doesn't accept.
    if fuel_typed_name and fuel_typed_name.type == "fluid" then
        local fixed = acc.try_get_fixed_fuel(machine)
        if fixed and fixed.type == "fluid" and fixed.name == fuel_typed_name.name then
            fuel_typed_name = fixed
        else
            local lo, hi = acc.resolve_bare_fluid_ingredient(fuel_typed_name.name)
            fuel_typed_name = tn.create_typed_name("fluid", fuel_typed_name.name, nil, lo, hi)
        end
    end
    fuel_typed_name = fuel_typed_name or preset.get_fuel_preset(player_index, machine_typed_name)

    -- Plant lines default substrate to the first tile listed in the plant's
    -- autoplace_specification.tile_restriction. Non-plant recipes leave it
    -- nil. Mutated later through the substrate widget in solution_editor.
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

---Snapshot the machine-side configuration of a production line into the
---per-player clipboard. The whole snapshot (machine + fuel + substrate +
---modules + beacons) is always taken; the caller-supplied `mode` decides
---which subset paste will later apply. deep_copy detaches the snapshot
---from the live line so subsequent edits on the source row don't bleed
---into the clipboard.
---@param player_index integer
---@param line ProductionLine
---@param mode "machine_fuel"|"module_beacon"
function M.set_machine_clipboard(player_index, line, mode)
    storage.players[player_index].machine_clipboard = {
        mode = mode,
        machine_typed_name = flib_table.deep_copy(line.machine_typed_name),
        fuel_typed_name = line.fuel_typed_name and flib_table.deep_copy(line.fuel_typed_name) or nil,
        substrate_tile_name = line.substrate_tile_name,
        module_typed_names = flib_table.deep_copy(line.module_typed_names),
        affected_by_beacons = flib_table.deep_copy(line.affected_by_beacons),
    }
end

---@param player_index integer
---@return MachineClipboard?
function M.get_machine_clipboard(player_index)
    return storage.players[player_index].machine_clipboard
end

---Slot-level companion to set_machine_clipboard for the single-module
---Shift+Click flow inside machine_setup. The clipboard is independent
---from machine_clipboard so the two coexist: the row-level flow stores
---a full ProductionLine snapshot, this one stores a single module
---TypedName. deep_copy detaches from any caller-owned table; nil clears.
---@param player_index integer
---@param typed_name TypedName?
function M.set_module_clipboard(player_index, typed_name)
    storage.players[player_index].module_clipboard =
        typed_name and flib_table.deep_copy(typed_name) or nil
end

---@param player_index integer
---@return TypedName?
function M.get_module_clipboard(player_index)
    return storage.players[player_index].module_clipboard
end

---@alias PasteResult "ok"|"empty"|"incompatible_machine"|"no_module_or_beacon_slot"

---Apply the clipboard to a production line. Mode-driven: machine_fuel
---rewrites machine + fuel + substrate, module_beacon rewrites modules +
---beacons. Sanitization in priority order:
---  * empty clipboard → reject "empty"
---  * machine_fuel mode + clipboard machine cannot run target recipe
---    → reject "incompatible_machine" (no partial application, to avoid
---    leaving fuel/substrate from one machine paired with another)
---  * module_beacon mode + target machine takes neither modules nor beacons
---    → reject "no_module_or_beacon_slot"
---  * machine_fuel: substrate dropped if target machine isn't a plant or
---    the tile isn't in tile_restriction. fuel dropped if not in target
---    machine's fuel categories, falling back to preset.
---  * module_beacon: oversized module slots are trimmed; allowed_effects
---    mismatch is left to the LP mask (UI warning label already handles it).
---On success, marks the solution dirty.
---@param player_index integer
---@param solution Solution
---@param line_index integer
---@return PasteResult
function M.apply_machine_clipboard(player_index, solution, line_index)
    local clipboard = storage.players[player_index].machine_clipboard
    if not clipboard then
        return "empty"
    end

    local line = solution.production_lines[line_index]
    if not line then
        return "empty"
    end

    if clipboard.mode == "machine_fuel" then
        local recipe = tn.typed_name_to_recipe(line.recipe_typed_name)
        local candidates = acc.get_machines_for_recipe(recipe)
        local clipboard_machine_name = clipboard.machine_typed_name.name
        local compatible = false
        for _, candidate in ipairs(candidates) do
            if candidate.name == clipboard_machine_name then
                compatible = true
                break
            end
        end
        if not compatible then
            return "incompatible_machine"
        end

        local new_machine_typed_name = flib_table.deep_copy(clipboard.machine_typed_name)
        local new_machine = tn.typed_name_to_machine(new_machine_typed_name)

        -- Reconcile the clipboard fuel to the target machine across every fuel mode:
        -- heat / fixed-filter fluid keep or adopt the machine's intrinsic fuel (a
        -- fluid temperature is kept-or-snapped), item / any-fluid keep an in-list
        -- fuel, otherwise fall back to this machine's preset. A fuel-less machine
        -- yields nil. Mirrors the dialog reconciliation in on_make_fuel_table.
        local clipboard_fuel = clipboard.fuel_typed_name
            and flib_table.deep_copy(clipboard.fuel_typed_name) or nil
        local new_fuel_typed_name, needs_preset =
            acc.reconcile_fuel_for_machine(clipboard_fuel, new_machine)
        if needs_preset then
            new_fuel_typed_name = preset.get_fuel_preset(player_index, new_machine_typed_name)
        end

        local new_substrate = nil
        if new_machine.type == "plant" then
            local tiles = acc.get_plant_substrate_tiles(new_machine)
            if clipboard.substrate_tile_name
                and flib_table.find(tiles, clipboard.substrate_tile_name)
            then
                new_substrate = clipboard.substrate_tile_name
            else
                new_substrate = tiles[1]
            end
        end

        line.machine_typed_name = new_machine_typed_name
        line.fuel_typed_name = new_fuel_typed_name
        line.substrate_tile_name = new_substrate
    else
        local target_machine = tn.typed_name_to_machine(line.machine_typed_name)
        local takes_modules = (target_machine.module_inventory_size or 0) > 0
        local takes_beacons = acc.is_use_beacon(target_machine)
        if not takes_modules and not takes_beacons then
            return "no_module_or_beacon_slot"
        end

        if takes_modules then
            line.module_typed_names = acc.trim_modules(
                flib_table.deep_copy(clipboard.module_typed_names),
                target_machine.module_inventory_size)
        else
            line.module_typed_names = {}
        end

        if takes_beacons then
            line.affected_by_beacons = flib_table.deep_copy(clipboard.affected_by_beacons)
        else
            line.affected_by_beacons = {}
        end
    end

    solution.solver_state = "ready"
    return "ok"
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

---comment
---@param solution Solution
---@param from_constraint_index integer
---@param to_constraint_index integer
function M.move_constraint(solution, from_constraint_index, to_constraint_index)
    local constraints = solution.constraints
    local tail = #constraints

    from_constraint_index = flib_math.clamp(from_constraint_index, 1, tail)
    to_constraint_index = flib_math.clamp(to_constraint_index, 1, tail)

    local temp = flib_table.remove(constraints, from_constraint_index)
    flib_table.insert(constraints, to_constraint_index, temp)
end

return M
