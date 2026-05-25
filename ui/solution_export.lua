local fs_util = require "fs_util"
local save = require "manage/save"
local solution_codec = require "manage/solution_codec"
local factoryplanner_codec = require "manage/factoryplanner_codec"
local common = require "ui/common"

local handlers = {}

---Regenerate the export textbox from the currently selected radiobutton.
---Native factory_solver string is the default; FP form is opt-in.
---@param dialog LuaGuiElement
---@param player_index integer
local function refresh_export_textbox(dialog, player_index)
    local textbox = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_textbox"))
    local fp_radio = fs_util.find_lower(dialog, "factory_solver_solution_export_format_fp")
    local solution = assert(save.get_selected_solution(player_index))

    if fp_radio and fp_radio.state then
        local s, warnings = factoryplanner_codec.encode(solution)
        textbox.text = s
        local player = game.players[player_index]
        if player then
            for _, w in ipairs(warnings) do player.print(w) end
        end
    else
        textbox.text = solution_codec.encode(solution)
    end
    textbox.focus()
    textbox.select_all()
end

---@param event EventDataTrait
function handlers.on_init_export_textbox(event)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_solution_export"))
    refresh_export_textbox(dialog, event.player_index)
end

---@param event EventData.on_gui_checked_state_changed
function handlers.on_format_selected_native(event)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_solution_export"))
    local fp_radio = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_format_fp"))
    event.element.state = true
    fp_radio.state = false
    refresh_export_textbox(dialog, event.player_index)
end

---@param event EventData.on_gui_checked_state_changed
function handlers.on_format_selected_fp(event)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_solution_export"))
    local native_radio = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_format_native"))
    event.element.state = true
    native_radio.state = false
    refresh_export_textbox(dialog, event.player_index)
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
            type = "flow",
            direction = "horizontal",
            {
                type = "radiobutton",
                name = "factory_solver_solution_export_format_native",
                caption = { "factory-solver-export-format-native" },
                state = true,
                handler = {
                    [defines.events.on_gui_checked_state_changed] = handlers.on_format_selected_native,
                },
            },
            {
                type = "radiobutton",
                name = "factory_solver_solution_export_format_fp",
                caption = { "factory-solver-export-format-factoryplanner" },
                state = false,
                handler = {
                    [defines.events.on_gui_checked_state_changed] = handlers.on_format_selected_fp,
                },
            },
        },
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
