local flib_table = require "__flib__/table"
local flib_format = require "__flib__/format"
local fs_util = require "fs_util"
local save = require "manage/save"
local tn = require "manage/typed_name"

local M = {}

---comment
---@param is_hidden boolean
---@param is_unresearched boolean
---@param filter_type FilterType?
---@return string
function M.get_style(is_hidden, is_unresearched, filter_type)
    if is_hidden then
        return "flib_slot_button_grey"
    elseif is_unresearched then
        return "flib_slot_button_orange"
    else
        if filter_type == "recipe" or filter_type == "virtual_recipe" then
            return "flib_slot_button_blue"
        else
            return "flib_slot_button_default"
        end
    end
end

---True when the products/ingredients sections should be rendered ingredients-
---first (the default, matching the engine's "ingredients -> product" reading
---order): Ingredients column left of Products in the editor, input group above
---output group in the adder. This is the INVERSE of the per-player
---"classic-recipe-io-placement" opt-in, which restores the classic
---factory_solver products-first placement when enabled. Reading a per-player
---setting is MP-deterministic (settings are replicated), so it is safe to
---consult inside a GUI build/handler path.
---@param player_index integer
---@return boolean
function M.is_recipe_io_placement_swapped(player_index)
    return not settings.get_player_settings(player_index)["factory-solver-classic-recipe-io-placement"].value
end

---True when the production line rows should be rendered reversed (the default:
---newly added lines on top, Initial ingredients above Final products in the
---results panel). This is the INVERSE of the per-player
---"classic-production-line-order" opt-in, which restores the classic order
---(Final products on top) when enabled. Reverses the row order in the solution
---editor and build assistant and swaps the results-panel sections. Display-only:
---the shared production_lines array is never mutated. MP-deterministic for the
---same reason as the placement setting above.
---@param player_index integer
---@return boolean
function M.is_production_line_order_reversed(player_index)
    return not settings.get_player_settings(player_index)["factory-solver-classic-production-line-order"].value
end

---comment
---@param is_hidden boolean
---@param is_unresearched boolean
---@param player_data PlayerLocalData
---@return boolean
function M.craft_visible(is_hidden, is_unresearched, player_data)
    if is_hidden then
        return player_data.hidden_craft_visible
    elseif is_unresearched then
        return player_data.unresearched_craft_visible
    end

    return true
end

---comment
---@param group_infos GroupInfos
---@param group_name string
---@param player_data PlayerLocalData
---@return boolean
function M.group_visible(group_infos, group_name, player_data)
    local group_info = group_infos[group_name]
    if not group_info then
        return false
    end

    if player_data.hidden_craft_visible and 0 < group_info.hidden_count then
        return true
    elseif player_data.unresearched_craft_visible and 0 < group_info.unresearched_count then
        return true
    elseif 0 < group_info.researched_count then
        return true
    else
        return false
    end
end

---Substring name filter shared by the constraint and production-line pickers.
---`needle` must already be folded via helpers.multilingual_to_lower; "" matches
---everything. Matches the internal name first, then the locale-resolved display
---name (nil while the flib dictionary has not finished translating, so callers
---degrade to name-only filtering). Uses helpers.multilingual_to_lower so case is
---folded for non-Latin scripts too, and a plain (non-pattern) string.find.
---@param needle string
---@param name string
---@param localised string?
---@return boolean
function M.name_filter_matches(needle, name, localised)
    if needle == "" then
        return true
    end
    if string.find(helpers.multilingual_to_lower(name), needle, 1, true) then
        return true
    end
    if localised and string.find(helpers.multilingual_to_lower(localised), needle, 1, true) then
        return true
    end
    return false
end

