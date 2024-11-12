local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local save = require "manage/save"
local tn = require "manage/typed_name"
local common = require "ui/common"
local constraint_adder = require "ui/constraint_adder"
local production_line_adder = require "ui/production_line_adder"

local limit_type_to_index = {
    ["upper"] = 1,
    ["lower"] = 2,
    ["equal"] = 3,
}

local handlers = {}

---@param event EventData.on_gui_click
function handlers.on_add_constraint_click(event)
    common.open_gui(event.player_index, true, constraint_adder)
end

---@param event EventDataTrait
function handlers.on_make_constraints_table(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local solution = save.get_selected_solution(event.player_index)

    elem.clear()
    if not solution then
        return
    end

    for index, data in ipairs(solution.constraints) do
        do
            local typed_name = tn.create_typed_name(data.type, data.name, data.quality)

            local def = common.create_decorated_sprite_button{
                typed_name = typed_name,
                tags = data,
                handler = {
                    [defines.events.on_gui_click] = handlers.on_constraint_button_click,
                },
            }
            fs_util.add_gui(elem, def)
        end

        do
            local amount = data.limit_amount_per_second
            if not (data.type == "recipe" or data.type == "virtual_recipe") then
                amount = acc.to_scale(amount, player_data.time_scale)
            end
            local def = {
                type = "textfield",
                style = "factory_solver_limit_amount_textfield",
                numeric = true,
                allow_decimal = true,
                clear_and_focus_on_right_click = true,
                text = tostring(amount),
                tags = data,
                handler = {
                    [defines.events.on_gui_text_changed] = handlers.on_limit_amount_confirmed,
                }
            }
            fs_util.add_gui(elem, def)
        end

        do
            local limit_index = limit_type_to_index[data.limit_type]
            local def = {
                type = "drop-down",
                style = "factory_solver_limit_type_dropdown",
                selected_index = limit_index,
                items = {
                    "Upper limit",
                    "Lower limit",
                    "Equal",
                },
                tags = data,
                handler = {
                    [defines.events.on_gui_selection_state_changed] = handlers.on_limit_type_changed,
                }
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
                    constraint_index = index,
                },
                handler = {
                    [defines.events.on_gui_click] = handlers.on_remove_constraint_click
                },
            }
            fs_util.add_gui(elem, def)
        end
    end
end

---@param event EventData.on_gui_click
function handlers.on_constraint_button_click(event)
    local tags = event.element.tags
    local solution = assert(save.get_selected_solution(event.player_index))

    local typed_name = tn.create_typed_name(tags.type --[[@as FilterType]], tags.name --[[@as string]])

    if typed_name.type == "recipe" or typed_name.type == "virtual_recipe" then
        save.new_production_line(event.player_index, solution, typed_name)

        local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
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

---@param event EventDataTrait
function handlers.on_add_constraint_button_enabled(event)
    local elem = event.element
    local solution = save.get_selected_solution(event.player_index)

    elem.enabled = solution ~= nil
end

---@param event EventData.on_gui_text_changed
function handlers.on_limit_amount_confirmed(event)
    local elem = event.element
    local tags = elem.tags
    local typed_name = tn.create_typed_name(tags.type --[[@as FilterType]], tags.name --[[@as string]])
    local player_data = save.get_player_data(event.player_index)
    local solution = assert(save.get_selected_solution(event.player_index))

    local pos = assert(fs_util.find(solution.constraints, function(value)
        return tn.equals_typed_name(value, typed_name)
    end))
    local amount = tonumber(elem.text) or 0
    if not (typed_name.type == "recipe" or typed_name.type == "virtual_recipe") then
        amount = acc.from_scale(amount, player_data.time_scale)
    end

    save.update_constraint(solution, pos, { limit_amount_per_second = amount })
end

---@param event EventData.on_gui_selection_state_changed
function handlers.on_limit_type_changed(event)
    local elem = event.element
    local tags = elem.tags
    local typed_name = tn.create_typed_name(tags.type --[[@as FilterType]], tags.name --[[@as string]])
    local solution = assert(save.get_selected_solution(event.player_index))

    local pos = assert(fs_util.find(solution.constraints, function(value)
        return tn.equals_typed_name(value, typed_name)
    end))
    local limit_type = flib_table.find(limit_type_to_index, elem.selected_index)

    save.update_constraint(solution, pos, { limit_type = limit_type })
end

---@param event EventData.on_gui_click
function handlers.on_remove_constraint_click(event)
    local tags = event.element.tags
    local solution = assert(save.get_selected_solution(event.player_index))

    save.delete_constraint(solution, tags.constraint_index --[[@as integer]])

    local root = assert(fs_util.find_upper(event.element, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_constraint_changed")
end

fs_util.add_handlers(handlers)

---@diagnostic disable: missing-fields
---@type flib.GuiElemDef
return {
    type = "frame",
    name = "solution_settings",
    style = "inside_shallow_frame_with_padding",
    direction = "vertical",
    {
        type = "label",
        style = "caption_label",
        caption = "Constraints",
    },
    {
        type = "table",
        style = "factory_solver_constraints_table",
        column_count = 4,
        draw_horizontal_lines = true,
        handler = {
            on_added = handlers.on_make_constraints_table,
            on_selected_solution_changed = handlers.on_make_constraints_table,
            on_constraint_changed = handlers.on_make_constraints_table,
            on_amount_unit_changed = handlers.on_make_constraints_table,
        },
    },
    {
        type = "button",
        caption = "Add constraint",
        handler = {
            [defines.events.on_gui_click] = handlers.on_add_constraint_click,
            on_added = handlers.on_add_constraint_button_enabled,
            on_selected_solution_changed = handlers.on_add_constraint_button_enabled,
        },
    },
}
