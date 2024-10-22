local flib_table = require "__flib__/table"

local fs_util = require "fs_util"
local common = require "ui/common"
local machine_presets = require "ui/machine_presets"
local info = require "manage/info"
local save = require "manage/save"

local time_scale_to_index = {
    ["second"] = 1,
    ["minute"] = 2,
    ["hour"] = 3,
}

local handlers = {}

---@param event EventDataTrait
function handlers.on_time_scale_dropdown_added(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local limit_index = time_scale_to_index[player_data.time_scale]
    elem.selected_index = limit_index
end

---@param event EventData.on_gui_selection_state_changed
function handlers.on_time_scale_selection_state_changed(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local time_scale = flib_table.find(time_scale_to_index, elem.selected_index)
    player_data.time_scale = time_scale

    local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_amount_unit_changed", data)
end

---@param event EventData.on_gui_click
function handlers.on_open_machine_preset_dialog_button_click(event)
    common.open_gui(event.player_index, true, machine_presets)
end

fs_util.add_handlers(handlers)

---@diagnostic disable: missing-fields
---@type flib.GuiElemDef
return {
    type = "frame",
    name = "common_settings",
    style = "inside_shallow_frame_with_padding",
    direction = "vertical",
    {
        type = "label",
        style = "caption_label",
        caption = "Time scale",
    },
    {
        type = "drop-down",
        items = {
            "Second",
            "Minute",
            "Hour",
        },
        handler = {
            [defines.events.on_gui_selection_state_changed] = handlers.on_time_scale_selection_state_changed,
            on_added = handlers.on_time_scale_dropdown_added,
        }
    },
    {
        type = "line",
        style = "factory_solver_line",
    },
    {
        type = "button",
        caption = "Machine presets",
        handler = {
            [defines.events.on_gui_click] = handlers.on_open_machine_preset_dialog_button_click,
        },
    },
}