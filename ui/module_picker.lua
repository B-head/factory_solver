local fs_util = require "fs_util"
local acc = require "manage/accessor"
local save = require "manage/save"
local tn = require "manage/typed_name"
local common = require "ui/common"

local handlers = {}

---Resolve the parent machine_setups dialog and read the (recipe, entity) pair
---this picker is filtering against. `entity` is the beacon when `beacon_index`
---is set on the picker, otherwise the machine the line is configured with.
---@param picker LuaGuiElement
---@return LuaGuiElement parent_dialog
---@return LuaRecipePrototype | VirtualRecipe recipe
---@return LuaEntityPrototype? entity
local function resolve_context(picker)
    local player_index = picker.player_index
    local parent_dialog = assert(common.find_root_element(player_index, "factory_solver_machine_setups"))
    local recipe_typed_name = parent_dialog.tags.recipe_typed_name --[[@as TypedName]]
    local recipe = tn.typed_name_to_recipe(recipe_typed_name)

    local beacon_index = picker.tags.beacon_index --[[@as integer?]]
    local entity
    if beacon_index then
        local affected_by_beacon = parent_dialog.tags.affected_by_beacons[beacon_index] --[[@as AffectedByBeacon]]
        local beacon_typed_name = affected_by_beacon.beacon_typed_name --[[@as TypedName?]]
        entity = beacon_typed_name and acc.get_beacon(beacon_typed_name.name)
    else
        local machine_typed_name = parent_dialog.tags.machine_typed_name --[[@as TypedName]]
        entity = tn.typed_name_to_machine(machine_typed_name)
    end
    return parent_dialog, recipe, entity
end

---@param event EventDataTrait
function handlers.on_make_module_grid(event)
    local elem = event.element
    local picker = assert(fs_util.find_upper(elem, "factory_solver_module_picker"))
    local player_data = save.get_player_data(event.player_index)
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)

    local _, recipe, entity = resolve_context(picker)
    local allowed_effects, allowed_categories
    if entity then
        allowed_effects = acc.get_allowed_effects(recipe, entity)
        allowed_categories = acc.get_allowed_module_categories(recipe, entity)
    else
        -- Beacon slot was empty when picker opened. Without a beacon to read
        -- allowed_* from we have no machine-side restriction, so treat
        -- everything as effective (recipe restriction can still drive grey,
        -- but with the entity missing the picker is informational anyway).
        allowed_effects = { speed = true, productivity = true, consumption = true,
                            pollution = true, quality = true }
        allowed_categories = nil
    end

    local groups = fs_util.sort_prototypes(fs_util.to_list(prototypes.item_group))

    elem.clear()
    for _, group in ipairs(groups) do
        local subgroups = fs_util.sort_prototypes(group.subgroups)
        for _, subgroup in ipairs(subgroups) do
            local modules = prototypes.get_item_filtered {
                { filter = "type", type = "module" },
                { filter = "subgroup", subgroup = subgroup.name, mode = "and" },
            }
            local sorted = fs_util.sort_prototypes(fs_util.to_list(modules))

            local emitted_in_subgroup = false
            for _, module in ipairs(sorted) do
                if module.parameter then goto continue end
                local is_hidden = acc.is_hidden(module)
                local is_unresearched = acc.is_unresearched(module, relation_to_recipes)
                if not common.craft_visible(is_hidden, is_unresearched, player_data) then
                    goto continue
                end

                local typed_name = tn.craft_to_typed_name(module)
                local is_effective = acc.is_module_effective(module, allowed_effects, allowed_categories)

                local def = common.create_decorated_sprite_button {
                    typed_name = typed_name,
                    is_hidden = is_hidden,
                    is_unresearched = is_unresearched,
                    top_right_sprite = (not is_effective) and "utility/warning_icon" or nil,
                    tags = {
                        module_name = module.name,
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_module_grid_click,
                    },
                }
                if not is_effective then
                    def.tooltip = { "", def.tooltip or "", "\n",
                        { "factory-solver-module-no-effect-here" } }
                end
                fs_util.add_gui(elem, def)
                emitted_in_subgroup = true

                ::continue::
            end

            if emitted_in_subgroup then
                local column_count = elem.column_count
                local rest = #elem.children % column_count
                if 0 < rest then
                    for _ = rest, column_count - 1, 1 do
                        fs_util.add_gui(elem, {
                            type = "empty-widget",
                            style = "factory_solver_fake_slot",
                        })
                    end
                end
            end
        end
    end