---Format a power / energy value with an SI prefix. Negative values are treated
---as generation and shown with a leading "+". The unit suffix defaults to "J"
---(energy per the selected time unit, as shown in the UI); pass "W" for the
---time-scale-independent wattage.
---@param power number
---@param unit string?
---@return string
function M.format_power(power, unit)
    unit = unit or "J"
    if power < 0 then
        local temp = flib_format.number(-power, true, 5)
        return string.format("+%s%s", temp, unit)
    else
        local temp = flib_format.number(power, true, 5)
        return string.format("%s%s", temp, unit)
    end
end

---comment
---@param data table
---@return fs.GuiElemDef
function M.create_decorated_sprite_button(data)
    local typed_name = assert(data.typed_name) --[[@as TypedName]]
    local is_hidden = data.is_hidden or false
    local is_unresearched = data.is_unresearched or false
    -- Fluid TypedNames are range-only, so the slot reads its range from the
    -- typed_name's min/max. A single point temperature only appears on the raw
    -- product of an external source recipe (the recipe's typed_name is just a
    -- name); pull it from there into `temperature` below so source slots show a
    -- single "T°" while sink slots show their acceptance range.
    local temperature = nil ---@type number?
    local minimum_temperature = typed_name.minimum_temperature
    local maximum_temperature = typed_name.maximum_temperature
    local top_right_sprite = data.top_right_sprite --[[@as string?]]
    if not top_right_sprite and typed_name.type == "virtual_recipe" then
        local recipe = storage.virtuals.recipe[typed_name.name]
        if recipe then
            if recipe.consumed_pack_name then
                top_right_sprite = "factory-solver-research-overlay"
            elseif recipe.is_spoilage then
                top_right_sprite = "factory-solver-spoilage-overlay"
            elseif recipe.is_source then
                top_right_sprite = "factory-solver-source-overlay"
                local product = recipe.products[1]
                if product and product.type == "fluid" then
                    temperature = product.temperature
                end
            elseif recipe.is_sink then
                top_right_sprite = "factory-solver-sink-overlay"
                local ingredient = recipe.ingredients[1]
                if ingredient and ingredient.type == "fluid" then
                    minimum_temperature = ingredient.minimum_temperature
                    maximum_temperature = ingredient.maximum_temperature
                end
            end
        end
    end
    local children = {}

    if temperature ~= nil then
        flib_table.insert(children, {
            type = "flow",
            direction = "vertical",
            style = "factory_solver_slot_temperature_flow",
            ignored_by_interaction = true,
            children = {
                {
                    type = "label",
                    style = "factory_solver_slot_temperature_label",
                    caption = { "factory-solver-slot-temperature", tn.format_temperature(temperature) },
                    ignored_by_interaction = true,
                },
            },
        })
    elseif minimum_temperature ~= nil then
        -- A degenerate range (min == max) is conceptually a single temperature;
        -- render it as "25°" instead of "25°~25°" so it reads identically to the
        -- single-temperature slots it sits alongside.
        local range_children
        if minimum_temperature == maximum_temperature then
            range_children = {
                {
                    type = "label",
                    style = "factory_solver_slot_temperature_label",
                    caption = { "factory-solver-slot-temperature", tn.format_temperature(minimum_temperature) },
                    ignored_by_interaction = true,
                },
            }
        else
            range_children = {
                {
                    type = "label",
                    style = "factory_solver_slot_temperature_label",
                    caption = { "factory-solver-slot-temperature-lower", tn.format_temperature(minimum_temperature) },
                    ignored_by_interaction = true,
                },
                {
                    type = "label",
                    style = "factory_solver_slot_temperature_label",
                    caption = { "factory-solver-slot-temperature", tn.format_temperature(maximum_temperature) },
                    ignored_by_interaction = true,
                },
            }
        end
        flib_table.insert(children, {
            type = "flow",
            direction = "vertical",
            style = "factory_solver_slot_temperature_flow",
            ignored_by_interaction = true,
            children = range_children,
        })
    end

    -- Generic top-right overlay slot. Currently used by the module picker
    -- to flag effect-masked modules (warning icon); future callers can reuse
    -- the same corner for other per-slot indicators by passing their own
    -- sprite path. Tooltip extension is left to the caller because the
    -- meaning of the indicator is caller-specific.
    if top_right_sprite then
        flib_table.insert(children, {
            type = "sprite",
            style = "factory_solver_slot_image_top_right",
            sprite = top_right_sprite,
            ignored_by_interaction = true,
        })
    end

    return {
        type = "sprite-button",
        style = M.get_style(is_hidden, is_unresearched, typed_name.type),
        sprite = tn.get_sprite_path(typed_name),
        quality = typed_name.quality,
        tooltip = tn.typed_name_to_tooltip(typed_name),
        elem_tooltip = tn.typed_name_to_elem_id(typed_name),
        number = data.number,
        tags = data.tags,
        handler = data.handler,
        children = children
    }
