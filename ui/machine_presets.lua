local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local save = require "manage/save"
local preset = require "manage/preset"
local tn = require "manage/typed_name"
local common = require "ui/common"
local picker_build = require "ui/picker_build"

local handlers = {}

-- The (key, caption, crafts) rows of one preset section. Most preset types are one
-- row per category; machine presets split a category into ingredient_count tiers
-- (preset.machine_preset_tiers), each its own row and key. `crafts` holds prototype
-- objects (machines / fuels), resolved to names + TypedNames in the build plan.
local function preset_rows(preset_type)
    local categories
    if preset_type == "fuel" then
        categories = storage.virtuals.fuel_categories_dictionary
    elseif preset_type == "fluid_fuel" then
        categories = { ["<any-fluid-fuel>"] = true }
    elseif preset_type == "resource" then
        categories = prototypes.resource_category
    elseif preset_type == "machine" then
        categories = prototypes.recipe_category
    elseif preset_type == "fixed_recipe" then
        categories = storage.virtuals.shared_fixed_recipes
    else
        assert()
    end

    local out = {}
    for category_name, value in pairs(categories) do
        -- The engine auto-adds the core "parameters" crafting category to every
        -- crafting machine for parametrised blueprints; its row would just duplicate
        -- every real machine under a meaningless heading, so skip it.
        if not (preset_type == "machine" and category_name == "parameters") then
            if preset_type == "fuel" then
                out[#out + 1] = { key = category_name, caption = category_name,
                    crafts = acc.get_fuels_in_categories(value --[[@as { [string]: true }]]) }
            elseif preset_type == "fluid_fuel" then
                out[#out + 1] = { key = category_name, caption = category_name,
                    crafts = acc.get_any_fluid_fuels() }
            elseif preset_type == "resource" then
                out[#out + 1] = { key = category_name, caption = category_name,
                    crafts = acc.get_machines_in_resource_category(category_name) }
            elseif preset_type == "machine" then
                for _, tier in ipairs(preset.machine_preset_tiers(category_name)) do
                    local caption = tier.threshold
                        and { "factory-solver-machine-preset-tier", category_name, tostring(tier.threshold) }
                        or category_name
                    out[#out + 1] = { key = tier.key, caption = caption, crafts = tier.machines }
                end
            elseif preset_type == "fixed_recipe" then
                local recipe = prototypes.recipe[category_name]
                out[#out + 1] = { key = category_name, caption = recipe.localised_name,
                    crafts = acc.get_machines_for_recipe(recipe) }
            end
        end
    end
    return out
end

-- The currently-selected preset for one row (explicit per type, not dynamic, to
-- keep the Presets type checkable). Mirrors on_preset_change_toggle's lookup.
local function preset_selected(presets, preset_type, row_key)
    if preset_type == "fuel" then
        return presets.fuel[row_key]
    elseif preset_type == "fluid_fuel" then
        return presets.fluid_fuel
    elseif preset_type == "resource" then
        return presets.resource[row_key]
    elseif preset_type == "machine" then
        return presets.machine[row_key]
    elseif preset_type == "fixed_recipe" then
        return presets.fixed_recipe[row_key]
    end
end

---@param event EventDataTrait
function handlers.on_memorize_machine_presets(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)

    elem.tags = {
        presets = flib_table.deep_copy(player_data.presets),
    }
end

---Light handler: clear the section's layout table and arm a tick-split build.
---Each preset section can be hundreds of rows / ~1000 buttons (machine alone is one
---tier-row per recipe_category), so building all five synchronously on dialog open
---froze ~100ms in one tick. ui/picker_build spreads the build across ticks (one
---section advanced per tick via control.lua's on_tick -> advance_all). Runs on
---on_added and on_craft_visible_changed; re-arming overwrites = cancel + restart.
---@param event EventDataTrait
function handlers.on_make_preset_tables(event)
    local elem = event.element
    local preset_type = elem.tags.preset_type --[[@as string]]
    elem.clear()
    picker_build.request(event.player_index, "preset_" .. preset_type, {
        spec_id = "machine_presets",
        preset_type = preset_type,
        dialog_name = "factory_solver_machine_presets",
    })
end

---@param event EventData.on_gui_click
function handlers.on_preset_button_click(event)
    if common.try_open_factoriopedia(event) then return end
    local elem = event.element
    local typed_name = elem.tags.typed_name --[[@as TypedName]]
    local category_name = elem.tags.category_name
    local preset_type = elem.tags.preset_type
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))

    local dialog_tags = dialog.tags
    if preset_type == "fuel" then
        dialog_tags.presets.fuel[category_name] = typed_name
    elseif preset_type == "fluid_fuel" then
        dialog_tags.presets.fluid_fuel = typed_name
    elseif preset_type == "resource" then
        dialog_tags.presets.resource[category_name] = typed_name
    elseif preset_type == "machine" then
        dialog_tags.presets.machine[category_name] = typed_name
    elseif preset_type == "fixed_recipe" then
        dialog_tags.presets.fixed_recipe[category_name] = typed_name
    else
        assert()
    end

    dialog.tags = dialog_tags
    -- Only the clicked row's buttons change toggled state (its category's selection
    -- moved); re-sync just that slot table, not the whole dialog. elem.parent is the
    -- filter_slot_table holding this category's buttons. A dialog-wide dispatch here
    -- would re-toggle every preset button -- each snapshotting dialog.tags -- for no
    -- reason, the same cost the build path used to pay.
    fs_util.dispatch_to_subtree(elem.parent, "on_preset_changed")
