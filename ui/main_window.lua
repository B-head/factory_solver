local fs_util = require "fs_util"
local common = require "ui/common"
local common_settings = require "ui/common_settings"
local solution_editor = require "ui/solution_editor"
local solution_results = require "ui/solution_results"
local solution_selector = require "ui/solution_selector"
local solution_settings = require "ui/solution_settings"

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

---Title-bar name filter changed: store the needle on the window frame and
---repaint the highlights. Unlike the picker dialogs (which rebuild a slot list
---on filter change), the main window only restyles existing slots, so this calls
---refresh_highlight directly instead of dispatching a rebuild event.
---@param event EventData.on_gui_text_changed
function handlers.on_main_window_filter_textfield_changed(event)
    local root = assert(fs_util.find_upper(event.element, "factory_solver_main_window"))
    local root_tags = root.tags
    root_tags.filter_text = event.element.text
    root.tags = root_tags
    common.refresh_highlight(root)
end

---Re-apply highlights after a panel rebuilds its slots. The editor / results /
---constraints tables clear and regenerate on these events, and the solver pump
---also fires on_calculation_changed every tick while a solution iterates.
---Regenerated slots are born at base_style, and both highlight inputs (filter
---text, hovered slot) live on the window tags, so one refresh restores both. The
---anchor binding this handler sits at the end of the window contents, so DFS
---dispatch reaches it after every panel has rebuilt. Guarded so the every-tick
---on_calculation_changed storm is a no-op when nothing is highlighted; crucially,
---when a filter IS active this re-apply reads the stored hover too, so it no
---longer erases the hover highlight on each solver tick.
---@param event EventDataTrait
function handlers.on_reapply_filter_highlight(event)
    local root = assert(fs_util.find_upper(event.element, "factory_solver_main_window"))
    local tags = root.tags
    if (tags.filter_text --[[@as string?]] or "") ~= "" or tags.hover_typed_name ~= nil then
        common.refresh_highlight(root)
    end
end

---Repaint on the on_filter_text_changed broadcast that common.on_toggle_name_filter
---fires when the search box is closed (it clears filter_text but, being a
---programmatic .text change, raises no on_gui_text_changed). Unlike the rebuild
---re-apply above, this must run unconditionally: the filter is now empty, and the
---point is to clear the leftover highlights back to base_style.
---@param event EventDataTrait
function handlers.on_main_window_filter_cleared(event)
    local root = assert(fs_util.find_upper(event.element, "factory_solver_main_window"))
    common.refresh_highlight(root)
end

fs_util.add_handlers(handlers)

---@type fs.GuiElemDef
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
            caption = { "mod-name.factory_solver" },
            ignored_by_interaction = true,
        },
        {
            type = "empty-widget",
            style = "flib_titlebar_drag_handle",
            ignored_by_interaction = true,
        },
        {
            type = "textfield",
            name = "main_window_filter_textfield",
            style = "flib_titlebar_search_textfield",
            visible = false,
            clear_and_focus_on_right_click = true,
            tooltip = { "factory-solver-name-filter-tooltip" },
            handler = {
                [defines.events.on_gui_text_changed] = handlers.on_main_window_filter_textfield_changed,
            },
        },
        {
            type = "sprite-button",
            style = "frame_action_button",
            sprite = "utility/search",
            hovered_sprite = "utility/search",
            clicked_sprite = "utility/search",
            handler = {
                [defines.events.on_gui_click] = common.on_toggle_name_filter,
            },
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
        -- Invisible anchor that re-applies the name-filter highlight after any
        -- panel rebuilds its slots. Placed last in the contents so DFS dispatch
        -- visits it after every panel has regenerated. visible=false keeps it out
        -- of layout (no gap) while custom-event dispatch, which walks the tree via
        -- dfs_lower, still reaches it. Its handler set must cover every event that
        -- makes a panel clear+rebuild decorated slots.
        {
            type = "empty-widget",
            name = "main_window_filter_anchor",
            visible = false,
            handler = {
                on_filter_text_changed = handlers.on_main_window_filter_cleared,
                on_selected_solution_changed = handlers.on_reapply_filter_highlight,
                on_production_line_changed = handlers.on_reapply_filter_highlight,
                on_constraint_changed = handlers.on_reapply_filter_highlight,
                on_machine_setups_changed = handlers.on_reapply_filter_highlight,
                on_calculation_changed = handlers.on_reapply_filter_highlight,
                on_amount_unit_changed = handlers.on_reapply_filter_highlight,
            },
        },
    },
}
