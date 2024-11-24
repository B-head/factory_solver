local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local save = require "manage/save"
local tn = require "manage/typed_name"
local common = require "ui/common"

local handlers = {}

---@param event EventDataTrait
function handlers.on_make_machine_table(event)
    local elem = event.element
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local recipe_typed_name = dialog.tags.recipe_typed_name --[[@as TypedName]]
    local recipe = tn.typed_name_to_recipe(recipe_typed_name)
    local machines = acc.get_machines_for_recipe(recipe)

    elem.clear()
    for _, machine in ipairs(machines) do
        local typed_name = tn.craft_to_typed_name(machine)
        local is_hidden = acc.is_hidden(machine)
        local is_unresearched = acc.is_unresearched(machine, relation_to_recipes)

        local def = common.create_decorated_sprite_button {
            typed_name = typed_name,
            is_hidden = is_hidden,
            is_unresearched = is_unresearched,
            tags = {
                typed_name = typed_name,
            },
            handler = {
                [defines.events.on_gui_click] = handlers.on_machine_button_click,
                on_machine_setup_changed = handlers.on_machine_change_toggle,
            },
        }
        fs_util.add_gui(elem, def)
    end

    fs_util.dispatch_to_subtree(dialog, "on_machine_setup_changed")
end

---@param event EventData.on_gui_click
function handlers.on_machine_button_click(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local typed_name = elem.tags.typed_name --[[@as TypedName]]
    local dialog_tags = dialog.tags
    dialog_tags.machine_typed_name.type = typed_name.type
    dialog_tags.machine_typed_name.name = typed_name.name
    dialog.tags = dialog_tags

    fs_util.dispatch_to_subtree(dialog, "on_machine_setup_changed")
end

---@param event EventDataTrait
function handlers.on_machine_change_toggle(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local typed_name = elem.tags.typed_name --[[@as TypedName]]
    local machine_typed_name = dialog.tags.machine_typed_name --[[@as TypedName]]
    elem.toggled = tn.equals_typed_name(machine_typed_name, typed_name, true)
end

---@param event EventDataTrait
function handlers.on_make_machine_quality_dropdown(event)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))
    local initial_value = dialog.tags.machine_typed_name.quality --[[@as string]]

    common.make_quality_dropdown(event.element, initial_value)
end

---@param event EventData.on_gui_selection_state_changed
function handlers.on_machine_quality_state_changed(event)
    local elem = event.element
    local dictionary = elem.tags.dictionary
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local dialog_tags = dialog.tags
    dialog_tags.machine_typed_name.quality = dictionary[elem.selected_index]
    dialog.tags = dialog_tags
end

