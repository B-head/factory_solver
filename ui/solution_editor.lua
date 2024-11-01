local flib_table = require "__flib__/table"
local flib_format = require "__flib__/format"

local fs_util = require "fs_util"
local common = require "ui/common"
local info = require "manage/info"
local save = require "manage/save"
local production_line_adder = require "ui/production_line_adder"
local machine_setup = require "ui/machine_setup"

local headers = {
    "",
    "Recipe",
    "Required",
    "Machine",
    "Products",
    "Ingredients",
    "Power",
    "Pollution",
    "",
}

local handlers = {}

---@param event EventDataTrait
function handlers.make_production_line_table(event)
    local elem = event.element
    local force = fs_util.get_force(event.player_index)
    local solution = save.get_selected_solution(event.player_index)
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)

    elem.clear()
    if not solution then
        return
    elseif #solution.production_lines == 0 then
        return
    end

    for _, value in ipairs(headers) do
        local def = {
            type = "label",
            style = "bold_label",
            caption = value,
        }
        fs_util.add_gui(elem, def)
    end

    for line_index, line in ipairs(solution.production_lines) do
        local recipe = info.typed_name_to_recipe(line.recipe_typed_name)
        local machine = info.typed_name_to_machine(line.machine_typed_name)
        local craft_energy = assert(recipe.energy)
        local crafting_speed = info.get_crafting_speed(machine, line.machine_typed_name.quality)
        local module_counts = info.get_total_modules(machine, line.module_typed_names, line.affected_by_beacons)
        local effectivity = info.get_total_effectivity(module_counts)
        local recipe_tags = flib_table.deep_merge { { line_index = line_index }, line }

        do
            local def = {
                type = "flow",
                direction = "vertical",
                {
                    type = "sprite-button",
                    style = "mini_button",
                    sprite = "utility/speed_up",
                    tags = {
                        line_index = line_index,
                        direction = "up",
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_move_production_line_click,
                    },
                },
                {
                    type = "sprite-button",
                    style = "mini_button",
                    sprite = "utility/speed_down",
                    tags = {
                        line_index = line_index,
                        direction = "down",
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_move_production_line_click,
                    },
                },
            }
            fs_util.add_gui(elem, def)
        end

        do
            local typed_name = line.recipe_typed_name
            local is_hidden = info.is_hidden(recipe)
            local is_unresearched = info.is_unresearched(recipe, relation_to_recipes)

            local def = {
                type = "sprite-button",
                style = common.get_style(is_hidden, is_unresearched, typed_name.type),
                sprite = info.get_sprite_path(typed_name),
                elem_tooltip = info.typed_name_to_elem_id(typed_name),
                tags = recipe_tags,
                handler = {
                    [defines.events.on_gui_click] = handlers.on_production_line_recipe_click,
                },
            }
            fs_util.add_gui(elem, def)
        end

        do
            local def = {
                type = "label",
                tags = {
                    result_key = line.recipe_typed_name.name,
                },
                handler = {
                    on_added = handlers.update_machines_required,
                    on_amount_unit_changed = handlers.update_machines_required,
                    on_calculation_changed = handlers.update_machines_required,
                },
            }
            fs_util.add_gui(elem, def)
        end

        do
            local buttons = {}
            local machine_typed_name = line.machine_typed_name
            local is_hidden = info.is_hidden(machine)
            local is_unresearched = info.is_unresearched(machine, relation_to_recipes)

            do
                local def = {
                    type = "sprite-button",
                    style = common.get_style(is_hidden, is_unresearched, machine_typed_name.type),
                    sprite = info.get_sprite_path(machine_typed_name),
                    elem_tooltip = info.typed_name_to_elem_id(machine_typed_name),
                    tags = recipe_tags,
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_production_line_recipe_click,
                    },
                }
                flib_table.insert(buttons, def)
            end

            local total_modules = info.get_total_modules(machine, line.module_typed_names, line.affected_by_beacons)

            for name, inner in pairs(total_modules) do
                for quality, count in pairs(inner) do
                    local module_typed_name = info.create_typed_name("item", name, quality)

                    local def = {
                        type = "sprite-button",
                        style = common.get_style(false, false, module_typed_name.type),
                        sprite = info.get_sprite_path(module_typed_name),
                        elem_tooltip = info.typed_name_to_elem_id(module_typed_name),
                        number = count,
                        tags = recipe_tags,
                        handler = {
                            [defines.events.on_gui_click] = handlers.on_production_line_recipe_click,
                        },
                    }
                    flib_table.insert(buttons, def)
                end
            end

            local def = {
                type = "flow",
                children = buttons,
            }
            fs_util.add_gui(elem, def)
        end

        do
            local buttons = {}
            for _, value in pairs(recipe.products) do
                local typed_name = info.create_typed_name(value.type, value.name)
                local craft = info.typed_name_to_material(typed_name)
                local is_hidden = info.is_hidden(craft)
                local is_unresearched = info.is_unresearched(craft, relation_to_recipes)
                local raw_amount = info.raw_product_to_amount(value, craft_energy, crafting_speed,
                    effectivity.speed, effectivity.productivity)

                local def = {
                    type = "sprite-button",
                    style = common.get_style(is_hidden, is_unresearched, typed_name.type),
                    sprite = info.get_sprite_path(typed_name),
                    elem_tooltip = info.typed_name_to_elem_id(typed_name),
                    tags = {
                        line_index = line_index,
                        typed_name = typed_name,
                        is_product = true,
                        result_key = line.recipe_typed_name.name,
                        raw_amount = raw_amount,
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_production_line_inout_click,
                        on_added = handlers.update_amount,
                        on_amount_unit_changed = handlers.update_amount,
                        on_calculation_changed = handlers.update_amount,
                    },
                }
                flib_table.insert(buttons, def)
            end

            local def = {
                type = "flow",
                children = buttons,
            }
            fs_util.add_gui(elem, def)
        end

        do
            local buttons = {}
            for _, value in pairs(recipe.ingredients) do
                local typed_name = info.create_typed_name(value.type, value.name)
                local craft = info.typed_name_to_material(typed_name)
                local is_hidden = info.is_hidden(craft)
                local is_unresearched = info.is_unresearched(craft, relation_to_recipes)
                local raw_amount = info.raw_ingredient_to_amount(value, craft_energy, crafting_speed, effectivity.speed)

                local def = {
                    type = "sprite-button",
                    style = common.get_style(is_hidden, is_unresearched, typed_name.type),
                    sprite = info.get_sprite_path(typed_name),
                    elem_tooltip = info.typed_name_to_elem_id(typed_name),
                    tags = {
                        line_index = line_index,
                        typed_name = typed_name,
                        is_product = false,
                        result_key = line.recipe_typed_name.name,
                        raw_amount = raw_amount,
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_production_line_inout_click,
                        on_added = handlers.update_amount,
                        on_amount_unit_changed = handlers.update_amount,
                        on_calculation_changed = handlers.update_amount,
                    },
                }
                flib_table.insert(buttons, def)
            end

            local def = {
                type = "flow",
                children = buttons,
            }
            fs_util.add_gui(elem, def)
        end

        do
            local children = {}

            local power = info.raw_energy_to_power(machine, "normal", effectivity.consumption)

            if not info.is_use_fuel(machine) or info.is_generator(machine) then
                local def = {
                    type = "label",
                    tags = {
                        result_key = line.recipe_typed_name.name,
                        raw_amount = power,
                    },
                    handler = {
                        on_added = handlers.update_power,
                        on_amount_unit_changed = handlers.update_power,
                        on_calculation_changed = handlers.update_power,
                    },
                }
                flib_table.insert(children, def)
            end

            if info.is_use_fuel(machine) then
                local fuel_typed_name = assert(line.fuel_typed_name)
                local fuel = info.typed_name_to_material(fuel_typed_name)
                local is_hidden = info.is_hidden(fuel)
                local is_unresearched = info.is_unresearched(fuel, relation_to_recipes)
                local amount_per_second = info.get_fuel_amount_per_second(power, fuel, machine)

                if info.is_generator(machine) then
                    amount_per_second = -amount_per_second
                end

                local def = {
                    type = "sprite-button",
                    style = common.get_style(is_hidden, is_unresearched, fuel_typed_name.type),
                    sprite = info.get_sprite_path(fuel_typed_name),
                    elem_tooltip = info.typed_name_to_elem_id(fuel_typed_name),
                    tags = {
                        line_index = line_index,
                        typed_name = fuel_typed_name,
                        is_product = false,
                        result_key = line.recipe_typed_name.name,
                        raw_amount = amount_per_second,
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_production_line_inout_click,
                        on_added = handlers.update_amount,
                        on_amount_unit_changed = handlers.update_amount,
                        on_calculation_changed = handlers.update_amount,
                    },
                }
                flib_table.insert(children, def)
            end

            local def = {
                type = "flow",
                style = "factory_solver_centering_horizontal_flow",
                children = children,
            }
            fs_util.add_gui(elem, def)
        end

        do
            local pollution = info.raw_emission_to_pollution(machine, "pollution", line.machine_typed_name.quality,
                effectivity.consumption, effectivity.pollution)

            if info.is_use_fuel(machine) then
                local fuel = info.typed_name_to_material(line.fuel_typed_name)
                pollution = pollution * info.get_fuel_emissions_multiplier(fuel)
            end

            local def = {
                type = "label",
                tags = {
                    result_key = line.recipe_typed_name.name,
                    raw_amount = pollution,
                },
                handler = {
                    on_added = handlers.update_pollution,
                    on_amount_unit_changed = handlers.update_pollution,
                    on_calculation_changed = handlers.update_pollution,
                },
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
                    line_index = line_index,
                },
                handler = {
                    [defines.events.on_gui_click] = handlers.on_remove_production_line
                },
            }
            fs_util.add_gui(elem, def)
        end
    end
