local fs_util = require "fs_util"
local save = require "manage/save"
local solution_codec = require "manage/solution_codec"
local factoryplanner_codec = require "manage/factoryplanner_codec"
local helmod_codec = require "manage/helmod_codec"
local common = require "ui/common"

local DIALOG_NAME = "factory_solver_solution_import"

local handlers = {}

---@param event EventDataTrait
function handlers.on_init_import_textbox(event)
    event.element.focus()
end

---Try factory_solver's native codec first (cheap signature check). On
---failure, decode the string again and probe for FP's `export_modset` /
---`factories` shape, then Helmod's `class="Model"` shape. Returns a list
---of payloads (one per native solution, FP factory, or — at most — one
---Helmod model), an aggregated warning list, or an error.
---@param s string
---@param player_index integer
---@return table[]?
---@return LocalisedString[]
---@return LocalisedString?
local function decode_any(s, player_index)
    local payloads, err = solution_codec.decode(s)
    if payloads then
        return payloads, {}, nil
    end

    local export_table, fp_err = factoryplanner_codec.decode(s)
    if export_table then
        local fp_payloads = {}
        local warnings = {}
        for _, packed_factory in ipairs(export_table.factories) do
            local fp_payload, fp_warnings = factoryplanner_codec.factory_to_payload(
                packed_factory, player_index)
            fp_payloads[#fp_payloads + 1] = fp_payload
            for _, w in ipairs(fp_warnings) do warnings[#warnings + 1] = w end
        end
        if #fp_payloads == 0 then
            return nil, {}, { "factory-solver-import-error-structure" }
        end
        return fp_payloads, warnings, nil
    end

    local helmod_model, helmod_err = helmod_codec.decode(s)
    if helmod_model then
        local helmod_payload, helmod_warnings = helmod_codec.model_to_payload(helmod_model, player_index)
        return { helmod_payload }, helmod_warnings, nil
    end

    return nil, {}, err or fp_err or helmod_err
end

---Compute the rename a given payload name would get if imported on top of
---the supplied `taken` set, matching `save.import_solution`'s collision
---rule. Marks the chosen name as taken before returning so sequential calls
---see the running effect (i.e. two payloads named "X" become "X" / "X 1").
---@param base string
---@param taken table<string, boolean>
---@return string
local function resolve_rename(base, taken)
    local name = base
    local i = 1
    while taken[name] do
        name = string.format("%s %i", base, i)
        i = i + 1
    end
    taken[name] = true
    return name
end

---Sync the "select all" master checkbox to reflect whether every row is
---checked. Programmatic state writes do not fire the checked event, so this
---is safe to call from inside a row-change handler.
---@param dialog LuaGuiElement
local function sync_select_all(dialog)
    local list = assert(fs_util.find_lower(dialog, "factory_solver_solution_import_list"))
    local master = assert(fs_util.find_lower(dialog, "factory_solver_solution_import_select_all"))
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

---Redraw each row's caption so the rename suffix reflects the current set of
---checked payloads. Walks in list order: an unchecked row reserves nothing,
---a checked row claims either its native name or the next free suffix.
---@param dialog LuaGuiElement
---@param player_index integer
local function refresh_list_captions(dialog, player_index)
    local list = assert(fs_util.find_lower(dialog, "factory_solver_solution_import_list"))
    local payloads = dialog.tags.payloads --[[@as table[]?]]
    if not payloads then return end

    local taken = {}
    for name in pairs(save.get_solutions(player_index)) do
        taken[name] = true
    end

    for _, child in ipairs(list.children) do
        if child.type == "checkbox" then
            local index = child.tags.payload_index --[[@as integer]]
            local payload = payloads[index]
            local base = payload.name
            if child.state then
                local resolved = resolve_rename(base, taken)
                if resolved == base then
                    child.caption = base
                else
                    child.caption = { "", base, " → ", resolved }
                end
            else
                child.caption = base
            end
        end
    end
end

---Wipe and rebuild the list with one checkbox per decoded payload, all
---checked by default. Stores the payload list on dialog.tags so the confirm
---handler can pull the originals back without re-decoding.
---@param dialog LuaGuiElement
---@param payloads table[]
local function populate_list(dialog, payloads)
    local list = assert(fs_util.find_lower(dialog, "factory_solver_solution_import_list"))
    list.clear()

    local tags = dialog.tags
    tags.payloads = payloads
    dialog.tags = tags

    for i, payload in ipairs(payloads) do
        fs_util.add_gui(list, {
            type = "checkbox",
            state = true,
            caption = payload.name,
            tags = { payload_index = i },
            handler = {
                [defines.events.on_gui_checked_state_changed] = handlers.on_payload_checked,
            },
        })
    end

    refresh_list_captions(dialog, dialog.player_index)
    sync_select_all(dialog)
end

---@param dialog LuaGuiElement
local function clear_list(dialog)
    local list = assert(fs_util.find_lower(dialog, "factory_solver_solution_import_list"))
    list.clear()
    local tags = dialog.tags
    tags.payloads = nil
    dialog.tags = tags
    sync_select_all(dialog)
end

---@param event EventData.on_gui_text_changed
function handlers.on_import_textbox_changed(event)
    local dialog = assert(fs_util.find_upper(event.element, DIALOG_NAME))
    local error_label = assert(fs_util.find_lower(dialog, "factory_solver_solution_import_error"))
    local empty_label = assert(fs_util.find_lower(dialog, "factory_solver_solution_import_empty"))
    local select_all_checkbox = assert(fs_util.find_lower(dialog, "factory_solver_solution_import_select_all"))

    error_label.visible = false
    error_label.caption = ""

    local text = event.element.text
    if text == "" then
        clear_list(dialog)
        empty_label.visible = true
        select_all_checkbox.visible = false
        return
    end

    local payloads, _warnings, err = decode_any(text, event.player_index)
    if not payloads then
        clear_list(dialog)
        empty_label.visible = false
        select_all_checkbox.visible = false
        error_label.caption = err or { "factory-solver-import-error-structure" }
        error_label.visible = true
        return
    end

    empty_label.visible = false
    select_all_checkbox.visible = true
    populate_list(dialog, payloads)
end

---@param event EventData.on_gui_checked_state_changed
function handlers.on_payload_checked(event)
    local dialog = assert(fs_util.find_upper(event.element, DIALOG_NAME))
    refresh_list_captions(dialog, event.player_index)
    sync_select_all(dialog)
end

---@param event EventData.on_gui_checked_state_changed
function handlers.on_select_all_import(event)
    local dialog = assert(fs_util.find_upper(event.element, DIALOG_NAME))
    local list = assert(fs_util.find_lower(dialog, "factory_solver_solution_import_list"))
    local new_state = event.element.state
    for _, child in ipairs(list.children) do
        if child.type == "checkbox" then
            child.state = new_state
        end
    end
    refresh_list_captions(dialog, event.player_index)
end

---@param event EventDataTrait
function handlers.on_import_confirm(event)
    local dialog = assert(fs_util.find_upper(event.element, DIALOG_NAME))
    local textbox = assert(fs_util.find_lower(dialog, "factory_solver_solution_import_textbox"))
    local error_label = assert(fs_util.find_lower(dialog, "factory_solver_solution_import_error"))
    local list = assert(fs_util.find_lower(dialog, "factory_solver_solution_import_list"))

    local payloads, warnings, err = decode_any(textbox.text, event.player_index)
    if not payloads then
        error_label.caption = err or { "factory-solver-import-error-structure" }
        error_label.visible = true
        return
    end

    local filtered = {}
    for _, child in ipairs(list.children) do
        if child.type == "checkbox" and child.state then
            local index = child.tags.payload_index --[[@as integer]]
            filtered[#filtered + 1] = payloads[index]
        end
    end

    if #filtered == 0 then
        error_label.caption = { "factory-solver-import-no-selection" }
        error_label.visible = true
        return
    end

    local player_data = save.get_player_data(event.player_index)
    local solutions = save.get_solutions(event.player_index)
    local imported_name = save.import_solutions(solutions, filtered)
    if imported_name then
        player_data.selected_solution = imported_name
    end

    local player = game.players[event.player_index]
    if player then
        for _, w in ipairs(warnings) do player.print(w) end
    end

    local window = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(window, "on_files_changed")
    common.broadcast(event.player_index, "on_selected_solution_changed")

    local re_event = fs_util.create_gui_event(dialog)
    common.on_close_self(re_event)
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
        {
            type = "flow",
            direction = "vertical",
            {
                type = "text-box",
                name = "factory_solver_solution_import_textbox",
                elem_mods = {
                    word_wrap = true,
                },
                style_mods = {
                    width = 640,
                    height = 360,
                },
                handler = {
                    on_added = handlers.on_init_import_textbox,
                    [defines.events.on_gui_text_changed] = handlers.on_import_textbox_changed,
                },
            },
            {
                type = "line",
                style = "factory_solver_line",
            },
            {
                type = "checkbox",
                name = "factory_solver_solution_import_select_all",
                state = false,
                caption = { "factory-solver-import-choose-factories" },
                visible = false,
                handler = {
                    [defines.events.on_gui_checked_state_changed] = handlers.on_select_all_import,
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
                    name = "factory_solver_solution_import_list",
                    direction = "vertical",
                },
            },
            {
                type = "label",
                name = "factory_solver_solution_import_empty",
                caption = { "factory-solver-import-empty-hint" },
                visible = true,
            },
            {
                type = "label",
                name = "factory_solver_solution_import_error",
                style = "bold_red_label",
                caption = "",
                visible = false,
            },
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
                close_target = DIALOG_NAME,
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