---@param event EventDataTrait
function handlers.on_modules_visible(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local machine_typed_name = dialog.tags.machine_typed_name --[[@as TypedName]]
    local machine = tn.typed_name_to_machine(machine_typed_name)
    elem.visible = 0 < machine.module_inventory_size
end

---@param event EventDataTrait
function handlers.on_make_machine_modules(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local module_typed_names = dialog.tags.module_typed_names --[[@as table<string, TypedName>]]
    local machine_typed_name = dialog.tags.machine_typed_name --[[@as TypedName]]
    local machine = tn.typed_name_to_machine(machine_typed_name)

    elem.clear()
    for index = 1, machine.module_inventory_size do
        local def = {
            type = "choose-elem-button",
            elem_type = "item-with-quality",
            elem_filters = {
                { filter = "type", type = "module" },
            },
            tags = {
                slot_index = tostring(index),
                beacon_index = nil,
            },
            handler = {
                [defines.events.on_gui_elem_changed] = handlers.on_module_changed,
            },
        }
        local _, added = fs_util.add_gui(elem, def)
        local typed_name = module_typed_names[tostring(index)]
        if typed_name then
            if tn.get_module(typed_name.name) then
                added.elem_value = { name = typed_name.name, quality = typed_name.quality }
            else
                added.elem_value = { name = "item-unknown", quality = typed_name.quality }
            end
        end
    end
end

---@param event EventData.on_gui_elem_changed
function handlers.on_module_changed(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))
    local dialog_tags = dialog.tags

    local slot_index = elem.tags.slot_index --[[@as string]]
    local beacon_index = elem.tags.beacon_index --[[@as integer?]]
    local elem_value = elem.elem_value --[[@as { name: string, quality: string }]]
    local new_typed_name = nil
    if elem_value then
        new_typed_name = tn.create_typed_name("item", elem_value.name, elem_value.quality)
    end

    if beacon_index then
        local affected_by_beacon = dialog_tags.affected_by_beacons[beacon_index] --[[@as AffectedByBeacon]]
        local module_typed_names = affected_by_beacon.module_typed_names

        module_typed_names[slot_index] = new_typed_name
    else
        local module_typed_names = dialog_tags.module_typed_names --[[@as table<string, TypedName>]]
        module_typed_names[slot_index] = new_typed_name
    end

    dialog.tags = dialog_tags
    fs_util.dispatch_to_subtree(dialog, "on_module_changed")
end

---@param event EventDataTrait
function handlers.on_make_beacons_table(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local affected_by_beacons = dialog.tags.affected_by_beacons --[[@as (AffectedByBeacon[])]]

    elem.clear()
    for beacon_index, affected_by_beacon in ipairs(affected_by_beacons) do
        local beacon_typed_name = affected_by_beacon.beacon_typed_name
        local beacon = beacon_typed_name and tn.get_beacon(beacon_typed_name.name)

        do
            local def = {
                type = "choose-elem-button",
                elem_type = "entity-with-quality",
                elem_filters = {
                    { filter = "type", type = "beacon" },
                },
                tags = {
                    beacon_index = beacon_index,
                },
                handler = {
                    [defines.events.on_gui_elem_changed] = handlers.on_beacon_changed,
                },
            }
            local _, added = fs_util.add_gui(elem, def)
            if beacon_typed_name then
                if beacon then
                    added.elem_value = { name = beacon_typed_name.name, quality = beacon_typed_name.quality }
                else
                    added.elem_value = { name = "entity-unknown", quality = beacon_typed_name.quality }
                end
            end
        end

        do
            local def = {
                type = "textfield",
                style = "factory_solver_beacon_quantity_textfield",
                numeric = true,
                allow_decimal = false,
                clear_and_focus_on_right_click = true,
                text = tostring(affected_by_beacon.beacon_quantity),
                tags = {
                    beacon_index = beacon_index,
                },
                handler = {
                    [defines.events.on_gui_text_changed] = handlers.on_beacon_quantity_confirmed,
                }
            }
            fs_util.add_gui(elem, def)
        end

        do
            local def = {
                type = "flow",
                direction = "horizontal",
            }
            local _, flow = fs_util.add_gui(elem, def)

            if beacon then
                local module_typed_names = affected_by_beacon.module_typed_names

                for slot_index = 1, beacon.module_inventory_size do
                    local def = {
                        type = "choose-elem-button",
                        elem_type = "item-with-quality",
                        elem_filters = {
                            { filter = "type", type = "module" },
                        },
                        tags = {
                            slot_index = tostring(slot_index),
                            beacon_index = beacon_index,
                        },
                        handler = {
                            [defines.events.on_gui_elem_changed] = handlers.on_module_changed,
                        },
                    }
                    local _, added = fs_util.add_gui(flow, def)
                    local typed_name = module_typed_names[tostring(slot_index)]
                    if typed_name then
                        if tn.get_module(typed_name.name) then
                            added.elem_value = { name = typed_name.name, quality = typed_name.quality }
                        else
                            added.elem_value = { name = "item-unknown", quality = typed_name.quality }
                        end
                    end
                end
            end
        end

        do
            local def = {
                type = "sprite-button",
                style = "mini_tool_button_red",
                sprite = "utility/close",
                hovered_sprite = "utility/close_black",
                clicked_sprite = "utility/close_black",
                tags = {
                    beacon_index = beacon_index,
                },
                handler = {
                    [defines.events.on_gui_click] = handlers.on_remove_beacon_click
                },
            }
            fs_util.add_gui(elem, def)
        end
    end
end

---@param event EventData.on_gui_click
function handlers.on_add_beacon_click(event)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))
    local dialog_tags = dialog.tags

    local affected_by_beacons = dialog_tags.affected_by_beacons --[[@as (AffectedByBeacon[])]]

    ---@type AffectedByBeacon
    local add_data = {
        beacon_typed_name = nil,
        beacon_quantity = 1,
        module_typed_names = {},
    }
    flib_table.insert(affected_by_beacons, add_data)

    dialog.tags = dialog_tags
    fs_util.dispatch_to_subtree(dialog, "on_beacon_changed")
end

---@param event EventData.on_gui_elem_changed
function handlers.on_beacon_changed(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))
    local dialog_tags = dialog.tags

    local elem_value = elem.elem_value --[[@as { name: string, quality: string }]]
    local beacon_index = elem.tags.beacon_index --[[@as integer]]
    local affected_by_beacon = dialog_tags.affected_by_beacons[beacon_index] --[[@as AffectedByBeacon]]
    if elem_value then
        affected_by_beacon.beacon_typed_name = tn.create_typed_name("machine", elem_value.name, elem_value.quality)
    else
        affected_by_beacon.beacon_typed_name = nil
    end

    dialog.tags = dialog_tags
    fs_util.dispatch_to_subtree(dialog, "on_beacon_changed")
