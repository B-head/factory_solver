local flib_dictionary = require "__flib__/dictionary"
local flib_gui = require "__flib__/gui"
local flib_table = require "__flib__/table"

local fs_util = require "fs_util"
local save = require "manage/save"
local pre_solve = require "manage/pre_solve"
local virtual = require "manage/virtual"
local common = require "ui/common"
local main_window = require "ui/main_window"

script.on_init(function()
    flib_dictionary.on_init()

    storage.virtuals = virtual.create_virtuals()

    storage.players = {}
    for _, player in pairs(game.players) do
        save.init_player_data(player.index)
        if __DebugAdapter then
            player.cheat_mode = true
        end
    end

    storage.forces = {}
    for _, force in pairs(game.forces) do
        save.init_force_data(force.index)
        if __DebugAdapter then
            for _, quality in pairs(prototypes.quality) do
                force.unlock_quality(quality)
            end
        end
    end

    if __DebugAdapter then
        if remote.interfaces["freeplay"] then
            remote.call("freeplay", "set_skip_intro", true)
            remote.call("freeplay", "set_disable_crashsite", true)
        end
    end
end)

script.on_load(function()
    for _, force in pairs(storage.forces) do
        save.resetup_force_data_metatable(force)
    end
end)

script.on_configuration_changed(function(event)
    flib_dictionary.on_configuration_changed()

    storage.virtuals = virtual.create_virtuals()

    for _, player in pairs(game.players) do
        save.reinit_player_data(player.index)
        -- TODO reset gui
    end

    for _, force in pairs(game.forces) do
        save.reinit_force_data(force.index)
    end
end)


script.on_event(defines.events.on_player_created, function(event)
    save.init_player_data(event.player_index)
    if __DebugAdapter then
        game.players[event.player_index].cheat_mode = true
    end
end)

script.on_event(defines.events.on_player_changed_force, function(event)
    save.init_force_data(event.force.index)
    if __DebugAdapter then
        for _, quality in pairs(prototypes.quality) do
            event.force.unlock_quality(quality)
        end
    end
end)

script.on_event(defines.events.on_player_removed, function(event)
    storage.players[event.player_index] = nil
end)

script.on_event(defines.events.on_force_created, function(event)
    save.init_force_data(event.force.index)
end)

script.on_event(defines.events.on_force_reset, function(event)
    save.reinit_force_data(event.force.index)
end)

script.on_event(defines.events.on_forces_merged, function(event)
    local destination_force_data = storage.forces[event.destination.index]
    local source_force_data = storage.forces[event.source_index]

    destination_force_data.solutions = flib_table.array_merge {
        destination_force_data.solutions,
        source_force_data.solutions
    }

    storage.forces[event.source_index] = nil
end)

script.on_event(defines.events.on_research_finished, function(event)
    save.reinit_force_data(event.research.force.index)
end)

script.on_event(defines.events.on_research_reversed, function(event)
    save.reinit_force_data(event.research.force.index)
end)

script.on_event(defines.events.on_tick, function(event)
    flib_dictionary.on_tick()

    local solution = pre_solve.find_the_need_for_solve()
    if solution then
        pre_solve.forwerd_solve(solution)

        for _, player in pairs(game.players) do
            local window = player.gui.screen["factory_solver_main_window"]
            if window then
                fs_util.dispatch_to_subtree(window, "on_calculation_changed")
            end
        end
    end
end)

---@param player_index integer
local function toggle_main_window(player_index)
    local player = game.players[player_index]
    local window = player.gui.screen["factory_solver_main_window"]
    if window == nil then
        common.open_gui(player_index, false, main_window)
    else
        common.on_close_self {
            element = window,
            name = "on_close_toggle",
            player_index = player_index,
            tick = game.tick,
            mod_name = window.get_mod()
        }
    end
end

script.on_event("factory-solver-toggle-main-window", function(event)
    toggle_main_window(event.player_index)
end)

script.on_event(defines.events.on_lua_shortcut, function(event)
    if event.prototype_name == "factory-solver-toggle-main-window" then
        toggle_main_window(event.player_index)
    end
end)

flib_dictionary.handle_events()
flib_gui.handle_events()
