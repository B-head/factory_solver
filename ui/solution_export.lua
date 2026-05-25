local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local save = require "manage/save"
local solution_codec = require "manage/solution_codec"
local factoryplanner_codec = require "manage/factoryplanner_codec"
local common = require "ui/common"

local DIALOG_NAME = "factory_solver_solution_export"

local handlers = {}

---@param player_index integer
---@return string[]
local function sorted_solution_names(player_index)
    local names = flib_table.map(
        fs_util.to_list(save.get_solutions(player_index)),
        function(value) return value.name end)
    flib_table.sort(names)
    return names
end

---Walk the checkbox list inside the dialog and collect the Solutions whose
---row is checked, in list order.
---@param dialog LuaGuiElement
---@param player_index integer
---@return Solution[]
local function gather_selected_solutions(dialog, player_index)
    local list = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_list"))
    local solutions = save.get_solutions(player_index)
    local selected = {}
    for _, child in ipairs(list.children) do
        if child.type == "checkbox" and child.state then
            local name = child.tags.solution_name --[[@as string?]]
            local solution = name and solutions[name]
            if solution then
                selected[#selected + 1] = solution
            end
        end
    end
    return selected
end

---Sync the "select all" master checkbox to reflect whether every row is
---checked. Programmatic state writes do not fire the checked event, so this
---is safe to call from inside a row-change handler.
---@param dialog LuaGuiElement
local function sync_select_all(dialog)
    local list = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_list"))
    local master = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_select_all"))
    local all_checked = true
    local any = false
    for _, child in ipairs(list.children) do
        if child.type == "checkbox" then
            any = true
            if not child.state then
                all_checked = false
                break
            end
        end
    end
    master.state = any and all_checked
end

---Regenerate the export textbox from the currently checked solutions.
---Native factory_solver string is the default; FP form is opt-in.
---@param dialog LuaGuiElement
---@param player_index integer
local function refresh_export_textbox(dialog, player_index)
    local textbox = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_textbox"))
    local empty_label = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_empty"))
    local fp_radio = fs_util.find_lower(dialog, "factory_solver_solution_export_format_fp")

    local selected = gather_selected_solutions(dialog, player_index)
    if #selected == 0 then
        textbox.text = ""
        empty_label.visible = true
        return
    end
    empty_label.visible = false

    if fp_radio and fp_radio.state then
        local s, warnings = factoryplanner_codec.encode(selected)
        textbox.text = s
        local player = game.players[player_index]
        if player then
            for _, w in ipairs(warnings) do player.print(w) end
        end
    else
        textbox.text = solution_codec.encode(selected)
    end
    textbox.focus()
    textbox.select_all()
end

---@param event EventDataTrait
function handlers.on_export_list_added(event)
    local list = event.element
    local player_data = save.get_player_data(event.player_index)
    local selected_name = player_data.selected_solution

    for _, name in ipairs(sorted_solution_names(event.player_index)) do
        fs_util.add_gui(list, {
            type = "checkbox",
            state = name == selected_name,
            caption = name,
            tags = { solution_name = name },
            handler = {
                [defines.events.on_gui_checked_state_changed] = handlers.on_solution_checked,
            },
        })
    end

    local dialog = assert(fs_util.find_upper(list, DIALOG_NAME))
    sync_select_all(dialog)
end

---@param event EventData.on_gui_checked_state_changed
function handlers.on_solution_checked(event)
    local dialog = assert(fs_util.find_upper(event.element, DIALOG_NAME))
    sync_select_all(dialog)
    refresh_export_textbox(dialog, event.player_index)
end

---@param event EventData.on_gui_checked_state_changed
function handlers.on_select_all_export(event)
    local dialog = assert(fs_util.find_upper(event.element, DIALOG_NAME))
    local list = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_list"))
    local new_state = event.element.state
    for _, child in ipairs(list.children) do
        if child.type == "checkbox" then
            child.state = new_state
        end
    end
    refresh_export_textbox(dialog, event.player_index)
end

---@param event EventDataTrait
function handlers.on_init_export_textbox(event)
    local dialog = assert(fs_util.find_upper(event.element, DIALOG_NAME))
    refresh_export_textbox(dialog, event.player_index)
end

---@param event EventData.on_gui_checked_state_changed
function handlers.on_format_selected_native(event)
    local dialog = assert(fs_util.find_upper(event.element, DIALOG_NAME))
    local fp_radio = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_format_fp"))
    event.element.state = true
    fp_radio.state = false
    refresh_export_textbox(dialog, event.player_index)
end

---@param event EventData.on_gui_checked_state_changed
function handlers.on_format_selected_fp(event)
    local dialog = assert(fs_util.find_upper(event.element, DIALOG_NAME))
    local native_radio = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_format_native"))
    event.element.state = true
    native_radio.state = false
    refresh_export_textbox(dialog, event.player_index)
end

fs_util.add_handlers(handlers)

---@type fs.GuiElemDef
return {
    type = "frame",
    name = DIALOG_NAME,
    direction = "vertical",
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = DIALOG_NAME,
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
            type = "checkbox",
            name = "factory_solver_solution_export_select_all",
            state = false,
            caption = { "factory-solver-export-choose-factories" },
            handler = {
                [defines.events.on_gui_checked_state_changed] = handlers.on_select_all_export,
            },
        },
        {
            type = "scroll-pane",
            style_mods = {
                width = 480,
                maximal_height = 200,
            },
            {
                type = "flow",
                name = "factory_solver_solution_export_list",
                direction = "vertical",
                handler = {
                    on_added = handlers.on_export_list_added,
                },
            },
        },
        {
            type = "label",
            name = "factory_solver_solution_export_empty",
            style = "bold_red_label",
            caption = { "factory-solver-export-no-selection" },
            visible = false,
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
                close_target = DIALOG_NAME,
            },
            handler = {
                [defines.events.on_gui_click] = common.on_close_target
            },
        },
    },
}
