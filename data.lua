---@diagnostic disable: undefined-global

if mods["base"] then
    -- Fixed base bug.
    -- data.raw["recipe"]["electric-energy-interface"].hidden = true
else
    data:extend({
        {
            type = "item-group",
            name = "other",
            icon = "__core__/graphics/icons/category/unsorted.png",
            icon_size = 128,
            order = "z"
        },
        {
            type = "item-subgroup",
            name = "other",
            group = "other",
            order = "d"
        },
    })
end

if mods["debugadapter"] then
    -- Test data --
    data:extend({
        {
            type = "recipe",
            name = "fs-test-base",
            enabled = true,
            energy_required = 1,
            ingredients =
            {
                { type = "item", name = "efficiency-module", amount = 1 },
                { type = "item", name = "speed-module", amount = 1 },
            },
            results = {
                { type = "item", name = "efficiency-module-2",   amount = 1 },
                { type = "item", name = "speed-module-2", amount = 1 },
            },
            main_product = "efficiency-module-2",
        },
        {
            type = "recipe",
            name = "fs-test-short-positive",
            enabled = true,
            energy_required = 1,
            ingredients =
            {
                { type = "item", name = "speed-module-2", amount = 1 },
            },
            results = {
                { type = "item", name = "speed-module", amount = 2 },
            }
        },
        {
            type = "recipe",
            name = "fs-test-short-negative",
            enabled = true,
            energy_required = 1,
            ingredients =
            {
                { type = "item", name = "speed-module-2", amount = 2 },
            },
            results = {
                { type = "item", name = "speed-module", amount = 1 },
            }
        },
        {
            type = "recipe",
            name = "fs-test-long-positive-1",
            enabled = true,
            energy_required = 1,
            ingredients =
            {
                { type = "item", name = "speed-module-2", amount = 1 },
            },
            results = {
                { type = "item", name = "speed-module-3", amount = 2 },
            }
        },
        {
            type = "recipe",
            name = "fs-test-long-positive-2",
            enabled = true,
            energy_required = 1,
            ingredients =
            {
                { type = "item", name = "speed-module-3", amount = 1 },
            },
            results = {
                { type = "item", name = "speed-module", amount = 2 },
            }
        },
        {
            type = "recipe",
            name = "fs-test-long-negative-1",
            enabled = true,
            energy_required = 1,
            ingredients =
            {
                { type = "item", name = "speed-module-2", amount = 2 },
            },
            results = {
                { type = "item", name = "speed-module-3", amount = 1 },
            }
        },
        {
            type = "recipe",
            name = "fs-test-long-negative-2",
            enabled = true,
            energy_required = 1,
            ingredients =
            {
                { type = "item", name = "speed-module-3", amount = 2 },
            },
            results = {
                { type = "item", name = "speed-module", amount = 1 },
            }
        },
        {
            type = "recipe",
            name = "fs-test-parallel-1",
            enabled = true,
            energy_required = 1,
            ingredients =
            {
                { type = "item", name = "efficiency-module-2",   amount = 1 },
                { type = "item", name = "speed-module-2", amount = 2 },
            },
            results = {
                { type = "item", name = "efficiency-module-3",   amount = 1 },
            }
        },
        {
            type = "recipe",
            name = "fs-test-parallel-2",
            enabled = true,
            energy_required = 1,
            ingredients =
            {
                { type = "item", name = "efficiency-module-2",   amount = 2 },
                { type = "item", name = "speed-module-2", amount = 1 },
            },
            results = {
                { type = "item", name = "efficiency-module-3",   amount = 1 },
            }
        },
    })
end

data:extend({
    {
        type = "custom-input",
        name = "factory-solver-toggle-main-window",
        key_sequence = "CONTROL + R",
        order = "a"
    },
    {
        type = "shortcut",
        name = "factory-solver-toggle-main-window",
        order = "c",
        action = "lua",
        icon = "__core__/graphics/questionmark.png",
        small_icon = "__core__/graphics/questionmark.png",
        toggleable = true,
        associated_control_input = "factory-solver-toggle-main-window",
    },
})

