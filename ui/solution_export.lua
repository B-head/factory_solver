local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local save = require "manage/save"
local solution_codec = require "manage/solution_codec"
local factoryplanner_codec = require "manage/factoryplanner_codec"
local helmod_codec = require "manage/helmod_codec"
local yafc_codec = require "manage/yafc_codec"
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

---Resolve which format radio is currently selected. Returns one of
---"native" / "fp" / "helmod" / "yafc". Falls back to "native" when none can be
---found (defensive; the dialog always has the radios).
---@param dialog LuaGuiElement
---@return "native"|"fp"|"helmod"|"yafc"
local function selected_format(dialog)
    local fp_radio = fs_util.find_lower(dialog, "factory_solver_solution_export_format_fp")
    if fp_radio and fp_radio.state then return "fp" end
    local helmod_radio = fs_util.find_lower(dialog, "factory_solver_solution_export_format_helmod")
    if helmod_radio and helmod_radio.state then return "helmod" end
    local yafc_radio = fs_util.find_lower(dialog, "factory_solver_solution_export_format_yafc")
    if yafc_radio and yafc_radio.state then return "yafc" end
    return "native"
end

---Helmod and YAFC share-string formats each carry a single factory, so their
---selection collapses to one checked row. Native / FP keep multi-select.
---@param dialog LuaGuiElement
---@return boolean
local function is_single_page_format(dialog)
    local format = selected_format(dialog)
    return format == "helmod" or format == "yafc"
end

---Regenerate the export textbox from the currently checked solutions.
---Dispatches to the codec matching the active format radio.
---@param dialog LuaGuiElement
---@param player_index integer
local function refresh_export_textbox(dialog, player_index)
    local textbox = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_textbox"))
    local empty_label = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_empty"))

    local selected = gather_selected_solutions(dialog, player_index)
    if #selected == 0 then
        textbox.text = ""
        empty_label.visible = true
        return
    end
    empty_label.visible = false

    local format = selected_format(dialog)
    if format == "fp" then
        local s, warnings = factoryplanner_codec.encode(selected)
        textbox.text = s
        local player = game.players[player_index]
        if player then
            for _, w in ipairs(warnings) do player.print(w) end
        end
    elseif format == "helmod" then
        local s, warnings = helmod_codec.encode(selected)
        textbox.text = s
        local player = game.players[player_index]
        if player then
            for _, w in ipairs(warnings) do player.print(w) end
        end
    elseif format == "yafc" then
        local s, warnings = yafc_codec.encode(selected)
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

---Helmod / YAFC shared strings only carry a single factory, so when one of
---those formats is active we collapse the selection to the first checked row.
---The user can still un-check it and pick a different one; we don't disable the
---boxes outright because that hides the choice.
---@param dialog LuaGuiElement
local function enforce_single_selection(dialog)
    if not is_single_page_format(dialog) then return end
    local list = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_list"))
    local seen_first = false
    for _, child in ipairs(list.children) do
        if child.type == "checkbox" and child.state then
            if seen_first then
                child.state = false
            else
                seen_first = true
            end
        end
    end
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
    -- When a single-page format (Helmod / YAFC) is active, a freshly-checked
    -- row must displace any previously-checked one. The new row stays checked
    -- because the event already wrote its `state = true`; we walk the list and
    -- clear earlier hits.
    if event.element.state and is_single_page_format(dialog) then
        local list = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_list"))
        for _, child in ipairs(list.children) do
            if child ~= event.element and child.type == "checkbox" then
                child.state = false
            end
        end
    end
    sync_select_all(dialog)
    refresh_export_textbox(dialog, event.player_index)
end