end

---Appends `line` as a new line below def's existing tooltip. The engine renders
---elem_tooltip (the Factoriopedia card) above the plain tooltip, so the appended
---line shows beneath the item / recipe name. When def has no tooltip yet — the
---common case, since typed_name_to_tooltip returns nil for items / recipes /
---entities and many buttons carry only elem_tooltip — the line becomes the whole
---tooltip with no leading blank line (a `{ "", "", "\n", line }` would render an
---empty first row). Mutates and returns def so it can be inlined at a call site.
---@param def fs.GuiElemDef
---@param line LocalisedString
---@return fs.GuiElemDef
function M.append_tooltip_line(def, line)
    if def.tooltip and def.tooltip ~= "" then
        def.tooltip = { "", def.tooltip, "\n", line }
    else
        def.tooltip = line
    end
    return def
end

---Per-role operation-hint builders. Each returns a LocalisedString listing the
---button's mouse actions (one per line, joined with "\n") in the order the
---click handlers resolve them: left -> right -> Shift-copy -> Shift-paste. Kept
---here so the wording and ordering for each role live in one place and can be
---shared across solution_editor / machine_setup / solution_settings. (A plain
---data table on M, like root_window_names; add_handlers ignores non-functions.)
M.op_hints = {}

---Recipe icon in the production-line table. Left-click selects quality variants
---only when the quality feature is enabled; without it the recipe icon's
---left-click does nothing (machine settings stay reachable via the machine /
---substrate / clock buttons), so the hint omits the left line in that case.
---@return LocalisedString
function M.op_hints.recipe_icon()
    if script.feature_flags.quality then
        return { "", { "factory-solver-hint-select-quality-variants" },
            "\n", { "factory-solver-hint-add-constraint" } }
    end
    return { "", { "factory-solver-hint-add-constraint" } }
end

---Machine icon / substrate tile button: open settings, add a constraint, and
---copy/paste the machine and fuel.
---@return LocalisedString
function M.op_hints.machine_icon()
    return { "", { "factory-solver-hint-open-machine-settings" },
        "\n", { "factory-solver-hint-add-constraint" },
        "\n", { "factory-solver-hint-copy-machine-fuel" },
        "\n", { "factory-solver-hint-paste-here" } }
end

---Aggregated module icon in the machine cell: like the machine icon, but the
---copy/paste mode pinned to this button covers modules and beacons.
---@return LocalisedString
function M.op_hints.module_aggregate()
    return { "", { "factory-solver-hint-open-machine-settings" },
        "\n", { "factory-solver-hint-add-constraint" },
        "\n", { "factory-solver-hint-copy-module-beacon" },
        "\n", { "factory-solver-hint-paste-here" } }
end

---Spoilage clock button: opens machine settings or adds a constraint. No
---copy/paste (no paste_target) and no Factoriopedia (no elem_tooltip).
---@return LocalisedString
function M.op_hints.recipe_clock()
    return { "", { "factory-solver-hint-open-machine-settings" },
        "\n", { "factory-solver-hint-add-constraint" } }
end

