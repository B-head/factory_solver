local flib_table = require "__flib__/table"
local flib_format = require "__flib__/format"

local fs_util = require "fs_util"
local common = require "ui/common"
local info = require "manage/info"
local save = require "manage/save"
local production_line_adder = require "ui/production_line_adder"

local handlers = {}

---@param event EventDataTrait
function handlers.make_final_products_table(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local solution = save.get_selected_solution(event.player_index)

    elem.clear()
    if not solution or type(solution.solver_state) == "number" then
        return
    end
    local item_totals, fluid_totals, virtual_totals = save.get_total_amounts(solution)

    local function add(typed_name, number)
        if number <= info.tolerance then
            return
        end
        number = info.to_scale(number, player_data.time_scale)

        local def = {
            type = "sprite-button",
            style = "flib_slot_button_default",
            sprite = info.get_sprite_path(typed_name),
            elem_tooltip = info.typed_name_to_elem_id(typed_name),
            number = number + info.tolerance,
            tags = {
                line_index = nil,
                typed_name = typed_name,
                is_product = true,
            },
            handler = {
                [defines.events.on_gui_click] = handlers.on_total_inout_click,
            },
        }
        fs_util.add_gui(elem, def)
    end

    for name, number in pairs(item_totals) do
        add(info.create_typed_name("item", name), number)
    end

    for name, number in pairs(fluid_totals) do
        add(info.create_typed_name("fluid", name), number)
    end

    for name, number in pairs(virtual_totals) do
        add(info.create_typed_name("virtual-object", name), number)
    end
end

---@param event EventDataTrait
function handlers.make_basic_ingredients_table(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local solution = save.get_selected_solution(event.player_index)

    elem.clear()
    if not solution or type(solution.solver_state) == "number" then
        return
    end
    local item_totals, fluid_totals, virtual_totals = save.get_total_amounts(solution)

    local function add(typed_name, number)
        if -info.tolerance <= number then
            return
        end
        number = info.to_scale(-number, player_data.time_scale)

        local def = {
            type = "sprite-button",
            style = "flib_slot_button_default",
            sprite = info.get_sprite_path(typed_name),
            elem_tooltip = info.typed_name_to_elem_id(typed_name),
            number = number + info.tolerance,
            tags = {
                line_index = nil,
                typed_name = typed_name,
                is_product = false,
            },
            handler = {
                [defines.events.on_gui_click] = handlers.on_total_inout_click,
            },
        }
        fs_util.add_gui(elem, def)
    end
    
    for name, number in pairs(item_totals) do
        add(info.create_typed_name("item", name), number)
    end

    for name, number in pairs(fluid_totals) do
        add(info.create_typed_name("fluid", name), number)
    end

    for name, number in pairs(virtual_totals) do
        add(info.create_typed_name("virtual-object", name), number)
    end
end

---@param event EventData.on_gui_click
function handlers.on_total_inout_click(event)
    local tags = event.element.tags
    local typed_name = tags.typed_name --[[@as TypedName]]
    if event.button == defines.mouse_button_type.left then
        local data = {
            typed_name = typed_name,
            is_choose_product = not tags.is_product,
            is_choose_ingredient = tags.is_product,
        }
        common.open_gui(event.player_index, true, production_line_adder, data)
    elseif event.button == defines.mouse_button_type.right then
        local solution = assert(save.get_selected_solution(event.player_index))
    
        save.new_constraint(solution, typed_name)

        local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
        fs_util.dispatch_to_subtree(root, "on_constraint_changed", data)
    end
end

---@param event EventDataTrait
function handlers.update_total_power_label(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local solution = save.get_selected_solution(event.player_index)

    if not solution then
        elem.caption = "0J"
        return
    end

    local total_power = info.to_scale(save.get_total_power(solution), player_data.time_scale)
    elem.caption = common.format_power(total_power)
end

---@param event EventDataTrait
function handlers.update_total_pollution_label(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local solution = save.get_selected_solution(event.player_index)

    if not solution then
        elem.caption = "0"
        return
    end

    local total_pollution = info.to_scale(save.get_total_pollution(solution), player_data.time_scale)
    elem.caption = flib_format.number(total_pollution, true, 5)
end

fs_util.add_handlers(handlers)

---@diagnostic disable: missing-fields
---@type flib.GuiElemDef
return {
    type = "frame",
    name = "solution_result",
    style = "inside_shallow_frame_with_padding",
    direction = "vertical",
    {
        type = "label",
        style = "caption_label",
        caption = "Final products",
    },
    {
        type = "frame",
        style = "factory_solver_result_slot_background_frame",
        {
            type = "table",
            style = "filter_slot_table",
            column_count = 8,
            handler = {
                on_added = handlers.make_final_products_table,
                on_selected_solution_changed = handlers.make_final_products_table,
                on_machine_setups_changed = handlers.make_final_products_table,
                on_amount_unit_changed = handlers.make_final_products_table,
                on_calculation_changed = handlers.make_final_products_table,
            },
        },
    },
    {
        type = "label",
        style = "caption_label",
        caption = "Basic ingredients",
    },
    {
        type = "frame",
        style = "factory_solver_result_slot_background_frame",
        {
            type = "table",
            style = "filter_slot_table",
            column_count = 8,
            handler = {
                on_added = handlers.make_basic_ingredients_table,
                on_selected_solution_changed = handlers.make_basic_ingredients_table,
                on_machine_setups_changed = handlers.make_basic_ingredients_table,
                on_amount_unit_changed = handlers.make_basic_ingredients_table,
                on_calculation_changed = handlers.make_basic_ingredients_table,
            },
        },
    },
    {
        type = "line",
        style = "factory_solver_line",
    },
    {
        type = "flow",
        style = "factory_solver_result_centering_flow",
        {
            type = "table",
            style = "factory_solver_result_layout_table",
            column_count = 2,
            {
                type = "label",
                style = "caption_label",
                caption = "Total power",
            },
            {
                type = "label",
                handler = {
                    on_added = handlers.update_total_power_label,
                    on_selected_solution_changed = handlers.update_total_power_label,
                    on_machine_setups_changed = handlers.update_total_power_label,
                    on_amount_unit_changed = handlers.update_total_power_label,
                    on_calculation_changed = handlers.update_total_power_label,
                },
            },
            {
                type = "label",
                style = "caption_label",
                caption = "Total pollution",
            },
            {
                type = "label",
                handler = {
                    on_added = handlers.update_total_pollution_label,
                    on_selected_solution_changed = handlers.update_total_pollution_label,
                    on_machine_setups_changed = handlers.update_total_pollution_label,
                    on_amount_unit_changed = handlers.update_total_pollution_label,
                    on_calculation_changed = handlers.update_total_pollution_label,
                },
            },
        },
    },
}
