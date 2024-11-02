local fs_util = require "fs_util"
local save = require "manage/save"
local common = require "ui/common"

local handlers = {}

---@param event EventDataTrait
function handlers.on_init_rename_textfield(event)
    local elem = event.element
    local solution = assert(save.get_selected_solution(event.player_index))
    local dialog = assert(fs_util.find_upper(event.element, "rename_solution"))

    elem.text = solution.name
    dialog.tags = { solution_name = solution.name, new_solution_name = solution.name }
end

---@param event EventData.on_gui_text_changed
function handlers.on_rename_textfield_changed(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "rename_solution"))

    local dialog_tags = dialog.tags
    dialog_tags.new_solution_name = elem.text
    dialog.tags = dialog_tags
end

---@param event EventData.on_gui_click
function handlers.on_rename_confirm(event)
    local player_data = save.get_player_data(event.player_index)
    local solutions = save.get_solutions(event.player_index)
    local dialog = assert(fs_util.find_upper(event.element, "rename_solution"))

    local solution_name = dialog.tags.solution_name --[[@as string]]
    local new_solution_name = dialog.tags.new_solution_name --[[@as string]]
    new_solution_name = save.rename_solution(solutions, solution_name, new_solution_name)
    player_data.selected_solution = new_solution_name
    
    local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_files_changed")
    
    local re_event = fs_util.create_gui_event(dialog)
    common.on_close_self(re_event)
end

fs_util.add_handlers(handlers)

---@diagnostic disable: missing-fields
---@type flib.GuiElemDef
return {
    type = "frame",
    name = "rename_solution",
    direction = "vertical",
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = "rename_solution",
        },
        handler = {
            on_added = common.on_init_drag_target
        },
        {
            type = "label",
            style = "frame_title",
            caption = "Rename solution",
            ignored_by_interaction = true,
        },
        {
            type = "empty-widget",
            style = "flib_titlebar_drag_handle",
            ignored_by_interaction = true,
        }
    },
    {
        type = "frame",
        style = "inside_shallow_frame_with_padding",
        direction = "vertical",
        {
            type = "textfield",
            name = "rename_textfield",
            style = "factory_solver_rename_textfield",
            clear_and_focus_on_right_click = true,
            handler = {
                on_added = handlers.on_init_rename_textfield,
                [defines.events.on_gui_text_changed] = handlers.on_rename_textfield_changed,
                [defines.events.on_gui_confirmed] = handlers.on_rename_confirm,
            }
        },
    },
    {
        type = "flow",
        name = "dialog_buttons",
        {
            type = "button",
            style = "back_button",
            caption = { "gui.cancel" },
            tags = {
                close_target = "rename_solution",
            },
            handler = {
                [defines.events.on_gui_click] = common.on_close_target
            },
        },
        {
            type = "empty-widget",
            style = "flib_dialog_footer_drag_handle",
            ignored_by_interaction = true,
        },
        {
            type = "button",
            style = "confirm_button",
            caption = { "gui.confirm" },
            handler = {
                [defines.events.on_gui_click] = handlers.on_rename_confirm
            },
        },
    },
}
