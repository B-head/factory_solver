local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local save = require "manage/save"
local tn = require "manage/typed_name"
local common = require "ui/common"

local handlers = {}

---@param event EventDataTrait
function handlers.on_init_choose_visiblity(event)
    local elem = event.element
    local dialog = assert(common.find_root_element(event.player_index, "factory_solver_production_line_adder"))
    local dialog_tags = dialog.tags

    local kind = elem.tags.kind --[[@as string]]
    local typed_name = dialog_tags.typed_name --[[@as TypedName]]
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)

    local relation_to_recipe
    if typed_name.type == "item" then
        relation_to_recipe = relation_to_recipes.item[typed_name.name]
    elseif typed_name.type == "fluid" then
        relation_to_recipe = relation_to_recipes.fluid[typed_name.name]
    elseif typed_name.type == "virtual_material" then
        relation_to_recipe = relation_to_recipes.virtual_recipe[typed_name.name]
    else
        assert()
    end

    if kind == "product" then
        elem.visible = dialog_tags.is_choose_product and 0 < #relation_to_recipe.recipe_for_product
    elseif kind == "ingredient" then
        elem.visible = dialog_tags.is_choose_ingredient and 0 < #relation_to_recipe.recipe_for_ingredient
    elseif kind == "fuel" then
        elem.visible = dialog_tags.is_choose_ingredient and 0 < #relation_to_recipe.recipe_for_fuel
    else
        assert()
    end
end

---@param event EventDataTrait
function handlers.on_make_choose_table(event)
    local elem = event.element
    local dialog = assert(common.find_root_element(event.player_index, "factory_solver_production_line_adder"))
    local dialog_tags = dialog.tags

    local player_data = save.get_player_data(event.player_index)
    local kind = elem.tags.kind --[[@as string]]
    local choose_typed_name = dialog_tags.typed_name --[[@as TypedName]]
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)

    local relation_to_recipe
    if choose_typed_name.type == "item" then
        relation_to_recipe = relation_to_recipes.item[choose_typed_name.name]
    elseif choose_typed_name.type == "fluid" then
        relation_to_recipe = relation_to_recipes.fluid[choose_typed_name.name]
    elseif choose_typed_name.type == "virtual_material" then
        relation_to_recipe = relation_to_recipes.virtual_recipe[choose_typed_name.name]
    else
        assert()
    end

    local recipe_names
    if kind == "product" then
        recipe_names = relation_to_recipe.recipe_for_product
    elseif kind == "ingredient" then
        recipe_names = relation_to_recipe.recipe_for_ingredient
    elseif kind == "fuel" then
        recipe_names = relation_to_recipe.recipe_for_fuel
    else
        assert()
    end

    local used_recipes = flib_table.map(recipe_names, function(name)
        return assert(storage.virtuals.recipe[name] or prototypes.recipe[name])
    end) --[=[@as (LuaRecipePrototype | VirtualRecipe)[]]=]

    local grouped = fs_util.group_by(used_recipes, function(value)
        if value.group then
            return value.group.name
        else
            return value.group_name
        end
    end) --[=[@as table<string, (LuaRecipePrototype | VirtualRecipe)[]>]=]

    local groups = fs_util.to_list(prototypes.item_group)
    groups = fs_util.sort_prototypes(groups)

    elem.clear()
    for _, group in ipairs(groups) do
        local group_name = group.name

        local group_recipes = grouped[group_name] or {}
        local subgrouped = fs_util.group_by(group_recipes, function(value)
            if value.subgroup then
                return value.subgroup.name
            else
                return value.subgroup_name
            end
        end) --[=[@as table<string, (LuaRecipePrototype | VirtualRecipe)[]>]=]

        local subgroups = fs_util.to_list(group.subgroups)
        subgroups = fs_util.sort_prototypes(subgroups)

        local def_buttons = {}
        for _, subgroup in ipairs(subgroups) do
            local subgroup_recipes = subgrouped[subgroup.name] or {}
            local sorted = fs_util.sort_prototypes(fs_util.to_list(subgroup_recipes))
            for _, recipe in ipairs(sorted) do
                local typed_name = tn.craft_to_typed_name(recipe)
                local is_hidden = acc.is_hidden(recipe)
                local is_unresearched = acc.is_unresearched(recipe, relation_to_recipes)
                if not common.craft_visible(is_hidden, is_unresearched, player_data) then
                    goto inner_continue
                end

                local def = common.create_decorated_sprite_button {
                    typed_name = typed_name,
                    is_hidden = is_hidden,
                    is_unresearched = is_unresearched,
                    tags = {
                        recipe_typed_name = typed_name,
                        kind = kind
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_production_line_picker_button_click,
                    },
                }
                flib_table.insert(def_buttons, def)
            end

            ::inner_continue::
        end

        if #def_buttons == 0 then
            goto outer_continue
        end

        local def_sprite = {
            type = "sprite",
            style = "factory_solver_group_sprite",
            sprite = "item-group/" .. group_name,
            resize_to_sprite = false,
            tooltip = group.localised_name,
        }
        fs_util.add_gui(elem, def_sprite)

        local def_table = {
            type = "frame",
            style = "factory_solver_recipe_slot_background_frame",
            {
                type = "table",
                style = "filter_slot_table",
                column_count = 6,
                children = def_buttons,
            },
        }
        fs_util.add_gui(elem, def_table)

        ::outer_continue::
    end