---Product / ingredient / spent-fuel icon: opens the recipe picker for that
---material, or adds a constraint.
---@return LocalisedString
function M.op_hints.inout()
    return { "", { "factory-solver-hint-open-recipe-picker" },
        "\n", { "factory-solver-hint-add-constraint" } }
end

---Filled module slot in machine_setup: pick / clear / copy / paste a module.
---@return LocalisedString
function M.op_hints.module_slot()
    return { "", { "factory-solver-hint-open-module-picker" },
        "\n", { "factory-solver-hint-clear-module" },
        "\n", { "factory-solver-hint-copy-module" },
        "\n", { "factory-solver-hint-paste-module" } }
end

---Empty module slot: only choosing or pasting a module is meaningful.
---@return LocalisedString
function M.op_hints.module_slot_empty()
    return { "", { "factory-solver-hint-open-module-picker" },
        "\n", { "factory-solver-hint-paste-module" } }
end

---Filled beacon slot: choose or clear the beacon. The beacon entity slot has no
---copy/paste (on_open_beacon_picker has no Shift branch).
---@return LocalisedString
function M.op_hints.beacon_slot()
    return { "", { "factory-solver-hint-open-beacon-picker" },
        "\n", { "factory-solver-hint-clear-beacon" } }
end

---Empty beacon slot: only choosing a beacon is meaningful.
---@return LocalisedString
function M.op_hints.beacon_slot_empty()
    return { "factory-solver-hint-open-beacon-picker" }
end

---Constraint icon in the constraints panel: left-click adds a production line
---for the target; there is no right-click action.
---@return LocalisedString
function M.op_hints.constraint_icon()
    return { "factory-solver-hint-constraint-add-lines" }
end

---Row move buttons (production line / constraint): one action per line, like
---the other hints — plain click / Shift (to the end) / Control (five steps).
---@return LocalisedString
function M.op_hints.move_row()
    return { "", { "factory-solver-hint-move-one" },
        "\n", { "factory-solver-hint-move-to-end" },
        "\n", { "factory-solver-hint-move-five" } }
end

---Resolve an ElemID to the prototype that LuaPlayer.open_factoriopedia_gui
---accepts and open Factoriopedia. Quality is intentionally dropped: the
---Factoriopedia surface is per-prototype, not per-quality variant. Returns
---true on a successful open so callers can decide whether to suppress the
---button's normal click action. Branches here cover the ElemID types that
---factory_solver actually emits into elem_tooltip (item / fluid / entity /
---recipe / tile + their *-with-quality variants). item-group elem_tooltips
---exist on constraint_adder filter buttons but open_factoriopedia_gui does
---not accept LuaGroup; those return false so the normal filter switch still
---fires when the user holds Alt.
---@param player LuaPlayer
---@param elem_id ElemID
---@return boolean opened
function M.open_factoriopedia_from_elem_id(player, elem_id)
    local t = elem_id.type
    local name = elem_id.name
    local proto
    if t == "item" or t == "item-with-quality" then
        proto = prototypes.item[name]
    elseif t == "entity" or t == "entity-with-quality" then
        proto = prototypes.entity[name]
    elseif t == "fluid" then
        proto = prototypes.fluid[name]
    elseif t == "recipe" or t == "recipe-with-quality" then
        proto = prototypes.recipe[name]
    elseif t == "tile" then
        proto = prototypes.tile[name]
    end
    if proto then
        player.open_factoriopedia_gui(proto)
        return true
    end
    return false
end

---If the click is Alt+left on a sprite-button whose elem_tooltip resolves to
---a Factoriopedia-accepted prototype, open Factoriopedia and return true so
---the caller can short-circuit its normal click flow. When the elem_tooltip
---is missing or its type cannot be opened (e.g. item-group), returns false
---and the caller's regular click action proceeds.
---@param event EventData.on_gui_click
---@return boolean handled
function M.try_open_factoriopedia(event)
    if not event.alt then return false end
    if event.button ~= defines.mouse_button_type.left then return false end
    local elem = event.element
    if not (elem and elem.valid) then return false end
    local elem_id = elem.elem_tooltip
    if not elem_id then return false end
    return M.open_factoriopedia_from_elem_id(game.players[event.player_index], elem_id)
