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

if mods["debugadapter"] and mods["base"] then
    -- A heat-fluid-inside boiler with no input filter; exercises the branch
    -- in create_boiler_virtual that enumerates one virtual recipe per fluid
    -- and heats each to its own FluidPrototype.max_temperature. No published
    -- mod is known to ship such a boiler, so this is the only way to cover
    -- that code path in-game.
    local universal_heater = table.deepcopy(data.raw["boiler"]["boiler"])
    universal_heater.name = "fs-test-universal-heater"
    universal_heater.minable = nil
    universal_heater.mode = "heat-fluid-inside"
    universal_heater.fluid_box.filter = nil
    universal_heater.output_fluid_box.filter = nil
    data:extend({ universal_heater })
end

-- ============================================================
-- TEST: FluidBox.maximum_temperature は受け入れをゲートするか?
-- 設置はマップエディタ (Editor > Entities で "fbtest" 検索)。item/recipe 不要。
-- 給湯は infinity-pipe (エディタ) で steam を任意温度に固定。
-- generator は電力負荷がないと回らないので、ランプ等を同電力網に置く。
-- ============================================================
local function make_fbtest(name, temp_field, temp_value)
    local e = table.deepcopy(data.raw.generator["steam-engine"])
    e.name = name
    e.localised_name = name
    e.minable = nil
    e.next_upgrade = nil
    e.placeable_by = nil
    -- generator 自身の上限は「探りたい対象でない」ので高く逃がす:
    e.maximum_temperature = 1000
    -- 作動流体 FluidBox を filter + 片側の温度境界だけにする:
    e.fluid_box.filter = "steam"
    e.fluid_box.minimum_temperature = nil
    e.fluid_box.maximum_temperature = nil
    e.fluid_box[temp_field] = temp_value
    return e
end

-- TEST: CraftingMachine の FluidEnergySource の FluidBox に付けた温度境界は
-- 燃料の受け入れをゲートするか? (energy_source.maximum_temperature フィールド
-- 自体は「非ゲート＝抽出頭打ち」と確定済み。ここで見るのは energy_source.fluid_box
-- レベルの min/max。) energy_source 自身の maximum_temperature は 1000 に逃がし、
-- fluid_box の境界だけを単独で効かせる。burns_fluid=false (steam を熱源として使用)。
local function make_fes_test(name, temp_field, temp_value)
    local e = table.deepcopy(data.raw["assembling-machine"]["assembling-machine-2"])
    e.name = name
    e.localised_name = name
    e.minable = nil
    e.next_upgrade = nil
    e.placeable_by = nil
    e.energy_usage = "100kW"
    e.energy_source = {
        type = "fluid",
        burns_fluid = false,
        scale_fluid_usage = true,
        destroy_non_fuel_fluid = false,
        maximum_temperature = 1000, -- energy_source 側は高く逃がす(探りたい対象でない)
        effectivity = 1,
        fluid_box = {
            volume = 200,
            production_type = "input",
            pipe_connections = {}, -- insert_fluid で直接注入するのでパイプ接続不要(衝突回避)
            filter = "steam",
            [temp_field] = temp_value, -- ★ 検証対象: energy_source.fluid_box の温度境界
        },
    }
    return e
end

-- ============================================================
-- TEST: 503efbb（実レシピの Recipes-for-fuel 温度フィルタ）の一対一検証。
-- 専用 crafting category に「テストレシピ1件」と「steam を下限100℃で受ける
-- 流体燃料 assembling-machine」だけを割り当て、他レシピの混入を排除する
-- (factory_solver は fixed_recipe を見ず crafting_category 単位で機械を解決
-- するため、隔離には専用カテゴリが必要)。
-- 手順: External source で steam を作り Recipes for fuel を開く。
--   steam@15  → fs-test-fuel-filter-recipe は出ないはず (機械が15を拒否)。
--   steam@165 (≥100) → 出るはず。出方が温度で切り替われば 503efbb が効いている。
-- ============================================================
if mods["debugadapter"] then
    local ffm = make_fes_test("fs-test-fuel-filter-machine", "minimum_temperature", 100)
    ffm.crafting_categories = { "fs-test-fuel-filter" }
    data:extend({
        { type = "recipe-category", name = "fs-test-fuel-filter" },
        ffm,
        {
            type = "recipe",
            name = "fs-test-fuel-filter-recipe",
            category = "fs-test-fuel-filter",
            enabled = true,
            energy_required = 1,
            ingredients = { { type = "item", name = "efficiency-module", amount = 1 } },
            results = { { type = "item", name = "speed-module", amount = 1 } },
        },
    })
end

if mods["debugadapter"] then
    -- Test data --
    data:extend({
        -- 対照群: minimum_temperature は受け入れゲートとして確定済み
        make_fbtest("fbtest-min-100", "minimum_temperature", 100),
        -- 本命(不明): maximum_temperature は同じようにゲートするか?
        make_fbtest("fbtest-max-100", "maximum_temperature", 100),
        -- CraftingMachine の FluidEnergySource.fluid_box 温度境界の検証用
        make_fes_test("fes-min-100", "minimum_temperature", 100),
        make_fes_test("fes-max-100", "maximum_temperature", 100),
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
        icon = "__factory_solver__/graphics/shortcut.png",
        small_icon = "__factory_solver__/graphics/shortcut.png",
        toggleable = true,
        associated_control_input = "factory-solver-toggle-main-window",
    },
    {
        type = "custom-input",
        name = "factory-solver-toggle-build-assistant",
        key_sequence = "CONTROL + SHIFT + R",
        order = "b"
    },
    {
        type = "shortcut",
        name = "factory-solver-toggle-build-assistant",
        order = "d",
        action = "lua",
        icon = "__factory_solver__/graphics/shortcut_ba.png",
        small_icon = "__factory_solver__/graphics/shortcut_ba.png",
        toggleable = true,
        associated_control_input = "factory-solver-toggle-build-assistant",
    },
})

