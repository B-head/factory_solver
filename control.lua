local flib_dictionary = require "__flib__/dictionary"
local flib_gui = require "__flib__/gui"
local flib_table = require "__flib__/table"

local fs_log = require "fs_log"
local fs_util = require "fs_util"
local save = require "manage/save"
local pre_solve = require "manage/pre_solve"
local virtual = require "manage/virtual"
local dictionary = require "manage/dictionary"
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
    -- Random-chain explorer (tests/chain_explorer.lua) shares this scenario so
    -- the same launcher mod-set control and RCON transport can drive it; its
    -- interface is separate (factory_solver_explore) from the smoke driver's.
    -- It lives under tests/ (harness-only, never loaded outside this gate), so
    -- the require is lazy and resolves from the mod root just like manage/*.
    require("tests/chain_explorer").register()
    -- Headless script context (no __DebugAdapter): default to debug so the RCON
    -- tooling reads back create_problem's debug-tier reproduction data, the same
    -- verbosity a debugger session gets. Trace (the bulky LP internals) stays
    -- opt-in via the /factory-solver-log-level command.
    fs_log.set_level("debug")
end

---Open the docked Build assistant for a player unless it is already shown.
---Called at new-game / new-player time so the early-game Manual mode is visible
---from the start; the panel is part of the saved GUI tree, so it survives
---save/load, and the shortcut still toggles it off afterwards.
---@param player LuaPlayer
local function open_build_assistant_default(player)
    if player.gui.left["factory_solver_build_assistant"] == nil then
        fs_util.add_gui(player.gui.left, build_assistant)
    end
end

script.on_init(function()
    flib_dictionary.on_init()

    storage.virtuals = virtual.create_virtuals()
    -- Locale dictionaries for the constraint-adder name filter. Must be built
    -- here (and in on_configuration_changed), before flib's first on_tick marks
    -- the dictionary module initialized.
    dictionary.build()

    -- New saves are born on the engine-aligned layout default, so they never get
    -- the one-time "the default layout changed" notice. Pre-set the flag here;
    -- existing saves (which reach on_configuration_changed instead) leave it nil
    -- and get the notice once on first load after the update.
    storage.layout_default_notice_shown = true

    -- Force data must exist before any GUI is built: open_build_assistant_default
    -- renders the docked panel, whose make_build_table handler immediately reads
    -- storage.forces via save.get_selected_solution. When the mod is added to an
    -- existing save (players already present), the player loop below runs for real,
    -- so storage.forces has to be ready first. (In a fresh world game.players is
    -- empty at on_init time, which is why this ordering bug stayed hidden.)
    storage.forces = {}
    for _, force in pairs(game.forces) do
        save.init_force_data(force.index)
        if __DebugAdapter then
            for _, quality in pairs(prototypes.quality) do
                force.unlock_quality(quality)
            end
        end
    end

    storage.players = {}
    for _, player in pairs(game.players) do
        save.init_player_data(player.index)
        open_build_assistant_default(player)
        if __DebugAdapter then
            player.cheat_mode = true
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
    -- flib resets its dictionary storage on on_configuration_changed, so the
    -- name-filter dictionaries must be re-declared here too.
    dictionary.build()

    -- One-time chat notice for existing saves: the layout default flipped to
    -- follow Factorio's ingredient-to-product order. Guarded by a storage flag so
    -- it prints exactly once per save (new saves pre-set it in on_init). The flag
    -- is nil on saves created before this change, which is exactly who should be
    -- told. Version-drift-proof: no version comparison needed.
    if not storage.layout_default_notice_shown then
        storage.layout_default_notice_shown = true
        game.print({ "factory-solver-layout-default-changed" })
    end

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
    local player = game.players[event.player_index]
    open_build_assistant_default(player)
    if __DebugAdapter then
        player.cheat_mode = true
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

---The recipe names a technology unlocks, from its unlock-recipe effects. Drives
---the incremental relation_to_recipes update so a research finish/reverse patches
---only the affected recipes instead of rebuilding the whole cache.
---@param research LuaTechnology
---@return string[]
local function unlocked_recipe_names(research)
    local names = {}
    for _, effect in ipairs(research.prototype.effects) do
        if effect.type == "unlock-recipe" then
            names[#names + 1] = effect.recipe
        end
    end
    return names
end

script.on_event(defines.events.on_research_finished, function(event)
    save.apply_research_change(event.research.force.index,
        unlocked_recipe_names(event.research), true)
end)

script.on_event(defines.events.on_research_reversed, function(event)
    save.apply_research_change(event.research.force.index,
        unlocked_recipe_names(event.research), false)
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
    if event.setting ~= "factory-solver-classic-recipe-io-placement"
        and event.setting ~= "factory-solver-classic-production-line-order" then
        return
    end
    -- These per-player display settings are read at GUI build time, so
    -- re-dispatching the production-line rebuild event applies them live (no
    -- re-solve — that path runs in on_tick). The reverse-order setting also
    -- affects the build assistant rows and the results-panel section order, so
    -- refresh both windows (the editor table, results panel and BA table all
    -- listen to on_production_line_changed). Only the toggling player needs it;
    -- the add-production-line dialog re-reads the setting whenever it is opened.
    local player_index = event.player_index
    if not player_index then
        return
    end
    local player = game.players[player_index]
    local window = player.gui.screen["factory_solver_main_window"]
    if window then
        fs_util.dispatch_to_subtree(window, "on_production_line_changed")
    end
    local build_window = player.gui.left["factory_solver_build_assistant"]
    if build_window then
        fs_util.dispatch_to_subtree(build_window, "on_production_line_changed")
    end
end)

-- The main window is sized to fill the whole display (see ui/main_window.lua),
-- which is computed from the player's resolution / UI scale at build time. When
-- either changes while the window is open it would otherwise keep the old size
-- and overflow (or underfill) the screen, so refit it live. Only the affected
-- player's window needs it.
local function refit_main_window(player_index)
    local player = game.players[player_index]
    local window = player.gui.screen["factory_solver_main_window"]
    if window then
        common.resize_window_to_screen(player, window)
    end
end

script.on_event(defines.events.on_player_display_resolution_changed, function(event)
    refit_main_window(event.player_index)
end)

script.on_event(defines.events.on_player_display_scale_changed, function(event)
    refit_main_window(event.player_index)
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
