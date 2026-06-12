---@diagnostic disable: undefined-global

if not mods["base"] then
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

-- Debug-only synthetic test prototypes (LP stress recipes, fluid-temperature
-- probes, virtual-recipe edge entities) live in data_test.lua. See that file for
-- the coverage map of which create_*_virtual / accessor branch each one
-- exercises. The file is excluded from the published mod (info.json
-- package.ignore), so a player build cannot load it; any dev / test checkout
-- always does. That is what lets the headless RCON smoke (tests/smoke_rcon.ps1)
-- reach the virtual-recipe / accessor branches vanilla + Space Age don't cover
-- WITHOUT the factoriomod-debug extension (debugadapter can't load on a server,
-- and --enable-unsafe-lua-debug-api is rejected with servers, so neither of
-- those gating signals is reachable from the RCON tooling). pcall keeps the
-- "module data_test not found" of a published build benign, but any genuine
-- error inside data_test.lua is re-raised so dev edits stay honest.
local ok, err = pcall(require, "data_test")
if not ok and not tostring(err):find("module data_test not found", 1, true) then
    error(err)
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
    {
        -- Editor next-step guide: a touch larger than the default label so the
        -- "what to do next" hint reads as a prompt rather than ambient help.
        type = "font",
        name = "factory_solver_getting_started_font",
        from = "default",
        size = 18,
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

-- Hover-highlight slot styles. The "same kind" highlight reuses each slot
-- button's own hovered graphic as its resting graphic, so a highlighted slot
-- looks exactly like the one the cursor is actually over (no separate orange
-- tint, which reads as a distinct state rather than "related to what I'm
-- hovering"). One per base colour get_style can return (default / blue / grey /
-- yellow); the runtime swaps a slot to its matching *_highlighted style on
-- hover and back on leave. flib's slot button styles are registered in the data
-- stage before this mod (flib is a dependency), so their hovered_graphical_set
-- is readable here.
for _, color in ipairs({ "default", "blue", "grey", "yellow" }) do
    local base_name = "flib_slot_button_" .. color
    styles["factory_solver_slot_button_" .. color .. "_highlighted"] = {
        type = "button_style",
        parent = base_name,
        default_graphical_set = styles[base_name].hovered_graphical_set,
    }
end

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

styles.factory_solver_getting_started_flow = {
    type = "vertical_flow_style",
    vertical_spacing = 8,
    padding = 12,
    horizontal_align = "left",
    horizontally_stretchable = "on",
}

-- One-line description shown under each dialog's title bar. Stretches to the
-- dialog's content width (single_line=false keeps its min width small, so it
-- never widens the dialog) and is dimmed so it reads as ambient help.
styles.factory_solver_dialog_description_label = {
    type = "label_style",
    single_line = false,
    horizontally_stretchable = "on",
    bottom_margin = 8,
    font_color = { r = 0.7, g = 0.7, b = 0.7 },
}

styles.factory_solver_getting_started_label = {
    type = "label_style",
    single_line = false,
    -- Fill the stretched flow so each step wraps at the panel width instead of
    -- collapsing to its longest-word minimum.
    horizontally_stretchable = "on",
    -- White and a touch larger so the next-step hint reads as a prompt.
    font = "factory_solver_getting_started_font",
    font_color = { r = 1, g = 1, b = 1 },
}

-- solution_selector

styles.factory_solver_solution_list = {
    type = "list_box_style",
    vertically_stretchable = "on",
}

-- right panel shared --

-- Both right-panel sections (constraints + results) use this one frame style, so
-- they end up the same fixed height and read as two equal halves of the column.
-- Parent is inside_shallow_frame (no padding): the padding lives on the scroll-
-- pane inside, not the frame, so the scrollbar tracks the frame edge instead of
-- floating in an outer padding gap.
styles.factory_solver_right_panel_half_frame = {
    type = "frame_style",
    parent = "inside_shallow_frame",
    height = 334,
}

-- Borderless, backgroundless scroll-pane: naked_scroll_pane draws no graphical_set
-- at all (base "scroll_pane" draws outer_frame_light, which would read as a second
-- nested frame), so the parent half-frame's background shows through unchanged.
-- The padding sits here (inside the scroll area) rather than on the frame so the
-- scrollbar gutter stays flush with the frame edge.
styles.factory_solver_right_panel_scroll_pane = {
    type = "scroll_pane_style",
    parent = "naked_scroll_pane",
    padding = 12,
}

-- solution_settings

styles.factory_solver_constraints_table = {
    type = "table_style",
    bottom_margin = 4,
    horizontal_spacing = 8,
    vertical_spacing = 10,
}

styles.factory_solver_limit_amount_textfield = {
    type = "textbox_style",
    width = 80,
}

styles.factory_solver_limit_type_dropdown = {
    type = "dropdown_style",
    width = 136,
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
    bottom_padding = 12,
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

-- factory_solver_name_filter_textfield --
-- Title-bar name filter shared by the constraint adder and production-line
-- adder. Sits between the drag handle and the close button, so it is kept
-- narrow.

styles.factory_solver_name_filter_textfield = {
    type = "textbox_style",
    width = 180,
}