end

---@param event EventData.on_gui_text_changed
function handlers.on_beacon_quantity_confirmed(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))
    local dialog_tags = dialog.tags

    local beacon_index = elem.tags.beacon_index --[[@as integer]]
    local affected_by_beacon = dialog_tags.affected_by_beacons[beacon_index] --[[@as AffectedByBeacon]]
    affected_by_beacon.beacon_quantity = tonumber(elem.text) or 0

    dialog.tags = dialog_tags
    fs_util.dispatch_to_subtree(dialog, "on_module_changed")
end

---@param event EventData.on_gui_click
function handlers.on_remove_beacon_click(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))
    local dialog_tags = dialog.tags

    local beacon_index = elem.tags.beacon_index --[[@as integer]]
    local affected_by_beacons = dialog_tags.affected_by_beacons --[[@as (AffectedByBeacon[])]]
    flib_table.remove(affected_by_beacons, beacon_index)

    dialog.tags = dialog_tags
    fs_util.dispatch_to_subtree(dialog, "on_beacon_changed")
end

---@param event EventDataTrait
function handlers.on_make_total_effectivity(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local machine_typed_name = dialog.tags.machine_typed_name --[[@as TypedName]]
    local machine = tn.typed_name_to_machine(machine_typed_name)
    local module_typed_names = dialog.tags.module_typed_names --[[@as table<string, TypedName>]]
    local affected_by_beacons = dialog.tags.affected_by_beacons --[[@as (AffectedByBeacon[])]]
    local total_modules = save.get_total_modules(machine, module_typed_names, affected_by_beacons)

    elem.clear()
    for name, inner in pairs(total_modules) do
        for quality, count in pairs(inner) do
            local module_typed_name = tn.create_typed_name("item", name, quality)

            local def = common.create_decorated_sprite_button {
                typed_name = module_typed_name,
                number = count,
            }
            fs_util.add_gui(elem, def)
        end
    end
end

---@param event EventDataTrait
function handlers.on_fuel_visible(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local machine_typed_name = dialog.tags.machine_typed_name --[[@as TypedName]]
    local machine = tn.typed_name_to_machine(machine_typed_name)
    local energy_source_type = acc.get_energy_source_type(machine)
    if energy_source_type == "burner" or energy_source_type == "fluid" then
        elem.visible = acc.try_get_fixed_fuel(machine) == nil
    else
        elem.visible = false
    end
end

---@param event EventDataTrait
function handlers.on_make_fuel_table(event)
    local elem = event.element
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))
    local dialog_tags = dialog.tags

    local machine_typed_name = dialog.tags.machine_typed_name --[[@as TypedName]]
    local machine = tn.typed_name_to_machine(machine_typed_name)
    local fuel_typed_name = dialog_tags.fuel_typed_name --[[@as TypedName?]]

    if not elem.visible then
        return
    end

    local fuel_categories = acc.try_get_fuel_categories(machine)
    local fuels
    if fuel_categories then
        fuels = acc.get_fuels_in_categories(fuel_categories)
    elseif acc.is_use_any_fluid_fuel(machine) then
        fuels = acc.get_any_fluid_fuels()
    end

    if fuels then
        local fuel_name = fuel_typed_name and fuel_typed_name.name
        local pos = fs_util.find(fuels, function(value)
            return value.name == fuel_name
        end)
        if not pos then
            fuel_typed_name = assert(save.get_fuel_preset(event.player_index, machine_typed_name))
            dialog_tags.fuel_typed_name = fuel_typed_name
        end

        elem.clear()
        for _, fuel in ipairs(fuels) do
            local typed_name = tn.craft_to_typed_name(fuel)
            local is_hidden = acc.is_hidden(fuel)
            local is_unresearched = acc.is_unresearched(fuel, relation_to_recipes)

            local def = common.create_decorated_sprite_button {
                typed_name = typed_name,
                is_hidden = is_hidden,
                is_unresearched = is_unresearched,
                tags = {
                    typed_name = typed_name,
                },
                handler = {
                    [defines.events.on_gui_click] = handlers.on_fuel_click,
                    on_fuel_setup_changed = handlers.on_fuel_change_toggle,
                },
            }
            fs_util.add_gui(elem, def)
        end
    end

    dialog.tags = dialog_tags
    fs_util.dispatch_to_subtree(dialog, "on_fuel_setup_changed")
end

