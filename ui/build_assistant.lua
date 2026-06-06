local flib_format = require "__flib__/format"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local save = require "manage/save"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
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
    local variable_name = vk.material(typed_name)
    return set[variable_name] == true
end

---Hand the player an item via the engine's "smart pipette", or force a ghost
---onto the cursor. Manual mode uses this so an early-game player (no
---construction robots) can grab the machine / module to hand-place.
---
---`player.pipette` invokes the same action as pressing the pipette key, so the
---engine owns all of it: pulling a stack out of inventory when the item is
---owned (with the slot reservation that returns it on cursor-clear), and doing
---nothing when it is not owned. That is why this never touches cursor_stack /
---get_item_count / remove directly — manually moving items would not reserve
---the return slot. Shift forces a ghost instead, regardless of ownership;
---cursor_ghost is item-only, so a machine passes its placeable item name.
---
---Note: under cheat_mode the engine instead materialises a free stack for an
---unowned item. control.lua turns cheat_mode on in __DebugAdapter (debug)
---builds, so when testing this in a debug session unowned clicks appear to
---"create" items — that is expected cheat behaviour, not a bug, and does not
---happen in normal play.
---@param player LuaPlayer
---@param pipette_id LuaEntityPrototype|LuaItemPrototype prototype passed to LuaPlayer.pipette
---@param ghost_item string? item name placed as a cursor ghost when force_ghost
---@param quality string TypedName quality ("normal" and sentinels collapse to normal)
---@param force_ghost boolean
local function pipette_or_ghost(player, pipette_id, ghost_item, quality, force_ghost)
    -- Resolve to a LuaQualityPrototype: string QualityID is documented but
    -- unreliable in practice. "normal" / unknown keys leave it nil, which both
    -- APIs read as normal quality.
    local quality_proto = nil
    if quality and quality ~= "normal" then
        quality_proto = prototypes.quality[quality]
    end

    -- Multiplayer: pipette / cursor_ghost act only on the event player's own
    -- cursor, which is local per-player. This handler runs on every client in
    -- lockstep, and each acts on that player's cursor identically, so the
    -- mutation is deterministic.
    if force_ghost then
        if not ghost_item then return end
        player.cursor_ghost = { name = ghost_item, quality = quality_proto }
    else
        player.pipette(pipette_id, quality_proto, true)
    end
end