end

---Builds a horizontal row of `tool_button` sprite-buttons inside `parent`, one per
---non-hidden quality, matching Factorio's engine-side quality selector. The button
---whose quality matches `initial_value` starts toggled. Each button stores its
---quality name in `tags.quality_name` and dispatches `on_click` on left-click.
---@param parent LuaGuiElement
---@param initial_value string
---@param on_click fun(event: EventData.on_gui_click)
function M.make_quality_buttons(parent, initial_value, on_click)
    local qualities = fs_util.sort_prototypes(fs_util.to_list(prototypes.quality))
    for _, value in ipairs(qualities) do
        if not value.hidden then
            fs_util.add_gui(parent, {
                type = "sprite-button",
                name = "factory_solver_quality_button_" .. value.name,
                style = "tool_button",
                sprite = "quality/" .. value.name,
                tooltip = { "", "[quality=", value.name, "] ", value.localised_name },
                toggled = (value.name == initial_value),
                tags = { quality_name = value.name },
                handler = {
                    [defines.events.on_gui_click] = on_click,
                },
            })
        end
    end
end

---Untoggles sibling quality buttons and toggles the clicked one. Returns the
---selected quality name pulled from `tags.quality_name`.
---@param clicked LuaGuiElement
---@return string selected_quality_name
function M.on_quality_button_clicked(clicked)
    for _, sibling in pairs(clicked.parent.children) do
        sibling.toggled = (sibling == clicked)
    end
    return clicked.tags.quality_name --[[@as string]]
end

---Multi-select variant of `make_quality_buttons`: each button is independently
---toggleable, and `initial_set[quality_name] = true` marks which start toggled.
---Visual style is identical to the single-select row.
---@param parent LuaGuiElement
---@param initial_set table<string, boolean>
---@param on_click fun(event: EventData.on_gui_click)
function M.make_quality_buttons_multi(parent, initial_set, on_click)
    local qualities = fs_util.sort_prototypes(fs_util.to_list(prototypes.quality))
    for _, value in ipairs(qualities) do
        if not value.hidden then
            fs_util.add_gui(parent, {
                type = "sprite-button",
                name = "factory_solver_quality_button_" .. value.name,
                style = "tool_button",
                sprite = "quality/" .. value.name,
                tooltip = { "", "[quality=", value.name, "] ", value.localised_name },
                toggled = initial_set[value.name] == true,
                tags = { quality_name = value.name },
                handler = {
                    [defines.events.on_gui_click] = on_click,
                },
            })
        end
    end
end

---Multi-select click: flips only the clicked button, leaving siblings alone.
---Returns the clicked quality name and its new toggled state.
---@param clicked LuaGuiElement
---@return string quality_name
---@return boolean new_state
function M.on_quality_button_clicked_multi(clicked)
    clicked.toggled = not clicked.toggled
    return clicked.tags.quality_name --[[@as string]], clicked.toggled
end

---Reads the current toggled set from a quality-button row built by
---`make_quality_buttons` or `make_quality_buttons_multi`. Returns a set
---(`{ [quality_name] = true }`) of currently-checked quality names.
---@param parent LuaGuiElement
---@return table<string, true>
function M.read_quality_button_set(parent)
    local set = {}
    for _, child in pairs(parent.children) do
        local quality_name = child.tags and child.tags.quality_name --[[@as string?]]
        if quality_name and child.toggled then
            set[quality_name] = true
        end
    end
    return set
end

