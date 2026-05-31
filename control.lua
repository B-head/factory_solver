local flib_dictionary = require "__flib__/dictionary"
local flib_gui = require "__flib__/gui"
local flib_table = require "__flib__/table"

local fs_log = require "fs_log"
local fs_util = require "fs_util"
local save = require "manage/save"
local pre_solve = require "manage/pre_solve"
local virtual = require "manage/virtual"
local common = require "ui/common"
local main_window = require "ui/main_window"
local build_assistant = require "ui/build_assistant"

-- factoriomod-debug injects __DebugAdapter as a truthy global only when the
-- VM is running under the debugger. The injection happens before any mod
-- code loads, so taking a local snapshot here is safe and keeps LuaLS from
-- flagging the global as undefined.
local __DebugAdapter = _G["__DebugAdapter"]

-- Activate the RCON-driven smoke driver only when this Factorio instance was
-- launched as a server with the factory_solver/smoke_rcon scenario (see
-- tests/smoke_rcon.ps1). The mod's normal flow is untouched otherwise. No
-- on_player_created / on_tick hook is needed: the solver pump in on_tick already
-- runs force-scoped, and the launcher drives setup / polling over RCON. We just
-- expose the remote interface it calls. remote.add_interface is not persisted,
-- so it must run on every load -- the control.lua main chunk does, which is
-- where we are.
if script.level and script.level.mod_name == "factory_solver"
    and script.level.level_name == "smoke_rcon"
then
    require("manage/smoke_rcon").register()
    -- Headless script context (no __DebugAdapter): default to debug so the RCON
    -- tooling reads back create_problem's debug-tier reproduction data, the same
    -- verbosity a debugger session gets. Trace (the bulky LP internals) stays
    -- opt-in via the /factory-solver-log-level command.
    fs_log.set_level("debug")
end

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
        local player_data = storage.players[player.index]
        local screen = player.gui.screen
        for _, name in ipairs(player_data.opened_gui) do
            if screen[name] then
                screen[name].destroy()
            end
        end
        player_data.opened_gui = {}
        player.set_shortcut_toggled("factory-solver-toggle-main-window", false)

        -- The build assistant is a docked panel in gui.left, outside the
        -- opened_gui modal stack, so it is destroyed and untoggled explicitly.
        if player.gui.left["factory_solver_build_assistant"] then
            player.gui.left["factory_solver_build_assistant"].destroy()
        end
        player.set_shortcut_toggled("factory-solver-toggle-build-assistant", false)
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

    local force_data, solution = pre_solve.find_the_need_for_solve()
    if force_data and solution then
        pre_solve.forwerd_solve(force_data, solution)

        for _, player in pairs(game.players) do
            local window = player.gui.screen["factory_solver_main_window"]
            if window then
                fs_util.dispatch_to_subtree(window, "on_calculation_changed")
            end
            local build_window = player.gui.left["factory_solver_build_assistant"]
            if build_window then
                fs_util.dispatch_to_subtree(build_window, "on_calculation_changed")
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

-- The build assistant is a persistent, docked panel rather than a floating
-- window: it lives in gui.left so it sits beside the main window instead of
-- hiding behind it, and it is added/destroyed directly rather than through
-- common.open_gui (which targets gui.screen, pushes onto the opened_gui modal
-- stack, and sets player.opened — none of which fit a docked panel).
---@param player_index integer
local function toggle_build_assistant(player_index)
    local player = game.players[player_index]
    local window = player.gui.left["factory_solver_build_assistant"]
    if window == nil then
        fs_util.add_gui(player.gui.left, build_assistant)
    else
        fs_util.dispatch_to_subtree(window, "on_close")
        window.destroy()
    end
end

---@param event EventData.CustomInputEvent
script.on_event("factory-solver-toggle-main-window", function(event)
    toggle_main_window(event.player_index)
end)

---@param event EventData.CustomInputEvent
script.on_event("factory-solver-toggle-build-assistant", function(event)
    toggle_build_assistant(event.player_index)
end)

script.on_event(defines.events.on_lua_shortcut, function(event)
    if event.prototype_name == "factory-solver-toggle-main-window" then
        toggle_main_window(event.player_index)
    elseif event.prototype_name == "factory-solver-toggle-build-assistant" then
        toggle_build_assistant(event.player_index)
    end
end)

-- Lets a player (or the server console) raise the fs_log threshold below
-- `debug` so the A-matrix dump in solver.lp's "ready" block reaches the log.
-- Intended for fixture capture: turn trace on, trigger a solve, copy the
-- emitted cost/limit/subject block into a tests/cases/*.lua entry, turn it
-- back off. Threshold lives in fs_log's module-local state (not storage), so
-- the change is per-process and does not need to survive save/load; running
-- the command on every client in MP keeps log threshold consistent across
-- clients without making it desync-relevant.
commands.add_command(
    "factory-solver-log-level",
    "Set the fs_log threshold (trace | debug | info | warn | error). " ..
    "With no argument, prints the current level.",
    function(event)
        local sink = event.player_index
            and game.players[event.player_index]
            or game
        local arg = event.parameter and event.parameter:match("^%s*(%S+)%s*$")
        if not arg then
            sink.print("factory_solver log level: " .. fs_log.get_level())
            return
        end
        local ok = pcall(fs_log.set_level, arg)
        if ok then
            sink.print("factory_solver log level set to " .. arg)
        else
            sink.print("factory_solver: unknown log level '" .. arg ..
                "' (expected trace | debug | info | warn | error)")
        end
    end
)

flib_dictionary.handle_events()
flib_gui.handle_events()
