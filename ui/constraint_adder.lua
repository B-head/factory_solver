local flib_table = require "__flib__/table"

local fs_util = require "fs_util"
local info = require "manage/info"
local save = require "manage/save"
local common = require "ui/common"
local production_line_adder = require "ui/production_line_adder"

local handlers = {}

---@param event EventDataTrait
function handlers.on_filter_type_tabbed_pane_added(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local relation = elem.tags.relation --[[@as (string[])]]

    local selected_tab_index = flib_table.find(relation, player_data.selected_filter_type)
    if selected_tab_index then
        elem.selected_tab_index = selected_tab_index
    else
        elem.selected_tab_index = 1
        player_data.selected_filter_type = elem.tags.relation[1]
    end
end

---@param event EventData.on_gui_selected_tab_changed
function handlers.on_filter_type_selected_tab_changed(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)

    player_data.selected_filter_type = elem.tags.relation[elem.selected_tab_index]

    local root = assert(fs_util.find_upper(event.element, "factory_solver_constraint_adder"))
    fs_util.dispatch_to_subtree(root, "on_filter_type_changed")
end

---@param event EventData.on_gui_click
function handlers.on_filter_group_click(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local filter_type = elem.tags.filter_type --[[@as FilterType]]
    local group_name = elem.tags.group_name --[[@as string]]

    player_data.selected_filter_group[filter_type] = group_name

    local root = assert(fs_util.find_upper(event.element, "factory_solver_constraint_adder"))
    fs_util.dispatch_to_subtree(root, "on_filter_group_changed")
end

---@param event EventDataTrait
function handlers.on_filter_group_change_toggle(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local filter_type = elem.tags.filter_type --[[@as FilterType]]
    local group_name = elem.tags.group_name --[[@as string]]

    elem.toggled = group_name == player_data.selected_filter_group[filter_type]
end

---@param event EventDataTrait
function handlers.on_make_filter_group(event)
    local elem = event.element
    local filter_type = elem.tags.filter_type --[[@as FilterType]]
    local player_data = save.get_player_data(event.player_index)
    local group_infos = save.get_group_infos(event.player_index, filter_type)
    local selected_filter_group = player_data.selected_filter_group


    local groups = fs_util.to_list(prototypes.item_group)
    groups = fs_util.sort_prototypes(groups)

    if not common.group_visible(group_infos, selected_filter_group[filter_type], player_data) then
        selected_filter_group[filter_type] = fs_util.find(group_infos, function(_, name)
            return common.group_visible(group_infos, name, player_data)
        end) or ""
    end

    elem.clear()
    for _, group in ipairs(groups) do
        if not common.group_visible(group_infos, group.name, player_data) then
            goto continue
        end

        local def = {
            type = "sprite-button",
            style = "factory_solver_filter_group_button",
            sprite = "item-group/" .. group.name,
            elem_tooltip = info.create_elem_id("item-group", group.name),
            tags = {
                filter_type = filter_type,
                group_name = group.name,
            },
            handler = {
                [defines.events.on_gui_click] = handlers.on_filter_group_click,
                on_added = handlers.on_filter_group_change_toggle,
                on_filter_group_changed = handlers.on_filter_group_change_toggle,
            },
        }
        fs_util.add_gui(elem, def)

        ::continue::
    end
end

---@param event EventDataTrait
function handlers.on_make_constraint_picker(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)
    local force = fs_util.get_force(event.player_index)

    ---comment
    ---@param typed_name TypedName
    ---@param is_hidden boolean
    ---@param is_unresearched boolean
    function add(typed_name, is_hidden, is_unresearched)
        if not common.craft_visible(is_hidden, is_unresearched, player_data) then
            return
        end

        local def = common.create_decorated_sprite_button{
            typed_name = typed_name,
            is_hidden = is_hidden,
            is_unresearched = is_unresearched,
            tags = {
                typed_name = typed_name,
            },
            handler = {
                [defines.events.on_gui_click] = handlers.on_constraint_picker_button_click,
            },
        }
        fs_util.add_gui(elem, def)
    end

    local filter_type = player_data.selected_filter_type
    local group = prototypes.item_group[player_data.selected_filter_group[filter_type]]
    local subgroups = {}
    if group then
        subgroups = fs_util.sort_prototypes(group.subgroups)
    end

    elem.clear()
    for _, subgroup in ipairs(subgroups) do
        if filter_type == "item" then
            local items = prototypes.get_item_filtered {
                { filter = "subgroup", subgroup = subgroup.name },
            }
            local sorted = fs_util.sort_prototypes(fs_util.to_list(items))

            for _, value in pairs(sorted) do
                if not value.parameter then
                    local is_hidden = info.is_hidden(value)
                    local is_unresearched = info.is_unresearched(value, relation_to_recipes)
                    local typed_name = info.craft_to_typed_name(value)
                    add(typed_name, is_hidden, is_unresearched)
                end
            end
        elseif filter_type == "fluid" then
            local fluids = prototypes.get_fluid_filtered {
                { filter = "subgroup", subgroup = subgroup.name },
            }
            local sorted = fs_util.sort_prototypes(fs_util.to_list(fluids))

            for _, value in pairs(sorted) do
                if not value.parameter then
                    local is_hidden = info.is_hidden(value)
                    local is_unresearched = info.is_unresearched(value, relation_to_recipes)
                    local typed_name = info.craft_to_typed_name(value)
                    add(typed_name, is_hidden, is_unresearched)
                end
            end
        elseif filter_type == "recipe" then
            local recipe_prototypes = prototypes.get_recipe_filtered {
                { filter = "subgroup", subgroup = subgroup.name },
            }
            local sorted = fs_util.sort_prototypes(fs_util.to_list(recipe_prototypes))

            for _, value in pairs(sorted) do
                if not prototypes.recipe[value.name].parameter then
                    local is_hidden = info.is_hidden(value)
                    local is_unresearched = info.is_unresearched(value, relation_to_recipes)
                    local typed_name = info.craft_to_typed_name(value)
                    add(typed_name, is_hidden, is_unresearched)
                end
            end
        elseif filter_type == "virtual_recipe" then
            ---@type (VirtualMaterial|VirtualRecipe)[]
            local virtuals = {}
            for _, value in pairs(storage.virtuals.material) do
                if value.subgroup_name == subgroup.name then
                    flib_table.insert(virtuals, value)
                end
            end
            for _, value in pairs(storage.virtuals.recipe) do
                if value.subgroup_name == subgroup.name then
                    flib_table.insert(virtuals, value)
                end
            end
            local sorted = fs_util.sort_prototypes(virtuals)

            for _, value in pairs(sorted) do
                local is_hidden = info.is_hidden(value)
                local is_unresearched = info.is_unresearched(value, relation_to_recipes)
                local typed_name = info.craft_to_typed_name(value)
                add(typed_name, is_hidden, is_unresearched)
            end
        else
            assert()
        end

        local column_count = elem.column_count
        local rest = #elem.children % column_count
        if 0 < rest then
            for _ = rest, column_count - 1, 1 do
                local def = {
                    type = "empty-widget",
                    style = "factory_solver_fake_slot",
                }
                fs_util.add_gui(elem, def)
            end
        end
    end
end

---@param event EventData.on_gui_click
function handlers.on_constraint_picker_button_click(event)
    local tags = event.element.tags
    local solution = assert(save.get_selected_solution(event.player_index))

    local typed_name = tags.typed_name --[[@as TypedName]]

    save.new_constraint(solution, typed_name)

    local dialog = assert(common.find_root_element(event.player_index, "factory_solver_constraint_adder"))
    local re_event = fs_util.create_gui_event(dialog)
    common.on_close_self(re_event)

    local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_constraint_changed")

    if typed_name.type == "recipe" or typed_name.type == "virtual_recipe" then
        save.new_production_line(event.player_index, solution, typed_name)

        fs_util.dispatch_to_subtree(root, "on_production_line_changed")
    else
        local data = {
            typed_name = typed_name,
            is_choose_product = true,
            is_choose_ingredient = true,
        }
        common.open_gui(event.player_index, true, production_line_adder, data)
    end
end

fs_util.add_handlers(handlers)

---@diagnostic disable: missing-fields
---@type flib.GuiElemDef
return {
    type = "frame",
    name = "factory_solver_constraint_adder",
    direction = "vertical",
    handler = {
        [defines.events.on_gui_closed] = common.on_close_self,
    },
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = "factory_solver_constraint_adder",
        },
        handler = {
            on_added = common.on_init_drag_target
        },
        {
            type = "label",
            style = "frame_title",
            caption = "Add constraint",
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
            tags = {
                close_target = "factory_solver_constraint_adder",
            },
            handler = {
                [defines.events.on_gui_click] = common.on_close_target
            },
        },
    },
    {
        type = "frame",
        style = "deep_frame_in_tabbed_pane",
        direction = "vertical",
        {
            type = "tabbed-pane",
            name = "filter_type_tabbed_pane",
            style = "factory_solver_filter_type_tabbed_pane",
            tags = {
                relation = {
                    "item",
                    "fluid",
                    "recipe",
                    "virtual_recipe",
                },
            },
            handler = {
                [defines.events.on_gui_selected_tab_changed] = handlers.on_filter_type_selected_tab_changed,
                on_added = handlers.on_filter_type_tabbed_pane_added,
            },
            {
                tab = {
                    type = "tab",
                    caption = "Item",
                },
                content = {
                    type = "frame",
                    style = "factory_solver_filter_group_background_frame",
                    {
                        type = "table",
                        name = "item_filter_group",
                        style = "slot_table",
                        column_count = 6,
                        tags = {
                            filter_type = "item",
                        },
                        handler = {
                            on_added = handlers.on_make_filter_group,
                            on_craft_visible_changed = handlers.on_make_filter_group,
                        },
                    },
                },
            },
            {
                tab = {
                    type = "tab",
                    caption = "Fluid",
                },
                content = {
                    type = "frame",
                    style = "factory_solver_filter_group_background_frame",
                    {
                        type = "table",
                        name = "fluid_filter_group",
                        style = "slot_table",
                        column_count = 6,
                        tags = {
                            filter_type = "fluid",
                        },
                        handler = {
                            on_added = handlers.on_make_filter_group,
                            on_craft_visible_changed = handlers.on_make_filter_group,
                        },
                    },
                },
            },
            {
                tab = {
                    type = "tab",
                    caption = "Recipe",
                },
                content = {
                    type = "frame",
                    style = "factory_solver_filter_group_background_frame",
                    {
                        type = "table",
                        name = "recipe_filter_group",
                        style = "slot_table",
                        column_count = 6,
                        tags = {
                            filter_type = "recipe",
                        },
                        handler = {
                            on_added = handlers.on_make_filter_group,
                            on_craft_visible_changed = handlers.on_make_filter_group,
                        },
                    },
                },
            },
            {
                tab = {
                    type = "tab",
                    caption = "Virtual",
                },
                content = {
                    type = "frame",
                    style = "factory_solver_filter_group_background_frame",
                    {
                        type = "table",
                        name = "recipe_filter_group",
                        style = "slot_table",
                        column_count = 6,
                        tags = {
                            filter_type = "virtual_recipe",
                        },
                        handler = {
                            on_added = handlers.on_make_filter_group,
                            on_craft_visible_changed = handlers.on_make_filter_group,
                        },
                    },
                },
            },
        },
        {
            type = "frame",
            style = "factory_solver_filter_picker_frame",
            direction = "vertical",
            {
                type = "scroll-pane",
                style = "factory_solver_filter_scroll_pane",
                horizontal_scroll_policy = "never",
                vertical_scroll_policy = "auto-and-reserve-space",
                {
                    type = "frame",
                    style = "factory_solver_filter_background_frame",
                    {
                        type = "table",
                        name = "constraint_picker",
                        style = "filter_slot_table",
                        column_count = 10,
                        handler = {
                            on_added = handlers.on_make_constraint_picker,
                            on_filter_type_changed = handlers.on_make_constraint_picker,
                            on_filter_group_changed = handlers.on_make_constraint_picker,
                            on_craft_visible_changed = handlers.on_make_constraint_picker,
                        },
                    },
                },
            },
            {
                type = "flow",
                style = "factory_solver_craft_visible_control_flow",
                {
                    type = "table",
                    name = "craft_visible_control",
                    style = "factory_solver_craft_visible_control_table",
                    column_count = 2,
                    {
                        type = "label",
                        caption = "Unresearched",
                    },
                    {
                        type = "switch",
                        name = "craft_visible_unresearched_switch",
                        switch_state = "right",
                        left_label_caption = "Show",
                        right_label_caption = "Hide",
                        tags = {
                            root_gui = "factory_solver_constraint_adder",
                            state_name = "unresearched_craft_visible",
                        },
                        handler = {
                            [defines.events.on_gui_switch_state_changed] = common
                                .on_craft_visible_switch_state_changed,
                            on_added = common.on_craft_visible_switch_added,
                        },
                    },
                    {
                        type = "label",
                        caption = "Hidden",
                    },
                    {
                        type = "switch",
                        name = "craft_visible_hidden_switch",
                        switch_state = "right",
                        left_label_caption = "Show",
                        right_label_caption = "Hide",
                        tags = {
                            root_gui = "factory_solver_constraint_adder",
                            state_name = "hidden_craft_visible",
                        },
                        handler = {
                            [defines.events.on_gui_switch_state_changed] = common
                                .on_craft_visible_switch_state_changed,
                            on_added = common.on_craft_visible_switch_added,
                        },
                    },
                },
            },
        },
    },
}