end

---@param event EventDataTrait
function handlers.on_preset_change_toggle(event)
    local elem = event.element
    local typed_name = elem.tags.typed_name --[[@as TypedName]]
    local category_name = elem.tags.category_name
    local preset_type = elem.tags.preset_type
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))

    local dialog_tags = dialog.tags
    local selected
    if preset_type == "fuel" then
        selected = dialog_tags.presets.fuel[category_name]
    elseif preset_type == "fluid_fuel" then
        selected = dialog_tags.presets.fluid_fuel
    elseif preset_type == "resource" then
        selected = dialog_tags.presets.resource[category_name]
    elseif preset_type == "machine" then
        selected = dialog_tags.presets.machine[category_name]
    elseif preset_type == "fixed_recipe" then
        selected = dialog_tags.presets.fixed_recipe[category_name]
    end
    assert(selected)

    elem.toggled = tn.equals_typed_name(selected, typed_name, true)
end

---@param event EventData.on_gui_click
function handlers.on_machine_presets_confirm(event)
    local player_data = save.get_player_data(event.player_index)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))

    player_data.presets = dialog.tags.presets --[[@as Presets]]

    local re_event = fs_util.create_gui_event(dialog)
    common.on_close_self(re_event)
end

-- Tick-split spec for the five preset sections. Each section is its own build keyed
-- "preset_<type>"; find_table re-finds that section's named layout table. The layout
-- table is a 2-column table, one row = [caption label, slot-table frame]; open_group
-- starts a row (label + empty slot table), make_button fills it. group_of is the row
-- key (a row change = a new label + table). Toggled is set at build time from the
-- plan's per-row selected preset (reading dialog.tags.presets once in plan, never
-- per button); the click path keeps on_preset_changed for the narrow per-row re-sync.
picker_build.register_spec {
    id = "machine_presets",

    find_table = function(player_index, req)
        local dialog = common.find_root_element(player_index, req.dialog_name)
        if not dialog then return nil end
        -- The scroll-pane is found high in the tree (before any built buttons); its
        -- section frames hold the named layout tables among their few direct children,
        -- so this never DFS-walks the rows already placed.
        local scroll = fs_util.find_lower(dialog, "fs_preset_scroll")
        if not scroll then return nil end
        local target = "fs_preset_" .. req.preset_type
        for _, frame in ipairs(scroll.children) do
            for _, child in ipairs(frame.children) do
                if child.name == target then return child end
            end
        end
        return nil
    end,

    plan = function(player_index, req)
        local preset_type = req.preset_type
        local relation_to_recipes = save.get_relation_to_recipes(player_index)
        local dialog = common.find_root_element(player_index, req.dialog_name)
        local presets = dialog and dialog.tags.presets --[[@as Presets?]]

        local entries, group_of = {}, {}
        local typed_name_of, is_hidden_of, is_unresearched_of = {}, {}, {}
        local row_caption, row_selected = {}, {}
        for _, row in ipairs(preset_rows(preset_type)) do
            -- A single (or empty) choice is not a meaningful preset; skip the row.
            if #row.crafts > 1 then
                row_caption[row.key] = row.caption
                if presets then row_selected[row.key] = preset_selected(presets, preset_type, row.key) end
                for _, craft in ipairs(row.crafts) do
                    entries[#entries + 1] = craft.name
                    group_of[#group_of + 1] = row.key
                    typed_name_of[#typed_name_of + 1] = tn.craft_to_typed_name(craft)
                    is_hidden_of[#is_hidden_of + 1] = acc.is_hidden(craft)
                    is_unresearched_of[#is_unresearched_of + 1] = acc.is_unresearched(craft, relation_to_recipes)
                end
            end
        end
        ---@type PickerBuildPlan
        return {
            entries = entries,
            group_of = group_of,
            typed_name_of = typed_name_of,
            is_hidden_of = is_hidden_of,
            is_unresearched_of = is_unresearched_of,
            row_caption = row_caption,
            row_selected = row_selected,
        }
    end,

    -- Start a row: the caption label (col 1) + a slot-table frame (col 2); return
    -- the inner slot table. plan carries the per-row caption keyed by group_of.
    open_group = function(player_index, req, layout_table, row_key, plan)
        fs_util.add_gui(layout_table, {
            type = "label",
            caption = plan.row_caption[row_key],
            -- single_line is a LuaStyle property, so it rides in style_mods; long
            -- ingredient-count tier captions then wrap inside the 160px column.
            style_mods = { single_line = false, maximal_width = 160 },
        })
        fs_util.add_gui(layout_table, {
            type = "frame",
            style = "factory_solver_slot_background_frame",
            { type = "table", style = "filter_slot_table", column_count = 6 },
        })
        local kids = layout_table.children
        return kids[#kids].children[1]
    end,

    current_slot = function(player_index, req, layout_table)
        local kids = layout_table.children
        return kids[#kids].children[1]
    end,

    make_button = function(player_index, req, plan, i)
        local player_data = save.get_player_data(player_index)
        local is_hidden = plan.is_hidden_of[i]
        local is_unresearched = plan.is_unresearched_of[i]
        if not common.craft_visible(is_hidden, is_unresearched, player_data) then
            return nil
        end
        local typed_name = plan.typed_name_of[i]
        local row_key = plan.group_of[i]
        local selected = plan.row_selected[row_key]
        local def = common.create_decorated_sprite_button {
            typed_name = typed_name,
            is_hidden = is_hidden,
            is_unresearched = is_unresearched,
            -- Dialog slots opt out of the per-hover full-grid refresh_highlight.
            no_hover_highlight = true,
            tags = {
                typed_name = typed_name,
                category_name = row_key,
                preset_type = req.preset_type,
            },
            handler = {
                [defines.events.on_gui_click] = handlers.on_preset_button_click,
                on_preset_changed = handlers.on_preset_change_toggle,
            },
        }
        -- toggled is a LuaGuiElement property; it rides in elem_mods on the def.
        def.elem_mods = {
            toggled = selected ~= nil and tn.equals_typed_name(selected, typed_name, true) or false,
        }
        return def
    end,

    -- The Fixed-recipe section is empty for vanilla / most mods (no recipe has >=2
    -- fixed_recipe machines), so hide its whole frame when the finished build placed
    -- no rows. The layout table is the section frame's only sizeable child, so
    -- toggling the parent is safe; runs on completion even for an empty plan.
    on_done = function(player_index, req, layout_table)
        if req.preset_type == "fixed_recipe" then
            layout_table.parent.visible = #layout_table.children > 0
        end
    end,
}

fs_util.add_handlers(handlers)

---@type fs.GuiElemDef
return {
    type = "frame",
    name = "factory_solver_machine_presets",
    direction = "vertical",
    handler = {
        on_added = handlers.on_memorize_machine_presets,
    },
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = "factory_solver_machine_presets",
        },
        handler = {
            on_added = common.on_init_drag_target
        },
        {
            type = "label",
            style = "frame_title",
            caption = { "factory-solver-machine-presets" },
            ignored_by_interaction = true,
        },
        {
            type = "empty-widget",
            style = "flib_titlebar_drag_handle",
            ignored_by_interaction = true,
        },
    },
    {
        type = "label",
        style = "factory_solver_dialog_description_label",
        caption = { "factory-solver-desc-machine-presets" },
    },
    {
        type = "frame",
        style = "inside_shallow_frame",
        direction = "vertical",
        style_mods = {
            width = 440,
            bottom_padding = 12,
        },
        {
            type = "scroll-pane",
            name = "fs_preset_scroll",
            style = "factory_solver_preset_scroll_pane",
            direction = "vertical",
            horizontal_scroll_policy = "never",
            vertical_scroll_policy = "always",
            {
                type = "frame",
                style = "factory_solver_shallow_frame_in_shallow_frame",
                direction = "vertical",
                {
                    type = "label",
                    style = "caption_label",
                    caption = { "factory-solver-fuels" },
                },
                {
                    type = "table",
                    name = "fs_preset_fuel",
                    style = "factory_solver_preset_layout_table",
                    column_count = 2,
                    tags = {
                        preset_type = "fuel",
                    },
                    handler = {
                        on_added = handlers.on_make_preset_tables,
                        on_craft_visible_changed = handlers.on_make_preset_tables,
                    },
                },
                {
                    type = "table",
                    name = "fs_preset_fluid_fuel",
                    style = "factory_solver_preset_layout_table",
                    column_count = 2,
                    tags = {
                        preset_type = "fluid_fuel",
                    },
                    handler = {
                        on_added = handlers.on_make_preset_tables,
                        on_craft_visible_changed = handlers.on_make_preset_tables,
                    },
                },
            },
            {
                type = "frame",
                style = "factory_solver_shallow_frame_in_shallow_frame",
                direction = "vertical",
                {
                    type = "label",
                    style = "caption_label",
                    caption = { "factory-solver-minings" },
                },
                {
                    type = "table",
                    name = "fs_preset_resource",
                    style = "factory_solver_preset_layout_table",
                    column_count = 2,
                    tags = {
                        preset_type = "resource",
                    },
                    handler = {
                        on_added = handlers.on_make_preset_tables,
                        on_craft_visible_changed = handlers.on_make_preset_tables,
                    },
                },
            },
            {
                type = "frame",
                style = "factory_solver_shallow_frame_in_shallow_frame",
                direction = "vertical",
                {
                    type = "label",
                    style = "caption_label",
                    caption = { "factory-solver-machines" },
                },
                {
                    type = "table",
                    name = "fs_preset_machine",
                    style = "factory_solver_preset_layout_table",
                    column_count = 2,
                    tags = {
                        preset_type = "machine",
                    },
                    handler = {
                        on_added = handlers.on_make_preset_tables,
                        on_craft_visible_changed = handlers.on_make_preset_tables,
                    },
                },
            },
            {
                type = "frame",
                style = "factory_solver_shallow_frame_in_shallow_frame",
                direction = "vertical",
                {
                    type = "label",
                    style = "caption_label",
                    caption = { "factory-solver-fixed-recipe-machines" },
                },
                {
                    type = "table",
                    name = "fs_preset_fixed_recipe",
                    style = "factory_solver_preset_layout_table",
                    column_count = 2,
                    tags = {
                        preset_type = "fixed_recipe",
                    },
                    handler = {
                        on_added = handlers.on_make_preset_tables,
                        on_craft_visible_changed = handlers.on_make_preset_tables,
                    },
                },
            },
        },
        -- One craft-visibility control governs all five preset tables; toggling
        -- dispatches on_craft_visible_changed to the root, which every table listens
        -- for and rebuilds from.
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
                        root_gui = "factory_solver_machine_presets",
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
                        root_gui = "factory_solver_machine_presets",
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
    {
        type = "flow",
        name = "dialog_buttons",
        {
            type = "button",
            style = "back_button",
            caption = { "gui.cancel" },
            tags = {
                close_target = "factory_solver_machine_presets",
            },
            handler = {
                [defines.events.on_gui_click] = common.on_close_target
            },
        },
        {
            type = "empty-widget",
            style = "flib_dialog_footer_drag_handle",
            ignored_by_interaction = true,
        },
        {
            type = "button",
            style = "confirm_button",
            caption = { "gui.confirm" },
            handler = {
                [defines.events.on_gui_click] = handlers.on_machine_presets_confirm,
            }
        },
    },
}