local styles = data.raw["gui-style"].default

-- common --

styles.factory_solver_shallow_frame_in_shallow_frame = {
    type = "frame_style",
    parent = "flib_shallow_frame_in_shallow_frame",
    padding = 12,
    horizontally_stretchable = "on",
    vertically_stretchable = "on",
}

styles.factory_solver_slot_background_frame = {
    type = "frame_style",
    parent = "slot_button_deep_frame",
    minimal_height = 40,
    background_graphical_set =
    {
        position = { 282, 17 },
        corner_size = 8,
        overall_tiling_vertical_size = 32,
        overall_tiling_vertical_spacing = 8,
        overall_tiling_vertical_padding = 4,
        overall_tiling_horizontal_size = 32,
        overall_tiling_horizontal_spacing = 8,
        overall_tiling_horizontal_padding = 4
    }
}

styles.factory_solver_line = {
    type = "line_style",
    top_margin = 4,
    bottom_margin = 4,
}

styles.factory_solver_scroll_pane = {
    type = "scroll_pane_style",
    padding = 12,
    height = 360,
}

styles.factory_solver_craft_visible_control_table = {
    type = "table_style",
    horizontal_spacing = 16,
}

styles.factory_solver_centering_horizontal_flow = {
    type = "horizontal_flow_style",
    vertical_align = "center",
}

styles.factory_solver_no_spacing_vertical_flow_style = {
    type = "vertical_flow_style",
    vertical_spacing = 0,
}

styles.factory_solver_fake_slot = {
    type = "empty_widget_style",
    width = 40,
    height = 40,
}

styles.factory_solver_slot_label = {
    type = "label_style",
    parent = "count_label",
    width = 40,
    height = 40,
}

styles.factory_solver_slot_image_with_quality = {
    type = "image_style",
    width = 32,
    height = 32,
    top_padding = 18,
    bottom_padding = 1,
    right_padding = 19,
    stretch_image_to_widget_size = true,
}

-- main_window --

styles.factory_solver_main_window = {
    type = "frame_style",
    width = 1280,
    height = 720,
}

styles.factory_solver_contents = {
    type = "horizontal_flow_style",
    vertically_stretchable = "on",
}

styles.factory_solver_left_panel = {
    type = "vertical_flow_style",
    width = 184,
    horizontally_stretchable = "off",
}

styles.factory_solver_right_panel = {
    type = "vertical_flow_style",
    width = 344,
    horizontally_stretchable = "off",
}

-- solution_editor --

styles.factory_solver_solution_editor_scroll_pane = {
    type = "scroll_pane_style",
    parent = "scroll_pane",
    vertically_stretchable = "on",
    horizontally_stretchable = "on",
}

styles.factory_solver_production_line_table = {
    type = "table_style",
    horizontal_spacing = 8,
    vertical_spacing = 10,
    padding = 12,
    column_alignments = {
        {
            column = 1,
            alignment = "center",
        },
        {
            column = 3,
            alignment = "right",
        },
        {
            column = 7,
            alignment = "right",
        },
        {
            column = 8,
            alignment = "right",
        },
    },
    odd_row_graphical_set =
    {
        filename = "__core__/graphics/gui-new.png",
        position = { 472, 25 },
        size = 1
    },
}

styles.factory_solver_production_line_header_label = {
    type = "label_style",
    parent = "bold_label",
}

-- solution_selector

styles.factory_solver_solution_list = {
    type = "list_box_style",
    vertically_stretchable = "on",
}

-- solution_settings

styles.factory_solver_constraints_table = {
    type = "table_style",
    bottom_margin = 4,
    horizontal_spacing = 8,
    vertical_spacing = 10,
    vertically_stretchable = "on",
}

styles.factory_solver_limit_amount_textfield = {
    type = "textbox_style",
    width = 80,
}

