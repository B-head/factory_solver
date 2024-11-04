local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local save = require "manage/save"
local tn = require "manage/typed_name"
local common = require "ui/common"

local handlers = {}

---@param event EventDataTrait
function handlers.on_memorize_machine_presets(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)

    elem.tags = {
        fuel_presets = flib_table.deep_copy(player_data.fuel_presets),
        machine_presets = flib_table.deep_copy(player_data.machine_presets),
    }
end

---@param event EventDataTrait
function handlers.on_make_fuel_presets(event)
    local elem = event.element
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)

    for category_name, _ in pairs(prototypes.fuel_category) do
        local fuels = acc.get_fuels_in_categories { [category_name] = true }
        if #fuels <= 1 then
            goto continue
        end

        do
            local def = {
                type = "label",
                caption = category_name,
            }
            fs_util.add_gui(elem, def)
        end

        do
            local def_buttons = {}
            for _, value in pairs(fuels) do
                local typed_name = tn.craft_to_typed_name(value)
                local is_hidden = acc.is_hidden(value)
                local is_unresearched = acc.is_unresearched(value, relation_to_recipes)

                local def = common.create_decorated_sprite_button {
                    typed_name = typed_name,
                    is_hidden = is_hidden,
                    is_unresearched = is_unresearched,
                    tags = {
                        typed_name = typed_name,
                        category_name = category_name,
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_fuel_preset_button_click,
                        on_fuel_preset_changed = handlers.on_fuel_preset_change_toggle,
                    },
                }
                flib_table.insert(def_buttons, def)
            end

            local def_table = {
                type = "frame",
                style = "factory_solver_slot_background_frame",
                {
                    type = "table",
                    style = "filter_slot_table",
                    column_count = 6,
                    children = def_buttons,
                },
            }
            fs_util.add_gui(elem, def_table)
        end
        ::continue::
    end

    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))
    fs_util.dispatch_to_subtree(dialog, "on_fuel_preset_changed")
end

---@param event EventDataTrait
function handlers.on_make_machine_presets(event)
    local elem = event.element
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)

    for category_name, _ in pairs(prototypes.recipe_category) do
        local machines = acc.get_machines_in_category(category_name)
        if #machines <= 1 then
            goto continue
        end

        do
            local def = {
                type = "label",
                caption = category_name,
            }
            fs_util.add_gui(elem, def)
        end

        do
            local def_buttons = {}
            for _, machine in pairs(machines) do
                local typed_name = tn.craft_to_typed_name(machine)
                local is_hidden = acc.is_hidden(machine)
                local is_unresearched = acc.is_unresearched(machine, relation_to_recipes)

                local def = common.create_decorated_sprite_button {
                    typed_name = typed_name,
                    is_hidden = is_hidden,
                    is_unresearched = is_unresearched,
                    tags = {
                        typed_name = typed_name,
                        category_name = category_name,
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_machine_preset_button_click,
                        on_machine_preset_changed = handlers.on_machine_preset_change_toggle,
                    },
                }
                flib_table.insert(def_buttons, def)
            end

            local def_table = {
                type = "frame",
                style = "factory_solver_slot_background_frame",
                {
                    type = "table",
                    style = "filter_slot_table",
                    column_count = 6,
                    children = def_buttons,
                },
            }
            fs_util.add_gui(elem, def_table)
        end
        ::continue::
    end

    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))
    fs_util.dispatch_to_subtree(dialog, "on_machine_preset_changed")
end

---@param event EventData.on_gui_click
function handlers.on_fuel_preset_button_click(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))

    local dialog_tags = dialog.tags
    local fuel_presets = dialog_tags.fuel_presets
    fuel_presets[elem.tags.category_name] = elem.tags.typed_name
    dialog.tags = dialog_tags

    fs_util.dispatch_to_subtree(dialog, "on_fuel_preset_changed")
end

---@param event EventData.on_gui_click
function handlers.on_machine_preset_button_click(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))

    local dialog_tags = dialog.tags
    local machine_presets = dialog_tags.machine_presets
    machine_presets[elem.tags.category_name] = elem.tags.typed_name
    dialog.tags = dialog_tags

    fs_util.dispatch_to_subtree(dialog, "on_machine_preset_changed")
end

---@param event EventDataTrait
function handlers.on_fuel_preset_change_toggle(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))
    local typed_name = elem.tags.typed_name --[[@as TypedName]]
    local fuel_presets = dialog.tags.fuel_presets

    elem.toggled = tn.equals_typed_name(fuel_presets[elem.tags.category_name], typed_name)
end

---@param event EventDataTrait
function handlers.on_machine_preset_change_toggle(event)
    local elem = event.element
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))
    local typed_name = elem.tags.typed_name --[[@as TypedName]]
    local machine_presets = dialog.tags.machine_presets

    elem.toggled = tn.equals_typed_name(machine_presets[elem.tags.category_name], typed_name)
end

---@param event EventData.on_gui_click
function handlers.on_machine_presets_confirm(event)
    local player_data = save.get_player_data(event.player_index)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))

    player_data.fuel_presets = dialog.tags.fuel_presets --[[@as table<string, TypedName>]]
    player_data.machine_presets = dialog.tags.machine_presets --[[@as table<string, TypedName>]]

    local re_event = fs_util.create_gui_event(dialog)
    common.on_close_self(re_event)
end

fs_util.add_handlers(handlers)

---@diagnostic disable: missing-fields
---@type flib.GuiElemDef
return {
    type = "frame",
    name = "factory_solver_machine_presets",
    direction = "vertical",
    handler = {
        on_added = handlers.on_memorize_machine_presets,
    },
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = "factory_solver_machine_presets",
        },
        handler = {
            on_added = common.on_init_drag_target
        },
        {
            type = "label",
            style = "frame_title",
            caption = "Machine presets",
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
        style = "inside_shallow_frame",
        {
            type = "scroll-pane",
            style = "factory_solver_preset_scroll_pane",
            direction = "vertical",
            horizontal_scroll_policy = "never",
            vertical_scroll_policy = "always",
            {
                type = "frame",
                style = "factory_solver_shallow_frame_in_shallow_frame",
                direction = "vertical",
                {
                    type = "label",
                    style = "caption_label",
                    caption = "Fuels",
                },
                {
                    type = "table",
                    style = "factory_solver_preset_layout_table",
                    column_count = 2,
                    handler = {
                        on_added = handlers.on_make_fuel_presets,
                    },
                },
            },
            {
                type = "frame",
                style = "factory_solver_shallow_frame_in_shallow_frame",
                direction = "vertical",
                {
                    type = "label",
                    style = "caption_label",
                    caption = "Machines",
                },
                {
                    type = "table",
                    style = "factory_solver_preset_layout_table",
                    column_count = 2,
                    handler = {
                        on_added = handlers.on_make_machine_presets,
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
                close_target = "factory_solver_machine_presets",
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
                [defines.events.on_gui_click] = handlers.on_machine_presets_confirm,
            }
        },
    },
}
