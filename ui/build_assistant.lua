local flib_format = require "__flib__/format"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local save = require "manage/save"
local tn = require "manage/typed_name"
local bp = require "manage/blueprint"
local common = require "ui/common"

local handlers = {}

-- Mirror solution_editor's Required-column tinting: inactive lines (not
-- graph-connected to any Constraint, so their machine count collapses to 0)
-- read dimmed. Kept local rather than shared because it is three trivial lines.
local inactive_font_color = { 0.5, 0.5, 0.5 }
local active_font_color = { 1, 1, 1 }

---@param solution Solution
---@param typed_name TypedName
---@return boolean
local function is_line_inactive(solution, typed_name)
    local set = solution.inactive_recipe_variables
    if not set then return false end
    local variable_name = string.format("%s/%s/%s", typed_name.type, typed_name.name, typed_name.quality)
    return set[variable_name] == true
end

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

        -- Column 1: recipe icon as the row identity (the machine icon alone is
        -- ambiguous when several recipes share a machine type).
        fs_util.add_gui(elem, common.create_decorated_sprite_button {
            typed_name = line.recipe_typed_name,
            is_hidden = acc.is_hidden(recipe),
            is_unresearched = acc.is_unresearched(recipe, relation_to_recipes),
        })

        -- Column 2: required machine count, same value/format/alignment/tint as
        -- the main window's "Required" column so a row reads identically in both
        -- windows (lower cognitive load than re-deriving from icons).
        fs_util.add_gui(elem, {
            type = "label",
            caption = flib_format.number(count, true, 5),
            style_mods = {
                font_color = is_line_inactive(solution, line.recipe_typed_name)
                    and inactive_font_color or active_font_color,
            },
        })

        -- Column 3: machine icon. This is the pipette button when the line maps
        -- to a placeable, configured machine.
        if bp.can_pipette(line) then
            fs_util.add_gui(elem, common.create_decorated_sprite_button {
                typed_name = line.machine_typed_name,
                is_hidden = acc.is_hidden(machine),
                is_unresearched = acc.is_unresearched(machine, relation_to_recipes),
                tags = { line_index = line_index },
                handler = {
                    [defines.events.on_gui_click] = handlers.on_pipette_click,
                },
            })
        else
            -- Plant (1 craft = 1 plant slot) and spoilage (time-driven) lines
            -- have no placeable machine. Show a non-interactive indicator so
            -- the columns still line up, matching solution_editor's machine-cell
            -- convention (substrate tile / clock).
            fs_util.add_gui(elem, {
                type = "sprite-button",
                style = "flib_slot_button_default",
                sprite = line.substrate_tile_name and ("tile/" .. line.substrate_tile_name) or "utility/clock",
                elem_tooltip = line.substrate_tile_name
                    and { type = "tile", name = line.substrate_tile_name } or nil,
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
    style = "tooltip_panel_background",
    style_mods = { padding = 0 },
    direction = "vertical",
    handler = {
        on_added = handlers.on_build_assistant_added,
        on_close = handlers.on_build_assistant_close,
    },
    -- No close button: the panel is docked in gui.left and the shortcut
    -- toggles it. No drag handler either — the engine owns docked placement.
    {
        type = "label",
        style = "frame_title",
        caption = { "factory-solver-build-assistant-title" },
        ignored_by_interaction = true,
    },
    {
        type = "scroll-pane",
        style = "factory_solver_dialog_fit_scroll_pane",
        style_mods = { padding = 0 },
        {
            type = "table",
            style = "factory_solver_build_assistant_table",
            column_count = 3,
            handler = {
                on_added = handlers.make_build_table,
                on_selected_solution_changed = handlers.make_build_table,
                on_machine_setups_changed = handlers.make_build_table,
                on_calculation_changed = handlers.make_build_table,
            },
        },
    },
}