---@param event EventData.on_gui_click
function handlers.on_fuel_click(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local dialog_tags = dialog.tags
    dialog_tags.fuel_typed_name = elem.tags.typed_name
    dialog.tags = dialog_tags

    fs_util.dispatch_to_subtree(dialog, "on_machine_setup_changed")
end

---@param event EventDataTrait
function handlers.on_fuel_change_toggle(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local typed_name = elem.tags.typed_name --[[@as TypedName]]
    local fuel_typed_name = dialog.tags.fuel_typed_name --[[@as TypedName]]
    elem.toggled = tn.equals_typed_name(fuel_typed_name, typed_name, true)
end

---@param event EventData.on_gui_click
function handlers.on_machine_setups_confirm(event)
    local solution = assert(save.get_selected_solution(event.player_index))
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local data = dialog.tags --[[@as ProductionLine]]
    local line_index = data.line_index --[[@as integer]]
    data.line_index = nil ---@diagnostic disable-line: inject-field

    save.update_production_line(solution, line_index, data)

    local re_event = fs_util.create_gui_event(dialog)
    common.on_close_self(re_event)

    local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_production_line_changed", data)
end

fs_util.add_handlers(handlers)

---@diagnostic disable: missing-fields
---@type flib.GuiElemDef
return {
    type = "frame",
    name = "factory_solver_machine_setups",
    direction = "vertical",
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = "factory_solver_machine_setups",
        },
        handler = {
            on_added = common.on_init_drag_target
        },
        {
            type = "label",
            style = "frame_title",
            caption = "Machine settings",
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
            type = "label",
            style = "caption_label",
            caption = "Machine",
        },
        {
            type = "frame",
            style = "factory_solver_slot_background_frame",
            {
                type = "table",
                style = "filter_slot_table",
                column_count = 6,
                handler = {
                    on_added = handlers.on_make_machine_table,
                },
            },
        },
        {
            type = "flow",
            style = "factory_solver_centering_horizontal_flow",
            direction = "horizontal",
            visible = script.feature_flags.quality,
            {
                type = "label",
                caption = "Quality",
            },
            {
                type = "drop-down",
                handler = {
                    on_added = handlers.on_make_machine_quality_dropdown,
                    [defines.events.on_gui_selection_state_changed] = handlers.on_machine_quality_state_changed,
                },
            },
        },
        {
            type = "line",
            style = "factory_solver_line",
        },
        {
            type = "flow",
            style = "factory_solver_no_spacing_vertical_flow_style",
            direction = "vertical",
            handler = {
                on_machine_setup_changed = handlers.on_modules_visible,
            },
            {
                type = "label",
                style = "caption_label",
                caption = "Modules",
            },
            {
                type = "flow",
                direction = "horizontal",
                handler = {
                    on_machine_setup_changed = handlers.on_make_machine_modules,
                },
            },
        },
        {
            type = "flow",
            style = "factory_solver_no_spacing_vertical_flow_style",
            direction = "vertical",
            {
                type = "label",
                style = "caption_label",
                caption = "Beacons",
            },
            {
                type = "table",
                style = "factory_solver_beacons_table",
                column_count = 4,
                draw_horizontal_lines = true,
                handler = {
                    on_added = handlers.on_make_beacons_table,
                    on_beacon_changed = handlers.on_make_beacons_table,
                },
            },
            {
                type = "button",
                caption = "Add beacon",
                handler = {
                    [defines.events.on_gui_click] = handlers.on_add_beacon_click,
                },
            },
        },
        {
            type = "flow",
            style = "factory_solver_no_spacing_vertical_flow_style",
            direction = "vertical",
            {
                type = "label",
                style = "caption_label",
                caption = "Total effectivity",
            },
            {
                type = "frame",
                style = "factory_solver_effectivity_slot_background_frame",
                {
                    type = "table",
                    style = "filter_slot_table",
                    column_count = 6,
                    handler = {
                        on_machine_setup_changed = handlers.on_make_total_effectivity,
                        on_beacon_changed = handlers.on_make_total_effectivity,
                        on_module_changed = handlers.on_make_total_effectivity,
                    },
                },
            },
        },
        {
            type = "flow",
            style = "factory_solver_no_spacing_vertical_flow_style",
            direction = "vertical",
            handler = {
                on_machine_setup_changed = handlers.on_fuel_visible,
            },
            {
                type = "line",
                style = "factory_solver_line",
            },
            {
                type = "label",
                style = "caption_label",
                caption = "Fuel",
            },
            {
                type = "frame",
                style = "factory_solver_slot_background_frame",
                {
                    type = "table",
                    style = "filter_slot_table",
                    column_count = 6,
                    handler = {
                        on_machine_setup_changed = handlers.on_make_fuel_table,
                    },
                },
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
                close_target = "factory_solver_machine_setups",
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
            caption = { "gui.confirm" },
            handler = {
                [defines.events.on_gui_click] = handlers.on_machine_setups_confirm,
            }
        },
    },
}