data:extend({
    {
        type = "font",
        name = "factory_solver_slot_temperature_font",
        from = "default-bold",
        size = 10,
        border = true,
        border_color = { r = 0, g = 0, b = 0 },
    },
})

-- Tight-cropped variants of __core__ utility sprites, used as the top-right
-- overlay on virtual recipes that need a category indicator (research, spoilage).
-- The stock utility sprites have significant transparent padding inside their
-- frames, which made the overlay render visibly smaller and shifted relative
-- to utility/warning_icon (which fills its frame fully) when scaled into the
-- small overlay slot. Cropping to each sprite's content bounding box lets the
-- overlay fill the allocated px the same way the warning icon does.
data:extend({
    {
        -- bbox in __core__'s technology-white.png first mip level: (17,16)-(47,48).
        type = "sprite",
        name = "factory-solver-research-overlay",
        filename = "__core__/graphics/icons/mip/technology-white.png",
        x = 17,
        y = 16,
        width = 32,
        height = 32,
        flags = { "gui-icon" },
    },
    {
        -- Pre-rendered from __core__'s clock-icon.png: the source clock content
        -- is 24x29 (non-square), so feeding it directly to an image_style with
        -- stretch_image_to_widget_size produced a visibly smaller / aspect-
        -- mismatched render than the 32x32-square research overlay. We pad the
        -- content to square then upscale to 32x32 in the bundled asset so the
        -- intrinsic sprite size matches the research overlay and the round
        -- clock face stays circular when the overlay slot stretches it.
        type = "sprite",
        name = "factory-solver-spoilage-overlay",
        filename = "__factory_solver__/graphics/spoilage-overlay.png",
        width = 32,
        height = 32,
        flags = { "gui-icon" },
    },
    {
        type = "sprite",
        name = "factory-solver-source-overlay",
        filename = "__factory_solver__/graphics/external_source.png",
        width = 32,
        height = 32,
        flags = { "gui-icon" },
    },
    {
        type = "sprite",
        name = "factory-solver-sink-overlay",
        filename = "__factory_solver__/graphics/external_sink.png",
        width = 32,
        height = 32,
        flags = { "gui-icon" },
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

styles.factory_solver_centering_vertical_flow = {
    type = "vertical_flow_style",
    horizontal_align = "center",
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

styles.factory_solver_slot_temperature_label = {
    type = "label_style",
    height = 10,
    font = "factory_solver_slot_temperature_font",
    font_color = { r = 0.75, g = 0.95, b = 1 },
    hovered_font_color = { r = 0.75, g = 0.95, b = 1 },
    clicked_font_color = { r = 0.75, g = 0.95, b = 1 },
    parent_hovered_font_color = { r = 0.75, g = 0.95, b = 1 },
}

styles.factory_solver_slot_temperature_flow = {
    type = "vertical_flow_style",
    width = 40,
    height = 32,
    vertical_align = "top",
    horizontal_align = "left",
    vertical_spacing = 0,
    top_padding = -4,
    bottom_padding = 20,
    left_padding = 0,
    right_padding = 0,
}

-- Generic top-right slot overlay: a 32x32 sprite child whose padding
-- squeezes the drawable area into the top-right quadrant of a 40x40 slot
-- button. Modeled after the now-retired factory_solver_slot_image_with_quality
-- style (commit 04c98af). The slot's `number` badge sits at bottom-right and
-- the engine's native `quality` indicator sits at bottom-left, so top-right
-- is the remaining corner free of collision. The first caller is the module
-- picker (warning icon for effect-masked modules); the parameter is kept
-- as a freeform sprite path on common.create_decorated_sprite_button so
-- future callers can render different indicators in the same slot region.
styles.factory_solver_slot_image_top_right = {
    type = "image_style",
    width = 32,
    height = 32,
    top_padding = 1,
    bottom_padding = 18,
    left_padding = 19,
    right_padding = 0,
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

-- Build assistant's compact rows (done | recipe | required | machine | beacons).
-- Same row striping and spacing as the main production-line table, but its own
-- column alignments: the Required number is right-aligned to read identically
-- to the main window's Required column, and the padding is trimmed (left/right
-- only) so rows sit close to the docked panel's edges.
styles.factory_solver_build_assistant_table = {
    type = "table_style",
    horizontal_spacing = 8,
    vertical_spacing = 10,
    top_padding = 0,
    bottom_padding = 0,
    left_padding = 4,
    right_padding = 4,
    column_alignments = {
        {
            column = 1,
            alignment = "center",
        },
        {
            column = 2,
            alignment = "center",
        },
        {
            column = 3,
            alignment = "right",
        },
        {
            column = 4,
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

styles.factory_solver_filter_group_tab = {
    type = "tab_style",
    minimal_width = 80,
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

styles.factory_solver_fit_filter_scroll_pane = {
    type = "scroll_pane_style",
    parent = "deep_slots_scroll_pane",
    maximal_height = 360,
    left_margin = 12,
    right_margin = 12,
}

styles.factory_solver_dialog_fit_scroll_pane = {
    type = "scroll_pane_style",
    parent = "scroll_pane",
    padding = 12,
    maximal_height = 600,
}

styles.factory_solver_filter_background_frame = {
    type = "frame_style",
    parent = "factory_solver_slot_background_frame",
    width = 400,
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