end

---@param event EventDataTrait
function handlers.on_make_module_picker_quality_row(event)
    local picker = assert(fs_util.find_upper(event.element, "factory_solver_module_picker"))
    local initial_value = picker.tags.current_quality --[[@as string?]] or "normal"
    common.make_quality_buttons(event.element, initial_value, handlers.on_module_picker_quality_clicked)
end

---@param event EventData.on_gui_click
function handlers.on_module_picker_quality_clicked(event)
    local quality_name = common.on_quality_button_clicked(event.element)
    local picker = assert(fs_util.find_upper(event.element, "factory_solver_module_picker"))
    local picker_tags = picker.tags
    picker_tags.current_quality = quality_name
    picker.tags = picker_tags
end

---@param event EventData.on_gui_click
function handlers.on_module_grid_click(event)
    if common.try_open_factoriopedia(event) then return end
    local elem = event.element
    local picker = assert(fs_util.find_upper(elem, "factory_solver_module_picker"))
    local parent_dialog = assert(common.find_root_element(event.player_index, "factory_solver_machine_setups"))

    local module_name = elem.tags.module_name --[[@as string]]
    local current_quality = picker.tags.current_quality --[[@as string?]] or "normal"
    local new_typed_name = tn.create_typed_name("item", module_name, current_quality)

    local slot_index = picker.tags.slot_index --[[@as string]]
    local beacon_index = picker.tags.beacon_index --[[@as integer?]]
    common.write_module_to_machine_setups(parent_dialog, slot_index, beacon_index, new_typed_name)

    local re_event = fs_util.create_gui_event(picker)
    common.on_close_self(re_event)
end

fs_util.add_handlers(handlers)

---@type fs.GuiElemDef
return {
    type = "frame",
    name = "factory_solver_module_picker",
    direction = "vertical",
    handler = {
        [defines.events.on_gui_closed] = common.on_close_self,
    },
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = "factory_solver_module_picker",
        },
        handler = {
            on_added = common.on_init_drag_target,
        },
        {
            type = "label",
            style = "frame_title",
            caption = { "factory-solver-module-picker-title" },
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
                close_target = "factory_solver_module_picker",
            },
            handler = {
                [defines.events.on_gui_click] = common.on_close_target,
            },
        },
    },
    {
        type = "frame",
        style = "factory_solver_filter_picker_frame",
        direction = "vertical",
        {
            type = "scroll-pane",
            style = "factory_solver_fit_filter_scroll_pane",
            horizontal_scroll_policy = "never",
            vertical_scroll_policy = "auto-and-reserve-space",
            {
                type = "frame",
                style = "factory_solver_slot_background_frame",
                {
                    type = "table",
                    name = "module_grid",
                    style = "filter_slot_table",
                    column_count = 10,
                    handler = {
                        on_added = handlers.on_make_module_grid,
                        on_craft_visible_changed = handlers.on_make_module_grid,
                    },
                },
            },
        },
        {
            type = "flow",
            style = "factory_solver_centering_horizontal_flow",
            style_mods = { horizontal_spacing = 0 },
            direction = "horizontal",
            visible = script.feature_flags.quality,
            handler = {
                on_added = handlers.on_make_module_picker_quality_row,
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
                        root_gui = "factory_solver_module_picker",
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
                        root_gui = "factory_solver_module_picker",
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
