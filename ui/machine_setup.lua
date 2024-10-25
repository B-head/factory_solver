local flib_table = require "__flib__/table"

local fs_util = require "fs_util"
local common = require "ui/common"
local info = require "manage/info"
local save = require "manage/save"

local handlers = {}

---@param event EventDataTrait
function handlers.on_make_machine_table(event)
    local elem = event.element
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local recipe_typed_name = dialog.tags.recipe_typed_name --[[@as TypedName]]
    local recipe = info.typed_name_to_recipe(recipe_typed_name)
    local machines = info.get_machines_in_category(recipe.category)

    elem.clear()
    for _, machine in pairs(machines) do
        local typed_name = info.craft_to_typed_name(machine)
        local is_hidden = info.is_hidden(machine)
        local is_unresearched = info.is_unresearched(machine, relation_to_recipes)

        local def = {
            type = "sprite-button",
            style = common.get_style(is_hidden, is_unresearched, typed_name.type),
            sprite = info.get_sprite_path(typed_name),
            elem_tooltip = info.typed_name_to_elem_id(typed_name),
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
    dialog_tags.machine_typed_name = typed_name
    dialog.tags = dialog_tags

    fs_util.dispatch_to_subtree(dialog, "on_machine_setup_changed")
end

---@param event EventDataTrait
function handlers.on_machine_change_toggle(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local typed_name = elem.tags.typed_name --[[@as TypedName]]
    local machine_typed_name = dialog.tags.machine_typed_name --[[@as TypedName]]
    elem.toggled = info.equals_typed_name(machine_typed_name, typed_name)
end

---@param event EventDataTrait
function handlers.on_modules_visible(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local machine_typed_name = dialog.tags.machine_typed_name --[[@as TypedName]]
    local machine = info.typed_name_to_machine(machine_typed_name)
    elem.visible = 0 < machine.module_inventory_size
end

---@param event EventDataTrait
function handlers.on_make_machine_modules(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local module_names = dialog.tags.module_names --[[@as table<string, string>]]
    local machine_typed_name = dialog.tags.machine_typed_name --[[@as TypedName]]
    local machine = info.typed_name_to_machine(machine_typed_name)

    elem.clear()
    for index = 1, machine.module_inventory_size do
        local module_name = module_names[tostring(index)]
        if module_name and not info.get_module(module_name) then
            module_name = "item-unknown"
        end

        local def = {
            type = "choose-elem-button",
            elem_type = "item",
            item = module_name,
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
        fs_util.add_gui(elem, def)
    end
end

---@param event EventData.on_gui_elem_changed
function handlers.on_module_changed(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))
    local dialog_tags = dialog.tags

    local slot_index = elem.tags.slot_index --[[@as string]]
    local beacon_index = elem.tags.beacon_index --[[@as integer?]]

    if beacon_index then
        local affected_by_beacon = dialog_tags.affected_by_beacons[beacon_index] --[[@as AffectedByBeacon]]
        affected_by_beacon.module_names[slot_index] = elem.elem_value --[[@as string]]
    else
        local module_names = dialog_tags.module_names --[[@as table<string, string>]]
        module_names[slot_index] = elem.elem_value --[[@as string]]
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
        local beacon_name = affected_by_beacon.beacon_name
        local beacon = info.get_beacon(beacon_name)

        do
            if beacon_name and not beacon then
                beacon_name = "entity-unknown"
            end

            local def = {
                type = "choose-elem-button",
                elem_type = "entity",
                entity = beacon_name,
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
            fs_util.add_gui(elem, def)
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
            local children = {}

            if beacon then
                local module_names = affected_by_beacon.module_names

                for slot_index = 1, beacon.module_inventory_size do
                    local module_name = module_names[tostring(slot_index)]
                    if module_name and not info.get_module(module_name) then
                        module_name = "item-unknown"
                    end

                    local def = {
                        type = "choose-elem-button",
                        elem_type = "item",
                        item = module_name,
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
                    flib_table.insert(children, def)
                end
            end

            local def = {
                type = "flow",
                direction = "horizontal",
                children = children,
            }
            fs_util.add_gui(elem, def)
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
        beacon_name = nil,
        beacon_quantity = 1,
        module_names = {},
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

    local beacon_index = elem.tags.beacon_index --[[@as integer]]
    local affected_by_beacon = dialog_tags.affected_by_beacons[beacon_index] --[[@as AffectedByBeacon]]
    affected_by_beacon.beacon_name = elem.elem_value --[[@as string]]

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
    local machine = info.typed_name_to_machine(machine_typed_name)
    local module_names = dialog.tags.module_names --[[@as table<string, string>]]
    local affected_by_beacons = dialog.tags.affected_by_beacons --[[@as (AffectedByBeacon[])]]
    local total_modules = info.get_total_modules(machine, module_names, affected_by_beacons)

    elem.clear()
    for name, count in pairs(total_modules) do
        local module_typed_name = info.create_typed_name("item", name)

        local def = {
            type = "sprite-button",
            style = common.get_style(false, false, module_typed_name.type),
            sprite = info.get_sprite_path(module_typed_name),
            elem_tooltip = info.typed_name_to_elem_id(module_typed_name),
            number = count,
        }
        fs_util.add_gui(elem, def)
    end
end

---@param event EventDataTrait
function handlers.on_fuel_visible(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))

    local machine_typed_name = dialog.tags.machine_typed_name --[[@as TypedName]]
    local machine = info.typed_name_to_machine(machine_typed_name)
    elem.visible = info.get_energy_source_type(machine) == "burner"
end

---@param event EventDataTrait
function handlers.on_make_fuel_table(event)
    local elem = event.element
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_setups"))
    local dialog_tags = dialog.tags

    local machine_typed_name = dialog.tags.machine_typed_name --[[@as TypedName]]
    local machine = info.typed_name_to_machine(machine_typed_name)

    local fuel_typed_name = dialog_tags.fuel_typed_name --[[@as TypedName?]]
    if not fuel_typed_name then
        fuel_typed_name = save.get_fuel_preset(event.player_index, machine_typed_name)
    end

    local fuel_categories = info.try_get_fuel_categories(machine)
    if fuel_categories then
        local fuels = info.get_fuels_in_categories(fuel_categories)

        assert(fuel_typed_name)
        local pos = fs_util.find(fuels, function(value)
            return value.name == fuel_typed_name.name
        end)
        if not pos then
            fuel_typed_name = save.get_fuel_preset(event.player_index, machine_typed_name)
        end

        elem.clear()
        for _, fuel in pairs(fuels) do
            local typed_name = info.craft_to_typed_name(fuel)
            local is_hidden = info.is_hidden(fuel)
            local is_unresearched = info.is_unresearched(fuel, relation_to_recipes)

            local def = {
                type = "sprite-button",
                style = common.get_style(is_hidden, is_unresearched, typed_name.type),
                sprite = info.get_sprite_path(typed_name),
                elem_tooltip = info.typed_name_to_elem_id(typed_name),
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

    ---@diagnostic disable-next-line: assign-type-mismatch
    dialog_tags.fuel_typed_name = fuel_typed_name
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
    elem.toggled = info.equals_typed_name(fuel_typed_name, typed_name)
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