end

---@param event EventData.on_gui_click
function handlers.on_production_line_picker_button_click(event)
    local tags = event.element.tags
    local solution = assert(save.get_selected_solution(event.player_index))
    local dialog = assert(common.find_root_element(event.player_index, "factory_solver_production_line_adder"))

    local recipe_typed_name = tags.recipe_typed_name --[[@as TypedName]]
    local line_index = dialog.tags.line_index --[[@as integer?]]
    local kind = tags.kind --[[@as string]]
    local typed_name = dialog.tags.typed_name --[[@as TypedName]]

    local fuel_typed_name = (kind == "fuel") and typed_name or nil
    save.new_production_line(event.player_index, solution, recipe_typed_name, fuel_typed_name, line_index)

    local re_event = fs_util.create_gui_event(dialog)
    common.on_close_self(re_event)

    local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_production_line_changed")
end

fs_util.add_handlers(handlers)

---@diagnostic disable: missing-fields
---@type flib.GuiElemDef
return {
    type = "frame",
    name = "factory_solver_production_line_adder",
    direction = "vertical",
    handler = {
        [defines.events.on_gui_closed] = common.on_close_self,
    },
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = "factory_solver_production_line_adder",
        },
        handler = {
            on_added = common.on_init_drag_target
        },
        {
            type = "label",
            style = "frame_title",
            caption = "Add production line",
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
                close_target = "factory_solver_production_line_adder",
            },
            handler = {
                [defines.events.on_gui_click] = common.on_close_target
            },
        },
    },
    {
        type = "frame",
        style = "inside_shallow_frame_with_padding",
        direction = "vertical",
        {
            type = "flow",
            {
                type = "frame",
                name = "recipe_for_product",
                style = "flib_shallow_frame_in_shallow_frame",
                direction = "vertical",
                visible = false,
                tags = {
                    kind = "product",
                },
                handler = {
                    on_added = handlers.on_init_choose_visiblity,
                },
                {
                    type = "scroll-pane",
                    style = "factory_solver_scroll_pane",
                    horizontal_scroll_policy = "never",
                    vertical_scroll_policy = "auto-and-reserve-space",
                    {
                        type = "label",
                        style = "caption_label",
                        caption = "Recipe for product",
                    },
                    {
                        type = "table",
                        style = "factory_solver_choose_table",
                        column_count = 2,
                        draw_horizontal_lines = true,
                        tags = {
                            kind = "product",
                        },
                        handler = {
                            on_added = handlers.on_make_choose_table,
                            on_craft_visible_changed = handlers.on_make_choose_table,
                        },
                    },
                },
            },
            {
                type = "frame",
                name = "recipe_for_ingredient",
                style = "flib_shallow_frame_in_shallow_frame",
                direction = "vertical",
                visible = false,
                tags = {
                    kind = "ingredient",
                },
                handler = {
                    on_added = handlers.on_init_choose_visiblity,
                },
                {
                    type = "scroll-pane",
                    style = "factory_solver_scroll_pane",
                    horizontal_scroll_policy = "never",
                    vertical_scroll_policy = "auto-and-reserve-space",
                    {
                        type = "label",
                        style = "caption_label",
                        caption = "Recipe for ingredient",
                    },
                    {
                        type = "table",
                        style = "factory_solver_choose_table",
                        column_count = 2,
                        draw_horizontal_lines = true,
                        tags = {
                            kind = "ingredient",
                        },
                        handler = {
                            on_added = handlers.on_make_choose_table,
                            on_craft_visible_changed = handlers.on_make_choose_table,
                        },
                    },
                },
            },
            {
                type = "frame",
                name = "recipe_for_fuel",
                style = "flib_shallow_frame_in_shallow_frame",
                direction = "vertical",
                visible = false,
                tags = {
                    kind = "fuel",
                },
                handler = {
                    on_added = handlers.on_init_choose_visiblity,
                },
                {
                    type = "scroll-pane",
                    style = "factory_solver_scroll_pane",
                    horizontal_scroll_policy = "never",
                    vertical_scroll_policy = "auto-and-reserve-space",
                    {
                        type = "label",
                        style = "caption_label",
                        caption = "Recipe for fuel",
                    },
                    {
                        type = "table",
                        style = "factory_solver_choose_table",
                        column_count = 2,
                        draw_horizontal_lines = true,
                        tags = {
                            kind = "fuel",
                        },
                        handler = {
                            on_added = handlers.on_make_choose_table,
                            on_craft_visible_changed = handlers.on_make_choose_table,
                        },
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
                        root_gui = "factory_solver_production_line_adder",
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
                        root_gui = "factory_solver_production_line_adder",
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
}