---@param event EventData.on_gui_checked_state_changed
function handlers.on_select_all_export(event)
    local dialog = assert(fs_util.find_upper(event.element, DIALOG_NAME))
    local list = assert(fs_util.find_lower(dialog, "factory_solver_solution_export_list"))
    local new_state = event.element.state
    -- Helmod / YAFC can only ship one factory per string, so "select all" must
    -- not check more than one box; instead, treat it as "check the first" (or
    -- "clear all" when toggling off). For native / FP we keep the normal
    -- multi-select semantics.
    local single_page = is_single_page_format(dialog)
    local seen_first = false
    for _, child in ipairs(list.children) do
        if child.type == "checkbox" then
            if single_page then
                if new_state and not seen_first then
                    child.state = true
                    seen_first = true
                else
                    child.state = false
                end
            else
                child.state = new_state
            end
        end
    end
    refresh_export_textbox(dialog, event.player_index)
end

---@param event EventDataTrait
function handlers.on_init_export_textbox(event)
    local dialog = assert(fs_util.find_upper(event.element, DIALOG_NAME))
    refresh_export_textbox(dialog, event.player_index)
end

---Mark `event.element` (one of the format radios) as the selected one and
---clear the others. Bundles the post-selection refresh so each radio
---handler stays a one-liner.
---@param dialog LuaGuiElement
---@param chosen LuaGuiElement
local function select_format_radio(dialog, chosen)
    local names = {
        "factory_solver_solution_export_format_native",
        "factory_solver_solution_export_format_fp",
        "factory_solver_solution_export_format_helmod",
        "factory_solver_solution_export_format_yafc",
    }
    for _, name in ipairs(names) do
        local radio = fs_util.find_lower(dialog, name)
        if radio then radio.state = (radio == chosen) end
    end
end

---@param event EventData.on_gui_checked_state_changed
function handlers.on_format_selected_native(event)
    local dialog = assert(fs_util.find_upper(event.element, DIALOG_NAME))
    select_format_radio(dialog, event.element)
    refresh_export_textbox(dialog, event.player_index)
end

---@param event EventData.on_gui_checked_state_changed
function handlers.on_format_selected_fp(event)
    local dialog = assert(fs_util.find_upper(event.element, DIALOG_NAME))
    select_format_radio(dialog, event.element)
    refresh_export_textbox(dialog, event.player_index)
end

---@param event EventData.on_gui_checked_state_changed
function handlers.on_format_selected_helmod(event)
    local dialog = assert(fs_util.find_upper(event.element, DIALOG_NAME))
    select_format_radio(dialog, event.element)
    -- Switching INTO Helmod collapses any multi-selection down to one
    -- (otherwise the textbox would silently drop everything past the
    -- first checked row). Refresh comes after so the textbox reflects
    -- exactly what's still checked.
    enforce_single_selection(dialog)
    sync_select_all(dialog)
    refresh_export_textbox(dialog, event.player_index)
end

---@param event EventData.on_gui_checked_state_changed
function handlers.on_format_selected_yafc(event)
    local dialog = assert(fs_util.find_upper(event.element, DIALOG_NAME))
    select_format_radio(dialog, event.element)
    -- YAFC is single-page like Helmod; collapse the selection the same way.
    enforce_single_selection(dialog)
    sync_select_all(dialog)
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
        {
            type = "flow",
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
                {
                    type = "radiobutton",
                    name = "factory_solver_solution_export_format_helmod",
                    caption = { "factory-solver-export-format-helmod" },
                    state = false,
                    handler = {
                        [defines.events.on_gui_checked_state_changed] = handlers.on_format_selected_helmod,
                    },
                },
                {
                    type = "radiobutton",
                    name = "factory_solver_solution_export_format_yafc",
                    caption = { "factory-solver-export-format-yafc" },
                    state = false,
                    handler = {
                        [defines.events.on_gui_checked_state_changed] = handlers.on_format_selected_yafc,
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
                type = "line",
                style = "factory_solver_line",
            },
            {
                type = "text-box",
                name = "factory_solver_solution_export_textbox",
                elem_mods = {
                    read_only = true,
                    word_wrap = true,
                },
                style_mods = {
                    width = 640,
                    height = 360,
                },
                handler = {
                    on_added = handlers.on_init_export_textbox,
                },
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