end

---@param event EventDataTrait
function handlers.update_machines_required(event)
    local elem = event.element
    local tags = elem.tags
    local solution = assert(save.get_selected_solution(event.player_index))

    local result_key = tags.result_key --[[@as string]]
    local quantity_of_machines_required = save.get_quantity_of_machines_required(solution, result_key)
    elem.caption = flib_format.number(quantity_of_machines_required, false, 5)
end

---@param event EventDataTrait
function handlers.update_amount(event)
    local elem = event.element
    local tags = elem.tags
    local player_data = save.get_player_data(event.player_index)
    local solution = assert(save.get_selected_solution(event.player_index))

    local result_key = tags.result_key --[[@as string]]
    local raw_amount = tags.raw_amount --[[@as number]]
    local quantity_of_machines_required = save.get_quantity_of_machines_required(solution, result_key) + info.tolerance
    elem.number = info.to_scale(raw_amount, player_data.time_scale) * quantity_of_machines_required
end

---@param event EventDataTrait
function handlers.update_power(event)
    local elem = event.element
    local tags = elem.tags
    local player_data = save.get_player_data(event.player_index)
    local solution = assert(save.get_selected_solution(event.player_index))

    local result_key = tags.result_key --[[@as string]]
    local raw_amount = tags.raw_amount --[[@as number]]
    local quantity_of_machines_required = save.get_quantity_of_machines_required(solution, result_key)
    local amount = info.to_scale(raw_amount, player_data.time_scale) * quantity_of_machines_required
    elem.caption = common.format_power(amount)