---Build the docked table's GUI definition. Factored out so the mode switch can
---destroy the table and re-add it: column_count is a static, immutable property
---and the two modes have differently-meaning columns, so a rebuild is cleaner
---than dispatching into the existing element.
---@return fs.GuiElemDef
local function build_table_def()
    return {
        type = "table",
        name = "build_table",
        style = "factory_solver_build_assistant_table",
        column_count = 5,
        handler = {
            on_added = handlers.make_build_table,
            on_selected_solution_changed = handlers.make_build_table,
            on_machine_setups_changed = handlers.make_build_table,
            on_calculation_changed = handlers.make_build_table,
        },
    }
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

    -- on_calculation_changed fires every tick while the solver iterates
    -- (solver_state is the "calculating" in-progress state). Rebuilding then
    -- would empty this fit-to-content docked panel each tick, collapsing it to
    -- just the title until the solve lands. So during a mid-solve state keep the
    -- last-rendered rows untouched and rebuild only when a final state arrives;
    -- a missing solution still clears to empty.
    if solution and solution.solver_state == "calculating" then
        return
    end

    elem.clear()
    if not solution then
        return
    end

    -- "manual" (default) hands the player the actual item/ghost via smart
    -- pipette and shows a per-machine module column; "blueprint" hands a
    -- temporary blueprint and shows the beacon column. Columns 1-3 are shared.
    local mode = save.get_player_data(event.player_index).build_assistant_mode or "manual"
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)
    for line_index, line in ipairs(solution.production_lines) do
        local recipe = tn.typed_name_to_recipe(line.recipe_typed_name)
        local machine = tn.typed_name_to_machine(line.machine_typed_name)
        local count = save.get_quantity_of_machines_required(solution, line.recipe_typed_name)

        -- Column 1: done checkbox — a build-progress TODO marker (BA only). For
        -- big plans (pyanodon can be ~100 lines) this lets the user tick off
        -- placed rows. State lives on the Solution, keyed by recipe identity.
        fs_util.add_gui(elem, {
            type = "checkbox",
            state = save.is_line_done(solution, line.recipe_typed_name),
            tags = { line_index = line_index },
            handler = {
                [defines.events.on_gui_checked_state_changed] = handlers.on_done_toggled,
            },
        })

        -- Column 2: recipe icon as the row identity (the machine icon alone is
        -- ambiguous when several recipes share a machine type).
        fs_util.add_gui(elem, common.create_decorated_sprite_button {
            typed_name = line.recipe_typed_name,
            is_hidden = acc.is_hidden(recipe),
            is_unresearched = acc.is_unresearched(recipe, relation_to_recipes),
        })

        -- Column 3: required machine count, same value/format/alignment/tint as
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

        -- Column 4: machine icon. This is the pipette button when the line maps
        -- to a placeable, configured machine; the handler differs by mode
        -- (blueprint on cursor vs. smart pipette of the machine item).
        if bp.can_pipette(line) then
            fs_util.add_gui(elem, common.create_decorated_sprite_button {
                typed_name = line.machine_typed_name,
                is_hidden = acc.is_hidden(machine),
                is_unresearched = acc.is_unresearched(machine, relation_to_recipes),
                tags = { line_index = line_index },
                handler = {
                    [defines.events.on_gui_click] = mode == "blueprint"
                        and handlers.on_pipette_click or handlers.on_machine_pick,
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

        -- Column 5: beacons (blueprint mode) or per-machine modules (manual
        -- mode). An empty flow keeps every row's cell count aligned.
        if mode == "blueprint" then
            -- Each beacon group can have a different beacon/module config, so
            -- all are shown as individual pipettes. Gated by is_use_beacon (and
            -- can_pipette) so beacon reads never touch the entity-ghost / plant
            -- sentinels.
            local beacon_buttons = {}
            if bp.can_pipette(line) and acc.is_use_beacon(machine) then
                for beacon_index, affected_by_beacon in ipairs(line.affected_by_beacons) do
                    local beacon_typed_name = affected_by_beacon.beacon_typed_name
                    local beacon = beacon_typed_name and tn.typed_name_to_machine(beacon_typed_name)
                    if beacon and beacon.type == "beacon" then
                        table.insert(beacon_buttons, common.create_decorated_sprite_button {
                            typed_name = beacon_typed_name,
                            is_hidden = acc.is_hidden(beacon),
                            is_unresearched = acc.is_unresearched(beacon, relation_to_recipes),
                            number = affected_by_beacon.beacon_quantity,
                            tags = { line_index = line_index, beacon_index = beacon_index },
                            handler = {
                                [defines.events.on_gui_click] = handlers.on_beacon_pipette_click,
                            },
                        })
                    end
                end
            end
            fs_util.add_gui(elem, {
                type = "flow",
                children = beacon_buttons,
            })
        else
            -- Manual mode: one badged button per distinct module the machine
            -- carries, the badge counting modules per single machine (not times
            -- the machine count). Beacons are hidden — without robots there are
            -- no beacons to place. Slots are walked in order so the buckets are
            -- deterministic across multiplayer clients.
            local module_buttons = {}
            if bp.can_pipette(line) then
                local size = machine.module_inventory_size
                if size and 0 < size then
                    local trimmed = acc.trim_modules(line.module_typed_names, size)
                    local order, buckets = {}, {}
                    for index = 1, size do
                        local module_typed_name = trimmed[tostring(index)]
                        if module_typed_name then
                            local key = module_typed_name.name .. "/" .. module_typed_name.quality
                            local entry = buckets[key]
                            if entry then
                                entry.count = entry.count + 1
                            else
                                buckets[key] = { typed_name = module_typed_name, count = 1 }
                                table.insert(order, key)
                            end
                        end
                    end
                    for _, key in ipairs(order) do
                        local entry = buckets[key]
                        local module_item = prototypes.item[entry.typed_name.name]
                        table.insert(module_buttons, common.create_decorated_sprite_button {
                            typed_name = entry.typed_name,
                            is_hidden = module_item and acc.is_hidden(module_item) or false,
                            is_unresearched = module_item
                                and acc.is_unresearched(module_item, relation_to_recipes) or false,
                            number = entry.count,
                            tags = {
                                line_index = line_index,
                                module_name = entry.typed_name.name,
                                module_quality = entry.typed_name.quality,
                            },
                            handler = {
                                [defines.events.on_gui_click] = handlers.on_module_pick,
                            },
                        })
                    end
                end
            end
            fs_util.add_gui(elem, {
                type = "flow",
                children = module_buttons,
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
    local player = game.players[event.player_index]
    local cursor = player.cursor_stack
    if not (cursor and cursor.valid) then return end

    local entities = bp.build_machine_blueprint_entities(line)
    if cursor.set_stack { name = "blueprint" } then
        cursor.set_blueprint_entities(entities)
        -- Mark the cursor blueprint temporary so the engine destroys it when
        -- the cursor is cleared, instead of dumping a real blueprint item into
        -- the player's inventory on every pipette.
        player.cursor_stack_temporary = true
    end
end

---@param event EventData.on_gui_click
function handlers.on_beacon_pipette_click(event)
    if common.try_open_factoriopedia(event) then return end
    if event.button ~= defines.mouse_button_type.left then return end

    local tags = event.element.tags
    local solution = save.get_selected_solution(event.player_index)
    if not solution then return end
    local line = solution.production_lines[tags.line_index --[[@as integer]]]
    if not line then return end
    local affected_by_beacon = line.affected_by_beacons[tags.beacon_index --[[@as integer]]]
    if not affected_by_beacon then return end

    local entities = bp.build_beacon_blueprint_entities(affected_by_beacon)
    if not entities then return end

    -- Same multiplayer reasoning as on_pipette_click: act unconditionally on
    -- the event player's own cursor; entities are built deterministically.
    local player = game.players[event.player_index]
    local cursor = player.cursor_stack
    if not (cursor and cursor.valid) then return end

    if cursor.set_stack { name = "blueprint" } then
        cursor.set_blueprint_entities(entities)
        player.cursor_stack_temporary = true
    end
end

---@param event EventData.on_gui_click
function handlers.on_machine_pick(event)
    if common.try_open_factoriopedia(event) then return end
    if event.button ~= defines.mouse_button_type.left then return end

    local tags = event.element.tags
    local solution = save.get_selected_solution(event.player_index)
    if not solution then return end
    local line = solution.production_lines[tags.line_index --[[@as integer]]]
    if not line or not bp.can_pipette(line) then return end

    local machine = tn.typed_name_to_machine(line.machine_typed_name)
    -- The placeable item is only needed for the forced-ghost (Shift) path;
    -- pipette resolves the item from the entity prototype itself.
    local first = machine.items_to_place_this and machine.items_to_place_this[1]
    local ghost_item = first and first.name or nil

    local player = game.players[event.player_index]
    pipette_or_ghost(player, machine, ghost_item, line.machine_typed_name.quality, event.shift)
end

---@param event EventData.on_gui_click
function handlers.on_module_pick(event)
    if common.try_open_factoriopedia(event) then return end
    if event.button ~= defines.mouse_button_type.left then return end

    local tags = event.element.tags
    local module_name = tags.module_name --[[@as string]]
    local module_quality = tags.module_quality --[[@as string]]
    local module_item = prototypes.item[module_name]
    if not module_item then return end

    local player = game.players[event.player_index]
    pipette_or_ghost(player, module_item, module_name, module_quality, event.shift)
end

---@param event EventData.on_gui_checked_state_changed
function handlers.on_done_toggled(event)
    local solution = save.get_selected_solution(event.player_index)
    if not solution then return end
    local line = solution.production_lines[event.element.tags.line_index --[[@as integer]]]
    if not line then return end
    -- Persist only; the engine already flipped the checkbox visual, and the
    -- state is re-read from the Solution when the table next rebuilds.
    save.set_line_done(solution, line.recipe_typed_name, event.element.state)
end

---@param event EventDataTrait
function handlers.on_build_assistant_mode_switch_added(event)
    local player_data = save.get_player_data(event.player_index)
    event.element.switch_state = player_data.build_assistant_mode == "blueprint" and "right" or "left"
end

---@param event EventData.on_gui_switch_state_changed
function handlers.on_build_assistant_mode_switch_state_changed(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    player_data.build_assistant_mode = elem.switch_state == "right" and "blueprint" or "manual"

    -- column_count is fixed once the table exists, so swap the whole table.
    -- add_gui re-fires on_added, which rebuilds the rows for the new mode.
    local frame = assert(fs_util.find_upper(elem, "factory_solver_build_assistant"))
    local scroll = frame["build_table_scroll"]
    local old_table = scroll and scroll["build_table"]
    if old_table then
        old_table.destroy()
    end
    if scroll then
        fs_util.add_gui(scroll, build_table_def())
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
    -- left = Manual (smart pipette of items/ghosts, early game),
    -- right = Blueprint (temporary blueprint for construction robots).
    {
        type = "switch",
        name = "build_assistant_mode_switch",
        switch_state = "left",
        left_label_caption = { "factory-solver-build-assistant-mode-manual" },
        right_label_caption = { "factory-solver-build-assistant-mode-blueprint" },
        tags = { root_gui = "factory_solver_build_assistant" },
        handler = {
            [defines.events.on_gui_switch_state_changed] = handlers.on_build_assistant_mode_switch_state_changed,
            on_added = handlers.on_build_assistant_mode_switch_added,
        },
    },
    {
        type = "scroll-pane",
        name = "build_table_scroll",
        style = "factory_solver_dialog_fit_scroll_pane",
        style_mods = { padding = 0 },
        build_table_def(),
    },
}
