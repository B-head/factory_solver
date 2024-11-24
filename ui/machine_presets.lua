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
        presets = flib_table.deep_copy(player_data.presets),
    }
end

---@param event EventDataTrait
function handlers.on_make_preset_tables(event)
    local elem = event.element
    local preset_type = elem.tags.preset_type
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)

    local categories
    if preset_type == "fuel" then
        categories = storage.virtuals.fuel_categories_dictionary
    elseif preset_type == "fluid_fuel" then
        categories = { ["<any-fluid-fuel>"] = true }
    elseif preset_type == "resource" then
        categories = prototypes.resource_category
    elseif preset_type == "machine" then
        categories = prototypes.recipe_category
    else
        assert()
    end

    for category_name, value in pairs(categories) do
        local crafts
        if preset_type == "fuel" then
            crafts = acc.get_fuels_in_categories(value --[[@as { [string]: true }]])
        elseif preset_type == "fluid_fuel" then
            crafts = acc.get_any_fluid_fuels()
        elseif preset_type == "resource" then
            crafts = acc.get_machines_in_resource_category(category_name)
        elseif preset_type == "machine" then
            crafts = acc.get_machines_in_category(category_name)
        else
            assert()
        end

        if #crafts <= 1 then
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
            for _, value in pairs(crafts) do
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
                        preset_type = preset_type,
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_preset_button_click,
                        on_preset_changed = handlers.on_preset_change_toggle,
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
    fs_util.dispatch_to_subtree(dialog, "on_preset_changed")
end

---@param event EventData.on_gui_click
function handlers.on_preset_button_click(event)
    local elem = event.element
    local typed_name = elem.tags.typed_name --[[@as TypedName]]
    local category_name = elem.tags.category_name
    local preset_type = elem.tags.preset_type
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))

    local dialog_tags = dialog.tags
    if preset_type == "fuel" then
        dialog_tags.presets.fuel[category_name] = typed_name
    elseif preset_type == "fluid_fuel" then
        dialog_tags.presets.fluid_fuel = typed_name
    elseif preset_type == "resource" then
        dialog_tags.presets.resource[category_name] = typed_name
    elseif preset_type == "machine" then
        dialog_tags.presets.machine[category_name] = typed_name
    else
        assert()
    end

    dialog.tags = dialog_tags
    fs_util.dispatch_to_subtree(dialog, "on_preset_changed")
end

---@param event EventDataTrait
function handlers.on_preset_change_toggle(event)
    local elem = event.element
    local typed_name = elem.tags.typed_name --[[@as TypedName]]
    local category_name = elem.tags.category_name
    local preset_type = elem.tags.preset_type
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))

    local dialog_tags = dialog.tags
    local preset
    if preset_type == "fuel" then
        preset = dialog_tags.presets.fuel[category_name]
    elseif preset_type == "fluid_fuel" then
        preset = dialog_tags.presets.fluid_fuel
    elseif preset_type == "resource" then
        preset = dialog_tags.presets.resource[category_name]
    elseif preset_type == "machine" then
        preset = dialog_tags.presets.machine[category_name]
    end
    assert(preset)

    elem.toggled = tn.equals_typed_name(preset, typed_name)
end

---@param event EventData.on_gui_click
function handlers.on_machine_presets_confirm(event)
    local player_data = save.get_player_data(event.player_index)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))

    player_data.presets = dialog.tags.presets --[[@as Presets]]

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
                    tags = {
                        preset_type = "fuel",
                    },
                    handler = {
                        on_added = handlers.on_make_preset_tables,
                    },
                },
                {
                    type = "table",
                    style = "factory_solver_preset_layout_table",
                    column_count = 2,
                    tags = {
                        preset_type = "fluid_fuel",
                    },
                    handler = {
                        on_added = handlers.on_make_preset_tables,
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
                    caption = "Minings",
                },
                {
                    type = "table",
                    style = "factory_solver_preset_layout_table",
                    column_count = 2,
                    tags = {
                        preset_type = "resource",
                    },
                    handler = {
                        on_added = handlers.on_make_preset_tables,
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
                    tags = {
                        preset_type = "machine",
                    },
                    handler = {
                        on_added = handlers.on_make_preset_tables,
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