end

---@param event EventDataTrait
function handlers.update_pollution(event)
    local elem = event.element
    local tags = elem.tags
    local player_data = save.get_player_data(event.player_index)
    local solution = assert(save.get_selected_solution(event.player_index))

    local result_key = tags.result_key --[[@as string]]
    local raw_amount = tags.raw_amount --[[@as number]]
    local quantity_of_machines_required = save.get_quantity_of_machines_required(solution, result_key)
    local amount = info.to_scale(raw_amount, player_data.time_scale) * quantity_of_machines_required
    elem.caption = flib_format.number(amount, false, 5)
end

---@param event EventData.on_gui_click
function handlers.on_production_line_recipe_click(event)
    local tags = event.element.tags
    if event.button == defines.mouse_button_type.left then
        common.open_gui(event.player_index, true, machine_setup, tags)
    elseif event.button == defines.mouse_button_type.right then
        local solution = assert(save.get_selected_solution(event.player_index))

        local typed_name = tags.recipe_typed_name --[[@as TypedName]]
        save.new_constraint(solution, typed_name)

        local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
        fs_util.dispatch_to_subtree(root, "on_constraint_changed", data)
    end
end

---@param event EventData.on_gui_click
function handlers.on_production_line_inout_click(event)
    local tags = event.element.tags
    local typed_name = tags.typed_name --[[@as TypedName]]
    local is_product = tags.is_product --[[@as boolean]]

    local line_index = tags.line_index --[[@as integer]]
    if not is_product then
        line_index = line_index + 1
    end

    if event.button == defines.mouse_button_type.left then
        local data = {
            typed_name = typed_name,
            is_choose_product = not is_product,
            is_choose_ingredient = is_product,
            line_index = line_index,
        }
        common.open_gui(event.player_index, true, production_line_adder, data)
    elseif event.button == defines.mouse_button_type.right then
        local solution = assert(save.get_selected_solution(event.player_index))

        save.new_constraint(solution, typed_name)

        local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
        fs_util.dispatch_to_subtree(root, "on_constraint_changed", data)
    end
