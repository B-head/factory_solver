local fs_util = require "fs_util"
local acc = require "manage/accessor"
local save = require "manage/save"
local tn = require "manage/typed_name"
local bp = require "manage/blueprint"
local common = require "ui/common"

local handlers = {}

---@param event EventDataTrait
function handlers.on_build_assistant_added(event)
    local player = game.players[event.player_index]
    player.set_shortcut_toggled("factory-solver-toggle-build-assistant", true)
end

---@param event EventDataTrait
function handlers.on_build_assistant_close(event)
    local player = game.players[event.player_index]
    player.set_shortcut_toggled("factory-solver-toggle-build-assistant", false)
end

-- The build assistant is a non-modal, persistent window that coexists with
-- the main window, so it deliberately does NOT participate in the opened_gui
-- modal stack (common.open_gui / on_close_self). Closing is just a subtree
-- on_close dispatch (to untoggle the shortcut) followed by destroy.
---@param event EventData.on_gui_click
function handlers.on_build_assistant_close_click(event)
    local window = common.find_root_element(event.player_index, "factory_solver_build_assistant")
    if window then
        fs_util.dispatch_to_subtree(window, "on_close")
        window.destroy()
    end
end

---@param event EventDataTrait
function handlers.make_build_table(event)
    local elem = event.element
    local solution = save.get_selected_solution(event.player_index)
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)

    elem.clear()
    if not solution or type(solution.solver_state) == "number" then
        return
    end

    for line_index, line in ipairs(solution.production_lines) do
        local recipe = tn.typed_name_to_recipe(line.recipe_typed_name)
        local machine = tn.typed_name_to_machine(line.machine_typed_name)
        local count = save.get_quantity_of_machines_required(solution, line.recipe_typed_name)
        local machine_number = math.ceil(count + acc.tolerance)

        -- Column A: recipe icon as the row identity (the machine icon alone is
        -- ambiguous when several recipes share a machine type).
        fs_util.add_gui(elem, common.create_decorated_sprite_button {
            typed_name = line.recipe_typed_name,
            is_hidden = acc.is_hidden(recipe),
            is_unresearched = acc.is_unresearched(recipe, relation_to_recipes),
        })

        -- Column B: machine icon + count. This is the pipette button when the
        -- line maps to a placeable, configured machine.
        if bp.can_pipette(line) then
            fs_util.add_gui(elem, common.create_decorated_sprite_button {
                typed_name = line.machine_typed_name,
                is_hidden = acc.is_hidden(machine),
                is_unresearched = acc.is_unresearched(machine, relation_to_recipes),
                number = machine_number,
                tags = { line_index = line_index },
                handler = {
                    [defines.events.on_gui_click] = handlers.on_pipette_click,
                },
            })
        else
            -- Plant (1 craft = 1 plant slot) and spoilage (time-driven) lines
            -- have no placeable machine. Show a non-interactive indicator so
            -- the two columns still line up, matching solution_editor's
            -- machine-cell convention (substrate tile / clock).
            fs_util.add_gui(elem, {
                type = "sprite-button",
                style = "flib_slot_button_default",
                sprite = line.substrate_tile_name and ("tile/" .. line.substrate_tile_name) or "utility/clock",
                elem_tooltip = line.substrate_tile_name
                    and { type = "tile", name = line.substrate_tile_name } or nil,
                number = machine_number,
                ignored_by_interaction = true,
            })
        end
    end
end

---@param event EventData.on_gui_click
function handlers.on_pipette_click(event)
    if common.try_open_factoriopedia(event) then return end
    if event.button ~= defines.mouse_button_type.left then return end

    local tags = event.element.tags
    local line_index = tags.line_index --[[@as integer]]
    local solution = save.get_selected_solution(event.player_index)
    if not solution then return end
    local line = solution.production_lines[line_index]
    if not line or not bp.can_pipette(line) then return end

    -- Cursor is local per-player, but this handler runs on every client in
    -- lockstep; acting unconditionally on the event player's own cursor is
    -- correct (each client mutates that player's cursor identically). The
    -- entity list is built deterministically in manage/blueprint.lua.
    local cursor = game.players[event.player_index].cursor_stack
    if not (cursor and cursor.valid) then return end

    local entities = bp.build_machine_blueprint_entities(line)
    if cursor.set_stack { name = "blueprint" } then
        cursor.set_blueprint_entities(entities)
    end
end

fs_util.add_handlers(handlers)

---@type fs.GuiElemDef
return {
    type = "frame",
    name = "factory_solver_build_assistant",
    direction = "vertical",
    handler = {
        on_added = handlers.on_build_assistant_added,
        on_close = handlers.on_build_assistant_close,
    },
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = "factory_solver_build_assistant",
        },
        handler = {
            on_added = common.on_init_drag_target,
        },
        {
            type = "label",
            style = "frame_title",
            caption = { "factory-solver-build-assistant-title" },
            ignored_by_interaction = true,
        },
        {
            type = "empty-widget",
            style = "flib_titlebar_drag_handle",
            ignored_by_interaction = true,
        },
        {
            type = "sprite-button",
            style = "frame_action_button",
            sprite = "utility/close",
            hovered_sprite = "utility/close_black",
            clicked_sprite = "utility/close_black",
            handler = {
                [defines.events.on_gui_click] = handlers.on_build_assistant_close_click,
            },
        },
    },
    {
        type = "scroll-pane",
        style = "factory_solver_fit_filter_scroll_pane",
        {
            type = "table",
            style = "filter_slot_table",
            column_count = 2,
            handler = {
                on_added = handlers.make_build_table,
                on_selected_solution_changed = handlers.make_build_table,
                on_machine_setups_changed = handlers.make_build_table,
                on_calculation_changed = handlers.make_build_table,
            },
        },
    },
}
