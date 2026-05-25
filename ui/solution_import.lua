local fs_util = require "fs_util"
local save = require "manage/save"
local solution_codec = require "manage/solution_codec"
local factoryplanner_codec = require "manage/factoryplanner_codec"
local common = require "ui/common"

local handlers = {}

---@param event EventDataTrait
function handlers.on_init_import_textbox(event)
    event.element.focus()
end

---@param event EventData.on_gui_text_changed
function handlers.on_import_textbox_changed(event)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_solution_import"))
    local error_label = fs_util.find_lower(dialog, "factory_solver_solution_import_error")
    if error_label then
        error_label.visible = false
        error_label.caption = ""
    end
end

---Try factory_solver's native codec first (cheap signature check). On
---failure, decode the string again and probe for FP's `export_modset` /
---`factories` shape. Returns a list of payloads to import (1 for native,
---N for FP factories), an aggregated warning list, or an error.
---@param s string
---@return table[]?
---@return LocalisedString[]
---@return LocalisedString?
local function decode_any(s)
    local payload, err = solution_codec.decode(s)
    if payload then
        return { payload }, {}, nil
    end

    local export_table, fp_err = factoryplanner_codec.decode(s)
    if export_table then
        local payloads = {}
        local warnings = {}
        for _, packed_factory in ipairs(export_table.factories) do
            local fp_payload, fp_warnings = factoryplanner_codec.factory_to_payload(packed_factory)
            payloads[#payloads + 1] = fp_payload
            for _, w in ipairs(fp_warnings) do warnings[#warnings + 1] = w end
        end
        if #payloads == 0 then
            return nil, {}, { "factory-solver-import-error-structure" }
        end
        return payloads, warnings, nil
    end

    return nil, {}, err or fp_err
end

---@param event EventDataTrait
function handlers.on_import_confirm(event)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_solution_import"))
    local textbox = assert(fs_util.find_lower(dialog, "factory_solver_solution_import_textbox"))
    local error_label = assert(fs_util.find_lower(dialog, "factory_solver_solution_import_error"))

    local payloads, warnings, err = decode_any(textbox.text)
    if not payloads then
        error_label.caption = err or ""
        error_label.visible = true
        return
    end

    local player_data = save.get_player_data(event.player_index)
    local solutions = save.get_solutions(event.player_index)
    local imported_name = save.import_solutions(solutions, payloads)
    if imported_name then
        player_data.selected_solution = imported_name
    end

    local player = game.players[event.player_index]
    if player then
        for _, w in ipairs(warnings) do player.print(w) end
    end

    local window = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(window, "on_files_changed")
    fs_util.dispatch_to_subtree(window, "on_selected_solution_changed")

    local re_event = fs_util.create_gui_event(dialog)
    common.on_close_self(re_event)
end

fs_util.add_handlers(handlers)

---@type fs.GuiElemDef
return {
    type = "frame",
    name = "factory_solver_solution_import",
    direction = "vertical",
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = "factory_solver_solution_import",
        },
        handler = {
            on_added = common.on_init_drag_target
        },
        {
            type = "label",
            style = "frame_title",
            caption = { "factory-solver-import-solution" },
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
            name = "factory_solver_solution_import_textbox",
            elem_mods = {
                word_wrap = true,
            },
            style_mods = {
                width = 480,
                height = 140,
            },
            handler = {
                on_added = handlers.on_init_import_textbox,
                [defines.events.on_gui_text_changed] = handlers.on_import_textbox_changed,
            },
        },
        {
            type = "label",
            name = "factory_solver_solution_import_error",
            style = "bold_red_label",
            caption = "",
            visible = false,
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
                close_target = "factory_solver_solution_import",
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
            caption = { "factory-solver-import" },
            handler = {
                [defines.events.on_gui_click] = handlers.on_import_confirm
            },
        },
    },
}
