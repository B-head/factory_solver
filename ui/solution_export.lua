local fs_util = require "fs_util"
local save = require "manage/save"
local solution_codec = require "manage/solution_codec"
local common = require "ui/common"

local handlers = {}

---@param event EventDataTrait
function handlers.on_init_export_textbox(event)
    local solution = assert(save.get_selected_solution(event.player_index))
    event.element.text = solution_codec.encode(solution)
    event.element.focus()
    event.element.select_all()
end

fs_util.add_handlers(handlers)

---@type fs.GuiElemDef
return {
    type = "frame",
    name = "factory_solver_solution_export",
    direction = "vertical",
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = "factory_solver_solution_export",
        },
        handler = {
            on_added = common.on_init_drag_target
        },
        {
            type = "label",
            style = "frame_title",
            caption = { "factory-solver-export-solution" },
            ignored_by_interaction = true,
        },
        {
            type = "empty-widget",
            style = "flib_titlebar_drag_handle",
            ignored_by_interaction = true,
        },
    },
    {
        type = "frame",
        style = "inside_shallow_frame_with_padding",
        direction = "vertical",
        {
            type = "text-box",
            name = "factory_solver_solution_export_textbox",
            elem_mods = {
                read_only = true,
                word_wrap = true,
            },
            style_mods = {
                width = 480,
                height = 140,
            },
            handler = {
                on_added = handlers.on_init_export_textbox,
            },
        },
    },
    {
        type = "flow",
        name = "dialog_buttons",
        {
            type = "empty-widget",
            style = "flib_dialog_footer_drag_handle",
            ignored_by_interaction = true,
        },
        {
            type = "button",
            style = "confirm_button",
            caption = { "gui.close" },
            tags = {
                close_target = "factory_solver_solution_export",
            },
            handler = {
                [defines.events.on_gui_click] = common.on_close_target
            },
        },
    },
}
