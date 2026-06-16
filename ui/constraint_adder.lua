local flib_table = require "__flib__/table"
local flib_dictionary = require "__flib__/dictionary"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local save = require "manage/save"
local tn = require "manage/typed_name"
local common = require "ui/common"
local picker_build = require "ui/picker_build"
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
    if common.try_open_factoriopedia(event) then return end
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
        local first_visible = ""
        for _, group in ipairs(groups) do
            if common.group_visible(group_infos, group.name, player_data) then
                first_visible = group.name
                break
            end
        end
        selected_filter_group[filter_type] = first_visible
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
            elem_tooltip = tn.create_elem_id("item-group", group.name),
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

---Light handler: clear the picker and arm a tick-split build. The actual
---candidate enumeration + button construction (which for a large item-group is
---thousands of elements -- e.g. py-alienlife recipe = 3,650) runs across ticks via
---ui/picker_build (control.lua's on_tick -> picker_build.advance_all), so opening a
---tab / switching a group / typing in the filter never freezes the whole server
---under multiplayer lockstep. The selected type + group are captured into the
---request so a later rebuild that changes them just re-arms (cancel + restart).
---@param event EventDataTrait
function handlers.on_make_constraint_picker(event)
    local elem = event.element -- the constraint_picker table
    local player_data = save.get_player_data(event.player_index)
    local filter_type = player_data.selected_filter_type
    local group_name = player_data.selected_filter_group[filter_type]

    -- The name filter lives in the root frame's tags (dialog-local, resets on open).
    local dialog = assert(fs_util.find_upper(elem, "factory_solver_constraint_adder"))
    local raw_filter = dialog.tags.filter_text --[[@as string?]] or ""
    local needle = (raw_filter ~= "") and helpers.multilingual_to_lower(raw_filter) or ""

    elem.clear()
    picker_build.request(event.player_index, "constraint_picker", {
        spec_id = "constraint_adder",
        filter_type = filter_type,
        group_name = group_name,
        needle = needle,
        dialog_name = "factory_solver_constraint_adder",
    })
end

---@param event EventDataTrait
function handlers.on_make_craft_quality_buttons(event)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_constraint_adder"))
    local initial_value = "normal" --[[@as string]]

    common.make_quality_buttons(event.element, initial_value, handlers.on_craft_quality_clicked)

    local dialog_tags = dialog.tags
    dialog_tags.craft_quality = initial_value
    dialog.tags = dialog_tags
end

---@param event EventData.on_gui_click
function handlers.on_craft_quality_clicked(event)
    local quality_name = common.on_quality_button_clicked(event.element)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_constraint_adder"))

    local dialog_tags = dialog.tags
    dialog_tags.craft_quality = quality_name
    dialog.tags = dialog_tags
end

---@param event EventData.on_gui_click
function handlers.on_constraint_picker_button_click(event)
    if common.try_open_factoriopedia(event) then return end
    local tags = event.element.tags
    local solution = assert(save.get_selected_solution(event.player_index))
    local dialog = assert(common.find_root_element(event.player_index, "factory_solver_constraint_adder"))

    local typed_name = tags.typed_name --[[@as TypedName]]
    local craft_quality = dialog.tags.craft_quality --[[@as string]]
    if typed_name.type ~= "fluid" then
        typed_name.quality = craft_quality
    end

    save.new_constraint(solution, typed_name)

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

---@param event EventData.on_gui_text_changed
function handlers.on_constraint_filter_textfield_changed(event)
    local root = assert(fs_util.find_upper(event.element, "factory_solver_constraint_adder"))
    local root_tags = root.tags
    root_tags.filter_text = event.element.text
    root.tags = root_tags

    fs_util.dispatch_to_subtree(root, "on_filter_text_changed")
end

-- Tick-split spec for the single constraint_picker table. Unlike production_line_adder
-- (per-group sub-tables with sprite headers), this builds ONE flat filter_slot_table
-- whose subgroups are separated by padding to a row boundary; open_group / current_slot
-- therefore return the same table and close_group emits the per-subgroup padding (the
-- former inline padding loop). plan emits every candidate name in display order with its
-- subgroup as the grouping key; make_button applies the per-entry hidden / unresearched /
-- name-filter checks (so they spread across ticks too) and returns nil to skip.
picker_build.register_spec {
    id = "constraint_adder",

    find_table = function(player_index, req)
        local dialog = common.find_root_element(player_index, req.dialog_name)
        if not dialog then return nil end
        -- constraint_picker is found before its (built) buttons are descended into,
        -- so this never DFS-walks the thousands of slots already placed.
        return fs_util.find_lower(dialog, "constraint_picker")
    end,

    -- Single table: every group's buttons go into the same constraint_picker.
    open_group = function(player_index, req, constraint_picker, group_name)
        return constraint_picker
    end,

    current_slot = function(player_index, req, constraint_picker)
        return constraint_picker
    end,

    -- Pad the just-finished subgroup to a row boundary so the next subgroup starts on
    -- a fresh row (the former inline `#elem.children % column_count` fake-slot loop).
    close_group = function(player_index, req, constraint_picker)
        local column_count = constraint_picker.column_count
        local rest = #constraint_picker.children % column_count
        if 0 < rest then
            for _ = rest, column_count - 1, 1 do
                fs_util.add_gui(constraint_picker, {
                    type = "empty-widget",
                    style = "factory_solver_fake_slot",
                })
            end
        end
    end,

    plan = function(player_index, req)
        local filter_type = req.filter_type
        local group = prototypes.item_group[req.group_name]
        local subgroups = group and fs_util.sort_prototypes(group.subgroups) or {}

        -- Bucket storage.virtuals by subgroup once (virtual_recipe / external tabs),
        -- not per subgroup -- the same O(virtuals) fix as the synchronous path.
        local virtuals_by_subgroup
        if filter_type == "virtual_recipe" then
            virtuals_by_subgroup = {}
            for _, value in pairs(storage.virtuals.material) do
                local bucket = virtuals_by_subgroup[value.subgroup_name]
                if not bucket then bucket = {}; virtuals_by_subgroup[value.subgroup_name] = bucket end
                bucket[#bucket + 1] = value
            end
            for _, value in pairs(storage.virtuals.recipe) do
                if not (value.is_source or value.is_sink) then
                    local bucket = virtuals_by_subgroup[value.subgroup_name]
                    if not bucket then bucket = {}; virtuals_by_subgroup[value.subgroup_name] = bucket end
                    bucket[#bucket + 1] = value
                end
            end
        elseif filter_type == "external" then
            virtuals_by_subgroup = {}
            for _, value in pairs(storage.virtuals.recipe) do
                if value.is_source or value.is_sink then
                    local bucket = virtuals_by_subgroup[value.subgroup_name]
                    if not bucket then bucket = {}; virtuals_by_subgroup[value.subgroup_name] = bucket end
                    bucket[#bucket + 1] = value
                end
            end
        end

        local entries, group_of, is_material = {}, {}, {}
        for _, subgroup in ipairs(subgroups) do
            local sorted
            if filter_type == "item" then
                sorted = fs_util.sort_prototypes(fs_util.to_list(prototypes.get_item_filtered {
                    { filter = "subgroup", subgroup = subgroup.name },
                }))
            elseif filter_type == "fluid" then
                sorted = fs_util.sort_prototypes(fs_util.to_list(prototypes.get_fluid_filtered {
                    { filter = "subgroup", subgroup = subgroup.name },
                }))
            elseif filter_type == "recipe" then
                sorted = fs_util.sort_prototypes(fs_util.to_list(prototypes.get_recipe_filtered {
                    { filter = "subgroup", subgroup = subgroup.name },
                }))
            else -- virtual_recipe / external
                sorted = fs_util.sort_prototypes(virtuals_by_subgroup[subgroup.name] or {})
            end

            for _, value in ipairs(sorted) do
                -- Blueprint-parameter placeholders must never be pickable (item / fluid
                -- / recipe carry .parameter; virtuals never do).
                local is_parameter = false
                if filter_type == "item" or filter_type == "fluid" then
                    is_parameter = value.parameter
                elseif filter_type == "recipe" then
                    is_parameter = prototypes.recipe[value.name].parameter
                end
                if not is_parameter then
                    entries[#entries + 1] = value.name
                    group_of[#group_of + 1] = subgroup.name
                    if filter_type == "virtual_recipe" then
                        -- material / recipe names share one namespace; identity against
                        -- storage.virtuals.material is collision-proof (value is the very
                        -- object bucketed from one of the two stores).
                        is_material[#is_material + 1] = storage.virtuals.material[value.name] == value
                    end
                end
            end
        end
        ---@type PickerBuildPlan
        return { entries = entries, group_of = group_of, is_material = is_material }
    end,

    make_button = function(player_index, req, plan, i)
        local name = plan.entries[i]
        local filter_type = req.filter_type

        local value
        if filter_type == "item" then
            value = prototypes.item[name]
        elseif filter_type == "fluid" then
            value = prototypes.fluid[name]
        elseif filter_type == "recipe" then
            value = prototypes.recipe[name]
        elseif filter_type == "virtual_recipe" then
            value = plan.is_material[i] and storage.virtuals.material[name] or storage.virtuals.recipe[name]
        elseif filter_type == "external" then
            value = storage.virtuals.recipe[name]
        end
        if not value then return nil end

        local relation_to_recipes = save.get_relation_to_recipes(player_index)
        local player_data = save.get_player_data(player_index)
        local is_hidden = acc.is_hidden(value)
        local is_unresearched = acc.is_unresearched(value, relation_to_recipes)
        if not common.craft_visible(is_hidden, is_unresearched, player_data) then
            return nil
        end
        local needle = req.needle or ""
        if needle ~= "" then
            local dict_name = (filter_type == "item" and "item")
                or (filter_type == "fluid" and "fluid")
                or (filter_type == "recipe" and "recipe")
                or "virtual" -- virtual_recipe / external both draw from storage.virtuals
            local dict = flib_dictionary.get(player_index, dict_name)
            -- name is the enumerated craft / entry name (the dictionary key), which
            -- differs from typed_name.name for fluid-temperature virtual materials.
            if not common.name_filter_matches(needle, name, dict and dict[name] or nil) then
                return nil
            end
        end

        local typed_name = tn.craft_to_typed_name(value)
        return common.create_decorated_sprite_button {
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
    end,
}

fs_util.add_handlers(handlers)

---@type fs.GuiElemDef
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
            caption = { "factory-solver-add-constraint" },
            ignored_by_interaction = true,
        },
        {
            type = "empty-widget",
            style = "flib_titlebar_drag_handle",
            ignored_by_interaction = true,
        },
        {
            type = "textfield",
            name = "constraint_filter_textfield",
            style = "flib_titlebar_search_textfield",
            visible = false,
            clear_and_focus_on_right_click = true,
            tooltip = { "factory-solver-name-filter-tooltip" },
            handler = {
                [defines.events.on_gui_text_changed] = handlers.on_constraint_filter_textfield_changed,
            },
        },
        {
            type = "sprite-button",
            style = "frame_action_button",
            sprite = "utility/search",
            hovered_sprite = "utility/search",
            clicked_sprite = "utility/search",
            handler = {
                [defines.events.on_gui_click] = common.on_toggle_name_filter,
            },
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
        type = "label",
        style = "factory_solver_dialog_description_label",
        caption = { "factory-solver-desc-constraint-adder" },
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
                    "external",
                },
            },
            handler = {
                [defines.events.on_gui_selected_tab_changed] = handlers.on_filter_type_selected_tab_changed,
                on_added = handlers.on_filter_type_tabbed_pane_added,
            },
            {
                tab = {
                    type = "tab",
                    style = "factory_solver_filter_group_tab",
                    caption = { "factory-solver-item" },
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
                    style = "factory_solver_filter_group_tab",
                    caption = { "factory-solver-fluid" },
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
                    style = "factory_solver_filter_group_tab",
                    caption = { "factory-solver-recipe" },
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
                    style = "factory_solver_filter_group_tab",
                    caption = { "factory-solver-virtual" },
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
            {
                tab = {
                    type = "tab",
                    style = "factory_solver_filter_group_tab",
                    caption = { "factory-solver-external" },
                },
                content = {
                    type = "frame",
                    style = "factory_solver_filter_group_background_frame",
                    {
                        type = "table",
                        name = "external_filter_group",
                        style = "slot_table",
                        column_count = 6,
                        tags = {
                            filter_type = "external",
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
                type = "flow",
                style = "factory_solver_centering_vertical_flow",
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
                                on_filter_text_changed = handlers.on_make_constraint_picker,
                            },
                        },
                    },
                },
                {
                    type = "flow",
                    style_mods = { horizontal_spacing = 0, horizontally_stretchable = true },
                    direction = "horizontal",
                    visible = script.feature_flags.quality,
                    handler = {
                        on_added = handlers.on_make_craft_quality_buttons,
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
                            caption = { "factory-solver-unresearched" },
                        },
                        {
                            type = "switch",
                            name = "craft_visible_unresearched_switch",
                            switch_state = "right",
                            left_label_caption = { "factory-solver-show" },
                            right_label_caption = { "factory-solver-hide" },
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
                            caption = { "factory-solver-hidden" },
                        },
                        {
                            type = "switch",
                            name = "craft_visible_hidden_switch",
                            switch_state = "right",
                            left_label_caption = { "factory-solver-show" },
                            right_label_caption = { "factory-solver-hide" },
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
    },
}