---Writes a module selection into the `factory_solver_machine_setups` dialog's
---tags and dispatches `on_module_changed` so the rest of the dialog (total
---effectivity table, quality-module warning, slot re-render) updates. Used by
---the module picker on commit, and shared with the machine_setups handler
---that mutates tags from the engine `on_gui_elem_changed` event so both
---paths stay in lockstep.
---@param dialog LuaGuiElement
---@param slot_index string
---@param beacon_index integer?
---@param new_typed_name TypedName?
function M.write_module_to_machine_setups(dialog, slot_index, beacon_index, new_typed_name)
    local dialog_tags = dialog.tags
    if beacon_index then
        local affected_by_beacon = dialog_tags.affected_by_beacons[beacon_index] --[[@as AffectedByBeacon]]
        affected_by_beacon.module_typed_names[slot_index] = new_typed_name
    else
        local module_typed_names = dialog_tags.module_typed_names --[[@as table<string, TypedName>]]
        module_typed_names[slot_index] = new_typed_name
    end
    dialog.tags = dialog_tags
    fs_util.dispatch_to_subtree(dialog, "on_module_changed")
end

---Writes a beacon entity selection into the `factory_solver_machine_setups`
---dialog's tags and dispatches `on_beacon_changed`. The existing
---`on_make_beacons_table` handler rebuilds the entire beacon row in response,
---so module slots whose index exceeds the new beacon's inventory size simply
---stop rendering — their tag entries are intentionally preserved so swapping
---back to a larger beacon restores them.
---@param dialog LuaGuiElement
---@param beacon_index integer
---@param new_typed_name TypedName?
function M.write_beacon_to_machine_setups(dialog, beacon_index, new_typed_name)
    local dialog_tags = dialog.tags
    local affected_by_beacon = dialog_tags.affected_by_beacons[beacon_index] --[[@as AffectedByBeacon]]
    affected_by_beacon.beacon_typed_name = new_typed_name
    dialog.tags = dialog_tags
    fs_util.dispatch_to_subtree(dialog, "on_beacon_changed")
end

---comment
---@param player_index integer
---@param is_dialog boolean
---@param gui_def fs.GuiElemDef
---@param append_data table?
---@return table<string, LuaGuiElement>
---@return LuaGuiElement
function M.open_gui(player_index, is_dialog, gui_def, append_data)
    local player = game.players[player_index]
    local opened_gui = storage.players[player_index].opened_gui
    local name = gui_def.name --[[@as string?]]
    local screen = player.gui.screen

    assert(name, "The name is required.")

    if screen[name] then
        local duplicate = screen[name]
        local event = fs_util.create_gui_event(duplicate)
        M.on_close_self(event)
    end

    if is_dialog then
        local sentinel_name = "%sentinel%" .. name
        local sentinel_def = {
            type = "empty-widget",
            name = sentinel_name,
            elem_mods = {
                location = { x = 0, y = 0 }
            },
            style_mods = {
                width = player.display_resolution.width,
                height = player.display_resolution.height,
            },
            tags = {
                close_target = name,
            },
            handler = {
                [defines.events.on_gui_click] = M.on_close_target,
            },
        }
        fs_util.add_gui(screen, sentinel_def)
        flib_table.insert(opened_gui, sentinel_name)
    end

    local elems, added = fs_util.add_gui(screen, gui_def, append_data)
    added.force_auto_center()
    player.opened = added
    flib_table.insert(opened_gui, name)

    return elems, added
end

---The top-level factory_solver windows that live directly under
---player.gui.screen. "Player-global" UI events (selected solution changed,
---etc.) must reach every one of them, not just the main window, now that the
---build assistant is a second independent root.
M.root_window_names = {
    "factory_solver_main_window",
    "factory_solver_build_assistant",
}

---Dispatch a UI event to every factory_solver root window the player currently
---has open. Use this for events that are global to the player's UI state (e.g.
---on_selected_solution_changed) so a second window like the build assistant
---stays in sync; per-window or dialog-local events should dispatch to their own
---subtree instead.
---@param player_index integer
---@param event_name string
---@param data table?
function M.broadcast(player_index, event_name, data)
    -- find_root_element searches every gui root, so this finds each window
    -- regardless of where it is docked (main window in gui.screen, build
    -- assistant in gui.left).
    for _, name in ipairs(M.root_window_names) do
        local window = M.find_root_element(player_index, name)
        if window then
            fs_util.dispatch_to_subtree(window, event_name, data)
        end
    end
