local flib_table = require "__flib__/table"

local fs_util = require "fs_util"
local save = require "manage/save"
local common = require "ui/common"
local constraint_adder = require "ui/constraint_adder"
local rename_solution = require "ui/rename_solution"

local handlers = {}

---@param event EventDataTrait
function handlers.on_selector_tool_enabled(event)
    local elem = event.element
    local solution = save.get_selected_solution(event.player_index)

    elem.enabled = solution ~= nil
end

---@param event EventData.on_gui_click
function handlers.on_new_solution(event)
    local player_data = save.get_player_data(event.player_index)
    local solutions = save.get_solutions(event.player_index)
    
    player_data.selected_solution = save.new_solution(solutions)

    local root = assert(fs_util.find_upper(event.element, "solution_selector"))
    fs_util.dispatch_to_subtree(root, "on_files_changed")

    local window = assert(fs_util.find_upper(event.element, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(window, "on_selected_solution_changed")

    common.open_gui(event.player_index, true, constraint_adder)
end

---@param event EventData.on_gui_click
function handlers.on_rename_solution(event)
    common.open_gui(event.player_index, true, rename_solution)
end

---@param event EventData.on_gui_click
function handlers.on_delete_solution(event)
    local player_data = save.get_player_data(event.player_index)
    local solutions = save.get_solutions(event.player_index)

    save.delete_solution(solutions, player_data.selected_solution)

    local root = assert(fs_util.find_upper(event.element, "solution_selector"))
    fs_util.dispatch_to_subtree(root, "on_files_changed")

    local window = assert(fs_util.find_upper(event.element, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(window, "on_selected_solution_changed")
end

---@param event EventData.on_gui_selection_state_changed
function handlers.on_selector_state_changed(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local name = elem.items[elem.selected_index] --[[@as string?]]
    player_data.selected_solution = name or ""

    local root = assert(fs_util.find_upper(event.element, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_selected_solution_changed")
end

---@param event EventDataTrait
function handlers.on_make_solution_list(event)
    local player_data = save.get_player_data(event.player_index)
    local solutions = save.get_solutions(event.player_index)
    local names = fs_util.to_list(solutions)

    names = flib_table.map(names, function(value)
        return value.name
    end)
    flib_table.sort(names)

    event.element.items = names
    event.element.selected_index = flib_table.find(names, player_data.selected_solution) or 0
end

fs_util.add_handlers(handlers)

---@diagnostic disable: missing-fields
---@type flib.GuiElemDef
return {
    type = "frame",
    name = "solution_selector",
    style = "inside_shallow_frame",
    direction = "vertical",
    {
        type = "frame",
        name = "solution_control",
        style = "subheader_frame",
        {
            type = "sprite-button",
            style = "tool_button_blue",
            sprite = "utility/add",
            handler = {
                [defines.events.on_gui_click] = handlers.on_new_solution,
            },
        },
        {
            type = "sprite-button",
            style = "tool_button",
            sprite = "utility/rename_icon",
            handler = {
                [defines.events.on_gui_click] = handlers.on_rename_solution,
                on_added = handlers.on_selector_tool_enabled,
                on_selected_solution_changed = handlers.on_selector_tool_enabled,
            },
        },
        {
            type = "empty-widget",
            style = "flib_horizontal_pusher",
        },
        {
            type = "sprite-button",
            style = "tool_button_red",
            sprite = "utility/trash",
            handler = {
                [defines.events.on_gui_click] = handlers.on_delete_solution,
                on_added = handlers.on_selector_tool_enabled,
                on_selected_solution_changed = handlers.on_selector_tool_enabled,
            },
        },
    },
    {
        type = "list-box",
        style = "factory_solver_solution_list",
        handler = {
            [defines.events.on_gui_selection_state_changed] = handlers.on_selector_state_changed,
            on_added = handlers.on_make_solution_list,
            on_files_changed = handlers.on_make_solution_list,
        }
    }
}