styles.factory_solver_limit_type_dropdown = {
    type = "dropdown_style",
    width = 160,
    top_margin = 2,
}

-- solution_results

styles.factory_solver_result_slot_background_frame = {
    type = "frame_style",
    parent = "factory_solver_slot_background_frame",
    width = 320,
    top_margin = 4,
    bottom_margin = 4,
}

styles.factory_solver_result_layout_table = {
    type = "table_style",
    horizontal_spacing = 16,
    column_alignments = {
        {
            column = 2,
            alignment = "right",
        },
    },
}

styles.factory_solver_result_centering_flow = {
    type = "horizontal_flow_style",
    horizontal_align = "center",
    horizontally_stretchable = "on",
}

-- machine_presets --

styles.factory_solver_preset_scroll_pane = {
    type = "scroll_pane_style",
    parent = "factory_solver_scroll_pane",
    height = 540,
}

styles.factory_solver_preset_layout_table = {
    type = "table_style",
    horizontal_spacing = 16,
    column_widths = {
        {
            column = 1,
            width = 160,
        },
    }
}

-- machine_setup --

styles.factory_solver_beacons_table = {
    type = "table_style",
    bottom_margin = 4,
    horizontal_spacing = 8,
    vertical_spacing = 10,
}

styles.factory_solver_beacon_quantity_textfield = {
    type = "textbox_style",
    width = 60,
}

styles.factory_solver_effectivity_slot_background_frame = {
    type = "frame_style",
    parent = "factory_solver_slot_background_frame",
    width = 240,
}

-- constraint_adder --

styles.factory_solver_filter_type_tabbed_pane = {
    type = "tabbed_pane_style",
    parent = "tabbed_pane_with_no_side_padding",
    horizontally_stretchable = "on",
}

styles.factory_solver_filter_group_background_frame = {
    type = "frame_style",
    parent = "slot_button_deep_frame",
    background_graphical_set =
    {
        position = { 282, 17 },
        corner_size = 8,
        overall_tiling_vertical_size = 44,
        overall_tiling_vertical_spacing = 20,
        overall_tiling_vertical_padding = 10,
        overall_tiling_horizontal_size = 44,
        overall_tiling_horizontal_spacing = 26,
        overall_tiling_horizontal_padding = 13,
    },
}

styles.factory_solver_filter_group_button = {
    type = "button_style",
    parent = "filter_group_button_tab_slightly_larger",
    width = 0,
    height = 64,
    natural_width = 0,
    minimal_width = 64,
    horizontally_stretchable = "on",
    padding = 4,
}

styles.factory_solver_filter_picker_frame = {
    type = "frame_style",
    top_padding = 4,
    right_padding = 0,
    left_padding = 0,
    bottom_padding = 4,
    graphical_set = tabbed_pane_graphical_set
}

styles.factory_solver_filter_scroll_pane = {
    type = "scroll_pane_style",
    parent = "deep_slots_scroll_pane",
    height = 360,
    left_margin = 12,
    right_margin = 12,
}

styles.factory_solver_filter_background_frame = {
    type = "frame_style",
    parent = "factory_solver_slot_background_frame",
    minimal_width = 400,
    minimal_height = 360,
}

-- production_line_adder --

styles.factory_solver_choose_table = {
    type = "table_style",
    width = 312,
    top_padding = 10,
    horizontal_spacing = 16,
    vertical_spacing = 20,
}

styles.factory_solver_group_sprite = {
    type = "image_style",
    width = 56,
    height = 56,
}

styles.factory_solver_craft_visible_control_flow = {
    type = "horizontal_flow_style",
    top_padding = 12,
    horizontal_align = "center",
    horizontally_stretchable = "on",
}

styles.factory_solver_recipe_slot_background_frame = {
    type = "frame_style",
    parent = "factory_solver_slot_background_frame",
    width = 240,
}

-- factory_solver_rename_textfield --

styles.factory_solver_rename_textfield = {
    type = "textbox_style",
    width = 224,
}