end

---comment
---@param player_index integer
---@param name string
---@return LuaGuiElement?
function M.find_root_element(player_index, name)
    local player = game.players[player_index]
    for _, second_root in pairs(player.gui.children) do
        if second_root[name] then
            return second_root[name]
        end
    end
    return nil
end

---comment
---@param event EventDataTrait
function M.on_init_drag_target(event)
    local elem = event.element
    local target_name = elem.tags.drag_target --[[@as string]]
    local target = M.find_root_element(event.player_index, target_name)
    elem.drag_target = target
end

---comment
---@param event EventDataTrait
function M.on_close_self(event)
    local elem = event.element
    local player = game.players[event.player_index]
    local opened_gui = storage.players[event.player_index].opened_gui

    if elem.name == opened_gui[#opened_gui] then
        fs_util.dispatch_to_subtree(elem, "on_close")
        flib_table.remove(opened_gui)
        elem.destroy()
        if opened_gui[#opened_gui] then
            local target = assert(M.find_root_element(event.player_index, opened_gui[#opened_gui]))
            if event.name == defines.events.on_gui_closed or target.type == "empty-widget" then
                local re_event = flib_table.shallow_copy(event)
                re_event.element = target
                M.on_close_self(re_event)
            else
                player.opened = target
            end
        end
    end
end

---comment
---@param event EventDataTrait
function M.on_close_target(event)
    local elem = event.element
    local target_name = elem.tags.close_target --[[@as string]]

    local target = M.find_root_element(event.player_index, target_name)
    if target then
        local re_event = flib_table.shallow_copy(event)
        re_event.element = target
        M.on_close_self(re_event)
    end
end

---comment
---@param event EventDataTrait
function M.on_craft_visible_switch_added(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local is_show = player_data[elem.tags.state_name]

    if is_show then
        event.element.switch_state = "left"
    else
        event.element.switch_state = "right"
    end
end

---comment
---@param event EventData.on_gui_switch_state_changed
function M.on_craft_visible_switch_state_changed(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local is_show = event.element.switch_state == "left"
    player_data[elem.tags.state_name] = is_show

    local root = assert(fs_util.find_upper(elem, elem.tags.root_gui --[[@as string]]))
    fs_util.dispatch_to_subtree(root, "on_craft_visible_changed")
end

---Toggle the title-bar name-filter textfield's visibility. Shared by the
---constraint and production-line adders: the search button sits in the title bar
---next to the textfield, and the textfield starts hidden every time the dialog
---opens (no persisted filter). Showing it focuses the field so the player can
---type immediately; hiding it clears any active filter and re-renders the picker
---so a hidden field never silently constrains the results. Both dialogs keep the
---filter string in their root frame's `tags.filter_text` and rebuild on
---`on_filter_text_changed`, so this handler can drive either one. The root frame
---is the title bar's parent; the textfield is the title bar's only textfield.
---@param event EventData.on_gui_click
function M.on_toggle_name_filter(event)
    local button = event.element
    local title_bar = button.parent
    local root = title_bar.parent

    local textfield
    for _, sibling in pairs(title_bar.children) do
        if sibling.type == "textfield" then
            textfield = sibling
            break
        end
    end
    if not textfield then return end

    local visible = not textfield.visible
    textfield.visible = visible
    button.toggled = visible

    if visible then
        textfield.focus()
        textfield.select_all()
    elseif textfield.text ~= "" then
        textfield.text = ""
        local root_tags = root.tags
        root_tags.filter_text = ""
        root.tags = root_tags
        fs_util.dispatch_to_subtree(root, "on_filter_text_changed")
    end
end

fs_util.add_handlers(M)

return M