end

---@param event EventData.on_gui_click
function handlers.on_move_production_line_click(event)
    local tags = event.element.tags
    local solution = assert(save.get_selected_solution(event.player_index))
    local from_line_index = tags.line_index --[[@as integer]]
    local direction = tags.direction

    if direction == "up" then
        local to_line_index
        if event.shift then
            to_line_index = 1
        elseif event.control then
            to_line_index = from_line_index - 5
        else
            to_line_index = from_line_index - 1
        end

        save.move_production_line(solution, from_line_index, to_line_index)
    elseif direction == "down" then
        local line_index2
        if event.shift then
            line_index2 = #solution.production_lines
        elseif event.control then
            line_index2 = from_line_index + 5
        else
            line_index2 = from_line_index + 1
        end

        save.move_production_line(solution, from_line_index, line_index2)
    end

    local root = assert(fs_util.find_upper(event.element, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_production_line_changed")
end

---@param event EventData.on_gui_click
function handlers.on_remove_production_line(event)
    local tags = event.element.tags
    local solution = assert(save.get_selected_solution(event.player_index))

    save.delete_production_line(solution, tags.line_index --[[@as integer]])

    local root = assert(fs_util.find_upper(event.element, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_production_line_changed")
end

fs_util.add_handlers(handlers)

---@diagnostic disable: missing-fields
---@type flib.GuiElemDef
return {
    type = "frame",
    name = "solution_editor",
    style = "inside_deep_frame",
    direction = "vertical",
    {
        type = "scroll-pane",
        style = "factory_solver_solution_editor_scroll_pane",
        {
            type = "table",
            style = "factory_solver_production_line_table",
            column_count = 9,
            handler = {
                on_added = handlers.make_production_line_table,
                on_selected_solution_changed = handlers.make_production_line_table,
                on_production_line_changed = handlers.make_production_line_table,
            },
        }
    },
}
