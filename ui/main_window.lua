local fs_util = require "fs_util"

local common = require "ui/common"
local solution_selector = require "ui/solution_selector"
local common_settings = require "ui/common_settings"
local solution_editor = require "ui/solution_editor"
local solution_settings = require "ui/solution_settings"
local solution_results = require "ui/solution_results"

local handlers = {}

---@param event EventDataTrait
function handlers.on_main_window_added(event)
    local player = game.players[event.player_index]
    player.set_shortcut_toggled("factory-solver-toggle-main-window", true)
end

---@param event EventDataTrait
function handlers.on_main_window_close(event)
    local player = game.players[event.player_index]
    player.set_shortcut_toggled("factory-solver-toggle-main-window", false)
end

fs_util.add_handlers(handlers)

---@diagnostic disable: missing-fields
---@type flib.GuiElemDef
return {
    type = "frame",
    name = "factory_solver_main_window",
    style = "factory_solver_main_window",
    direction = "vertical",
    handler = {
        [defines.events.on_gui_closed] = common.on_close_self,
        on_added = handlers.on_main_window_added,
        on_close = handlers.on_main_window_close,
    },
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = "factory_solver_main_window",
        },
        handler = {
            on_added = common.on_init_drag_target
        },
        {
            type = "label",
            style = "frame_title",
            caption = { "factory_solver_title" },
            ignored_by_interaction = true,
        },
        {
            type = "empty-widget",
            style = "flib_titlebar_drag_handle",
            ignored_by_interaction = true,
        },
        {
            type = "sprite-button",
            style = "frame_action_button",
            sprite = "utility/close",
            hovered_sprite = "utility/close_black",
            clicked_sprite = "utility/close_black",
            tags = {
                close_target = "factory_solver_main_window",
            },
            handler = {
                [defines.events.on_gui_click] = common.on_close_target
            },
        },
    },
    {
        type = "flow",
        style = "factory_solver_contents",
        {
            type = "flow",
            name = "left_panel",
            style = "factory_solver_left_panel",
            direction = "vertical",
            solution_selector,
            common_settings,
        },
        solution_editor,
        {
            type = "flow",
            name = "right_panel",
            style = "factory_solver_right_panel",
            direction = "vertical",
            solution_settings,
            solution_results,
        },
    },
}
